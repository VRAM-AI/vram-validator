#!/usr/bin/env bash
# VRAM Validator — one-line installer
#
# Installs: vram-validator, vram-nautilus, vram-cli
#
# Usage:
#   curl -sSf https://raw.githubusercontent.com/VRAM-AI/vram-validator/main/install.sh | bash

set -euo pipefail

REPO="VRAM-AI/vram-validator"
INSTALL_DIR="/usr/local/bin"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[vram]${NC} $*"; }
warn()  { echo -e "${YELLOW}[vram]${NC} $*"; }
error() { echo -e "${RED}[vram]${NC} $*" >&2; exit 1; }

[[ "$(uname -s)" == "Linux" ]] || error "vram-validator only runs on Linux."

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
install_bin "vram-cli-linux-${ARCH_SUFFIX}"        "vram-cli"

echo ""
echo -e "${GREEN}✓ vram-validator + vram-nautilus + vram-cli ${TAG} installed${NC}"
echo ""
echo "  Binaries:"
echo "    /usr/local/bin/vram-validator  — validator daemon"
echo "    /usr/local/bin/vram-nautilus   — enclave scoring server"
echo "    /usr/local/bin/vram-cli        — CLI tools"
echo ""
echo "  Quick start:"
echo "    SLCL_TEST_MODE=true vram-nautilus &"
echo "    source ~/.env && vram-validator"
echo ""
echo "  Docs: https://github.com/${REPO}#readme"
