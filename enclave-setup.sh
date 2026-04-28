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
# Ubuntu 22.04 / 24.04 or Amazon Linux 2023, x86_64.
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

# ─── 2. OS detection + prerequisites ────────────────────────────────────────
step "Installing prerequisites"
if command -v apt-get >/dev/null 2>&1; then
    _PKG_MGR="apt"
elif command -v dnf >/dev/null 2>&1; then
    _PKG_MGR="dnf"
else
    fatal "Unsupported OS: neither apt-get nor dnf found"
fi
ok "Detected package manager: ${_PKG_MGR}"

if [[ "$_PKG_MGR" == "dnf" ]]; then
    # AL2023 ships curl-minimal which conflicts with the full curl package — skip curl (binary already present)
    dnf install -y jq || fatal "dnf install jq failed"
    # Docker on AL2023: try plain 'docker' first, then Docker CE repo
    if ! dnf install -y docker 2>&1; then
        warn "docker package not found — trying Docker CE repo"
        dnf install -y dnf-plugins-core || true
        dnf config-manager --add-repo \
            https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null || true
        dnf install -y docker-ce docker-ce-cli containerd.io || \
            fatal "Could not install Docker — install manually and re-run"
    fi
    ok "Base packages installed"
    systemctl enable --now docker 2>/dev/null || true
    ok "Docker running"
else
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
fi

# ─── 3. Install nitro-cli ───────────────────────────────────────────────────
step "Installing nitro-cli"
# Prefer the distro package — it includes the allocator service + udev rules.
# The downloaded binary (v1.4.4) has a confirmed vsock bind failure on kernel 6.17+.
_NITRO_FROM_PKG=false
if [[ "$_PKG_MGR" == "dnf" ]]; then
    if dnf install -y aws-nitro-enclaves-cli aws-nitro-enclaves-cli-devel >/dev/null 2>&1; then
        [[ -f /usr/local/bin/nitro-cli ]] && rm -f /usr/local/bin/nitro-cli
        _NITRO_FROM_PKG=true
        ok "nitro-cli installed via dnf: $(nitro-cli --version 2>&1 | head -1)"
    fi
elif apt-get install -y -qq aws-nitro-enclaves-cli 2>/dev/null; then
    apt-get install -y -qq aws-nitro-enclaves-cli-devel 2>/dev/null || true
    [[ -f /usr/local/bin/nitro-cli ]] && rm -f /usr/local/bin/nitro-cli
    _NITRO_FROM_PKG=true
    ok "nitro-cli installed via apt: $(nitro-cli --version 2>&1 | head -1)"
fi

if [[ "$_NITRO_FROM_PKG" == "false" ]]; then
    if command -v nitro-cli >/dev/null 2>&1; then
        ok "nitro-cli already installed (binary): $(nitro-cli --version 2>&1 | head -1)"
    else
        warn "aws-nitro-enclaves-cli not in package manager — using release binary"
        curl -fsSL -o /usr/local/bin/nitro-cli \
            "${RELEASE_URL}/nitro-cli-linux-x86_64"
        chmod +x /usr/local/bin/nitro-cli
        ok "nitro-cli binary installed"
    fi
fi

# On Nitro parent instances, enclave vsock uses vhost_vsock (H2G transport) —
# the parent acts as a host relative to the enclave, so vhost_vsock routes
# AF_VSOCK connects to enclave CIDs.  vmw_vsock_virtio_transport (G2H) would
# intercept those connects and fail with ENODEV because the virtio vsock device
# only routes to the hypervisor (CID 2), not to enclave CIDs.
# vhost_vsock MUST be loaded before the enclave starts so the NE driver can
# register the enclave CID with the vhost backend via /dev/vhost-vsock.
modprobe vsock 2>/dev/null || true
modprobe vhost 2>/dev/null || true
modprobe vhost_vsock 2>/dev/null || true

# Unload vmw_vsock_virtio_transport if present — it registers as H2G and
# overrides vhost_vsock, causing ENODEV on connect to enclave CIDs.
if lsmod | grep -q vmw_vsock_virtio_transport; then
    # Unbind from any virtio device first so rmmod succeeds
    for _vdev in /sys/bus/virtio/drivers/vmw_vsock_virtio_transport/virtio*/; do
        [[ -e "$_vdev" ]] && echo "$(basename "$_vdev")" \
            > /sys/bus/virtio/drivers/vmw_vsock_virtio_transport/unbind 2>/dev/null || true
    done
    modprobe -r vmw_vsock_virtio_transport 2>/dev/null || true
