/*
 * FuseVault — Encrypted FUSE Filesystem
 *
 * File format on disk (each .enc file in the backing store):
 *
 *  ┌──────────────────┬──────────────┬───────────────────────┬────────────────┐
 *  │ PLAINTEXT_SIZE   │   IV (16 B)  │  Encrypted FEK (48 B) │  Ciphertext    │
 *  │     (4 B)        │              │  (FEK wrapped w/ mkey)│                │
 *  └──────────────────┴──────────────┴───────────────────────┴────────────────┘
 *  ←───────────────────── HEADER_SIZE = 68 bytes ──────────────────────────────→
 *
 * Encryption model:
 *   - Each file write generates a fresh random 32-byte File Encryption Key (FEK)
 *   - File content is encrypted with AES-256-CBC using the FEK and a random IV
 *   - The FEK itself is encrypted with AES-256-CBC using the master key and same IV
 *   - Compromising one file's FEK has zero impact on other files
 *
 * Audit log format (hash-chained, tamper-evident):
 *   [timestamp] [user] OP path PREV=<prev_sha256> HASH=<this_sha256>
 *   The HASH field is SHA-256([timestamp] [user] OP path PREV=<prev_sha256>)
 *   First entry uses PREV=GENESIS
 *
 * Security features:
 *   - OPENSSL_cleanse() on all key material and plaintext buffers after use
 *   - mlock() pins master key in RAM (never swaps to disk)
 *   - destroy() callback clears master key on unmount
 */

#define FUSE_USE_VERSION 26

#include <fuse.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/file.h>   /* flock */
#include <sys/mman.h>   /* mlock/munlock */
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <time.h>
#include <pwd.h>
#include <limits.h>
#include <stdint.h>

/* ── Layout constants ─────────────────────────────────────────────────────── */
#define IV_SIZE          16
#define FEK_SIZE         32
#define ENC_FEK_SIZE     48   /* FEK (32 B) + AES-CBC PKCS7 padding → 48 B */
#define PLEN_PREFIX_SIZE 4    /* uint32_t plaintext length stored in header */
#define HEADER_SIZE      (PLEN_PREFIX_SIZE + IV_SIZE + ENC_FEK_SIZE)  /* 68 B */
#define KEY_SIZE         32
#define MAX_LINE_LEN     512

/* ── Default paths (override via environment variables) ───────────────────── */
#define DEFAULT_BACKING_DIR  "/workspace/store"
#define DEFAULT_KEY_FILE     "/workspace/keys/vault.key"
#define DEFAULT_LOG_FILE     "/workspace/logs/vault_audit.log"

/* ── Global state ─────────────────────────────────────────────────────────── */
static unsigned char master_key[KEY_SIZE];
static char g_backing_dir[PATH_MAX];
static char g_key_file[PATH_MAX];
static char g_log_file[PATH_MAX];

/* ── Path helpers ─────────────────────────────────────────────────────────── */

/* Map a virtual FUSE path to the encrypted backing-store path (.enc suffix). */
static void get_backing_path(char *backing, size_t sz, const char *virtpath)
{
    snprintf(backing, sz, "%s%s.enc", g_backing_dir, virtpath);
}

/* ── Master key management ────────────────────────────────────────────────── */

static int load_master_key(void)
{
    FILE *f = fopen(g_key_file, "rb");
    if (!f) {
        fprintf(stderr, "fusevault: cannot open key file %s: %s\n",
                g_key_file, strerror(errno));
        return -1;
    }
    size_t n = fread(master_key, 1, KEY_SIZE, f);
    fclose(f);
    if (n != KEY_SIZE) {
        fprintf(stderr, "fusevault: key file must be exactly %d bytes (got %zu)\n",
                KEY_SIZE, n);
        return -1;
    }
#ifndef DEBUG
    /* Lock master key in RAM so it never swaps to disk. */
    if (mlock(master_key, KEY_SIZE) != 0)
        fprintf(stderr, "fusevault: mlock() failed (non-fatal): %s\n", strerror(errno));
#endif
    return 0;
}

/* ── Hash-chained audit log ───────────────────────────────────────────────── */

/*
 * Compute SHA-256 of `data` (length `len`) and write 64-char lowercase hex
 * into `hexout` (must be at least 65 bytes).
 */
