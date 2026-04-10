# vram-validator

Earn VRAM rewards by running a validator on the VRAM HUB network. Validators download miner gradients, evaluate them inside a secure hardware enclave, and submit verified scores on the Sui blockchain — every 10 minutes, automatically.

> Backed by a $10M token facility from GEM Digital. Testnet is live.

---

## What is a validator?

Miners on VRAM HUB train AI models and upload their gradient updates. Validators are the referees — they check the work, score each miner's contribution, and submit those scores on-chain. The blockchain then distributes VRAM rewards proportional to each miner's score.

To prevent validators from cheating or colluding, scoring runs inside an **AWS Nitro Enclave** — a locked hardware environment where even the server operator cannot see or tamper with the computation. The result is a cryptographic signature that the blockchain verifies. No trust required.

---

## What is AWS Nitro?

AWS Nitro Enclaves are isolated virtual machines that run inside an EC2 instance, completely cut off from the rest of the server — no network access, no persistent storage, no way for the operator to peek inside. The enclave runs our `vram-validator` scoring code, generates an Ed25519 signing key that never leaves the hardware, and signs every score it produces.

When you register as a validator, your enclave's cryptographic fingerprint (called PCR values) is recorded on-chain. If anyone tries to run a modified scoring binary, the fingerprint changes and the blockchain rejects it. This is how VRAM HUB guarantees honest scoring without a trusted coordinator.

Think of it like a sealed black box that the network trusts — not because they trust you, but because the hardware itself is tamper-evident.

---

## Requirements

| | |
|---|---|
| AWS account | Any account — free tier is not enough (see instance type below) |
| EC2 instance | `m7i.xlarge` or larger — must support Nitro Enclaves |
| RAM | 16 GB (4 GB reserved for enclave) |
| Storage | 50 GB encrypted EBS volume |
| OS | Amazon Linux 2023 or Ubuntu 22.04 |
| Sui wallet | 10 SUI minimum stake on testnet |
| Cloudflare R2 | Free tier bucket for gradient downloads |

---

## Step 1 — Launch your EC2 server

