#!/usr/bin/env bash
# VRAM Validator — Full One-Click Setup
# =======================================
# Installs and configures everything needed to run a VRAM validator:
#   • Nitro Enclaves kernel module + nitro-cli
#   • AL2023 / Ubuntu CPU pool + vsock fixes
#   • slcl-nautilus enclave (production mode, no --debug-console)
#   • socat vsock bridge (TCP 3000 → enclave CID:3000)
#   • vram-validator + vram-cli binaries
#   • ~/.env from template (prompts for wallet mnemonic if missing)
#   • On-chain registration (register-validator + register-enclave)
#   • vram-validator.service systemd unit
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/VRAM-AI/vram-validator/main/setup.sh | sudo bash
#
# Optional env vars (set before piping):
#   ENCLAVE_MEMORY_MIB   MiB reserved for enclave  (default: 4096)
#   ENCLAVE_CPU_COUNT    CPUs reserved for enclave  (default: 2)
#   ENCLAVE_CID          vsock CID for enclave      (default: 16)
#   ENCLAVE_DEBUG        set "true" for debug mode  (default: false)
#   SKIP_REGISTER        set "true" to skip on-chain registration
#   VRAM_REPO            GitHub repo                (default: VRAM-AI/vram-validator)
#
# Supported:
#   Amazon Linux 2023  (dnf)
#   Ubuntu 22.04 / 24.04  (apt)
#   Any x86_64 EC2 instance with Nitro Enclaves enabled

set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────
ENCLAVE_MEMORY_MIB="${ENCLAVE_MEMORY_MIB:-1024}"
ENCLAVE_CPU_COUNT="${ENCLAVE_CPU_COUNT:-2}"
ENCLAVE_CID="${ENCLAVE_CID:-16}"
ENCLAVE_DEBUG="${ENCLAVE_DEBUG:-false}"
SKIP_REGISTER="${SKIP_REGISTER:-false}"
VRAM_REPO="${VRAM_REPO:-VRAM-AI/vram-validator}"
VRAMHUB_REPO="VRAM-AI/VRAM-HUB"
INSTALL_DIR=/opt/vram
BUILD_DIR=/tmp/vram-setup
RELEASE_URL="https://github.com/${VRAM_REPO}/releases/latest/download"
VRAMHUB_RELEASE_URL="https://github.com/${VRAMHUB_REPO}/releases/latest/download"
RAW_URL="https://raw.githubusercontent.com/${VRAM_REPO}/main"

# ─── Output helpers ──────────────────────────────────────────────────────────
C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
C_RED=$'\033[31m';  C_BOLD=$'\033[1m';   C_RESET=$'\033[0m'
step()  { echo; echo "${C_CYAN}${C_BOLD}▸ $*${C_RESET}"; }
ok()    { echo "${C_GREEN}  ✓ $*${C_RESET}"; }
warn()  { echo "${C_YELLOW}  ⚠ $*${C_RESET}"; }
fatal() { echo "${C_RED}${C_BOLD}✗ $*${C_RESET}" >&2; exit 1; }
info()  { echo "    $*"; }

# ─── Must run as root ─────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || fatal "Run with sudo:  curl -fsSL ${RAW_URL}/setup.sh | sudo bash"

# Identify the actual non-root user who ran sudo (for ~/.env and registration)
ACTUAL_USER="${SUDO_USER:-}"
[[ -z "$ACTUAL_USER" || "$ACTUAL_USER" == "root" ]] && \
    ACTUAL_USER=$(logname 2>/dev/null || getent passwd 1000 | cut -d: -f1 || echo "ec2-user")
USER_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6 2>/dev/null || echo "/home/$ACTUAL_USER")
ENV_FILE="$USER_HOME/.env"

echo "${C_BOLD}"
echo "╔════════════════════════════════════════════════════╗"
echo "║        VRAM Validator — Full Setup                 ║"
echo "╚════════════════════════════════════════════════════╝"
echo "${C_RESET}"
info "Repo:    ${VRAM_REPO}"
info "User:    ${ACTUAL_USER}  (home: ${USER_HOME})"
info "Memory:  ${ENCLAVE_MEMORY_MIB} MiB   CPUs: ${ENCLAVE_CPU_COUNT}   CID: ${ENCLAVE_CID}"
info "Debug:   ${ENCLAVE_DEBUG}    Skip-register: ${SKIP_REGISTER}"
echo

# ─── 1. Pre-checks ───────────────────────────────────────────────────────────
step "Pre-flight checks"

[[ "$(uname -m)" == "x86_64" ]] || fatal "Only x86_64 supported (got $(uname -m)). ARM/Graviton instances do not support Nitro Enclaves."

# Verify Nitro hardware is present
if [[ ! -e /dev/nitro_enclaves ]]; then
    # Check we're at least on AWS
    if ! grep -qi amazon /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null && \
       ! grep -qi amazon /sys/devices/virtual/dmi/id/bios_vendor 2>/dev/null; then
        fatal "Not an AWS instance. Nitro Enclaves require AWS EC2."
    fi
    warn "/dev/nitro_enclaves not present yet — will be created once the module loads"
