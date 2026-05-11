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

**Instance type:** Choose from the table below. The enclave needs at least 2 dedicated vCPUs and 4 GB of RAM reserved for it, so the host must have at least 4 vCPUs and 8 GB total.

| Instance | vCPUs | RAM | Notes |
|---|---|---|---|
| `m5.xlarge` | 4 | 16 GB | ✅ Recommended — best price/performance |
| `m5.2xlarge` | 8 | 32 GB | ✅ If you need more headroom |
| `m7i.xlarge` | 4 | 16 GB | ✅ Latest gen, slightly faster |
| `c5.xlarge` | 4 | 8 GB | ✅ Works — tight on memory |
| `c5.2xlarge` | 8 | 16 GB | ✅ Comfortable |
| `r5.xlarge` | 4 | 32 GB | ✅ If memory-heavy workloads |
| `t3.*` / `t2.*` | any | any | ❌ **Not supported** — T-family instances have no Nitro Enclave support |
| `t3a.*` / `t4g.*` | any | any | ❌ **Not supported** |
| `m6g.*` / `c7g.*` (ARM) | any | any | ❌ **Not supported** — Nitro Enclaves require x86_64 |

> **Tip:** When in doubt, use `m5.xlarge`. It is the most widely tested instance type for Nitro Enclaves.

**Key pair:** Create a new key pair, download the `.pem` file, keep it safe.

**Security group:**
- SSH (port 22) — set source to **My IP only** (not 0.0.0.0/0)
- Remove HTTP and HTTPS inbound rules (not needed)

**Storage:**
- Size: **50 GiB**
- Type: `gp3`
- Encrypted: **Yes** — select your KMS key if you have one

**Advanced details — critical settings:**

> ⚠️ **Nitro Enclave support cannot be enabled after launch.** You must check the box before clicking "Launch Instance". There is no way to add it to a running instance — you would need to terminate and relaunch.

- **Nitro Enclave: Enable** ← scroll down in Advanced details, it is a single checkbox
- IAM instance profile: attach a role with `secretsmanager:GetSecretValue` if you plan to use AWS Secrets Manager for your wallet mnemonic (recommended)

Launch the instance.

### How to confirm Nitro Enclaves is enabled

After SSHing into the instance:

```bash
nitro-cli describe-enclaves
# Expected output: [] (empty list — no enclaves running yet, but CLI works)
```

If you see `bash: nitro-cli: command not found` or `Failed to connect to NE socket`, the instance was launched **without** Nitro Enclave support. Terminate it and relaunch with the checkbox checked.

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

1. Get your wallet address:
   ```bash
   sui client active-address
   ```
