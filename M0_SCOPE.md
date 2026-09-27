# M0 scope and spike results

Status: **open** (2026-09-27). This document treats the iOS notification and Wallet transaction automations as working triggers, as requested. It does not treat their output fields or delivery under every phone state as verified. M0 ends when the raw input contract, CIBC corpus, model decision, Secure Enclave design, and unattended Mac access are recorded with reproducible evidence. M1 then builds the capture shortcut.

## Input contract from the screenshot

The upper card is the CIBC Banking app's push. The lower card is the Apple Pay/Wallet card notification; it should not be counted as a second CIBC Banking push. Apple's notification UI provides a system app header separately from the content's `title`, `subtitle`, and `body` ([notification UI](https://developer.apple.com/documentation/usernotificationsui/customizing-the-appearance-of-notifications), [content properties](https://developer.apple.com/documentation/usernotifications/unnotificationcontent)). The most likely field mapping is:

| Displayed text | Tentative field | Confidence |
| --- | --- | --- |
| `CIBC Banking` beside the app icon | app/display name | High; it is the system header, not the payload title |
| `CIBC Dividend Visa Card, 9***` | notification title | Likely |
| `PRESTO MOB/...` | notification subtitle | Plausible, but it could be part of a multiline body |
| `$20.00` | notification body/message | Plausible, but only raw Shortcut Input can prove the split |
| `CIBC` + Wallet badge; `PRESTO`; `$20.00` | Wallet app/card label; likely title; likely body | Visual inference only |

**Do not parse from visual line position.** Save the exact automation input fields separately, including empty strings and nulls. If Shortcuts exposes only combined text, store that unmodified with an explicit `input_shape` value and parse it on the Mac. `app` must be separate from `title`. Do not put the real screenshot, full card number, merchant token, or raw financial notifications into Git.

Provisional raw event shape for the M0 capture experiment (not the final database schema):

```json
{
  "schema": 1,
  "source": "bank_notification",
  "app": "CIBC Banking",
  "captured_at": "<ISO-8601 with offset from Current Date>",
  "title": "CIBC Dividend Visa Card, 9***",
  "subtitle": "PRESTO MOB/<redacted>",
  "body": "$20.00",
  "input_shape": "separate_fields",
  "raw_input": null
}
```

The example is redacted and reconstructed from the image, **not** a captured Shortcut payload. The Wallet shape should keep raw `Amount`, `Merchant`, `Name`, and `Card or Pass` values in separate fields. The Mac parser will derive signed cents, currency, merchant normalization, and card identity later.

## Completed temporary experiments

The experiments ran outside the repository in `/tmp/gk-m0-spike/`; no transaction database or production key was created. The test corpus contains 12 hand-labelled merchant strings, including one PRESTO-like example. It is a small synthetic diagnostic, not a measured sample of this user's spending.

### Laya on the M4 Pro

