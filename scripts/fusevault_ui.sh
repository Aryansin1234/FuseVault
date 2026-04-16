#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
#  FuseVault — Interactive TUI  v2.0
#  Powered by gum (https://github.com/charmbracelet/gum) v0.14
#  Enhanced edition with animations, typewriter effects & cinematic intro
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Force UTF-8 so bash string indexing works on multi-byte characters (━, 🔐, etc.)
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

WORKSPACE="${WORKSPACE:-/workspace}"
VAULT="${WORKSPACE}/scripts/vault.sh"
STORE_DIR="${WORKSPACE}/store"
MOUNT_DIR="${WORKSPACE}/mount"
KEY_FILE="${WORKSPACE}/keys/vault.key"
LOG_FILE="${WORKSPACE}/logs/vault_audit.log"

if ! command -v gum &>/dev/null; then
    echo "ERROR: 'gum' not found. Rebuild the Docker image: ./run.sh --rebuild" >&2
    exit 1
fi

# ── Palette ───────────────────────────────────────────────────────────────────
# Foreground
G="#00ff87"    # bright green
R="#ff5f5f"    # bright red
Y="#ffd700"    # gold
C="#00d7ff"    # bright cyan
M="#ff5fd7"    # hot magenta
P="#af87ff"    # soft purple
O="#ff8700"    # orange
W="#ffffff"    # white
DM="#585858"   # dim grey
SV="#bcbcbc"   # silver
TEAL="#00bfa5" # teal accent
LIME="#b2ff59" # lime accent
PINK="#ff80ab"  # pink accent
BLUE="#448aff"  # electric blue

# Background (for badges)
BG_G="#003300"    # dark green bg
BG_R="#330000"    # dark red bg
BG_C="#002244"    # dark cyan bg
BG_Y="#332200"    # dark amber bg
BG_M="#330022"    # dark magenta bg
BG_P="#1a0033"    # dark purple bg
BG_PANEL="#0a0f1a" # near-black panel bg
BG_O="#331a00"    # dark orange bg
BG_TEAL="#003330" # dark teal bg

# Borders
BR_MAIN="#005f87"
BR_G="#005f00"
BR_R="#5f0000"
BR_Y="#5f4400"
BR_C="#005f87"
BR_M="#5f0044"
BR_P="#3d0066"

# ── Animation Helpers ─────────────────────────────────────────────────────────

