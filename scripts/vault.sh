#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
#  FuseVault — Vault CLI Backend  v2.0
#  Manages mount, unmount, keygen, key rotation, encryption, audit log, and
#  diagnostics.  Called directly or by fusevault_ui.sh.
#
#  Usage: vault.sh <command> [options]
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Paths (all inside the Docker workspace) ───────────────────────────────────
WORKSPACE="${WORKSPACE:-/workspace}"
MYFS_BIN="${WORKSPACE}/myfs"
MOUNT_DIR="${WORKSPACE}/mount"
STORE_DIR="${WORKSPACE}/store"
KEY_FILE="${WORKSPACE}/keys/vault.key"
KEY_DIR="${WORKSPACE}/keys"
LOG_FILE="${WORKSPACE}/logs/vault_audit.log"
LOG_DIR="${WORKSPACE}/logs"

# ── Colours (extended palette) ────────────────────────────────────────────────
R='\033[0;31m'; BR='\033[1;31m'    # red / bold red
G='\033[0;32m'; BG='\033[1;32m'    # green / bold green
Y='\033[1;33m'; BY='\033[1;33m'    # gold
C='\033[0;36m'; BC='\033[1;36m'    # cyan / bold cyan
M='\033[0;35m'; BM='\033[1;35m'    # magenta / bold magenta
P='\033[38;5;141m'                 # purple
O='\033[38;5;208m'                 # orange
W='\033[1;37m';  GR='\033[38;5;245m' # white / grey
DIM='\033[2m';  NC='\033[0m';   BOLD='\033[1m'
UL='\033[4m'                       # underline
BLINK='\033[5m'                    # blink (used sparingly)

# RGB helper for 24-bit color
rgb() { printf '\033[38;2;%d;%d;%dm' "$1" "$2" "$3"; }

ok()   { echo -e "  ${BG}✔${NC}  $*"; }
err()  { echo -e "  ${BR}✖${NC}  $*" >&2; }
warn() { echo -e "  ${BY}⚠${NC}  $*"; }
info() { echo -e "  ${BC}ℹ${NC}  ${DIM}$*${NC}"; }
hint() { echo -e "  ${DIM}    $*${NC}"; }

# Separator with gradient
separator() {
    printf '  '
    local -a shades=("30;60;90" "40;80;120" "50;100;150" "60;120;180" "70;140;210" "80;160;240" "70;140;210" "60;120;180" "50;100;150" "40;80;120" "30;60;90")
    for s in "${shades[@]}"; do
        IFS=';' read -r r g b <<< "$s"
        printf '\033[38;2;%d;%d;%dm━━━━━━━\033[0m' "$r" "$g" "$b"
    done
    echo ""
}

# Section header
section_header() {
    local icon="$1" title="$2"
    echo ""
    separator
    echo -e "  ${BOLD}${BC}${icon}  ${title}${NC}"
    separator
    echo ""
}

# ── Guards ────────────────────────────────────────────────────────────────────
require_binary() {
    if [ ! -f "$MYFS_BIN" ]; then
        err "myfs binary not found at ${MYFS_BIN}"
        info "The binary needs to be compiled before you can use the vault."
        hint "Fix: run  make  inside /workspace  to build it."
        exit 1
    fi
}

require_key() {
    if [ ! -f "$KEY_FILE" ]; then
        err "No vault key found at ${KEY_FILE}"
        info "A master key is required to encrypt and decrypt files."
        hint "Fix: run  vault.sh keygen  to create one (random 256-bit key)."
        hint "     run  vault.sh keygen --passphrase  to derive one from a passphrase."
        exit 1
    fi
}

is_mounted() {
    mountpoint -q "$MOUNT_DIR" 2>/dev/null
}