fi

if [[ -e /dev/vhost-vsock ]]; then
    ok "vhost_vsock loaded — /dev/vhost-vsock present"
else
    warn "vhost_vsock failed to load — AF_VSOCK to enclave CIDs may not work"
    warn "lsmod: $(lsmod | awk '/vsock|vhost|nitro/{printf \"%s(ref=%s) \",$1,$3}')"
fi

# Functional test: bind an AF_VSOCK socket (confirms vsock module is functional).
if python3 - <<'PYEOF' 2>/dev/null
import socket, sys
s = socket.socket(getattr(socket,'AF_VSOCK',40), socket.SOCK_STREAM)
try:
    s.bind((getattr(socket,'VMADDR_CID_ANY',0xFFFFFFFF), 65432))
    s.close(); sys.exit(0)
except Exception as e:
    sys.stderr.write(str(e)+'\n'); sys.exit(1)
PYEOF
then
    ok "AF_VSOCK bind test passed — vsock transport is functional"
else
    warn "AF_VSOCK bind FAILED — vsock transport not registered"
    warn "lsmod: $(lsmod | awk '/vsock|vhost|nitro/{printf \"%s(ref=%s) \",$1,$3}')"
fi

# Load nitro_enclaves.  Remove any stale modprobe.d options file first so
# a previous ne_cpus value doesn't interfere.
rm -f /etc/modprobe.d/nitro_enclaves.conf
modprobe nitro_enclaves 2>/dev/null || true

# Create the enclave sockets directory early — describe-enclaves needs it.
# 755 so non-root users (ubuntu) can list enclaves without sudo.
# tmpfiles.d entry recreates it on every reboot (it lives on tmpfs).
mkdir -p /run/nitro_enclaves
chmod 755 /run/nitro_enclaves
echo 'd /run/nitro_enclaves 0755 root root -' > /etc/tmpfiles.d/nitro-enclaves.conf

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

# Detect if the allocator systemd unit is installed (aws-nitro-enclaves-cli apt package)
ALLOC_SVC=$(systemctl list-unit-files 2>/dev/null | grep nitro-enclaves-allocator | head -1 || true)

if [[ -n "$ALLOC_SVC" ]]; then
    systemctl enable nitro-enclaves-allocator.service
    systemctl restart nitro-enclaves-allocator.service
    sleep 2
    ok "Allocator service running"
