"""Pinned public model download; no private data leaves this process."""

from huggingface_hub import snapshot_download

snapshot_download(
    "mlx-community/Qwen3.5-4B-MLX-4bit",
    revision="32f3e8ecf65426fc3306969496342d504bfa13f3",
    local_dir=".local/finetune/models/qwen35-original",
    allow_patterns=[
        "model.safetensors",
        "model.safetensors.index.json",
        "config.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "chat_template.jinja",
        "vocab.json",
        "README.md",
    ],
    max_workers=3,
)