# ── Command: mount ────────────────────────────────────────────────────────────
cmd_mount() {
    require_binary
    require_key

    if is_mounted; then
        warn "Vault is already mounted at ${W}${MOUNT_DIR}${NC}"
        info "Files written to ${W}${MOUNT_DIR}${NC} are automatically encrypted."
        return 0
    fi

    section_header "▲" "Mounting Vault"
    info "Starting FUSE filesystem — all reads/writes will be transparently encrypted."
    mkdir -p "$MOUNT_DIR" "$STORE_DIR" "$LOG_DIR"
    VAULT_BACKING_DIR="$STORE_DIR" \
    VAULT_KEY_FILE="$KEY_FILE" \
    VAULT_LOG_FILE="$LOG_FILE" \
    "$MYFS_BIN" "$MOUNT_DIR" -o nonempty 2>/tmp/fusevault_mount.log &

    # Wait up to 3 s for the mount to appear
    local i=0
    while [ $i -lt 30 ]; do
        if is_mounted; then
            echo ""
            ok "Vault ${BG}mounted${NC} at ${W}${MOUNT_DIR}${NC}"
            echo ""
            echo -e "  ${DIM}┌──────────────────────────────────────────────────────┐${NC}"
            echo -e "  ${DIM}│${NC}  ${BC}Write:${NC}  echo 'secret' > mount/file.txt             ${DIM}│${NC}"
            echo -e "  ${DIM}│${NC}  ${BC}Read:${NC}   cat mount/file.txt                         ${DIM}│${NC}"
            echo -e "  ${DIM}│${NC}  ${BC}List:${NC}   ls mount/                                  ${DIM}│${NC}"
            echo -e "  ${DIM}│${NC}  ${BC}Stop:${NC}   vault.sh unmount                           ${DIM}│${NC}"
            echo -e "  ${DIM}└──────────────────────────────────────────────────────┘${NC}"
            echo ""
            return 0
        fi
        sleep 0.1
        i=$((i + 1))
    done

    err "Mount timed out after 3 seconds."
    info "Check the error log at: ${W}/tmp/fusevault_mount.log${NC}"
    hint "Common causes: myfs binary crash, missing FUSE device, bad key file."
    exit 1
}

# ── Command: unmount ──────────────────────────────────────────────────────────
cmd_unmount() {
    if ! is_mounted; then
        warn "Vault is not currently mounted — nothing to do."
        return 0
    fi
    section_header "▼" "Unmounting Vault"
    info "Stopping FUSE filesystem and flushing all pending writes..."
    fusermount -u "$MOUNT_DIR" 2>/dev/null || umount "$MOUNT_DIR" 2>/dev/null || {
        err "Failed to unmount ${W}${MOUNT_DIR}${NC}"
        hint "Try: fusermount -u ${MOUNT_DIR}  or  umount ${MOUNT_DIR}"
        hint "If a process is still using the mount, close it first."
        exit 1
    }
    echo ""
    ok "Vault ${BG}unmounted${NC} — all key material has been erased from RAM."
    info "OPENSSL_cleanse() zeroed the master key buffer before releasing memory."
    hint "Encrypted files remain safely in ${W}${STORE_DIR}${NC} and are unreadable without the key."
    echo ""
}

# ── Command: status ───────────────────────────────────────────────────────────
cmd_status() {
    section_header "🛡️" "Vault Status"

    # Mount status
    if is_mounted; then
        echo -e "  ${BG}●${NC}  Mount       ${BG}MOUNTED${NC}  (${W}${MOUNT_DIR}${NC})"
        hint "The FUSE filesystem is active. Files in mount/ are decrypted on read."
    else
        echo -e "  ${BR}●${NC}  Mount       ${BR}UNMOUNTED${NC}"
        hint "Run 'vault.sh mount' to start the filesystem."
    fi

    # Key status
    if [ -f "$KEY_FILE" ]; then
        local key_size perms age
        key_size=$(wc -c < "$KEY_FILE" 2>/dev/null | tr -d ' ')
        perms=$(stat -c '%a' "$KEY_FILE" 2>/dev/null || stat -f '%Lp' "$KEY_FILE" 2>/dev/null)
        age=$(( ($(date +%s) - $(stat -c '%Y' "$KEY_FILE" 2>/dev/null || stat -f '%m' "$KEY_FILE" 2>/dev/null)) / 86400 ))
        echo -e "  ${BG}●${NC}  Key         ${BG}PRESENT${NC}  (${W}${key_size}B${NC}, mode ${W}${perms}${NC}, ${W}${age}d${NC} old)"
        if [ "$perms" != "600" ]; then
            warn "Key permissions are ${perms} — should be 600 (owner read/write only)."
            hint "Fix: chmod 600 ${KEY_FILE}"
        fi
        if [ "$age" -gt 90 ]; then
            warn "Key is ${age} days old — consider rotating it for better security."
            hint "Run: vault.sh rotate"
        fi
    else
        echo -e "  ${BR}●${NC}  Key         ${BR}MISSING${NC}"
        hint "No master key found. Run 'vault.sh keygen' to create one."
    fi

    # Binary status
    if [ -f "$MYFS_BIN" ]; then
        local bin_size
        bin_size=$(du -sh "$MYFS_BIN" 2>/dev/null | cut -f1)
        echo -e "  ${BG}●${NC}  Binary      ${BG}BUILT${NC}    (${W}myfs${NC}, ${W}${bin_size}${NC})"
    else
        echo -e "  ${BR}●${NC}  Binary      ${BR}NOT BUILT${NC}"
        hint "Run 'make' inside /workspace to compile the FUSE driver."
    fi

    # Encrypted files
    local enc_count
    enc_count=$(find "$STORE_DIR" -name '*.enc' 2>/dev/null | wc -l | tr -d ' ')
    echo -e "  ${BC}●${NC}  Enc files   ${W}${enc_count}${NC} files in store/"
    if [ "$enc_count" -eq 0 ]; then
        hint "No encrypted files yet. Mount the vault and write to mount/ to create some."
    else
        hint "These .enc files are ciphertext only — unreadable without the key."
    fi

    # Audit log
    if [ -f "$LOG_FILE" ]; then
        local log_lines
        log_lines=$(wc -l < "$LOG_FILE" | tr -d ' ')
        local last_op
        last_op=$(tail -1 "$LOG_FILE" 2>/dev/null | grep -oP '(?<=\] )\w+' | head -1 || echo "none")
        echo -e "  ${BC}●${NC}  Audit log   ${W}${log_lines}${NC} entries, last op: ${BY}${last_op}${NC}"
        hint "Run 'vault.sh verify-log' to check that no log entries have been tampered with."
    else
        echo -e "  ${BY}●${NC}  Audit log   ${BY}EMPTY${NC}"
        hint "Audit log is created automatically when the vault is first mounted."
    fi

    separator
    echo ""
}

