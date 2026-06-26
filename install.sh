#!/usr/bin/env bash
# VRAM — one-line installer
#
# Installs: vram-validator, vram-nautilus, vram-miner, vram-cli
# Creates:  /etc/systemd/system/vram-validator.service (if systemd present)
# Creates:  /etc/systemd/system/vram-miner.service     (if systemd present)
# Creates:  ~/.env from template if not already present
#
# Usage:
#   curl -sSf https://raw.githubusercontent.com/VRAM-AI/vram-validator/main/install.sh | bash

set -euo pipefail

REPO="VRAM-AI/vram-validator"
INSTALL_DIR="/usr/local/bin"
ENV_FILE="$HOME/.env"
VALIDATOR_SERVICE="/etc/systemd/system/vram-validator.service"
MINER_SERVICE="/etc/systemd/system/vram-miner.service"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[vram]${NC} $*"; }
warn()  { echo -e "${YELLOW}[vram]${NC} $*"; }
error() { echo -e "${RED}[vram]${NC} $*" >&2; exit 1; }

[[ "$(uname -s)" == "Linux" ]] || error "vram only runs on Linux."

install_bin() {
    local asset="$1" dest="$2"
    local url="https://github.com/${REPO}/releases/download/${TAG}/${asset}"
    info "Downloading ${asset}..."
    curl -L --progress-bar -o "/tmp/${dest}" "$url"
    chmod +x "/tmp/${dest}"
    if [[ $EUID -eq 0 ]] || [[ -w "${INSTALL_DIR}" ]]; then
        mv "/tmp/${dest}" "${INSTALL_DIR}/${dest}"
    else
        sudo mv "/tmp/${dest}" "${INSTALL_DIR}/${dest}"
    fi
    info "Installed ${dest} → ${INSTALL_DIR}/${dest}"
}

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)        ARCH_SUFFIX="x86_64" ;;
  aarch64|arm64) ARCH_SUFFIX="aarch64" ;;
  *)             error "Unsupported architecture: ${ARCH}" ;;
esac