Go to the [AWS EC2 console](https://console.aws.amazon.com/ec2/v2/home#LaunchInstances) and configure:

**Name:** `vram-validator`

**AMI:** Amazon Linux 2023 (recommended — has native Nitro support)

**Instance type:** `m7i.xlarge`
> Do not use `t3` or free tier instances — they do not support Nitro Enclaves.

**Key pair:** Create a new key pair, download the `.pem` file, keep it safe.

**Security group:**
- SSH (port 22) — set source to **My IP only** (not 0.0.0.0/0)
- Remove HTTP and HTTPS inbound rules (not needed)

**Storage:**
- Size: **50 GiB**
- Type: `gp3`
- Encrypted: **Yes** — select your KMS key if you have one

**Advanced details:**
- Nitro Enclave: **Enable** ← this is the critical one
- IAM instance profile: attach a role with `secretsmanager:GetSecretValue` if you plan to use AWS Secrets Manager for your wallet mnemonic (recommended)

Launch the instance.

---

## Step 2 — Connect to your server

Once the instance is running, connect via SSH:

```bash
chmod 400 your-key.pem
ssh -i your-key.pem ec2-user@<your-ec2-public-ip>
```

---

## Step 3 — Install the validator

Run this on your EC2 instance:

```bash
curl -sSf https://raw.githubusercontent.com/VRAM-AI/vram-validator/main/install.sh | bash
```

This downloads the latest pre-built binary and places it in `/usr/local/bin/vram-validator`.

---

## Step 4 — Configure

```bash
curl -o .env https://raw.githubusercontent.com/VRAM-AI/vram-validator/main/.env.example
nano .env
```

The only fields you must fill in:

```bash
# Your Sui wallet — 12 words, keep this secret
VRAMHUB_WALLET_MNEMONIC=word1 word2 word3 ... word12

# Cloudflare R2 — create a free bucket at dash.cloudflare.com
VRAMHUB_R2_ACCOUNT_ID=your-cloudflare-account-id
VRAMHUB_R2_BUCKET_NAME=vram-validator-gradients
VRAMHUB_R2_ACCESS_KEY_ID=your-r2-key-id
VRAMHUB_R2_SECRET_ACCESS_KEY=your-r2-secret
```

Everything else (all testnet contract IDs) is pre-filled.

> **Security tip:** Instead of putting your mnemonic in `.env`, store it in AWS Secrets Manager:
> ```bash
> aws secretsmanager create-secret \
>   --name vramhub/validator/mnemonic \
>   --secret-string "your twelve words here" \
>   --region ap-southeast-2
> ```
> The validator will fetch it automatically at startup if the IAM role has access.

---

## Step 5 — Get testnet SUI

You need 10 SUI to stake as a validator.

1. Get your wallet address: `vram-validator wallet-address`
2. Visit [faucet.sui.io](https://faucet.sui.io) and paste your address
3. Confirm you received SUI: `vram-validator balance`

---

## Step 6 — Run

```bash
source .env
vram-validator
```

On first run, it auto-registers on-chain and prints your assigned UID:

```
INFO vramhub_validator: Registered as validator uid=3
INFO vramhub_validator: Validator starting uid=3
INFO vramhub_validator: Starting window window=2957300
INFO vramhub_validator: Decrypting credentials for 12 miners
INFO vramhub_validator: Submitting 12 scores to chain window=2957300
```

Add your UID to `.env`:
```bash
VRAMHUB_VALIDATOR_UID=3
```

Restart the validator. It will now run continuously, scoring every 10-minute window automatically.

---

## Step 7 — Run as a background service (recommended)

So the validator keeps running after you close SSH:

```bash
sudo tee /etc/systemd/system/vram-validator.service > /dev/null << EOF
[Unit]
Description=VRAM Validator
After=network.target

[Service]
EnvironmentFile=/home/ec2-user/.env
ExecStart=/usr/local/bin/vram-validator
Restart=on-failure
RestartSec=10
User=ec2-user

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable --now vram-validator
sudo journalctl -u vram-validator -f   # watch logs
```

---

## Nitro Enclave setup

The Nitro Enclave is required to submit verified scores on mainnet. On testnet it runs in a compatibility mode — but to be production-ready, set it up now:

```bash
# Install and start the enclave (installs nitro-cli, downloads EIF, creates systemd service)
curl -sSf https://raw.githubusercontent.com/VRAM-AI/vram-validator/main/install-enclave.sh | bash

# Register the enclave on-chain (one-time — or after every restart)
vram-validator register-enclave --enclave-url http://localhost:3000
```

After registration you'll see:
```
INFO: Enclave registered successfully pubkey=a3f9...
```

Add to `.env`:
```bash
VRAMHUB_NITRO_ENCLAVE=true
VRAMHUB_ENCLAVE_PUBKEY=a3f9...   # from the line above
VRAMHUB_ENCLAVE_OBJECT_ID=0x...  # printed after register-enclave
```

---

## How rewards work

Every 10-minute window the network runs automatically:

1. **Miners** train on assigned data and upload compressed gradients to Cloudflare R2
2. **Your validator** downloads each gradient and sends it to the Nautilus enclave
3. **The enclave** computes how much each gradient improved the model, signs the result
4. **You submit** the signed scores to `score_ledger.move` on Sui
5. **`reward_distributor.move`** emits **1,200 VRAM** every window, split between miners by score

Validators earn a fee from miner stake slashing — separate from the miner emission, so your rewards don't compete with miners.

Current testnet: [VRAMScan Explorer](https://suiscan.xyz/testnet/object/0x48703e08da129342d7943193c9b9ea17e588b471fe21b13870f16ebc82db0aa8)

---

## Troubleshooting

**"compile_error: must be built on Linux"**
The validator only runs on Linux. Use an EC2 instance, not your local machine.

**"Nitro Enclave not available"**
Your instance type doesn't support Nitro. Launch an `m7i.xlarge`, `c5.xlarge`, or any `m5`/`c5`/`r5` instance. `t3` instances do not support Nitro.

**"MissingEnvVar: VRAMHUB_WALLET_MNEMONIC"**
Your `.env` file isn't loaded. Run `source .env` before `vram-validator`, or use the systemd service which loads it automatically.

**Scores not submitting**
Check that the enclave is running: `curl http://localhost:3000/health_check`
If it returns nothing, restart the enclave service: `sudo systemctl restart slcl-nautilus`

---

## Links

- [vram.ai](https://vram.ai) — main site and dashboard
- [VRAMScan](https://vram.ai/scan) — live network explorer
- [VRAM HUB](https://github.com/VRAM-AI/VRAM-HUB) — open source protocol
- [Full validator docs](https://docs.vram.ai/validators/setup)
- [Discord](https://discord.gg/vram) — get help, find other validators
- team@vram.ai
