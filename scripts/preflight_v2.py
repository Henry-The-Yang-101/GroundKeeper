"""Freeze a finite v2 configuration after label audit and token/mask checks."""

import json
import time
from pathlib import Path

from mlx_lm.tuner.datasets import ChatDataset
from mlx_lm.utils import load_tokenizer

from groundkeeper.policy_v2 import messages_v2
from scripts.common_io import read_rows, sha256, write_json
from scripts.v2_common import CONFIG, OUT, PUBLIC, ROOT, checkpoint_steps


def main():
    if CONFIG.exists():
        raise FileExistsError("Do not replace the frozen v2 configuration")
    dataset = json.loads((PUBLIC / "dataset_report.json").read_text())
    if dataset["phase"] != "frozen" or dataset["coverage_failures"]:
        raise ValueError("Coverage and audit gates must pass")
    tokenizer = load_tokenizer(ROOT / "models/qwen35-text")
    max_tokens = 0
    counts = {}
    for split in ("train", "valid"):
        rows = read_rows(OUT / f"prepared/{split}_records.jsonl")
        if sha256(OUT / f"prepared/{split}_records.jsonl") != dataset["files"][split]:
            raise ValueError("Dataset changed after freeze")
        counts[split] = len(rows)
        data = ChatDataset(
            [{"messages": messages_v2(r["input"], r["answer"])} for r in rows],
            tokenizer,
            mask_prompt=True,
        )
        for row in data._data:
            tokens, offset = data.process(row)
            prefix = tokenizer.apply_chat_template(
                row["messages"][:-1],
                tokenize=True,
                add_generation_prompt=True,
                enable_thinking=False,
                return_dict=False,
            )
            if tokens[:offset] != prefix or not 0 < offset < len(tokens) <= 640:
                raise ValueError("Prompt mask or length gate failed")
            if not tokenizer.decode(tokens[offset:]).startswith('{"type":'):
                raise ValueError("Training target is not canonical type-first JSON")
            max_tokens = max(max_tokens, len(tokens))
    steps = checkpoint_steps(counts["train"])
    # Sequence ceiling follows actual token lengths, with a small aligned margin;
    # no row truncation or invisible prompt-only loss is allowed.
    seq_length = ((max_tokens + 31) // 32) * 32
    code_paths = sorted(
        [
            *Path("groundkeeper").glob("*.py"),
            Path("scripts/full_common.py"),
            *[
                Path("scripts") / name
                for name in [
                    "v2_common.py",
                    "preflight_v2.py",
                    "run_v2_training.py",
                    "evaluate_v2_baselines.py",
                    "v2_pipeline.py",
                    "finalize_v2.py",
                ]
            ],
        ]
    )
    estimated_seconds = 2 * steps[-1] * 3.5 + 6 * (counts["valid"] + 116) * 0.9 + 2400
    if estimated_seconds > 21600:
        raise ValueError(
            f"Conservative estimate {estimated_seconds:.0f}s exceeds six-hour budget; review before launch"
        )
    cfg = {
        "approval": "User approved coverage repair, label audit, constrained JSON and hours of training on 2026-10-09",
        "model": str(ROOT / "models/qwen35-text"),
        "train_n": counts["train"],
        "valid_n": counts["valid"],
        "learning_rates": [5e-5, 2e-5],
        "epochs": 1,
        "iters": steps[-1],
        "checkpoint_steps": steps,
        "batch_size": 1,
        "grad_accumulation_steps": 8,
        "num_layers": 4,
        "seed": 20261009,
        "max_seq_length": seq_length,
        "observed_max_tokens": max_tokens,
        "mask_prompt": True,
        "lora_parameters": {
            "rank": 8,
            "scale": 2.0,
            "dropout": 0.0,
            "keys": [
                "self_attn.q_proj",
                "self_attn.v_proj",
                "linear_attn.in_proj_qkv",
                "linear_attn.in_proj_z",
            ],
        },
        "decoder": "constrained",
        "prompt_version": "v2",
        "overall_seconds": 21600,
        "candidate_seconds": 10800,
        "estimate_seconds": estimated_seconds,
        "data_hashes": {
            f"{s}_records.jsonl": dataset["files"][s] for s in ("train", "valid", "test")
        },
        "legacy_validation_sha256": sha256(ROOT / "prepared/valid_records.jsonl"),
        "code_hashes": {str(p): sha256(p) for p in code_paths},
        "frozen_unix": time.time(),
    }
    write_json(CONFIG, cfg)
    print(json.dumps(cfg, indent=2))


if __name__ == "__main__":
    main()