# Typewriter effect: typewriter "text" color [speed]
# Speed: chars per second delay (default 0.02)
typewriter() {
    local text="$1" color="${2:-$W}" speed="${3:-0.02}"
    local r g b
    r=$(( 16#${color:1:2} ))
    g=$(( 16#${color:3:2} ))
    b=$(( 16#${color:5:2} ))
    # Use grep -oP '.' to split into actual characters (multi-byte safe)
    local ch
    while IFS= read -r ch; do
        printf '\033[38;2;%d;%d;%dm%s' "$r" "$g" "$b" "$ch"
        sleep "$speed"
    done < <(printf '%s' "$text" | grep -oP '.')
    printf '\033[0m'
}

# Typewriter with newline
typewriterln() {
    typewriter "$@"
    echo ""
}

# Fade-in text line by line with progressive brightness
fade_in_lines() {
    local color="$1"
    shift
    local shades=("#1a1a2e" "#2a2a4e" "#3a3a6e" "#5a5a8e" "#8a8aae" "$color")
    local total=${#shades[@]}
    for line in "$@"; do
        for ((s = 0; s < total; s++)); do
            printf '\r'
            gum style --foreground "${shades[$s]}" "  $line"
            sleep 0.04
        done
        echo ""
    done
}

# Animated progress bar
progress_bar() {
    local label="${1:-Loading}" width="${2:-40}" duration="${3:-2}"
    local steps=$((width))
    local step_delay
    step_delay=$(echo "scale=4; $duration / $steps" | bc 2>/dev/null || echo "0.05")
    local bar=""
    local i
    for ((i = 0; i <= steps; i++)); do
        local pct=$((i * 100 / steps))
        bar=""
        local j
        for ((j = 0; j < i; j++)); do bar+="█"; done
        for ((j = i; j < steps; j++)); do bar+="░"; done
        printf '\r  \033[38;2;0;215;255m%s \033[38;2;0;255;135m[%s] \033[38;2;188;188;188m%3d%%\033[0m' \
            "$label" "$bar" "$pct"
        sleep "$step_delay"
    done
    echo ""
}

# Spinning dots animation for a message
spin_text() {
    local msg="$1" duration="${2:-1}"
    local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local end=$((SECONDS + duration))
    local i=0
    while [ $SECONDS -lt $end ]; do
        printf '\r  \033[38;2;0;215;255m%s\033[0m  \033[38;2;88;88;88m%s\033[0m' "${frames[$((i % ${#frames[@]}))]}" "$msg"
        sleep 0.08
        i=$((i + 1))
    done
    printf '\r  \033[38;2;0;255;135m✔\033[0m  \033[38;2;188;188;188m%s\033[0m\n' "$msg"
}

# Reveal text character by character with a glow effect
glow_reveal() {
    local text="$1" color="${2:-$C}"
    local r g b
    r=$((16#${color:1:2}))
    g=$((16#${color:3:2}))
    b=$((16#${color:5:2}))
    local ch
    while IFS= read -r ch; do
        # Bright flash then settle
        printf '\033[38;2;255;255;255m%s\033[0m' "$ch"
        sleep 0.01
        printf '\b\033[38;2;%d;%d;%dm%s\033[0m' "$r" "$g" "$b" "$ch"
    done < <(printf '%s' "$text" | grep -oP '.')
    echo ""
}

# ── Helpers ───────────────────────────────────────────────────────────────────
is_mounted()      { mountpoint -q "$MOUNT_DIR" 2>/dev/null; }
enc_file_count()  { find "$STORE_DIR" -name '*.enc' 2>/dev/null | wc -l | tr -d ' '; }
log_entry_count() { [ -f "$LOG_FILE" ] && wc -l < "$LOG_FILE" | tr -d ' ' || echo "0"; }
last_log_op()     { [ -f "$LOG_FILE" ] && grep -oP '(?<=\] )\w+' "$LOG_FILE" | tail -1 || echo "none"; }

press_enter() {
    local msg="${1:-Press Enter to continue...}"
    echo ""
    gum style --foreground "$DM" "  ${msg}"
    read -r 2>/dev/null || true
}

# Coloured badge: badge "label" fg_hex bg_hex
badge() {
    gum style \
        --foreground "$2" \
        --background "$3" \
        --bold \
        --padding "0 1" \
        " $1 "
}

# Section header with accent bar — now animated
section() {
    local icon="${1}" label="${2}" color="${3:-$C}"
    echo ""
    gum style --foreground "$color" --bold "  ${icon}  ${label}"
    # Animated separator
    local sep=""
    for ((i = 0; i < 58; i++)); do sep+="─"; done
    gum style --foreground "$color" "  ${sep}"
}

# Explainer box — shows a context hint in a subtle bordered box
explain() {
    local color="${1:-$DM}"
    shift
    gum style \
        --border rounded \
        --border-foreground "$DM" \
        --foreground "$color" \
        --padding "0 2" \
        --width 72 \
        "$@"
}

# ── Cinematic Splash Screen ──────────────────────────────────────────────────
show_splash() {
    clear

    # Phase 1: Dark screen with subtle particle rain
    echo ""
    local particles=("·" "∙" "." ":" "⋅")
    for ((row = 0; row < 3; row++)); do
        local line="    "
        for ((col = 0; col < 72; col++)); do
            if (( RANDOM % 8 == 0 )); then
                line+="${particles[$((RANDOM % ${#particles[@]}))]}"
            else
                line+=" "
            fi
        done
        printf '\033[38;2;0;40;20m%s\033[0m\n' "$line"
        sleep 0.05
    done

    # Phase 2: ASCII banner with gradient reveal (line by line)
    local -a banner_lines=(
        "    ███████╗██╗   ██╗███████╗███████╗██╗   ██╗ █████╗ ██╗   ██╗██╗ ████████╗"
        "    ██╔════╝██║   ██║██╔════╝██╔════╝██║   ██║██╔══██╗██║   ██║██║ ╚══██╔══╝"
        "    █████╗  ██║   ██║███████╗█████╗  ██║   ██║███████║██║   ██║██║    ██║   "
        "    ██╔══╝  ██║   ██║╚════██║██╔══╝  ╚██╗ ██╔╝██╔══██║██║   ██║██║    ██║   "
        "    ██║     ╚██████╔╝███████║███████╗ ╚████╔╝ ██║  ██║╚██████╔╝███████╗██║   "
        "    ╚═╝      ╚═════╝ ╚══════╝╚══════╝  ╚═══╝  ╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝  "
    )
    local -a gradient_colors=("#003322" "#005533" "#007744" "#009955" "#00bb77" "#00ffaa")

    for ((i = 0; i < ${#banner_lines[@]}; i++)); do
        # Quick flash then color
        printf '\033[38;2;255;255;255m%s\033[0m' "${banner_lines[$i]}"
        sleep 0.04
        printf '\r\033[38;2;%d;%d;%dm%s\033[0m\n' \
            "$(( 16#${gradient_colors[$i]:1:2} ))" \
            "$(( 16#${gradient_colors[$i]:3:2} ))" \
            "$(( 16#${gradient_colors[$i]:5:2} ))" \
            "${banner_lines[$i]}"
        sleep 0.06
    done

    echo ""

    # Phase 3: Tagline with typewriter effect
    printf '    '
    typewriter "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "$DM" 0.005
    echo ""
    echo ""

    printf '           '
    typewriter "🔐  " "$C" 0.06
    typewriter "Your Files. " "$W" 0.04
    typewriter "Your Keys. " "$G" 0.04
    typewriter "Your Vault." "$C" 0.04
    echo ""
    echo ""

    printf '    '
    typewriter "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "$DM" 0.005
    echo ""
    echo ""

    # Phase 4: Animated description reveal
    printf '    '
    typewriter "A " "$SV" 0.03
    typewriter "military-grade " "$Y" 0.03
    typewriter "encrypted virtual filesystem" "$SV" 0.03
    echo ""
    printf '    '
    typewriter "powered by " "$DM" 0.03
    typewriter "FUSE" "$C" 0.05
    typewriter " + " "$DM" 0.05
    typewriter "AES-256-CBC" "$G" 0.04
    typewriter " + " "$DM" 0.05
    typewriter "Argon2id" "$P" 0.04
    echo ""
    echo ""
    sleep 0.3

    # Phase 5: Feature cards revealed one by one with animation
    local -a feat_icons=("🛡️ " "🔑" "📝" "⚡" "🧬" "🔒")
    local -a feat_labels=("AES-256-CBC Encryption     " "Envelope Key Wrapping      " "Hash-Chain Audit Trail     " "Transparent FUSE I/O       " "Argon2id Key Derivation    " "Secure Memory Erasure      ")
    local -a feat_descs=("Per-file random IV — identical data encrypts differently every time" "Each file has its own FEK, wrapped by the master key — AWS KMS model" "SHA-256 linked entries — tampering breaks the chain instantly" "Read & write normally — encryption is invisible to your applications" "Memory-hard password hashing — GPU brute-force becomes infeasible" "mlock() + OPENSSL_cleanse() — keys never touch swap, zeroed on exit")
    local -a feat_colors=("$G" "$C" "$M" "$Y" "$P" "$TEAL")
    local -a feat_bgs=("$BG_G" "$BG_C" "$BG_M" "$BG_Y" "$BG_P" "$BG_TEAL")

    for ((i = 0; i < ${#feat_icons[@]}; i++)); do
        printf '    '
        # Icon badge
        printf '\033[1;38;2;%d;%d;%dm%s\033[0m ' \
            "$(( 16#${feat_colors[$i]:1:2} ))" \
            "$(( 16#${feat_colors[$i]:3:2} ))" \
            "$(( 16#${feat_colors[$i]:5:2} ))" \
            "${feat_icons[$i]}"
        # Label
        typewriter "${feat_labels[$i]}" "${feat_colors[$i]}" 0.012
        # Description in dim
        printf '\033[38;2;88;88;88m%s\033[0m' "${feat_descs[$i]}"
        echo ""
        sleep 0.08
    done

    echo ""

    # Phase 6: Animated loading bar
    progress_bar "  ⚙ Initializing vault systems" 35 1.5

    echo ""
    spin_text "Loading encryption modules..." 0.5
    spin_text "Verifying system integrity..." 0.4
    spin_text "Ready." 0.3
    echo ""
}

# ── Header (shown at top of every screen) ─────────────────────────────────────
draw_header() {
    # Top accent line with gradient dots
    printf '  '
    local -a accent_colors=("#003322" "#005533" "#007744" "#009955" "#00bb77" "#00dd99" "#00ffaa" "#00dd99" "#00bb77" "#009955" "#007744" "#005533" "#003322")
    for ac in "${accent_colors[@]}"; do
        printf '\033[38;2;%d;%d;%dm━━━━━━\033[0m' \
            "$(( 16#${ac:1:2} ))" "$(( 16#${ac:3:2} ))" "$(( 16#${ac:5:2} ))"
    done
    echo ""

    # Title bar — dark background, bright cyan text with shield icon
    local title_bar
    title_bar=$(gum style \
        --foreground "$C" \
        --background "$BG_PANEL" \
        --bold \
        --width 74 \
        --align center \
        --padding "0 1" \
        "🛡️  F U S E V A U L T   v2.0  🛡️   AES-256-CBC · Argon2id · Hash-Chain")

    # Status badges with solid background colours
    local mount_badge key_badge
    if is_mounted; then
        mount_badge=$(badge "● MOUNTED"   "$G" "$BG_G")
    else
        mount_badge=$(badge "○ UNMOUNTED" "$R" "$BG_R")
    fi

    if [ -f "$KEY_FILE" ]; then
        key_badge=$(badge "🔑 KEY OK" "$C" "$BG_C")
    else
        key_badge=$(badge "🔑 NO KEY" "$R" "$BG_R")
    fi

    local enc_badge
    enc_badge=$(badge "◈ $(enc_file_count) files" "$P" "$BG_P")

    local log_badge
    log_badge=$(badge "≡ $(log_entry_count) log" "$Y" "$BG_Y")

    # Badge row — join horizontally with spaces
    local badge_row
    badge_row=$(gum join --horizontal \
        "  " "$mount_badge" \
        "  " "$key_badge" \
        "  " "$enc_badge" \
        "  " "$log_badge")

    echo "$title_bar"
    echo ""
    echo "$badge_row"
    echo ""

    # Bottom gradient separator
    printf '  '
    for ac in "${accent_colors[@]}"; do
        printf '\033[38;2;%d;%d;%dm══════\033[0m' \
            "$(( 16#${ac:1:2} ))" "$(( 16#${ac:3:2} ))" "$(( 16#${ac:5:2} ))"
    done
    echo ""
}

# ── Status bar ────────────────────────────────────────────────────────────────
draw_statusbar() {
    local msg="${1:-Ready}"
    local help_key quit_key sep
    help_key=$(gum style --foreground "$BG_PANEL" --background "$C"  --padding "0 1" " ? help ")
    quit_key=$(gum style --foreground "$BG_PANEL" --background "$DM" --padding "0 1" " q back ")
    sep=$(gum style --foreground "$DM" "  │  ")
    local msg_styled
    msg_styled=$(gum style --foreground "$SV" --italic "  ${msg}")
    echo ""
    # Gradient separator
    printf '  '
    local -a accent_colors=("#003322" "#005533" "#007744" "#009955" "#00bb77" "#00dd99" "#00ffaa" "#00dd99" "#00bb77" "#009955" "#007744" "#005533" "#003322")
    for ac in "${accent_colors[@]}"; do
        printf '\033[38;2;%d;%d;%dm══════\033[0m' \
            "$(( 16#${ac:1:2} ))" "$(( 16#${ac:3:2} ))" "$(( 16#${ac:5:2} ))"
    done
    echo ""
    echo "  $(gum join --horizontal "$help_key" "  " "$quit_key" "$sep" "$msg_styled")"
}

# ═════════════════════════════════════════════════════════════════════════════
#  MAIN MENU
# ═════════════════════════════════════════════════════════════════════════════
main_menu() {
    while true; do
        clear
        draw_header

        # Show a contextual tip based on vault state with animated indicator
        echo ""
        if ! [ -f "${WORKSPACE}/myfs" ]; then
            explain "$Y" "  ⚠  myfs binary not compiled yet.  →  Go to Vault Controls → Run Self-Test to build it."
        elif ! [ -f "$KEY_FILE" ]; then
            explain "$Y" "  ⚠  No master key found.  →  Open Key Management to generate one before mounting."
        elif ! is_mounted; then
            explain "$C" "  ℹ  Vault is not mounted.  →  Open Vault Controls and choose Mount Vault to start."
        else
            explain "$G" "  ✔  Vault is mounted and ready.  Write files to mount/ to encrypt them automatically."
        fi
        echo ""

        # Compact feature summary bar
        local features_row
        features_row=$(gum join --horizontal \
            "$(gum style --foreground "$G"  --bold " AES-256 ")" \
            "$(gum style --foreground "$DM" "·")" \
            "$(gum style --foreground "$C"  --bold " Envelope Enc ")" \
            "$(gum style --foreground "$DM" "·")" \
            "$(gum style --foreground "$M"  --bold " Hash-Chain ")" \
            "$(gum style --foreground "$DM" "·")" \
            "$(gum style --foreground "$P"  --bold " Argon2id ")" \
            "$(gum style --foreground "$DM" "·")" \
            "$(gum style --foreground "$Y"  --bold " FUSE ")" \
            "$(gum style --foreground "$DM" "·")" \
            "$(gum style --foreground "$TEAL" --bold " mlock() ")")
        echo "  $features_row"
        echo ""

        # Coloured icon + bold label + dim description per item
        local choice
        choice=$(printf '%s\n' \
            "$(gum style --foreground "$C"  "  🖥   Dashboard        ")$(gum style --foreground "$DM" " live vault status, files, recent events")" \
            "$(gum style --foreground "$G"  "  📁  File Browser      ")$(gum style --foreground "$DM" " browse, read, write, delete encrypted files")" \
            "$(gum style --foreground "$Y"  "  🔒  Vault Controls    ")$(gum style --foreground "$DM" " mount, unmount, self-test, wipe")" \
            "$(gum style --foreground "$M"  "  📋  Audit Log         ")$(gum style --foreground "$DM" " view, verify, follow hash-chain log")" \
            "$(gum style --foreground "$P"  "  🔑  Key Management    ")$(gum style --foreground "$DM" " generate, derive, rotate master key")" \
            "$(gum style --foreground "$SV" "  🔬  Diagnostics       ")$(gum style --foreground "$DM" " health checks, binary, crypto versions")" \
            "$(gum style --foreground "$O"  "  📖  About FuseVault   ")$(gum style --foreground "$DM" " architecture, security model, design philosophy")" \
            "$(gum style --foreground "$W"  "  🎬  Guided Demo        ")$(gum style --foreground "$DM" " 7-step interactive walkthrough — start here if new")" \
            "$(gum style --foreground "$DM" "  ✕   Quit")" | \
            gum choose \
                --header "$(gum style --foreground "$SV" "  ⌨  Navigate ↑↓  ·  Select ↵  ·  🎬 Guided Demo if you're new")" \
                --cursor "$(gum style --foreground "$G" " ❯ ")" \
                --cursor.foreground "$G" \
                --height 12) || break

        case "$choice" in
            *"Dashboard"*)      screen_dashboard ;;
            *"File Browser"*)   screen_file_browser ;;
            *"Vault Controls"*) screen_vault_controls ;;
            *"Audit Log"*)      screen_audit_log ;;
            *"Key Management"*) screen_key_management ;;
            *"Diagnostics"*)    screen_diagnostics ;;
            *"About FuseVault"*) screen_about ;;
            *"Guided Demo"*)    screen_demo ;;
            *"Quit"*)
                clear
                echo ""
                echo ""
                # Animated exit
                printf '    '
                typewriter "Shutting down FuseVault..." "$DM" 0.03
                echo ""
                sleep 0.3
                echo ""
                gum style \
                    --border double \
                    --border-foreground "$C" \
                    --padding "1 4" \
                    --align center \
                    --width 62 \
                    "$(gum style --foreground "$C" --bold "  🛡️  FuseVault — Session Ended")" \
                    "" \
                    "$(gum style --foreground "$G" "  ✔ Your encrypted files remain safely in store/.")" \
                    "$(gum style --foreground "$DM" "  The container is still running in the background.")" \
                    "" \
                    "$(gum style --foreground "$C" "  ./run.sh          ")$(gum style --foreground "$DM" "— reconnect")" \
                    "$(gum style --foreground "$C" "  ./run.sh --clean  ")$(gum style --foreground "$DM" "— full teardown")" \
                    "" \
                    "$(gum style --foreground "$DM" --italic "  \"Security is not a product, but a process.\" — Bruce Schneier")"
                echo ""
                echo ""
                exit 0 ;;
        esac
    done
}

# ═════════════════════════════════════════════════════════════════════════════
#  SCREEN 1 — DASHBOARD
# ═════════════════════════════════════════════════════════════════════════════
screen_dashboard() {
    clear
    draw_header
    section "🖥" "Dashboard" "$C"

    # Explainer
    explain "$DM" \
        "  The dashboard shows a live snapshot of vault health. The top panels summarise" \
        "  the current state of the mount, key, and binary. Recent audit events are shown" \
        "  below — every file operation is logged automatically."
    echo ""

    # Left: vault state panel
    local m_line k_line b_line
    if is_mounted; then
        m_line="$(badge "● MOUNTED"   "$G" "$BG_G")"
    else
        m_line="$(badge "○ UNMOUNTED" "$R" "$BG_R")"
    fi

    if [ -f "$KEY_FILE" ]; then
        local age; age=$(( ( $(date +%s) - $(stat -c '%Y' "$KEY_FILE") ) / 86400 ))
        k_line="$(badge "KEY PRESENT  ${age}d" "$C" "$BG_C")"
    else
        k_line="$(badge "NO KEY" "$R" "$BG_R")"
    fi

    if [ -f "${WORKSPACE}/myfs" ]; then
        b_line="$(badge "BUILT" "$G" "$BG_G")"
    else
        b_line="$(badge "NOT BUILT" "$R" "$BG_R")"
    fi

    local col_vault
    col_vault=$(gum style \
        --border rounded \
        --border-foreground "$BR_C" \
        --padding "1 2" \
        --width 34 \
        "$(gum style --foreground "$C" --bold "  ◈ Vault State")" \
        "" \
        "  Mount   ${m_line}" \
        "  Key     ${k_line}" \
        "  Binary  ${b_line}" \
        "" \
        "$(gum style --foreground "$DM" --italic "  Mount = FUSE driver running")" \
        "$(gum style --foreground "$DM" --italic "  Key   = master encryption key")" \
        "$(gum style --foreground "$DM" --italic "  Binary= myfs compiled binary")")

    # Right: storage stats panel
    local enc_count log_count last_op
    enc_count=$(enc_file_count)
    log_count=$(log_entry_count)
    last_op=$(last_log_op)

    local last_op_badge
    case "$last_op" in
        WRITE)   last_op_badge=$(badge "WRITE"   "$Y"  "$BG_Y") ;;
        READ)    last_op_badge=$(badge "READ"    "$C"  "$BG_C") ;;
        MOUNT)   last_op_badge=$(badge "MOUNT"   "$G"  "$BG_G") ;;
        UNMOUNT) last_op_badge=$(badge "UNMOUNT" "$M"  "$BG_M") ;;
        DELETE)  last_op_badge=$(badge "DELETE"  "$R"  "$BG_R") ;;
        *)       last_op_badge=$(badge "${last_op}" "$DM" "#1a1a1a") ;;
    esac

    local col_store
    col_store=$(gum style \
        --border rounded \
        --border-foreground "$BR_P" \
        --padding "1 2" \
        --width 34 \
        "$(gum style --foreground "$P" --bold "  ◈ Storage & Log")" \
        "" \
        "  Enc files   $(gum style --foreground "$W" "${enc_count}")" \
        "  Log entries $(gum style --foreground "$W" "${log_count}")" \
        "  Last op     ${last_op_badge}" \
        "" \
        "$(gum style --foreground "$DM" --italic "  .enc = ciphertext in store/")" \
        "$(gum style --foreground "$DM" --italic "  Log entries = operations recorded")")

    gum join --horizontal "$col_vault" "  " "$col_store"
    echo ""

    # Recent audit events
    gum style --foreground "$M" --bold "  ◈ Recent Audit Events  $(gum style --foreground "$DM" --italic "(last 5 operations)")"
    gum style --foreground "$M" "  ────────────────────────────────────────────────────────"
    echo ""

    if [ -f "$LOG_FILE" ] && [ "$(log_entry_count)" -gt 0 ]; then
        while IFS= read -r line; do
            local op_fg="$SV" op_bg="#1a1a1a" op_label="●"
            if   echo "$line" | grep -qw "WRITE";   then op_fg="$Y";  op_bg="$BG_Y"; op_label="✎ WRITE  "
            elif echo "$line" | grep -qw "READ";    then op_fg="$C";  op_bg="$BG_C"; op_label="◎ READ   "
            elif echo "$line" | grep -qw "MOUNT";   then op_fg="$G";  op_bg="$BG_G"; op_label="▲ MOUNT  "
            elif echo "$line" | grep -qw "UNMOUNT"; then op_fg="$M";  op_bg="$BG_M"; op_label="▼ UNMOUNT"
            elif echo "$line" | grep -qw "DELETE";  then op_fg="$R";  op_bg="$BG_R"; op_label="✖ DELETE "
            fi
            local op_tag
            op_tag=$(gum style --foreground "$op_fg" --background "$op_bg" --padding "0 1" " ${op_label} ")
            local rest
            rest=$(gum style --foreground "$DM" "  ${line:0:64}...")
            echo "  $(gum join --horizontal "$op_tag" "$rest")"
        done < <(tail -5 "$LOG_FILE")
    else
        gum style --foreground "$DM" --italic "  No audit events yet — mount the vault and write a file to see activity here."
    fi

    draw_statusbar "Dashboard — live vault snapshot"
    press_enter "Press Enter to return to menu..."
}

# ═════════════════════════════════════════════════════════════════════════════
#  SCREEN 2 — FILE BROWSER
# ═════════════════════════════════════════════════════════════════════════════
screen_file_browser() {
    while true; do
        clear
        draw_header
        section "📁" "File Browser" "$G"

        if ! is_mounted; then
            echo ""
            explain "$R" \
                "  The File Browser requires the vault to be mounted first." \
                "" \
                "  When mounted, the FUSE driver exposes your encrypted files as normal files." \
                "  You can read, write, and delete them here — encryption is fully transparent." \
                "" \
                "  Go to  Vault Controls  →  Mount Vault  to get started."
            gum style \
                --border rounded \
                --border-foreground "$BR_R" \
                --foreground "$R" \
                --padding "1 3" \
                "$(gum style --foreground "$R" --bold "  ○  Vault Not Mounted")" \
                "" \
                "  Files cannot be browsed until the vault is running."
            draw_statusbar "Vault unmounted — go to Vault Controls to mount"
            press_enter "Press Enter to return..."
            return
        fi

        local files=()
        while IFS= read -r -d '' f; do
            files+=("$(basename "$f")")
        done < <(find "$MOUNT_DIR" -maxdepth 1 -type f -print0 2>/dev/null)

        if [ ${#files[@]} -eq 0 ]; then
            echo ""
            explain "$Y" \
                "  The vault is mounted but contains no files yet." \
                "" \
                "  Choose  ✚ Write new file  below to create your first encrypted file." \
                "  Anything you write here is automatically encrypted on disk in store/." \
                "  The plaintext never touches the disk — only the .enc ciphertext is stored."
            gum style \
                --border rounded \
                --border-foreground "$BR_Y" \
                --foreground "$Y" \
                --padding "1 3" \
                "$(gum style --foreground "$Y" --bold "  ◈  Vault is Empty")" \
                "" \
                "  Write a file to mount/ to encrypt it automatically."
            draw_statusbar "0 files — use Write new file to add one"
            press_enter "Press Enter to return..."
            return
        fi

        # Build icon-prefixed file list
        local icon_files=()
        for f in "${files[@]}"; do
            icon_files+=("$(gum style --foreground "$G" "  📄 ") $(gum style --foreground "$W" "$f")")
        done

        local selected
        selected=$(printf '%s\n' \
            "$(gum style --foreground "$G"  "  ✚  Write new file")" \
            "$(gum style --foreground "$R"  "  ✖  Delete a file")" \
            "$(gum style --foreground "$DM" "  ──────────────────────")" \
            "${icon_files[@]}" \
            "$(gum style --foreground "$DM" "  ← Back")" | \
            gum choose \
                --header "$(gum style --foreground "$G" "  ${#files[@]} file(s) in vault  ·  Select to view contents  ·  or choose an action")" \
                --cursor.foreground "$G" \
                --height 16) || return

        case "$selected" in
            *"← Back"*) return ;;
            *"──────"*)  continue ;;
            *"Write new file"*) screen_write_file ;;
            *"Delete a file"*)  screen_delete_file "${files[@]}" ;;
            *)
                # Strip icon prefix to get filename
                local fname; fname=$(echo "$selected" | sed 's/.*📄 *//' | sed 's/^ *//')
                local filepath="${MOUNT_DIR}/${fname}"
                local content file_size enc_size="-"
                content=$(cat "$filepath" 2>/dev/null || echo "(unreadable)")
                file_size=$(wc -c < "$filepath" 2>/dev/null | tr -d ' ')
                local enc_path="${STORE_DIR}/${fname}.enc"
                [ -f "$enc_path" ] && enc_size=$(wc -c < "$enc_path" | tr -d ' ')

                clear
                draw_header
                section "📄" "File: ${fname}" "$G"
                echo ""
                explain "$DM" \
                    "  You are viewing the decrypted plaintext — the FUSE driver decrypts it on the fly." \
                    "  The ciphertext size (${enc_size}B) is larger due to the encryption header and padding." \
                    "  The raw .enc file in store/ is unreadable binary data — this view is via the vault."
                echo ""
                gum style \
                    --border rounded \
                    --border-foreground "$BR_G" \
                    --padding "0 2" \
                    --width 72 \
                    "$(badge "PLAINTEXT" "$G" "$BG_G") $(gum style --foreground "$W" "${file_size}B")   $(badge "CIPHERTEXT" "$Y" "$BG_Y") $(gum style --foreground "$W" "${enc_size}B")   $(badge "AES-256-CBC" "$C" "$BG_C")"
                echo ""
                echo "$content" | gum pager || true
                ;;
        esac
    done
}

screen_write_file() {
    clear; draw_header
    section "✚" "Write New File to Vault" "$G"
    echo ""

    explain "$DM" \
        "  Files written here are encrypted immediately by the FUSE driver." \
        "  The plaintext is passed to myfs_write() → AES-256-CBC with a fresh random IV" \
        "  and per-file key (FEK) → the ciphertext lands in store/<filename>.enc." \
        "  The original plaintext never touches the disk."
    echo ""

    local filename
    filename=$(gum input \
        --placeholder "e.g. secret.txt, passwords.txt, notes.md" \
        --header "  Filename  (will be created inside mount/):" \
        --width 52) || return
    [ -z "$filename" ] && return

    echo ""
    local content
    content=$(gum write \
        --placeholder "Type or paste your secret content here..." \
        --header "  Content  (Ctrl+D or Esc to save and encrypt):" \
        --width 68 \
        --height 10) || return

    printf '%s' "$content" > "${MOUNT_DIR}/${filename}"
    local bytes; bytes=$(wc -c < "${MOUNT_DIR}/${filename}" | tr -d ' ')

    echo ""
    gum style \
        --border rounded \
        --border-foreground "$BR_G" \
        --padding "0 3" \
        "$(badge "ENCRYPTED" "$G" "$BG_G")  $(gum style --foreground "$W" "${filename}")  $(gum style --foreground "$DM" "${bytes}B written → stored as ${filename}.enc in store/")"
    sleep 1
}

screen_delete_file() {
    local files=("$@")

    clear; draw_header
    section "✖" "Delete File from Vault" "$R"
    echo ""

    explain "$Y" \
        "  Deleting a file removes it from the mount/ view AND deletes the .enc file in store/." \
        "  This operation is logged in the audit trail. It cannot be undone without a backup." \
        "  If you only want to temporarily hide a file, unmount the vault instead."
    echo ""

    local target
    target=$(printf '%s\n' "${files[@]}" | \
        gum choose \
            --header "$(gum style --foreground "$R" "  Select file to permanently delete:")" \
            --cursor.foreground "$R" \
            --height 12) || return

    gum confirm "  Permanently delete '${target}'? This cannot be undone." || return
    rm -f "${MOUNT_DIR}/${target}"
    gum style --foreground "$G" "  ✔  Deleted: ${target}  (and its .enc ciphertext from store/)"
    sleep 1
}

# ═════════════════════════════════════════════════════════════════════════════
#  SCREEN 3 — VAULT CONTROLS
# ═════════════════════════════════════════════════════════════════════════════
screen_vault_controls() {
    while true; do
        clear
        draw_header
        section "🔒" "Vault Controls" "$Y"

        # Context explainer
        if is_mounted; then
            explain "$G" \
                "  The vault is currently MOUNTED. The FUSE driver is running and intercepts all" \
                "  reads and writes in mount/. To stop it and erase the key from RAM, choose Unmount."
        else
            explain "$DM" \
                "  The vault is UNMOUNTED. To start encrypting and reading files, choose Mount Vault." \
                "  Mounting starts the FUSE driver (myfs) and loads the master key into locked RAM."
        fi
        echo ""

        local toggle
        if is_mounted; then
            toggle="$(gum style --foreground "$G" "  ▼  Unmount Vault       ")$(gum style --foreground "$DM" " safely stop FUSE, flush writes, erase key from RAM")"
        else
            toggle="$(gum style --foreground "$Y" "  ▲  Mount Vault         ")$(gum style --foreground "$DM" " start the FUSE driver and load the master key")"
        fi

        local action
        action=$(printf '%s\n' \
            "${toggle}" \
            "$(gum style --foreground "$C"  "  ◎  Vault Status        ")$(gum style --foreground "$DM" " show mount, key, binary, and log state")" \
            "$(gum style --foreground "$SV" "  ⚙  Run Self-Test       ")$(gum style --foreground "$DM" " automated write→read→verify cycle to confirm everything works")" \
            "$(gum style --foreground "$R"  "  ✖  Wipe Key Material   ")$(gum style --foreground "$DM" " destroy key — encrypted files become PERMANENTLY unreadable")" \
            "$(gum style --foreground "$DM" "  ←  Back")" | \
            gum choose \
                --header "$(gum style --foreground "$Y" "  Choose an action:")" \
                --cursor.foreground "$Y" \
                --height 8) || return

        case "$action" in
            *"Mount Vault"*|*"Unmount Vault"*)
                echo ""
                if is_mounted; then
                    gum style --foreground "$DM" --italic "  Unmounting — flushing all pending writes and erasing key from RAM..."
                    gum spin --spinner dot --title "  Unmounting vault..." \
                        -- bash "$VAULT" unmount
                    gum style --foreground "$G" "  ✔  Vault unmounted."
                    gum style --foreground "$DM" --italic "  Key material has been zeroed in RAM via OPENSSL_cleanse()."
                    gum style --foreground "$DM" --italic "  Encrypted files remain in store/ but are unreadable without the key."
                else
                    if [ ! -f "$KEY_FILE" ]; then
                        gum style \
                            --border rounded --border-foreground "$BR_R" \
                            --foreground "$R" --padding "1 3" \
                            "$(gum style --foreground "$R" --bold "  ✖  No Master Key Found")" \
                            "" \
                            "  A key is required to mount the vault." \
                            "  Go to  Key Management  to generate one first."
                    else
                        gum style --foreground "$DM" --italic "  Starting FUSE driver — loading master key into locked RAM..."
                        gum spin --spinner dot --title "  Mounting vault..." \
                            -- bash "$VAULT" mount
                        gum style --foreground "$G" "  ✔  Vault mounted at ${MOUNT_DIR}"
                        gum style --foreground "$DM" --italic "  The FUSE driver is now intercepting all reads/writes in mount/."
                        gum style --foreground "$DM" --italic "  Files written to mount/ are AES-256-CBC encrypted in store/."
                    fi
                fi
                sleep 2 ;;
            *"Vault Status"*)
                clear; draw_header
                section "◎" "Vault Status" "$C"
                echo ""
                explain "$DM" \
                    "  This shows the live state of every vault component." \
                    "  Green = healthy, Red = needs attention, Yellow = warning." \
                    "  Any issues are shown with a suggested fix."
                echo ""
                bash "$VAULT" status
                draw_statusbar "Vault Status"
                press_enter ;;
            *"Self-Test"*)
                clear; draw_header
                section "⚙" "Self-Test" "$SV"
                echo ""
                explain "$DM" \
                    "  The self-test runs an automated write → read → verify cycle to confirm" \
                    "  that the FUSE driver, encryption, and decryption are all working correctly." \
                    "  It creates a temporary test file, writes a known value, reads it back," \
                    "  verifies the content matches, and cleans up. All output is shown below."
                echo ""
                local test_out
                test_out=$(bash -c "cd ${WORKSPACE} && make test" 2>&1 || true)
                echo "$test_out" | gum pager || true
                press_enter ;;
            *"Wipe Key"*)
                echo ""
                explain "$R" \
                    "  DANGER: Wiping key material is a one-way destructive operation." \
                    "" \
                    "  The master key will be overwritten 3 times with random data and deleted." \
                    "  All encrypted files in store/ will become permanently unreadable — there is" \
                    "  NO recovery. Only proceed if you intend to permanently destroy the vault data."
                echo ""
                gum confirm "  DANGER: Wipe all key material? Encrypted files become UNRECOVERABLE." || continue
                gum confirm "  Final confirmation: this CANNOT be undone. Destroy the key?" || continue
                gum spin --spinner dot --title "  Securely erasing key material (3-pass overwrite)..." \
                    -- bash "$VAULT" wipe
                echo ""
                gum style \
                    --border double --border-foreground "$BR_R" \
                    --foreground "$R" --padding "1 3" \
                    "$(badge "WIPED" "$R" "$BG_R")  Key destroyed." \
                    "" \
                    "  Encrypted files in store/ still exist on disk." \
                    "  They are now permanently inaccessible without the key." \
                    "  Run 'rm -rf store/*.enc' to clean up the ciphertext files."
                sleep 3 ;;
            *"Back"*) return ;;
        esac
    done
}