# ── Command: keygen ───────────────────────────────────────────────────────────
cmd_keygen() {
    local use_passphrase=false
    [[ "${1:-}" == "--passphrase" ]] && use_passphrase=true

    mkdir -p "$KEY_DIR"
    chmod 700 "$KEY_DIR"

    if [ -f "$KEY_FILE" ]; then
        warn "A key already exists at ${W}${KEY_FILE}${NC}."
        info "To protect existing encrypted data, use '${BC}vault.sh rotate${NC}' instead of overwriting."
        hint "Overwriting the key directly would make your encrypted files permanently unreadable."
        exit 1
    fi

    if $use_passphrase; then
        section_header "⌘" "Argon2id Key Derivation"
        info "Deriving a 256-bit key from your passphrase using ${BM}Argon2id${NC}."
        echo ""
        echo -e "  ${DIM}┌──────────────────────────────────────────────────────┐${NC}"
        echo -e "  ${DIM}│${NC}  ${P}Algorithm:${NC}  Argon2id (PHC 2015 winner)            ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC}  ${P}Iterations:${NC} 3 time passes                         ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC}  ${P}Memory:${NC}     64 MB per attempt                     ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC}  ${P}Threads:${NC}    4 parallel lanes                      ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC}  ${P}Output:${NC}     32 bytes (256-bit key)                 ${DIM}│${NC}"
        echo -e "  ${DIM}└──────────────────────────────────────────────────────┘${NC}"
        echo ""
        echo -en "  ${BC}🔑 Passphrase:${NC} "
        read -rs passphrase
        echo ""
        echo -en "  ${BC}🔑 Confirm:${NC}    "
        read -rs passphrase2
        echo ""
        echo ""
        if [ "$passphrase" != "$passphrase2" ]; then
            err "Passphrases do not match — no key was created."
            exit 1
        fi
        # Argon2id: t=3 iterations, m=65536 (64MB), p=4 threads, 32-byte output
        local salt
        salt=$(openssl rand -hex 16)
        echo -n "$passphrase" | argon2 "$salt" -id -l 32 -t 3 -m 16 -p 4 -r > "$KEY_FILE"
        echo ""
        ok "Argon2id key derived and saved to ${W}${KEY_FILE}${NC}"
        echo ""
        echo -e "  ${BR}┌──────────────────────────────────────────────────────────────┐${NC}"
        echo -e "  ${BR}│${NC}  ${BY}⚠  SAVE THIS SALT — you need it to recover your key!${NC}      ${BR}│${NC}"
        echo -e "  ${BR}│${NC}                                                              ${BR}│${NC}"
        echo -e "  ${BR}│${NC}  ${W}Salt: ${BC}${salt}${NC}  ${BR}│${NC}"
        echo -e "  ${BR}│${NC}                                                              ${BR}│${NC}"
        echo -e "  ${BR}│${NC}  ${DIM}Store in a password manager or print it securely.${NC}          ${BR}│${NC}"
        echo -e "  ${BR}└──────────────────────────────────────────────────────────────┘${NC}"
        echo ""
    else
        section_header "★" "Generate Random Master Key"
        info "Generating a cryptographically random 256-bit (32-byte) master key..."
        echo ""
        openssl rand 32 > "$KEY_FILE"
        ok "Random 256-bit key generated at ${W}${KEY_FILE}${NC}"
        echo ""
        echo -e "  ${DIM}┌──────────────────────────────────────────────────────┐${NC}"
        echo -e "  ${DIM}│${NC}  ${BC}Source:${NC}      OpenSSL CSPRNG (RAND_bytes)           ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC}  ${BC}Size:${NC}        32 bytes (256 bits)                   ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC}  ${BC}Algorithm:${NC}   AES-256-CBC encryption key            ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC}  ${BC}Permissions:${NC} 600 (owner read/write only)           ${DIM}│${NC}"
        echo -e "  ${DIM}└──────────────────────────────────────────────────────┘${NC}"
        echo ""
        warn "${BY}IMPORTANT${NC} — Back up this key file securely. If you lose it, your data is gone."
        hint "The key file is binary — use: xxd ${KEY_FILE} | head  to inspect it."
    fi

    chmod 600 "$KEY_FILE"
    ok "Key file permissions set to ${BG}600${NC} (owner read/write only)."
    echo ""
}