else
    # No allocator service — reserve resources directly via the kernel module.
    #
    # The nitro_enclaves module accepts an `ne_cpus` parameter at load time that
    # takes CPU IDs offline from the host and adds them to the enclave pool.
    # We reload the module with this parameter to configure the pool.
    # This is the standard alternative to the allocator binary on systems where
    # the aws-nitro-enclaves-cli apt package is not installed.

    warn "nitro-enclaves-allocator.service not found — configuring pool via kernel module"

    # 1. Reserve huge pages for enclave memory (each page is 2 MiB)
    HUGE_PAGES=$((ENCLAVE_MEMORY_MIB / 2))
    echo "$HUGE_PAGES" > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
    ACTUAL_HP=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages)
    ok "Huge pages: ${ACTUAL_HP} × 2 MiB = $((ACTUAL_HP * 2)) MiB reserved"

    # 2. Determine the target CPU list for the enclave pool.
    #
    # Key constraint: on kernel 6.17, offline CPUs lose their sysfs
    # topology/core_id files. A live topology scan therefore fails when the
    # pool CPUs are already offline (all topology info gone → empty CPU_LIST).
    # Re-onlining the pool CPUs to do the scan would then undo the pool state
    # and force an unnecessary rmmod+modprobe, which disrupts vsock (→ E36).
    #
    # Strategy:
    #   A) If nitro_enclaves is loaded and we have a saved ne_cpus config that
    #      satisfies ENCLAVE_CPU_COUNT, AND those CPUs are currently offline
    #      (in pool) → use saved config, skip topology scan and reload entirely.
    #   B) Otherwise, re-online all CPUs (they must be online for the scan to
    #      see their topology), run the scan, then reload the module.

    CPU_LIST=""
    _NEED_RELOAD=true

    # (A) Try to reuse the existing pool without touching vsock.
    SAVED_CPU_LIST=$(sed -n 's/.*ne_cpus=\([0-9,]*\).*/\1/p' \
        /etc/modprobe.d/nitro_enclaves.conf 2>/dev/null || echo "")
    SAVED_COUNT=$(echo "$SAVED_CPU_LIST" | tr ',' '\n' | grep -c '[0-9]' 2>/dev/null || echo 0)

    if lsmod | grep -q "^nitro_enclaves" && \
       [[ -n "$SAVED_CPU_LIST" ]] && \
       [[ "$SAVED_COUNT" -ge "$ENCLAVE_CPU_COUNT" ]]; then
        _all_offline=true
        for _cpu in $(echo "$SAVED_CPU_LIST" | tr ',' ' '); do
            _state=$(cat "/sys/devices/system/cpu/cpu${_cpu}/online" 2>/dev/null || echo "1")
            [[ "$_state" != "0" ]] && _all_offline=false && break
        done
        if $_all_offline; then
            CPU_LIST="$SAVED_CPU_LIST"
            _NEED_RELOAD=false
            ok "CPU pool already active (${CPU_LIST} offline) — skipping module reload"
        fi
    fi

    # (B) Fresh scan: re-online all CPUs so topology files are accessible.
    if [[ -z "$CPU_LIST" ]]; then
        for _ocpu in /sys/devices/system/cpu/cpu[0-9]*/online; do
            [[ -f "$_ocpu" ]] && echo 1 > "$_ocpu" 2>/dev/null || true
        done
        sleep 0.2
        TOTAL_CPUS=$(nproc --all)
        if [[ $ENCLAVE_CPU_COUNT -ge $TOTAL_CPUS ]]; then
            fatal "Cannot reserve ${ENCLAVE_CPU_COUNT} CPUs — host only has ${TOTAL_CPUS}"
        fi
        CPU_LIST=$(python3 - "${ENCLAVE_CPU_COUNT}" <<'PYEOF'
import os, sys, collections
enclave_cpus = int(sys.argv[1])
cpu_dir = '/sys/devices/system/cpu'
core_to_cpus = collections.defaultdict(list)
for ent in sorted(os.listdir(cpu_dir)):
    if not ent.startswith('cpu') or not ent[3:].isdigit():
        continue
    cpu_id = int(ent[3:])
    core_path = os.path.join(cpu_dir, ent, 'topology', 'core_id')
    if os.path.exists(core_path):
        core_id = int(open(core_path).read().strip())
        core_to_cpus[core_id].append(cpu_id)
sorted_cores = sorted(core_to_cpus.keys(), reverse=True)
pool = []
for core in sorted_cores:
    if len(pool) >= enclave_cpus:
        break
    cpus = core_to_cpus[core]
    if 0 in cpus:
        continue
    pool.extend(cpus)
print(','.join(str(c) for c in sorted(pool)))
PYEOF
        )
        if [[ -z "$CPU_LIST" ]]; then
            fatal "No eligible CPUs found for enclave pool (need ${ENCLAVE_CPU_COUNT}, host has ${TOTAL_CPUS})."
        fi
        ok "Reserving CPUs ${CPU_LIST} for enclave pool (of ${TOTAL_CPUS} total)"
    fi

    # 3. Load / reload nitro_enclaves with the chosen CPU pool (if needed).
    EXISTING_ENCLAVE=$(nitro-cli describe-enclaves 2>/dev/null | \
        jq -r ".[] | select(.EnclaveCID == ${ENCLAVE_CID}) | .EnclaveID" 2>/dev/null || echo "")

    if [[ -n "$EXISTING_ENCLAVE" ]]; then
        ok "Enclave already running with CID ${ENCLAVE_CID} — pool already configured"
        echo "vm.nr_hugepages=${HUGE_PAGES}" > /etc/sysctl.d/20-nitro-enclaves.conf

    elif [[ "$_NEED_RELOAD" == "false" ]]; then
        # Pool is already active — nothing to do for the module.
        echo "vm.nr_hugepages=${HUGE_PAGES}" > /etc/sysctl.d/20-nitro-enclaves.conf

    else
        # Need to (re)load the module.  CPUs must be online before modprobe.
        for _cpu in $(echo "${CPU_LIST}" | tr ',' ' '); do
            _f="/sys/devices/system/cpu/cpu${_cpu}/online"
            for _t in $(seq 1 20); do
                [[ "$(cat "$_f" 2>/dev/null)" == "1" ]] && break
                echo 1 > "$_f" 2>/dev/null || true; sleep 0.1
            done
        done
        if lsmod | grep -q "^nitro_enclaves"; then
            if ! rmmod nitro_enclaves 2>/dev/null; then
                fatal "nitro_enclaves in use — terminate existing enclaves first: sudo nitro-cli terminate-enclave --all"
            fi
            sleep 1
            # rmmod may not re-online CPUs on kernel 6.17 — retry explicitly.
            for _cpu in $(echo "${CPU_LIST}" | tr ',' ' '); do
                _f="/sys/devices/system/cpu/cpu${_cpu}/online"
                for _t in $(seq 1 20); do
                    [[ "$(cat "$_f" 2>/dev/null)" == "1" ]] && break
                    echo 1 > "$_f" 2>/dev/null || true; sleep 0.1
                done
                [[ "$(cat "$_f" 2>/dev/null)" != "1" ]] && \
                    fatal "CPU ${_cpu} still offline after rmmod — reboot the instance to reset CPU state"
            done
        fi
        rm -f /etc/modprobe.d/nitro_enclaves.conf
        if ! modprobe nitro_enclaves ne_cpus="${CPU_LIST}"; then
            dmesg | tail -10 >&2
            fatal "Could not load nitro_enclaves with ne_cpus=${CPU_LIST}"
        fi
        ok "nitro_enclaves loaded with ne_cpus=${CPU_LIST}"
        echo "options nitro_enclaves ne_cpus=${CPU_LIST}" > /etc/modprobe.d/nitro_enclaves.conf
        echo "vm.nr_hugepages=${HUGE_PAGES}" > /etc/sysctl.d/20-nitro-enclaves.conf
        ok "Pool settings saved (persists across reboots)"

        # Reload vhost_vsock after nitro_enclaves load to restore clean vsock state.
        if lsmod | grep -q "^vhost_vsock"; then
            rmmod vhost_vsock 2>/dev/null || true
            sleep 0.3
            modprobe vhost_vsock 2>/dev/null || true
            sleep 0.5
        fi
    fi
