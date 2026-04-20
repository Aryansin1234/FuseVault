<div align="center">

```
███████╗██╗   ██╗███████╗███████╗██╗   ██╗ █████╗ ██╗   ██╗██╗ ████████╗
██╔════╝██║   ██║██╔════╝██╔════╝██║   ██║██╔══██╗██║   ██║██║ ╚══██╔══╝
█████╗  ██║   ██║███████╗█████╗  ██║   ██║███████║██║   ██║██║    ██║   
██╔══╝  ██║   ██║╚════██║██╔══╝  ╚██╗ ██╔╝██╔══██║██║   ██║██║    ██║   
██║     ╚██████╔╝███████║███████╗ ╚████╔╝ ██║  ██║╚██████╔╝███████╗██║  
╚═╝      ╚═════╝ ╚══════╝╚══════╝  ╚═══╝  ╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝  
```

**A military-grade encrypted virtual filesystem built in C**

`FUSE` · `AES-256-CBC` · `Argon2id` · `OpenSSL` · `Hash-Chain Audit Log`

---

[![Language](https://img.shields.io/badge/Language-C-blue?style=flat-square&logo=c)](https://en.wikipedia.org/wiki/C_(programming_language))
[![Encryption](https://img.shields.io/badge/Encryption-AES--256--CBC-green?style=flat-square&logo=openssl)](https://www.openssl.org/)
[![KDF](https://img.shields.io/badge/KDF-Argon2id-purple?style=flat-square)](https://github.com/P-H-C/phc-winner-argon2)
[![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20Docker-orange?style=flat-square&logo=linux)](https://kernel.org/)
[![FUSE](https://img.shields.io/badge/FUSE-libfuse2-yellow?style=flat-square)](https://github.com/libfuse/libfuse)

</div>

---

## 🔐 What is FuseVault?

Imagine a black hole for your sensitive data, where files go in and instantly turn into cryptographically secure noise—but to you, everything looks perfectly normal.

**FuseVault** is a mountable virtual filesystem that **transparently encrypts every file you write and decrypts every file you read** — completely invisible to the applications you use daily.

### 🧠 Explain Like I'm 5 (ELI5)
Think of `mount/` as a magic portal and `store/` as a reinforced concrete vault. 

When you drop a file into the magic portal (`mount/`), our FUSE engine intercepts it, instantly wraps it in AES-256-CBC encryption, and drops the scrambled binary mess into the vault (`store/`). When you open the file, the portal decrypts it on-the-fly. 

No special commands. No manual decryption steps. It just works.

```text
 🧑‍💻 You: cat mount/secrets.txt
                  ↓
         [ Magic Portal (FUSE) Intercepts ]
                  ↓
         [ Decrypts on-the-fly via AES-256-CBC ]
                  ↓
 📄 App receives: "my top secret content"

 💽 What's actually in store/: ÿó¤±Ðú╗╢╕ëÞõ (unreadable binary)
```

> **Vibe Check:** It's like **macOS FileVault** or **VeraCrypt** — but built entirely from scratch in C, running in userspace, with a gorgeous terminal UI.

---

## ✨ Key Features (The Magic Under the Hood)

| Feature | Description |
|---|---|
| 🔒 **Transparent Shielding** | Any app reads/writes normally — encryption is completely invisible at the OS level |
| 🛡️ **AES-256-CBC per file** | Each file gets a fresh random IV, making frequency analysis completely useless |
| 🗝️ **Envelope Encryption (FEK)** | Per-file keys wrapped by a master key — exactly the same architecture used in **AWS KMS** & **Google Cloud KMS** |
| 🧬 **Argon2id Key Derivation** | Memory-hard passphrase KDF — it forces brute-forcing GPUs to an absolute crawl (because of RAM limits) |
| 📋 **Hash-Chain Audit Log** | Every operation SHA-256 chained — log tampering is instantly mathematically detectable |
| 🔏 **Secure Memory Erasure** | `OPENSSL_cleanse()` + `mlock()` — keys never hit swap disks and are aggressively zeroed on unmount |
| 🎬 **Immersive TUI** | Cinematic Hacker/Matrix terminal UI with guided demos, file browsing, health diagnostics, and confirmation gates |
| 🔄 **One-Command Key Rotation** | Instantly re-encrypt all files under a brand new master key with a single lifecycle command |

---

## 🏗️ Architecture

```
 ┌─────────────────────────────────────┐
 │    User Application                 │
 │    (cat, cp, vim, any program...)   │
 └──────────────┬──────────────────────┘
                │  read() / write() syscalls
                ▼
 ┌──────────────────────────────────────┐
 │    VFS — Linux Virtual File System   │
 │    (routes I/O to correct driver)    │
 └──────────────┬───────────────────────┘
                │
                ▼
 ┌──────────────────────────────────────┐
 │    FUSE Kernel Module                │
 │    (bridges kernel ↔ userspace)      │
 └──────────────┬───────────────────────┘
                │
                ▼
 ┌──────────────────────────────────────┐
 │    myfs  (src/myfs.c)                │  ← Your C process, running in userspace
 │    intercepts every read/write/open  │
 └─────────┬──────────────┬────────────┘
           │              │
           ▼              ▼
       Decrypt          Encrypt
      (read path)      (write path)
           │              │
           └──────┬────────┘
                  ▼
        store/*.enc              ← AES-256-CBC encrypted binary blobs
             +
        logs/vault_audit.log     ← SHA-256 hash-chained tamper-evident log
```

### 📦 Data Flow

| Operation | What happens end-to-end |
|---|---|
| `cp secret.pdf mount/` | plaintext → fresh random IV + FEK → AES-256-CBC encrypt with FEK → wrap FEK with master key → write `.enc` header + ciphertext to `store/` |
| `cat mount/notes.txt` | read `.enc` → parse header → unwrap FEK using master key → decrypt ciphertext → return plaintext |
| `ls mount/` | list `store/`, strip `.enc` suffix → return plain filenames |
| Any operation | timestamp + user + op + path → SHA-256 hash-chained entry → appended to audit log |

---

## 🔒 Security Model

### 1️⃣ AES-256-CBC with a Random IV Per Write

Every `write()` call generates a new 16-byte IV via `RAND_bytes()`. This means:
- Encrypting the same file twice produces **completely different ciphertext**
- Prevents frequency analysis and known-plaintext attacks

### 2️⃣ Per-File Envelope Encryption (FEK)

```
 ┌──────────────────┬──────────────┬───────────────────────┬──────────────┐
 │  PLAINTEXT_SIZE  │   IV (16 B)  │  Encrypted FEK (48 B) │  Ciphertext  │
 │      (4 B)       │ random/write │  master-key wrapped    │  (variable)  │
 └──────────────────┴──────────────┴───────────────────────┴──────────────┘
 ←────────────────────── HEADER_SIZE = 68 bytes ──────────────────────────→
```

- Each file gets its own random **File Encryption Key (FEK)**
- The FEK is encrypted (wrapped) with the master key and stored in the file header
- **Compromise of one file's FEK has zero impact on any other file**
- This is identical to the model used by **AWS KMS** and **Google Cloud KMS**

### 3️⃣ Argon2id Key Derivation

When using `vault.sh keygen --passphrase`, the master key is derived using **Argon2id** (winner of the 2015 Password Hashing Competition):

| Parameter | Value | Effect |
|---|---|---|
| `-t 3` | 3 iterations | CPU work |
| `-m 16` | 2¹⁶ = **64 MB RAM** | Memory-hard — destroys GPU parallelism |
| `-p 4` | 4 threads | Parallel lanes |
| `-l 32` | 32-byte output | 256-bit key |

**Why Argon2id over PBKDF2?**
PBKDF2 is compute-only — a GPU farm can test billions of passwords/sec. Argon2id requires 64 MB of RAM per attempt, so an attacker with 1 TB of GPU RAM can only test ~16,000 passwords simultaneously. Brute-force becomes economically infeasible.

### 4️⃣ Hash-Chained Tamper-Evident Audit Log

```
[2026-03-24 10:15:33] [alice] MOUNT /workspace/store PREV=GENESIS HASH=a3f9...
[2026-03-24 10:15:41] [alice] WRITE /notes.txt PREV=a3f9... HASH=b812...
[2026-03-24 10:16:02] [alice] READ  /notes.txt PREV=b812... HASH=c490...
```

`HASH = SHA-256("[timestamp] [user] OP path PREV=<prev_hash>")` — any modification to any entry breaks the entire chain.

### 5️⃣ Secure Memory Erasure

```c
// ❌ WRONG — compiler can eliminate this as a "dead store"
memset(key_buffer, 0, KEY_SIZE);

// ✅ CORRECT — OpenSSL guarantees this is never optimized away
OPENSSL_cleanse(key_buffer, KEY_SIZE);
```

- `OPENSSL_cleanse()` zeros all key material and plaintext buffers after use
- `mlock()` pins the master key buffer in physical RAM — never paged to swap
- `destroy()` callback (called on unmount) cleanses and unlocks the master key

---

## 🌍 Real-World Equivalents

| FuseVault Concept | Real-World Equivalent |
|---|---|
| FUSE transparent encryption | macOS FileVault, VeraCrypt |
| Per-file envelope encryption | AWS KMS, Google Cloud KMS |
| Argon2id key derivation | 1Password, Bitwarden |
| Hash-chained audit log | Blockchain, HashiCorp Vault |
| `mlock()` + `OPENSSL_cleanse()` | Hardware Security Modules (HSMs) |

---

## 📁 Project Structure

```
FuseVault/
├── src/
│   └── myfs.c                 ← FUSE filesystem (C) — the encryption engine
├── scripts/
│   ├── vault.sh               ← Vault lifecycle manager (Bash)
│   └── fusevault_ui.sh        ← Interactive cinematic TUI (gum-powered)
├── store/                     ← Encrypted .enc backing files (gitignored)
├── mount/                     ← FUSE mount point — the "magic folder"
├── keys/                      ← Master key (gitignored, chmod 600)
├── logs/                      ← Audit log (vault_audit.log)
├── Makefile                   ← Build system
├── Dockerfile                 ← Docker image (required for macOS)
├── run.sh                     ← Convenience launch script
├── DOCS.md                    ← Full technical documentation
└── TESTING.md                 ← Test procedures
```

---

## 📋 Prerequisites

> **FuseVault requires Linux.** FUSE is a Linux kernel feature. On macOS, use Docker (recommended).

| Package | Purpose | Install |
|---|---|---|
| `libfuse-dev` | FUSE headers | `apt install libfuse-dev` |
| `fuse` | `fusermount` binary | `apt install fuse` |
| `openssl` + `libssl-dev` | AES-256, SHA-256 | `apt install openssl libssl-dev` |
| `gcc`, `build-essential` | C compiler | `apt install build-essential` |
| `pkg-config` | FUSE CFLAGS/LDFLAGS | `apt install pkg-config` |
| `argon2` | Passphrase key derivation | `apt install argon2` |
| `inotify-tools` | Idle-timeout watchdog | `apt install inotify-tools` |

Install all at once:
```bash
sudo apt update && sudo apt install -y \
  libfuse-dev fuse openssl libssl-dev \
  build-essential pkg-config argon2 \
  inotify-tools cppcheck clang-format
```

---

## 🐳 Docker Quick-Start (Recommended for macOS)

```bash
# 1. Build the image
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
```

---

## 🚀 First-Time Setup

```bash
# Compile the FUSE binary
make

# Generate a random 256-bit key
./scripts/vault.sh keygen

# OR derive a key from a passphrase (Argon2id — memory-hard)
./scripts/vault.sh keygen --passphrase

# Mount the vault
./scripts/vault.sh mount

# Verify it's running
./scripts/vault.sh status
```

---

## 📂 Using the Vault

```bash
# ✏️  Write a file (encrypted transparently on write)
cp ~/secret.pdf mount/
echo "TOP SECRET" > mount/notes.txt

# 📖  Read a file (decrypted transparently on read)
cat mount/notes.txt           # → TOP SECRET
libreoffice mount/report.docx

# 📋  List files (shows plain names, not .enc names)
ls mount/

# 🔒  Unmount safely (zeroes key from RAM)
./scripts/vault.sh unmount
```

---

## 🖥️ Interactive TUI (The Matrix Hacker Experience)

FuseVault isn't just a backend tool. It ships with a fully **cinematic terminal UI** featuring a custom green-to-cyan hacker aesthetic, particle rain animations, typewriter text effects, and interactive flow-gates. It's built beautifully using [gum](https://github.com/charmbracelet/gum).

```bash
./scripts/fusevault_ui.sh
```

*Drop into a fully guided, visually stunning dashboard that makes securing your files feel like operating a sci-fi mainframe.*

**Screens available:**

| Screen | Description |
|---|---|
| 🖥️ **Dashboard** | Live vault status — mount state, key health, recent events |
| 📁 **File Browser** | Browse, read, write, and delete encrypted files interactively |
| 🔒 **Vault Controls** | Mount, unmount, self-test, wipe |
| 📋 **Audit Log** | View, verify, and follow the hash-chain audit trail live |
| 🔑 **Key Management** | Generate, derive, rotate, and inspect the master key |
| 🔬 **Diagnostics** | Health checks for binary, crypto libraries, key permissions |
| 🎬 **Guided Demo** | 7-step interactive walkthrough — best starting point |

---

## 📖 All Vault Commands

```bash
# 🔌 Lifecycle
./scripts/vault.sh mount                      # Mount the vault
./scripts/vault.sh mount --idle-timeout 10    # Auto-unmount after 10 min idle
./scripts/vault.sh unmount                    # Unmount safely (zeroes key from RAM)
./scripts/vault.sh status                     # Show mount state, key, log, watchdog

# 🗝️  Key Management
./scripts/vault.sh keygen                     # Generate new random 256-bit key
./scripts/vault.sh keygen --passphrase        # Derive key via Argon2id passphrase
./scripts/vault.sh passphrase                 # Change passphrase
./scripts/vault.sh rotate                     # Re-encrypt all files with a new key
./scripts/vault.sh wipe                       # Securely shred key (type CONFIRM)

# 📄 File Operations
./scripts/vault.sh encrypt <file>             # Manually encrypt a file
./scripts/vault.sh decrypt <file.enc>         # Manually decrypt a file

# 📋 Audit Log
./scripts/vault.sh log                        # View full audit log
./scripts/vault.sh log --tail 20              # View last 20 entries
./scripts/vault.sh verify-log                 # Verify hash-chain integrity
```

---

## 🛠️ Build Targets

```bash
make              # Build myfs binary
make debug        # Build with -g -DDEBUG + AddressSanitizer
make clean        # Remove build artifacts
make install      # Install myfs and vault to /usr/local/bin
make uninstall    # Remove installed files
make test         # Automated mount → write → read → verify → unmount self-test
make lint         # Run cppcheck on src/myfs.c
make format       # Run clang-format on src/myfs.c
make help         # Print all targets
```

---

## 🔬 Verifying Encryption Works

```bash
# Mount and write a secret
./scripts/vault.sh mount
echo "TOP SECRET" > mount/test.txt

# Unmount and inspect the raw backing file — should be unreadable binary
./scripts/vault.sh unmount
xxd store/test.txt.enc | head
# Output: 00000000: 0b00 0000 a3f9 b2c1 d4e7 ...  ← binary garbage

# Re-mount and confirm plaintext is recovered
./scripts/vault.sh mount
cat mount/test.txt    # → TOP SECRET
./scripts/vault.sh unmount
```

---

## 📋 Audit Log Example

```
[2026-03-24 10:15:33] [alice] MOUNT  /workspace/store PREV=GENESIS  HASH=a3f9...
[2026-03-24 10:15:41] [alice] WRITE  /notes.txt       PREV=a3f9...  HASH=b812...
[2026-03-24 10:16:02] [alice] READ   /notes.txt       PREV=b812...  HASH=c490...
[2026-03-24 10:20:15] [alice] UNMOUNT /workspace/store PREV=c490... HASH=d107...
```

Verify integrity at any time:
```bash
./scripts/vault.sh verify-log
# Line 1: OK    [2026-03-24 10:15:33] MOUNT
# Line 2: OK    [2026-03-24 10:15:41] WRITE
# Line 3: OK    [2026-03-24 10:16:02] READ
# Line 4: OK    [2026-03-24 10:20:15] UNMOUNT
# Summary: 4 OK | 0 TAMPERED
```

---

## ⚙️ Environment Variables

Override default paths with environment variables:

| Variable | Default | Description |
|---|---|---|
| `VAULT_BACKING_DIR` | `<project>/store` | Where `.enc` files are stored |
| `VAULT_KEY_FILE` | `<project>/keys/vault.key` | Path to the 32-byte master key |
| `VAULT_LOG_FILE` | `<project>/logs/vault_audit.log` | Path to the audit log |
| `VAULT_MOUNT_POINT` | `<project>/mount` | FUSE mount point directory |

---

## 🔭 Potential Enhancements

- **ChaCha20-Poly1305** — authenticated encryption; detects ciphertext tampering
- **FUSE 3 API** — updated `getattr` signature and improved performance
- **Key escrow** — encrypted key backup for disaster recovery
- **Multi-user ACL** — per-user FEK wrapping with individual master keys
- **Integrity tags** — HMAC per file to detect in-place ciphertext modification
- **macOS support** — macFUSE (`osxfuse`) port

---

## 🔧 Troubleshooting

| Problem | Fix |
|---|---|
| `cannot open key file` | Run `./scripts/vault.sh keygen` |
| `myfs binary not found` | Run `make` |
| `fuse device not found` | Run `sudo modprobe fuse` |
| `mlock() failed (non-fatal)` | Add `--cap-add IPC_LOCK` to Docker |
| Vault did not mount | Ensure `--privileged --cap-add SYS_ADMIN --device /dev/fuse` in Docker |
| Decryption failed / binary output | Wrong key loaded — key mismatch with `.enc` files |

---

## 📚 References

- [FUSE Documentation](https://libfuse.github.io/doxygen/)
- [OpenSSL EVP API](https://www.openssl.org/docs/man3.0/man3/EVP_EncryptInit.html)
- [Argon2 Paper & Reference Implementation](https://github.com/P-H-C/phc-winner-argon2)
- [FUSE GitHub](https://github.com/libfuse/libfuse)
- [AWS KMS Envelope Encryption](https://docs.aws.amazon.com/kms/latest/developerguide/concepts.html#enveloping)

---

## 📖 Full Documentation

For complete technical documentation including FUSE callback internals, key management workflows, file format spec, concepts glossary, and more — see [DOCS.md](DOCS.md).

---

<div align="center">

**FuseVault** — *Your Files. Your Keys. Your Vault.*

*Built with C · OpenSSL · FUSE · Argon2id · Claude Code*

</div>