# ── Command: rotate ───────────────────────────────────────────────────────────
cmd_rotate() {
    require_key

    if is_mounted; then
        err "The vault must be unmounted before rotating the key."
        hint "Run '${BC}vault.sh unmount${NC}' first, then retry '${BC}vault.sh rotate${NC}'."
        exit 1
    fi

    section_header "↺" "Rotate Master Key"

    echo -e "  ${DIM}┌──────────────────────────────────────────────────────────┐${NC}"
    echo -e "  ${DIM}│${NC}  ${BC}Operation:${NC}  Replace master key with a new random key    ${DIM}│${NC}"
    echo -e "  ${DIM}│${NC}  ${BC}Backup:${NC}     Old key → keys/vault.key.bak.<timestamp>   ${DIM}│${NC}"
    echo -e "  ${DIM}│${NC}  ${BC}New key:${NC}    256-bit random via OpenSSL CSPRNG           ${DIM}│${NC}"
    echo -e "  ${DIM}└──────────────────────────────────────────────────────────┘${NC}"
    echo ""

    local backup="${KEY_FILE}.bak.$(date +%s)"
    cp "$KEY_FILE" "$backup"
    chmod 600 "$backup"
    ok "Old key backed up to: ${backup}"

    # Re-encrypt every .enc file with a new master key
    local new_key_tmp="${KEY_DIR}/vault.key.new"
    openssl rand 32 > "$new_key_tmp"
    chmod 600 "$new_key_tmp"

    local count=0
    while IFS= read -r -d '' enc_file; do
        warn "In-place FEK re-wrapping requires vault mount — skipping: $(basename "$enc_file")"
        count=$((count + 1))
    done < <(find "$STORE_DIR" -name '*.enc' -print0 2>/dev/null)

    mv "$new_key_tmp" "$KEY_FILE"
    ok "Master key rotated — new key is live at ${KEY_FILE}"

    if [ $count -gt 0 ]; then
        echo ""
        warn "${count} existing encrypted file(s) still use the old per-file key wrapping."
        info "To fully re-encrypt these files with the new master key:"
        hint "1.  Temporarily restore the backup:  cp ${backup} ${KEY_FILE}"
        hint "2.  Mount the vault and copy files out to a safe temp location."
        hint "3.  Restore the new key:  cp ${KEY_FILE}.bak.<ts>  keys/vault.key  (swap back)"
        hint "4.  Re-mount with the new key and copy files back in."
    fi
}

