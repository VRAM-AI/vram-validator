#!/usr/bin/env bash
#
# VRAM Validator :: Nitro Enclave Setup
# ======================================
# One-shot script that installs nitro-cli, builds the slcl-nautilus EIF
# from the pre-built binary in the latest release, configures the Nitro
# memory allocator, and runs the enclave with a vsock-proxy bridge on
# localhost:3000.
#
# Run on AWS EC2 instances with Nitro Enclaves enabled (m5*, m6*, m7*, c5*, etc.)
# Ubuntu 22.04 / 24.04 x86_64.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/VRAM-AI/vram-validator/main/enclave-setup.sh | sudo bash
#
# Flags (via env vars):
#   ENCLAVE_MEMORY_MIB   default 4096
#   ENCLAVE_CPU_COUNT    default 2
#   ENCLAVE_CID          default 16
#   ENCLAVE_DEBUG        default false (set true for console output)
#   VRAM_REPO            default VRAM-AI/vram-validator
#

set -euo pipefail

# ─── Config ─────────────────────────────────────────────────────────────────
ENCLAVE_MEMORY_MIB="${ENCLAVE_MEMORY_MIB:-4096}"
ENCLAVE_CPU_COUNT="${ENCLAVE_CPU_COUNT:-2}"
ENCLAVE_CID="${ENCLAVE_CID:-16}"
ENCLAVE_DEBUG="${ENCLAVE_DEBUG:-false}"
VRAM_REPO="${VRAM_REPO:-VRAM-AI/vram-validator}"

INSTALL_DIR=/opt/vram
BUILD_DIR=/tmp/nautilus-build
RELEASE_URL="https://github.com/${VRAM_REPO}/releases/latest/download"

# ─── Pretty output ──────────────────────────────────────────────────────────
C_CYAN=$'\033[36m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'
C_BOLD=$'\033[1m'
C_RESET=$'\033[0m'

step()  { echo; echo "${C_CYAN}${C_BOLD}▸ $*${C_RESET}"; }
ok()    { echo "${C_GREEN}  ✓ $*${C_RESET}"; }
warn()  { echo "${C_YELLOW}  ⚠ $*${C_RESET}"; }
fatal() { echo "${C_RED}${C_BOLD}✗ $*${C_RESET}" >&2; exit 1; }

# ─── Root check ─────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    fatal "Must be run as root (try: curl ... | sudo bash)"
fi

# ─── Arch check ─────────────────────────────────────────────────────────────
if [[ "$(uname -m)" != "x86_64" ]]; then
    fatal "Only x86_64 is supported (got $(uname -m))"
fi

echo "${C_BOLD}"
echo "╔═══════════════════════════════════════════════════╗"
echo "║    VRAM Validator :: Nitro Enclave Setup         ║"
echo "╚═══════════════════════════════════════════════════╝"
echo "${C_RESET}"
echo "  Repo:       ${VRAM_REPO}"
echo "  Memory:     ${ENCLAVE_MEMORY_MIB} MiB"
echo "  CPUs:       ${ENCLAVE_CPU_COUNT}"
echo "  CID:        ${ENCLAVE_CID}"
echo "  Debug mode: ${ENCLAVE_DEBUG}"
echo

# ─── 1. Verify Nitro hardware ───────────────────────────────────────────────
step "Verifying Nitro Enclaves support"
if [[ ! -e /dev/nitro_enclaves ]]; then
    if ! [[ -r /sys/devices/virtual/dmi/id/sys_vendor ]] || \
       ! grep -qi amazon /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null; then
        fatal "Not an AWS EC2 instance, or not a Nitro-capable instance type"
    fi
    warn "/dev/nitro_enclaves not present yet (will be created when allocator starts)"
else
    ok "/dev/nitro_enclaves is present"
fi

# ─── 2. APT prerequisites ───────────────────────────────────────────────────
step "Installing apt prerequisites"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    curl \
    jq \
    docker.io \
    linux-modules-extra-aws 2>/dev/null || \
apt-get install -y -qq \
    curl \
    jq \
    docker.io
ok "Base packages installed"