static void sha256_hex(const unsigned char *data, size_t len, char *hexout)
{
    unsigned char digest[32];
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    EVP_DigestInit_ex(ctx, EVP_sha256(), NULL);
    EVP_DigestUpdate(ctx, data, len);
    unsigned int dlen = 0;
    EVP_DigestFinal_ex(ctx, digest, &dlen);
    EVP_MD_CTX_free(ctx);
    for (int i = 0; i < 32; i++)
        snprintf(hexout + i * 2, 3, "%02x", digest[i]);
    hexout[64] = '\0';
}

/*
 * Append a tamper-evident entry to the audit log.
 * Format:
 *   [timestamp] [user] OP path PREV=<prev_hash> HASH=<this_hash>
 *
 * The HASH field covers everything up to and including "PREV=<prev_hash>".
 * This exact format must match the verification in vault.sh verify-log.
 */
static void log_access(const char *op, const char *path)
{
    /* Open (or create) the log file for append. */
    FILE *lf = fopen(g_log_file, "a+");
    if (!lf) return;

    /* Exclusive lock so concurrent FUSE threads cannot interleave entries. */
    flock(fileno(lf), LOCK_EX);

    /* ── Read previous line's HASH field ────────────────────────────────── */
    char prev_hash[65];
    strcpy(prev_hash, "GENESIS");

    /* Seek backward to find the last line. */
    fseek(lf, 0, SEEK_END);
    long fsize = ftell(lf);
    if (fsize > 0) {
        /* Read up to MAX_LINE_LEN bytes from the end to find the last line. */
        long readstart = fsize - MAX_LINE_LEN;
        if (readstart < 0) readstart = 0;
        fseek(lf, readstart, SEEK_SET);

        char buf[MAX_LINE_LEN + 1];
        size_t nr = fread(buf, 1, MAX_LINE_LEN, lf);
        buf[nr] = '\0';

        /* Find the last complete newline-terminated line. */
        char *last_nl = NULL;
        char *p = buf;
        while ((p = strchr(p, '\n')) != NULL) {
            last_nl = p;
            p++;
        }
        if (last_nl && last_nl != buf) {
            /* Walk back to the preceding newline (or buffer start). */
            char *line_start = last_nl - 1;
            while (line_start > buf && *(line_start - 1) != '\n')
                line_start--;
            /* Extract HASH= field from this last line. */
            char *hash_field = strstr(line_start, "HASH=");
            if (hash_field) {
                hash_field += 5; /* skip "HASH=" */
                snprintf(prev_hash, sizeof(prev_hash), "%.64s", hash_field);
                /* Strip trailing whitespace/newline. */
                for (int i = 0; i < 64; i++) {
                    if (prev_hash[i] == '\n' || prev_hash[i] == '\r' ||
                        prev_hash[i] == ' '  || prev_hash[i] == '\0') {
                        prev_hash[i] = '\0';
                        break;
                    }
                }
            }
        }
    }

    /* ── Build the content string (what we hash) ─────────────────────────── */
    time_t now = time(NULL);
    struct tm *tm_info = localtime(&now);
    char timestamp[32];
    strftime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S", tm_info);

    const char *username = "unknown";
    struct passwd *pw = getpwuid(getuid());
    if (pw) username = pw->pw_name;

    char content[MAX_LINE_LEN];
    snprintf(content, sizeof(content),
             "[%s] [%s] %s %s PREV=%s",
             timestamp, username, op, path, prev_hash);

    /* ── Compute hash of content ─────────────────────────────────────────── */
    char this_hash[65];
    sha256_hex((const unsigned char *)content, strlen(content), this_hash);

    /* ── Write the full log entry ─────────────────────────────────────────── */
    fseek(lf, 0, SEEK_END);
    fprintf(lf, "%s HASH=%s\n", content, this_hash);
    fflush(lf);

    flock(fileno(lf), LOCK_UN);
    fclose(lf);
}

/* ── AES-256-CBC encrypt/decrypt primitives ──────────────────────────────── */

/*
 * Encrypt `plaintext` using AES-256-CBC with `key` and `iv`.
 * Returns allocated ciphertext buffer (caller must free) and sets *out_len.
 * Returns NULL on failure.
 */