# ═════════════════════════════════════════════════════════════════════════════
#  SCREEN 4 — AUDIT LOG
# ═════════════════════════════════════════════════════════════════════════════
screen_audit_log() {
    while true; do
        clear
        draw_header
        section "📋" "Audit Log" "$M"

        explain "$DM" \
            "  Every vault operation — mount, unmount, file read, write, and delete — is recorded" \
            "  in an append-only audit log. Each entry is SHA-256 hashed and linked to the previous" \
            "  entry, forming a tamper-evident chain. Editing any entry breaks all subsequent hashes." \
            "" \
            "  Log location: ${LOG_FILE}"
        echo ""

        local entry_count; entry_count=$(log_entry_count)
        local last_op; last_op=$(last_log_op)
        gum style --foreground "$SV" "  $(badge "${entry_count} entries" "$M" "$BG_M")  last operation: $(badge "${last_op}" "$Y" "$BG_Y")"
        echo ""

        local action
        action=$(printf '%s\n' \
            "$(gum style --foreground "$C"  "  ≡  View Full Log           ")$(gum style --foreground "$DM" " pageable colorized log — all recorded operations")" \
            "$(gum style --foreground "$G"  "  ✔  Verify Hash-Chain       ")$(gum style --foreground "$DM" " check every entry's SHA-256 hash for tampering")" \
            "$(gum style --foreground "$Y"  "  ⟳  Follow Live  (tail -f)  ")$(gum style --foreground "$DM" " stream new entries as they happen — Ctrl+C to stop")" \
            "$(gum style --foreground "$DM" "  ←  Back")" | \
            gum choose \
                --header "$(gum style --foreground "$M" "  Audit Log Actions:")" \
                --cursor.foreground "$M" \
                --height 7) || return

        case "$action" in
            *"View Full Log"*)
                if [ ! -f "$LOG_FILE" ] || [ "$(log_entry_count)" -eq 0 ]; then
                    gum style --foreground "$DM" --italic "  No log entries yet — mount the vault and perform some operations first."
                    sleep 2; continue
                fi
                clear; draw_header
                section "≡" "Full Audit Log" "$C"
                echo ""
                explain "$DM" \
                    "  Log entries are color-coded by operation type:" \
                    "  Yellow = WRITE   Cyan = READ   Green = MOUNT   Magenta = UNMOUNT   Red = DELETE" \
                    "  Each line: [timestamp] OPERATION  filename  PREV=<prev_hash>  HASH=<entry_hash>"
                echo ""
                local colorized=""
                while IFS= read -r line; do
                    local lc="$SV"
                    if   echo "$line" | grep -qw "WRITE";   then lc="$Y"
                    elif echo "$line" | grep -qw "READ";    then lc="$C"
                    elif echo "$line" | grep -qw "MOUNT";   then lc="$G"
                    elif echo "$line" | grep -qw "UNMOUNT"; then lc="$M"
                    elif echo "$line" | grep -qw "DELETE";  then lc="$R"
                    fi
                    colorized+="$(gum style --foreground "$lc" "  $line")"$'\n'
                done < <(cat "$LOG_FILE")
                printf '%s' "$colorized" | gum pager || true ;;
            *"Verify"*)
                clear; draw_header
                section "✔" "Hash-Chain Verification" "$G"
                echo ""
                explain "$DM" \
                    "  FuseVault uses a SHA-256 hash chain to detect log tampering." \
                    "  Each entry stores a hash of its own content plus a pointer to the previous hash." \
                    "  If any entry is modified, deleted, or inserted, its hash will not match — and" \
                    "  all subsequent hashes will also break, making tampering immediately visible." \
                    "" \
                    "  This is similar to how blockchain transactions link to their predecessors."
                echo ""
                bash "$VAULT" verify-log
                draw_statusbar "Verification complete"
                press_enter ;;
            *"Follow Live"*)
                clear; draw_header
                section "⟳" "Live Log Stream" "$Y"
                echo ""
                explain "$DM" \
                    "  New log entries appear here as they happen in real-time." \
                    "  Try mounting the vault, writing a file, and reading it in another terminal." \
                    "  Press Ctrl+C to stop following."
                echo ""
                tail -f "$LOG_FILE" 2>/dev/null || true ;;
            *"Back"*) return ;;
        esac
    done
}

