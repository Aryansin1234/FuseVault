# FuseVault — Technical Documentation

> **Custom Encrypted FUSE Filesystem**  
> C · OpenSSL AES-256 · Argon2id · Shell Vault Manager

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [File Format on Disk](#3-file-format-on-disk)
4. [Security Model](#4-security-model)
5. [Project Structure](#5-project-structure)
6. [Prerequisites](#6-prerequisites)
7. [Quick Start with Docker](#7-quick-start-with-docker)
8. [Building from Source](#8-building-from-source)
9. [Vault Commands Reference](#9-vault-commands-reference)
10. [Makefile Targets](#10-makefile-targets)
11. [Environment Variables](#11-environment-variables)
12. [FUSE Callbacks (C Core)](#12-fuse-callbacks-c-core)
13. [Audit Log](#13-audit-log)
14. [Key Management](#14-key-management)
15. [Troubleshooting](#15-troubleshooting)
16. [Concepts Glossary](#16-concepts-glossary)

---

## 1. Overview

FuseVault is a **mountable virtual filesystem** that transparently encrypts every file you write and decrypts every file you read. Any application that opens a file from `mount/` sees plain text — the encryption is completely invisible at the OS level.

### How it works in one sentence

When you copy a file into `mount/`, the C program `myfs` intercepts the write, encrypts the data with AES-256-CBC, and saves a `.enc` binary blob to `store/`. When you read it back, `myfs` decrypts on the fly — the app sees plain text, the disk holds only ciphertext.

### What makes it notable

| Concept | Real-world equivalent |
|---|---|
| FUSE transparent encryption | macOS FileVault, VeraCrypt |
| Per-file envelope encryption | AWS KMS, Google Cloud KMS |
| Argon2id key derivation | 1Password, Bitwarden |
| Hash-chained audit log | Blockchain, HashiCorp Vault |
| `mlock()` + `OPENSSL_cleanse()` | Hardware Security Modules (HSMs) |

---

## 2. Architecture

### System diagram

```
 User Application  (cat, cp, vim, any app…)
         │
         ▼
   VFS — Linux Virtual Filesystem Switch
         │
         ▼
   FUSE Kernel Module
         │
         ▼
   myfs  (src/myfs.c)          ← your C process, running in userspace
    │              │
    ▼              ▼
 Decrypt        Encrypt
 (read path)    (write path)
    │              │
    └──────┬────────┘
           ▼
      store/*.enc              ← AES-256-CBC encrypted binary blobs
           +
      logs/vault_audit.log     ← SHA-256 hash-chained tamper-evident log
```

### Data flow

| Operation | What happens end-to-end |
|---|---|
| `cp secret.pdf mount/` | plaintext → fresh random IV + FEK → AES-256-CBC encrypt FEK with master key → AES-256-CBC encrypt file with FEK → write `.enc` header + ciphertext to `store/` |
| `cat mount/notes.txt` | read `.enc` file → parse header → decrypt FEK using master key → decrypt ciphertext using FEK → return plaintext to caller |
| `ls mount/` | list `store/`, strip `.enc` suffix, return plain filenames |
| Any access | timestamp + user + operation + path → SHA-256 hash-chained entry appended to audit log |

---

## 3. File Format on Disk

Every `.enc` file in `store/` has the following binary layout:

```
 Offset   Size    Field
 ──────   ──────  ──────────────────────────────────────────────────
 0        4 B     Plaintext length (uint32_t, little-endian)
 4        16 B    IV — random, fresh per write (AES block size)
 20       48 B    Encrypted FEK — the per-file key wrapped with master key
 68       N B     Ciphertext — file content encrypted with FEK + IV
```

```
┌──────────────────┬──────────────┬───────────────────────┬──────────────┐
│  PLAINTEXT_SIZE  │   IV (16 B)  │  Encrypted FEK (48 B) │  Ciphertext  │
│      (4 B)       │              │  AES-CBC key-wrapped   │              │
└──────────────────┴──────────────┴───────────────────────┴──────────────┘
←─────────────────────── HEADER_SIZE = 68 bytes ──────────────────────────→
```

### Why store the plaintext size?

AES-CBC with PKCS7 padding rounds ciphertext up to a multiple of 16 bytes. Without storing the original size, there is no way to know exactly how many bytes of plaintext were intended — the padding bytes are indistinguishable from data at the ciphertext level.

### Why 48 bytes for the encrypted FEK?

The FEK is 32 bytes. AES-CBC with PKCS7 padding on a 32-byte input produces exactly 48 bytes (32 + one full 16-byte padding block).

---

## 4. Security Model

### 4.1 AES-256-CBC with a random IV per write

Every call to `myfs_write()` generates a new 16-byte IV via OpenSSL's `RAND_bytes()`. This means:

- Encrypting the same file twice produces completely different ciphertext.
- Frequency analysis and known-plaintext attacks based on ciphertext patterns are defeated.

### 4.2 Per-file envelope encryption (FEK)

```
Master Key  (32 bytes, stored in keys/vault.key)
     │
     └── wraps ──► Encrypted FEK  (48 bytes, stored in file header)
                        │
                        └── decrypts ──► FEK  (32 bytes, ephemeral in RAM)
                                              │
                                              └── decrypts ──► Plaintext
```

- Each file gets its own random **File Encryption Key (FEK)**.
- The FEK is encrypted with the master key and stored in the file header.
- **Compromise of one file's FEK has zero impact on any other file.**
- This is identical to the model used by **AWS KMS** and **Google Cloud KMS**.

### 4.3 Argon2id key derivation

When generating a key from a passphrase (`vault.sh keygen --passphrase`), the master key is derived using **Argon2id** with these parameters:

| Parameter | Value | Meaning |
|---|---|---|
| `-t` | `3` | 3 time iterations |
| `-m` | `16` | 2¹⁶ = **64 MB RAM** required per attempt |
| `-p` | `4` | 4 parallel threads |
| `-l` | `32` | 32-byte (256-bit) output |

**Why Argon2id over PBKDF2?**  
PBKDF2 is compute-only — an attacker with a GPU farm can test billions of passwords per second. Argon2id is **memory-hard**: each attempt requires 64 MB of RAM, so an attacker with 1 TB of GPU memory can only test ~16,000 passwords simultaneously. It won the 2015 Password Hashing Competition.

### 4.4 Hash-chained tamper-evident audit log

Each log entry is structured as:

```
[2026-03-30 10:15:41] [alice] WRITE /notes.txt PREV=a3f9...b2 HASH=b812...c4
```

The `HASH` field is computed as:

```
SHA-256( "[timestamp] [user] OP path PREV=<prev_hash>" )
```

The `PREV` field contains the hash of the immediately preceding entry. The first entry uses `PREV=GENESIS`.

- **Modifying any entry** — its stored `HASH` will no longer match the recomputed hash.
- **Deleting any entry** — the `PREV` field of the next entry will mismatch.
- **Inserting a fake entry** — breaks the chain because you cannot forge a hash that matches both content and the next entry's `PREV`.

Verify integrity at any time: `./scripts/vault.sh verify-log`

### 4.5 Secure memory erasure

```c
// WRONG — a compiler optimising a dead store can silently remove this
memset(key_buffer, 0, KEY_SIZE);

// CORRECT — OpenSSL guarantees this is never eliminated by the compiler
OPENSSL_cleanse(key_buffer, KEY_SIZE);
```

- `OPENSSL_cleanse()` is used on all key material and plaintext buffers immediately after use.
- `mlock()` pins the master key buffer in physical RAM so the OS never pages it to swap/disk.
- The FUSE `destroy()` callback (called on unmount) cleanses and unlocks the master key.

---

## 5. Project Structure

```
FuseVault/
├── src/
│   └── myfs.c                 ← FUSE filesystem (C) — the encryption engine
├── scripts/
│   ├── vault.sh               ← Vault lifecycle manager (Bash)
│   └── fusevault_ui.sh        ← Interactive UI wrapper
├── store/                     ← Encrypted .enc backing files (gitignored)
│   └── intel/
│       └── agents.txt.enc
├── mount/                     ← FUSE mount point — the "magic folder"
├── keys/                      ← Master key file (gitignored, chmod 600)
├── logs/                      ← Audit log (vault_audit.log)
├── Makefile                   ← Build system
├── Dockerfile                 ← Docker image for running on macOS
├── run.sh                     ← Convenience launch script
├── README.md                  ← Project readme
├── TESTING.md                 ← Test procedures
└── DOCS.md                    ← This file
```

---

## 6. Prerequisites

FuseVault requires Linux (or Docker). FUSE is a Linux kernel feature.

| Package | Purpose | Install (Ubuntu/Debian) |
|---|---|---|
| `libfuse-dev` | FUSE headers for compilation | `apt install libfuse-dev` |
| `fuse` | `fusermount` binary | `apt install fuse` |
| `openssl` | AES-256, SHA-256 CLI tools | `apt install openssl` |
| `libssl-dev` | OpenSSL headers for compilation | `apt install libssl-dev` |
| `gcc` / `build-essential` | C compiler | `apt install build-essential` |
| `pkg-config` | Resolves FUSE CFLAGS/LDFLAGS | `apt install pkg-config` |
| `argon2` | Passphrase key derivation binary | `apt install argon2` |
| `inotify-tools` | Idle-timeout watchdog | `apt install inotify-tools` |
| `xxd` | Hex inspection of `.enc` files | included with `build-essential` |

Install all at once:

```bash
sudo apt update && sudo apt install -y \
  libfuse-dev fuse openssl libssl-dev \
  build-essential pkg-config argon2 \
  inotify-tools cppcheck clang-format
```

---

## 7. Quick Start with Docker

Docker is the recommended way to run FuseVault on macOS, since FUSE requires Linux.

```bash
# 1. Build the Docker image
docker build -t fusevault .

# 2. Run with FUSE privileges (required for /dev/fuse access)
docker run -it \
  --privileged \
  --cap-add SYS_ADMIN \
  --device /dev/fuse \
  --name fusevault \
  -v "$(pwd):/workspace" \
  fusevault bash

# 3. Inside the container — compile, generate a key, and mount
make
./scripts/vault.sh keygen
./scripts/vault.sh mount

# 4. Use the vault
echo "TOP SECRET" > mount/notes.txt
cat mount/notes.txt       # → TOP SECRET

# 5. Verify encryption
./scripts/vault.sh unmount
xxd store/notes.txt.enc | head   # → binary garbage

# 6. Re-mount and confirm plaintext is recoverable
./scripts/vault.sh mount
cat mount/notes.txt       # → TOP SECRET
./scripts/vault.sh unmount
```

---

## 8. Building from Source

```bash
# Default build
make

# Debug build — adds -g, -DDEBUG, and AddressSanitizer
make debug

# Remove build artifacts
make clean

# Install myfs and vault.sh system-wide
sudo make install       # copies to /usr/local/bin/myfs and /usr/local/bin/vault

# Run the automated self-test (mount → write → read → verify → unmount)
make test
```

The compiler command produced by `make` is:

```bash
gcc -Wall -Wextra -Wpedantic $(pkg-config fuse --cflags) \
    src/myfs.c \
    $(pkg-config fuse --libs) -lssl -lcrypto \
    -o myfs
```

---

## 9. Vault Commands Reference

All commands are run as `./scripts/vault.sh <command> [options]`.

### Vault lifecycle

| Command | Description |
|---|---|
| `mount` | Launch the FUSE process and attach it to `mount/`. Loads the master key into RAM (`mlock`'d). |
| `mount --idle-timeout N` | Same as `mount`, but starts a background watchdog that auto-unmounts after `N` minutes of inactivity. |
| `unmount` | Detach the FUSE process. Triggers `OPENSSL_cleanse` on the master key and `munlock`. |
| `status` | Show a dashboard: mount state, FUSE PID, key fingerprint, encrypted file count, log entry count, watchdog state. |

### Key management

| Command | Description |
|---|---|
| `keygen` | Generate a fresh 32-byte random master key using `openssl rand` (reads from `/dev/urandom`). |
| `keygen --passphrase` | Derive a 32-byte master key from a passphrase using Argon2id (t=3, m=2¹⁶, p=4). |
| `passphrase` | Re-derive the master key from a new passphrase. Backs up the old key. You must run `rotate` afterwards. |
| `rotate` | Mount with the current key, copy all plaintext to a temp dir, generate a new key, re-mount, re-encrypt everything, shred the old key. |
| `wipe` | Securely shred the master key file using `shred -u`. Requires typing `CONFIRM`. **All encrypted data becomes permanently unreadable.** |

### File operations (standalone, outside FUSE)

| Command | Description |
|---|---|
| `encrypt <file>` | Encrypt a single file using `openssl enc -aes-256-cbc -pbkdf2`. Outputs `<file>.enc`. |
| `decrypt <file.enc>` | Decrypt a file encrypted with the `encrypt` command. |

> **Note:** The standalone `encrypt`/`decrypt` commands use a different format (OpenSSL's PBKDF2 envelope) from the FUSE backing store format (C code with raw binary header). Do not mix them.

### Audit

| Command | Description |
|---|---|
| `log` | Print the full audit log to stdout. |
| `log --tail N` | Print the last `N` log entries. |
| `verify-log` | Re-compute every SHA-256 hash in the log and verify the chain. Prints `OK` or `TAMPERED` per line plus a final summary. |

### Other

| Command | Description |
|---|---|
| `about` | Print version, tech stack, and architecture summary. |
| `help` | Print command reference and quick-start example. |

---

## 10. Makefile Targets

| Target | What it does |
|---|---|
| `make` | Build the `myfs` binary (default) |
| `make debug` | Build with `-g -DDEBUG` and AddressSanitizer (`-fsanitize=address,undefined`) |
| `make clean` | Delete `myfs` and any `.o` files |
| `make install` | Copy `myfs` → `/usr/local/bin/myfs` and `vault.sh` → `/usr/local/bin/vault` |
| `make uninstall` | Remove the installed files |
| `make test` | Run the automated self-test: keygen → mount → write → read → verify → unmount |
| `make lint` | Run `cppcheck` on `src/myfs.c` |
| `make format` | Run `clang-format -style=GNU` on `src/myfs.c` |
| `make help` | Print this target list |

---

## 11. Environment Variables

`myfs` and `vault.sh` both read these environment variables to locate paths. If not set, the compiled-in defaults are used.

| Variable | Default | Description |
|---|---|---|
| `VAULT_BACKING_DIR` | `<project>/store` | Directory where `.enc` files are stored |
| `VAULT_KEY_FILE` | `<project>/keys/vault.key` | Path to the 32-byte master key file |
| `VAULT_LOG_FILE` | `<project>/logs/vault_audit.log` | Path to the audit log |
| `VAULT_MOUNT_POINT` | `<project>/mount` | Directory `myfs` is mounted on (shell only) |

Example — override all paths:

```bash
export VAULT_BACKING_DIR=/data/encrypted
export VAULT_KEY_FILE=/etc/vault/master.key
export VAULT_LOG_FILE=/var/log/vault_audit.log
./scripts/vault.sh mount
```

---

## 12. FUSE Callbacks (C Core)

These are the functions in `src/myfs.c` that the FUSE kernel module calls. Each one maps a virtual filesystem operation to an action on the encrypted backing store.

| Callback | Triggered by | What it does |
|---|---|---|
| `myfs_getattr` | `stat`, `ls` | Reads the `.enc` header to report the **plaintext** file size instead of the ciphertext file size. |
| `myfs_readdir` | `ls`, `opendir` | Lists `store/`, strips `.enc` suffix from filenames so users see plain names. |
| `myfs_open` | `open()` syscall | Checks that the backing `.enc` file exists. Logs `OPEN` to audit log. |
| `myfs_create` | `touch`, `>` redirection | Creates an empty `.enc` file (zero-length encrypted plaintext). Logs `CREATE`. |
| `myfs_read` | `cat`, `read()` syscall | Calls `read_decrypt_file()` → parses header → unwraps FEK → decrypts ciphertext → returns plaintext to caller. Cleanses plaintext buffer after copy. Logs `READ`. |
| `myfs_write` | `cp`, `write()` syscall | Reads existing plaintext (if any), overlays the new write at `offset`, calls `encrypt_write_file()` with fresh IV + FEK. Cleanses buffers. Logs `WRITE`. |
| `myfs_truncate` | `truncate()`, text editors | Decrypts, resizes the plaintext buffer, re-encrypts. Logs `TRUNCATE`. |
| `myfs_unlink` | `rm` | Deletes the `.enc` file from `store/`. Logs `UNLINK`. |
| `myfs_mkdir` | `mkdir` | Creates a subdirectory in `store/`. Logs `MKDIR`. |
| `myfs_rmdir` | `rmdir` | Removes a subdirectory from `store/`. Logs `RMDIR`. |
| `myfs_destroy` | Unmount | Calls `OPENSSL_cleanse` on the master key, then `munlock`. Logs `UNMOUNT`. |

---

## 13. Audit Log

### Format

```
[YYYY-MM-DD HH:MM:SS] [username] OPERATION /path PREV=<64-char-hex> HASH=<64-char-hex>
```

### Example

```
[2026-03-30 10:15:33] [alice] MOUNT /workspace/store PREV=GENESIS HASH=a3f9b2...
[2026-03-30 10:15:41] [alice] WRITE /notes.txt PREV=a3f9b2... HASH=b812c4...
[2026-03-30 10:16:02] [alice] READ /notes.txt PREV=b812c4... HASH=c490d1...
[2026-03-30 10:20:15] [alice] UNMOUNT /workspace/store PREV=c490d1... HASH=d107e3...
```

### Verification

```bash
./scripts/vault.sh verify-log
```

Example output when clean:

```
  Line    1: OK       [2026-03-30 10:15:33] [alice] MOUNT
  Line    2: OK       [2026-03-30 10:15:41] [alice] WRITE
  Line    3: OK       [2026-03-30 10:16:02] [alice] READ
  Line    4: OK       [2026-03-30 10:20:15] [alice] UNMOUNT

  Summary: 4 OK  │  0 TAMPERED  │  0 SKIPPED  │  4 total
```

Example output when an entry was edited:

```
  Line    1: OK       [2026-03-30 10:15:33] [alice] MOUNT
  Line    2: TAMPERED [2026-03-30 10:15:41] [alice] WRITE
              ↳ Hash mismatch — the content of this line was edited
  Line    3: TAMPERED [2026-03-30 10:16:02] [alice] READ
              ↳ PREV chain broken — entries may have been inserted or deleted

  Summary: 1 OK  │  2 TAMPERED  │  0 SKIPPED  │  4 total
```

### Hash computation

The HASH field for each entry is:

```
SHA-256( "[timestamp] [user] OP path PREV=<prev_hash>" )
```

The exact same algorithm is implemented in both `src/myfs.c` (using OpenSSL's EVP API) and `scripts/vault.sh` (using `openssl dgst -sha256`), so log entries written by either component can be verified by the other.

---

## 14. Key Management

### Key file

The master key is a raw 32-byte (256-bit) binary file stored at `keys/vault.key` with permissions `600`. It is read into a `mlock()`'d buffer by `myfs` at startup.

```bash
# Inspect the key (safe — shows only the SHA-256 fingerprint, not the key itself)
openssl dgst -sha256 keys/vault.key

# Verify the file is exactly 32 bytes
wc -c keys/vault.key   # should print: 32 keys/vault.key
```

### Generating a random key

```bash
./scripts/vault.sh keygen
# Internally runs: openssl rand -out keys/vault.key 32
```

### Generating a passphrase-derived key

```bash
./scripts/vault.sh keygen --passphrase
# Internally runs:
#   printf '%s' "$PASSPHRASE" | argon2 "fusevault_salt" -id -l 32 -t 3 -m 16 -p 4 -r | xxd -r -p > keys/vault.key
```

### Key rotation workflow

```bash
# 1. Generate a new key (or use passphrase)
# 2. Rotate re-encrypts all files under the new key in one command
./scripts/vault.sh rotate
```

`rotate` mounts with the old key, reads all plaintext through FUSE, unmounts, generates a new key, re-mounts, writes everything back (re-encrypted with fresh FEKs under the new master key), unmounts, and shreds the old key file.

### Emergency key destruction

```bash
./scripts/vault.sh wipe
# Type: CONFIRM
```

This runs `shred -u keys/vault.key`, overwriting the file with random data multiple times before deletion. All `.enc` files in `store/` become permanently and irreversibly unreadable.

---

## 15. Troubleshooting

### `fusevault: cannot open key file`

The key file is missing. Generate one:

```bash
./scripts/vault.sh keygen
```

### `myfs binary not found`

The C program has not been compiled. Run:

```bash
make
```

### Vault did not mount within 3 seconds

Common in Docker. Check:

```bash
# Confirm /dev/fuse is available
ls -la /dev/fuse

# Confirm container has SYS_ADMIN capability
cat /proc/self/status | grep CapEff

# Check kernel messages
dmesg | tail -20
```

The container must be started with `--privileged --cap-add SYS_ADMIN --device /dev/fuse`.

### `fusermount: fuse device not found`

The `fuse` kernel module is not loaded. Run:

```bash
sudo modprobe fuse
```

### Decryption failed / binary output instead of plaintext

The wrong key is loaded. The `.enc` file was encrypted with a different master key than the one currently in `keys/vault.key`. If you rotated the key, the old files can only be decrypted with the old key.

### `mlock() failed (non-fatal)`

The process does not have the `CAP_IPC_LOCK` capability. In Docker, add `--cap-add IPC_LOCK`. This is non-fatal — the vault still works, but the master key is not pinned in RAM.

### File appears empty after write

Text editors (like Vim, nano) often write via a `truncate → write` sequence. Both operations are supported. If a file appears empty:

```bash
# Check the .enc file exists and is non-trivial
ls -lh store/<filename>.enc

# Inspect the header (first 68 bytes)
xxd store/<filename>.enc | head -6
```

---

## 16. Concepts Glossary

| Term | Definition |
|---|---|
| **FUSE** | *Filesystem in Userspace.* A Linux kernel interface that lets a regular program implement a filesystem without writing a kernel module. |
| **VFS** | *Virtual Filesystem Switch.* The Linux kernel abstraction layer that routes filesystem calls (read, write, stat…) to the correct driver. FUSE plugs into VFS. |
| **AES-256-CBC** | A symmetric block cipher with a 256-bit key and Cipher Block Chaining mode. The current standard for symmetric encryption. |
| **IV** | *Initialization Vector.* A random 16-byte value injected into AES-CBC so that encrypting the same data twice produces different ciphertext. |
| **FEK** | *File Encryption Key.* A random 32-byte key generated fresh for every file write. Used to encrypt the file content. |
| **Envelope Encryption** | Encrypting a data key (FEK) with a master key. Compromise of one data key only exposes one file, not all files. |
| **Master Key** | The 32-byte key stored in `keys/vault.key`. It wraps all FEKs but never directly encrypts file content. |
| **Key Wrapping** | Encrypting one key with another key (AES-CBC used as a key wrap here). |
| **Argon2id** | A memory-hard password hashing algorithm and winner of the 2015 Password Hashing Competition. Resistant to GPU brute-force due to its RAM requirement. |
| **PBKDF2** | An older password-based key derivation function. Compute-only and trivially parallelisable on GPUs. Superseded by Argon2id for new systems. |
| **Hash Chaining** | A technique where each record includes a cryptographic hash of the previous record, making any modification to historical records detectable. |
| **SHA-256** | A cryptographic hash function producing a 256-bit digest. Any change to the input produces a completely different output. |
| **`OPENSSL_cleanse()`** | An OpenSSL function that zeros a buffer in a way that the compiler cannot optimise away, unlike `memset()`. |
| **`mlock()`** | A Linux syscall that pins a memory region in physical RAM, preventing it from being paged to the swap device. |
| **`shred`** | A Linux utility that overwrites a file with random data multiple times before deleting it, making recovery from magnetic residue infeasible. |
| **Non-repudiation** | The property that a specific action by a specific user can be proven after the fact and cannot be denied. Provided here by the signed audit log. |
| **CSPRNG** | *Cryptographically Secure Pseudo-Random Number Generator.* On Linux, reads from `/dev/urandom`. Used to generate IVs and FEKs. |

---

*FuseVault — Documentation v1.0 · Last updated 2026-03-30*