static unsigned char *aes_encrypt(const unsigned char *plaintext, int plen,
                                   const unsigned char *key,
                                   const unsigned char *iv,
                                   int *out_len)
{
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) return NULL;

    int buf_size = plen + EVP_MAX_BLOCK_LENGTH;
    unsigned char *out = malloc(buf_size);
    if (!out) { EVP_CIPHER_CTX_free(ctx); return NULL; }

    int len1 = 0, len2 = 0;
    if (EVP_EncryptInit_ex(ctx, EVP_aes_256_cbc(), NULL, key, iv) != 1 ||
        EVP_EncryptUpdate(ctx, out, &len1, plaintext, plen)        != 1 ||
        EVP_EncryptFinal_ex(ctx, out + len1, &len2)                != 1) {
        free(out);
        EVP_CIPHER_CTX_free(ctx);
        return NULL;
    }
    EVP_CIPHER_CTX_free(ctx);
    *out_len = len1 + len2;
    return out;
}

/*
 * Decrypt `ciphertext` using AES-256-CBC with `key` and `iv`.
 * Returns allocated plaintext buffer (caller must free) and sets *out_len.
 * Returns NULL on failure.
 */
static unsigned char *aes_decrypt(const unsigned char *ciphertext, int clen,
                                   const unsigned char *key,
                                   const unsigned char *iv,
                                   int *out_len)
{
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) return NULL;

    unsigned char *out = malloc(clen + EVP_MAX_BLOCK_LENGTH);
    if (!out) { EVP_CIPHER_CTX_free(ctx); return NULL; }

    int len1 = 0, len2 = 0;
    if (EVP_DecryptInit_ex(ctx, EVP_aes_256_cbc(), NULL, key, iv) != 1 ||
        EVP_DecryptUpdate(ctx, out, &len1, ciphertext, clen)       != 1 ||
        EVP_DecryptFinal_ex(ctx, out + len1, &len2)                != 1) {
        free(out);
        EVP_CIPHER_CTX_free(ctx);
        return NULL;
    }
    EVP_CIPHER_CTX_free(ctx);
    *out_len = len1 + len2;
    return out;
}

/* ── Full file read/write helpers ────────────────────────────────────────── */

/*
 * Read the complete encrypted backing file at `backing_path` and decrypt it.
 * On success, returns malloc'd plaintext buffer and sets *plaintext_len.
 * Returns NULL on failure (empty file is treated as zero-length plaintext).
 */
static unsigned char *read_decrypt_file(const char *backing_path, int *plaintext_len)
{
    FILE *f = fopen(backing_path, "rb");
    if (!f) return NULL;

    fseek(f, 0, SEEK_END);
    long fsize = ftell(f);
    fseek(f, 0, SEEK_SET);

    /* Empty or header-only file → treat as zero-length plaintext. */
    if (fsize <= (long)HEADER_SIZE) {
        fclose(f);
        *plaintext_len = 0;
        unsigned char *empty = malloc(1);
        if (empty) empty[0] = 0;
        return empty;
    }

    unsigned char *file_buf = malloc(fsize);
    if (!file_buf) { fclose(f); return NULL; }
    if (fread(file_buf, 1, fsize, f) != (size_t)fsize) {
        free(file_buf); fclose(f); return NULL;
    }
    fclose(f);

    /* Parse header: [plen(4)][IV(16)][enc_fek(48)] */
    uint32_t stored_plen;
    memcpy(&stored_plen, file_buf, PLEN_PREFIX_SIZE);
    const unsigned char *iv      = file_buf + PLEN_PREFIX_SIZE;
    const unsigned char *enc_fek = file_buf + PLEN_PREFIX_SIZE + IV_SIZE;
    const unsigned char *cipher  = file_buf + HEADER_SIZE;
    int cipher_len = (int)(fsize - HEADER_SIZE);

    /* Unwrap the FEK using the master key. */
    int fek_len = 0;
    unsigned char *fek = aes_decrypt(enc_fek, ENC_FEK_SIZE, master_key, iv, &fek_len);
    if (!fek || fek_len != FEK_SIZE) {
        free(file_buf);
        if (fek) { OPENSSL_cleanse(fek, fek_len); free(fek); }
        return NULL;
    }

    /* Decrypt the ciphertext with the FEK. */
    int raw_plen = 0;
    unsigned char *plaintext = aes_decrypt(cipher, cipher_len, fek, iv, &raw_plen);
    OPENSSL_cleanse(fek, fek_len);
    free(fek);
    free(file_buf);

    if (!plaintext) return NULL;

    /* Honour the stored plaintext length (handles truncation). */
    *plaintext_len = (int)stored_plen;
    if (*plaintext_len > raw_plen) *plaintext_len = raw_plen;
    return plaintext;
}

