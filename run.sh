#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
#  FuseVault — Mac Launcher
#  Builds the Docker image if needed, starts the container, and launches
#  the interactive TUI inside it.
#
#  Usage:  ./run.sh [--rebuild | --clean | --help]
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="fusevault"
CONTAINER_NAME="fusevault-dev"
START_TIME=$(date +%s)
BUILD_LOG="/tmp/fusevault_build.log"

# ── CLI flags ─────────────────────────────────────────────────────────────────
FLAG_REBUILD=false
FLAG_CLEAN=false

for arg in "$@"; do
    case "$arg" in
        --rebuild) FLAG_REBUILD=true ;;
        --clean)   FLAG_CLEAN=true   ;;
        --help|-h)
            echo ""
            echo "  FuseVault — Mac Launcher"
            echo "  Builds the Docker image, starts the container, and launches the TUI."
            echo ""
            echo "  Usage: ./run.sh [OPTIONS]"
            echo ""
            echo "  Options:"
            echo "    (none)      Start FuseVault — reuse existing container/image if available"
            echo "    --rebuild   Force rebuild the Docker image (picks up Dockerfile changes)"
            echo "    --clean     Tear down the existing container and image, then rebuild from scratch"
            echo "    --help      Show this help message"
            echo ""
            echo "  First time?"
            echo "    Just run:  ./run.sh"
            echo "    The launcher will build the image (~2 min first time) and open the TUI."
            echo "    Inside the TUI, choose 'Guided Demo' for a step-by-step walkthrough."
            echo ""
            echo "  Common workflows:"
            echo "    ./run.sh              — reconnect to a running or stopped container"
            echo "    ./run.sh --rebuild    — pick up Dockerfile changes without losing data"
            echo "    ./run.sh --clean      — full reset: removes container, image, and rebuilds"
            echo ""
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Run './run.sh --help' to see available options."
            exit 1
            ;;
    esac
done

# ── Colours ───────────────────────────────────────────────────────────────────
R='\033[0;31m'       G='\033[0;32m'       Y='\033[1;33m'
C='\033[0;36m'       M='\033[0;35m'       W='\033[1;37m'
DIM='\033[2m'        BOLD='\033[1m'       NC='\033[0m'
LG='\033[1;32m'

TEAL='\033[38;5;37m'     GOLD='\033[38;5;220m'   SKY='\033[38;5;117m'
LIME='\033[38;5;154m'    SILVER='\033[38;5;250m'  ORANGE='\033[38;5;208m'

# ── Output helpers ────────────────────────────────────────────────────────────
step()   { echo -e "\n  ${SKY}▶${NC}  ${BOLD}${W}$1${NC}"; }
ok()     { echo -e "  ${LG}✔${NC}  $1"; }
warn()   { echo -e "  ${ORANGE}⚠${NC}  $1"; }
err()    { echo -e "  ${R}✖${NC}  $1" >&2; }
info()   { echo -e "  ${SILVER}ℹ${NC}  ${DIM}${SILVER}$1${NC}"; }
detail() { echo -e "     ${DIM}${SILVER}$1${NC}"; }

elapsed() { echo "$(( $(date +%s) - START_TIME ))s"; }

spinner() {
    local pid=$1 msg="$2" spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
    while kill -0 "$pid" 2>/dev/null; do
        local c="${spin:$((i % ${#spin})):1}"
        printf "\r  ${TEAL}%s${NC}  ${W}%s${NC}...  ${DIM}${SILVER}(%ds)${NC}" \
            "$c" "$msg" "$(( i * 8 / 100 ))"
        sleep 0.08; i=$((i + 1))
    done
    printf "\r  ${LG}✔${NC}  ${W}%s${NC}  ${DIM}${SILVER}(%ds)${NC}      \n" \
        "$msg" "$(( i * 8 / 100 ))"
}

# ── Phase header ──────────────────────────────────────────────────────────────
phase() {
    local num="$1" icon="$2" color="$3" title="$4"
    echo ""
    echo -e "  ${TEAL}────────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${color}${BOLD}${icon} PHASE ${num}${NC}  ${DIM}${SILVER}│${NC}  ${BOLD}${W}${title}${NC}"
    echo -e "  ${TEAL}────────────────────────────────────────────────────────────────${NC}"
}

