# Receipt context pilot — October 20, 2026

On these deliberately selected cases, receipt text substantially helped Qwen and
the selected Apple Cloud model. It did little for the existing Laya package.
Native OCR is sufficient to continue with this design; there is no measured
reason here to add Docling to the shipped runtime.

## Dataset and method

Downloaded 100 public SROIE receipts and their published OCR/key annotations,
from a pinned mirror, with content hashes and dataset attribution in the
[manifest](results/sroie-100-manifest.json). The images remain under the ignored
`.local/receipts/sroie-100`, approximately 48.6 MB. No personal transactions were
used and none of these cases entered model training.

The [20 cases](cases.json) were fixed before model runs. They cover unfamiliar
legal company names, fuel and parking, prepared meals, general retail containing
batteries, stationery versus education, a pharmacy selling crisps, medicine,
payment identifiers, refund-policy footers and promotional income language.
Expected categories are agent-reviewed policy expectations based on the
published transcripts. They are not independent human labels or a random sample.
Payment direction was debit and currency unspecified for every classification.
Ingestion used separately identified fictional CAD 1.00 payments, not converted
Malaysian totals.

Each local model received the same description-only input, then actual OCR
context, then the published reference text as context. Reference categories were
never sent to a classifier. The Apple Cloud comparison used only description and
actual OCR, limiting it to 40 calls. Errors count as misses. All suggestions were
forced to review by the production worker. Cases were not used to tune weights,
category rules, or prompt instructions. Context minimization was revised during
implementation; changed inputs were re-evaluated and reports use the latest
record for each exact case/variant. Raw inputs, hashes and responses remain in
the ignored working directory.

This compares the existing description path with the implemented receipt path,
including receipt-specific instructions and input capacity. Qwen's prompt limit
is 512 tokens without a receipt and 2,048 with one; oversize prompts fail instead
of being silently accepted. Laya's sequence/head limits change from 512/384 to
1,024/768 and its receipt path adds an explicit OCR evidence field and questions.
Weights are unchanged. This is not an ablation that holds every prompt token
and runtime setting fixed while adding text.

## Actual Shortcuts OCR and classification

The installed GK Receipt OCR used Apple's Extract Text from Image action on the
Mac, invoked through the real `shortcuts` CLI. It completed 20/20 images. Earlier
locked-Mac timeouts were retained in the raw log; the table uses the completed
runs after unlocking.

| Provider | Description only | With actual Shortcuts OCR | With published transcript |
| --- | ---: | ---: | ---: |
| Qwen, `qwen-delaware-v1-step5872` | 10/20 | 19/20 | 19/20 |
| Laya, `laya-epoch3` | 4/20 | 5/20 | 6/20 |
| Apple Intelligence, selected Cloud model | 8/20 | 19/20 | Not run |

These are category matches; joint type/category counts are identical. Apple's
baseline included one `invalid_output` failure, on case 060; 19/20 baseline calls
returned valid results and 20/20 OCR calls did. Among the 19 cases with a valid
baseline response, Apple matched 8/19 without OCR and 18/19 with it. The result is
for Cloud, not the on-device Apple model or the entitlement-gated native PCC API.

The selected Cloud model, Text output, disabled Follow Up, and disabled broad
world knowledge toggle were inspected in the native editor. Receipt instructions
were inserted while preserving the input variable and current model selection.
The prompt retains the existing merchant-knowledge sentence; the UI knowledge
toggle remained off throughout this run. Apple does not expose an immutable
model-weights identity here. The worker's manifest hash identifies the adapter
configuration, not a cryptographic hash of Apple's model or the live Shortcut's
editable prompt. Qwen and Laya package identities, per-case inputs' hashes,
decisions and safe errors are in the [machine-readable report](results/2026-10-20-shortcuts.json).

Qwen corrected nine cases with no regressions in this sample. Apple corrected
eleven, including the baseline error, with no regressions. Both still missed
case 421: the pharmacy sold Pringles, whose abbreviated line was insufficiently
used to select groceries. Qwen abstained as uncategorized; Apple chose shopping.
Laya corrected two cases and regressed on grocery control 060, incorrectly
predicting a refund. It also incorrectly predicted balance adjustment for a
hardware receipt. Its current weights are a poor fit for this sample, and adding
text does not make it a reliable default. No provider is silently substituted.

