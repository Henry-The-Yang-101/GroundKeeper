# Model council

Implemented 2026-10-23. Council is selected explicitly in provider setup and uses
Qwen, Laya and an Apple Intelligence Shortcut with one vote each. The versioned
policy is `council-equal-v2`; the [roadmap design](roadmap.md#council-design)
records the decisions and the [classifier contract](../contracts/classifier/README.md#council-orchestration)
describes the queue and evidence boundaries.

Two matching valid type/category decisions produce a suggestion requiring review.
If the third provider fails, that suggestion is visibly partial. One valid vote,
three different answers or a tie produce no consensus and leave the current
categorization in place. Individual model outputs remain inspectable. User
confirmation/correction preserves the original council record as earlier history.

## Verification on 2026-10-23

All council classifications and UI edits below used fictional inputs and temporary
vaults/preferences. No private transactions were sent to Apple or DuckDuckGo.

| Check | Result |
| --- | --- |
| GroundKeeperCore suite | 63 tests passed, including 18 council tests. |
| Python schema, worker, merchant search, search benchmark and Shortcut adapter suites | 77 tests passed. |
| Signed Debug macOS build | Passed with the existing development identity and entitlements. |
| Native council queue smoke | Passed manual-mode gating, model verification, real Qwen/Laya XPC inference, persisted parent/member runs, review and database integrity. Apple was recorded unavailable; the agreeing local members produced a partial result. |
| Native classifier boundary smoke | Host/nonce rejection, cancellation, search-runtime handshake, MLX GPU and PyTorch MPS probes passed. |
| Live Apple success from the sandboxed app | **Not verified.** See the limitation below. |

The council tests cover complete-decision voting, order independence, invalid
responses, timeouts, partial participation, quota suppression within a batch,
one-vote abstention, explicit retry, mode switches, cancellation without spending
retries, interrupted-run recovery, old model-job migration, immutable retrieval
snapshots, receipt consent, Wallet source-reference hashing, cross-member
provenance rejection, stale edits and retained user-correction history.

The native UI walkthrough checked:

- Missing-package setup and the disabled activation button; selecting both
  existing packages makes the button available.
- Explicit activation, verification progress, disabled controls during setup and
  the selected Council state. Draft choices do not apply themselves.
- Unanimous, disagreement, partial/quota and no-consensus/timeout records backed
  by the real queue and persistence with deterministic fictional providers.
- Collapsed/expanded member decisions, safe failure text, model names and saved
  search-source links. The expansion control exposes its state to accessibility.
- Light and dark appearances, the 720-point setup sheet, and the 530-point editor.
  Expanded evidence scrolls inside the editor and keeps Cancel/Save visible.
- Confirming a fictional suggestion, reopening it with review off, and retaining
  the original council result as earlier history.

The walkthrough caught and fixed an initially empty view that did not start its
asynchronous report load. It also checked that an old result is identified as
history after a user confirmation. This was not a full VoiceOver audit or an
iPhone test.

## Apple availability limitation

The installed `GK Categorize Cloud` Shortcut produced a valid decision for a
fictional input when called outside the app sandbox. The sandboxed app/XPC route
did not produce a usable result during these checks. macOS logs included a
WorkflowKit temporary-file permission failure. Experiments with owned temporary
directories, explicit text output and execution from the main app sandbox did
not establish a working route; those experimental adapter changes were removed.
The exact remaining OS/Shortcut integration cause is unresolved.

Council records the actual Apple failure and retains review. The successful
three-member path is covered with deterministic providers; successful live
three-member inference has **not** been demonstrated on this Mac. No permissions,
sandbox exceptions or user Shortcut contents were changed to work around it.
Apple usage limits can independently make the provider unavailable.

## Reproduce

Run the core and relevant Python suites from the repository root:

```sh
swift test --package-path apps/macos/GroundKeeperCore --scratch-path .local/macos/CoreBuild
.venv/bin/python -m pytest tests/test_database_schema.py tests/test_worker.py tests/test_merchant_search.py tests/test_real_merchant_search_benchmark.py tests/test_apple_shortcuts.py -q
```

The [macOS guide](../apps/macos/README.md#council-verification) gives the disposable
UI-preview and native council-smoke commands. The preview never invokes live
models or networking. The smoke prompts for the actual local packages and may
consume Apple quota, but uses a fictional transaction and separate preferences.
Use a whole-process timeout when automating it.

Equal weights remain provisional. These tests establish flow correctness; they
do not measure council accuracy, calibrated confidence, production merchant-match
precision or a controlled latency/memory benchmark.
