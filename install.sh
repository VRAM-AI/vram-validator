#!/usr/bin/env bash
# VRAM Validator — one-line installer
#
# Usage:
#   curl -sSf https://raw.githubusercontent.com/VRAM-AI/vram-validator/main/install.sh | bash

set -euo pipefail

REPO="VRAM-AI/vram-validator"
BIN_NAME="vram-validator"
INSTALL_PATH="/usr/local/bin/${BIN_NAME}"
ASSET_NAME="vram-validator-linux-x86_64"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[vram]${NC} $*"; }
warn()  { echo -e "${YELLOW}[vram]${NC} $*"; }
error() { echo -e "${RED}[vram]${NC} $*" >&2; exit 1; }

[[ "$(uname -s)" == "Linux" ]] || error "vram-validator only runs on Linux (AWS EC2 with Nitro Enclave)."

info "Fetching latest release..."
TAG=$(curl -sf "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
[[ -n "$TAG" ]] || error "Could not fetch latest release. Check https://github.com/${REPO}/releases"
info "Installing ${TAG}..."

URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET_NAME}"
curl -L --progress-bar -o "/tmp/${BIN_NAME}" "$URL"
chmod +x "/tmp/${BIN_NAME}"

if [[ $EUID -eq 0 ]] || [[ -w "/usr/local/bin" ]]; then
  mv "/tmp/${BIN_NAME}" "${INSTALL_PATH}"
else
  sudo mv "/tmp/${BIN_NAME}" "${INSTALL_PATH}"
fi

echo ""
echo -e "${GREEN}✓ vram-validator ${TAG} installed${NC}"
echo ""
echo "  Next steps:"
echo "  1. Copy and fill in your config:"
echo "     curl -o .env https://raw.githubusercontent.com/${REPO}/main/.env.example"
echo "     \$EDITOR .env   # set VRAMHUB_WALLET_MNEMONIC"
echo ""
echo "  2. Run:"
echo "     vram-validator"
echo ""
echo "  Docs: https://github.com/${REPO}#readme"
