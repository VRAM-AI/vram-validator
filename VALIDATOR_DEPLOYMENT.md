# VRAM Validator — Deployment Runbook

End-to-end deployment of a VRAM HUB validator with Nitro Enclave attestation on AWS EC2. This runbook captures the exact sequence verified to work on testnet, including the AWS Nitro driver workaround discovered with AWS Premium Support.

---

## Prerequisites

- AWS account with Business Support tier or higher (for AWS Nitro support escalation if needed)
- EC2 instance with Nitro Enclaves enabled at launch (cannot be added later)
- Sui testnet wallet with at least 11 SUI (10 for validator stake plus gas)
- Validator UID assigned by admin (or registered via `vram-cli register-validator`)
- Enclave PCR values added to `EnclaveRegistry.expected_pcr0/1/2` by admin

## Instance configuration

| Setting | Value |
|---------|-------|
| Instance type | `c5.2xlarge` or `m5.2xlarge` (8 vCPU, 16 to 32 GiB RAM) |
| AMI | Amazon Linux 2023 (kernel 6.1) `ami-0eb38b817b93460ac` |
| Storage | 50 GiB gp3, encrypted |
| Enclaves Support | **Enabled at launch** (Advanced details checkbox) |
| Security group | SSH from your IP only |

---

## Step 1: Initial setup

SSH into the freshly launched instance, then run the one-shot installer:

```bash
sudo curl -fsSL https://raw.githubusercontent.com/VRAM-AI/vram-validator/main/setup.sh | sudo bash
```

This installs `nitro-cli`, configures the enclave CPU pool, builds the `slcl-nautilus.eif` enclave image, and attempts to launch it.

## Step 2: If the enclave fails to start, reboot once

On a freshly launched AL2023 instance, the `nitro_enclaves` kernel driver often initializes with allocated CPUs in an offline state, producing this error:

```
[ E36 ] Enclave boot failure.
nitro_enclaves: No CPUs available in CPU pool
nitro_enclaves: Error in setup CPU pool [rc=-22]
```

This is a known AWS issue confirmed by AWS Premium Support. The fix is a single reboot:

```bash
sudo reboot
```

Wait 60 to 90 seconds, then SSH back in. The instance's public IP may have changed if no Elastic IP is attached.

## Step 3: Launch the enclave manually (do NOT re-run setup.sh)

After the reboot, the kernel state is clean. Launch the enclave directly without re-running the setup script. The setup script re-triggers the broken driver state.

```bash
sudo nitro-cli run-enclave \
  --eif-path /opt/vram/slcl-nautilus.eif \
  --cpu-ids 1 5 \
  --memory 4096 \
  --enclave-cid 16

nitro-cli describe-enclaves
```

Confirm output shows:

```json
"State": "RUNNING",
"Flags": "NONE",
"Measurements": {
  "PCR0": "<64 hex chars>",
  "PCR1": "<64 hex chars>",
  "PCR2": "<64 hex chars>"
}
```

`Flags: NONE` means production mode. `DEBUG_MODE` would produce all-zero PCRs and be rejected by the on-chain registry. Save the PCR values — the admin needs them in `EnclaveRegistry.expected_pcr0/1/2`.

## Step 4: Install the vsock bridge as a persistent service

The enclave listens on vsock CID 16 port 3000 but the validator daemon talks to TCP `localhost:3000`. The bridge connects them and must persist across reboots.

```bash
sudo tee /etc/systemd/system/vram-vsock-bridge.service > /dev/null <<'EOF'
[Unit]
Description=VRAM vsock bridge TCP 3000 to enclave CID 16 port 3000
After=network.target

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:3000,reuseaddr,fork VSOCK-CONNECT:16:3000
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now vram-vsock-bridge

# Verify
sleep 2
curl http://localhost:3000/health_check
```

Should print `ok`.

## Step 5: Configure `~/.env`

```bash
curl -o ~/.env https://raw.githubusercontent.com/VRAM-AI/vram-validator/main/.env.example
nano ~/.env
```

Fill in:

```bash
VRAMHUB_WALLET_MNEMONIC="your twelve word mnemonic here"
VRAMHUB_VALIDATOR_UID="<your-uid-from-admin>"

# For initial registration leave these as test mode
VRAMHUB_TEST_MODE="true"
VRAMHUB_NITRO_ENCLAVE="false"

# R2 credentials (Cloudflare R2 free tier)
VRAMHUB_R2_ACCOUNT_ID="<your-account-id>"
VRAMHUB_R2_BUCKET_NAME="vram-validator-gradients"
VRAMHUB_R2_ACCESS_KEY_ID="<your-r2-key>"
VRAMHUB_R2_SECRET_ACCESS_KEY="<your-r2-secret>"

# If running test mode without real R2, use local filesystem fallback:
VRAMHUB_R2_LOCAL_DIR=/tmp/vram-local-bucket
```

