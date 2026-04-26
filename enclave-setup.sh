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
    # Try the apt package first (installs allocator service too); -devel is optional
    if apt-get install -y -qq aws-nitro-enclaves-cli 2>/dev/null; then
        apt-get install -y -qq aws-nitro-enclaves-cli-devel 2>/dev/null || true
        ok "Installed aws-nitro-enclaves-cli via apt"
    else
        warn "aws-nitro-enclaves-cli not in apt (normal on Ubuntu 24.04) — using release binary"
        curl -fsSL -o /usr/local/bin/nitro-cli \
            "${RELEASE_URL}/nitro-cli-linux-x86_64"
        chmod +x /usr/local/bin/nitro-cli
        ok "nitro-cli binary installed"
    fi
fi

# Remove any stale blacklist from a previous script run.
rm -f /etc/modprobe.d/blacklist-vmw-vsock.conf

# On EC2 Nitro, the virtio-vsock device is presented by the hypervisor.
# The guest driver (vmw_vsock_virtio_transport) must be both LOADED and BOUND
# to the device for the transport to register — loading the module alone is not
# enough.  The driver's refcount in lsmod will be 0 if it loaded without a
# device probe.  We explicitly trigger a virtio bus scan after loading so the
# kernel binds the driver to the vsock device.
modprobe vsock 2>/dev/null || true
modprobe vhost 2>/dev/null || true
modprobe vhost_vsock 2>/dev/null || true
modprobe vmw_vsock_virtio_transport 2>/dev/null || true