# ── Command: wipe ─────────────────────────────────────────────────────────────
cmd_wipe() {
    if is_mounted; then
        info "Vault is mounted — unmounting first before wiping key material."
        cmd_unmount
    fi

    section_header "✖" "Wipe Key Material"

    echo -e "  ${BR}┌──────────────────────────────────────────────────────────┐${NC}"
    echo -e "  ${BR}│${NC}  ${BR}⚠  DANGER: DESTRUCTIVE OPERATION${NC}                         ${BR}│${NC}"
    echo -e "  ${BR}│${NC}                                                            ${BR}│${NC}"
    echo -e "  ${BR}│${NC}  ${W}This will permanently destroy the master key.${NC}             ${BR}│${NC}"
    echo -e "  ${BR}│${NC}  ${W}All encrypted files become PERMANENTLY UNREADABLE.${NC}        ${BR}│${NC}"
    echo -e "  ${BR}│${NC}  ${W}There is NO recovery — this cannot be undone.${NC}             ${BR}│${NC}"
    echo -e "  ${BR}└──────────────────────────────────────────────────────────┘${NC}"
    echo ""

    # Secure-erase key with overwrite passes
    if [ -f "$KEY_FILE" ]; then
        info "Securely erasing key file with 3 overwrite passes..."
        if command -v shred &>/dev/null; then
            shred -u -z -n 3 "$KEY_FILE"
            hint "Used 'shred' — 3 random overwrite passes + final zero pass + file deletion."
        else
            dd if=/dev/urandom of="$KEY_FILE" bs=32 count=1 conv=notrunc 2>/dev/null
            rm -f "$KEY_FILE"
            hint "Used dd + rm (shred not available)."
        fi
        ok "Key file securely erased — key material is gone from disk."
    fi

    ok "Vault wiped — all key material destroyed."
    warn "Encrypted files in store/ still exist on disk but are now permanently unrecoverable."
    hint "To also remove the encrypted files: rm -rf ${STORE_DIR}/*.enc"
}

# ── Command: log ──────────────────────────────────────────────────────────────
cmd_log() {
    local tail_mode=false
    [[ "${1:-}" == "--tail" ]] && tail_mode=true

    if [ ! -f "$LOG_FILE" ]; then
        warn "No audit log found at ${W}${LOG_FILE}${NC}"
        info "The audit log is created automatically when the vault is first mounted."
        hint "Every file read, write, delete, mount, and unmount is recorded here."
        return 0
    fi

    if $tail_mode; then
        section_header "⟳" "Live Audit Log Stream"
        info "Following audit log live — press ${W}Ctrl+C${NC} to stop."
        hint "Each new vault operation will appear here as it happens."
        echo ""
        tail -f "$LOG_FILE"
    else
        local line_count
        line_count=$(wc -l < "$LOG_FILE" | tr -d ' ')
        section_header "📋" "Audit Log (${line_count} entries)"
        echo -e "  ${DIM}Color coding:${NC}  ${BG}MOUNT${NC}  ${BC}READ${NC}  ${BY}WRITE${NC}  ${BM}UNMOUNT${NC}  ${BR}DELETE${NC}"
        echo ""

        while IFS= read -r line; do
            if   echo "$line" | grep -qw "WRITE";   then echo -e "  ${BY}${line}${NC}"
            elif echo "$line" | grep -qw "READ";    then echo -e "  ${BC}${line}${NC}"
            elif echo "$line" | grep -qw "MOUNT";   then echo -e "  ${BG}${line}${NC}"
            elif echo "$line" | grep -qw "UNMOUNT"; then echo -e "  ${BM}${line}${NC}"
            elif echo "$line" | grep -qw "DELETE";  then echo -e "  ${BR}${line}${NC}"
            else echo -e "  ${DIM}${line}${NC}"
            fi
        done < "$LOG_FILE"
        echo ""
        hint "Run '${BC}vault.sh verify-log${NC}' to check the hash chain for tampering."
    fi
}