/*
 * Encrypt `plaintext` of `plaintext_len` bytes and write the full encrypted
 * file to `backing_path`.  Generates a fresh FEK and IV on every call.
 * Returns 0 on success, -1 on failure.
 */
static int encrypt_write_file(const char *backing_path,
                               const unsigned char *plaintext, int plaintext_len)
{
    /* Generate fresh random IV and FEK. */
    unsigned char iv[IV_SIZE];
    unsigned char fek[FEK_SIZE];
    if (RAND_bytes(iv, IV_SIZE) != 1 || RAND_bytes(fek, FEK_SIZE) != 1) {
        OPENSSL_cleanse(fek, FEK_SIZE);
        return -1;
    }

    /* Encrypt the plaintext with the FEK. */
    int clen = 0;
    unsigned char *cipher = aes_encrypt(plaintext, plaintext_len, fek, iv, &clen);
    if (!cipher) {
        OPENSSL_cleanse(fek, FEK_SIZE);
        return -1;
    }

    /* Wrap the FEK with the master key. */
    int enc_fek_len = 0;
    unsigned char *enc_fek = aes_encrypt(fek, FEK_SIZE, master_key, iv, &enc_fek_len);
    OPENSSL_cleanse(fek, FEK_SIZE);  /* done with FEK — cleanse immediately */
    if (!enc_fek || enc_fek_len != ENC_FEK_SIZE) {
        free(cipher);
        if (enc_fek) free(enc_fek);
        return -1;
    }

    /* Write: [plen(4)][IV(16)][enc_fek(48)][ciphertext] */
    FILE *f = fopen(backing_path, "wb");
    if (!f) {
        free(cipher); free(enc_fek);
        return -1;
    }
    uint32_t plen_u32 = (uint32_t)plaintext_len;
    fwrite(&plen_u32, 1, PLEN_PREFIX_SIZE, f);
    fwrite(iv,      1, IV_SIZE,       f);
    fwrite(enc_fek, 1, enc_fek_len,   f);
    fwrite(cipher,  1, clen,          f);
    fclose(f);

    OPENSSL_cleanse(enc_fek, enc_fek_len);
    free(enc_fek);
    free(cipher);
    return 0;
}

/* ── FUSE callbacks ──────────────────────────────────────────────────────── */

static int myfs_getattr(const char *path, struct stat *stbuf)
{
    memset(stbuf, 0, sizeof(*stbuf));

    if (strcmp(path, "/") == 0) {
        stbuf->st_mode  = S_IFDIR | 0755;
        stbuf->st_nlink = 2;
        return 0;
    }

    char backing[PATH_MAX];
    get_backing_path(backing, sizeof(backing), path);

    struct stat backing_stat;
    if (lstat(backing, &backing_stat) != 0) {
        /* Also check if it is a directory in the backing store. */
        char dir_backing[PATH_MAX];
        snprintf(dir_backing, sizeof(dir_backing), "%s%s", g_backing_dir, path);
        if (lstat(dir_backing, &backing_stat) != 0)
            return -ENOENT;
        *stbuf = backing_stat;
        return 0;
    }

    *stbuf = backing_stat;
    stbuf->st_mode = S_IFREG | 0644;

    /* Report the plaintext size from the header, not the encrypted file size. */
    if (backing_stat.st_size > (off_t)HEADER_SIZE) {
        FILE *f = fopen(backing, "rb");
        if (f) {
            uint32_t plen = 0;
            if (fread(&plen, 1, PLEN_PREFIX_SIZE, f) == PLEN_PREFIX_SIZE)
                stbuf->st_size = (off_t)plen;
            fclose(f);
        }
    } else {
        stbuf->st_size = 0;
    }

    return 0;
}