fi

# ─── 5. Install vram-cli (on-chain registration tool) ───────────────────────
step "Installing vram-cli"
if command -v vram-cli >/dev/null 2>&1; then
    ok "vram-cli already installed: $(vram-cli --version 2>&1 | head -1)"
else
    if curl -fsSL --retry 3 -o /usr/local/bin/vram-cli \
        "${RELEASE_URL}/vram-cli-linux-x86_64" 2>/dev/null && \
       [[ $(stat -c%s /usr/local/bin/vram-cli 2>/dev/null) -gt 100000 ]]; then
        chmod +x /usr/local/bin/vram-cli
        ok "vram-cli installed"
    else
        rm -f /usr/local/bin/vram-cli
        warn "vram-cli not yet in this release — install manually after CI completes:"
        warn "  curl -Lo /usr/local/bin/vram-cli ${RELEASE_URL}/vram-cli-linux-x86_64 && chmod +x /usr/local/bin/vram-cli"
    fi
fi

# ─── 6. Download pre-built nautilus binary ──────────────────────────────────
step "Downloading pre-built slcl-nautilus binary"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

curl -fsSL --retry 3 -o "$BUILD_DIR/slcl-nautilus" \
    "${RELEASE_URL}/slcl-nautilus-linux-x86_64"
chmod +x "$BUILD_DIR/slcl-nautilus"
SIZE=$(stat -c%s "$BUILD_DIR/slcl-nautilus")
ok "Downloaded slcl-nautilus ($(numfmt --to=iec-i --suffix=B "$SIZE"))"