else
    ok "/dev/nitro_enclaves present"
fi
ok "Architecture: x86_64"

# ─── 2. OS detection ─────────────────────────────────────────────────────────
step "Detecting OS"
if command -v dnf >/dev/null 2>&1; then
    _PKG="dnf"
elif command -v apt-get >/dev/null 2>&1; then
    _PKG="apt"
else
    fatal "Unsupported OS: neither dnf nor apt-get found"
fi
ok "Package manager: ${_PKG}"

# ─── 3. System packages ──────────────────────────────────────────────────────
step "Installing system packages"
if [[ "$_PKG" == "dnf" ]]; then
    # AL2023: curl-minimal conflicts with full curl — skip; binary is already present
    dnf install -y jq socat git python3 2>/dev/null || \
        dnf install -y jq socat python3 || fatal "dnf install failed"

    # Docker on AL2023
    if ! command -v docker >/dev/null 2>&1; then
        dnf install -y docker 2>/dev/null || {
            dnf install -y dnf-plugins-core 2>/dev/null || true
            dnf config-manager --add-repo \
                https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null || true
            dnf install -y docker-ce docker-ce-cli containerd.io || \
                fatal "Docker install failed — install manually and re-run"
        }
    fi
else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl jq socat git python3 docker.io \
        linux-modules-extra-aws 2>/dev/null || \
    apt-get install -y -qq curl jq socat git python3 docker.io
fi
systemctl enable --now docker 2>/dev/null || true
ok "Packages ready"

# ─── 4. nitro-cli ────────────────────────────────────────────────────────────
step "Installing nitro-cli"
_NITRO_FROM_PKG=false
if [[ "$_PKG" == "dnf" ]]; then
    if dnf install -y aws-nitro-enclaves-cli aws-nitro-enclaves-cli-devel \
            >/dev/null 2>&1; then
        rm -f /usr/local/bin/nitro-cli 2>/dev/null || true
        _NITRO_FROM_PKG=true
    fi
else
    if apt-get install -y -qq aws-nitro-enclaves-cli 2>/dev/null; then
        apt-get install -y -qq aws-nitro-enclaves-cli-devel 2>/dev/null || true
        rm -f /usr/local/bin/nitro-cli 2>/dev/null || true
        _NITRO_FROM_PKG=true
    fi
fi
if [[ "$_NITRO_FROM_PKG" == "false" ]]; then
    if ! command -v nitro-cli >/dev/null 2>&1; then
        warn "aws-nitro-enclaves-cli not in package repos — using release binary"
        curl -fsSL --retry 3 -o /usr/local/bin/nitro-cli \
            "${RELEASE_URL}/nitro-cli-linux-x86_64"
        chmod +x /usr/local/bin/nitro-cli
    fi
fi
ok "nitro-cli: $(nitro-cli --version 2>&1 | head -1)"

# ─── 5. vsock transport ──────────────────────────────────────────────────────
step "Configuring vsock transport"
# vhost_vsock is the H2G (host→enclave) transport. vmw_vsock_virtio_transport
# is G2H only and intercepts AF_VSOCK connects before they reach vhost_vsock,
# causing ENODEV on enclave CIDs. Unload it first.
modprobe vsock 2>/dev/null || true
modprobe vhost 2>/dev/null || true
modprobe vhost_vsock 2>/dev/null || true

if lsmod | grep -q vmw_vsock_virtio_transport; then
    for _vd in /sys/bus/virtio/drivers/vmw_vsock_virtio_transport/virtio*/; do
        [[ -e "$_vd" ]] && echo "$(basename "$_vd")" \
            > /sys/bus/virtio/drivers/vmw_vsock_virtio_transport/unbind 2>/dev/null || true
    done
    modprobe -r vmw_vsock_virtio_transport 2>/dev/null || true
fi

[[ -e /dev/vhost-vsock ]] && ok "vhost_vsock loaded (/dev/vhost-vsock present)" || \
    warn "vhost_vsock not loaded — vsock to enclave CIDs may fail"

# ─── 6. nitro_enclaves module + /run/nitro_enclaves permissions ──────────────
step "Loading nitro_enclaves kernel module"
rm -f /etc/modprobe.d/nitro_enclaves.conf 2>/dev/null || true
modprobe nitro_enclaves 2>/dev/null || true

# /run/nitro_enclaves must be 775 root:ne so non-root nitro-cli can bind its
# management socket. AL2023 creates it as 755 root:root by default.
mkdir -p /run/nitro_enclaves
chown root:ne /run/nitro_enclaves 2>/dev/null || true
chmod 775 /run/nitro_enclaves
echo 'd /run/nitro_enclaves 0775 root ne -' > /usr/lib/tmpfiles.d/nitro_enclaves.conf
ok "/run/nitro_enclaves: 775 root:ne"

