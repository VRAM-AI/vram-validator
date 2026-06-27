#!/usr/bin/env python3
"""
VRAM Network - Python Sidecar Trainer
=====================================
Sidecar HTTP protocol so a PyTorch training script can act as a VRAM miner.
The Rust miner daemon handles chain / Walrus / compression; this handles the
forward/backward pass.

QLoRA is auto-enabled for large models (gemma/llama/mistral/qwen/phi) on GPUs
with < 40 GB, or forced with --lora. This is what makes a 5B model fit a 24 GB
card and what keeps the /train payload to a few thousand floats instead of
billions.

Endpoints:
  POST /train           { uid, window } -> { gradient: [f32], loss: f32 }
  POST /forward_loss    { uid, window } -> { loss: f32 }
  POST /load_checkpoint { data: b64 }   -> { ok: true }
  POST /save_checkpoint {}              -> { data: b64 }
  GET  /health                          -> { status, model, device, dataset }
"""

import argparse
import base64
import io
import json
import logging
import pathlib
import random
import threading
import urllib.request
from typing import Optional, List, Dict

import torch
from flask import Flask, jsonify, request

# USE_TF=0 must be set before importing transformers, so is_tf_available() stays
# False and tensorflow_text never enters _import_structure (transformers #46178).
import os as _os
_os.environ.setdefault("USE_TF", "0")
from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("vram_trainer")

# -- CLI args ------------------------------------------------------------------

parser = argparse.ArgumentParser()
parser.add_argument("--port",          type=int,   default=17070,  help="HTTP port")
parser.add_argument("--model",         type=str,   default="gpt2", help="HF model name or path")
parser.add_argument("--dataset",       type=str,   default=None,   help="JSONL dataset: path, URL, or 'fineweb'")
parser.add_argument("--device",        type=str,   default="auto", help="auto|cuda|cpu|mps")
parser.add_argument("--dtype",         type=str,   default="auto", help="auto|bfloat16|float16|float32")
parser.add_argument("--lr",            type=float, default=3e-4,   help="Learning rate")
parser.add_argument("--batch",         type=int,   default=4,      help="Batch size")
parser.add_argument("--seqlen",        type=int,   default=256,    help="Max sequence length")
parser.add_argument("--use-8bit-adam", action="store_true",        help="Force bitsandbytes 8-bit AdamW")
parser.add_argument("--lora",          action="store_true",        help="Force 4-bit QLoRA")
parser.add_argument("--no-lora",       action="store_true",        help="Disable QLoRA auto-detection")
parser.add_argument("--lora-r",        type=int,   default=16,     help="LoRA rank")
parser.add_argument("--lora-alpha",    type=int,   default=32,     help="LoRA alpha")
parser.add_argument("--lora-dropout",  type=float, default=0.05,   help="LoRA dropout")
args = parser.parse_args()

# -- Device + dtype ------------------------------------------------------------

def pick_device(spec: str) -> torch.device:
    if spec == "auto":
        if torch.cuda.is_available():
            return torch.device("cuda")
        if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
            return torch.device("mps")
        return torch.device("cpu")
    return torch.device(spec)

def pick_dtype(spec: str, device: torch.device) -> torch.dtype:
    if spec == "auto":
        return torch.bfloat16 if device.type == "cuda" else torch.float32
    return {"bfloat16": torch.bfloat16, "float16": torch.float16,
            "float32": torch.float32}.get(spec, torch.float32)

DEVICE = pick_device(args.device)
DTYPE  = pick_dtype(args.dtype, DEVICE)
log.info(f"Device: {DEVICE}  dtype: {DTYPE}")

# -- Model (QLoRA-aware) -------------------------------------------------------

def _should_use_lora() -> bool:
    if args.no_lora:
        return False
    if args.lora:
        return True
    if DEVICE.type != "cuda":
        return False
    _, total = torch.cuda.mem_get_info()
    big = any(k in args.model.lower()
              for k in ["gemma", "llama", "mistral", "qwen", "phi", "mixtral"])
    return big and (total / 1e9) < 40.0

USE_LORA = _should_use_lora()
log.info(f"QLoRA: {'enabled' if USE_LORA else 'disabled'} for {args.model!r}")
log.info(f"Loading {args.model!r} ...")

import inspect as _inspect
_fp_sig = _inspect.signature(AutoModelForCausalLM.from_pretrained)
_dtype_key = "dtype" if "dtype" in _fp_sig.parameters else "torch_dtype"