All `SLCL_*` variables should mirror the `VRAMHUB_*` values exactly. Some validator code reads one prefix, some reads the other.

## Step 6: Register the validator on chain (if not already done)

Fund the wallet with at least 11 testnet SUI:

```bash
for i in $(seq 1 11); do
  curl -s --location --request POST 'https://faucet.testnet.sui.io/v1/gas' \
    --header 'Content-Type: application/json' \
    --data-raw "{\"FixedAmountRequest\":{\"recipient\":\"<YOUR_WALLET_ADDRESS>\"}}" \
    -o /dev/null -w "Request $i: HTTP %{http_code}\n"
  sleep 6
done
```

Then register:

```bash
source ~/.env
vram-cli register-validator
```

Output:
```
Registered as validator uid=N
```

Save the UID:

```bash
sed -i "s|^VRAMHUB_VALIDATOR_UID=.*|VRAMHUB_VALIDATOR_UID=\"N\"|" ~/.env
sed -i "s|^SLCL_VALIDATOR_UID=.*|SLCL_VALIDATOR_UID=\"N\"|" ~/.env
```

## Step 7: Register the enclave on chain

Requires that the admin has already populated `EnclaveRegistry.expected_pcr0/1/2` with your PCR values. Confirm before registering:

```bash
curl -s -X POST https://fullnode.testnet.sui.io:443 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0","id":1,
    "method":"sui_getObject",
    "params":["0x20634567d619d9d7988d6b9cc8c901655f6b98a2f3e19fbbc88bf024d2610533",{"showContent":true}]
  }' | grep expected_pcr
```

`expected_pcr0/1/2` should be non-empty arrays. If empty, ask the admin to call `update_expected_pcrs` first.

Then register:

```bash
source ~/.env
vram-cli register-enclave \
  --enclave-url http://localhost:3000 \
  --validator-uid $VRAMHUB_VALIDATOR_UID
```

Output:
```
Enclave registered successfully.
VRAMHUB_ENCLAVE_PUBKEY=<64-char hex pubkey>
```

Save the pubkey — **paste it as a single line, do not let it wrap**:

```bash
echo 'VRAMHUB_ENCLAVE_PUBKEY="<paste-pubkey>"' >> ~/.env
echo 'SLCL_ENCLAVE_PUBKEY="<paste-pubkey>"' >> ~/.env
```

## Step 8: Switch to production mode

```bash
sed -i 's|^VRAMHUB_TEST_MODE=.*|VRAMHUB_TEST_MODE="false"|' ~/.env
sed -i 's|^VRAMHUB_NITRO_ENCLAVE=.*|VRAMHUB_NITRO_ENCLAVE="true"|' ~/.env
sed -i 's|^SLCL_TEST_MODE=.*|SLCL_TEST_MODE="false"|' ~/.env
sed -i 's|^SLCL_NITRO_ENCLAVE=.*|SLCL_NITRO_ENCLAVE="true"|' ~/.env

grep -E "TEST_MODE|NITRO_ENCLAVE|ENCLAVE_PUBKEY|VALIDATOR_UID" ~/.env
```

Verify all four mode flags are correct and the pubkey is on one line.

## Step 9: Run the validator daemon via Docker

The validator binary requires glibc 2.38; AL2023 ships glibc 2.34. Run inside an Ubuntu 24.04 container with the binary mounted in:

```bash
sudo systemctl enable docker   # survive reboots

mkdir -p /tmp/vram-local-bucket

sudo docker stop vram-validator 2>/dev/null || true
sudo docker rm vram-validator 2>/dev/null || true

sudo docker run -d \
  --name vram-validator \
  --network host \
  --restart unless-stopped \
  -e RUST_LOG=info \
  -v /usr/local/bin/vram-validator:/usr/bin/vram-validator:ro \
  -v "$HOME/.env:/root/.env:ro" \
  -v /tmp/vram-local-bucket:/tmp/vram-local-bucket \
  ubuntu:24.04 \
  bash -c "apt-get update -qq && apt-get install -y -qq ca-certificates && set -a && source /root/.env && set +a && export RUST_LOG=info && exec /usr/bin/vram-validator"

sleep 20
sudo docker logs --tail 30 vram-validator
```

Look for:
```
Validator starting enclave_url="http://localhost:3000" validator_uid=N mode=Nitro
Starting validation window window=...
```

`mode=Nitro` = production with hardware attestation. `mode=Dev` = TEST_MODE still on.

---

## Troubleshooting

### Enclave fails with E36 / "No CPUs available in CPU pool"

The Nitro driver is in the broken state. Reboot the instance:

```bash
sudo reboot
```

Then run `nitro-cli run-enclave` directly. **Do not run setup.sh again** — it re-breaks the kernel state.

### Validator container restarts in a loop with "Is a directory"

`/usr/local/bin/vram-validator` got created as a directory instead of a file. Fix:

