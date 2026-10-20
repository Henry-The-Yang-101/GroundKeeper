# Receipt OCR design and next steps

Start with native OCR on the phone and make image retention optional. Receipt
text is already enough to improve this project's Qwen classifier on the selected
pilot cases. Keep the photo when the user wants a receipt archive or the ability
to reprocess it later. The [pilot report](../experiments/receipts/RESULTS.md)
separates measured results from phone behavior that still needs testing.

## Capture and processing

1. Wallet and bank adapters call the shared writer. It offers Add receipt, Add
   note, or Skip adding receipt, followed by a choice to add the other detail.
2. A receipt uses Take photo or Choose image, then native GK Receipt OCR. Text
   only keeps recognized text; Keep image retains a JPEG without metadata.
3. The writer waits until all selected steps finish before writing schema 4
   payment JSON, with optional nested receipt and note. Cancellation/errors abort
   the capture. An optional image is saved immediately before JSON; a failed
   JSON save may leave an unreferenced image.
4. Attach Receipt Later selects an existing payment and writes a separate schema
   3 attachment referencing its source, app and event ID. Original captures are
   never overwritten.
5. The Mac imports payment and details atomically, links later attachments even
   when files arrive out of order, and retries optional image delivery. Notes
   appear in Notes & receipts and stay separate from editable ledger notes.
6. Receipt classification snapshots, cloud consent, category protection and
   monetary fields follow the existing rules. Captured notes remain local
   evidence and are not included in classifier input.

Apple documents a Wallet transaction trigger for a selected tapped card in its
[Shortcuts guide](https://support.apple.com/en-euro/guide/shortcuts/apd65c67538a/ios).
It does not establish that our camera/menu flow completes while locked. The
signed installers still need receiving-phone helper selection, folder setup,
and a physical-device test. See the [setup guide](../shortcuts/README.md).

## Storage and provider boundaries

The receipt envelope is limited to 64 KiB and OCR text to 32 KiB. Images are flat
relative references under `assets`, limited to 8 MiB and 40 megapixels, validated
as supported image data, and hashed from the actual bytes on the Mac. They are
stored as BLOBs in the existing vault; an encrypted SQLCipher vault therefore
protects both the image and its OCR. Capture JSON and optional images in iCloud
remain capture files, and are not deleted automatically after import.

Retaining only text saves space and avoids syncing a photo. It also means no
future re-OCR, visual evidence, or recovery of discarded layout. Retaining the
image supports those features, with the additional iCloud storage and sync cost.
The shipped choice is Text only by default, with explicit Keep image per capture.

Raw text is preserved locally. Classifiers receive at most 1,600 UTF-8 bytes of
context, with a hash and truncation indicator. Basic minimization removes known
payment/loyalty/URL lines and long numeric identifiers. This is not comprehensive
anonymization; OCR can still contain personal information. Qwen and Laya use the
excerpt locally. Apple Intelligence receives it only after a separate setting is
enabled; that setting defaults off. Images never enter classification requests.

All providers treat receipt text as evidence rather than instructions. Purchased
items can resolve an ambiguous merchant, but promotional text, refund policies,
payment identifiers, and receipt totals cannot override payment direction or
establish hidden intent. A mixed basket remains a reviewable shopping suggestion.
The classifier output contract remains exactly type, category, and review.

## Docling and other repositories

| Option | Where it fits | Decision for this flow |
| --- | --- | --- |
| Native Shortcuts OCR | Immediate text from a phone photo with no packaged OCR model | Implemented first; 20 actual Mac Shortcuts OCR runs completed |
| Native Vision document recognition | Local Mac reprocessing with text and document/table observations | Implemented; 100 images processed. Table observations are not yet normalized into receipt line items |
| [Docling](https://github.com/docling-project/docling) | Multi-format document conversion, layout, reading order, tables and structured export | Candidate for later PDF/invoice and line-item experiments; not a shipped dependency |
| [PaddleOCR](https://github.com/PaddlePaddle/PaddleOCR) | Alternative OCR and document parsing pipelines | Candidate if native OCR fails on the languages or images our users actually capture |

Docling supports images and PDFs and exports a unified document representation,
including JSON; its [format documentation](https://docling-project.github.io/docling/usage/supported_formats/)
and [repository](https://github.com/docling-project/docling) explain the scope.
It is broader than the single Shortcuts extraction action. That breadth does not
demonstrate better receipt transcription or category decisions on our data.

Docling also offers an `ocrmac` backend that wraps Apple Vision. Its
[OCR documentation](https://docling-project.github.io/docling/concepts/OCR_native/)
explains that this engine uses the recognizers supplied by macOS. Choosing Docling
therefore does not necessarily choose a different OCR engine. Its layout pipeline
can still change crops, order, and structured output. A useful future comparison
must name the backend, model artifacts and settings, rather than compare the
product names alone. This pilot did not install or benchmark Docling.

For PaddleOCR, evaluate the current PP-Structure pipeline rather than copying
legacy PP-StructureV2/KIE examples: the maintainers explicitly describe the
[upgrade path](https://github.com/PaddlePaddle/PaddleOCR/blob/main/ppstructure/README.md).
Both alternatives add runtime/model distribution and licensing work. Neither
replaces GroundKeeper's event linking, reconciliation, taxonomy or human review.

Before adding an engine, compare the same retained images against native OCR and
published or independently corrected transcripts. Score line items, amounts,
reading order, latency, memory, and classification changes separately. Use a new
held-out Canadian sample with blur, thermal fading, French/English, long baskets,
skew, glare, and mixed purchases. Keep this pilot out of training and prompt tuning.

## Features enabled by retaining receipt evidence

These are follow-on proposals, not implemented receipt analytics:

| Feature | Additional work and boundary |
| --- | --- |
| Find a purchase by item or receipt text | Local searchable OCR index with item snippets and links to the original receipt |
| Return and warranty reminders | Extract explicit dates/terms into reviewable fields; retain the image and source spans |
| Suggested category splits | Structured line items, discounts/tax allocation, and sum reconciliation; user confirms every split |
| Total, tip and tax comparison | Compare extracted fields with the recorded payment; flag discrepancies instead of changing money automatically |
| Better merchant names and reconciliation | Propose aliases or matches using explicit receipt evidence; do not apply one purchase's purpose to every merchant transaction |
| Item price and household spending history | Normalize products, quantities and units; account for discounts, returns and uncertain OCR |
| Receipt export for reimbursement | User-selected records with images and reviewed amounts; no automatic external sharing |

The next practical step is to finish the phone acceptance checks, then collect a
small independently labeled local sample. The current pilot supports receipt
context for Qwen and the selected Apple Cloud configuration. It does not support
promoting the existing Laya model to a default, nor claiming that OCR alone has
produced trustworthy item-level accounting.