def _load_plain():
    kw = {"device_map": {"": DEVICE} if DEVICE.type != "cpu" else "cpu",
          "low_cpu_mem_usage": True, _dtype_key: DTYPE}
    try:
        return AutoModelForCausalLM.from_pretrained(args.model, **kw)
    except (ValueError, KeyError, AttributeError, OSError) as e:
        log.warning(f"AutoModelForCausalLM failed ({e!r}) - trying AutoModelForMultimodalLM")
        from transformers import AutoModelForMultimodalLM
        return AutoModelForMultimodalLM.from_pretrained(args.model, **kw)

def _load_4bit():
    bnb = BitsAndBytesConfig(
        load_in_4bit=True,
        bnb_4bit_quant_type="nf4",
        bnb_4bit_compute_dtype=torch.bfloat16,
        bnb_4bit_use_double_quant=True,
    )
    kw = {"quantization_config": bnb, "device_map": {"": 0}}
    try:
        return AutoModelForCausalLM.from_pretrained(args.model, **kw)
    except (ValueError, KeyError, AttributeError, OSError) as e:
        log.warning(f"AutoModelForCausalLM failed ({e!r}) - trying AutoModelForMultimodalLM")
        from transformers import AutoModelForMultimodalLM
        return AutoModelForMultimodalLM.from_pretrained(args.model, **kw)

if USE_LORA:
    from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training
    model = _load_4bit()
    model = prepare_model_for_kbit_training(model)
    model = get_peft_model(model, LoraConfig(
        r=args.lora_r,
        lora_alpha=args.lora_alpha,
        lora_dropout=args.lora_dropout,
        bias="none",
        task_type="CAUSAL_LM",
        target_modules="all-linear",
    ))
    model.print_trainable_parameters()
else:
    model = _load_plain()
    if hasattr(model, "gradient_checkpointing_enable"):
        model.gradient_checkpointing_enable()
        log.info("Gradient checkpointing enabled")

model.train()

# AutoProcessor handles multimodal checkpoints without a plain AutoTokenizer
try:
    tokenizer = AutoTokenizer.from_pretrained(args.model)
except Exception as e:
    log.warning(f"AutoTokenizer failed ({e!r}) - trying AutoProcessor")
    from transformers import AutoProcessor
    tokenizer = AutoProcessor.from_pretrained(args.model)
if tokenizer.pad_token is None:
    tokenizer.pad_token = tokenizer.eos_token

def _trainable_params():
    return [p for p in model.parameters() if p.requires_grad]

def _param_count() -> int:
    return sum(p.numel() for p in model.parameters())

def _make_optimizer():
    trainable = _trainable_params()
    n_train = sum(p.numel() for p in trainable)
    if not USE_LORA and (args.use_8bit_adam or n_train > 500_000_000):
        try:
            import bitsandbytes as bnb
            log.info("Using bitsandbytes 8-bit AdamW")
            return bnb.optim.AdamW8bit(trainable, lr=args.lr)
        except ImportError:
            log.warning("bitsandbytes not installed - falling back to fp32 AdamW")
    return torch.optim.AdamW(trainable, lr=args.lr)

optimizer  = _make_optimizer()
model_lock = threading.Lock()
MODEL_NAME = f"{args.model}@{_param_count()//1_000_000}M"
log.info(f"Model ready: {MODEL_NAME}")

if DEVICE.type == "cuda":
    free, total = torch.cuda.mem_get_info()
    log.info(f"VRAM after load: {(total-free)/1e9:.1f}/{total/1e9:.1f} GB")

# -- Dataset -------------------------------------------------------------------

HAS_CHAT_TEMPLATE = (hasattr(tokenizer, "chat_template")
                     and tokenizer.chat_template is not None)
log.info(f"Chat template: {'yes' if HAS_CHAT_TEMPLATE else 'no (pretraining format)'}")

INSTRUCTION_ROWS: Optional[List[Dict]] = None
FINEWEB_CACHE:    Optional[List[str]]  = None  # pre-loaded at startup, sampled per batch
FINEWEB_CACHE_SIZE = 2000

def _load_jsonl_from_url(url: str) -> List[Dict]:
    log.info(f"Fetching dataset from {url} ...")
    with urllib.request.urlopen(url, timeout=60) as resp:
        raw = resp.read().decode("utf-8")
    rows = [json.loads(l) for l in raw.splitlines() if l.strip()]
    log.info(f"Loaded {len(rows)} rows from URL")
    return rows

def _load_jsonl_from_path(path: str) -> List[Dict]:
    p = pathlib.Path(path)
    rows = [json.loads(l) for l in p.read_text(encoding="utf-8").splitlines() if l.strip()]
    log.info(f"Loaded {len(rows)} rows from {path}")
    return rows