2. Visit [faucet.sui.io](https://faucet.sui.io) and paste your address
3. Confirm you received SUI:
   ```bash
   sui client balance
   ```

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

The Nitro Enclave is required to submit verified scores. The enclave runs the `slcl-nautilus` binary inside the sealed hardware environment and signs every score with a key that never leaves it.

### Debug mode vs production mode

The enclave can run in two modes — **use production mode for everything except local development**:

| | Debug mode | Production mode |
|---|---|---|
| How to start | `--debug-console` flag | No extra flag |
| PCR values | All zeros in attestation | Real SHA-384 measurements |
| On-chain registration | **Will be rejected** — zeros fail PCR check | ✅ Accepted |
| Enclave console | Readable via `nitro-cli console` | Not accessible |
| Use for | Diagnosing crashes during setup | Everything else |

To check which mode your enclave is running:
```bash
nitro-cli describe-enclaves | python3 -m json.tool
# "Flags": "NONE"        → production mode ✅
# "Flags": "DEBUG_MODE"  → debug mode — registration will be rejected
```

### Start the enclave

```bash
# Install nitro-cli, download the enclave EIF, create systemd services
curl -sSf https://raw.githubusercontent.com/VRAM-AI/VRAM-HUB/master/scripts/enclave-setup.sh | bash
```

The script starts the enclave in **production mode** and creates:
- `slcl-nautilus.service` — runs the enclave
- `vram-vsock-bridge.service` — socat bridge (TCP 3000 → vsock CID 16:3000)

Verify it started correctly:
```bash
nitro-cli describe-enclaves   # Flags must be "NONE"
curl http://localhost:3000/health_check   # must return: ok
```

### Register on-chain (one-time per enclave)

```bash
source ~/.env
vram-cli register-validator   # prints VRAMHUB_VALIDATOR_UID=N
echo 'VRAMHUB_VALIDATOR_UID=N' >> ~/.env   # replace N
source ~/.env

vram-cli register-enclave \
  --enclave-url http://localhost:3000 \
  --validator-uid $VRAMHUB_VALIDATOR_UID
```

After success:
```
Enclave registered successfully.
VRAMHUB_ENCLAVE_PUBKEY=42c3adc8...
```

Add to `.env`:
```bash
VRAMHUB_ENCLAVE_PUBKEY=42c3adc8...
VRAMHUB_ENCLAVE_URL=http://localhost:3000
VRAMHUB_TEST_MODE=false
```

> **Note:** You must re-run `register-enclave` any time the enclave EIF is rebuilt (PCR values change when code changes). The validator UID stays the same — only the enclave registration needs to be re-done.

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

**`~/.env` is a directory instead of a file**
If `vi .env` opens a directory listing, a `.env` folder was accidentally created. Remove it and create the file:
```bash
rm -rf ~/.env
vi ~/.env
```

**Enclave pubkey split across two lines in `.env`**
Pasting a long value in a terminal can wrap mid-line, breaking `source ~/.env` with errors like `-bash: e1f68: command not found`. Fix:
```bash
# Remove all broken ENCLAVE_PUBKEY lines
sed -i '/^VRAMHUB_ENCLAVE_PUBKEY/d; /^SLCL_ENCLAVE_PUBKEY/d; /^  e1f68$/d' ~/.env
# Append correct values on one line each
echo 'VRAMHUB_ENCLAVE_PUBKEY=<your-pubkey>' >> ~/.env
echo 'SLCL_ENCLAVE_PUBKEY=<your-pubkey>' >> ~/.env
source ~/.env && echo "OK"
```

**PCR mismatch after replacing or re-imaging the EC2 instance**
PCR0 and PCR2 are derived from the enclave binary. If you move to a new instance and rebuild the EIF (or download a new version), the PCR values change. The on-chain `EnclaveRegistry` must be updated by the admin before `register-enclave` will succeed:
```bash
# Check current production PCRs
nitro-cli describe-enclaves | python3 -m json.tool
# "Flags" must be "NONE" (production mode) — debug-mode PCRs are zeros and will be rejected
```
Contact the team on Discord with your PCR0/1/2 values to have the allowlist updated.

**Enclave starts in `DEBUG_MODE` — `register-enclave` fails**
Stop the debug enclave and restart without `--debug-console`:
```bash
sudo nitro-cli terminate-enclave --enclave-id $(nitro-cli describe-enclaves | python3 -c "import sys,json; e=json.load(sys.stdin); print(e[0]['EnclaveID'] if e else '')")
sudo nitro-cli run-enclave \
  --eif-path /opt/vram/slcl-nautilus.eif \
  --memory 4096 \
  --cpu-count 2 \
  --enclave-cid 16
nitro-cli describe-enclaves   # Flags must be "NONE"
```

**`localhost:3000` connection refused — vsock bridge not running**
The socat bridge forwards TCP port 3000 to the enclave's vsock socket. If it's not running:
```bash
sudo ss -tlnp | grep 3000   # check if anything is listening
sudo socat TCP-LISTEN:3000,reuseaddr,fork VSOCK-CONNECT:16:3000 &
curl http://localhost:3000/health_check   # should return: ok
```
For a persistent bridge (survives reboots), the full `setup.sh` installs a `slcl-vsock-bridge.service` systemd unit automatically.

**E36 / `No CPUs available in CPU pool` — enclave fails to start on AL2023**
AL2023 boots secondary CPUs offline; the Nitro driver can't pool them until they're online. `setup.sh` installs a `nitro-cpu-fix.service` that fixes this at boot, but it only takes effect after a reboot:
```bash
sudo reboot
# After ~60s, verify:
nitro-cli describe-enclaves   # Flags: NONE
curl http://localhost:3000/health_check   # ok
```

**"compile_error: must be built on Linux"**
The validator only runs on Linux. Use an EC2 instance, not your local machine.

**"Nitro Enclave not available" or `nitro-cli: command not found`**
Your instance was launched without Nitro Enclave support enabled. This cannot be fixed on a running instance — terminate it and relaunch with **Nitro Enclave: Enable** checked in Advanced details. See the instance type table above; `t3`, `t4g`, and ARM instances do not support Nitro.

**"MissingEnvVar: VRAMHUB_WALLET_MNEMONIC"**
Your `.env` file isn't loaded. Run `source .env` before `vram-validator`, or use the systemd service which loads it automatically.

**Enclave shows `Flags: DEBUG_MODE` instead of `NONE`**
The enclave was started with `--debug-console`. Stop it and restart without that flag:
```bash
sudo nitro-cli terminate-enclave --enclave-name slcl-nautilus
sudo nitro-cli run-enclave \
  --eif-path /opt/vram/slcl-nautilus.eif \
  --memory 4096 \
  --cpu-count 2 \
  --enclave-cid 16
nitro-cli describe-enclaves   # confirm Flags: NONE
```

**`ArityMismatch in command 0` during register-validator**
The CLI binary is out of date. Pull the latest and rebuild:
```bash
cd ~/vramhub-validator && git pull
cargo build --release -p slcl-cli
sudo cp target/release/slcl-cli /usr/local/bin/vram-cli
```

**`InsufficientStake` during register-validator**
The contract requires 10 SUI stake minimum. Make sure you have SUI in your wallet (`sui client balance`) and the latest `vram-cli` binary which passes the correct stake.

**`E_ALREADY_REGISTERED` during register-validator**
Your address is already registered. Query your existing UID:
```bash
vram-cli status
```

**Health check returns empty / connection refused**
The vsock bridge is not running. Start it:
```bash
sudo systemctl start vram-vsock-bridge
sudo systemctl status vram-vsock-bridge
curl http://localhost:3000/health_check   # should return: ok
```
If the bridge is running but curl still fails, the enclave may have crashed. Check:
```bash
nitro-cli describe-enclaves   # confirm State: RUNNING
sudo journalctl -u slcl-nautilus -n 50 --no-pager
```

**Scores not submitting**
Check that the enclave is running and in production mode:
```bash
nitro-cli describe-enclaves   # State: RUNNING, Flags: NONE
curl http://localhost:3000/health_check   # ok
curl http://localhost:3000/get_attestation | python3 -m json.tool | grep test_mode
# must show: "test_mode": false
```
If `test_mode` is true, set `VRAMHUB_TEST_MODE=false` in `.env` and restart the validator.

---

## Links

- [vram.ai](https://vram.ai) — main site and dashboard
- [VRAMScan](https://vram.ai/scan) — live network explorer
- [VRAM HUB](https://github.com/VRAM-AI/VRAM-HUB) — open source protocol
- [Full validator docs](https://docs.vram.ai/validators/setup)
- [Discord](https://discord.gg/vram) — get help, find other validators
- team@vram.ai