# Add the calling user to ne and docker groups
for _u in "$ACTUAL_USER" ubuntu ec2-user; do
    if id "$_u" >/dev/null 2>&1; then
        usermod -aG ne "$_u" 2>/dev/null || true
        usermod -aG docker "$_u" 2>/dev/null || true
    fi
done

# ─── 7. CPU pool (allocator or direct kernel parameter) ──────────────────────
step "Configuring enclave CPU pool (${ENCLAVE_CPU_COUNT} CPUs, ${ENCLAVE_MEMORY_MIB} MiB)"
mkdir -p /etc/nitro_enclaves
cat > /etc/nitro_enclaves/allocator.yaml <<YAML
---
memory_mib: ${ENCLAVE_MEMORY_MIB}
cpu_count: ${ENCLAVE_CPU_COUNT}
YAML

ALLOC_SVC=$(systemctl list-unit-files 2>/dev/null | \
    awk '/nitro-enclaves-allocator/{print $1}' | head -1 || true)

if [[ -n "$ALLOC_SVC" ]]; then
    # AL2023 kernel 6.x: secondary CPUs boot offline. The nitro_enclaves driver
    # calls cpu_down() to pool CPUs, but cpu_down() fails if the CPU is already
    # offline (rc=-22 / EINVAL). Clearing ne_cpus on an already-loaded module is
    # a no-op — the driver only reacts to changes. The only reliable fix is:
    #   1. Unload the module entirely (clears all driver state)
    #   2. Online all secondary CPUs while the module is absent
    #   3. Reload the module fresh — driver starts with zero state, CPUs online
    #   4. Start allocator — cpu_down() now succeeds on every CPU

    systemctl stop "$ALLOC_SVC" 2>/dev/null || true
    rmmod nitro_enclaves 2>/dev/null && sleep 1 || true

    for _f in /sys/devices/system/cpu/cpu[1-9]*/online; do
        [[ -f "$_f" ]] && echo 1 > "$_f" 2>/dev/null || true
    done
    ok "CPUs online: $(cat /sys/devices/system/cpu/online)"

    modprobe nitro_enclaves && sleep 1

    systemctl enable "$ALLOC_SVC"
    systemctl start "$ALLOC_SVC" || true
    sleep 3
    ok "Allocator service: $ALLOC_SVC"
    ok "CPU pool applied: $(cat /sys/module/nitro_enclaves/parameters/ne_cpus 2>/dev/null)"

    # Verify no rc=-22 errors
    if dmesg | tail -20 | grep -q 'not onlined'; then
        warn "CPU pool setup may have failed — check: dmesg | grep nitro_enclaves"
    fi

    # Persist across reboots: nitro-cpu-fix service runs BEFORE the allocator.
    # It unloads the module, onlines CPUs, then reloads — same sequence as above.
    cat > /usr/local/sbin/nitro-cpu-fix.sh <<'CPUFIX'
#!/bin/bash
# AL2023: rmmod + online CPUs + modprobe before allocator sets ne_cpus
systemctl stop nitro-enclaves-allocator.service 2>/dev/null || true
rmmod nitro_enclaves 2>/dev/null || true
sleep 1
for f in /sys/devices/system/cpu/cpu[1-9]*/online; do
    [[ -f "$f" ]] && echo 1 > "$f" 2>/dev/null || true
done
modprobe nitro_enclaves
sleep 1
CPUFIX
    chmod +x /usr/local/sbin/nitro-cpu-fix.sh
    cat > /etc/systemd/system/nitro-cpu-fix.service <<UNIT
[Unit]
Description=Reload nitro_enclaves with secondary CPUs online (AL2023 E36 fix)
Before=${ALLOC_SVC}
After=modules-load.target local-fs.target
DefaultDependencies=no
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nitro-cpu-fix.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable nitro-cpu-fix.service 2>/dev/null || true