info "Fetching latest release..."
TAG=$(curl -sf "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
[[ -n "$TAG" ]] || error "Could not fetch latest release. Check https://github.com/${REPO}/releases"
info "Installing ${TAG} (${ARCH_SUFFIX})..."

install_bin "vram-validator-linux-${ARCH_SUFFIX}"  "vram-validator"
install_bin "slcl-nautilus-linux-${ARCH_SUFFIX}"   "vram-nautilus"
install_bin "vram-miner-linux-${ARCH_SUFFIX}"      "vram-miner"
install_bin "vram-cli-linux-${ARCH_SUFFIX}"        "vram-cli"

# ── ~/.env template ────────────────────────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
    info "Creating ${ENV_FILE} from template..."
    cat > "$ENV_FILE" << 'ENVEOF'
# VRAM — fill in VRAMHUB_WALLET_MNEMONIC then run the relevant register command
VRAMHUB_WALLET_MNEMONIC=word1 word2 word3 word4 word5 word6 word7 word8 word9 word10 word11 word12
VRAMHUB_SUI_RPC_URL=https://fullnode.testnet.sui.io:443
VRAMHUB_PACKAGE_ID=0xb7b988ccc15e3d384143fc1d3bf950a20fa85966cd032453c6b2fd2b85d7747f
VRAMHUB_PEER_REGISTRY_ID=0x8595c6fe73834bff68e2b0e5bf0edd87a9c4eecedf459eb7ab94a018bf2ea9c2
VRAMHUB_VALIDATOR_REGISTRY_ID=0xf1a95dde69a5c63197f49d61ecfe2d2ec7a1b3fab8402fd48d5a67978a3090e2
VRAMHUB_ENCLAVE_REGISTRY_ID=0x4f7761e6086cd15667b3f63d3339b7c309825542f5f0a96325f950b65a57e7ad
VRAMHUB_SCORE_LEDGER_ID=0xc6d77a40094182701abc3333cf0706f5906f267d8f354f57cc35d5ca902c3abb
VRAMHUB_ROUND_STATE_ID=0x1986381a30c700f712a2aec0cf1526a6262462d52d39613d7bfbc0e9b07219f6
VRAMHUB_HPARAMS_ID=0x9fe8836e53a365aaa98af325ad348bf7e01eb05c1bb79d56204f487891ef84e8
VRAMHUB_REWARD_POOL_ID=0x88ea70ad39a62cbb59b2556e4c349903aa3a0bfc8b737b21dff030f5e6f9ccf2
VRAMHUB_TRAINING_JOB_BOARD_ID=0xe9e4dad2f05487c21c27823f1107e94c8799fd6759b3f1aef30d3ed69e144188
VRAMHUB_GRADIENT_REGISTRY_ID=0x1ed628e71a2f062b5b9089f3c4c2aae1e5c84dc247e34cee90ea3683b84d14b3
VRAMHUB_STORAGE_BACKEND=walrus
VRAMHUB_DEMO_MODE=true
VRAMHUB_SKIP_SEAL=true
VRAMHUB_SEAL_KEY_SERVER_IDS=0x73d05d62c18d9374e3ea529e8e0ed6161da1a141a94d3f76ae3fe4e99356db75,0xf5d14a81a982144ae441cd7d64b09027f116a468bd36e7eca494f750591623c8
VRAMHUB_SEAL_THRESHOLD=2
RUST_LOG=info

# ── Validator (set after: source ~/.env && vram-cli register-validator) ────────
VRAMHUB_SIMULATED=true
VRAMHUB_ENCLAVE_URL=http://localhost:3000
VRAMHUB_VALIDATOR_UID=

# ── Miner (set after: source ~/.env && vram-cli register-miner) ───────────────
# NOTE: miner wallet must be different from validator wallet (one registration per address)
VRAMHUB_MINER_UID=
ENVEOF
    chmod 600 "$ENV_FILE"
    warn "~/.env created — edit it and set VRAMHUB_WALLET_MNEMONIC before starting."
else
    info "~/.env already exists — skipping template."
fi

# ── systemd services ───────────────────────────────────────────────────────────
if command -v systemctl &>/dev/null; then
    SUDO=""
    [[ $EUID -ne 0 ]] && SUDO="sudo"

    info "Installing systemd service: vram-validator..."
    $SUDO tee "${VALIDATOR_SERVICE}" > /dev/null << SVCEOF
[Unit]
Description=VRAM Validator
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${USER}
EnvironmentFile=${ENV_FILE}
ExecStart=${INSTALL_DIR}/vram-validator
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=vram-validator

[Install]
WantedBy=multi-user.target
SVCEOF

    info "Installing systemd service: vram-miner..."
    $SUDO tee "${MINER_SERVICE}" > /dev/null << SVCEOF
[Unit]
Description=VRAM Miner
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${USER}
EnvironmentFile=${ENV_FILE}
ExecStart=${INSTALL_DIR}/vram-miner
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=vram-miner

[Install]
WantedBy=multi-user.target
SVCEOF

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable vram-validator
    info "Services installed and enabled (validator auto-enabled; start miner manually after registering)."
else
    warn "systemd not found — skipping service install."
fi

echo ""
echo -e "${GREEN}✓ vram-validator + vram-nautilus + vram-miner + vram-cli ${TAG} installed${NC}"
echo ""
echo "  Binaries:"
echo "    /usr/local/bin/vram-validator  — validator daemon"
echo "    /usr/local/bin/vram-nautilus   — enclave scoring server"
echo "    /usr/local/bin/vram-miner      — miner daemon"
echo "    /usr/local/bin/vram-cli        — CLI tools"
echo ""
echo "  Validator quick start:"
echo "    1. Edit ~/.env — set VRAMHUB_WALLET_MNEMONIC"
echo "    2. source ~/.env && vram-cli register-validator"
echo "    3. Set VRAMHUB_VALIDATOR_UID=<uid> in ~/.env"
echo "    4. sudo systemctl start vram-validator"
echo "    5. sudo journalctl -u vram-validator -f"
echo ""
echo "  Miner quick start (requires a DIFFERENT wallet from validator):"
echo "    1. Edit ~/.env — set VRAMHUB_WALLET_MNEMONIC to miner wallet mnemonic"
echo "    2. source ~/.env && vram-cli register-miner"
echo "    3. Set VRAMHUB_MINER_UID=<uid> in ~/.env"
echo "    4. sudo systemctl start vram-miner"
echo "    5. sudo journalctl -u vram-miner -f"
echo ""
echo "  Docs: https://github.com/${REPO}#readme"
