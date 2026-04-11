# FuseVault

> Custom Encrypted FUSE Filesystem — C + OpenSSL AES-256 + Shell Vault Manager

FuseVault is a mountable virtual filesystem that transparently encrypts every file you write and decrypts every file you read. Any application that opens a file from `~/vault/` sees plain text — the encryption is invisible at the OS level, handled entirely in userspace via FUSE.

---

## Architecture

```
User Application (cat, cp, vim, …)
        │
        ▼
  VFS (Linux Kernel)
        │
        ▼
  FUSE Kernel Module
        │
        ▼
  myfs (your process)       ← intercepts every read / write / open / readdir
        │              │
        ▼              ▼
   Decrypt           Encrypt
  (read path)       (write path)
        │              │
        └──────┬────────┘
               ▼
       store/             ← AES-256-CBC encrypted .enc files
               +
       logs/vault_audit.log  ← hash-chained tamper-evident access trail
```

### Data Flow

| Operation | What happens |
|-----------|-------------|
| `cp file.txt mount/` | plaintext → AES-256-CBC encrypt (fresh FEK + IV) → `.enc` stored |
| `cat mount/file.txt` | `.enc` read → decrypt FEK → decrypt ciphertext → plaintext returned |
| Any access | timestamp + user + op + path → SHA-256 hash-chained audit log entry |

---

## Prerequisites

| Package | Purpose | Install |
|---------|---------|---------|
| `libfuse-dev` | FUSE headers | `apt install libfuse-dev` |
| `fuse` | `fusermount` binary | `apt install fuse` |
| `openssl` + `libssl-dev` | AES-256, SHA-256 | `apt install openssl libssl-dev` |
| `gcc`, `build-essential` | C compiler | `apt install build-essential` |
| `pkg-config` | FUSE CFLAGS/LDFLAGS | `apt install pkg-config` |
| `argon2` | Passphrase key derivation | `apt install argon2` |
| `inotify-tools` | Idle-timeout watchdog | `apt install inotify-tools` |
| `xxd` | Hex-to-binary for Argon2 output | included in `build-essential` |

---

## Docker Quick-Start (Recommended)

```bash
# 1. Build the image
docker build -t fusevault .

# 2. Run with FUSE privileges
docker run -it \
  --privileged \
  --cap-add SYS_ADMIN \
  --device /dev/fuse \
  --name fusevault \
  -v "$(pwd):/workspace" \
  fusevault bash

# 3. Inside the container — build and start
make
./scripts/vault.sh keygen
./scripts/vault.sh mount
```

---

## First-Time Setup

```bash
# Compile the FUSE binary
make

# Generate a random 256-bit key
./scripts/vault.sh keygen

# OR derive a key from a passphrase (Argon2id, memory-hard)
./scripts/vault.sh keygen --passphrase

# Mount the vault
./scripts/vault.sh mount

# Verify it is up
./scripts/vault.sh status
```

---

## Using the Vault

```bash
# Write a file (encrypted transparently on write)
cp ~/secret.pdf mount/
echo "TOP SECRET" > mount/notes.txt

# Read a file (decrypted transparently on read)
cat mount/notes.txt
libreoffice mount/report.docx

# List files (shows plain names, not .enc names)
ls mount/

# Unmount safely
./scripts/vault.sh unmount
```

---

## All Vault Commands

```bash
./scripts/vault.sh mount                 # Mount the vault
./scripts/vault.sh mount --idle-timeout 10   # Auto-unmount after 10 min idle
./scripts/vault.sh unmount               # Unmount safely
./scripts/vault.sh status                # Show mount state, key, log, watchdog
./scripts/vault.sh keygen                # Generate new random 256-bit key
./scripts/vault.sh keygen --passphrase   # Derive key via Argon2id passphrase
./scripts/vault.sh passphrase            # Change passphrase
./scripts/vault.sh rotate                # Re-encrypt all files with a new key
./scripts/vault.sh wipe                  # Securely shred key (requires typing CONFIRM)
./scripts/vault.sh encrypt <file>        # Manually encrypt a file
./scripts/vault.sh decrypt <file.enc>    # Manually decrypt a file
./scripts/vault.sh log                   # View full audit log
./scripts/vault.sh log --tail 20         # View last 20 log entries
./scripts/vault.sh verify-log            # Verify hash-chain integrity
```

---

## Makefile Targets

```bash
make          # Build myfs binary
make debug    # Build with -g -DDEBUG and AddressSanitizer
make clean    # Remove build artifacts
make install  # Install myfs and vault to /usr/local/bin
make uninstall
make test     # Automated mount/write/read/unmount self-test
make lint     # Run cppcheck on src/myfs.c
make format   # Run clang-format on src/myfs.c
make help     # Print all targets
```

