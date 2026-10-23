# Bundled classifier bridge

GroundKeeper's native app calls `com.groundkeeper.macos.classifier`, an embedded
XPC service. A native Objective-C host embeds CPython; Python/MLX/PyTorch never
load in the UI process. Swift owns SQLite and application state, persists
classification jobs, and saves results as assignments requiring review. See the
[application integration](../database/IMPLEMENTATION.md) for transaction and
retry behavior.

## Build and run

For a fresh checkout, follow the [setup guide](../../docs/setup.md) to install
both pinned Python environments. Once they are installed:

```sh
.venv/bin/python -m scripts.prepare_classifier_runtime
./apps/macos/run.sh
```

The preparer checks `runtime-lock.json`, resolves the installed dependency
closure, copies CPython 3.12 and runtime packages to the ignored
`.local/macos/classifier-runtime`, rewrites non-relocatable library IDs and signs
the copied native libraries. It never changes research environments or downloads
models. Source interpreters can be supplied with `--python`/`--laya-python`.
An intentional runtime upgrade requires reviewing/updating the lock and then
restaging with `--rebuild`. A clean machine must install those exact dependencies
first; the preparer is an offline packager, not a dependency installer.

Xcode builds a real XPC target, embeds the runtime/worker, signs native code with
the build identity and copies the service into the app. Runtime copies/signatures
are cached by dependency lock and signing identity for incremental builds. The
built app does not invoke `.venv`, `pip`, a shell, a system Python or a web server.
Runtime libraries retain their distribution metadata/licenses in the bundle.
The current packaged native dependencies target Apple silicon and macOS 26.2+;
Intel is not supported. A scan of all staged native library deployment targets
found the highest minimum in MLX's core/library at macOS 26.2. The app target is
aligned with that floor. The older UI-only preview's macOS 14 minimum no longer
describes the bundled classifier build. Validate this floor on runtime upgrades.

Settings > Categorization selects a local model package or an explicit Apple
Intelligence Shortcut provider for the persistent queue. The selected processing
mode controls when jobs run. Separate diagnostics can check GPU support and
classify fictional text without writing a transaction. Council orchestration
remains planned.

## Model packages

Models are data-only packages selected through the app's directory picker.
They are separate from the app/runtime and capped at 3 GB each. Export an
existing manifest-verified experimental package into a new destination:

```sh
.venv/bin/python -m scripts.export_classifier_package \
  .local/finetune/package-full-v1 .local/macos/models/qwen \
  --backend qwen_mlx --model-id qwen-full-v1-step512
```

For Laya, use `--backend laya_mps`. This checkpoint's upstream tokenizer loader
normalizes tokenizer metadata on first load. The exporter normalizes the copied
metadata before hashing so the service can load a read-only package. If that
normalization already changed an old package's metadata after its manifest was
written, the exporter rejects it. `--verified-fallback <original-checkpoint>`
can recover only small JSON files matching the **original** manifest hash; it
cannot bypass weight verification or change original packages.

`classifier.json` binds the package format, model ID, backend, prompt version,
policy and SHA-256/size of every model file. The worker verifies the complete
file set and hashes on prepare, before calling a loader. Extra files, traversal,
symlink escapes and executable/pickle content are rejected. Model code is always
the bundled worker; remote tokenizer code is disabled. A checksum proves package
identity/integrity, not an independent publisher signature or model accuracy.

The Swift app creates a **transient cross-process bookmark** from the user-chosen
URL using creation options `[]`. The service resolves it without UI, balances
the implicit sandbox extension, and retains that access only while the model is
loaded. App-scoped persistent bookmarks are a separate mechanism and must not
be passed as another process's app-scoped grant. The app's picker entitlement
allows read-only access; the service receives no vault path or unlock key.

## Wire contract v1

`ClassifierClient` is a Swift actor. Its transport uses `NSXPCConnection` with
two methods: `request(Data, reply: Data)` and `cancel(requestID, reply: Bool)`.
A reverse XPC interface delivers small JSON stage events. The native interface
uses only Foundation types; each JSON envelope is bounded to 64 KiB.

