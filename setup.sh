#!/usr/bin/env bash
# One-shot VRAM HUB validator setup on Ubuntu 24.04 EC2 with Nitro Enclaves.
#
# Usage:
#   curl -sSf https://raw.githubusercontent.com/VRAM-AI/vram-validator/main/setup.sh | bash
#
# What this does:
#   1. Installs the kernel module for Nitro Enclaves
#   2. Downloads nitro-cli (pre-built binary from releases)
#   3. Downloads and runs the nautilus enclave EIF
#   4. Downloads vram-validator binary
#   5. Creates .env from template
#   6. Creates systemd services for enclave + validator

set -euo pipefail

RELEASE_BASE="https://github.com/VRAM-AI/vram-validator/releases/latest/download"
PUBLIC_BASE="https://github.com/VRAM-AI/vram-validator/releases/latest/download"
ENV_TEMPLATE="https://raw.githubusercontent.com/VRAM-AI/vram-validator/main/.env.example"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { printf "${GREEN}[vram-setup]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[vram-setup]${NC} %s\n" "$*"; }
fail() { printf "${RED}[vram-setup]${NC} %s\n" "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] && fail "Run as ubuntu (not root) — script uses sudo internally."

# ── 1. Nitro Enclaves kernel module ──────────────────────────────────────────
log "Checking Nitro Enclave support..."

if [[ ! -e /dev/nitro_enclaves ]]; then
  log "Installing linux-modules-extra-aws..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq linux-modules-extra-aws

  if ! sudo modprobe nitro_enclaves 2>/dev/null; then
    warn "Module load failed — a reboot is needed to pick up new kernel modules."
    warn "After reboot, re-run this script."
    sudo reboot
  fi
fi

[[ -e /dev/nitro_enclaves ]] || fail \
  "/dev/nitro_enclaves not found. Ensure Enclaves Support is Enabled on the EC2 instance
  (EC2 console → Stop → Change Nitro Enclaves → Enable → Start)."

log "Nitro device present: $(ls -l /dev/nitro_enclaves)"

# ── 2. nitro-cli ─────────────────────────────────────────────────────────────
if ! command -v nitro-cli >/dev/null; then
  log "Downloading nitro-cli..."
  sudo curl -fsSL -o /usr/local/bin/nitro-cli \
    "$RELEASE_BASE/nitro-cli-linux-x86_64"
  sudo chmod +x /usr/local/bin/nitro-cli
fi

nitro-cli --version || fail "nitro-cli install failed."

# ── 3. Allocator config ───────────────────────────────────────────────────────
log "Configuring Nitro allocator (4 GiB, 2 vCPUs)..."
sudo mkdir -p /etc/nitro_enclaves
sudo tee /etc/nitro_enclaves/allocator.yaml > /dev/null <<'YAML'
---
memory_mib: 4096
cpu_count: 2
YAML

sudo apt-get install -y -qq docker.io
sudo systemctl enable --now docker
getent group ne >/dev/null || sudo groupadd ne
sudo usermod -aG ne,docker "$USER"

sudo tee /etc/systemd/system/nitro-enclaves-allocator.service > /dev/null <<'UNIT'
[Unit]
Description=Nitro Enclaves Allocator
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/nitro-cli-config -i
ExecStop=/usr/local/bin/nitro-cli-config -r
StandardOutput=journal

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl enable --now nitro-enclaves-allocator.service 2>/dev/null || true

# ── 4. Download EIF ───────────────────────────────────────────────────────────
log "Downloading nautilus enclave EIF..."
sudo mkdir -p /opt/vram
sudo curl -fsSL -o /opt/vram/slcl-nautilus.eif \
  "$RELEASE_BASE/slcl-nautilus.eif"

log "Downloading PCR values..."
sudo curl -fsSL -o /opt/vram/build-output.json \
  "$RELEASE_BASE/build-output.json" 2>/dev/null || true

# ── 5. Enclave systemd service ────────────────────────────────────────────────
log "Creating enclave service..."
sudo tee /etc/systemd/system/vram-enclave.service > /dev/null <<'UNIT'
[Unit]
Description=VRAM Nautilus Enclave
After=nitro-enclaves-allocator.service docker.service
Requires=nitro-enclaves-allocator.service

[Service]
Type=simple
ExecStart=/usr/local/bin/nitro-cli run-enclave \
  --eif-path /opt/vram/slcl-nautilus.eif \
  --memory 4096 \
  --cpu-count 2 \
  --enclave-cid 16
ExecStop=/usr/local/bin/nitro-cli terminate-enclave --enclave-id $(nitro-cli describe-enclaves | grep -o '"EnclaveID": "[^"]*"' | head -1 | cut -d'"' -f4)
Restart=on-failure
RestartSec=10
User=ubuntu

[Install]
WantedBy=multi-user.target
UNIT

# ── 6. vsock-proxy service ────────────────────────────────────────────────────
log "Creating vsock-proxy service..."
sudo tee /etc/systemd/system/vram-vsock-proxy.service > /dev/null <<'UNIT'
[Unit]
Description=VRAM vsock proxy (enclave HTTP bridge)
After=vram-enclave.service
Requires=vram-enclave.service

[Service]
Type=simple
ExecStart=/usr/local/bin/vsock-proxy 3000 127.0.0.1 3000
Restart=on-failure
RestartSec=5
User=ubuntu

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now vram-enclave.service
sudo systemctl enable --now vram-vsock-proxy.service

# ── 7. vram-validator binary ──────────────────────────────────────────────────
log "Downloading vram-validator..."
sudo curl -fsSL -o /usr/local/bin/vram-validator \
  "$PUBLIC_BASE/vram-validator-linux-x86_64"
sudo chmod +x /usr/local/bin/vram-validator

# ── 8. .env setup ─────────────────────────────────────────────────────────────
if [[ ! -f ~/.env ]]; then
  log "Fetching .env template..."
  curl -fsSL -o ~/.env "$ENV_TEMPLATE"
  chmod 600 ~/.env
fi

# Flip to Nitro mode
sed -i 's/^VRAMHUB_TEST_MODE=true/VRAMHUB_TEST_MODE=false/' ~/.env
sed -i 's/^VRAMHUB_NITRO_ENCLAVE=false/VRAMHUB_NITRO_ENCLAVE=true/' ~/.env

# ── 9. Wait for enclave + register ───────────────────────────────────────────
log "Waiting for enclave to start (30s)..."
sleep 30

HEALTH=$(curl -sf http://localhost:3000/health 2>/dev/null || echo "")
if [[ -z "$HEALTH" ]]; then
  warn "Enclave not responding yet. Check: sudo systemctl status vram-enclave"
  warn "Once it's up, run: vram-register"
else
  log "Enclave healthy: $HEALTH"
fi

# ── 10. Install vram-register helper ─────────────────────────────────────────
sudo tee /usr/local/bin/vram-register > /dev/null <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
source ~/.env

PUBKEY=$(curl -sf http://localhost:3000/health | grep -o '"pubkey":"[^"]*"' | cut -d'"' -f4)
[[ -z "$PUBKEY" ]] && { echo "Enclave not responding at localhost:3000"; exit 1; }

echo "Enclave pubkey: $PUBKEY"
echo "Registering on-chain..."

curl -sf -X POST http://localhost:3000/get_attestation | \
  curl -sf -X POST "$VRAMHUB_SUI_RPC_URL" \
    -H "Content-Type: application/json" \
    -d @- 2>/dev/null || true

echo ""
echo "Run this to register the enclave on-chain (requires vramhub-cli):"
echo "  cargo run --bin slcl-cli -- register-enclave --enclave-url http://localhost:3000 --validator-uid \$VRAMHUB_VALIDATOR_UID"
SCRIPT
sudo chmod +x /usr/local/bin/vram-register

# ── Done ──────────────────────────────────────────────────────────────────────
cat <<DONE

${GREEN}Setup complete!${NC}

Services running:
  sudo systemctl status vram-enclave
  sudo systemctl status vram-vsock-proxy

Next steps:
  1. Fill in your mnemonic and R2 credentials in ~/.env
  2. Register enclave on-chain:   vram-register
  3. Add UID to .env:             echo 'VRAMHUB_VALIDATOR_UID=<uid>' >> ~/.env
  4. Run validator:               source ~/.env && vram-validator

Logs:
  sudo journalctl -u vram-enclave -f
  sudo journalctl -u vram-vsock-proxy -f
DONE
