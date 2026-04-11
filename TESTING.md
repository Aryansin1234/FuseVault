# FuseVault — Testing & Getting Started Guide

> **Complete walkthrough:** how to build, run, test every feature, and understand what each step is doing.

---

## Table of Contents

1. [What You Need](#1-what-you-need)
2. [Build the Docker Image](#2-build-the-docker-image)
3. [Enter the Container](#3-enter-the-container)
4. [Compile FuseVault](#4-compile-fusevault)
5. [Test 1 — Basic Encrypt/Decrypt Round-Trip](#5-test-1--basic-encryptdecrypt-round-trip)
6. [Test 2 — Prove Encryption is Real](#6-test-2--prove-encryption-is-real)
7. [Test 3 — Passphrase-Derived Key (Argon2id)](#7-test-3--passphrase-derived-key-argon2id)
8. [Test 4 — Audit Log & Hash-Chain Verification](#8-test-4--audit-log--hash-chain-verification)
9. [Test 5 — Tamper Detection](#9-test-5--tamper-detection)
10. [Test 6 — Auto-Unmount on Idle](#10-test-6--auto-unmount-on-idle)
11. [Test 7 — Key Rotation](#11-test-7--key-rotation)
12. [Test 8 — Key Wipe](#12-test-8--key-wipe)
13. [Test 9 — Directories inside the Vault](#13-test-9--directories-inside-the-vault)
14. [Test 10 — Delete a File](#14-test-10--delete-a-file)
15. [Test 11 — Manual Encrypt/Decrypt (outside FUSE)](#15-test-11--manual-encryptdecrypt-outside-fuse)
16. [Test 12 — make test (automated self-test)](#16-test-12--make-test-automated-self-test)
17. [Troubleshooting](#17-troubleshooting)
18. [Full Feature Checklist](#18-full-feature-checklist)

---

## 1. What You Need

| Requirement | Version | Check |
|-------------|---------|-------|
| Docker Desktop | Any recent | `docker --version` |
| Mac with Apple Silicon or Intel | — | — |

Everything else (gcc, libfuse, openssl, argon2 …) is installed inside the Docker container automatically.

You do **not** need to install anything on your Mac except Docker.

---

## 2. Build the Docker Image

From the project root (`/path/to/FuseVault`):

```bash
cd /path/to/FuseVault
docker build -t fusevault .
```

Expected output — the image installs Ubuntu 22.04 with all dependencies:
```
...
Step 4/4 : WORKDIR /workspace
 ---> Running in ...
Successfully built <image-id>
Successfully tagged fusevault:latest
```

This takes about 1–2 minutes the first time (downloading packages). Subsequent builds are cached.

---

## 3. Enter the Container

```bash
docker run -it \
  --privileged \
  --cap-add SYS_ADMIN \
  --device /dev/fuse \
  --name fusevault \
  -v "$(pwd):/workspace" \
  fusevault bash
```

**What each flag does:**

| Flag | Why it is needed |
|------|-----------------|
| `--privileged` | Allows FUSE to mount a filesystem inside the container |
| `--cap-add SYS_ADMIN` | Grants `mount` syscall permission |
| `--device /dev/fuse` | Passes the FUSE device from host into container |
| `-v "$(pwd):/workspace"` | Mounts your project directory inside the container at `/workspace` |

You are now root inside the container, in `/workspace`. Your project files are live-synced — edits on your Mac appear instantly inside the container.

**To re-enter a stopped container later:**
```bash
docker start -ai fusevault
```

---

## 4. Compile FuseVault

Inside the container:

```bash
make
```

Expected output:
```
gcc -Wall -Wextra -Wpedantic -D_FILE_OFFSET_BITS=64 -I/usr/include/fuse \
    src/myfs.c -lfuse -lssl -lcrypto -o myfs
```

Verify the binary exists:
```bash
ls -lh myfs
# -rwxr-xr-x 1 root root 47K ... myfs
```

**Other build targets:**
```bash
make debug    # Build with -g -DDEBUG + AddressSanitizer (disables mlock)
make clean    # Remove the binary
make lint     # Run cppcheck static analysis
make format   # Auto-format src/myfs.c with clang-format
make help     # List all targets
```

---

## 5. Test 1 — Basic Encrypt/Decrypt Round-Trip

This is the core proof that the filesystem works.

```bash
# Step 1: Generate a random 256-bit master key
./scripts/vault.sh keygen
```
Expected:
```
[INFO]  Random 256-bit key saved to /workspace/keys/vault.key
```

```bash
# Step 2: Mount the vault
./scripts/vault.sh mount
```
Expected:
```
[INFO]  Vault mounted at /workspace/mount
```

```bash
# Step 3: Write a secret file (FUSE intercepts this write and encrypts it)
echo "TOP SECRET — mission debrief at 0600" > mount/secret.txt

# Step 4: Read it back (FUSE intercepts this read and decrypts it)
cat mount/secret.txt
```
Expected:
```
TOP SECRET — mission debrief at 0600
```

```bash
# Step 5: Copy a larger file
cp /etc/passwd mount/passwd_copy.txt
diff /etc/passwd mount/passwd_copy.txt
```
Expected: no diff output (files are identical).

```bash
# Step 6: List files — names appear without .enc suffix
ls mount/
```
Expected:
```
passwd_copy.txt  secret.txt
```

```bash
# Step 7: Unmount
./scripts/vault.sh unmount
```
Expected:
```
[INFO]  Vault unmounted
```

---

## 6. Test 2 — Prove Encryption is Real

After Test 1, the vault is unmounted. The backing store contains the raw encrypted files.

```bash
# Look at the raw encrypted file — should be binary garbage
xxd store/secret.txt.enc | head -5
```
Expected output (binary — your values will differ):
```
00000000: 0d00 0000 a3f9 2b1c 8e45 d7f0 3391 cc4b  ......+..E..3..K
00000010: 2a88 91e5 7b3d 9f06 a1b2 c3d4 e5f6 0718  *...{=..........
00000020: 29a0 b1c2 d3e4 f500 1122 3344 5566 7788  )........"3DUfw.
```

The first 4 bytes are the plaintext length stored as a little-endian uint32. The next 64 bytes are the IV + encrypted FEK. Everything after is AES-256-CBC ciphertext.

```bash
# Try to read it as text — should be unreadable
cat store/secret.txt.enc
```
Expected: garbled binary output. **If you can read your secret text here, encryption is broken.**

```bash
# Re-mount and verify the file is still readable
./scripts/vault.sh mount
cat mount/secret.txt
```
Expected:
```
TOP SECRET — mission debrief at 0600
```

```bash
./scripts/vault.sh unmount
```

---

## 7. Test 3 — Passphrase-Derived Key (Argon2id)

```bash
# First, wipe the existing key so we start fresh
# (or just overwrite it)
./scripts/vault.sh keygen --passphrase
```

You will be prompted:
```
Enter passphrase:        ← type: mypassphrase (hidden)
Confirm passphrase:      ← type: mypassphrase again
[INFO]  Key derived via Argon2id and saved to /workspace/keys/vault.key
```

This runs Argon2id with parameters: `-t 3 -m 16 -p 4` (64 MB RAM, 3 iterations, 4 threads). It takes about 1 second — that is intentional. Attackers must also pay that cost per guess.

```bash
# Verify the derived key is binary (32 bytes), not text
wc -c keys/vault.key
```
Expected: `32 keys/vault.key`

```bash
# Mount and use the vault normally with the passphrase-derived key
./scripts/vault.sh mount
echo "Argon2 protected content" > mount/argon_test.txt
cat mount/argon_test.txt
./scripts/vault.sh unmount
```

**What to observe:** the vault works identically regardless of whether the key was random or Argon2-derived. The passphrase never touches disk — only the 32-byte derived binary key is written to `keys/vault.key`.

---

## 8. Test 4 — Audit Log & Hash-Chain Verification

Every operation is logged. Let's verify the log and its integrity.

```bash
# Do several operations to build up a log
./scripts/vault.sh mount
echo "File A" > mount/a.txt
cat mount/a.txt
echo "File B" > mount/b.txt
rm mount/a.txt
./scripts/vault.sh unmount
```

```bash
# View the full audit log
./scripts/vault.sh log
```
Expected output (timestamps and hashes will differ):
```
[2025-03-24 10:15:33] [root] KEYGEN passphrase-derived PREV=GENESIS HASH=a3f9...
[2025-03-24 10:15:41] [root] MOUNT /workspace/mount PREV=a3f9... HASH=b812...
[2025-03-24 10:15:41] [root] MOUNT /workspace/store PREV=b812... HASH=c490...
[2025-03-24 10:15:55] [root] CREATE /a.txt PREV=c490... HASH=d107...
[2025-03-24 10:15:55] [root] WRITE /a.txt PREV=d107... HASH=e2f8...
[2025-03-24 10:15:58] [root] OPEN /a.txt PREV=e2f8... HASH=f3a9...
[2025-03-24 10:15:58] [root] READ /a.txt PREV=f3a9... HASH=0411...
...
```

```bash
# View just the last 5 entries
./scripts/vault.sh log --tail 5
```

```bash
# Verify the hash chain — every entry should be OK
./scripts/vault.sh verify-log
```
Expected:
```
Line 1: OK      [2025-03-24 10:15:33] [root] KEYGEN passphrase-derived PREV=GENESIS HASH=...
Line 2: OK      [2025-03-24 10:15:41] [root] MOUNT ...
...
Summary: 12 OK | 0 TAMPERED
```

---

## 9. Test 5 — Tamper Detection

This test proves the audit log detects modification.

```bash
# First verify all is OK
./scripts/vault.sh verify-log
# Note: Summary: N OK | 0 TAMPERED

# Now manually edit one log entry to simulate an attacker covering their tracks
nano logs/vault_audit.log
# Find a line that says WRITE and change it to READ
# Save and exit (Ctrl+X, Y, Enter in nano)

# Re-run verification — it should catch the tamper
./scripts/vault.sh verify-log
```
Expected:
```
Line 5: OK      ...
Line 6: TAMPERED  [2025-03-24 10:15:55] [root] READ /a.txt ...
           Hash mismatch: expected 4d9e...
Line 7: TAMPERED  [2025-03-24 10:15:58] [root] OPEN /a.txt ...
           PREV mismatch: expected e2f8...
...
Summary: 5 OK | 7 TAMPERED
```

Notice: tampering one line breaks **all subsequent entries** too, because each entry's `PREV` field no longer matches.

**Restore the log to its original state:**
```bash
# Use git to restore, or simply accept that the log now shows tampered entries
# (In a real deployment you would not be able to restore — that's the point)
```

---

## 10. Test 6 — Auto-Unmount on Idle

```bash
# Mount with a 1-minute idle timeout (use 1 minute for testing)
./scripts/vault.sh mount --idle-timeout 1

# Check that the watchdog is running
./scripts/vault.sh status
```
Expected:
```
=== FuseVault Status ===
Mount:    MOUNTED at /workspace/mount
Key:      PRESENT (/workspace/keys/vault.key)
Log:      N entries (/workspace/logs/vault_audit.log)
Watchdog: active (PID 12345)
```

```bash
# Use the vault so the timer resets
echo "keeping alive" > mount/alive.txt

# Now do nothing for 1 minute...
# After 1 minute of no activity, the vault auto-unmounts.

# Verify it unmounted:
./scripts/vault.sh status
```
Expected after timeout:
```
Mount:    NOT MOUNTED
Watchdog: not running
```

The audit log will contain an `AUTO_UNMOUNT` entry with the timeout value.

---

## 11. Test 7 — Key Rotation

Key rotation re-encrypts all existing files with a completely new key. This is used when a key may have been compromised.

```bash
# Start with some files
./scripts/vault.sh mount
echo "File before rotation" > mount/old_file.txt
./scripts/vault.sh unmount

# Note the current .enc file's contents for comparison
xxd store/old_file.txt.enc | head -3 > /tmp/before_rotation.txt

# Rotate the key
./scripts/vault.sh rotate
```
Expected:
```
[INFO]  Rotating encryption key...
[INFO]  Random 256-bit key saved to /workspace/keys/vault.key
[INFO]  Key rotation complete. All files re-encrypted with new key.
```

```bash
# The .enc file should now have DIFFERENT bytes (new key, new IV, new FEK)
xxd store/old_file.txt.enc | head -3 > /tmp/after_rotation.txt
diff /tmp/before_rotation.txt /tmp/after_rotation.txt
```
Expected: the hex dump is completely different.

```bash
# But the plaintext should still be readable
./scripts/vault.sh mount
cat mount/old_file.txt
```
Expected:
```
File before rotation
```

```bash
./scripts/vault.sh unmount
```

---

## 12. Test 8 — Key Wipe

```bash
# First write something and unmount
./scripts/vault.sh mount
echo "soon to be unrecoverable" > mount/doomed.txt
./scripts/vault.sh unmount

# Wipe the key
./scripts/vault.sh wipe
```
You will see:
```
[WARN]  This will permanently destroy the master key.
[WARN]  ALL ENCRYPTED DATA WILL BE UNRECOVERABLE without a backup.
Type CONFIRM to proceed:
```
Type anything other than `CONFIRM` — the wipe should abort:
```
[INFO]  Aborted — key not wiped
```

Run it again and type `CONFIRM`:
```
[INFO]  Key wiped securely
```

```bash
# Try to mount — should fail (no key)
./scripts/vault.sh mount
```
Expected:
```
[ERROR] Key not found. Run: vault keygen
```

```bash
# Verify the key file is gone
ls keys/
# (empty)

# The backing store files are still there but permanently unreadable
ls store/
# doomed.txt.enc   old_file.txt.enc   ...

xxd store/doomed.txt.enc | head -3
# Binary garbage — unrecoverable without the key
```

**Recovery:** you must run `vault keygen` to create a new key, but the existing encrypted files cannot be decrypted with the new key. This is by design — wiping the key destroys access permanently.

---

## 13. Test 9 — Directories inside the Vault

```bash
./scripts/vault.sh keygen
./scripts/vault.sh mount

# Create a directory structure inside the vault
mkdir mount/documents
mkdir mount/documents/private
echo "nested file" > mount/documents/private/note.txt

# List recursively
ls -R mount/
```
Expected:
```
mount/:
documents

mount/documents:
private

mount/documents/private:
note.txt
```

```bash
# Read the nested file
cat mount/documents/private/note.txt
```
Expected:
```
nested file
```

```bash
# Verify the backing store mirrors the directory structure with .enc files
find store/ -type f
```
Expected:
```
store/documents/private/note.txt.enc
```

```bash
# Remove a directory (must be empty first)
rm mount/documents/private/note.txt
rmdir mount/documents/private
rmdir mount/documents

./scripts/vault.sh unmount
```

---

## 14. Test 10 — Delete a File

```bash
./scripts/vault.sh mount
echo "delete me" > mount/temp.txt
ls mount/
# temp.txt

rm mount/temp.txt
ls mount/
# (empty)

# Verify the .enc file is gone from the backing store
ls store/
# (empty — temp.txt.enc should be gone)

./scripts/vault.sh unmount
```

---

## 15. Test 11 — Manual Encrypt/Decrypt (outside FUSE)

The vault manager also has `encrypt` and `decrypt` commands that work directly with `openssl enc` — no FUSE mount needed.

```bash
./scripts/vault.sh keygen

# Create a plain file
echo "manual encryption test" > /tmp/plaintext.txt

# Encrypt it manually
./scripts/vault.sh encrypt /tmp/plaintext.txt
ls /tmp/plaintext.txt.enc
# file exists

# Remove the original
rm /tmp/plaintext.txt

# Decrypt it
./scripts/vault.sh decrypt /tmp/plaintext.txt.enc

# Read the decrypted result
cat /tmp/plaintext.txt
```
Expected:
```
manual encryption test
```

Note: manual `encrypt`/`decrypt` uses `openssl enc -aes-256-cbc -pbkdf2` with the master key file as a passphrase source — these files are **not** FUSE-compatible (different format than the FUSE backing store). They are for standalone file encryption only.

---

## 16. Test 12 — make test (automated self-test)

```bash
make test
```

This runs the complete automated round-trip:
1. Generates a fresh key
2. Mounts the vault
3. Writes a test file
4. Reads it back and verifies the content matches
5. Unmounts

Expected:
```
=== FuseVault Self-Test ===
[INFO]  Random 256-bit key saved to /workspace/keys/vault.key
[INFO]  Vault mounted at /workspace/mount
READ/WRITE: PASS
[INFO]  Vault unmounted
=== Self-test PASSED ===
```

---

## 17. Troubleshooting

### "myfs binary not found. Run: make"
```bash
make
```

### "Key not found. Run: vault keygen"
```bash
./scripts/vault.sh keygen
```

### "Vault did not mount within 3 seconds"
Usually means FUSE is not available. Check:
```bash
ls /dev/fuse
# Should exist. If not, your docker run command is missing --device /dev/fuse
```
Also verify the container was launched with `--privileged`.

### "fusermount: fuse device not found"
```bash
modprobe fuse   # (may help inside some containers)
```
If that doesn't work, ensure you used `--device /dev/fuse` in the `docker run` command.

### Vault is busy / cannot unmount
```bash
# Find what has files open inside the mount
lsof | grep workspace/mount

# Kill any blocking process
kill <PID>

# Then retry unmount
./scripts/vault.sh unmount

# Force unmount if still stuck
fusermount -uz mount/
```

### verify-log shows all entries as TAMPERED
This happens if entries were written by C code and verified by shell (or vice versa) with a subtle format mismatch. Check that the log file was not modified outside the vault tools. If starting fresh, delete the log:
```bash
rm logs/vault_audit.log
```

### Container was removed
```bash
# Remove old container
docker rm fusevault

# Create a new one
docker run -it --privileged --cap-add SYS_ADMIN --device /dev/fuse \
  --name fusevault -v "$(pwd):/workspace" fusevault bash
```

---

## 18. Full Feature Checklist

Use this to confirm every feature from the project guide is working:

### Core Filesystem (Prompt 2)
- [ ] `myfs_getattr` — `ls -la mount/` shows correct file sizes
- [ ] `myfs_readdir` — `ls mount/` shows clean names (no `.enc` suffix)
- [ ] `myfs_open` — opening a file is logged as `OPEN` in the audit log
- [ ] `myfs_read` — `cat mount/file.txt` decrypts and returns plaintext
- [ ] `myfs_write` — `echo "x" > mount/file.txt` encrypts and stores as `.enc`
- [ ] `myfs_create` — `touch mount/new.txt` creates a `.enc` backing file
- [ ] `myfs_unlink` — `rm mount/file.txt` removes the `.enc` file
- [ ] `myfs_mkdir` — `mkdir mount/dir` creates directory in backing store
- [ ] `myfs_rmdir` — `rmdir mount/dir` removes directory from backing store
- [ ] `myfs_truncate` — `truncate -s 0 mount/file.txt` truncates and re-encrypts

### Shell Vault Manager (Prompt 3)
- [ ] `vault mount` — mounts at `mount/`
- [ ] `vault unmount` — unmounts cleanly
- [ ] `vault status` — shows mount, key, log line count
- [ ] `vault keygen` — creates random 32-byte binary key
- [ ] `vault rotate` — re-encrypts all files with new key
- [ ] `vault wipe` — requires typing `CONFIRM`, then destroys key
- [ ] `vault encrypt <file>` — manual openssl encryption
- [ ] `vault decrypt <file.enc>` — manual openssl decryption
- [ ] `vault log` — shows audit log
- [ ] `vault log --tail N` — shows last N entries
- [ ] Color output — green/red/yellow in terminal

### Argon2 Key Derivation (Prompt 4)
- [ ] `vault keygen --passphrase` — derives key from passphrase via Argon2id
- [ ] `vault passphrase` — changes passphrase, backs up old key
- [ ] Passphrase never logged or stored
- [ ] Key file is exactly 32 binary bytes

### Hash-Chained Audit Log (Prompt 5)
- [ ] Each log entry has `PREV=` and `HASH=` fields
- [ ] First entry has `PREV=GENESIS`
- [ ] `vault verify-log` confirms all entries OK on unmodified log
- [ ] `vault verify-log` detects a manually edited entry as TAMPERED

### Auto-Unmount on Idle (Prompt 6)
- [ ] `vault mount --idle-timeout N` starts watchdog
- [ ] `vault status` shows Watchdog PID
- [ ] Vault auto-unmounts after N minutes with no filesystem activity
- [ ] Auto-unmount is recorded in audit log as `AUTO_UNMOUNT`

### Per-File Envelope Encryption (Prompt 7)
- [ ] Two writes of identical content produce different `.enc` file bytes (different FEK + IV each time)
- [ ] `xxd store/file.txt.enc | head -1` shows 68 bytes of header before ciphertext

### Secure Memory Erasure (Prompt 8)
- [ ] Source: `OPENSSL_cleanse()` called after every FEK and plaintext use (see `src/myfs.c`)
- [ ] `mlock()` called on `master_key` at startup (non-DEBUG builds)
- [ ] `destroy()` callback cleanses and unlocks master key on unmount

### Build System (Prompt 9)
- [ ] `make` — builds successfully
- [ ] `make debug` — builds with AddressSanitizer
- [ ] `make clean` — removes binary
- [ ] `make install` — copies to `/usr/local/bin`
- [ ] `make test` — automated self-test passes
- [ ] `make lint` — cppcheck runs without errors
- [ ] `make format` — clang-format runs
- [ ] `make help` — prints all targets

### Documentation (Prompt 10)
- [ ] `README.md` — architecture diagram, security model, all commands, file format diagram
- [ ] `TESTING.md` (this file) — step-by-step guide to run and test every feature

---

## Quick Reference: Full Session from Zero

```bash
# On your Mac terminal:
cd /path/to/FuseVault
docker build -t fusevault .
docker run -it --privileged --cap-add SYS_ADMIN --device /dev/fuse \
  --name fusevault -v "$(pwd):/workspace" fusevault bash

# Inside the container:
make
./scripts/vault.sh keygen
./scripts/vault.sh mount
echo "hello vault" > mount/hello.txt
cat mount/hello.txt
./scripts/vault.sh unmount
xxd store/hello.txt.enc | head
./scripts/vault.sh mount
cat mount/hello.txt
./scripts/vault.sh verify-log
./scripts/vault.sh log
./scripts/vault.sh unmount
```

That sequence covers build → key generation → mount → write → read → unmount → inspect raw ciphertext → re-mount → verify → view log → clean shutdown.
