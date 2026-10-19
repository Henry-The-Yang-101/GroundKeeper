# Native Apple Private Cloud Compute

The Mac app uses `FoundationModels.PrivateCloudComputeLanguageModel` directly
from Swift on macOS 27+. It does not run a classifier Shortcut, invoke a CLI,
or send Apple inference through Python. Qwen and Laya alone use the bundled
Python/XPC worker. iPhone capture still uses Shortcuts.

## Availability and signing

Apple's [PCC access requirements](https://developer.apple.com/private-cloud-compute/)
currently require an eligible App Store Small Business Program developer, fewer
than two million first-time App Store downloads, and Apple's assigned managed
`com.apple.developer.private-cloud-compute` entitlement. User Apple Intelligence
availability alone does not authorize a third-party app to call PCC.

After Apple approves the capability, enable it for the GroundKeeper App ID and
regenerate its provisioning profile. Use `GroundKeeper.PCC.entitlements`, which
includes the existing sandbox and protected Keychain requirements plus PCC:

```sh
GK_APP_ENTITLEMENTS=GroundKeeper.PCC.entitlements ./apps/macos/run.sh
```

For direct Xcode builds, set `GK_APP_ENTITLEMENTS = GroundKeeper.PCC.entitlements`
in `.local/macos/Signing.xcconfig`. The normal launcher defaults to the Keychain
profile; the environment override above opts into PCC provisioning. Adding a key
to an entitlements file does not grant Apple approval. No team ID or credentials
are committed, and the existing local signing configuration is not changed.

The default and free ad hoc builds remain buildable without the managed
entitlement. They explain why PCC is unavailable and offer local models/manual
categorization. Apple's supported ad hoc testing distribution uses an approved
profile; it is different from this project's free `codesign --sign -` release.

## Usage and knowledge

Apple's [native integration documentation](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute)
describes a daily allowance for the person using the device and increased access
through iCloud+. GroundKeeper reads the framework's quota status and reset time,
and shows Apple's access-options button only when the framework offers one.
There is no developer-supplied API key or GroundKeeper billing account.

The public macOS 27 Swift interface has no equivalent to the Shortcuts action's
**Broad World Knowledge** switch. Native PCC uses Apple's server model with a
merchant-categorization prompt; this implementation adds no web-search tool and
does not claim the same behavior as that Shortcuts setting. Apple manages server
model updates, so the recorded identity describes the API, prompt, policy and
OS build, not a fabricated model-weight hash.

## Data and queue behavior

- Each transaction gets a fresh session containing only description, direction,
  and currency. Descriptions are bounded and treated as untrusted data. No
  amount, account identifier, location, or other transaction history is sent.
- Guided generation restricts type/category vocabulary. Swift validates the
  allowed combinations and always sets `review=true` before saving a result.
- Existing revision, confirmation and idempotency checks still govern writes.
  Pending jobs are superseded when the user changes providers; history remains.
- The app checks availability and quota before claiming work. Daily quota
  exhaustion stops automatic attempts; a request that encounters exhaustion
  is retained as failed work for explicit retry after reset or an access change.
  Network, temporary service and rate-limit failures use bounded queue backoff.
- Cancellation propagates to the framework and releases the queue job. A
  60-second watchdog cancels a slow generation task. Stopping local work cannot
  guarantee that Apple has not already processed a dispatched request.
- Errors stored or displayed by GroundKeeper use fixed messages/codes, never
  framework debug descriptions or transcripts.
- Local providers never fall back to PCC. Previously saved Shortcut selections
  migrate to manual mode with an explanation and require an explicit new choice.

## Verification

The native provider builds with Xcode 27. Swift core tests cover input boundaries,
policy validation, review enforcement, provider switching, cloud provenance and
quota-failure retry behavior. Python worker tests reject `prepare_shortcut` and
advertise only `qwen_mlx`/`laya_mps`. Historical Shortcut benchmark scripts remain
in the repository but are not bundled into the app's worker.

The disposable app smoke runs with:

```sh
/path/to/GroundKeeper.app/Contents/MacOS/GroundKeeper --setup-preview --pcc-smoke
```

It checks old-provider migration, cancellation before dispatch, rejection of cloud
requests by the Python client, sanitized quota/network errors, and the missing
entitlement gate. Add `--pcc-live-smoke` in an approved build to send one fictional
cafe description through PCC. Current local validation has no approved PCC
entitlement, so it cannot establish a successful server prediction, real quota
behavior, or categorization accuracy. No real financial data was sent in testing.