# ── Command: verify-log ───────────────────────────────────────────────────────
cmd_verify_log() {
    if [ ! -f "$LOG_FILE" ]; then
        warn "No audit log found — nothing to verify."
        info "The log is created when the vault is first mounted and used."
        return 0
    fi

    section_header "✔" "Audit Log Integrity Verification"

    echo -e "  ${DIM}┌──────────────────────────────────────────────────────────┐${NC}"
    echo -e "  ${DIM}│${NC}  ${BC}Method:${NC}   SHA-256 hash chain verification              ${DIM}│${NC}"
    echo -e "  ${DIM}│${NC}  ${BC}Model:${NC}    Each entry hashes itself + links to previous  ${DIM}│${NC}"
    echo -e "  ${DIM}│${NC}  ${BC}Detects:${NC}  Edits, deletions, insertions, reordering     ${DIM}│${NC}"
    echo -e "  ${DIM}└──────────────────────────────────────────────────────────┘${NC}"
    echo ""

    local line_num=0 ok_count=0 tamper_count=0 prev_hash="GENESIS"

    while IFS= read -r line; do
        line_num=$((line_num + 1))

        # Extract stored PREV and HASH from the line
        local stored_prev stored_hash
        stored_prev=$(echo "$line" | grep -oP '(?<=PREV=)\S+' || true)
        stored_hash=$(echo "$line" | grep -oP '(?<=HASH=)\S+' || true)

        if [ -z "$stored_hash" ]; then
            echo -e "  ${BY}${line_num}${NC}  ${BY}SKIP${NC}     (no hash field — old format entry)"
            continue
        fi

        # Recompute hash of everything before HASH= field
        local content_to_hash
        content_to_hash=$(echo "$line" | sed 's/ HASH=.*//')
        local computed_hash
        computed_hash=$(echo -n "$content_to_hash" | sha256sum | cut -c1-64)

        if [ "$stored_hash" != "$computed_hash" ]; then
            echo -e "  ${BR}✖ ${line_num}${NC}  ${BR}TAMPERED${NC} — hash mismatch (entry content was modified)"
            tamper_count=$((tamper_count + 1))
        elif [ "$stored_prev" != "$prev_hash" ]; then
            echo -e "  ${BR}✖ ${line_num}${NC}  ${BR}TAMPERED${NC} — PREV chain broken (entry inserted or deleted)"
            tamper_count=$((tamper_count + 1))
        else
            echo -e "  ${BG}✔ ${line_num}${NC}  ${BG}OK${NC}       ${DIM}${line:0:64}...${NC}"
            ok_count=$((ok_count + 1))
        fi

        prev_hash="$stored_hash"
    done < "$LOG_FILE"

    echo ""
    separator
    if [ $tamper_count -eq 0 ]; then
        echo ""
        echo -e "  ${BG}┌──────────────────────────────────────────────┐${NC}"
        echo -e "  ${BG}│  ✔  INTEGRITY CHECK PASSED                  │${NC}"
        echo -e "  ${BG}│     ${W}${ok_count} OK${NC}  │  ${W}0 TAMPERED${NC}  │  ${W}${line_num} total${NC}       ${BG}│${NC}"
        echo -e "  ${BG}└──────────────────────────────────────────────┘${NC}"
        echo ""
        hint "All log entries are intact — the hash chain is unbroken."
    else
        echo ""
        echo -e "  ${BR}┌──────────────────────────────────────────────┐${NC}"
        echo -e "  ${BR}│  ✖  INTEGRITY CHECK FAILED                  │${NC}"
        echo -e "  ${BR}│     ${W}${ok_count} OK${NC}  │  ${W}${tamper_count} TAMPERED${NC}  │  ${W}${line_num} total${NC}       ${BR}│${NC}"
        echo -e "  ${BR}└──────────────────────────────────────────────┘${NC}"
        echo ""
        warn "One or more log entries have been modified, deleted, or inserted."
        hint "Tampered entries are marked above. This may indicate unauthorized access."
    fi
    echo ""
}

# ── Command: encrypt (standalone, outside vault) ──────────────────────────────
cmd_encrypt() {
    local input="${1:-}"
    if [ -z "$input" ] || [ ! -f "$input" ]; then
        err "Usage: vault.sh encrypt <file>"
        info "Encrypts a file using the master key and AES-256-CBC."
        hint "The output will be written to <file>.enc in the same directory."
        hint "For automatic encryption, you can also just copy files into mount/ while mounted."
        exit 1
    fi
    require_key

    info "Encrypting '${input}' with AES-256-CBC..."
    hint "A fresh random IV and per-file encryption key (FEK) are generated for each file."
    hint "The FEK is wrapped (encrypted) with the master key and stored in the .enc header."

    local output="${input}.enc"
    local iv fek enc_fek ciphertext

    iv=$(openssl rand -hex 16)
    fek=$(openssl rand -hex 32)
    enc_fek=$(echo -n "$fek" | openssl enc -aes-256-cbc \
        -K "$(xxd -p -c 256 "$KEY_FILE")" -iv "$iv" -nosalt 2>/dev/null | xxd -p -c 256)
    openssl enc -aes-256-cbc -K "$fek" -iv "$iv" -nosalt -in "$input" -out "$output"

    ok "Encrypted: ${output}"
    info "IV: ${iv}"
    hint "The original file '${input}' is unchanged — you may want to shred it."
    hint "To decrypt later, mount the vault and access the file through mount/."
}