# ── Pre-flight counters ───────────────────────────────────────────────────────
CHECKS_PASS=0 CHECKS_WARN=0 CHECKS_FAIL=0
check_ok()   { ok "$1";   CHECKS_PASS=$((CHECKS_PASS + 1)); }
check_warn() { warn "$1"; CHECKS_WARN=$((CHECKS_WARN + 1)); }
check_fail() { err "$1";  CHECKS_FAIL=$((CHECKS_FAIL + 1)); }

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo -e "\033[38;5;45m  ███████╗██╗   ██╗███████╗███████╗██╗   ██╗ █████╗ ██╗   ██╗██╗ ████████╗${NC}"
echo -e "\033[38;5;44m  ██╔════╝██║   ██║██╔════╝██╔════╝██║   ██║██╔══██╗██║   ██║██║ ╚══██╔══╝${NC}"
echo -e "\033[38;5;43m  █████╗  ██║   ██║███████╗█████╗  ██║   ██║███████║██║   ██║██║    ██║   ${NC}"
echo -e "\033[38;5;42m  ██╔══╝  ██║   ██║╚════██║██╔══╝  ╚██╗ ██╔╝██╔══██║██║   ██║██║    ██║   ${NC}"
echo -e "\033[38;5;41m  ██║     ╚██████╔╝███████║███████╗ ╚████╔╝ ██║  ██║╚██████╔╝███████╗██║   ${NC}"
echo -e "\033[38;5;40m  ╚═╝      ╚═════╝ ╚══════╝╚══════╝  ╚═══╝  ╚═╝  ╚═╝ ╚═════╝╚══════╝╚═╝   ${NC}"
echo ""
echo -e "  ${TEAL}────────────────────────────────────────────────────────────────────────────${NC}"
echo -e "  ${DIM}${SILVER}  Encrypted FUSE Filesystem  ·  AES-256-CBC  ·  Argon2id  ·  Hash-Chain Audit${NC}"
echo -e "  ${TEAL}────────────────────────────────────────────────────────────────────────────${NC}"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
#  PHASE 1 — PRE-FLIGHT
# ══════════════════════════════════════════════════════════════════════════════
phase 1 "🛠" "$SKY" "Pre-flight Checks  —  verifying Docker, FUSE device, and project files"

step "System Information"
HOST_OS=$(sw_vers -productName 2>/dev/null || uname -s)
HOST_VER=$(sw_vers -productVersion 2>/dev/null || uname -r)
HOST_ARCH=$(uname -m)
info "Host:  ${HOST_OS} ${HOST_VER}  (${HOST_ARCH})"
info "Shell: ${BASH_VERSION}"
info "Date:  $(date '+%Y-%m-%d %H:%M:%S %Z')"

step "Docker Engine"
if ! command -v docker &>/dev/null; then
    check_fail "Docker is not installed"
    echo ""
    err "Install Docker Desktop:  https://www.docker.com/products/docker-desktop"
    exit 1
fi

if ! docker info &>/dev/null 2>&1; then
    check_fail "Docker daemon is not running"
    err "Start Docker Desktop and try again."
    exit 1
fi

DOCKER_VER=$(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
DOCKER_CONTEXT=$(docker context show 2>/dev/null || echo "default")
check_ok "Docker Engine v${DOCKER_VER}  (context: ${DOCKER_CONTEXT})"

DOCKER_CPUS=$(docker info --format '{{.NCPU}}' 2>/dev/null || echo "?")
DOCKER_MEM_RAW=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo "0")
if [ "$DOCKER_MEM_RAW" != "0" ]; then
    DOCKER_MEM_GB=$(awk "BEGIN {printf \"%.1f\", ${DOCKER_MEM_RAW}/1073741824}")
    detail "${DOCKER_CPUS} CPUs, ${DOCKER_MEM_GB} GB RAM allocated to Docker"
fi

step "FUSE Device"
if [ ! -e /dev/fuse ]; then
    check_warn "/dev/fuse not found on host (expected on Apple Silicon — Linux VM provides it)"
    detail "FUSE will work inside the container via --privileged."
    [[ "$HOST_ARCH" == "arm64" ]] && detail "Apple Silicon: VM-based FUSE should work out of the box."
else
    check_ok "/dev/fuse available"
fi

step "Project Files"
REQUIRED_FILES=(Dockerfile Makefile run.sh src/myfs.c scripts/fusevault_ui.sh scripts/vault.sh)
MISSING_FILES=()
for f in "${REQUIRED_FILES[@]}"; do
    [ ! -f "${SCRIPT_DIR}/${f}" ] && MISSING_FILES+=("$f")
done