Requests use `protocol_version=1`, a unique string `request_id`, `operation`,
and `timeout_ms` (100–120000; default 60000). Protocol version, policy version,
model manifest identity and model package format are separate versions.

| Operation | Additional input | Result |
| --- | --- | --- |
| `handshake` | None | Supported backends, policy, categories/types, bundled runtime versions, current model. No model is loaded. |
| `gpu_probe` | None | Real small matrix calculations on MLX GPU and PyTorch MPS, with device and numerical result. |
| `prepare_model` | `package_bookmark` | Verified `model` identity and `reused` flag. Same verified package reuses the loaded model. |
| `prepare_shortcut` | `shortcut_name` | Selects the explicit Apple Shortcut provider and releases local model weights. |
| `classify` | `job_id`, `part_id`, `transaction_revision`, `policy_version`, `model_manifest_sha256`, `input` | Decision, actual model identity and echoed job/part/revision. |
| `release_model` | None | Releases model references and backend allocator caches. |

Classifier input is `{description,direction,currency}` with optional
`receipt_context`, `wallet_category_raw`, and `merchant_context` fields, including explicit
JSON null for unknown currency. Description is bounded to 2048 characters; Qwen
also rejects prompts over 512 tokens without additional evidence, 768 with only
a Wallet hint, or 2048 tokens with receipts.
Receipt context uses `receipt-context-v1` with `text` (at most 1600 UTF-8 bytes),
`truncated` (boolean), and `evidence_sha256` (full original OCR hash). Qwen adds
receipt instructions to its package's v1/v2 prompt. Laya receives a separately
identified OCR state field and receipt-aware questions, with 1024/768 sequence/head
budgets; its existing weights are unchanged and receipt performance must be
evaluated independently. Apple Shortcut exports include receipt instructions;
the queue omits receipt evidence unless its separate consent setting is enabled.
`wallet_category_raw` is a nonblank string of at most 128 UTF-8 bytes without
ASCII controls. It is an untrusted broad merchant-category hint, never an
instruction or direct category assignment. Explicit purchase/receipt evidence
takes priority; it does not establish purchased items, payment type, gift intent
or refund purpose. Conflicts and ambiguity require review. Qwen v1/v2 append
hint instructions only when present. Laya preserves the hint alongside any OCR
state and uses evidence-aware questions and 1024/768 budgets. The Apple Shortcut
adapter forwards it as JSON; the exported categorizer prompts include the same
rules. Existing weights are unchanged; improved accuracy is not established.
Without either evidence field, Python-built Qwen prompts and Laya state,
questions and limits are preserved.
No account identifier, amount, geotag or
financial history is required. Category/type vocabulary is currently the pinned
18-category experimental policy, not the dynamically expandable database table.

Success envelope:

```json
{
  "protocol_version": 1,
  "request_id": "request-uuid",
  "status": "succeeded",
  "elapsed_ms": 185.2,
  "result": {
    "decision": {"type":"expense","category":"dining","review":true},
    "model": {
      "model_id":"laya-epoch3", "backend":"laya_mps",
      "manifest_sha256":"<package identity>",
      "policy_version":"groundkeeper-18-v1", "device":"mps"
    },
    "job_id":"job-uuid", "part_id":"part-uuid", "transaction_revision":3
  }
}
```

Errors have `status=failed` and `error:{code,message}`. Defined codes include
`incompatible_protocol`, `unsupported_operation`, `invalid_request`, `busy`,
`package_access_denied`, `invalid_package`, `incompatible_policy`,
`gpu_unavailable`, `model_not_ready`, `model_mismatch`, `input_too_large`,
`invalid_output`, `cancelled`, `deadline_exceeded`, `inference_failed`,
`runtime_unavailable` and `runtime_failed`. Native dependency exception messages,
tracebacks and transaction descriptions are not returned as diagnostics.

Progress events identify the request and a stage: `queued`, `running`,
`verifying_package`, `loading_model`. No invented percentage is emitted.

## Execution and performance