systemctl enable --now docker >/dev/null 2>&1 || true
ok "Docker running"

# ─── 3. Install nitro-cli ───────────────────────────────────────────────────
step "Installing nitro-cli"
if command -v nitro-cli >/dev/null 2>&1; then
    ok "nitro-cli already installed: $(nitro-cli --version 2>&1 | head -1)"
else
    if apt-get install -y -qq aws-nitro-enclaves-cli aws-nitro-enclaves-cli-devel 2>/dev/null; then
        ok "Installed aws-nitro-enclaves-cli via apt"
    else
        warn "apt package unavailable, using release binary"
        curl -fsSL -o /usr/local/bin/nitro-cli \
            "${RELEASE_URL}/nitro-cli-linux-x86_64"
        chmod +x /usr/local/bin/nitro-cli
        ok "nitro-cli binary installed"
    fi
fi

modprobe nitro_enclaves 2>/dev/null || true
modprobe vhost_vsock 2>/dev/null || true

if getent group ne >/dev/null 2>&1; then
    for u in ubuntu ec2-user; do
        if id "$u" >/dev/null 2>&1; then
            usermod -aG ne "$u" || true
            usermod -aG docker "$u" || true
        fi
    done
fi

# ─── 4. Configure memory allocator ──────────────────────────────────────────
step "Configuring Nitro allocator (${ENCLAVE_MEMORY_MIB} MiB, ${ENCLAVE_CPU_COUNT} CPUs)"
mkdir -p /etc/nitro_enclaves
cat > /etc/nitro_enclaves/allocator.yaml <<YAML
---
memory_mib: ${ENCLAVE_MEMORY_MIB}
cpu_count: ${ENCLAVE_CPU_COUNT}
YAML

if systemctl list-unit-files nitro-enclaves-allocator.service >/dev/null 2>&1; then
    systemctl enable --now nitro-enclaves-allocator.service
    systemctl restart nitro-enclaves-allocator.service
    sleep 2
    ok "Allocator service running"
else
    warn "nitro-enclaves-allocator.service not found; memory must be reserved on each boot"
fi

# ─── 5. Download pre-built nautilus binary ──────────────────────────────────
step "Downloading pre-built slcl-nautilus binary"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

curl -fsSL --retry 3 -o "$BUILD_DIR/slcl-nautilus" \
    "${RELEASE_URL}/slcl-nautilus-linux-x86_64"
chmod +x "$BUILD_DIR/slcl-nautilus"
SIZE=$(stat -c%s "$BUILD_DIR/slcl-nautilus")
ok "Downloaded slcl-nautilus ($(numfmt --to=iec-i --suffix=B "$SIZE"))"

# ─── 6. Build Docker image for EIF ──────────────────────────────────────────
step "Building Docker image for EIF"
cat > "$BUILD_DIR/Dockerfile" <<'EOF'
FROM scratch
COPY slcl-nautilus /app/slcl-nautilus
ENV PORT=3000
ENTRYPOINT ["/app/slcl-nautilus"]
EOF

docker build -t slcl-nautilus:latest "$BUILD_DIR/" >/dev/null
ok "Built slcl-nautilus:latest"

# ─── 6b. Ensure nitro-cli blobs are present ─────────────────────────────────
step "Checking nitro-cli blobs"
BLOBS_DIR=/usr/share/nitro_enclaves/blobs

# Verify blobs are real binary files (not empty or HTML 404 pages)
blobs_ok() {
    [[ -f "$BLOBS_DIR/cmdline" ]] && \
    [[ -f "$BLOBS_DIR/linuxkit" ]] && \
    [[ $(stat -c%s "$BLOBS_DIR/cmdline") -gt 10 ]] && \
    [[ $(stat -c%s "$BLOBS_DIR/linuxkit") -gt 10000 ]]
}

if blobs_ok; then
    ok "Blobs present at $BLOBS_DIR"