if [ ${#MISSING_FILES[@]} -gt 0 ]; then
    check_fail "Missing files: ${MISSING_FILES[*]}"
    exit 1
fi

SRC_LINES=$(wc -l < "${SCRIPT_DIR}/src/myfs.c" | tr -d ' ')
STORE_COUNT=$(find "${SCRIPT_DIR}/store" -name '*.enc' 2>/dev/null | wc -l | tr -d ' ')
check_ok "All required files present"
detail "src/myfs.c: ${SRC_LINES} lines   |   store: ${STORE_COUNT} encrypted files"

# Pre-flight summary
echo ""
echo -e "  ${DIM}${SILVER}Pre-flight:  ${LG}${CHECKS_PASS} passed${NC}${DIM}${SILVER}  ${ORANGE}${CHECKS_WARN} warnings${NC}${DIM}${SILVER}  ${R}${CHECKS_FAIL} failed${NC}"

if [ "$CHECKS_FAIL" -gt 0 ]; then
    echo ""
    err "Cannot continue — fix the issues above and retry."
    exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
#  PHASE 2 — DOCKER IMAGE
# ══════════════════════════════════════════════════════════════════════════════
phase 2 "📦" "$GOLD" "Docker Image  —  build or reuse the FuseVault container image"

# Detect if Dockerfile has changed since the image was last built
dockerfile_changed() {
    if ! docker image inspect "${IMAGE_NAME}" &>/dev/null; then return 0; fi
    local df_mtime img_mtime
    df_mtime=$(stat -f '%m' "${SCRIPT_DIR}/Dockerfile" 2>/dev/null || \
               stat -c '%Y' "${SCRIPT_DIR}/Dockerfile" 2>/dev/null || echo "0")
    img_mtime=$(docker image inspect "${IMAGE_NAME}" \
        --format '{{.Metadata.LastTagTime}}' 2>/dev/null | \
        # convert RFC3339 to epoch
        python3 -c "import sys,datetime; s=sys.stdin.read().strip()[:19]; \
            print(int(datetime.datetime.strptime(s,'%Y-%m-%dT%H:%M:%S').timestamp()))" \
        2>/dev/null || echo "0")
    [ "$df_mtime" -gt "$img_mtime" ]
}

build_image() {
    step "Building Docker image"
    info "Base: Ubuntu 22.04 LTS"
    info "Installs: gcc, libfuse-dev, openssl, argon2, gum, cppcheck, inotify-tools, xxd"
    info "This takes ~2 minutes on first build — subsequent launches reuse the cached image."
    echo ""
    docker build -t "${IMAGE_NAME}" "${SCRIPT_DIR}" > "$BUILD_LOG" 2>&1 &
    local build_pid=$!
    spinner $build_pid "Building image"
    wait $build_pid || {
        local rc=$?
        err "Image build FAILED (exit ${rc})  —  log: ${BUILD_LOG}"
        echo ""
        echo -e "  ${DIM}── Last 15 lines of build log ──${NC}"
        tail -15 "$BUILD_LOG" 2>/dev/null | while IFS= read -r line; do
            echo -e "  ${DIM}  ${line}${NC}"
        done
        exit 1
    }
    ok "Image built"
    local img_size_mb
    img_size_mb=$(docker image inspect "${IMAGE_NAME}" --format '{{.Size}}' 2>/dev/null | \
        awk '{printf "%.0f", $1/1048576}')
    detail "Image size: ${img_size_mb} MB"
}

step "Checking image '${IMAGE_NAME}'"

if $FLAG_CLEAN; then
    step "Cleaning (--clean)"
    docker ps -aq -f name="${CONTAINER_NAME}" | grep -q . && \
        docker rm -f "${CONTAINER_NAME}" > /dev/null 2>&1 && ok "Container removed" || true
    docker image inspect "${IMAGE_NAME}" &>/dev/null && \
        docker rmi -f "${IMAGE_NAME}" > /dev/null 2>&1 && ok "Image removed" || true
    FLAG_REBUILD=true
fi

if docker image inspect "${IMAGE_NAME}" &>/dev/null; then
    IMAGE_CREATED=$(docker image inspect "${IMAGE_NAME}" --format '{{.Created}}' | cut -c1-19 | tr 'T' ' ')
    IMAGE_SIZE_MB=$(docker image inspect "${IMAGE_NAME}" --format '{{.Size}}' 2>/dev/null | \
        awk '{printf "%.0f", $1/1048576}')
    IMAGE_ID=$(docker image inspect "${IMAGE_NAME}" --format '{{.Id}}' | cut -c8-19)
    ok "Image '${IMAGE_NAME}' found"
    detail "ID: ${IMAGE_ID}   Created: ${IMAGE_CREATED}   Size: ${IMAGE_SIZE_MB} MB"

    # Auto-detect Dockerfile changes
    if ! $FLAG_REBUILD && dockerfile_changed; then
        warn "Dockerfile has changed since the image was built — rebuild recommended"
        FLAG_REBUILD=true
    fi

    if $FLAG_REBUILD; then
        build_image
    else
        # Offer interactive prompt only when not in a clean rebuild
        echo ""
        echo -e "  ${DIM}${SILVER}Image is up to date. You can rebuild to pick up any Dockerfile changes.${NC}"
        echo -e "  ${DIM}${SILVER}If you haven't changed the Dockerfile, select N to use the existing image.${NC}"
        read -rp "  $(echo -e "${SKY}?${NC}")  Rebuild image? [y/N]: " _rebuild_ans
        if [[ "$(echo "${_rebuild_ans:-n}" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
            build_image
        else
            ok "Using existing image"
        fi
    fi
else
    info "No image found — building for the first time"
    build_image
fi

# ══════════════════════════════════════════════════════════════════════════════
#  PHASE 3 — CONTAINER LAUNCH
# ══════════════════════════════════════════════════════════════════════════════
phase 3 "🚀" "$LIME" "Container Launch  —  start the Docker container and open the TUI"

step "Preparing container '${CONTAINER_NAME}'"

CONTAINER_STATE=$(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null || echo "notfound")

launch_notice() {
    local action="$1"
    echo ""
    echo -e "  ${TEAL}────────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}${W}  Launching FuseVault TUI${NC}"
    echo -e "  ${DIM}${SILVER}  Action:    ${action}${NC}"
    echo -e "  ${DIM}${SILVER}  Container: ${CONTAINER_NAME}${NC}"
    echo -e "  ${DIM}${SILVER}  Workspace: /workspace  (mounted from host — your files persist here)${NC}"
    echo -e "  ${DIM}${SILVER}  Setup time: $(elapsed)${NC}"
    echo -e "  ${TEAL}────────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${DIM}${SILVER}  Tip: If this is your first time, choose 'Guided Demo' inside the TUI.${NC}"
    echo ""
}

case "$CONTAINER_STATE" in
    "true")
        ok "Container already running"
        STARTED_AT=$(docker inspect -f '{{.State.StartedAt}}' "${CONTAINER_NAME}" | cut -c1-19 | tr 'T' ' ')
        detail "Running since: ${STARTED_AT}"
        launch_notice "Attaching to running container"
        docker exec -it "${CONTAINER_NAME}" bash /workspace/scripts/fusevault_ui.sh
        ;;
    "false")
        ok "Found stopped container — restarting"
        docker start "${CONTAINER_NAME}" > /dev/null
        ok "Container restarted"
        launch_notice "Restarted existing container"
        docker exec -it "${CONTAINER_NAME}" bash /workspace/scripts/fusevault_ui.sh
        ;;
    *)
        ok "Creating new container"
        detail "Mode:   privileged  (required for FUSE)"
        detail "Caps:   SYS_ADMIN"
        detail "Mount:  ${SCRIPT_DIR} → /workspace"
        launch_notice "New container"
        docker run -it \
            --privileged \
            --cap-add SYS_ADMIN \
            --device /dev/fuse \
            --name "${CONTAINER_NAME}" \
            -v "${SCRIPT_DIR}:/workspace" \
            "${IMAGE_NAME}" \
            bash /workspace/scripts/fusevault_ui.sh
        ;;
esac

# ── Goodbye ───────────────────────────────────────────────────────────────────
echo ""
echo -e "  ${TEAL}────────────────────────────────────────────────────────────────────────────${NC}"
echo -e "  ${LG}✔${NC}  ${BOLD}${W}FuseVault session ended${NC}  ${DIM}${SILVER}(total: $(elapsed))${NC}"
echo -e ""
echo -e "  ${DIM}${SILVER}  Your encrypted files are safe in:  ${SCRIPT_DIR}/store/${NC}"
echo -e "  ${DIM}${SILVER}  The container '${CONTAINER_NAME}' is still available.${NC}"
echo -e ""
echo -e "  ${DIM}${SILVER}  To reconnect:        ./run.sh${NC}"
echo -e "  ${DIM}${SILVER}  To rebuild image:    ./run.sh --rebuild    (pick up Dockerfile changes)${NC}"
echo -e "  ${DIM}${SILVER}  To full reset:       ./run.sh --clean      (removes container + image)${NC}"
echo -e "  ${TEAL}────────────────────────────────────────────────────────────────────────────${NC}"
echo ""