One dedicated OS thread owns CPython and model execution, preserving interpreter
thread state and MLX's thread-local streams. It releases the GIL while waiting
for work. Native XPC control/cancellation remain independent of the inference
thread/GIL. Both app and service bound pending work to 16 requests.

- Qwen uses MLX's GPU device/stream, retains quantized weights and tokenizer,
  precomputes the finite JSON grammar once and streams generation internally
  for cancellation checks. It generates only a schema-valid canonical decision,
  with thinking disabled and greedy sampling. The MLX allocator has a 128 MiB
  cache cap and a 10 GiB process allocation limit. These are limits, not expected
  memory use or a reservation against other apps.
- Laya uses PyTorch MPS, `inference_mode` and the established fp32/eager settings.
  Device placement is checked after loading and after inference. CPU fallback
  is disabled. No unvalidated precision conversion changes the trained model.
- Only one heavyweight model is retained. Switching drops the old model and
  clears its allocator cache before loading the next. Python/native libraries
  themselves remain resident until the process ends. Partial load failures also
  clear the selected backend's allocator after releasing failed-loader traceback
  references. Laya's package-specific global tokenizer cache entries are evicted
  after loading; the active agent retains its tokenizer until release. This
  integration uses the private cache API in pinned Laya 0.4.1 and must be checked
  when upgrading that dependency.
- `review=true` is enforced on every suggestion. Structural validation/GPU use
  do not establish real transaction accuracy or automatic-acceptance calibration.

Deadlines include queue time. Hashing and Qwen generation check cancellation;
Laya/native kernels may only return cooperatively after an inference call.
Swift cancellation finishes its await immediately and ignores late replies.
A native watchdog exits the service if a request remains stuck five seconds
beyond its deadline. This loses all in-flight requests; Swift reports the
interruption and can reconnect. A cancel request alone is not permission to
kill other work before its deadline.
Each watchdog is cancelled when its request finishes and holds only a weak job
reference, so completed request payloads are not retained until their deadlines.

The client matches response ID, protocol, model identity and job/part/revision.
Interruption/invalidation drains each continuation exactly once. Callback
generation checks prevent a stale connection invalidation tearing down a new
connection. No request is automatically replayed. After a restart, reconnect,
handshake and prepare again. The Swift job coordinator persists attempts, applies
bounded retries, and commits results idempotently only when the database revision
and current assignment still permit them. The bridge itself does not write to
SQLite or promise exactly-once inference.

## Merchant search evidence

Search is an optional stage owned by the Swift queue before inference. Settings
and cached evidence live in the vault, with migration 006 adding a bounded
cache and immutable per-run `merchant_search_json` metadata. The original
transaction/capture remains unchanged. The final canonical input hash includes
the selected `merchant_context`; Wallet values are reconstructed from their
existing source reference for hashing. Cache expiry/clearing does not remove
the run's evidence snapshot. Enabling the setting does not recategorize already
completed/confirmed transactions automatically.

The dedicated `com.groundkeeper.macos.merchant-search` XPC service receives only
`merchant` (at most 120 UTF-8 bytes) and `locality` (80), not the transaction.
It exposes `search_handshake` and `merchant_search` over the same authenticated,
64 KiB, cancellable native transport. Search stages happen outside inference's
deadline. The search service has network-client access and no vault/key access;
the inference service keeps its network-free sandbox. Each service bundles only
its worker entry point. One physical CPython/dependency copy lives under the
enclosing app's `Contents/Resources/Python`, with libpython in
`Contents/Frameworks`. Authenticated services retain a read grant to that exact
signed app for loading this shared code. They do not receive a ledger bookmark.
Ad hoc distributions use the distinct `.merchant-search.adhoc` service identifier
to avoid reusing a development-team-owned sandbox container. The client reads the
embedded helper's identifier; both known variants keep the same host signature
and nonce checks. No container access ACL is weakened during a signing transition.