```bash
sudo rm -rf /usr/local/bin/vram-validator
sudo curl -fsSL https://raw.githubusercontent.com/VRAM-AI/vram-validator/main/install.sh | sudo bash
ls -la /usr/local/bin/vram-validator   # confirm it's a file
```

### `register-enclave` aborts with PCR mismatch

`EnclaveRegistry.expected_pcr0/1/2` either does not match your PCR values or is empty. Check:

```bash
curl -s -X POST https://fullnode.testnet.sui.io:443 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"sui_getObject","params":["0x20634567d619d9d7988d6b9cc8c901655f6b98a2f3e19fbbc88bf024d2610533",{"showContent":true}]}' \
  | grep expected_pcr
```

If empty, ask the admin to call `update_expected_pcrs`. If non-empty but wrong, confirm your enclave is running in production mode (`Flags: NONE`) not debug mode.

### `register-validator` aborts with InsufficientStake

Wallet has less than 10 SUI for stake. Use the faucet loop in Step 6. Check balance:

```bash
source ~/.env
vram-cli status
```

### Validator logs show `mode=Dev` after switching to production

The `.env` was not loaded correctly. Common causes: pubkey wrapped to two lines, `SLCL_*` flags still set to test mode, or multiple conflicting `ENCLAVE_PUBKEY` lines.

Fix:

```bash
sed -i '/^VRAMHUB_ENCLAVE_PUBKEY/d; /^SLCL_ENCLAVE_PUBKEY/d' ~/.env
echo 'VRAMHUB_ENCLAVE_PUBKEY="<your-pubkey-no-wrap>"' >> ~/.env
echo 'SLCL_ENCLAVE_PUBKEY="<your-pubkey-no-wrap>"' >> ~/.env
grep -E "TEST_MODE|NITRO_ENCLAVE" ~/.env
# All should be: test=false, nitro=true
```

Then restart the Docker container:

```bash
sudo docker restart vram-validator
sudo docker logs --tail 10 vram-validator
```

### Validator shows `No checkpoint for window, skipping`

Healthy — the validator is running and waiting. No aggregator has anchored a checkpoint for the current window yet, or all miners are inactive. No action needed.

### Public IP changed after reboot

Without an Elastic IP, the public IPv4 changes on every stop/start. Get the new one from the AWS Console or:

```bash
curl -s http://169.254.169.254/latest/meta-data/public-ipv4
```

---

## Operational notes

### One reboot per instance lifetime

The AL2023 + Nitro driver issue requires one reboot after initial setup, then stays healthy. Avoid re-running `setup.sh`, `rmmod nitro_enclaves`, or `systemctl restart nitro-enclaves-allocator` after initial setup. If the driver breaks again, reboot.

### Backup

The `~/.env` file is your full validator identity. Back it up immediately after Step 8:

```bash
# From your laptop
scp -i <your-key>.pem ec2-user@<instance-ip>:~/.env \
  ~/Desktop/validator-env-backup-$(date +%Y%m%d).env
chmod 600 ~/Desktop/validator-env-backup-*.env
# Move to 1Password / encrypted vault
```

### Re-launch sequence after an unplanned reboot

```bash
# 1. Check Docker auto-started
sudo systemctl is-active docker

# 2. Launch enclave (never re-run setup.sh)
sudo nitro-cli run-enclave \
  --eif-path /opt/vram/slcl-nautilus.eif \
  --cpu-ids 1 5 \
  --memory 4096 \
  --enclave-cid 16

nitro-cli describe-enclaves   # State: RUNNING, Flags: NONE

# 3. Bridge auto-starts via systemd — verify
curl http://localhost:3000/health_check   # ok

# 4. Validator container auto-restarts via --restart unless-stopped
sudo docker logs --tail 10 vram-validator
```

If the enclave fails at step 2 with E36, reboot once more.

### Updating the validator binary

```bash
sudo docker stop vram-validator && sudo docker rm vram-validator
sudo rm -f /usr/local/bin/vram-validator
sudo curl -fsSL https://raw.githubusercontent.com/VRAM-AI/vram-validator/main/install.sh | sudo bash
# Re-run the docker run command from Step 9
```

The enclave EIF and on-chain registration do not change unless the enclave binary itself is updated. If the enclave binary changes: rebuild the EIF, capture new PCR values, ask the admin to call `update_expected_pcrs`, and re-run `register-enclave`.

---

## Verified working configuration

| Component | Version |
|-----------|---------|
| OS | Amazon Linux 2023 kernel 6.1.166-197.305 |
| `aws-nitro-enclaves-cli` | 1.4.4 |
| Docker | 25.0.14 |
| `vram-validator` | v0.4.19 |
| Enclave runtime | `slcl-nautilus` v0.4.19 |
| Sui RPC | testnet `fullnode.testnet.sui.io:443` |

---

## Acknowledgements

The reboot workaround for the Nitro Enclave CPU pool issue was identified by AWS Premium Support engineer Liv Armand N. (case `177805522200761`) on May 6, 2026.