def _init_dataset():
    global INSTRUCTION_ROWS, FINEWEB_CACHE
    spec = args.dataset
    if spec is not None and spec != "fineweb":
        if spec.startswith("http://") or spec.startswith("https://"):
            INSTRUCTION_ROWS = _load_jsonl_from_url(spec)
        else:
            INSTRUCTION_ROWS = _load_jsonl_from_path(spec)
        if not INSTRUCTION_ROWS:
            raise ValueError(f"Dataset loaded 0 rows from {spec!r}")
        log.info(f"Dataset: instruction JSONL - {len(INSTRUCTION_ROWS)} rows")
        return

    # FineWeb-edu: load a fixed pool once at startup so /train never re-downloads
    log.info(f"Dataset: FineWeb-edu — pre-loading {FINEWEB_CACHE_SIZE} rows into memory...")
    try:
        from datasets import load_dataset
        ds = load_dataset("HuggingFaceFW/fineweb-edu", name="sample-10BT",
                          split="train", streaming=True)
        texts = []
        for ex in ds:
            texts.append(ex["text"])
            if len(texts) >= FINEWEB_CACHE_SIZE:
                break
        FINEWEB_CACHE = texts
        log.info(f"FineWeb cache ready: {len(FINEWEB_CACHE)} rows")
    except Exception as e:
        log.warning(f"FineWeb unavailable ({e!r}) — will use synthetic tokens")

_init_dataset()

def _format_instruction_row(row: Dict) -> str:
    instruction = row.get("instruction", "")
    inp         = row.get("input", "")
    output      = row.get("output", "")
    user_content = instruction if not inp else f"{instruction}\n\n{inp}"
    if HAS_CHAT_TEMPLATE:
        messages = [
            {"role": "user",      "content": user_content},
            {"role": "assistant", "content": output},
        ]
        return tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=False)
    return f"### Instruction\n{user_content}\n\n### Response\n{output}"

def _sample_instruction_batch(uid: int, window: int) -> torch.Tensor:
    rng = random.Random(uid * 1_000_003 + window)
    selected = rng.choices(INSTRUCTION_ROWS, k=args.batch)
    texts = [_format_instruction_row(r) for r in selected]
    enc = tokenizer(texts, truncation=True, max_length=args.seqlen + 1,
                    padding="max_length", return_tensors="pt")
    return enc["input_ids"].to(DEVICE)

def _lcg_tokens(seed: int, n: int) -> torch.Tensor:
    vocab = model.config.vocab_size
    s = seed & 0xFFFF_FFFF_FFFF_FFFF
    tokens = []
    for _ in range(n):
        s = (s * 6364136223846793005 + 1442695040888963407) & 0xFFFF_FFFF_FFFF_FFFF
        tokens.append(s % vocab)
    return torch.tensor(tokens, dtype=torch.long)

def _get_fineweb_batch(uid: int, window: int) -> torch.Tensor:
    seed = (uid * 1_000_003 + window) & 0xFFFF_FFFF_FFFF_FFFF
    if FINEWEB_CACHE:
        rng = random.Random(seed)
        texts = rng.choices(FINEWEB_CACHE, k=args.batch)
        enc = tokenizer(texts, truncation=True, max_length=args.seqlen + 1,
                        padding="max_length", return_tensors="pt")
        return enc["input_ids"].to(DEVICE)
    # Fallback: synthetic tokens (no network, deterministic)
    log.debug("FineWeb cache empty — using synthetic tokens")
    rows = [_lcg_tokens(seed + b, args.seqlen + 1) for b in range(args.batch)]
    return torch.stack(rows).to(DEVICE)

def _get_batch(uid: int, window: int) -> torch.Tensor:
    if INSTRUCTION_ROWS is not None:
        return _sample_instruction_batch(uid, window)
    return _get_fineweb_batch(uid, window)

def _compute_loss(uid: int, window: int):
    batch   = _get_batch(uid, window)
    inputs  = batch[:, :-1]
    targets = batch[:, 1:]
    out     = model(input_ids=inputs, labels=targets)
    return out.loss, out.loss.item()

# -- HTTP server ---------------------------------------------------------------

app = Flask(__name__)

TOPK_FRAC = 0.001
MAX_GRADIENT_VALUES = 8192  # hard cap so the JSON response stays small