else
    warn "Blobs missing or invalid — cloning AWS repo to get them"
    mkdir -p "$BLOBS_DIR"
    rm -rf /tmp/nitro-cli-src
    git clone --depth 1 \
        https://github.com/aws/aws-nitro-enclaves-cli.git \
        /tmp/nitro-cli-src
    cp /tmp/nitro-cli-src/blobs/x86_64/* "$BLOBS_DIR/"
    chmod +x "$BLOBS_DIR/linuxkit" "$BLOBS_DIR/init" 2>/dev/null || true
    rm -rf /tmp/nitro-cli-src
    if blobs_ok; then
        ok "Blobs installed to $BLOBS_DIR"
    else
        fatal "Could not install nitro-cli blobs — check the repo structure"
    fi
fi

# Write the nitro_enclaves.conf so nitro-cli knows where the blobs are
mkdir -p /etc/nitro_enclaves
if [[ ! -f /etc/nitro_enclaves/nitro_enclaves.conf ]]; then
    cat > /etc/nitro_enclaves/nitro_enclaves.conf <<CONF
# Nitro Enclaves configuration
blobs_path=${BLOBS_DIR}
CONF
    ok "Wrote /etc/nitro_enclaves/nitro_enclaves.conf"
fi

# Show where nitro-cli binary is and what blob path it has embedded
NITRO_BIN=$(command -v nitro-cli)
ok "nitro-cli binary: $NITRO_BIN"
EMBEDDED_PATH=$(strings "$NITRO_BIN" 2>/dev/null | grep -i "nitro_enclaves/blobs" | head -1 || echo "(none found)")
ok "Embedded blob path hint: $EMBEDDED_PATH"
ok "Blobs directory contents: $(ls $BLOBS_DIR | tr '\n' ' ')"

# ─── 7. Build EIF ───────────────────────────────────────────────────────────
step "Building Enclave Image File (EIF)"
mkdir -p "$INSTALL_DIR"
mkdir -p /var/log/nitro_enclaves
EIF_PATH="$INSTALL_DIR/slcl-nautilus.eif"
BUILD_OUT="$INSTALL_DIR/build-output.json"

if ! nitro-cli build-enclave \
    --docker-uri slcl-nautilus:latest \
    --output-file "$EIF_PATH" \
    > "$BUILD_OUT" 2>&1; then
    echo
    warn "nitro-cli build-enclave failed. Error log:"
    ERRLOG=$(ls -t /var/log/nitro_enclaves/err*.log 2>/dev/null | head -1)
    [[ -n "$ERRLOG" ]] && cat "$ERRLOG" || echo "(no error log found)"
    fatal "EIF build failed — see above"
fi

# nitro-cli outputs "Start building..." before the JSON — extract just the JSON block
JSON_BLOCK=$(python3 -c "
import sys, re
data = open('$BUILD_OUT').read()
m = re.search(r'(\{.*\})', data, re.DOTALL)
print(m.group(1) if m else '{}')
")
PCR0=$(echo "$JSON_BLOCK" | jq -r '.Measurements.PCR0 // empty')
PCR1=$(echo "$JSON_BLOCK" | jq -r '.Measurements.PCR1 // empty')
PCR2=$(echo "$JSON_BLOCK" | jq -r '.Measurements.PCR2 // empty')
# Rewrite build-output.json with clean JSON only
echo "$JSON_BLOCK" > "$BUILD_OUT"

ok "EIF built: $EIF_PATH"
echo "    PCR0: ${PCR0:0:32}..."
echo "    PCR1: ${PCR1:0:32}..."
echo "    PCR2: ${PCR2:0:32}..."

# ─── 8. Terminate any previously running enclave ────────────────────────────
step "Stopping any existing enclaves"
RUNNING=$(nitro-cli describe-enclaves | jq -r '.[].EnclaveID' 2>/dev/null || echo "")
if [[ -n "$RUNNING" ]]; then
    for eid in $RUNNING; do
        nitro-cli terminate-enclave --enclave-id "$eid" >/dev/null
        ok "Terminated $eid"
    done
else
    ok "No existing enclaves"
fi

# ─── 9. Run the enclave ─────────────────────────────────────────────────────
step "Starting enclave (CID=${ENCLAVE_CID})"
DEBUG_FLAG=""
if [[ "$ENCLAVE_DEBUG" == "true" ]]; then
    DEBUG_FLAG="--debug-mode"
fi

nitro-cli run-enclave \
    --eif-path "$EIF_PATH" \
    --memory "$ENCLAVE_MEMORY_MIB" \
    --cpu-count "$ENCLAVE_CPU_COUNT" \
    --enclave-cid "$ENCLAVE_CID" \
    $DEBUG_FLAG > /tmp/run-enclave.json

ENCLAVE_ID=$(jq -r '.EnclaveID' /tmp/run-enclave.json)
ok "Enclave started: $ENCLAVE_ID"

# ─── 10. vsock-proxy: localhost:3000 → enclave:3000 ─────────────────────────
step "Setting up vsock-proxy bridge (localhost:3000 → CID ${ENCLAVE_CID}:3000)"
apt-get install -y -qq socat

cat > /etc/systemd/system/vram-vsock-bridge.service <<SERVICE
[Unit]
Description=VRAM vsock bridge (TCP 3000 -> enclave vsock:${ENCLAVE_CID}:3000)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:3000,reuseaddr,fork VSOCK-CONNECT:${ENCLAVE_CID}:3000
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now vram-vsock-bridge.service
sleep 2
ok "vsock bridge running on 127.0.0.1:3000"

# ─── 11. Health check ───────────────────────────────────────────────────────
step "Health check (waiting up to 30s for enclave to serve /health)"
HEALTH_OK=false
for i in $(seq 1 30); do
    if curl -fsS --max-time 2 http://localhost:3000/health >/dev/null 2>&1; then
        HEALTH_OK=true
        break
    fi
    sleep 1
done

if [[ "$HEALTH_OK" == "true" ]]; then
    ok "Enclave is healthy"
else
    warn "Enclave did not respond to /health in 30s"
    warn "Check: nitro-cli describe-enclaves"
    warn "Logs:  nitro-cli console --enclave-id $ENCLAVE_ID   (debug builds only)"
fi

# ─── 12. Summary + next steps ───────────────────────────────────────────────
echo
echo "${C_GREEN}${C_BOLD}╔═══════════════════════════════════════════════════╗"
echo "║                Setup complete                     ║"
echo "╚═══════════════════════════════════════════════════╝${C_RESET}"
echo
echo "  ${C_BOLD}Enclave ID:${C_RESET}     $ENCLAVE_ID"
echo "  ${C_BOLD}EIF path:${C_RESET}       $EIF_PATH"
echo "  ${C_BOLD}Build output:${C_RESET}   $BUILD_OUT"
echo "  ${C_BOLD}PCR0:${C_RESET}           $PCR0"
echo "  ${C_BOLD}Endpoint:${C_RESET}       http://localhost:3000"
echo
echo "  ${C_BOLD}Next steps:${C_RESET}"
echo
echo "  1. Register the enclave on-chain:"
echo "     ${C_CYAN}source ~/.env${C_RESET}"
echo "     ${C_CYAN}vram-cli register-enclave --enclave-url http://localhost:3000${C_RESET}"
echo "     Save the printed VRAMHUB_ENCLAVE_OBJECT_ID into ~/.env"
echo
echo "  2. Register as a validator:"
echo "     ${C_CYAN}vram-cli register-validator${C_RESET}"
echo "     Save the printed VRAMHUB_VALIDATOR_UID into ~/.env"
echo
echo "  3. Also set in ~/.env:"
echo "     ${C_CYAN}VRAMHUB_ENCLAVE_PUBKEY=<from register-enclave output>${C_RESET}"
echo "     ${C_CYAN}VRAMHUB_NITRO_ENCLAVE=true${C_RESET}"
echo "     ${C_CYAN}VRAMHUB_TEST_MODE=false${C_RESET}"
echo
echo "  4. Run the validator:"
echo "     ${C_CYAN}source ~/.env && vram-validator${C_RESET}"
echo
echo "  ${C_BOLD}Useful commands:${C_RESET}"
echo "     nitro-cli describe-enclaves"
echo "     systemctl status vram-vsock-bridge"
echo "     journalctl -u vram-vsock-bridge -f"
echo
