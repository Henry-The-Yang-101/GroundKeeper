# Receipt capture events

Schema 3 receipt attachments are independent immutable JSON files in the same
inbox as schema 1/2 payments. They do not amend a payment file or create a monetary
transaction. See `receipt-example.json` for fictional data.

`target` identifies the original capture by its source (`wallet_transaction` or
`bank_notification`), exact app name and `event_id`. The importer derives the same
source identity as the payment parser. Explicit parent identity, not a guessed
merchant/amount match, links the receipt when that capture has a reconciled
transaction. Unresolved receipts wait durably. Test receipts cannot enrich live
transactions. A repeated ID with different bytes is quarantined.

The envelope must fit in 64 KiB, including JSON escaping. OCR text must fit in
32 KiB of UTF-8 and contain no NUL. Producers are `apple_shortcuts`,
`apple_vision`, `apple_vision_documents`, or `user_text`. Empty text requires an
image. Images are optional references under `assets/` with an opaque filename
and JPEG/PNG/HEIC extension; never absolute paths, nested traversal, or base64.
An optional image `sha256` must describe the actual stored bytes. Without one,
the Mac computes it. Images are limited to 8 MiB and 40 million pixels, validated
by ImageIO, and stored as BLOBs inside the local vault. SQLCipher consequently
protects retained images when the vault is encrypted. Plain vaults remain plain.
The iCloud transport copy has its existing iCloud protection and is retained.

The phone saves the payment before receipt UI. Cancellation therefore cannot
remove an already saved payment. Image delivery can lag JSON; image download is
retried independently and text remains available. Invalid assets can be retried
with the app's Retry failures action. An image with empty phone OCR is read
locally on the Mac when imported. Reading it again creates a versioned OCR run.

Classifier context is a stable `receipt-context-v1` projection of the latest OCR
for each attached receipt. At most 1600 UTF-8 bytes are passed, with a truncation
flag and hash of the full original text. Payment/loyalty marker lines and long
numeric identifiers are removed from this excerpt. This is minimization, not a
guarantee of complete PII removal. Raw evidence stays in the vault. No image,
account identifier, receipt total, or financial history goes to the classifier.

Receipt evidence increments the transaction revision and invalidates stale
jobs. Unconfirmed model suggestions can be revisited; user-origin assignments
and confirmed categories are preserved. Monetary fields never change because
of a receipt. Jobs snapshot the exact input and context version/hash.

The Apple Shortcut provider receives receipt text only after the separate
`receipt_cloud_consent` setting is enabled. This setting is checked when the job
is claimed, including by the background agent. The selected Shortcut may use
cloud inference; local providers do not fall back to it.