# Explicitly bind vmw_vsock_virtio_transport to the virtio-vsock device (device
# ID 19 = 0x0013) if it exists but hasn't been auto-probed (e.g. after manual
# module reload).  Writing the device name to the driver's bind sysfs file
# triggers probe() and vsock_core_register() without needing udevadm.
for _vdev in /sys/bus/virtio/devices/*/; do
    _id=$(printf '%d' "$(cat "${_vdev}device" 2>/dev/null || echo 0)" 2>/dev/null || echo 0)
    if [[ "$_id" -eq 19 ]]; then
        _devname=$(basename "$_vdev")
        # Bind succeeds silently; EBUSY means already bound (both are fine).
        echo "$_devname" > /sys/bus/virtio/drivers/vmw_vsock_virtio_transport/bind 2>/dev/null || true
        ok "Bound vmw_vsock_virtio_transport to virtio vsock device $_devname"
        break
    fi
done

# Functional test: actually try to bind an AF_VSOCK socket.
# lsmod refcounts only show module dependencies, not transport registration —
# a module can be loaded but unbound (no device probe) and bind() still fails.
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
    warn "lsmod: $(lsmod | awk '/vsock|nitro/{printf \"%s(ref=%s) \",$1,$3}')"
    warn "virtio devices: $(ls /sys/bus/virtio/devices/ 2>/dev/null | tr '\n' ' ')"
    warn "Rebooting the instance will restore the original vsock state."
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

    # 2. Choose which CPUs to dedicate to the enclave pool.
    #    The driver requires ALL hyperthreads of a physical core to be in the
    #    pool together — you cannot mix threads from different cores.
    #    We walk CPUs from the end (avoiding CPU 0 which handles IRQs), read
    #    each CPU's thread_siblings_list, and accumulate whole cores until we
    #    have enough vCPUs.
    TOTAL_CPUS=$(nproc --all)
    if [[ $ENCLAVE_CPU_COUNT -ge $TOTAL_CPUS ]]; then
        fatal "Cannot reserve ${ENCLAVE_CPU_COUNT} CPUs — host only has ${TOTAL_CPUS}"
    fi
    # Use lscpu -p to build a core→cpu mapping (reliable on all kernels/hypervisors)
    CPU_LIST=$(python3 - "${ENCLAVE_CPU_COUNT}" <<'PYEOF'
import subprocess, sys, collections

enclave_cpus = int(sys.argv[1])

# lscpu -p outputs lines like: CPU,Core,Socket,... (skip comment lines)
out = subprocess.check_output(['lscpu', '-p'], text=True)
core_to_cpus = collections.defaultdict(list)
for line in out.splitlines():
    if line.startswith('#') or not line.strip():
        continue
    fields = line.split(',')
    cpu_id, core_id = int(fields[0]), int(fields[1])
    core_to_cpus[core_id].append(cpu_id)

# Sort cores descending (prefer higher-numbered cores, avoiding core 0).
# Skip any physical core that contains CPU 0 — it handles IPIs/IRQs and
# cannot be in the enclave pool (the driver returns EINVAL).
sorted_cores = sorted(core_to_cpus.keys(), reverse=True)

pool = []
for core in sorted_cores:
    if len(pool) >= enclave_cpus:
        break
    cpus = core_to_cpus[core]
    if 0 in cpus:
        continue  # boot CPU cannot be in enclave pool
    pool.extend(cpus)

print(','.join(str(c) for c in sorted(pool)))
PYEOF
)
    ok "Reserving CPUs ${CPU_LIST} for enclave pool (of ${TOTAL_CPUS} total, aligned to physical cores)"

    # 3. Reload the nitro_enclaves module with ne_cpus to activate the pool.
    #    Skip if an enclave with our CID is already running (pool already set).
    EXISTING_ENCLAVE=$(nitro-cli describe-enclaves 2>/dev/null | \
        jq -r ".[] | select(.EnclaveCID == ${ENCLAVE_CID}) | .EnclaveID" 2>/dev/null || echo "")

    if [[ -n "$EXISTING_ENCLAVE" ]]; then
        ok "Enclave already running with CID ${ENCLAVE_CID} — CPU pool already configured"
        echo "vm.nr_hugepages=${HUGE_PAGES}" \
            > /etc/sysctl.d/20-nitro-enclaves.conf
    else
        if lsmod | grep -q "^nitro_enclaves"; then
            if ! rmmod nitro_enclaves 2>/dev/null; then
                fatal "nitro_enclaves in use — terminate existing enclaves first: sudo nitro-cli terminate-enclave --all"
            fi
            sleep 0.5
        fi
        sleep 0.3
        # Re-online any CPUs the previous module load took offline.
        # rmmod does not always restore CPU online state; if they're still
        # offline when we modprobe, the driver returns EINVAL.
        for _cpu in $(echo "${CPU_LIST}" | tr ',' ' '); do
            _f="/sys/devices/system/cpu/cpu${_cpu}/online"
            [[ -f "$_f" ]] && echo 1 > "$_f" 2>/dev/null || true
        done
        # Remove stale conf so modprobe doesn't merge old ne_cpus with the new value.
        rm -f /etc/modprobe.d/nitro_enclaves.conf
        if ! modprobe nitro_enclaves ne_cpus="${CPU_LIST}"; then
            dmesg | tail -10 >&2
            fatal "Could not load nitro_enclaves with ne_cpus=${CPU_LIST}"
        fi
        ok "nitro_enclaves loaded with ne_cpus=${CPU_LIST}"

        # 4. Persist across reboots (only when we actually loaded the module;
        #    do NOT overwrite the conf in the "already running" path — the
        #    enclave keeps CPUs offline so lscpu sees a truncated topology,
        #    causing the Python to compute a wrong CPU_LIST including CPU 0).
        echo "options nitro_enclaves ne_cpus=${CPU_LIST}" \
            > /etc/modprobe.d/nitro_enclaves.conf
        echo "vm.nr_hugepages=${HUGE_PAGES}" \
            > /etc/sysctl.d/20-nitro-enclaves.conf
        ok "Pool settings saved (persists across reboots)"
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

# Pre-flight: verify AF_VSOCK bind actually works before launching.
# Without a functional transport, nitro-cli fails at E36 boot heartbeat.
if ! python3 - <<'PYEOF' 2>/dev/null
import socket, sys
s = socket.socket(getattr(socket,'AF_VSOCK',40), socket.SOCK_STREAM)
try:
    s.bind((getattr(socket,'VMADDR_CID_ANY',0xFFFFFFFF), 65432))
    s.close(); sys.exit(0)
except Exception: sys.exit(1)
PYEOF
then
    warn "AF_VSOCK bind pre-flight FAILED — attempting emergency recovery"
    modprobe vhost 2>/dev/null || true
    modprobe vhost_vsock 2>/dev/null || true
    modprobe vmw_vsock_virtio_transport 2>/dev/null || true
    if python3 - <<'PYEOF' 2>/dev/null
import socket, sys
s = socket.socket(getattr(socket,'AF_VSOCK',40), socket.SOCK_STREAM)
try:
    s.bind((getattr(socket,'VMADDR_CID_ANY',0xFFFFFFFF), 65432))
    s.close(); sys.exit(0)
except Exception: sys.exit(1)
PYEOF
    then
        ok "AF_VSOCK bind recovered"
    else
        warn "AF_VSOCK still failing — E36 boot heartbeat will likely fail"
        warn "Devices: $(ls /dev/vhost-vsock /dev/vsock 2>/dev/null | tr '\n' ' '; echo)"
        warn "Consider rebooting the instance to restore vsock state"
    fi
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
    ERRLOG=$(ls -t /var/log/nitro_enclaves/err*.log 2>/dev/null | head -1)
    [[ -n "$ERRLOG" ]] && cat "$ERRLOG"
    fatal "Failed to start enclave — re-run with ENCLAVE_DEBUG=true for console output"
fi
ok "Enclave started: $ENCLAVE_ID"

# ─── 10. vsock-proxy: localhost:3000 → enclave:3000 ─────────────────────────
step "Setting up vsock-proxy bridge (localhost:3000 → CID ${ENCLAVE_CID}:3000)"
apt-get install -y -qq socat

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
step "Health check (waiting up to 30s for enclave to serve /health)"
HEALTH_OK=false
for i in $(seq 1 30); do
    if curl -fsS --max-time 2 http://localhost:3000/health_check >/dev/null 2>&1; then
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
