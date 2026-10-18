Pinned model assets used by the GroundKeeper release workflow.

- Qwen: `qwen-delaware-v1-step5872`, split across `part001` and `part002`.
- Laya: `laya-epoch3`, one archive part.

The catalog in `release/models.json` records sizes, file hashes, and model
manifest hashes. Preserve these assets unchanged. No training or evaluation
datasets are included. See `MODEL-NOTICES.txt` for upstream attribution.

For installation, use a `GroundKeeper build` release, which includes these same
archives, a checksum verifier, an installation script, and the app installer.