## OCR quality and time

Environment: Apple M4 Pro, macOS 27.0.1 (26A434). These are Mac measurements,
not iPhone capture latency or iCloud delivery time.

| OCR path | Completed | Median selected-20 time | Mean token F1 | Mean normalized character error rate |
| --- | ---: | ---: | ---: | ---: |
| Actual Shortcuts action + CLI | 20/20 | 486.7 ms | 0.8987 | 0.2759 |
| Production native Vision document reader | 20/20 | 198.5 ms | 0.8985 | 0.2761 |

The native reader also completed all 100 images, with a 203.7 ms median OCR time.
That time excludes process launch; Shortcuts timing includes CLI overhead. This
is not a controlled engine-speed comparison. Character error rate is sensitive
to reading order, annotation differences, and normalized whitespace. Token F1
ignores order and is useful for category context, but does not measure whether
prices are aligned with the correct items. Neither metric establishes reliable
item-level accounting. Native OCR produced the same local-model category scores
as Shortcuts OCR on the selected 20; see the
[native report](results/2026-10-20-native.json) and
[100-image summary](results/2026-10-20-native-100.json).

## Integration verification

- 132 Python tests and 24 Swift core tests passed. The Swift suite covers existing
  vault migration, out-of-order linking, replay/collision handling, OCR revisions,
  stale jobs, user-category preservation, cloud consent, and image encryption.
- Native imported writer actions emitted a numeric schema 2 payment. An isolated
  receipt check used the same production actions with helper calls inlined and
  Save File omitted. It emitted numeric schema 3, nested target/receipt/OCR
  dictionaries and actual OCR text. A second check exercised JPEG conversion,
  hashing and the nested `assets/<hash>.jpg` image reference.
- The Mac importer accepted the native receipt output: one payment, one linked
  receipt, one classifier context, no quarantine, and valid database integrity.
- The 20-case ingestion test imported 40 payment/receipt files in reverse arrival
  order into an isolated encrypted temporary vault. It produced exactly 20
  purchases, 20 receipts, 20 stored images and 20 receipt-aware jobs, with no
  quarantine. These ingestion decisions were explicit fixtures, not predictions.
- A correctly signed sandboxed app copy exercised a fictional receipt through
  the real queue, ClassifierClient, XPC worker and Qwen model, then committed a
  valid reviewable result. One purchase remained and the vault integrity check
  passed. Its category was shopping; this smoke check verifies transport and
  persistence, not accuracy on the fictional basket.
- The app's incremental build originally copied new worker code with a stale XPC
  resource seal. The build now copies the complete signed worker product and
  verifies its seal. Deep strict signature verification and a repeated incremental
  build passed. The peer-identity checks were preserved.
- All eight signed Shortcut exports were unpacked and compared with their
  reviewed plist sources, allowing only Apple's signing metadata normalization.

The raw fixture vaults were isolated from the live ledger. The saved
[ingestion report](results/2026-10-20-ingestion.json),
[native envelope report](results/2026-10-20-native-envelope-ingestion.json), and
[signed app check](results/2026-10-20-app-integration.json) describe each surface.

## Still requires a phone

The physical Apple Pay trigger, camera/photo permissions, cancellation, locking,
helper chaining, image Save File destinations and iCloud arrival were not tested
on an iPhone. Nested Run Shortcut execution stalled on this Mac, including after
selecting installed helpers; inlining the actions allowed serialization and OCR
to be checked separately. Follow the [setup guide](../../shortcuts/README.md),
select every helper target on the receiving phone, and verify those interactions
before relying on unattended capture. Existing installed capture folder settings
and personal Wallet automations were not replaced during this pilot.

Docling was researched, not benchmarked. On-device Apple Intelligence was not
retested. The next evaluation should use an independently labeled Canadian
sample, with merchant-separated cases and realistic phone photos. The current
20 cases deliberately favor situations where receipt context could matter.
