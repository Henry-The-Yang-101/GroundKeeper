# Bundled classifier bridge

**App integration update (2026-10-17):** The Swift app now owns a local SQLite
ledger, durable classification jobs and review-required assignments. See the
[application integration](../database/IMPLEMENTATION.md). The original bridge
diagnostics and historical smoke measurements below remain useful in isolation.

GroundKeeper's native app calls `com.groundkeeper.macos.classifier`, an embedded
XPC service. A native Objective-C host embeds CPython; Python/MLX/PyTorch never
load in the UI process. Swift owns SQLite and application state. This bridge
does not connect the disposable UI transactions to a database.

## Build and run

On Apple silicon, with the pinned local source environments already installed:

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

In Settings → Local classifier diagnostics, check GPU support, select an exported
model package, classify explicitly entered fictional text and release the model.
No sample result is written to transaction storage. Automatic categorization,
Apple cloud invocation, Council orchestration and durable job scheduling remain
Swift application integration work.

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
| `classify` | `job_id`, `part_id`, `transaction_revision`, `policy_version`, `model_manifest_sha256`, `input` | Decision, actual model identity and echoed job/part/revision. |
| `release_model` | None | Releases model references and backend allocator caches. |

Classifier input is exactly `{description,direction,currency}`, including explicit
JSON null for unknown currency. Description is bounded to 2048 characters; Qwen
also rejects prompts over 512 tokens. No account identifier, amount, geotag or
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
handshake and prepare again. The future Swift job coordinator must persist
jobs/attempts, use bounded retry policy and commit results idempotently only
when the database revision/current assignment still permits them. This bridge
does not itself write to SQLite or promise exactly-once inference.

## Signing and isolation

Both app and XPC service are sandboxed. The service has no network, App Group
vault, iCloud or Keychain entitlement. It authenticates its native peer by app
identifier and the same Apple signing team in Release. Native libraries are
signed with the service/app identity; Release retains library validation.

Local Debug builds use ad hoc signatures with no Team ID. Debug therefore has
an explicit library-validation exception and a peer-identifier-only requirement.
Those development exceptions do not apply to Release. This Mac has no valid
distribution signing identity configured, so notarized/same-team hardened
distribution cannot be claimed from the local development smoke tests.
Release also disables Xcode's injected debugging entitlements; its service has
neither `get-task-allow` nor the library-validation exception.

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

The full Python suite passed 97 tests. Debug and Release builds passed, and both
app bundles passed deep/strict code-signature verification. GPU/model inference
was verified in the local Debug configuration; same-team hardened Release
execution and notarization require a configured distribution identity.

## Technical references

- [Apple XPC services](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html)
- [Apple cross-process file bookmarks](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [CPython isolated initialization](https://docs.python.org/3.12/c-api/init_config.html)
- [MLX Metal APIs](https://ml-explore.github.io/mlx/build/html/python/metal.html)