@app.route("/health")
def health():
    info = {
        "status":        "ok",
        "model":         MODEL_NAME,
        "device":        str(DEVICE),
        "dtype":         str(DTYPE),
        "lora":          USE_LORA,
        "dataset":       args.dataset or "fineweb",
        "dataset_rows":  len(INSTRUCTION_ROWS) if INSTRUCTION_ROWS else None,
        "chat_template": HAS_CHAT_TEMPLATE,
    }
    if DEVICE.type == "cuda":
        free, total = torch.cuda.mem_get_info()
        info["vram_used_gb"]  = round((total - free) / 1e9, 2)
        info["vram_total_gb"] = round(total / 1e9, 2)
    return jsonify(info)

@app.route("/train", methods=["POST"])
def train():
    body   = request.get_json(force=True)
    uid    = int(body.get("uid", 0))
    window = int(body.get("window", 0))
    with model_lock:
        optimizer.zero_grad()
        loss, loss_val = _compute_loss(uid, window)
        loss.backward()
        # Only trainable params carry grads. Under QLoRA that is the adapters,
        # a few million floats, not the billions in the frozen base. Never
        # build a dense zeros_like over the full param count.
        grad_parts = []
        for p in model.parameters():
            if not p.requires_grad or p.grad is None:
                continue
            grad_parts.append(p.grad.detach().cpu().float().flatten())
        all_grads = torch.cat(grad_parts) if grad_parts else torch.zeros(1)
        topk = max(1, min(int(all_grads.numel() * TOPK_FRAC), MAX_GRADIENT_VALUES))
        _, indices = torch.topk(all_grads.abs(), topk)
        grads = all_grads[indices].tolist()
        optimizer.step()
    log.info(f"train uid={uid} window={window} loss={loss_val:.4f} "
             f"params={all_grads.numel():,} returned={topk:,}")
    return jsonify({"gradient": grads, "loss": loss_val})

@app.route("/forward_loss", methods=["POST"])
def forward_loss():
    body   = request.get_json(force=True)
    uid    = int(body.get("uid", 0))
    window = int(body.get("window", 0))
    with model_lock:
        with torch.no_grad():
            _, loss_val = _compute_loss(uid, window)
    return jsonify({"loss": loss_val})

@app.route("/load_checkpoint", methods=["POST"])
def load_checkpoint():
    body = request.get_json(force=True)
    data = base64.b64decode(body["data"])
    # Safetensors magic: first 8 bytes encode the metadata length (little-endian u64)
    # Pickle magic: 0x80 0x04 or 0x80 0x05
    is_safetensors = len(data) > 8 and data[0:1] != b"\x80"
    with model_lock:
        if is_safetensors:
            try:
                import tempfile, os
                from safetensors.torch import load_file as sf_load_file
                with tempfile.NamedTemporaryFile(suffix=".safetensors", delete=False) as f:
                    f.write(data)
                    fname = f.name
                state = sf_load_file(fname)
                os.unlink(fname)
                model.load_state_dict(state, strict=False)
                log.info(f"Loaded safetensors checkpoint ({len(data):,} bytes)")
            except Exception as e:
                log.warning(f"safetensors load failed ({e!r}), trying torch.load")
                buf = io.BytesIO(data)
                state = torch.load(buf, map_location=DEVICE, weights_only=True)
                model.load_state_dict(state, strict=False)
        else:
            buf = io.BytesIO(data)
            state = torch.load(buf, map_location=DEVICE, weights_only=True)
            model.load_state_dict(state, strict=False)
    return jsonify({"ok": True})

@app.route("/save_checkpoint", methods=["POST"])
def save_checkpoint():
    with model_lock:
        if USE_LORA:
            from peft import get_peft_model_state_dict
            state_dict = get_peft_model_state_dict(model)
        else:
            state_dict = {k: v for k, v in model.state_dict().items()}
        cpu_dict = {k: v.detach().cpu().float() for k, v in state_dict.items()}
    try:
        from safetensors.torch import save as sf_save
        data_bytes = sf_save(cpu_dict)
        fmt = "safetensors"
    except Exception as e:
        log.warning(f"safetensors unavailable ({e!r}), falling back to torch.save")
        buf = io.BytesIO()
        torch.save(cpu_dict, buf)
        data_bytes = buf.getvalue()
        fmt = "pickle"
    data = base64.b64encode(data_bytes).decode()
    log.info(f"Saved checkpoint {fmt} ({len(data_bytes):,} bytes)")
    return jsonify({"data": data, "format": fmt})

if __name__ == "__main__":
    log.info(f"VRAM sidecar listening on 0.0.0.0:{args.port}")
    app.run(host="0.0.0.0", port=args.port, threaded=False)