static int myfs_readdir(const char *path, void *buf, fuse_fill_dir_t filler,
                        off_t offset, struct fuse_file_info *fi)
{
    (void)offset; (void)fi;

    char dir_backing[PATH_MAX];
    if (strcmp(path, "/") == 0)
        snprintf(dir_backing, sizeof(dir_backing), "%s", g_backing_dir);
    else
        snprintf(dir_backing, sizeof(dir_backing), "%s%s", g_backing_dir, path);

    DIR *dp = opendir(dir_backing);
    if (!dp) return -ENOENT;

    filler(buf, ".",  NULL, 0);
    filler(buf, "..", NULL, 0);

    struct dirent *de;
    while ((de = readdir(dp)) != NULL) {
        if (de->d_name[0] == '.') continue;

        char visible_name[NAME_MAX + 1];
        strncpy(visible_name, de->d_name, NAME_MAX);
        visible_name[NAME_MAX] = '\0';

        /* Strip the .enc suffix so users see plain filenames. */
        size_t nlen = strlen(visible_name);
        if (nlen > 4 && strcmp(visible_name + nlen - 4, ".enc") == 0)
            visible_name[nlen - 4] = '\0';

        filler(buf, visible_name, NULL, 0);
    }
    closedir(dp);
    return 0;
}

static int myfs_open(const char *path, struct fuse_file_info *fi)
{
    (void)fi;
    char backing[PATH_MAX];
    get_backing_path(backing, sizeof(backing), path);
    if (access(backing, F_OK) != 0) return -ENOENT;
    log_access("OPEN", path);
    return 0;
}

static int myfs_create(const char *path, mode_t mode, struct fuse_file_info *fi)
{
    (void)mode; (void)fi;
    char backing[PATH_MAX];
    get_backing_path(backing, sizeof(backing), path);

    /* Create an empty encrypted file (zero-length plaintext). */
    if (encrypt_write_file(backing, NULL, 0) != 0)
        return -EIO;

    log_access("CREATE", path);
    return 0;
}

static int myfs_read(const char *path, char *buf, size_t size,
                     off_t offset, struct fuse_file_info *fi)
{
    (void)fi;
    char backing[PATH_MAX];
    get_backing_path(backing, sizeof(backing), path);

    int plen = 0;
    unsigned char *plaintext = read_decrypt_file(backing, &plen);
    if (!plaintext) return -EIO;

    int bytes_read = 0;
    if (offset < plen) {
        bytes_read = (int)(plen - offset);
        if ((size_t)bytes_read > size) bytes_read = (int)size;
        memcpy(buf, plaintext + offset, bytes_read);
    }

    OPENSSL_cleanse(plaintext, plen);
    free(plaintext);

    log_access("READ", path);
    return bytes_read;
}

static int myfs_write(const char *path, const char *buf, size_t size,
                      off_t offset, struct fuse_file_info *fi)
{
    (void)fi;
    char backing[PATH_MAX];
    get_backing_path(backing, sizeof(backing), path);

    /* Read existing plaintext (if any). */
    int existing_plen = 0;
    unsigned char *existing = read_decrypt_file(backing, &existing_plen);
    /* If the file doesn't exist yet, treat as empty. */
    if (!existing) {
        existing_plen = 0;
        existing = malloc(1);
        if (!existing) return -ENOMEM;
    }

    /* Determine new total plaintext length. */
    int new_plen = existing_plen;
    if ((int)(offset + size) > new_plen)
        new_plen = (int)(offset + size);

    unsigned char *new_plain = calloc(new_plen, 1);
    if (!new_plain) {
        OPENSSL_cleanse(existing, existing_plen);
        free(existing);
        return -ENOMEM;
    }

    /* Copy existing data, then overlay the new write. */
    if (existing_plen > 0)
        memcpy(new_plain, existing, existing_plen);
    memcpy(new_plain + offset, buf, size);

    OPENSSL_cleanse(existing, existing_plen);
    free(existing);

    /* Re-encrypt and write the full plaintext. */
    int ret = encrypt_write_file(backing, new_plain, new_plen);
    OPENSSL_cleanse(new_plain, new_plen);
    free(new_plain);

    if (ret != 0) return -EIO;

    log_access("WRITE", path);
    /* Always return the number of plaintext bytes written (not ciphertext). */
    return (int)size;
}

