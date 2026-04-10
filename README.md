# vram-validator

Run a VRAM HUB validator and earn VRAM rewards for evaluating miner gradients on Sui testnet.

## Quick Install

```bash
curl -sSf https://raw.githubusercontent.com/VRAM-AI/vram-validator/main/install.sh | bash
```

Requires Linux. Tested on Ubuntu 22.04 and Amazon Linux 2023.

## Requirements

| | |
|---|---|
| OS | Linux (Ubuntu 22.04+ / Amazon Linux 2023) |
| Instance | AWS EC2 with Nitro Enclave enabled (`m7i.xlarge` or larger) |
| RAM | 8 GB minimum (4 GB allocated to enclave) |
| Stake | 10 SUI on testnet |
| Cloudflare R2 | Free tier bucket for gradient storage |

## Setup

**1. Install**
```bash
curl -sSf https://raw.githubusercontent.com/VRAM-AI/vram-validator/main/install.sh | bash
```

**2. Configure**
```bash
curl -o .env https://raw.githubusercontent.com/VRAM-AI/vram-validator/main/.env.example
nano .env   # set VRAMHUB_WALLET_MNEMONIC + R2 credentials
```

**3. Get testnet SUI**

Visit [faucet.sui.io](https://faucet.sui.io) and paste your wallet address.

**4. Run**
```bash
source .env
vram-validator
```

On first run, the validator auto-registers on-chain and prints your UID:
```
INFO vramhub_validator: Registered as validator uid=3
```

Set `VRAMHUB_VALIDATOR_UID=3` in your `.env` and restart.

## Nitro Enclave (required for production scoring)

The validator needs a running Nautilus enclave to submit verified scores.

```bash
# Install the enclave on the same EC2 instance
curl -sSf https://raw.githubusercontent.com/VRAM-AI/vram-validator/main/install.sh | bash -s -- --enclave

# Register on-chain (one-time)
vram-validator register-enclave --enclave-url http://localhost:3000
```

## Rewards

Validators earn a fee from miner stake. Every 10-minute window:
- Download miner gradients from Cloudflare R2
- Send to Nautilus enclave for loss evaluation
- Submit Ed25519-signed scores to `score_ledger.move` on Sui
- `reward_distributor.move` emits 1,200 VRAM to top miners

Explorer: [suiscan.xyz/testnet](https://suiscan.xyz/testnet/object/0x48703e08da129342d7943193c9b9ea17e588b471fe21b13870f16ebc82db0aa8)
Dashboard: [vram.ai](https://vram.ai)

## Links

- [vram.ai](https://vram.ai) — main site
- [VRAMScan](https://vram.ai/scan) — block explorer
- [Full docs](https://docs.vram.ai/validators/setup)
- [VRAM HUB](https://github.com/VRAM-AI/VRAM-HUB) — open source coordination layer