- `laya==0.3.11`, `torch==2.14.0`, Python 3.11.14; English checkpoint `convaiinnovations/laya` at revision `55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851`.
- `laya.load(local_checkpoint, device="mps")` worked. `torch.backends.mps.is_available()` was true, the agent and first model parameter were on MPS, and PyTorch reported 1,688,613,632 bytes allocated through MPS. This was with MPS CPU fallback **unset**. A temporary user LaunchAgent also completed one inference on MPS and exited 0.
- For the same 12 inputs and ten-category question, warmed median batch time across three repeats was 0.398 seconds on MPS versus 0.735 seconds on CPU. CPU and MPS selected the same 12 labels. The first MPS batch took 2.315 seconds, so the plan's claim that a day's classification is necessarily under one second should distinguish warm inference from process/model startup.
- Zero-shot top-label agreement with the hand labels was **3/12** for the plan's ten categories on raw strings, **4/12** after minimal normalization, **4/12** for a nine-category forced choice, and **4/12** for nine categories with a short purchase context. In the ten-category raw run, only 1/12 answers reached 0.6 on Laya's entropy-based `confidence` field. PRESTO was labelled `other`, and `SQ *BLUE BOTTLE` was also labelled `other`. The exact cases and a follow-up on Laya 0.3.21 are in [research/LAYA_FINDINGS.md](research/LAYA_FINDINGS.md).
- The package emitted a warning about the checkpoint's invalid `choice:11+` temperature. These experiments used nine or ten choices, so that specific bucket was not used. The observed low accuracy still means **0.6 is only a provisional review threshold**, not an acceptance guarantee. Laya's own model card advises calibrating probabilities on task data ([model card](https://huggingface.co/convaiinnovations/laya)).

**Decision:** MPS deployment is technically viable on this Mac, including a user LaunchAgent. Do not approve raw-string Laya as an unattended categorizer yet. M2 should use explicit merchant rules/normalization first and send unrecognized cases to review. Re-evaluate the model on a representative, privately labelled real corpus; consider a simpler rule baseline before expanding prompt work. The follow-up found that input/schema changes can produce highly confident wrong answers, so no fixed confidence gate is approved yet.

### Touch ID / Secure Enclave

- `SecureEnclave.isAvailable` and biometric availability were true on this Mac.
- An **ad hoc signed** Swift command-line binary created a `SecureEnclave.P256.KeyAgreement.PrivateKey` protected by `[.privateKeyUsage, .biometryCurrentSet]`. It derived a symmetric key with P-256 ECDH and HKDF, AES-GCM-wrapped a temporary 256-bit data key, reloaded the Secure Enclave key representation, and opened the wrapped key successfully. The binary had no Apple developer team or entitlement, so a paid/team signature was not required for this local proof of concept.
- Use **KeyAgreement**, not `SecureEnclave.P256.Signing`, for wrapping. The enclave cannot import the existing database key as a private key; the helper should generate an enclave key and store its opaque representation, an ephemeral public key, and AES-GCM ciphertext/tag in the Touch ID slot. Apple's API supports P-256 key agreement and a reloadable data representation ([key agreement](https://developer.apple.com/documentation/cryptokit/secureenclave/p256/keyagreement), [reload initializer](https://developer.apple.com/documentation/cryptokit/secureenclave/p256/keyagreement/privatekey/init%28datarepresentation%3Aauthenticationcontext%3A%29)).
- `.biometryCurrentSet` binds access to the currently enrolled fingerprints; adding or removing one invalidates this slot ([Apple documentation](https://developer.apple.com/documentation/security/secaccesscontrolcreateflags/biometrycurrentset)). Password and recovery-key paths remain mandatory.
- A separate-process reopen of a persisted test wrapper did **not** finish after several minutes and was stopped. The create process wrote a 1,046-byte wrapper, but the reopen process produced no result. An authentication prompt may have been pending; this run cannot establish why it waited. That persistence/UI behavior is a remaining M0 check. A signed helper invoked by the eventual Python backend has not yet been built.

### launchd and iCloud

A temporary user LaunchAgent proved MPS inference works outside the shell. Its service was removed after the test. An attempt by a second temporary LaunchAgent to enumerate the existing Shortcuts iCloud Documents directory did not complete promptly and was stopped. The `GroundKeeper/queue.noindex` directory does not yet exist, and there has been no Full Disk Access grant for a production interpreter/helper. **iCloud queue access under launchd is unresolved**; the hanging read alone does not establish a TCC cause.

## Remaining M0 work and stop checks

1. **Capture the exact raw fields from one real push and one Wallet tap.** Record the Shortcuts input type and each value (`app`, `title`, `subtitle`, `message/body`, Wallet `Amount`, `Merchant`, `Name`, `Card or Pass`) without converting them to display text. Verify whether the merchant and amount are separate fields, whether an absent subtitle is null or empty, how Amount represents currency and sign, and whether the captured time has an offset. Run once unlocked and once locked if payload availability may differ. Pass: a redacted fixture and a field mapping based on the actual Shortcut output, not this screenshot.
2. **Build the CIBC format corpus.** Privately collect about ten *real* alert payloads spanning purchase, refund, e-Transfer/deposit, decline, different cards, long/truncated merchants, and any French or foreign-currency format that actually occurs. Keep originals out of Git; save redacted/minimized fixtures under `tests/fixtures/` with expected direction, amount/currency, merchant, and card last-four. Pass: each observed format has a fixture, and unknown formats are explicitly listed for review rather than invented.
3. **Settle the model decision.** Label a representative set of real merchant strings and compare raw Laya, normalized Laya, and a deterministic merchant-rule baseline. Report top-1 accuracy, review coverage at the chosen threshold, and errors by category. Keep the model revision pinned and verify device **after** inference because Laya can fall back internally on some errors. Pass: a written choice of model/rules/review policy with an acceptable error rate for this data; otherwise use rules plus review in M2.
4. **Finish the Touch ID persistence test.** Repeat the separate-process unlock with the user present to respond to any macOS prompt, with a bounded timeout and clear cancellation result. Then test the helper's `create`, `wrap`, and `unwrap` subprocess protocol using only temporary keys, including an authentication cancellation. Do not test fingerprint-set invalidation by altering the user's enrolled fingers. Pass: ad hoc signing, persistence, biometric access, and fallback behavior documented; if persistence fails, defer Touch ID to M7 as PLAN.md allows.
5. **Verify unattended iCloud access.** Create a harmless test file in the intended queue only once the capture directory exists, invoke a user LaunchAgent with the exact interpreter/path and environment planned for production, and check read access and a clean timeout. If macOS denies access, grant the minimum workable permission through System Settings and retry. Pass: the job reads the test file and records its result without logging file contents. The nightly schedule itself is an M5 endurance test, not an M0 requirement.

M0 is complete when these results are saved, the bank-source field mapping is decided, the corpus is available as private originals plus safe fixtures, and the unresolved iCloud/Touch ID gates have explicit pass or defer decisions. Trigger existence is an assumption supplied for this exercise, not a measured result of these Mac-side spikes.
