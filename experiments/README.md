# Experiment evidence and reproduction

Completed reports, configurations, annotations, and recorded source hashes are
historical evidence. Application cleanup does not revise their results. Current
Python module roles are documented in [`groundkeeper/README.md`](../groundkeeper/README.md);
operational and historical commands are inventoried in [`scripts/README.md`](../scripts/README.md).

For the frozen v2 fine-tuning configuration, commit `2564f09` contains all 15
source files matching `finetune/v2/training_config.json`. The Delaware
continuation configuration was committed at `e649646`; its script hash uses an
absolute checkout path, so resolve that path relative to the historical checkout
when inspecting its recorded code. Keep a historical checkout separate from the
working app and use the dependencies and runbook from that revision.

Files such as `runtime.py`, `runtime_v2.py`, `full_common.py`, and `v2_common.py`
have been cleaned up since those runs. Formatting and shared-helper extraction
change their hashes even when behavior is preserved. Do not refresh hashes in a
completed configuration, weaken its integrity checks, or reuse its output path
to make current code resume an old run. A new experiment needs a new frozen
configuration, source revision, and output directory.