DDGS 9.16.0 uses only its DuckDuckGo HTML adapter with `ca-en`, five results,
one thread, a reused client/adapter, and a 12-second HTTP timeout. An explicit
host/path guard permits only HTTPS `html.duckduckgo.com/html/`; redirects and
other engines are disabled, and result URLs are never visited. The adapter
retains DDGS's randomly chosen browser/OS profile, while configuring primp's
`dns_resolver="system"` because its default resolver cannot read DNS configuration
in the macOS sandbox. TLS verification remains enabled. This is a transport
configuration change from the original standalone experiment; the signed app
is checked separately. No API/MCP server dependencies or browser automation are bundled.
The pinned [primp resolver implementation](https://github.com/deedy5/primp/blob/v2.0.1/crates/primp-python/src/client_builder.rs)
defines the system-resolver option.

A native service thread serializes searches. The queue caches repeated queries,
persists a conservative reservation before dispatch and the next eligible time
after completion, and shares that pacing across provider switches and process
handoffs. The helper independently enforces 10.5 seconds after each completed
search using monotonic time. CAPTCHA/403/429 activates a 15-minute circuit breaker;
other unavailable responses back off for one minute. No challenge solving,
proxy rotation, immediate retry or engine fallback is attempted. Empty/ambiguous
matches and failures continue classification without web evidence. Positive cache
entries expire after 30 days; negatives after one day; the cache holds at most
1,000 entries. Idle client connections close after 60 seconds.

`merchant_context` has exactly `version="merchant-search-v1"`,
`source="duckduckgo"`, and `results` (one or two objects with `title`, `body`,
`url`). Titles/snippets/URLs are bounded to 120/360/320 UTF-8 bytes per result,
and the entire canonical context is bounded to 1,500 UTF-8 bytes. Names and
supplied locality must match the retrieved evidence conservatively; empty or
ambiguous results are omitted. URLs exclude query strings/fragments.

Qwen v1/v2, Laya questions/state, and both categorizer Shortcut prompts identify
search results as untrusted business-type evidence. They cannot establish items,
gift intent, transfers or refund purpose. Original purchase/receipt evidence
takes priority. Qwen has a 3,072-token ceiling with web evidence and trims only
optional web snippets if needed. Laya uses 2,048/1,024 sequence/head budgets only
when web context is supplied, preflights the pinned tokenizer's actual state
budget, and trims web evidence before allowing any original evidence to be
truncated. If the primary evidence still does not fit, it abstains. Legacy
prompt/state/budget behavior remains unchanged without web evidence. The
audit retains the complete bounded input even when model-specific projections
trim optional snippets.

The exported Apple categorizer Shortcuts must be reimported after upgrading;
their built-in web search stays off. The selected Use Model action still controls
on-device versus cloud inference. Receipt sharing retains its separate consent;
web-context consent also authorizes forwarding the retrieved context to that
explicitly selected provider. All suggestions require review.

For reproducible baseline/enriched comparisons, prepare a local JSON case list:

```json
[{"id":"case-1","input":{"description":"PUBLIC MERCHANT","direction":"debit","currency":"CAD"},
  "merchant_context":{"version":"merchant-search-v1","source":"duckduckgo","results":[{"title":"Public merchant","body":"Previously captured business evidence.","url":"https://example.org/"}]},
  "expected":{"type":"expense","category":"shopping","review":true}}]
```

Run `python -m scripts.benchmark_merchant_context --package <verified-package>
--cases <cases.json> --output <new-results.jsonl>` with the appropriate pinned
model environment, or use `--shortcut <exact-name>` for an explicitly selected
Apple provider. This reuses production prompt/inference code and existing
evidence without performing searches. It compares type/category correctness and
latency per mode. Keep private cases/results under ignored `.private/`.
Small smoke comparisons do not establish classification accuracy improvement.

## Signing and isolation

Both app and XPC services are sandboxed. The inference service has no network, App Group
vault, iCloud, or Keychain entitlement. Native libraries are signed with the
service/app identity.

The free release is ad hoc-signed. Before requests can reach Python, the client
passes a transient read-only bookmark for its own app bundle. The worker accepts
only the enclosing app's exact path, verifies both bundle signatures, and sets
an XPC code-signing requirement for that app's code hash and identifier. A fresh
32-byte per-connection nonce protects against messages queued before that
requirement took effect. Requests with missing, guessed, or another connection's
nonce are rejected before model loading. The bookmark grant is released after
the identity check. This grants access to app code, not the ledger or home folder.

Apple-signed builds retain the same-team requirement. Ad hoc Debug builds now
use the same exact-host check as Release, replacing the former identifier-only
fallback. Unsigned or damaged bundles fail closed.

Ad hoc Release builds select `ClassifierService.AdHoc.entitlements`, which adds
a library-validation exception only to the sandboxed worker. CPython and the ML
libraries need it because ad hoc signatures have no shared Apple Team ID. The
main app keeps library validation and both targets retain hardened runtime.
Apple-signed Release builds default to the stricter service entitlement file.
Neither Release configuration enables `get-task-allow`. Ad hoc releases are not
notarized and do not establish a verified developer identity.

## Verification commands

```sh
.venv/bin/python -m pytest tests/test_worker.py tests/test_database_schema.py \
  tests/test_laya_runtime.py tests/test_constraints.py tests/test_runtime_v2.py -q

.local/macos/DerivedData/Build/Products/Debug/GroundKeeper.app/Contents/MacOS/GroundKeeper \
  --classifier-smoke

.local/macos/DerivedData/Build/Products/Debug/GroundKeeper.app/Contents/MacOS/GroundKeeper \
  --classifier-smoke --classifier-model-picker /absolute/path/to/model-package
```

The second model command opens the actual sandboxed picker. It checks a short
deadline, loads/verifies the selected package, classifies three fictional inputs,
releases the model and exits. GPU probe mode tests protocol errors, cancellation
and real Metal/MPS arithmetic. Run through a whole-process timeout in automation.
No private or sealed evaluation data is used.

## Local verification

Local development measurements (2026-10-17), through the actual app → sandboxed
XPC → embedded Python path, using one authored fictional merchant input three
times per model, while the existing independent Qwen training run continued:

| Package/backend | Prepare incl. file verification | First inference | Two warmed inferences |
| --- | ---: | ---: | ---: |
| Laya epoch 3 / MPS | 6.00 s | 2.49 s | 0.36 / 0.22 s |
| Qwen full-v1 step 512 / MLX GPU | 5.70 s | 4.13 s | 1.65 / 1.66 s |

Both runs passed GPU arithmetic, cancellation, protocol-error and short-deadline
checks, produced schema-valid review-required decisions, and released the model.
These are smoke measurements, not a controlled throughput benchmark or accuracy
evaluation; concurrent training and first-use compilation affect timing. The
model packages are historical experimental models, not newly selected production
checkpoints. Native logs are kept in the ignored `.local/macos/` workspace.

Those earlier model checks used Debug builds. The current free-release checks
are documented in [release maintenance](../../docs/releases.md). The release
workflow verifies the XPC connection without a GPU; full inference is a separate
local check. Native identity tests use disposable apps to reject a different
executable with the same bundle identifier, modified hosts, and unsigned code.

## Technical references

- [Apple XPC services](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html)
- [Apple cross-process file bookmarks](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [CPython isolated initialization](https://docs.python.org/3.12/c-api/init_config.html)
- [MLX Metal APIs](https://ml-explore.github.io/mlx/build/html/python/metal.html)

### Explicit Apple Shortcut provider

`prepare_shortcut` accepts `shortcut_name` (1–128 characters, no control characters).
It releases local GPU weights and returns the usual model identity with backend
`apple_shortcut`, device `shortcut`. `classify` uses the same job/revision/policy/
identity checks and strictly validated, review-required decision contract as local
inference. The bundled Python adapter invokes `/usr/bin/shortcuts` without a shell,
observes native cancellation and bounds response size. Errors expose safe codes
(`shortcut_unavailable`, `shortcut_rate_limited`, `invalid_output`, or
`deadline_exceeded`) rather than private input or dependency logs. No automatic
local/cloud fallback exists. Only Settings explicitly selects this provider.