else
    # No allocator service — configure pool directly via kernel module
    warn "nitro-enclaves-allocator not found — configuring pool via kernel module"
    HUGE_PAGES=$(( ENCLAVE_MEMORY_MIB / 2 ))
    echo "$HUGE_PAGES" > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages 2>/dev/null || true

    TOTAL_CPUS=$(nproc --all)
    [[ $ENCLAVE_CPU_COUNT -ge $TOTAL_CPUS ]] && \
        fatal "Cannot reserve ${ENCLAVE_CPU_COUNT} CPUs — host only has ${TOTAL_CPUS}"

    # Re-online all CPUs so topology files are visible for the selection scan
    for _f in /sys/devices/system/cpu/cpu[0-9]*/online; do
        [[ -f "$_f" ]] && echo 1 > "$_f" 2>/dev/null || true
    done
    sleep 0.3

    CPU_LIST=$(python3 - "${ENCLAVE_CPU_COUNT}" <<'PYEOF'
import os, sys, collections
n = int(sys.argv[1])
cpudir = '/sys/devices/system/cpu'
cores = collections.defaultdict(list)
for e in sorted(os.listdir(cpudir)):
    if not e.startswith('cpu') or not e[3:].isdigit(): continue
    cid = int(e[3:])
    p = os.path.join(cpudir, e, 'topology', 'core_id')
    if os.path.exists(p): cores[int(open(p).read().strip())].append(cid)
pool = []
for core in sorted(cores.keys(), reverse=True):
    if len(pool) >= n: break
    cpus = cores[core]
    if 0 in cpus: continue
    pool.extend(cpus)
print(','.join(str(c) for c in sorted(pool)))
PYEOF
    )
    [[ -z "$CPU_LIST" ]] && fatal "No eligible CPUs for enclave pool (need ${ENCLAVE_CPU_COUNT})"

    for _c in $(echo "$CPU_LIST" | tr ',' ' '); do
        echo 1 > /sys/devices/system/cpu/cpu${_c}/online 2>/dev/null || true
    done

    if lsmod | grep -q "^nitro_enclaves"; then
        rmmod nitro_enclaves 2>/dev/null || \
            fatal "nitro_enclaves in use — terminate enclaves first: sudo nitro-cli terminate-enclave --all"
        sleep 1
    fi
    modprobe nitro_enclaves ne_cpus="${CPU_LIST}" || fatal "modprobe nitro_enclaves failed"
    echo "options nitro_enclaves ne_cpus=${CPU_LIST}" > /etc/modprobe.d/nitro_enclaves.conf
    echo "vm.nr_hugepages=${HUGE_PAGES}" > /etc/sysctl.d/20-nitro-enclaves.conf
    ok "CPU pool: ${CPU_LIST} (of ${TOTAL_CPUS} total)"
fi

# ─── 8. Download EIF or build from binary ────────────────────────────────────
step "Preparing slcl-nautilus enclave image"
mkdir -p "$INSTALL_DIR" "$BUILD_DIR" /var/log/nitro_enclaves
EIF_PATH="$INSTALL_DIR/slcl-nautilus.eif"
BUILD_OUT="$INSTALL_DIR/build-output.json"

# Try pre-built EIF from release first (faster, stable PCRs)
EIF_DOWNLOADED=false
if curl -fsSL --retry 3 -o "$EIF_PATH" "${RELEASE_URL}/slcl-nautilus.eif" 2>/dev/null && \
   [[ $(stat -c%s "$EIF_PATH" 2>/dev/null || echo 0) -gt 100000 ]]; then
    ok "Downloaded pre-built EIF ($(numfmt --to=iec-i --suffix=B "$(stat -c%s "$EIF_PATH")"))"
    # Download the accompanying PCR manifest if available
    curl -fsSL --retry 3 -o "$BUILD_OUT" \
        "${RELEASE_URL}/build-output.json" 2>/dev/null || \
        echo '{}' > "$BUILD_OUT"
    EIF_DOWNLOADED=true
else
    warn "Pre-built EIF not available in release — building from binary"
    rm -f "$EIF_PATH" 2>/dev/null || true

    # Download the nautilus binary (static musl — from VRAM-HUB releases)
    curl -fsSL --retry 3 -o "$BUILD_DIR/vramhub-nautilus" \
        "${VRAMHUB_RELEASE_URL}/vramhub-nautilus-linux-x86_64" || \
        fatal "Could not download vramhub-nautilus binary from ${VRAMHUB_RELEASE_URL}"
    chmod +x "$BUILD_DIR/vramhub-nautilus"
    ok "Downloaded vramhub-nautilus binary"

    # Dockerfile: FROM scratch — binary is static musl, no libc needed
    cat > "$BUILD_DIR/Dockerfile" <<'DEOF'