static int myfs_truncate(const char *path, off_t newsize)
{
    char backing[PATH_MAX];
    get_backing_path(backing, sizeof(backing), path);

    int plen = 0;
    unsigned char *plaintext = read_decrypt_file(backing, &plen);
    if (!plaintext) {
        /* File doesn't exist; create empty if truncating to 0. */
        if (newsize == 0) return encrypt_write_file(backing, NULL, 0);
        return -ENOENT;
    }

    unsigned char *new_plain;
    int new_plen = (int)newsize;
    if (new_plen == 0) {
        new_plain = malloc(1);
        if (!new_plain) { free(plaintext); return -ENOMEM; }
    } else {
        new_plain = calloc(new_plen, 1);
        if (!new_plain) {
            OPENSSL_cleanse(plaintext, plen);
            free(plaintext);
            return -ENOMEM;
        }
        int copy_len = plen < new_plen ? plen : new_plen;
        memcpy(new_plain, plaintext, copy_len);
    }

    OPENSSL_cleanse(plaintext, plen);
    free(plaintext);

    int ret = encrypt_write_file(backing, new_plain, new_plen);
    OPENSSL_cleanse(new_plain, new_plen > 0 ? new_plen : 1);
    free(new_plain);

    if (ret != 0) return -EIO;
    log_access("TRUNCATE", path);
    return 0;
}

static int myfs_unlink(const char *path)
{
    char backing[PATH_MAX];
    get_backing_path(backing, sizeof(backing), path);
    if (unlink(backing) != 0) return -errno;
    log_access("UNLINK", path);
    return 0;
}

static int myfs_mkdir(const char *path, mode_t mode)
{
    char dir_backing[PATH_MAX];
    snprintf(dir_backing, sizeof(dir_backing), "%s%s", g_backing_dir, path);
    if (mkdir(dir_backing, mode) != 0) return -errno;
    log_access("MKDIR", path);
    return 0;
}

static int myfs_rmdir(const char *path)
{
    char dir_backing[PATH_MAX];
    snprintf(dir_backing, sizeof(dir_backing), "%s%s", g_backing_dir, path);
    if (rmdir(dir_backing) != 0) return -errno;
    log_access("RMDIR", path);
    return 0;
}

static void myfs_destroy(void *private_data)
{
    (void)private_data;
    log_access("UNMOUNT", g_backing_dir);

    /* Secure memory erasure: guaranteed not to be optimized away. */
    OPENSSL_cleanse(master_key, KEY_SIZE);
#ifndef DEBUG
    munlock(master_key, KEY_SIZE);
#endif
}

/* ── FUSE operations table ───────────────────────────────────────────────── */

static struct fuse_operations myfs_oper = {
    .getattr  = myfs_getattr,
    .readdir  = myfs_readdir,
    .open     = myfs_open,
    .create   = myfs_create,
    .read     = myfs_read,
    .write    = myfs_write,
    .truncate = myfs_truncate,
    .unlink   = myfs_unlink,
    .mkdir    = myfs_mkdir,
    .rmdir    = myfs_rmdir,
    .destroy  = myfs_destroy,
};

/* ── Entry point ─────────────────────────────────────────────────────────── */

int main(int argc, char *argv[])
{
    /* Resolve paths from environment variables with compiled-in defaults. */
    const char *env_backing = getenv("VAULT_BACKING_DIR");
    const char *env_key     = getenv("VAULT_KEY_FILE");
    const char *env_log     = getenv("VAULT_LOG_FILE");

    strncpy(g_backing_dir, env_backing ? env_backing : DEFAULT_BACKING_DIR, PATH_MAX - 1);
    strncpy(g_key_file,    env_key     ? env_key     : DEFAULT_KEY_FILE,    PATH_MAX - 1);
    strncpy(g_log_file,    env_log     ? env_log     : DEFAULT_LOG_FILE,    PATH_MAX - 1);

    /* Ensure backing store and log directories exist. */
    struct stat st;
    if (stat(g_backing_dir, &st) != 0)
        mkdir(g_backing_dir, 0700);

    char log_dir[PATH_MAX];
    strncpy(log_dir, g_log_file, PATH_MAX - 1);
    char *slash = strrchr(log_dir, '/');
    if (slash) {
        *slash = '\0';
        if (stat(log_dir, &st) != 0)
            mkdir(log_dir, 0700);
    }

    /* Load the master key before entering the FUSE event loop. */
    if (load_master_key() != 0)
        return 1;

    log_access("MOUNT", g_backing_dir);
    return fuse_main(argc, argv, &myfs_oper, NULL);
}