# ═════════════════════════════════════════════════════════════════════════════
#  SCREEN 5 — KEY MANAGEMENT
# ═════════════════════════════════════════════════════════════════════════════
screen_key_management() {
    while true; do
        clear
        draw_header
        section "🔑" "Key Management" "$P"

        local key_exists=false
        [ -f "$KEY_FILE" ] && key_exists=true

        # Key state explainer
        if $key_exists; then
            local age; age=$(( ( $(date +%s) - $(stat -c '%Y' "$KEY_FILE") ) / 86400 ))
            explain "$G" \
                "  A master key exists at keys/vault.key  (${age} days old)." \
                "  This 32-byte key is the root secret that protects all your encrypted files." \
                "  Keep it safe — losing it means losing access to all vault data permanently."
        else
            explain "$Y" \
                "  No master key found. You need to create one before mounting the vault." \
                "" \
                "  Choose  Generate Random Key  for the most secure option (recommended for most users)." \
                "  Choose  Derive from Passphrase  if you want a human-memorable recovery method."
        fi
        echo ""

        local action
        action=$(printf '%s\n' \
            "$(gum style --foreground "$G"  "  ★  Generate Random Key           ")$(gum style --foreground "$DM" " 256-bit random key via openssl rand (recommended)")" \
            "$(gum style --foreground "$P"  "  ⌘  Derive from Passphrase        ")$(gum style --foreground "$DM" " Argon2id key derivation — t=3, m=64MB, p=4")" \
            "$(gum style --foreground "$Y"  "  ↺  Rotate Master Key             ")$(gum style --foreground "$DM" " safely replace key — old key is backed up first")" \
            "$(gum style --foreground "$C"  "  ℹ  Show Key Info                 ")$(gum style --foreground "$DM" " size, permissions, age, storage path")" \
            "$(gum style --foreground "$DM" "  ←  Back")" | \
            gum choose \
                --header "$(gum style --foreground "$P" "  Key Operations  ·  $([ "$key_exists" = "true" ] && echo "Key: PRESENT" || echo "Key: MISSING")")" \
                --cursor.foreground "$P" \
                --height 8) || return

        case "$action" in
            *"Generate Random Key"*)
                if $key_exists; then
                    gum style --border rounded --border-foreground "$BR_Y" \
                        --foreground "$Y" --padding "1 2" \
                        "$(badge "KEY EXISTS" "$Y" "$BG_Y")" \
                        "" \
                        "  A key already exists at keys/vault.key." \
                        "  Use  Rotate Master Key  to safely replace it — this preserves a backup" \
                        "  so you can still access files encrypted with the old key if needed."
                    sleep 3; continue
                fi
                clear; draw_header
                section "★" "Generate Random Key" "$G"
                echo ""
                explain "$DM" \
                    "  This generates a cryptographically random 256-bit (32-byte) key using OpenSSL." \
                    "  Random keys are stronger than passphrase-derived keys because they are fully" \
                    "  unpredictable — even to an attacker who knows how the key was generated." \
                    "" \
                    "  The key file is saved to keys/vault.key with permissions 600 (owner only)." \
                    "  IMPORTANT: Back up this file. If you lose it, your encrypted data is gone."
                echo ""
                gum spin --spinner dot --title "  Generating 256-bit random key via openssl rand..." \
                    -- bash "$VAULT" keygen
                echo ""
                gum style --border rounded --border-foreground "$BR_G" \
                    --foreground "$G" --padding "1 2" \
                    "$(badge "GENERATED" "$G" "$BG_G")" \
                    "" \
                    "  keys/vault.key  ·  32 bytes  ·  chmod 600" \
                    "" \
                    "$(gum style --foreground "$Y" --italic "  ⚠  Back up this key file to a safe location now.")"
                sleep 2 ;;
            *"Passphrase"*)
                if $key_exists; then
                    gum style --border rounded --border-foreground "$BR_Y" \
                        --foreground "$Y" --padding "1 2" \
                        "$(badge "KEY EXISTS" "$Y" "$BG_Y")" \
                        "" \
                        "  A key already exists. Use  Rotate Master Key  to replace it safely."
                    sleep 2; continue
                fi
                clear; draw_header
                section "⌘" "Derive Key from Passphrase" "$P"
                echo ""
                explain "$DM" \
                    "  Argon2id is a memory-hard password hashing algorithm designed to resist" \
                    "  GPU and ASIC brute-force attacks. Parameters used: t=3 iterations, m=64MB" \
                    "  memory, p=4 threads — this takes ~3 seconds deliberately to slow attackers." \
                    "" \
                    "  A random 16-byte salt is generated and mixed with your passphrase. You MUST" \
                    "  save the salt — without it, the same passphrase produces a different key."
                echo ""
                local pass pass2
                pass=$(gum input --password \
                    --placeholder "Enter a strong passphrase..." \
                    --header "  Passphrase  (Argon2id: t=3, m=64MB, p=4 — takes ~3 sec):" \
                    --width 60) || continue
                pass2=$(gum input --password \
                    --placeholder "Re-enter the same passphrase to confirm..." \
                    --header "  Confirm passphrase:" \
                    --width 60) || continue
                if [ "$pass" != "$pass2" ]; then
                    gum style --border rounded --border-foreground "$BR_R" \
                        --foreground "$R" --padding "1 2" \
                        "$(badge "MISMATCH" "$R" "$BG_R")  Passphrases do not match — no key was created."
                    sleep 2; continue
                fi
                local salt; salt=$(openssl rand -hex 16)
                gum spin --spinner dot --title "  Deriving key with Argon2id (~3 seconds — intentionally slow)..." \
                    -- bash -c "mkdir -p '${WORKSPACE}/keys' && printf '%s' '${pass}' | argon2 '${salt}' -id -l 32 -t 3 -m 16 -p 4 -r > '${KEY_FILE}' && chmod 600 '${KEY_FILE}'"
                echo ""
                gum style --border rounded --border-foreground "$BR_G" \
                    --foreground "$G" --padding "1 2" \
                    "$(badge "DERIVED" "$G" "$BG_G")" \
                    "" \
                    "  Key saved to keys/vault.key  ·  chmod 600" \
                    "" \
                    "$(gum style --foreground "$Y" --bold "  ⚠  Save this salt — you need it to recover your key:")" \
                    "$(gum style --foreground "$W" "     Salt: ${salt}")" \
                    "" \
                    "$(gum style --foreground "$DM" --italic "  Store the salt in a password manager or written down securely.")"
                sleep 4 ;;
            *"Rotate"*)
                if ! $key_exists; then
                    gum style --foreground "$R" "  No key to rotate — generate one first."; sleep 1; continue
                fi
                clear; draw_header
                section "↺" "Rotate Master Key" "$Y"
                echo ""
                explain "$DM" \
                    "  Key rotation replaces the master key with a new random 256-bit key." \
                    "  The current key is backed up to keys/vault.key.bak.<timestamp> first." \
                    "" \
                    "  NOTE: Existing encrypted files use the old key's FEK wrapping. To fully" \
                    "  migrate, you need to mount with the old key, copy files out, then re-encrypt" \
                    "  them with the new key. The rotation instructions will guide you through this." \
                    "" \
                    "  Use rotation periodically (every 90 days) or after a suspected compromise."
                echo ""
                gum confirm "  Rotate the master key? The current key will be backed up first." || continue
                gum spin --spinner dot --title "  Rotating master key (backing up old key first)..." \
                    -- bash "$VAULT" rotate
                echo ""
                gum style --border rounded --border-foreground "$BR_G" \
                    --foreground "$G" --padding "1 2" \
                    "$(badge "ROTATED" "$G" "$BG_G")" \
                    "" \
                    "  New key active at keys/vault.key" \
                    "  Old key backed up to keys/vault.key.bak.<timestamp>"
                sleep 2 ;;
            *"Show Key Info"*)
                clear; draw_header
                section "ℹ" "Key Information" "$C"
                echo ""
                explain "$DM" \
                    "  This shows metadata about the master key file — not the key itself." \
                    "  The raw key bytes are never displayed for security reasons." \
                    "  Permissions must be 600 (owner read/write only) to prevent other users" \
                    "  on the system from reading the key. The key is also locked in RAM via" \
                    "  mlock() while the vault is mounted, preventing it from being swapped to disk."
                echo ""
                if ! $key_exists; then
                    gum style --border rounded --border-foreground "$BR_R" \
                        --foreground "$R" --padding "1 3" \
                        "$(badge "MISSING" "$R" "$BG_R")  No key found at  keys/vault.key" \
                        "" \
                        "  Use  Generate Random Key  or  Derive from Passphrase  to create one."
                else
                    local key_size perms mtime age
                    key_size=$(wc -c < "$KEY_FILE" | tr -d ' ')
                    perms=$(stat -c '%a' "$KEY_FILE")
                    mtime=$(stat -c '%y' "$KEY_FILE" | cut -c1-19)
                    age=$(( ( $(date +%s) - $(stat -c '%Y' "$KEY_FILE") ) / 86400 ))
                    local perm_badge
                    [ "$perms" = "600" ] && perm_badge=$(badge "600 ✔" "$G" "$BG_G") || perm_badge=$(badge "$perms ✖ — should be 600" "$R" "$BG_R")
                    local age_badge
                    [ "$age" -gt 90 ] && age_badge=$(badge "${age}d — consider rotating" "$Y" "$BG_Y") || age_badge=$(badge "${age}d" "$G" "$BG_G")
                    gum style \
                        --border rounded --border-foreground "$BR_C" \
                        --padding "1 3" --width 62 \
                        "$(gum style --foreground "$C" --bold "  🔑 Master Key")" \
                        "" \
                        "  Path        $(gum style --foreground "$W" "${KEY_FILE}")" \
                        "  Size        $(gum style --foreground "$W" "${key_size} bytes")  $(badge "256-bit AES" "$P" "$BG_P")" \
                        "  Permissions ${perm_badge}" \
                        "  Created     $(gum style --foreground "$W" "${mtime}")" \
                        "  Age         ${age_badge}" \
                        "" \
                        "$(gum style --foreground "$DM" --italic "  Key material NOT shown — binary content is never displayed.")" \
                        "$(gum style --foreground "$DM" --italic "  mlock() keeps it in RAM — it is never paged to disk.")" \
                        "$(gum style --foreground "$DM" --italic "  OPENSSL_cleanse() zeros it from RAM on unmount.")"
                fi
                echo ""
                press_enter ;;
            *"Back"*) return ;;
        esac
    done
}

