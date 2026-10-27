# Python module boundaries

The macOS app embeds only the modules listed in
[`service-modules.json`](../contracts/classifier/service-modules.json).
`scripts/embed_classifier_runtime.py` uses that manifest for both XPC bundles;
tests check that every relative import is available within its service.

The classifier entry point is `groundkeeper.worker`. Policy, constrained decoding,
receipt/context handling, Apple Shortcuts, and the Laya adapter support that
entry point. The separate search service enters through
`groundkeeper.merchant_search`. Backend libraries are imported when needed so
policy and orchestration tests do not require MLX, Torch, or model weights.

`runtime.py`, `runtime_v2.py`, `metrics.py`, and `merchant.py` support experiments
and evaluation. They are not embedded in the app. Their paths remain stable for
saved commands and reports. Shared modules such as `policy.py` and
`laya_runtime.py` are also used by experiments; their package location alone
does not determine whether they ship.

Completed experiment configurations contain historical code hashes. Use their
source revision to reproduce a completed run. Current cleanup code intentionally
does not satisfy those old hashes; never replace the hashes in an old report or
disable the integrity gate to resume it. New runs require a new configuration and
output directory. See the [script inventory](../scripts/README.md).