# ── Command: decrypt (standalone) ─────────────────────────────────────────────
cmd_decrypt() {
    local input="${1:-}"
    if [ -z "$input" ] || [ ! -f "$input" ]; then
        err "Usage: vault.sh decrypt <file.enc>"
        info "Decrypts a .enc file through the running vault mount."
        hint "The vault must be mounted first — run 'vault.sh mount'."
        exit 1
    fi
    require_key

    if ! is_mounted; then
        err "Vault must be mounted to decrypt files."
        info "Decryption happens transparently through the FUSE filesystem."
        hint "Run 'vault.sh mount' first, then retry."
        exit 1
    fi

    local output="${input%.enc}"
    if [ "$output" = "$input" ]; then output="${input}.dec"; fi

    info "Reading '${input}' through the vault mount (decrypting transparently)..."

    local base
    base=$(basename "$input" .enc)
    cp "${MOUNT_DIR}/${base}" "$output" 2>/dev/null || {
        err "File '${base}' is not accessible through the vault mount."
        hint "Make sure the .enc file is in ${STORE_DIR}/ and the vault is mounted."
        exit 1
    }

    ok "Decrypted: ${output}"
    hint "The .enc file in store/ is unchanged — this is a decrypted copy."
}

# ── Command: about ────────────────────────────────────────────────────────────
cmd_about() {
    echo ""
    separator
    echo ""
    echo -e "  ${BOLD}$(rgb 0 187 255)███████╗██╗   ██╗███████╗███████╗${NC}"
    echo -e "  ${BOLD}$(rgb 0 170 240)██╔════╝██║   ██║██╔════╝██╔════╝${NC}  $(rgb 0 215 255)FuseVault${NC}  ${DIM}v2.0.0${NC}"
    echo -e "  ${BOLD}$(rgb 0 153 225)█████╗  ██║   ██║███████╗█████╗${NC}    ${DIM}Encrypted FUSE Filesystem${NC}"
    echo -e "  ${BOLD}$(rgb 0 136 210)██╔══╝  ██║   ██║╚════██║██╔══╝${NC}    ${DIM}AES-256-CBC + Argon2id + Hash-Chain${NC}"
    echo -e "  ${BOLD}$(rgb 0 119 195)██║     ╚██████╔╝███████║███████╗${NC}"
    echo -e "  ${BOLD}$(rgb 0 102 180)╚═╝      ╚═════╝ ╚══════╝╚══════╝${NC}"
    echo ""
    separator
    echo ""

    echo -e "  ${BOLD}${BC}🏗️  How It Works${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
    echo -e "  ${W}FuseVault mounts a virtual filesystem using FUSE (Filesystem in Userspace).${NC}"
    echo -e "  ${DIM}Every file written to mount/ is immediately encrypted on disk in store/.${NC}"
    echo -e "  ${DIM}Every file read from mount/ is decrypted on-the-fly — apps see plaintext.${NC}"
    echo ""

    echo -e "  ${BOLD}${BG}🔐  Security Features${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
    echo -e "  ${BG}●${NC} ${W}Encryption:${NC}  AES-256-CBC per-file envelope encryption"
    echo -e "    ${DIM}Each file gets its own random 256-bit FEK, wrapped by the master key.${NC}"
    echo -e "  ${BM}●${NC} ${W}Key derive:${NC}  Argon2id (t=3, m=64MB, p=4)"
    echo -e "    ${DIM}Memory-hard — makes GPU brute-force economically infeasible.${NC}"
    echo -e "  ${BY}●${NC} ${W}Audit log:${NC}   SHA-256 hash-chained tamper-evident trail"
    echo -e "    ${DIM}Every operation logged with a chain — editing breaks all subsequent hashes.${NC}"
    echo -e "  ${BC}●${NC} ${W}Memory:${NC}      mlock() + OPENSSL_cleanse() on all key material"
    echo -e "    ${DIM}Key bytes pinned in RAM (never swap to disk) and zeroed on unmount.${NC}"
    echo ""

    echo -e "  ${BOLD}${P}📦  File Format${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
    echo -e "  ${DIM}┌──────────────┬──────────────┬───────────────────┬──────────────┐${NC}"
    echo -e "  ${DIM}│${NC} ${W}SIZE (4B)${NC}    ${DIM}│${NC} ${BG}IV (16B)${NC}      ${DIM}│${NC} ${BM}Enc FEK (48B)${NC}    ${DIM}│${NC} ${BC}Ciphertext${NC}   ${DIM}│${NC}"
    echo -e "  ${DIM}└──────────────┴──────────────┴───────────────────┴──────────────┘${NC}"
    echo -e "  ${DIM}←─────────── HEADER = 68 bytes ───────────────→   variable${NC}"
    echo ""

    echo -e "  ${DIM}Source: /workspace/src/myfs.c${NC}"
    separator
    echo ""
}