---

## Security Model

### 1. AES-256-CBC with Random IV per File

Every write generates a cryptographically random 16-byte IV via `RAND_bytes()`. Identical plaintexts produce different ciphertexts, preventing frequency analysis.

### 2. Per-File Envelope Encryption

```
┌──────────────────┬──────────────┬───────────────────────┬──────────────┐
│ PLAINTEXT_SIZE   │  IV (16 B)   │  Encrypted FEK (48 B) │  Ciphertext  │
│    (4 B)         │              │  master-key wrapped    │              │
└──────────────────┴──────────────┴───────────────────────┴──────────────┘
←────────────────────── HEADER_SIZE = 68 bytes ────────────────────────────→
```

- Each file gets its own random **File Encryption Key (FEK)**
- File content is encrypted with the FEK using AES-256-CBC
- The FEK is encrypted with the master key (AES-256-CBC key wrapping)
- Compromising one file's FEK does not compromise any other file
- This is the same model used by **AWS KMS** and **Google Cloud KMS**

### 3. Argon2id Key Derivation

When using `vault keygen --passphrase`, the master key is derived using Argon2id (winner of the Password Hashing Competition 2015):

```
Argon2id parameters:
  -t 3   : 3 time iterations
  -m 16  : 2^16 = 64 MB of RAM required per attempt
  -p 4   : 4 parallel threads
  -l 32  : 32-byte (256-bit) output
```

Argon2id beats PBKDF2 because it is **memory-hard**: an attacker with a GPU farm still needs gigabytes of RAM per password guess. PBKDF2 is compute-only and can be parallelized cheaply on GPUs. Argon2id makes brute-force economically infeasible.

### 4. Hash-Chained Tamper-Evident Audit Log

Each log entry includes:
```
[2025-03-24 10:15:41] [alice] WRITE /notes.txt PREV=a3f9...b2 HASH=b812...c4
```

The `HASH` field is `SHA-256("[timestamp] [user] OP path PREV=<prev_hash>")`. The `PREV` field chains entries together. Any modification to any entry breaks the chain — detectable with `vault verify-log`.

### 5. Secure Memory Erasure

- `OPENSSL_cleanse()` is used (not `memset`) to zero key material and plaintext buffers after use. Compilers cannot optimize away `OPENSSL_cleanse` as a dead store.
- `mlock()` pins the master key buffer in RAM so it is never paged to the swap device.
- The FUSE `destroy()` callback (called on unmount) cleanses and unlocks the master key.

---

## Verifying Encryption Works

```bash
# Mount, write a file, unmount
./scripts/vault.sh mount
echo "TOP SECRET" > mount/test.txt
./scripts/vault.sh unmount

# Inspect the raw backing store — should be binary garbage
xxd store/test.txt.enc | head

# Re-mount and verify you can read plaintext
./scripts/vault.sh mount
cat mount/test.txt   # → TOP SECRET
./scripts/vault.sh unmount
```

---

## Audit Log Example

```
[2025-03-24 10:15:33] [alice] MOUNT /workspace/store PREV=GENESIS HASH=a3f9...
[2025-03-24 10:15:41] [alice] WRITE /notes.txt PREV=a3f9... HASH=b812...
[2025-03-24 10:16:02] [alice] READ /notes.txt PREV=b812... HASH=c490...
[2025-03-24 10:20:15] [alice] UNMOUNT /workspace/store PREV=c490... HASH=d107...
```

Verify integrity:
```bash
./scripts/vault.sh verify-log
# Line 1: OK    [2025-03-24 10:15:33] MOUNT
# Line 2: OK    [2025-03-24 10:15:41] WRITE
# Summary: 4 OK | 0 TAMPERED
```

---

## Potential Enhancements

- **ChaCha20-Poly1305** — authenticated encryption; detects ciphertext tampering
- **FUSE 3 API** — updated `getattr` signature and improved performance
- **Key escrow** — encrypted key backup for disaster recovery
- **Multi-user ACL** — per-user FEK wrapping with individual master keys
- **Integrity tags** — HMAC per file to detect in-place ciphertext modification
- **macOS support** — macFUSE (`osxfuse`) port

---

## References

- [FUSE Documentation](https://libfuse.github.io/doxygen/)
- [OpenSSL EVP API](https://www.openssl.org/docs/man3.0/man3/EVP_EncryptInit.html)
- [Argon2 Paper & Reference Implementation](https://github.com/P-H-C/phc-winner-argon2)
- [FUSE GitHub](https://github.com/libfuse/libfuse)
- [AWS KMS Envelope Encryption](https://docs.aws.amazon.com/kms/latest/developerguide/concepts.html#enveloping)

---

*FuseVault — Built with Claude Code*
