# 🔒 FuseVault — Complete Project Guide

> **Custom Encrypted FUSE Filesystem + Vault Manager**
> Built with C (FUSE) + Shell Scripting + OpenSSL AES-256

---

## 📋 Table of Contents

1. [Project Overview](#project-overview)
2. [Claude Code Prompt Guide](#claude-code-prompt-guide)
3. [Mac Setup — Claude Code](#mac-setup--claude-code)
4. [Linux VM Setup](#linux-vm-setup)
5. [Running the Project on Linux](#running-the-project-on-linux)
6. [Enhanced Features & Enhancements](#enhanced-features--enhancements)
7. [Project Development Journal](#project-development-journal)

---

---

# 1. Project Overview

FuseVault is a mountable encrypted virtual filesystem built with:

- **C + FUSE** — intercepts all filesystem I/O at the kernel level
- **OpenSSL AES-256-CBC** — transparently encrypts every file on write, decrypts on read
- **Shell Vault Manager** — mount/unmount lifecycle, key management, audit logging
- **Argon2 Key Derivation** — memory-hard passphrase-to-key derivation (enhancement)
- **Hash-chained Audit Log** — tamper-evident access trail (enhancement)

### Architecture

```
User App
   │
   ▼
VFS (Linux Kernel)
   │
   ▼
FUSE Kernel Module
   │
   ▼
myfs.c (Your C Program)         ← intercepts every read/write/open/readdir
   │              │
   ▼              ▼
Decrypt          Encrypt
(read path)      (write path)
   │              │
   └──────┬───────┘
          ▼
   ~/.vault_store/         ← AES-256 encrypted backing store
          +
   ~/.vault_audit.log      ← timestamped access trail
```

### Data Flow

| Operation | Path |
|-----------|------|
| `cp file.txt ~/vault/` | plaintext → AES-256-CBC encrypt → `.enc` stored |
| `cat ~/vault/file.txt` | `.enc` read → AES-256-CBC decrypt → plaintext returned |
| Any access | timestamp + username + op + path → appended to audit log |

---

---

# 2. Claude Code Prompt Guide

> Use these prompts **in sequence** inside a Claude Code session.
> Each prompt builds on the previous one.

---

## Prompt 1 — Project Scaffold

```
Create a new project called fusevault with the following directory structure:

fusevault/
├── src/
│   └── myfs.c
├── scripts/
│   └── vault.sh
├── keys/           (gitignored)
├── logs/
├── mount/
├── store/
├── Makefile
└── README.md

Initialize a git repo, add a .gitignore that excludes keys/, logs/, and *.enc files.
Create a Makefile that compiles src/myfs.c using:
  gcc -Wall src/myfs.c `pkg-config fuse --cflags --libs` -o myfs
```

---

## Prompt 2 — Core FUSE Filesystem (C)

```
In src/myfs.c, implement a complete FUSE filesystem with the following:

1. FUSE callbacks to implement:
   - myfs_getattr    → stat files/dirs in the backing store
   - myfs_readdir    → list files in the backing store directory
   - myfs_open       → open files, log access
   - myfs_read       → read encrypted file, decrypt with AES-256-CBC, return plaintext
   - myfs_write      → receive plaintext, encrypt with AES-256-CBC, write to backing store
   - myfs_create     → create new encrypted file
   - myfs_unlink     → delete encrypted file from backing store
   - myfs_mkdir      → create directory in backing store
   - myfs_rmdir      → remove directory from backing store
   - myfs_truncate   → truncate encrypted file

2. Encryption: use OpenSSL EVP API with AES-256-CBC
   - Load key from ~/.vault.key (32 bytes binary)
   - Generate random IV per write operation, prepend IV to ciphertext
   - On read: extract first 16 bytes as IV, decrypt remainder

3. Audit logging:
   - log_access(operation, path) function
   - Log to ~/.vault_audit.log
   - Format: [YYYY-MM-DD HH:MM:SS] [username] [OP] [path]

4. Configuration constants at top of file:
   #define BACKING_DIR   "/home/user/.vault_store"
   #define KEY_FILE      "/home/user/.vault.key"
   #define LOG_FILE      "/home/user/.vault_audit.log"

5. Include these headers:
   fuse.h, stdio.h, stdlib.h, string.h, errno.h, fcntl.h,
   unistd.h, sys/types.h, openssl/evp.h, openssl/rand.h, time.h

6. main() registers fuse_operations struct and calls fuse_main()

Compile target: gcc -Wall src/myfs.c `pkg-config fuse --cflags --libs` -lssl -lcrypto -o myfs
```

---

## Prompt 3 — Shell Vault Manager

```
In scripts/vault.sh, implement a complete vault manager with these commands:

vault mount      → launch the FUSE binary, mount at ~/vault
vault unmount    → fusermount -u ~/vault
vault status     → show if mounted, key present, log line count
vault encrypt    → encrypt a file into the backing store using openssl
vault decrypt    → decrypt a file from the backing store
vault log        → display audit log with optional --tail N flag
vault keygen     → generate a new 32-byte random key using openssl rand
vault rotate     → re-encrypt all files in backing store with a new key
vault wipe       → securely shred key file (with confirmation prompt)

Requirements:
- Store MOUNT_POINT, BACKING_DIR, LOG_FILE, KEY_FILE as variables at top
- All operations must append to the audit log
- Encrypt using: openssl enc -aes-256-cbc -pbkdf2 -iter 100000
- Color-coded output: green for success, red for errors, yellow for warnings
- vault wipe must ask "Type CONFIRM to proceed:" before deleting key
- Make script POSIX-compatible (#!/bin/bash)
- Add usage() function showing all commands and examples
```

---

## Prompt 4 — Argon2 Key Derivation (Enhancement)

```
Enhance the key management in src/myfs.c and scripts/vault.sh:

1. In vault.sh, add a new command: vault passphrase
   - Prompt user for a passphrase (hidden input with -s flag)
   - Derive a 32-byte key using: echo "$PASSPHRASE" | argon2 salt -id -l 32 -t 3 -m 16 -p 4
   - Save derived key to KEY_FILE with chmod 600
   - Log "KEYGEN passphrase-derived" to audit log (never log the passphrase)

2. In vault keygen, also support: vault keygen --passphrase
   - Branch: if --passphrase flag, use Argon2 derivation; else use openssl rand

3. Add a note in the README: why Argon2id beats PBKDF2
   (memory-hard, GPU-resistant, winner of Password Hashing Competition 2015)

Install dependency note: sudo apt install argon2
```

---

## Prompt 5 — Hash-Chained Audit Log (Enhancement)

```
Upgrade the audit log to be tamper-evident using hash chaining:

In src/myfs.c, modify log_access():
1. Read the SHA-256 hash of the current last line of the log file
2. Append a new log entry in this format:
   [timestamp] [user] [op] [path] PREV=[previous_line_hash] HASH=[hash_of_this_line]
3. Where HASH = SHA256(timestamp + user + op + path + PREV_HASH)
4. For the first entry, PREV=GENESIS

In scripts/vault.sh, add: vault verify-log
1. Read each log line
2. Recompute the hash of each line's content
3. Verify it matches the stored HASH field
4. Verify PREV field matches the hash of the previous line
5. Print: OK or TAMPERED for each line, and a final summary

Use OpenSSL SHA-256: EVP_DigestInit, EVP_DigestUpdate, EVP_DigestFinal
```

---

## Prompt 6 — Auto-Unmount + Idle Timer (Enhancement)

```
Add auto-unmount on idle to scripts/vault.sh:

1. vault mount --idle-timeout <minutes>
   - After mounting, start a background watchdog process (subshell + sleep loop)
   - Watchdog checks inotifywait on the mount point every 30 seconds
   - If no filesystem events for <minutes> minutes, call fusermount -u automatically
   - Log "AUTO_UNMOUNT idle timeout reached" to audit log
   - Kill watchdog PID on manual unmount

2. vault mount --lock-on-sleep
   - Use: system_profiler SPDisplaysDataType | grep "Display Asleep" (macOS)
   - On Linux: watch /sys/class/power_supply or use logind dbus signal
   - Auto-unmount when screen locks or laptop sleeps

3. Store watchdog PID in /tmp/.vault_watchdog.pid
4. vault status should show: "Watchdog: active (PID 12345, timeout 10min)"
```

---

## Prompt 7 — Per-File Envelope Encryption (Enhancement)

```
Upgrade from single-master-key to per-file envelope encryption in src/myfs.c:

1. On every file create/write:
   a. Generate a random 32-byte File Encryption Key (FEK) using RAND_bytes()
   b. Encrypt the file content with AES-256-CBC using the FEK
   c. Encrypt the FEK itself using the master key (AES-256-CBC key wrapping)
   d. Store the encrypted file as: [16-byte IV][32-byte encrypted FEK][ciphertext]

2. On every read:
   a. Extract the IV (first 16 bytes)
   b. Extract and decrypt the FEK (next 32 bytes, using master key)
   c. Decrypt ciphertext using the FEK

3. This means: compromising one file's key does not compromise all files
4. Document the format in a comment block at top of myfs.c:

   File format on disk:
   ┌──────────────┬──────────────────────┬────────────────┐
   │  IV (16B)    │  Enc. FEK (48B)      │  Ciphertext    │
   └──────────────┴──────────────────────┴────────────────┘
```

---

## Prompt 8 — Secure Memory Erasure (Enhancement)

```
Add secure memory handling to src/myfs.c:

1. After using any key material or plaintext buffer, zero it out using:
   OPENSSL_cleanse(buffer, length);
   (NOT memset — compiler won't optimize this away)

2. Lock key material in RAM with mlock() so it never swaps to disk:
   mlock(key_buffer, KEY_SIZE);
   munlock(key_buffer, KEY_SIZE);  // after use

3. In the FUSE destroy() callback (called on unmount):
   - OPENSSL_cleanse the global master key buffer
   - Log "SECURE_WIPE master key cleared from memory"

4. Add a comment explaining why memset is insufficient:
   (compiler dead-store elimination can remove memset of unused memory)
```

---

## Prompt 9 — Makefile + Full Build System

```
Upgrade the Makefile with these targets:

make            → build myfs binary
make debug      → build with -g -DDEBUG flags and AddressSanitizer
make clean      → remove binary and object files
make install    → copy myfs to /usr/local/bin, vault.sh to /usr/local/bin/vault
make uninstall  → remove installed files
make test       → run a self-test: mount, write a test file, read it back, verify content, unmount
make lint       → run cppcheck on src/myfs.c
make format     → run clang-format on src/myfs.c

CFLAGS should include: -Wall -Wextra -Wpedantic
Link: `pkg-config fuse --cflags --libs` -lssl -lcrypto

Add a help target that prints all targets with descriptions.
```

---

## Prompt 10 — Final Polish & README

```
Generate a complete README.md for the fusevault project covering:

1. Project description and what makes it unique
2. Architecture diagram (ASCII art)
3. Prerequisites table (libfuse-dev, openssl, argon2, gcc, pkg-config)
4. Installation steps (clone → install deps → make → keygen)
5. All vault commands with examples
6. Security model section:
   - AES-256-CBC with random IV per file
   - Per-file envelope encryption (FEK + master key wrapping)
   - Argon2id key derivation
   - Hash-chained tamper-evident audit log
   - Secure memory erasure with OPENSSL_cleanse
7. File format diagram (the IV + Enc.FEK + Ciphertext layout)
8. Potential future enhancements
9. References to FUSE docs, OpenSSL docs, Argon2 paper

Also add inline code comments throughout myfs.c explaining every non-obvious line.
```

---

---

# 3. Mac Setup — Claude Code

## Install Prerequisites on Mac

```bash
# Install Homebrew if not present
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install Node.js (required for Claude Code)
brew install node

# Install Claude Code
npm install -g @anthropic/claude-code

# Verify
claude --version
```

## Launch Claude Code

```bash
# Create project folder
mkdir ~/Projects/fusevault && cd ~/Projects/fusevault

# Start Claude Code
claude
```

> Claude Code will scan the directory and load context. You are now ready to paste the prompts from Section 2 one by one.

## Mac-Specific Notes

| Topic | Note |
|-------|------|
| FUSE on Mac | macFUSE required — download from https://osxfuse.github.io |
| Compiling C | Install Xcode CLT: `xcode-select --install` |
| OpenSSL | Homebrew version: `brew install openssl` |
| Running vault | Actual mounting must happen inside Linux VM (see Section 4) |
| File sync | Use rsync or shared folder to push code to VM after building |

## Workflow on Mac

```
Mac (Claude Code) → writes all source files
       ↓
   rsync / shared folder
       ↓
Linux VM → compiles, runs, mounts FUSE filesystem
```

---

---

# 4. Linux VM Setup

## Option A — UTM (Best for Apple Silicon Mac)

```bash
# 1. Download UTM: https://mac.getutm.app
# 2. Download Ubuntu 22.04 LTS ARM: https://ubuntu.com/download/server/arm
# 3. In UTM: New → Virtualize → Linux → browse to ISO
# 4. RAM: 4096 MB | Disk: 30 GB | CPUs: 4
# 5. Boot and install Ubuntu
# 6. After install, inside Ubuntu:

sudo apt update
sudo apt install -y \
  libfuse-dev \
  openssl \
  libssl-dev \
  pkg-config \
  gcc \
  build-essential \
  fuse \
  argon2 \
  cppcheck \
  clang-format \
  inotify-tools \
  rsync
```

## Option B — OrbStack (Lightest on Mac)

```bash
# Install OrbStack
brew install orbstack

# Create Ubuntu VM
orb create ubuntu fusevault-vm

# Shell into it
orb shell fusevault-vm

# Install dependencies (same apt block as above)
```

## Option C — Docker with FUSE Support

```bash
docker run -it \
  --privileged \
  --cap-add SYS_ADMIN \
  --device /dev/fuse \
  --name fusevault \
  -v ~/Projects/fusevault:/workspace \
  ubuntu:22.04 bash

# Inside container:
apt update && apt install -y libfuse-dev openssl libssl-dev \
  pkg-config gcc build-essential fuse argon2 inotify-tools
```

## Syncing Files from Mac to VM

```bash
# From your Mac terminal (not inside VM):
rsync -avz ~/Projects/fusevault/ ubuntu@<vm-ip>:~/fusevault/

# Get VM IP (run inside VM):
ip addr show | grep "inet " | grep -v 127
```

## Shared Folder via UTM

In UTM settings for your VM:
1. Go to **Sharing** tab
2. Enable **Shared Directory**
3. Point to `~/Projects/fusevault` on Mac
4. Inside Ubuntu, mount it:
```bash
sudo mount -t 9p -o trans=virtio share /mnt/mac
```

---

---

# 5. Running the Project on Linux

## First-Time Setup

```bash
# Navigate to project
cd ~/fusevault

# Compile
make

# Generate encryption key
./scripts/vault.sh keygen

# OR passphrase-based key (uses Argon2)
./scripts/vault.sh keygen --passphrase
```

## Mounting the Vault

```bash
# Mount
./scripts/vault.sh mount

# Mount with auto-unmount after 10 min idle
./scripts/vault.sh mount --idle-timeout 10

# Verify mount
./scripts/vault.sh status
```

## Using the Vault

```bash
# Copy a file in (triggers encrypt on write)
cp ~/secret_document.pdf ~/vault/

# Read a file (triggers decrypt on read)
cat ~/vault/notes.txt

# Open with any application — it sees plaintext automatically
libreoffice ~/vault/report.docx
```

## Vault Manager Commands

```bash
./scripts/vault.sh mount              # Mount filesystem
./scripts/vault.sh unmount            # Unmount safely
./scripts/vault.sh status             # Show mount + key + log status
./scripts/vault.sh encrypt <file>     # Manually encrypt a file
./scripts/vault.sh decrypt <file>     # Manually decrypt a file
./scripts/vault.sh log                # View full audit log
./scripts/vault.sh log --tail 20      # View last 20 entries
./scripts/vault.sh verify-log         # Verify hash-chain integrity
./scripts/vault.sh rotate             # Re-encrypt all files with new key
./scripts/vault.sh wipe               # Securely shred key (with confirmation)
./scripts/vault.sh passphrase         # Change passphrase
```

## Unmounting

```bash
./scripts/vault.sh unmount

# If busy (files open):
lsof ~/vault/         # find what has it open
kill <PID>
./scripts/vault.sh unmount
```

## Verifying Encryption Works

```bash
# Mount vault
./scripts/vault.sh mount

# Write a test file
echo "TOP SECRET" > ~/vault/test.txt

# Unmount
./scripts/vault.sh unmount

# Try to read the raw encrypted file (should be binary garbage)
cat ~/.vault_store/test.txt.enc

# Remount and read (should show plaintext)
./scripts/vault.sh mount
cat ~/vault/test.txt
```

## Reading the Audit Log

```bash
./scripts/vault.sh log
```

Example output:
```
[2025-03-24 10:15:33] [alice] MOUNT   /home/alice/vault          PREV=GENESIS            HASH=a3f9...
[2025-03-24 10:15:41] [alice] WRITE   /vault/secret.pdf          PREV=a3f9...            HASH=b812...
[2025-03-24 10:16:02] [alice] READ    /vault/secret.pdf          PREV=b812...            HASH=c490...
[2025-03-24 10:20:15] [alice] UNMOUNT /home/alice/vault          PREV=c490...            HASH=d107...
```

## Verifying Audit Log Integrity

```bash
./scripts/vault.sh verify-log

# Output:
Line 1: OK    [2025-03-24 10:15:33] MOUNT
Line 2: OK    [2025-03-24 10:15:41] WRITE
Line 3: TAMPERED  [2025-03-24 10:16:02] READ   ← hash mismatch detected!
Line 4: OK    [2025-03-24 10:20:15] UNMOUNT

Summary: 3/4 OK | 1 TAMPERED — log has been modified!
```

---

---

# 6. Enhanced Features & Enhancements

## Enhancement Summary Table

| # | Feature | Complexity | Security Impact | Prompt # |
|---|---------|------------|-----------------|----------|
| 1 | Argon2id Key Derivation | Medium | ⭐⭐⭐⭐⭐ | 4 |
| 2 | Per-File Envelope Encryption | High | ⭐⭐⭐⭐⭐ | 7 |
| 3 | Hash-Chained Audit Log | Medium | ⭐⭐⭐⭐ | 5 |
| 4 | Secure Memory Erasure | Low | ⭐⭐⭐⭐ | 8 |
| 5 | Auto-Unmount on Idle | Low | ⭐⭐⭐ | 6 |
| 6 | Key Rotation | Medium | ⭐⭐⭐⭐ | 3 |
| 7 | mlock() RAM protection | Low | ⭐⭐⭐ | 8 |
| 8 | Full build system (Makefile) | Low | — | 9 |

---

## Enhancement 1 — Argon2id Key Derivation

**Why:** PBKDF2 is breakable with GPUs. Argon2id is memory-hard — requires gigabytes of RAM per attempt, making GPU/ASIC cracking economically infeasible.

**What it replaces:** `openssl rand -base64 32` for passphrase-based keys.

**How it works:**
```bash
# Derives a 32-byte key from a passphrase
echo "$PASSPHRASE" | argon2 "fusevault_salt" -id -l 32 -t 3 -m 16 -p 4
#                                              ^ memory-hard iterations
```

| Parameter | Meaning |
|-----------|---------|
| `-id` | Argon2id variant (hybrid, best practice) |
| `-l 32` | Output 32 bytes (256-bit key) |
| `-t 3` | 3 time iterations |
| `-m 16` | 2^16 = 64MB RAM required |
| `-p 4` | 4 parallel threads |

---

## Enhancement 2 — Per-File Envelope Encryption

**Why:** With a single master key, if the key leaks, every file is compromised. Envelope encryption generates a unique key per file.

**File format on disk:**
```
┌──────────────┬───────────────────────┬──────────────────────┐
│  IV (16 B)   │  Encrypted FEK (48 B) │  Ciphertext (N B)    │
└──────────────┴───────────────────────┴──────────────────────┘
     ↑                  ↑                        ↑
 Random per         AES-256 wrapped           AES-256-CBC
  write op          with master key           with FEK + IV
```

**Security gain:** Compromise of one file's FEK has zero impact on any other file.

---

## Enhancement 3 — Hash-Chained Audit Log

**Why:** Without integrity protection, an attacker with filesystem access can simply delete or edit log entries. Hash chaining makes any modification detectable.

**Log entry format:**
```
[timestamp] [user] [op] [path] PREV=<hash_of_prev_line> HASH=<sha256_of_this_line>
```

**Detection:** If any entry is edited, its HASH won't match when recomputed, AND the PREV field of the next entry will mismatch — cascading evidence of tampering.

---

## Enhancement 4 — Secure Memory Erasure

**Why:** `memset()` is silently removed by optimizing compilers when the buffer is never read again. Key material can linger in RAM indefinitely.

```c
// WRONG — compiler may optimize this away
memset(key_buffer, 0, KEY_SIZE);

// CORRECT — OpenSSL guarantees this is never eliminated
OPENSSL_cleanse(key_buffer, KEY_SIZE);
```

Combined with `mlock()`, key material is guaranteed to:
- Never be swapped to disk
- Be zeroed immediately after use

---

## Enhancement 5 — Auto-Unmount on Idle

**Why:** If you forget to unmount, your vault stays accessible indefinitely. A watchdog daemon closes it automatically.

```bash
# Mount with 10-minute idle timeout
./vault.sh mount --idle-timeout 10

# Internally:
inotifywait -m -r ~/vault/ &   # watch for filesystem events
# If no events for 10 minutes → fusermount -u ~/vault
```

---

## What Makes FuseVault Unique (Portfolio Value)

```
Most students:           FuseVault:
─────────────────────    ──────────────────────────────────────────
"I know what AES is"  →  AES-256 implemented via OpenSSL EVP API in C
"I know filesystems"  →  Built a custom kernel-interfacing FUSE driver
"I understand logs"   →  Hash-chained tamper-evident audit trail
"I used passwords"    →  Argon2id key derivation (PHC winner)
"I encrypted files"   →  Per-file envelope encryption (industry standard)
"I wrote shell"       →  Full vault lifecycle manager with key rotation
```

This is the architecture used by:
- **VeraCrypt** — FUSE + AES + key derivation
- **AWS KMS** — envelope encryption (data key + master key)
- **HashiCorp Vault** — audit log + access control
- **macOS FileVault** — transparent filesystem encryption

---

---

# 7. Project Development Journal

> This section is your living documentation. Fill it in as you build.
> It serves as your portfolio evidence, interview talking points, and debugging history.

---

## Journal Entry Template

```
Date: YYYY-MM-DD
Prompt Used: [paste the prompt number and title]
─────────────────────────────────────────────────────
WHAT I ASKED:
[exact prompt or paraphrase]

WHAT CLAUDE CODE PRODUCED:
[file names created, lines of code, key decisions made]

IMPLEMENTATION DETAILS:
[what the code does, design choices, algorithms used]

ISSUES ENCOUNTERED:
[compiler errors, linker errors, runtime crashes, logic bugs]

HOW IT WAS FIXED:
[exact fix applied, what caused the issue]

WHAT I LEARNED:
[concepts, tools, commands learned from this step]

CURRENT STATUS:
[ ] Not started  [x] In progress  [ ] Complete  [ ] Blocked
```

---

## Entry 1 — Project Scaffold

```
Date: ___________
Prompt Used: Prompt 1 — Project Scaffold
─────────────────────────────────────────────────────
WHAT I ASKED:
Create project structure with Makefile, .gitignore, and directory layout.

WHAT CLAUDE CODE PRODUCED:


ISSUES ENCOUNTERED:


HOW IT WAS FIXED:


WHAT I LEARNED:


CURRENT STATUS:
[ ] Not started  [ ] In progress  [ ] Complete  [ ] Blocked
```

---

## Entry 2 — Core FUSE Filesystem

```
Date: ___________
Prompt Used: Prompt 2 — Core FUSE Filesystem (C)
─────────────────────────────────────────────────────
WHAT I ASKED:
Implement full FUSE callbacks with AES-256-CBC encryption and audit logging.

WHAT CLAUDE CODE PRODUCED:


KEY IMPLEMENTATION DETAILS:
- FUSE callbacks implemented:
- Encryption approach:
- IV handling:
- Key loading:

COMPILER ERRORS ENCOUNTERED:


LINKER ERRORS ENCOUNTERED:
(Common: missing -lssl -lcrypto in CFLAGS)

HOW THEY WERE FIXED:


RUNTIME ISSUES:


WHAT I LEARNED:


CURRENT STATUS:
[ ] Not started  [ ] In progress  [ ] Complete  [ ] Blocked
```

---

## Entry 3 — Shell Vault Manager

```
Date: ___________
Prompt Used: Prompt 3 — Shell Vault Manager
─────────────────────────────────────────────────────
WHAT I ASKED:
Implement vault.sh with mount/unmount/encrypt/decrypt/log/keygen/rotate/wipe.

WHAT CLAUDE CODE PRODUCED:


ISSUES ENCOUNTERED:
(Common: fusermount not found, wrong path to myfs binary, permission denied on mount point)

HOW THEY WERE FIXED:


WHAT I LEARNED:


CURRENT STATUS:
[ ] Not started  [ ] In progress  [ ] Complete  [ ] Blocked
```

---

## Entry 4 — Argon2 Key Derivation

```
Date: ___________
Prompt Used: Prompt 4 — Argon2 Key Derivation
─────────────────────────────────────────────────────
WHAT I ASKED:
Replace openssl rand with Argon2id passphrase-based key derivation.

WHAT CLAUDE CODE PRODUCED:


WHY ARGON2 OVER PBKDF2:
(write in your own words after researching)

ISSUES ENCOUNTERED:
(Common: argon2 binary not found → sudo apt install argon2)

HOW THEY WERE FIXED:


WHAT I LEARNED:


CURRENT STATUS:
[ ] Not started  [ ] In progress  [ ] Complete  [ ] Blocked
```

---

## Entry 5 — Hash-Chained Audit Log

```
Date: ___________
Prompt Used: Prompt 5 — Hash-Chained Audit Log
─────────────────────────────────────────────────────
WHAT I ASKED:
Upgrade audit log to use SHA-256 hash chaining for tamper detection.

WHAT CLAUDE CODE PRODUCED:


HOW HASH CHAINING WORKS (my understanding):


VERIFICATION TEST RESULT:
(Did vault verify-log catch a manual edit to the log?)

ISSUES ENCOUNTERED:


HOW THEY WERE FIXED:


WHAT I LEARNED:


CURRENT STATUS:
[ ] Not started  [ ] In progress  [ ] Complete  [ ] Blocked
```

---

## Entry 6 — Auto-Unmount

```
Date: ___________
Prompt Used: Prompt 6 — Auto-Unmount + Idle Timer
─────────────────────────────────────────────────────
WHAT I ASKED:


WHAT CLAUDE CODE PRODUCED:


ISSUES ENCOUNTERED:
(Common: inotifywait not found → sudo apt install inotify-tools)

HOW THEY WERE FIXED:


WHAT I LEARNED:


CURRENT STATUS:
[ ] Not started  [ ] In progress  [ ] Complete  [ ] Blocked
```

---

## Entry 7 — Per-File Envelope Encryption

```
Date: ___________
Prompt Used: Prompt 7 — Per-File Envelope Encryption
─────────────────────────────────────────────────────
WHAT I ASKED:


WHAT CLAUDE CODE PRODUCED:


FILE FORMAT DIAGRAM:
(Draw it yourself after reading the code)

ISSUES ENCOUNTERED:
(Common: off-by-one errors reading IV/FEK offsets, buffer size issues)

HOW THEY WERE FIXED:


WHAT I LEARNED:


CURRENT STATUS:
[ ] Not started  [ ] In progress  [ ] Complete  [ ] Blocked
```

---

## Entry 8 — Secure Memory

```
Date: ___________
Prompt Used: Prompt 8 — Secure Memory Erasure
─────────────────────────────────────────────────────
WHAT I ASKED:


WHAT CLAUDE CODE PRODUCED:


WHY memset() IS INSUFFICIENT (my understanding):


ISSUES ENCOUNTERED:


HOW THEY WERE FIXED:


WHAT I LEARNED:


CURRENT STATUS:
[ ] Not started  [ ] In progress  [ ] Complete  [ ] Blocked
```

---

## Known Issues Log

| # | Date | Issue Description | Status | Fix Applied |
|---|------|-------------------|--------|-------------|
| 1 | | | Open | |
| 2 | | | Open | |
| 3 | | | Open | |

---

## Concepts Learned

Fill this in as you go — use it for interview prep:

| Concept | What It Is | Where Used in FuseVault |
|---------|-----------|------------------------|
| FUSE | Filesystem in Userspace — lets you write filesystems without kernel modules | Core of myfs.c |
| VFS | Virtual Filesystem Switch — Linux abstraction layer for all filesystems | FUSE plugs into VFS |
| AES-256-CBC | Symmetric block cipher, 256-bit key, Cipher Block Chaining mode | Every file encrypt/decrypt |
| IV (Initialization Vector) | Random value that makes identical plaintexts encrypt differently | Prepended to each .enc file |
| EVP API | OpenSSL's high-level encryption API | Encryption functions in myfs.c |
| Argon2id | Memory-hard password hashing function, PHC winner 2015 | Key derivation from passphrase |
| Envelope Encryption | Encrypt data with a data key, encrypt the data key with a master key | Per-file FEK system |
| SHA-256 | Cryptographic hash function, 256-bit output | Audit log hash chaining |
| mlock() | Linux syscall that pins memory pages, preventing swap to disk | Key buffer protection |
| OPENSSL_cleanse | Guaranteed memory zeroing that compiler cannot optimize away | Clearing key material |
| Non-repudiation | Proof that a specific user performed a specific action | Audit log with username + timestamp |

---

## Final Reflection

```
Project Start Date:
Project Completion Date:
Total Prompts Used:
Total Files Created:
Total Lines of Code (approx):

BIGGEST CHALLENGE:


MOST INTERESTING THING LEARNED:


HOW THIS PROJECT DIFFERS FROM TYPICAL STUDENT PROJECTS:


WHAT I WOULD ADD NEXT:


HOW I WOULD EXPLAIN THIS IN AN INTERVIEW:

```

---

---

## References

- FUSE Documentation: https://libfuse.github.io/doxygen/
- OpenSSL EVP API: https://www.openssl.org/docs/man3.0/man3/EVP_EncryptInit.html
- Argon2 Paper: https://github.com/P-H-C/phc-winner-argon2
- FUSE GitHub: https://github.com/libfuse/libfuse
- Claude Code Docs: https://docs.claude.com/en/docs/claude-code/overview
- UTM for Mac: https://mac.getutm.app
- macFUSE: https://osxfuse.github.io

---

*FuseVault — Built with Claude Code | Documentation v1.0*