FROM scratch
COPY vramhub-nautilus /vramhub-nautilus
CMD ["/vramhub-nautilus"]
DEOF

    # Check nitro-cli blobs
    BLOBS_DIR=/usr/share/nitro_enclaves/blobs
    if ! { [[ -f "$BLOBS_DIR/linuxkit" ]] && \
           [[ $(stat -c%s "$BLOBS_DIR/linuxkit" 2>/dev/null) -gt 10000 ]]; }; then
        warn "nitro-cli blobs missing — cloning aws-nitro-enclaves-cli"
        mkdir -p "$BLOBS_DIR"
        rm -rf /tmp/ne-blobs
        git clone --depth 1 \
            https://github.com/aws/aws-nitro-enclaves-cli.git /tmp/ne-blobs
        cp /tmp/ne-blobs/blobs/x86_64/* "$BLOBS_DIR/"
        chmod +x "$BLOBS_DIR/linuxkit" "$BLOBS_DIR/init" 2>/dev/null || true
        rm -rf /tmp/ne-blobs
        ok "Blobs installed"
    fi

    mkdir -p /etc/nitro_enclaves
    [[ -f /etc/nitro_enclaves/nitro_enclaves.conf ]] || \
        echo "blobs_path=${BLOBS_DIR}" > /etc/nitro_enclaves/nitro_enclaves.conf

    docker build -t vramhub-nautilus:latest "$BUILD_DIR/" 2>&1 | grep -v '^#' | tail -5
    ok "Docker image built"

    nitro-cli build-enclave \
        --docker-uri vramhub-nautilus:latest \
        --output-file "$EIF_PATH" > "$BUILD_OUT" 2>&1 || {
        cat "$BUILD_OUT" >&2
        fatal "EIF build failed — see above"
    }
    ok "EIF built from binary"
fi

# Parse PCR values from build output
JSON_BLOCK=$(python3 -c "
import sys, re, json
data = open('$BUILD_OUT').read()
m = re.search(r'(\{.*\})', data, re.DOTALL)
print(m.group(1) if m else '{}')
" 2>/dev/null || echo '{}')
PCR0=$(echo "$JSON_BLOCK" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Measurements',{}).get('PCR0',''))" 2>/dev/null || echo "")
PCR1=$(echo "$JSON_BLOCK" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Measurements',{}).get('PCR1',''))" 2>/dev/null || echo "")
PCR2=$(echo "$JSON_BLOCK" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Measurements',{}).get('PCR2',''))" 2>/dev/null || echo "")
[[ -n "$PCR0" ]] && echo "    PCR0: ${PCR0:0:48}..."
[[ -n "$PCR1" ]] && echo "    PCR1: ${PCR1:0:48}..."
[[ -n "$PCR2" ]] && echo "    PCR2: ${PCR2:0:48}..."

# ─── 9. Terminate stale enclaves ─────────────────────────────────────────────
step "Stopping any existing enclaves"
_RUNNING=$(nitro-cli describe-enclaves 2>/dev/null | \
    python3 -c "import sys,json; [print(e['EnclaveID']) for e in json.load(sys.stdin)]" \
    2>/dev/null || echo "")
if [[ -n "$_RUNNING" ]]; then
    for _eid in $_RUNNING; do
        nitro-cli terminate-enclave --enclave-id "$_eid" >/dev/null 2>&1 || true
        ok "Terminated $_eid"
    done
    # Reload vhost_vsock after terminate so CID assignment is clean
    rmmod vhost_vsock 2>/dev/null || true; sleep 0.3
    modprobe vhost_vsock 2>/dev/null || true; sleep 0.5
else
    ok "No existing enclaves"
fi

# ─── 10. vsock bind pre-flight ───────────────────────────────────────────────
python3 - <<'PYEOF' 2>/dev/null && true
import socket, sys
AF_VSOCK = getattr(socket, 'AF_VSOCK', 40)
CID_ANY  = getattr(socket, 'VMADDR_CID_ANY', 0xFFFFFFFF)
for port in [9000, 9001, 65432]:
    s = socket.socket(AF_VSOCK, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((CID_ANY, port)); s.close()
PYEOF
_vsock_ok=$?
if [[ $_vsock_ok -ne 0 ]]; then
    warn "AF_VSOCK bind failed on heartbeat ports — reloading vhost_vsock"
    rmmod vhost_vsock 2>/dev/null || true; sleep 0.3
    modprobe vhost 2>/dev/null || true
    modprobe vhost_vsock 2>/dev/null || true; sleep 0.5
fi

# ─── 11. Run the enclave ─────────────────────────────────────────────────────
step "Starting enclave (CID=${ENCLAVE_CID}, ${ENCLAVE_MEMORY_MIB} MiB, ${ENCLAVE_CPU_COUNT} CPUs)"
DEBUG_FLAG=""
[[ "$ENCLAVE_DEBUG" == "true" ]] && DEBUG_FLAG="--debug-mode"

nitro-cli run-enclave \
    --eif-path "$EIF_PATH" \
    --memory "$ENCLAVE_MEMORY_MIB" \
    --cpu-count "$ENCLAVE_CPU_COUNT" \
    --enclave-cid "$ENCLAVE_CID" \
    $DEBUG_FLAG > /tmp/vram-run-enclave.json 2>&1 || true

ENCLAVE_ID=$(python3 -c "
import sys, re
data = open('/tmp/vram-run-enclave.json').read()
m = re.search(r'\"EnclaveID\"\s*:\s*\"([^\"]+)\"', data)
print(m.group(1) if m else '')
" 2>/dev/null || echo "")

if [[ -z "$ENCLAVE_ID" ]]; then
    ENCLAVE_ID=$(nitro-cli describe-enclaves 2>/dev/null | \
        python3 -c "
import sys,json
enclaves = json.load(sys.stdin)
for e in enclaves:
    if e.get('EnclaveCID') == ${ENCLAVE_CID}: print(e['EnclaveID']); break
" 2>/dev/null || echo "")
fi

if [[ -z "$ENCLAVE_ID" ]]; then
    warn "Enclave failed to start. Diagnostics:"
    cat /tmp/vram-run-enclave.json >&2 || true
    dmesg | grep -iE "nitro|enclave|E36|ne_cpus" | tail -20 >&2 || true
    fatal "Enclave did not start. Re-run with ENCLAVE_DEBUG=true for console output."
fi
ok "Enclave started: $ENCLAVE_ID"

# Verify production mode (Flags: NONE, not DEBUG_MODE)
_FLAGS=$(nitro-cli describe-enclaves 2>/dev/null | \
    python3 -c "
import sys,json
for e in json.load(sys.stdin):
    if e.get('EnclaveID') == '${ENCLAVE_ID}': print(e.get('Flags','?')); break
" 2>/dev/null || echo "?")
if [[ "$_FLAGS" == "NONE" ]]; then
    ok "Mode: production (Flags: NONE) — real attestation, real PCRs"
elif [[ "$_FLAGS" == "DEBUG_MODE" ]]; then
    warn "Mode: DEBUG_MODE — PCRs will be zeroed. On-chain registration will fail."
    warn "To run in production mode, re-run without ENCLAVE_DEBUG=true"
else
    ok "Flags: ${_FLAGS}"
fi

# ─── 12. slcl-nautilus systemd service ───────────────────────────────────────
step "Creating slcl-nautilus.service"
cat > /etc/systemd/system/slcl-nautilus.service <<UNIT
[Unit]
Description=VRAM slcl-nautilus Nitro Enclave
After=fix-nitro-pool.service nitro-enclaves-allocator.service
Wants=fix-nitro-pool.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/nitro-cli run-enclave \\
    --eif-path ${EIF_PATH} \\
    --memory ${ENCLAVE_MEMORY_MIB} \\
    --cpu-count ${ENCLAVE_CPU_COUNT} \\
    --enclave-cid ${ENCLAVE_CID}
ExecStop=/bin/sh -c 'nitro-cli describe-enclaves | python3 -c "import sys,json; [print(e[\"EnclaveID\"]) for e in json.load(sys.stdin)]" | xargs -r -I{} nitro-cli terminate-enclave --enclave-id {}'
Restart=no

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable slcl-nautilus.service 2>/dev/null || true
ok "slcl-nautilus.service enabled"

# ─── 13. vsock bridge ────────────────────────────────────────────────────────
step "Setting up vsock bridge (TCP 3000 → enclave vsock ${ENCLAVE_CID}:3000)"
cat > /etc/systemd/system/vram-vsock-bridge.service <<UNIT
[Unit]
Description=VRAM vsock bridge (TCP 3000 -> enclave vsock:${ENCLAVE_CID}:3000)
After=slcl-nautilus.service
Wants=slcl-nautilus.service

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:3000,reuseaddr,fork VSOCK-CONNECT:${ENCLAVE_CID}:3000
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now vram-vsock-bridge.service
ok "vram-vsock-bridge.service running"

# ─── 14. Health check ────────────────────────────────────────────────────────
step "Waiting for enclave health check (up to 120s)"
HEALTH_OK=false
for i in $(seq 1 120); do
    if curl -fsS --max-time 2 http://localhost:3000/health_check >/dev/null 2>&1; then
        HEALTH_OK=true; break
    fi
    (( i % 15 == 0 )) && warn "  ${i}s elapsed — still waiting..."
    sleep 1
done
if [[ "$HEALTH_OK" == "true" ]]; then
    ok "Enclave healthy after ~${i}s"
else
    warn "Enclave not responding after 120s"
    warn "Check: nitro-cli describe-enclaves"
    warn "Logs:  ENCLAVE_DEBUG=true bash <(curl -fsSL ${RAW_URL}/setup.sh)"
    fatal "Health check failed — cannot continue to registration"
fi

# ─── 15. Install vram-validator + vram-cli binaries ──────────────────────────
step "Installing vram-validator and vram-cli"
for _bin in vram-validator vram-cli; do
    _asset="${_bin}-linux-x86_64"
    _dest="/usr/local/bin/${_bin}"
    if curl -fsSL --retry 3 -o "$_dest" "${RELEASE_URL}/${_asset}" 2>/dev/null && \
       [[ $(stat -c%s "$_dest" 2>/dev/null || echo 0) -gt 100000 ]]; then
        chmod +x "$_dest"
        ok "Installed ${_bin}"
    else
        rm -f "$_dest" 2>/dev/null || true
        warn "${_bin} not yet in release — add to CI and re-run"
    fi
done

# ─── 16. ~/.env setup ────────────────────────────────────────────────────────
step "Setting up ~/.env (${ENV_FILE})"
if [[ ! -f "$ENV_FILE" ]]; then
    curl -fsSL -o "$ENV_FILE" "${RAW_URL}/.env.example" 2>/dev/null || \
        touch "$ENV_FILE"
    chown "$ACTUAL_USER" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    ok "Downloaded .env.example → ${ENV_FILE}"
fi

# Flip to production mode (binary reads SLCL_ prefix)
sed -i 's/^SLCL_TEST_MODE=true/SLCL_TEST_MODE=false/' "$ENV_FILE"
sed -i 's/^SLCL_NITRO_ENCLAVE=false/SLCL_NITRO_ENCLAVE=true/' "$ENV_FILE"
grep -q 'SLCL_ENCLAVE_URL' "$ENV_FILE" || \
    echo 'SLCL_ENCLAVE_URL=http://localhost:3000' >> "$ENV_FILE"
grep -q 'SLCL_NAUTILUS_URL' "$ENV_FILE" && \
    sed -i 's|^SLCL_NAUTILUS_URL=.*|SLCL_NAUTILUS_URL=http://localhost:3000|' "$ENV_FILE" || \
    echo 'SLCL_NAUTILUS_URL=http://localhost:3000' >> "$ENV_FILE"

# Check for wallet mnemonic
_MNEMONIC=$(grep -E '^VRAMHUB_WALLET_MNEMONIC=' "$ENV_FILE" | \
    cut -d= -f2- | sed "s/^['\"]//; s/['\"]$//" | xargs 2>/dev/null || echo "")
_MNEMONIC_PLACEHOLDER="word1 word2 word3"

if [[ -z "$_MNEMONIC" ]] || [[ "$_MNEMONIC" == *"$_MNEMONIC_PLACEHOLDER"* ]]; then
    echo
    echo "${C_YELLOW}${C_BOLD}Wallet mnemonic required${C_RESET}"
    echo "  Enter your Sui wallet 12-word or 24-word mnemonic phrase."
    echo "  This is stored in ${ENV_FILE} (chmod 600, readable only by you)."
    echo "  Press Ctrl+C to skip — you can add it manually later."
    echo
    read -r -p "  Mnemonic: " _MNEMONIC < /dev/tty || true
    if [[ -n "$_MNEMONIC" ]]; then
        sed -i "s|^VRAMHUB_WALLET_MNEMONIC=.*|VRAMHUB_WALLET_MNEMONIC=${_MNEMONIC}|" "$ENV_FILE"
        chown "$ACTUAL_USER" "$ENV_FILE"; chmod 600 "$ENV_FILE"
        ok "Mnemonic saved"
    else
        warn "No mnemonic entered — skipping registration"
        SKIP_REGISTER=true
    fi
fi

# ─── 17. On-chain registration ───────────────────────────────────────────────
if [[ "$SKIP_REGISTER" == "true" ]]; then
    warn "Skipping registration (SKIP_REGISTER=true or no mnemonic)"
elif ! command -v vram-cli >/dev/null 2>&1; then
    warn "vram-cli not installed — skipping registration (not in release yet)"
else
    step "On-chain registration"

    # Load current .env values
    _UID_EXISTING=$(grep -E '^VRAMHUB_VALIDATOR_UID=' "$ENV_FILE" | \
        cut -d= -f2- | tr -d "'\"\n " || echo "")
    _PUBKEY_EXISTING=$(grep -E '^VRAMHUB_ENCLAVE_PUBKEY=' "$ENV_FILE" | \
        cut -d= -f2- | tr -d "'\"\n " || echo "")

    # register-validator
    if [[ -z "$_UID_EXISTING" ]] || [[ "$_UID_EXISTING" == "0" ]]; then
        info "Running register-validator..."
        _REG_OUT=$(su -c "source ${ENV_FILE} && vram-cli register-validator 2>&1" \
            "$ACTUAL_USER" < /dev/null) || true
        echo "$_REG_OUT"
        _UID_NEW=$(echo "$_REG_OUT" | grep -oE 'VRAMHUB_VALIDATOR_UID=[0-9]+' | \
            cut -d= -f2 || echo "")
        if [[ -n "$_UID_NEW" ]] && [[ "$_UID_NEW" != "0" ]]; then
            sed -i "s/^VRAMHUB_VALIDATOR_UID=.*/VRAMHUB_VALIDATOR_UID=${_UID_NEW}/" "$ENV_FILE" || \
                echo "VRAMHUB_VALIDATOR_UID=${_UID_NEW}" >> "$ENV_FILE"
            _UID_EXISTING="$_UID_NEW"
            ok "Validator registered: UID=${_UID_NEW}"
        else
            warn "register-validator did not return a UID — check output above"
            warn "Add VRAMHUB_VALIDATOR_UID=<uid> to ${ENV_FILE} manually, then re-run"
            SKIP_REGISTER=true
        fi
    else
        ok "Already registered as validator: UID=${_UID_EXISTING}"
    fi

    # register-enclave
    if [[ "$SKIP_REGISTER" != "true" ]] && \
       [[ -n "$_UID_EXISTING" ]] && [[ "$_UID_EXISTING" != "0" ]] && \
       { [[ -z "$_PUBKEY_EXISTING" ]]; }; then
        info "Running register-enclave (UID=${_UID_EXISTING})..."
        _ENC_OUT=$(su -c "source ${ENV_FILE} && \
            vram-cli register-enclave \
                --enclave-url http://localhost:3000 \
                --validator-uid ${_UID_EXISTING} 2>&1" \
            "$ACTUAL_USER" < /dev/null) || true
        echo "$_ENC_OUT"
        _PUBKEY_NEW=$(echo "$_ENC_OUT" | grep -oE 'VRAMHUB_ENCLAVE_PUBKEY=[0-9a-f]+' | \
            cut -d= -f2 || echo "")
        if [[ -n "$_PUBKEY_NEW" ]]; then
            grep -q '^VRAMHUB_ENCLAVE_PUBKEY=' "$ENV_FILE" && \
                sed -i "s/^VRAMHUB_ENCLAVE_PUBKEY=.*/VRAMHUB_ENCLAVE_PUBKEY=${_PUBKEY_NEW}/" "$ENV_FILE" || \
                echo "VRAMHUB_ENCLAVE_PUBKEY=${_PUBKEY_NEW}" >> "$ENV_FILE"
            _PUBKEY_EXISTING="$_PUBKEY_NEW"
            ok "Enclave registered: pubkey=${_PUBKEY_NEW:0:16}..."
        else
            warn "register-enclave did not return a pubkey — check output above"
        fi
    elif [[ -n "$_PUBKEY_EXISTING" ]]; then
        ok "Enclave already registered: pubkey=${_PUBKEY_EXISTING:0:16}..."
    fi