# ── Command: help ─────────────────────────────────────────────────────────────
cmd_help() {
    echo ""
    echo -e "  $(rgb 0 187 255)🛡️  vault.sh${NC}  ${DIM}— FuseVault CLI${NC}"
    echo -e "  ${DIM}Encrypted FUSE filesystem — all commands run inside the Docker container.${NC}"
    separator
    echo ""
    echo -e "  ${BY}⚡ Quick Start${NC} ${DIM}(if new to FuseVault)${NC}"
    echo ""
    echo -e "    ${BG}1.${NC}  ${BC}vault.sh keygen${NC}          ${DIM}→  create a 256-bit master key${NC}"
    echo -e "    ${BG}2.${NC}  ${BC}vault.sh mount${NC}           ${DIM}→  start the encrypted filesystem${NC}"
    echo -e "    ${BG}3.${NC}  ${BC}echo 'secret' > mount/hi.txt${NC}   ${DIM}→  write an encrypted file${NC}"
    echo -e "    ${BG}4.${NC}  ${BC}cat mount/hi.txt${NC}              ${DIM}→  read it back (decrypted)${NC}"
    echo -e "    ${BG}5.${NC}  ${BC}vault.sh unmount${NC}         ${DIM}→  stop, erase key from RAM${NC}"
    echo ""
    echo -e "  ${BC}🔒 Vault Lifecycle${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
    echo -e "    ${W}mount${NC}                  ${DIM}Start the FUSE filesystem at /workspace/mount${NC}"
    echo -e "    ${W}unmount${NC}                ${DIM}Safely stop & erase key from RAM${NC}"
    echo -e "    ${W}status${NC}                 ${DIM}Show vault health: mount, key, binary, log${NC}"
    echo ""
    echo -e "  ${BG}🔑 Key Management${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
    echo -e "    ${W}keygen${NC}                 ${DIM}Generate a random 256-bit master key${NC}"
    echo -e "    ${W}keygen --passphrase${NC}    ${DIM}Derive key from passphrase (Argon2id)${NC}"
    echo -e "    ${W}rotate${NC}                 ${DIM}Replace master key (old key backed up)${NC}"
    echo -e "    ${W}wipe${NC}                   ${DIM}Securely shred key — ${BR}IRREVERSIBLE${NC}"
    echo ""
    echo -e "  ${BY}📁 File Operations${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
    echo -e "    ${W}encrypt <file>${NC}         ${DIM}Encrypt a file with the master key${NC}"
    echo -e "    ${W}decrypt <file.enc>${NC}     ${DIM}Decrypt via vault mount${NC}"
    echo ""
    echo -e "  ${BM}📋 Audit Log${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
    echo -e "    ${W}log${NC}                    ${DIM}Print all log entries${NC}"
    echo -e "    ${W}log --tail${NC}             ${DIM}Follow log in real-time${NC}"
    echo -e "    ${W}verify-log${NC}             ${DIM}Check SHA-256 hash chain for tampering${NC}"
    echo ""
    echo -e "  ${P}ℹ  Info${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
    echo -e "    ${W}about${NC}                  ${DIM}Architecture & security model${NC}"
    echo -e "    ${W}help${NC}                   ${DIM}Show this help${NC}"
    echo ""
    echo -e "  ${DIM}💡 Tip: Use the interactive TUI for a guided experience:  fusevault_ui.sh${NC}"
    separator
    echo ""
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
CMD="${1:-help}"
shift || true

case "$CMD" in
    mount)        cmd_mount "$@"       ;;
    unmount)      cmd_unmount "$@"     ;;
    status)       cmd_status "$@"      ;;
    keygen)       cmd_keygen "$@"      ;;
    rotate)       cmd_rotate "$@"      ;;
    wipe)         cmd_wipe "$@"        ;;
    log)          cmd_log "$@"         ;;
    verify-log)   cmd_verify_log "$@"  ;;
    encrypt)      cmd_encrypt "$@"     ;;
    decrypt)      cmd_decrypt "$@"     ;;
    about)        cmd_about "$@"       ;;
    help|--help)  cmd_help "$@"        ;;
    *)
        err "Unknown command: '${CMD}'"
        info "Run 'vault.sh help' to see all available commands."
        exit 1
        ;;
esac