# ─── 7. Build Docker image for EIF ──────────────────────────────────────────
step "Building Docker image for EIF"
# slcl-nautilus listens on vsock natively (VMADDR_CID_ANY:3000).
# The host-side socat bridges: TCP-LISTEN:3000 → VSOCK-CONNECT:CID:3000.
# FROM scratch keeps the EIF minimal and the PCR measurements stable.
cat > "$BUILD_DIR/Dockerfile" <<'EOF'
FROM alpine:3.19
RUN apk add --no-cache ca-certificates
COPY slcl-nautilus /app/slcl-nautilus
ENV PORT=3000
# The Nitro Enclave kernel registers a dummy VGA console before ttyS0, so
# /dev/console may alias to the VGA device (invisible in nitro-cli console).
# Write to /dev/ttyS0 directly to guarantee output on the serial console.
ENTRYPOINT ["/bin/sh", "-c", "echo '[nautilus] sh wrapper started' >/dev/ttyS0 2>/dev/null; exec /app/slcl-nautilus 2>/dev/ttyS0"]
EOF

docker build -t slcl-nautilus:latest "$BUILD_DIR/" 2>&1 | grep -v "^#" | tail -5
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
mkdir -p "$INSTALL_DIR" /var/log/nitro_enclaves
EIF_PATH="$INSTALL_DIR/slcl-nautilus.eif"
BUILD_OUT="$INSTALL_DIR/build-output.json"
HASH_FILE="$INSTALL_DIR/image.sha256"

# Hash both the Dockerfile AND the binary — the EIF must be rebuilt whenever
# either changes (binary changes don't alter the Dockerfile hash).
IMAGE_HASH=$( (sha256sum "$BUILD_DIR/Dockerfile"; sha256sum "$BUILD_DIR/slcl-nautilus") \
    | sha256sum | cut -d' ' -f1)
CACHED_HASH=$(cat "$HASH_FILE" 2>/dev/null || echo "")

if [[ -f "$EIF_PATH" ]] && [[ -f "$BUILD_OUT" ]] && \
   grep -q 'PCR0' "$BUILD_OUT" 2>/dev/null && \
   [[ "$IMAGE_HASH" == "$CACHED_HASH" ]]; then
    ok "EIF already exists (Dockerfile + binary unchanged), skipping build"
elif ! nitro-cli build-enclave \
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

echo "$IMAGE_HASH" > "$HASH_FILE"
ok "EIF built: $EIF_PATH"
echo "    PCR0: ${PCR0:0:32}..."
echo "    PCR1: ${PCR1:0:32}..."
echo "    PCR2: ${PCR2:0:32}..."

# ─── 8. Terminate any previously running enclave ────────────────────────────
step "Stopping any existing enclaves"
RUNNING=$(nitro-cli describe-enclaves 2>/dev/null | jq -r '.[].EnclaveID' 2>/dev/null || echo "")
if [[ -n "$RUNNING" ]]; then
    for eid in $RUNNING; do
        nitro-cli terminate-enclave --enclave-id "$eid" >/dev/null
        ok "Terminated $eid"
    done

    # After terminate-enclave the nitro_enclaves module de-registers the old
    # enclave's vsock CID.  A subsequent run-enclave does NOT re-register it
    # reliably — reload nitro_enclaves so the new enclave's CID is visible to
    # the host vsock transport (vmw_vsock_virtio_transport, the EC2 virtio vsock)
    # before socat tries to connect.
    # Only needed when we manage the module directly (no allocator service).
    if [[ -z "$ALLOC_SVC" ]]; then
        # Read the ACTUAL ne_cpus the kernel has loaded — sysfs is authoritative.
        # The enclave keeps its CPUs offline, so lscpu shows a truncated topology
        # and CPU_LIST may include CPU 0 (invalid).  Prefer sysfs, then the conf
        # file written by a previous successful module load.
        _RELOAD_CPUS="$(cat /sys/module/nitro_enclaves/parameters/ne_cpus 2>/dev/null || true)"
        _RELOAD_CPUS="${_RELOAD_CPUS:-$(grep -oP '(?<=ne_cpus=)\S+' \
            /etc/modprobe.d/nitro_enclaves.conf 2>/dev/null)}"
        if [[ -n "$_RELOAD_CPUS" ]]; then
            rmmod nitro_enclaves 2>/dev/null || true
            sleep 0.3
            for _cpu in $(echo "${_RELOAD_CPUS}" | tr ',' ' '); do
                _f="/sys/devices/system/cpu/cpu${_cpu}/online"
                [[ -f "$_f" ]] && echo 1 > "$_f" 2>/dev/null || true
            done
            rm -f /etc/modprobe.d/nitro_enclaves.conf
            modprobe nitro_enclaves ne_cpus="${_RELOAD_CPUS}"
            echo "options nitro_enclaves ne_cpus=${_RELOAD_CPUS}" \
                > /etc/modprobe.d/nitro_enclaves.conf
            ok "vsock transport refreshed (ne_cpus=${_RELOAD_CPUS})"
        fi
    fi