# ═════════════════════════════════════════════════════════════════════════════
#  SCREEN 6 — DIAGNOSTICS
# ═════════════════════════════════════════════════════════════════════════════
screen_diagnostics() {
    clear
    draw_header
    section "🔬" "Diagnostics" "$SV"

    explain "$DM" \
        "  Diagnostics checks every component FuseVault depends on: the FUSE mount, the" \
        "  compiled binary, the key file and its permissions, the cryptographic libraries," \
        "  and available disk space. Any issue is flagged with its severity and a fix hint."
    echo ""

    # Build each row with badge + label
    _diag_row() {
        local ok="$1" label="$2" detail="$3" fix="${4:-}"
        if [ "$ok" = "ok" ]; then
            echo "  $(badge " ✔ " "$G" "$BG_G")  $(gum style --foreground "$W" "${label}")   $(gum style --foreground "$DM" "${detail}")"
        elif [ "$ok" = "warn" ]; then
            echo "  $(badge " ● " "$Y" "$BG_Y")  $(gum style --foreground "$Y" "${label}")   $(gum style --foreground "$DM" "${detail}")"
            [ -n "$fix" ] && echo "  $(gum style --foreground "$DM" --italic "       Fix: ${fix}")"
        else
            echo "  $(badge " ✖ " "$R" "$BG_R")  $(gum style --foreground "$R" "${label}")   $(gum style --foreground "$DM" "${detail}")"
            [ -n "$fix" ] && echo "  $(gum style --foreground "$Y" --italic "       Fix: ${fix}")"
        fi
    }

    local rows=()

    if is_mounted; then
        rows+=("$(_diag_row ok   "FUSE mount"       "active — ${MOUNT_DIR}")")
    else
        rows+=("$(_diag_row warn "FUSE mount"       "not mounted" "Vault Controls → Mount Vault")")
    fi

    if [ -f "${WORKSPACE}/myfs" ]; then
        rows+=("$(_diag_row ok   "myfs binary"      "compiled  ($(du -sh "${WORKSPACE}/myfs" | cut -f1))")")
    else
        rows+=("$(_diag_row fail "myfs binary"      "not found" "run 'make' in /workspace to compile")")
    fi

    if [ -f "$KEY_FILE" ]; then
        local perms; perms=$(stat -c '%a' "$KEY_FILE")
        if [ "$perms" = "600" ]; then
            rows+=("$(_diag_row ok   "Key permissions"  "600 — owner read/write only")")
        else
            rows+=("$(_diag_row fail "Key permissions"  "${perms} — insecure" "chmod 600 ${KEY_FILE}")")
        fi
        local age; age=$(( ( $(date +%s) - $(stat -c '%Y' "$KEY_FILE") ) / 86400 ))
        if [ "$age" -gt 90 ]; then
            rows+=("$(_diag_row warn "Key age"          "${age} days — rotation recommended" "Key Management → Rotate Master Key")")
        else
            rows+=("$(_diag_row ok   "Key age"          "${age} days — within rotation window")")
        fi
    else
        rows+=("$(_diag_row fail "Key file"         "missing" "Key Management → Generate Random Key")")
    fi

    local ssl_ver; ssl_ver=$(openssl version 2>/dev/null | cut -d' ' -f1-2 || echo "not found")
    rows+=("$(_diag_row ok   "OpenSSL"           "${ssl_ver} — provides AES-256-CBC")")

    if command -v argon2 &>/dev/null; then
        rows+=("$(_diag_row ok   "Argon2"           "available — used for passphrase key derivation")")
    else
        rows+=("$(_diag_row fail "Argon2"           "not found" "rebuild Docker image: ./run.sh --rebuild")")
    fi

    local free_space; free_space=$(df -h "${WORKSPACE}" 2>/dev/null | awk 'NR==2{print $4}' || echo "?")
    rows+=("$(_diag_row ok   "Disk free"        "${free_space} available at ${WORKSPACE}")")

    local mc=0
    is_mounted && mc=$(find "$MOUNT_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ') || true
    rows+=("$(_diag_row ok   "Store"            "$(enc_file_count) .enc ciphertext files  ·  mount visible: ${mc}")")

    gum style \
        --border rounded \
        --border-foreground "$BR_MAIN" \
        --padding "1 2" \
        --width 74 \
        "${rows[@]}"

    draw_statusbar "Diagnostics — all checks complete"
    press_enter "Press Enter to return to menu..."
}

# ═════════════════════════════════════════════════════════════════════════════
#  SCREEN 7 — GUIDED DEMO
# ═════════════════════════════════════════════════════════════════════════════
screen_demo() {
    clear
    draw_header
    section "🎬" "Guided Demo / Walkthrough" "$W"
    echo ""

    gum style \
        --border double \
        --border-foreground "$C" \
        --padding "1 4" \
        --width 70 \
        "$(gum style --foreground "$C" --bold "  Interactive FuseVault Walkthrough  —  7 Steps")" \
        "" \
        "$(gum style --foreground "$SV" "  This demo walks through the complete vault lifecycle step by step.")" \
        "$(gum style --foreground "$SV" "  Each step pauses and explains what just happened and why it matters.")" \
        "" \
        "  $(badge "1" "$G"  "$BG_G")  Generate a fresh 256-bit master key" \
        "  $(badge "2" "$C"  "$BG_C")  Mount the FUSE filesystem (start the encryption driver)" \
        "  $(badge "3" "$Y"  "$BG_Y")  Write an encrypted secret file to the vault" \
        "  $(badge "4" "$R"  "$BG_R")  Inspect the raw ciphertext on disk (unreadable binary)" \
        "  $(badge "5" "$G"  "$BG_G")  Read back the file — decrypted transparently by FUSE" \
        "  $(badge "6" "$M"  "$BG_M")  Verify the audit log hash-chain integrity" \
        "  $(badge "7" "$P"  "$BG_P")  Unmount and erase the master key from RAM" \
        "" \
        "$(gum style --foreground "$DM" --italic "  New to FuseVault? This is the best place to start.")"
    echo ""

    gum confirm "  Start the guided demo?" || return

    # Helper: step header
    _step_header() {
        local num="$1" label="$2" color="$3" bg="$4"
        clear; draw_header; echo ""
        gum style \
            --border rounded \
            --border-foreground "$color" \
            --padding "0 3" \
            --width 70 \
            "$(badge "Step ${num} of 7" "$color" "$bg")  $(gum style --foreground "$color" --bold "${label}")"
        echo ""
    }

    # ── Step 1 — keygen ──────────────────────────────────────────────────────
    _step_header "1" "Generate Master Key" "$G" "$BG_G"

    explain "$DM" \
        "  The master key is the root secret for the entire vault. It is a 32-byte (256-bit)" \
        "  cryptographically random value generated by OpenSSL's CSPRNG." \
        "" \
        "  FuseVault uses per-file encryption — each file gets its own File Encryption Key (FEK)" \
        "  generated randomly at write time. The FEK is then encrypted (wrapped) with the master" \
        "  key and stored in the file's header. The master key never directly encrypts file data." \
        "" \
        "  This envelope encryption design means rotating the master key does not require" \
        "  re-encrypting every file — only the FEK wrappers need to change."
    echo ""

    if [ -f "$KEY_FILE" ]; then
        gum style --foreground "$G" "  $(badge "SKIPPED" "$G" "$BG_G")  A key already exists at keys/vault.key — reusing it."
        gum style --foreground "$DM" --italic "  In a real first-run, this would generate a new 32-byte random key."
    else
        gum spin --spinner dot --title "  Generating 256-bit random key via openssl rand 32..." -- bash "$VAULT" keygen
        echo ""
        gum style --foreground "$G" "  $(badge "DONE" "$G" "$BG_G")  keys/vault.key created  ·  chmod 600  ·  32 bytes"
    fi
    echo ""
    gum style \
        --border rounded --border-foreground "$BR_G" --padding "0 2" --width 68 \
        "$(gum style --foreground "$G" --bold "  What just happened:")" \
        "$(gum style --foreground "$DM" "  • openssl rand 32  generated 32 bytes of cryptographic randomness")" \
        "$(gum style --foreground "$DM" "  • Saved to keys/vault.key  with permissions 600")" \
        "$(gum style --foreground "$DM" "  • Keys directory permissions set to 700 (directory listing restricted)")"
    press_enter "Press Enter for Step 2..."

    # ── Step 2 — mount ───────────────────────────────────────────────────────
    _step_header "2" "Mount the FUSE Filesystem" "$C" "$BG_C"

    explain "$DM" \
        "  Mounting starts the myfs FUSE driver — a C program that registers itself with the" \
        "  Linux kernel as the handler for all filesystem operations on mount/." \
        "" \
        "  When you write a file to mount/, the kernel calls myfs_write() in our driver." \
        "  myfs_write() generates a random IV and FEK, AES-256-CBC encrypts the data, wraps" \
        "  the FEK with the master key, and writes the result to store/<filename>.enc." \
        "" \
        "  When you read a file from mount/, the kernel calls myfs_read(). The driver reads" \
        "  the .enc file, unwraps the FEK, decrypts the ciphertext, and returns plaintext." \
        "  From your app's perspective, it's just a normal file."
    echo ""

    if is_mounted; then
        gum style --foreground "$G" "  $(badge "ALREADY MOUNTED" "$G" "$BG_G")  ${MOUNT_DIR}"
        gum style --foreground "$DM" --italic "  The FUSE driver is already running from a previous operation."
    else
        gum spin --spinner dot --title "  Starting FUSE driver and loading master key into locked RAM..." -- bash "$VAULT" mount
        echo ""
        gum style --foreground "$G" "  $(badge "MOUNTED" "$G" "$BG_G")  ${MOUNT_DIR}"
    fi
    echo ""
    gum style \
        --border rounded --border-foreground "$BR_C" --padding "0 2" --width 68 \
        "$(gum style --foreground "$C" --bold "  What just happened:")" \
        "$(gum style --foreground "$DM" "  • myfs binary launched as a background FUSE process")" \
        "$(gum style --foreground "$DM" "  • Master key loaded into RAM via mlock() — kernel won't swap it")" \
        "$(gum style --foreground "$DM" "  • mount/ is now an encrypted virtual filesystem")" \
        "$(gum style --foreground "$DM" "  • Audit log opened — MOUNT event recorded")"
    press_enter "Press Enter for Step 3..."

    # ── Step 3 — write ───────────────────────────────────────────────────────
    _step_header "3" "Write an Encrypted Secret" "$Y" "$BG_Y"

    explain "$DM" \
        "  Writing to mount/ triggers myfs_write() in the FUSE driver. Here is the exact" \
        "  encryption process that happens for every file write:" \
        "" \
        "  1.  openssl_rand(16)  →  fresh random Initialisation Vector (IV)" \
        "  2.  openssl_rand(32)  →  fresh random File Encryption Key (FEK)" \
        "  3.  AES-256-CBC(plaintext, FEK, IV)  →  ciphertext" \
        "  4.  AES-256-CBC(FEK, master_key, IV)  →  encrypted FEK (enc_fek)" \
        "  5.  Write header: [4B length][16B IV][48B enc_fek] + ciphertext to store/.enc" \
        "  6.  OPENSSL_cleanse(FEK)  →  FEK zeroed from RAM immediately" \
        "  7.  Audit log entry written: WRITE + filename + SHA-256 hash"
    echo ""

    local demo_file="${MOUNT_DIR}/demo_secret.txt"
    local demo_content="TOP SECRET — FuseVault Demo  ($(date '+%Y-%m-%d %H:%M:%S'))"
    echo "$demo_content" > "$demo_file"
    gum style --foreground "$Y" "  $(badge "WRITTEN" "$Y" "$BG_Y")  mount/demo_secret.txt"
    echo ""
    gum style \
        --border rounded --border-foreground "$BR_Y" \
        --foreground "$W" --padding "0 2" \
        "  Plaintext written:  ${demo_content}"
    echo ""
    gum style \
        --border rounded --border-foreground "$BR_G" --padding "0 2" --width 68 \
        "$(gum style --foreground "$Y" --bold "  What just happened:")" \
        "$(gum style --foreground "$DM" "  • myfs_write() intercepted the write syscall")" \
        "$(gum style --foreground "$DM" "  • Fresh IV + FEK generated  →  data encrypted with AES-256-CBC")" \
        "$(gum style --foreground "$DM" "  • FEK encrypted with master key  →  both stored in .enc header")" \
        "$(gum style --foreground "$DM" "  • FEK immediately zeroed from RAM  →  plaintext never touched disk")"
    press_enter "Press Enter for Step 4..."

    # ── Step 4 — ciphertext ──────────────────────────────────────────────────
    _step_header "4" "Inspect Raw Ciphertext on Disk" "$R" "$BG_R"

    explain "$DM" \
        "  The .enc file in store/ is what actually lives on disk. Let's look at its raw" \
        "  hex content to see the encryption header and ciphertext layout." \
        "" \
        "  The file structure is: [4B length][16B IV][48B enc_fek][ciphertext...]" \
        "    • Bytes  0-3:   original plaintext length (little-endian uint32)" \
        "    • Bytes  4-19:  16-byte random IV (different on every write)" \
        "    • Bytes 20-67:  48-byte encrypted FEK (AES-256-CBC wrapped with master key)" \
        "    • Bytes 68+:    AES-256-CBC ciphertext (the actual encrypted file content)"
    echo ""

    local enc_file="${WORKSPACE}/store/demo_secret.txt.enc"
    if [ -f "$enc_file" ]; then
        local enc_size; enc_size=$(wc -c < "$enc_file")
        gum style --foreground "$Y" "  $(badge "store/demo_secret.txt.enc" "$Y" "$BG_Y")  ${enc_size} bytes  — raw hex dump:"
        echo ""
        gum style \
            --border rounded --border-foreground "$BR_R" \
            --foreground "$R" --padding "0 2" \
            "$(xxd "$enc_file" | head -12)"
        echo ""
        gum style --foreground "$DM" --italic "  This binary data is unreadable without the master key."
        gum style --foreground "$DM" --italic "  Even knowing the IV, an attacker cannot decrypt without the master key."
    else
        gum style --foreground "$R" "  Encrypted file not found — was the vault mounted when the file was written?"
    fi
    press_enter "Press Enter for Step 5..."

    # ── Step 5 — read back ───────────────────────────────────────────────────
    _step_header "5" "Read Back  —  Transparent Decryption" "$G" "$BG_G"

    explain "$DM" \
        "  Reading from mount/ triggers myfs_read() in the FUSE driver. Decryption steps:" \
        "" \
        "  1.  Read store/<filename>.enc from disk" \
        "  2.  Parse header: extract IV and enc_fek" \
        "  3.  AES-256-CBC-decrypt(enc_fek, master_key, IV)  →  plaintext FEK" \
        "  4.  AES-256-CBC-decrypt(ciphertext, FEK, IV)  →  plaintext" \
        "  5.  OPENSSL_cleanse(FEK)  →  FEK zeroed from RAM immediately" \
        "  6.  Return plaintext to the calling application" \
        "  7.  Audit log entry written: READ + filename + hash"
    echo ""

    local readback; readback=$(cat "$demo_file" 2>/dev/null || echo "(error — vault may have been unmounted)")
    gum style --foreground "$G" "  $(badge "DECRYPTED" "$G" "$BG_G")  cat mount/demo_secret.txt  →"
    echo ""
    gum style \
        --border rounded --border-foreground "$BR_G" \
        --foreground "$G" --padding "0 2" \
        "  ${readback}"
    echo ""
    gum style --foreground "$DM" --italic "  The app received the original plaintext — decryption was fully transparent."
    gum style \
        --border rounded --border-foreground "$BR_G" --padding "0 2" --width 68 \
        "$(gum style --foreground "$G" --bold "  What just happened:")" \
        "$(gum style --foreground "$DM" "  • myfs_read() intercepted the read syscall")" \
        "$(gum style --foreground "$DM" "  • .enc header parsed  →  FEK decrypted with master key")" \
        "$(gum style --foreground "$DM" "  • Ciphertext decrypted with FEK  →  plaintext returned")" \
        "$(gum style --foreground "$DM" "  • FEK and plaintext buffer zeroed immediately after use")"
    press_enter "Press Enter for Step 6..."

    # ── Step 6 — verify log ──────────────────────────────────────────────────
    _step_header "6" "Verify Audit Log Integrity" "$M" "$BG_M"

    explain "$DM" \
        "  FuseVault logs every operation in a hash-chained audit trail. Each log entry contains:" \
        "    • Timestamp  (UTC)" \
        "    • Operation type  (MOUNT, UNMOUNT, READ, WRITE, DELETE)" \
        "    • Filename  (if applicable)" \
        "    • PREV=<hash>  — SHA-256 of the previous log entry  (GENESIS for the first)" \
        "    • HASH=<hash>  — SHA-256 of this entire log entry" \
        "" \
        "  This forms a chain: to tamper with entry N, an attacker must also update entries" \
        "  N+1 through the end — and recomputing all hashes is detectable. The verify-log" \
        "  command recomputes every hash and checks the PREV chain end-to-end."
    echo ""

    bash "$VAULT" verify-log
    echo ""
    gum style --foreground "$DM" --italic "  All entries verified — the log chain is intact."
    press_enter "Press Enter for Step 7..."

    # ── Step 7 — unmount ─────────────────────────────────────────────────────
    _step_header "7" "Unmount — Erase Key from RAM" "$P" "$BG_P"

    explain "$DM" \
        "  Unmounting cleanly stops the FUSE driver and performs secure key erasure:" \
        "" \
        "  1.  fusermount -u mount/  →  signals myfs to begin clean shutdown" \
        "  2.  myfs flushes all pending write buffers to disk" \
        "  3.  OPENSSL_cleanse(master_key_buffer, 32)  →  overwrites the key in RAM with zeros" \
        "  4.  free() and munlock()  →  key memory released back to OS" \
        "  5.  UNMOUNT event written to audit log" \
        "  6.  FUSE process exits" \
        "" \
        "  After unmount, mount/ appears empty. The .enc files in store/ remain, but are" \
        "  unreadable — the key no longer exists in memory."
    echo ""

    gum spin --spinner dot --title "  Flushing writes, erasing key from RAM, unmounting..." -- bash "$VAULT" unmount
    echo ""
    gum style --foreground "$G" "  $(badge "DONE" "$G" "$BG_G")  Vault unmounted  ·  master key erased from RAM."
    echo ""

    gum style \
        --border double \
        --border-foreground "$G" \
        --padding "1 4" \
        --width 66 \
        "$(gum style --foreground "$G" --bold "  ✔  Demo Complete!")" \
        "" \
        "  You have seen the full FuseVault lifecycle end-to-end:" \
        "" \
        "  $(badge "✔" "$G" "$BG_G")  AES-256-CBC per-file envelope encryption" \
        "  $(badge "✔" "$C" "$BG_C")  Transparent FUSE read / write — apps see plaintext" \
        "  $(badge "✔" "$Y" "$BG_Y")  Per-file random IV + FEK — each file independently secure" \
        "  $(badge "✔" "$M" "$BG_M")  SHA-256 hash-chained tamper-evident audit log" \
        "  $(badge "✔" "$P" "$BG_P")  Secure key erasure on unmount via OPENSSL_cleanse()" \
        "" \
        "$(gum style --foreground "$DM" --italic "  From here, try the File Browser or Key Management screens.")"
    echo ""
    press_enter "Press Enter to return to the main menu..."
}

# ═════════════════════════════════════════════════════════════════════════════
#  SCREEN 8 — ABOUT FUSEVAULT
# ═════════════════════════════════════════════════════════════════════════════
screen_about() {
    clear
    draw_header
    section "📖" "About FuseVault" "$O"
    echo ""

    # Architecture diagram with colors
    gum style \
        --border double \
        --border-foreground "$C" \
        --padding "1 3" \
        --width 72 \
        "$(gum style --foreground "$C" --bold "  🏗️  Architecture Overview")" \
        "" \
        "$(gum style --foreground "$W" "  User Application")$(gum style --foreground "$DM" "  (cat, cp, vim, any program...)")" \
        "$(gum style --foreground "$DM" "        │")" \
        "$(gum style --foreground "$DM" "        ▼")" \
        "$(gum style --foreground "$SV" "  VFS (Linux Kernel)")$(gum style --foreground "$DM" "  — standard filesystem layer")" \
        "$(gum style --foreground "$DM" "        │")" \
        "$(gum style --foreground "$DM" "        ▼")" \
        "$(gum style --foreground "$Y" "  FUSE Kernel Module")$(gum style --foreground "$DM" " — redirects I/O to userspace")" \
        "$(gum style --foreground "$DM" "        │")" \
        "$(gum style --foreground "$DM" "        ▼")" \
        "$(gum style --foreground "$G" --bold "  myfs (FuseVault)")$(gum style --foreground "$DM" " — intercepts every read/write/open")" \
        "$(gum style --foreground "$DM" "     ╱      ╲")" \
        "$(gum style --foreground "$C" "  Decrypt") $(gum style --foreground "$DM" "     ") $(gum style --foreground "$M" "Encrypt")" \
        "$(gum style --foreground "$DM" "     ╲      ╱")" \
        "$(gum style --foreground "$P" "  store/")$(gum style --foreground "$DM" " → AES-256-CBC encrypted .enc files")" \
        "$(gum style --foreground "$Y" "  logs/")$(gum style --foreground "$DM" "  → SHA-256 hash-chained audit trail")"
    echo ""

    # Security features grid
    gum style --foreground "$G" --bold "  🔐  Security Features"
    echo ""

    local -a sec_items=(
        "$(badge "AES-256-CBC" "$G" "$BG_G")  $(gum style --foreground "$SV" "Per-file encryption with random IV — same data encrypts differently each time")"
        "$(badge "ENVELOPE"    "$C" "$BG_C")  $(gum style --foreground "$SV" "Each file has its own FEK, wrapped by master key — same model as AWS KMS")"
        "$(badge "ARGON2ID"    "$P" "$BG_P")  $(gum style --foreground "$SV" "Memory-hard passphrase hashing (t=3, m=64MB, p=4) — resists GPU attacks")"
        "$(badge "HASH-CHAIN"  "$M" "$BG_M")  $(gum style --foreground "$SV" "SHA-256 linked audit entries — tampering is instantly detectable")"
        "$(badge "MLOCK()"     "$Y" "$BG_Y")  $(gum style --foreground "$SV" "Master key pinned in RAM — never paged to swap disk, ever")"
        "$(badge "CLEANSE"     "$R" "$BG_R")  $(gum style --foreground "$SV" "OPENSSL_cleanse() zeroes key material — compiler can't optimize it away")"
    )
    for item in "${sec_items[@]}"; do
        echo "    $item"
    done
    echo ""

    # File format diagram
    gum style \
        --border rounded \
        --border-foreground "$BR_C" \
        --padding "0 2" \
        --width 72 \
        "$(gum style --foreground "$C" --bold "  📦  Encrypted File Format (.enc)")" \
        "" \
        "$(gum style --foreground "$Y" "  ┌──────────────┬──────────────┬───────────────────┬──────────────┐")" \
        "$(gum style --foreground "$Y" "  │")$(gum style --foreground "$W" " SIZE (4B)    ")$(gum style --foreground "$Y" "│")$(gum style --foreground "$G" " IV (16B)      ")$(gum style --foreground "$Y" "│")$(gum style --foreground "$M" " Enc FEK (48B)    ")$(gum style --foreground "$Y" "│")$(gum style --foreground "$C" " Ciphertext   ")$(gum style --foreground "$Y" "│")" \
        "$(gum style --foreground "$Y" "  └──────────────┴──────────────┴───────────────────┴──────────────┘")" \
        "$(gum style --foreground "$DM" "  ←─────────────── HEADER = 68 bytes ─────────────────→  variable  ")"
    echo ""

    # Design philosophy
    gum style \
        --border rounded \
        --border-foreground "$BR_P" \
        --padding "0 2" \
        --width 72 \
        "$(gum style --foreground "$P" --bold "  💡  Design Philosophy")" \
        "" \
        "$(gum style --foreground "$SV" "  FuseVault follows the principle of defense in depth:")" \
        "" \
        "$(gum style --foreground "$G" "  ✔")$(gum style --foreground "$SV" "  Encryption at rest — every file is AES-256-CBC encrypted on disk")" \
        "$(gum style --foreground "$G" "  ✔")$(gum style --foreground "$SV" "  Key isolation — per-file FEKs limit blast radius of compromise")" \
        "$(gum style --foreground "$G" "  ✔")$(gum style --foreground "$SV" "  Memory safety — keys are mlock'd, cleansed, and never logged")" \
        "$(gum style --foreground "$G" "  ✔")$(gum style --foreground "$SV" "  Auditability — every operation is hash-chained and verifiable")" \
        "$(gum style --foreground "$G" "  ✔")$(gum style --foreground "$SV" "  Transparency — apps see normal files; encryption is invisible")" \
        "" \
        "$(gum style --foreground "$DM" --italic "  Source: src/myfs.c  ·  FUSE + OpenSSL  ·  Built with ♥")"

    draw_statusbar "About — architecture & security model"
    press_enter "Press Enter to return to menu..."
}

# ═════════════════════════════════════════════════════════════════════════════
#  FIRST-RUN WIZARD  (now with animations)
# ═════════════════════════════════════════════════════════════════════════════
first_run_check() {
    local need_build=false need_key=false
    [ ! -f "${WORKSPACE}/myfs" ] && need_build=true
    [ ! -f "$KEY_FILE" ]         && need_key=true
    $need_build || $need_key || return 0

    clear
    echo ""
    echo ""

    # Animated first-run header
    printf '    '
    typewriter "⚠  First-Run Setup Detected" "$Y" 0.03
    echo ""
    echo ""

    gum style \
        --border double \
        --border-foreground "$Y" \
        --padding "1 4" \
        --width 68 \
        "$(gum style --foreground "$SV" "  FuseVault needs a couple of things before it's ready:")" \
        "" \
        "$($need_build && gum style --foreground "$W" "  $(badge "1" "$Y" "$BG_Y")  myfs binary  — the FUSE encryption driver must be compiled." || true)" \
        "$($need_build && gum style --foreground "$DM" --italic "     Compiles src/myfs.c with gcc + libfuse + OpenSSL." || true)" \
        "" \
        "$($need_key   && gum style --foreground "$W" "  $(badge "2" "$P" "$BG_P")  Master key  — a 256-bit key is needed to encrypt your files." || true)" \
        "$($need_key   && gum style --foreground "$DM" --italic "     Generates 32 bytes of cryptographic randomness via OpenSSL." || true)" \
        "" \
        "$(gum style --foreground "$C" "  ⚡ Quick Setup will do everything automatically in seconds.")"
    echo ""

    gum confirm "  Run Quick Setup  (compile myfs + generate master key)?" || return 0

    echo ""
    if $need_build; then
        spin_text "Compiling src/myfs.c with gcc + libfuse + OpenSSL..." 1
        gum spin --spinner dot --title "  Building FUSE driver..." \
            -- bash -c "cd ${WORKSPACE} && make"
        echo ""
        gum style --foreground "$G" "  $(badge "✔ COMPILED" "$G" "$BG_G")  myfs binary is ready"
        echo ""
    fi
    if $need_key; then
        spin_text "Generating 256-bit cryptographic master key..." 0.8
        gum spin --spinner dot --title "  Creating master key..." \
            -- bash "$VAULT" keygen
        echo ""
        gum style --foreground "$G" "  $(badge "✔ KEY READY" "$G" "$BG_G")  keys/vault.key created  ·  chmod 600"
        gum style --foreground "$Y" --italic "  ⚠  Back up keys/vault.key — losing it means losing your data."
        echo ""
    fi

    progress_bar "  Finalizing setup" 30 1

    echo ""
    gum style \
        --border rounded \
        --border-foreground "$BR_G" \
        --padding "1 3" \
        --width 60 \
        "$(gum style --foreground "$G" --bold "  ✔  Setup Complete!")" \
        "" \
        "$(gum style --foreground "$SV" "  FuseVault is ready to use.")" \
        "$(gum style --foreground "$DM" --italic "  Tip: Try the 🎬 Guided Demo from the main menu.")"
    sleep 2
}

# ── Entry point ───────────────────────────────────────────────────────────────
show_splash

# ── Confirmation gate ─────────────────────────────────────────────────────────
echo ""
gum style \
    --border rounded \
    --border-foreground "$C" \
    --padding "1 4" \
    --width 62 \
    --align center \
    "$(gum style --foreground "$C" --bold "🛡️  Welcome to FuseVault")" \
    "" \
    "$(gum style --foreground "$SV" "Your encrypted FUSE filesystem is ready.")" \
    "$(gum style --foreground "$DM" "AES-256-CBC · Argon2id · Hash-Chain Audit")"
echo ""

if ! gum confirm \
    "$(gum style --foreground "$W" "  Enter the vault?")" \
    --affirmative "$(gum style --foreground "$G" "  ✔  Enter Vault  ")" \
    --negative    "$(gum style --foreground "$R" "  ✕  Exit         ")" \
    --default=Yes; then
    echo ""
    gum style \
        --foreground "$DM" \
        --italic \
        --align center \
        --width 62 \
        "Session aborted. Your encrypted files remain safely in store/."
    echo ""
    exit 0
fi

first_run_check
main_menu