fi

# ─── 18. vram-validator.service ──────────────────────────────────────────────
step "Creating vram-validator.service"
command -v vram-validator >/dev/null 2>&1 || { warn "vram-validator binary not installed — skipping service"; }
if command -v vram-validator >/dev/null 2>&1; then
    cat > /etc/systemd/system/vram-validator.service <<UNIT
[Unit]
Description=VRAM Validator Daemon
After=vram-vsock-bridge.service network-online.target
Wants=vram-vsock-bridge.service network-online.target

[Service]
User=${ACTUAL_USER}
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/local/bin/vram-validator
Restart=on-failure
RestartSec=15
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now vram-validator.service 2>/dev/null || true
    sleep 2
    _VSVC_STATUS=$(systemctl is-active vram-validator.service 2>/dev/null || echo "unknown")
    if [[ "$_VSVC_STATUS" == "active" ]]; then
        ok "vram-validator.service: active"
    else
        warn "vram-validator.service status: ${_VSVC_STATUS}"
        warn "Check: sudo journalctl -u vram-validator -n 30 --no-pager"
    fi
fi

# ─── 19. Final summary ───────────────────────────────────────────────────────
echo
echo "${C_GREEN}${C_BOLD}╔══════════════════════════════════════════════════════╗"
echo "║            Setup complete                            ║"
echo "╚══════════════════════════════════════════════════════╝${C_RESET}"
echo
_UID_FINAL=$(grep -E '^VRAMHUB_VALIDATOR_UID=' "$ENV_FILE" | cut -d= -f2- | tr -d "'\"\n " || echo "not set")
_PUBKEY_FINAL=$(grep -E '^VRAMHUB_ENCLAVE_PUBKEY=' "$ENV_FILE" | cut -d= -f2- | tr -d "'\"\n " || echo "not set")
echo "  ${C_BOLD}Enclave ID:${C_RESET}       $ENCLAVE_ID"
echo "  ${C_BOLD}Enclave mode:${C_RESET}     ${_FLAGS}"
echo "  ${C_BOLD}Validator UID:${C_RESET}    ${_UID_FINAL}"
echo "  ${C_BOLD}Enclave pubkey:${C_RESET}   ${_PUBKEY_FINAL:0:24}..."
echo "  ${C_BOLD}EIF:${C_RESET}             ${EIF_PATH}"
[[ -n "$PCR0" ]] && echo "  ${C_BOLD}PCR0:${C_RESET}            ${PCR0:0:32}..."
echo "  ${C_BOLD}Endpoint:${C_RESET}        http://localhost:3000"
echo "  ${C_BOLD}Config:${C_RESET}          ${ENV_FILE}"
echo
echo "  ${C_BOLD}Services:${C_RESET}"
echo "    systemctl status slcl-nautilus"
echo "    systemctl status vram-vsock-bridge"
echo "    systemctl status vram-validator"
echo "    sudo journalctl -u vram-validator -f"
echo

if [[ "$_UID_FINAL" == "not set" ]] || [[ "$_UID_FINAL" == "0" ]]; then
    echo "  ${C_YELLOW}${C_BOLD}Registration incomplete.${C_RESET}"
    echo "  Fill in ${ENV_FILE} with your mnemonic and run:"
    echo "    source ${ENV_FILE}"
    echo "    vram-cli register-validator"
    echo "    echo 'VRAMHUB_VALIDATOR_UID=<uid>' >> ${ENV_FILE}"
    echo "    source ${ENV_FILE}"
    echo "    vram-cli register-enclave --enclave-url http://localhost:3000 --validator-uid \$VRAMHUB_VALIDATOR_UID"
    echo "    sudo systemctl restart vram-validator"
fi