else
    ok "No existing enclaves"
fi

# ─── 9. Run the enclave ─────────────────────────────────────────────────────
step "Starting enclave (CID=${ENCLAVE_CID})"
DEBUG_FLAG=""
if [[ "$ENCLAVE_DEBUG" == "true" ]]; then
    DEBUG_FLAG="--debug-mode"
fi

# Pre-flight: test AF_VSOCK bind on the ports nitro-cli uses for the
# enclave heartbeat (9000) and our own diagnostic port (65432).
# A bind failure here means run-enclave will fail with E36 vsock error.
python3 - <<'PYEOF'
import socket, sys, os
AF_VSOCK  = getattr(socket, 'AF_VSOCK',       40)
CID_ANY   = getattr(socket, 'VMADDR_CID_ANY', 0xFFFFFFFF)
failed = []
for port in [9000, 9001, 65432]:
    try:
        s = socket.socket(AF_VSOCK, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((CID_ANY, port))
        s.close()
    except Exception as e:
        failed.append((port, str(e)))
if failed:
    for p, e in failed:
        print(f"vsock port {p} FAILED: {e}", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PYEOF
_vsock_rc=$?
if [[ $_vsock_rc -ne 0 ]]; then
    warn "AF_VSOCK bind pre-flight FAILED on heartbeat ports — attempting recovery"
    rmmod vhost_vsock 2>/dev/null || true
    sleep 0.3
    modprobe vhost 2>/dev/null || true
    modprobe vhost_vsock 2>/dev/null || true
    sleep 0.5
    if python3 - <<'PYEOF' 2>/dev/null
import socket, sys
s = socket.socket(getattr(socket,'AF_VSOCK',40), socket.SOCK_STREAM)
s.bind((getattr(socket,'VMADDR_CID_ANY',0xFFFFFFFF), 9000))
s.close(); sys.exit(0)
PYEOF
    then
        ok "AF_VSOCK bind recovered"
    else
        warn "AF_VSOCK port 9000 still failing — E36 boot heartbeat will fail"
        warn "vsock modules: $(lsmod | awk '/vsock/{printf \"%s(ref=%s) \",$1,$3}')"
        warn "Devices: $(ls /dev/vhost-vsock /dev/vsock 2>/dev/null | tr '\n' ' '; echo)"
        warn "Consider rebooting the instance to restore vsock state"
    fi
else
    ok "AF_VSOCK bind test passed on ports 9000, 9001, 65432"
fi

nitro-cli run-enclave \
    --eif-path "$EIF_PATH" \
    --memory "$ENCLAVE_MEMORY_MIB" \
    --cpu-count "$ENCLAVE_CPU_COUNT" \
    --enclave-cid "$ENCLAVE_CID" \
    $DEBUG_FLAG > /tmp/run-enclave.json 2>&1 || true

# nitro-cli mixes status text, JSON, and error text in a single stream.
# Extract the JSON block with regex, then fall back to describe-enclaves
# to confirm the enclave is actually running (the IPC monitor error is
# non-fatal when the enclave itself started successfully).
RUN_JSON=$(python3 -c "
import sys, re
data = open('/tmp/run-enclave.json').read()
m = re.search(r'(\{[^{}]*\"EnclaveID\"[^{}]*\})', data, re.DOTALL)
print(m.group(1) if m else '{}')
" 2>/dev/null || echo '{}')

ENCLAVE_ID=$(echo "$RUN_JSON" | jq -r '.EnclaveID // empty' 2>/dev/null || echo "")

# If jq found nothing, check whether an enclave with our CID is already running
if [[ -z "$ENCLAVE_ID" ]]; then
    ENCLAVE_ID=$(nitro-cli describe-enclaves 2>/dev/null | \
        jq -r ".[] | select(.EnclaveCID == ${ENCLAVE_CID}) | .EnclaveID" 2>/dev/null || echo "")
fi

if [[ -z "$ENCLAVE_ID" ]]; then
    warn "run-enclave output:"
    cat /tmp/run-enclave.json
    warn "--- nitro_enclaves kernel messages ---"
    dmesg | grep -i "nitro\|enclave\|vsock" | tail -20 || true
    warn "--- AppArmor denials (vsock bind often blocked by aa profile) ---"
    dmesg | grep -i "apparmor\|DENIED" | tail -10 || true
    journalctl -k --since "5 minutes ago" 2>/dev/null | grep -i "DENIED\|apparmor" | tail -10 || true
    warn "--- nitro error logs ---"
    for _elog in $(ls -t /var/log/nitro_enclaves/err*.log 2>/dev/null | head -5); do
        warn "  $_elog:"
        cat "$_elog" 2>/dev/null || true
    done
    rm -f "$HASH_FILE"
    warn "EIF cache cleared — next run will rebuild the enclave image"
    fatal "Failed to start enclave — re-run with ENCLAVE_DEBUG=true for console output"
fi
ok "Enclave started: $ENCLAVE_ID"

# ─── 10. vsock-proxy: localhost:3000 → enclave:3000 ─────────────────────────
step "Setting up vsock-proxy bridge (localhost:3000 → CID ${ENCLAVE_CID}:3000)"
if [[ "$_PKG_MGR" == "dnf" ]]; then
    dnf install -y socat >/dev/null 2>&1
else
    apt-get install -y -qq socat
fi

tee /etc/systemd/system/vram-vsock-bridge.service > /dev/null << SVCEOF
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
SVCEOF

systemctl daemon-reload
systemctl enable --now vram-vsock-bridge.service
sleep 2
ok "vsock bridge running on 127.0.0.1:3000"

# ─── 11. Health check ───────────────────────────────────────────────────────
step "Health check (waiting up to 120s for enclave to serve /health)"
HEALTH_OK=false
for i in $(seq 1 120); do
    if curl -fsS --max-time 2 http://localhost:3000/health_check >/dev/null 2>&1; then
        HEALTH_OK=true
        break
    fi
    if (( i % 10 == 0 )); then
        warn "Still waiting… ${i}s elapsed"
    fi
    sleep 1
done

if [[ "$HEALTH_OK" == "true" ]]; then
    ok "Enclave is healthy (responded after ~${i}s)"
else
    warn "Enclave did not respond to /health_check in 120s"
    warn "Check: nitro-cli describe-enclaves"
    warn "Logs:  sudo ENCLAVE_DEBUG=true bash enclave-setup.sh   (rebuild with debug mode)"
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
echo "  1. Register as a validator peer (first time only):"
echo "     ${C_CYAN}source ~/.env${C_RESET}"
echo "     ${C_CYAN}vram-cli register-validator${C_RESET}"
echo "     # Prints: VRAMHUB_VALIDATOR_UID=<uid>"
echo "     ${C_CYAN}echo 'VRAMHUB_VALIDATOR_UID=<uid>' >> ~/.env${C_RESET}"
echo
echo "  2. Register the enclave on-chain:"
echo "     ${C_CYAN}source ~/.env${C_RESET}"
echo '     '"${C_CYAN}"'vram-cli register-enclave --enclave-url http://localhost:3000 --validator-uid $VRAMHUB_VALIDATOR_UID'"${C_RESET}"
echo "     # Prints: VRAMHUB_ENCLAVE_PUBKEY=<hex>"
echo "     ${C_CYAN}echo 'VRAMHUB_ENCLAVE_PUBKEY=<hex>' >> ~/.env${C_RESET}"
echo
echo "  3. Enable production mode in ~/.env:"
echo "     ${C_CYAN}echo 'VRAMHUB_NITRO_ENCLAVE=true'  >> ~/.env${C_RESET}"
echo "     ${C_CYAN}echo 'VRAMHUB_TEST_MODE=false'     >> ~/.env${C_RESET}"
echo
echo "  4. Run the validator:"
echo "     ${C_CYAN}source ~/.env && vram-validator${C_RESET}"
echo
echo "  ${C_BOLD}Useful commands:${C_RESET}"
echo "     nitro-cli describe-enclaves"
echo "     systemctl status vram-vsock-bridge"
echo "     journalctl -u vram-vsock-bridge -f"
echo
