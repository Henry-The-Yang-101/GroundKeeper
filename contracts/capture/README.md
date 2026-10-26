# Transaction details and receipt capture events

Valid mapped Wallet and bank payment captures create actual ledger transactions
immediately. The app does not wait for a statement import or claim to track bank
settlement. Category suggestions still require review. Incomplete captures and
ambiguous duplicate matches stay in Sync for correction or reconciliation; CSV
imports remain an optional source of history and matching evidence.

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
The iCloud transport copy is removed after the Mac verifies durable vault storage.

The schema 4 phone writer collects optional details before saving payment JSON.
Cancellation or failure in a selected step aborts that capture. Explicit Skip
saves without a receipt. Retained images are saved immediately before JSON; a
final JSON save failure can leave an unreferenced image because Shortcuts has no
transaction spanning two files. Image delivery can lag JSON; image download is
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
of a receipt. Jobs snapshot receipt input and context version/hash.

The Apple Shortcut provider receives receipt text only after the separate
`receipt_cloud_consent` setting is enabled. This setting is checked when the job
is claimed, including by the background agent. The selected Shortcut may use
cloud inference; local providers do not fall back to it.

## Optional Wallet category evidence

Wallet payment payloads may include `wallet_category_raw`. This optional text
is accepted without a schema migration or new observation/transaction column;
the value is retained solely in the original `raw_event_payloads.payload_json`.
Classification reads active links to non-test `apple_wallet` events. A usable
hint must be a nonblank string of at most 128 UTF-8 bytes with no ASCII control
characters. Missing, null, empty, non-string, oversized or conflicting hints
are ignored without rejecting the payment. Bank payloads cannot supply a Wallet
hint. Multiple valid linked Wallet hints must agree exactly.

The inference request includes `wallet_category_raw` only when usable.
`classification_runs.input_json` instead records
`wallet_category_source_event_id`; `input_sha256` hashes the actual request,
including the hint. To reconstruct that request, replace the source reference
with the original payload's `wallet_category_raw`. The audit does not duplicate
the category value. Existing captures without hints keep the existing flow.
This supplies evidence for future jobs; it does not reclassify completed jobs.

Shortcuts does not expose Category in the inspected transaction property picker.
The adapter leaves its optional entry blank; a category-filtered iPhone
automation can explicitly supply its filter label. See the
[setup guide](../../shortcuts/README.md#optional-wallet-category-hint).

## Schema 4 payments

Schema 4 retains the schema 2 payment fields and adds optional `note` (nonblank,
NUL-free, at most 10,000 UTF-8 bytes) and `receipt` (the same nested OCR/image
payload as schema 3). Missing fields mean the user did not add that detail. A
malformed supplied detail rejects the whole envelope. The payment, captured note
and receipt rows commit together. No separate phone receipt event is necessary
for details added during the initial capture. Later attachments remain schema 3.

The Shortcut uses conservative character limits before saving: 2,000 for notes,
8,000 for OCR and 16,000 for serialized JSON. The importer enforces byte limits.
Captured notes remain immutable source evidence and are copied once into editable
transaction notes. **Notes & receipts…** can edit or clear them. A bounded note
excerpt is included in classifier requests.

Names follow `<description>_<app>_CAPTURE_<yyyy-MM-dd_HH-mm-ss-SSS>.json`, using
the merchant/subtitle and source app. Unsafe filename characters and spaces are
underscores; description/app components are each limited to 60 ASCII characters.
The timestamp is local capture time. The envelope retains its offset-bearing
`captured_at` and unique event ID. Names are descriptive only: import, replay,
receipt association and matching use payload identity. See `payment-details-example.json`.


After successful ingestion, the Mac acknowledges the queue by deleting matching
JSON and image copies from iCloud. The payload, note, OCR and retained image bytes
remain in the local vault. Deletion retries after interruption or access failure;
invalid files are retained. Existing folder connections need read/write access.
Receipt images can also be added or removed in **Notes & receipts…** on the Mac.


## Optional captured location

Schema 4 accepts an optional `location` object with numeric `latitude` (-90…90)
and `longitude` (-180…180), optional `horizontal_accuracy_m` (0…10,000,000),
optional offset-bearing ISO 8601 `measured_at` (defaults to `captured_at`), and an
optional NUL-free `label` of at most 500 UTF-8 bytes. Coordinates must be finite.
Invalid supplied locations reject the entire capture. Location evidence is saved
atomically in `geotags` against the immutable event and follows active transaction
links. Replayed deliveries do not duplicate it. No database migration is needed;
these tables have existed since migration 001.

The optional `location_status` is `not_requested`, `available`, `denied`,
`unavailable`, or `timeout`. `available` requires coordinates; the other statuses
require absent/null `location`. With no status, the importer infers `available`
when coordinates exist, otherwise `not_requested`, preserving older producers.
The resolved status is stored in `raw_events.location_status`. Schema 1/2 do not
accept location details or status.

The bundled writer requests one current location before any receipt/note menus,
then emits numeric coordinates and an ISO 8601 `measured_at` recording when the
action returned. It omits accuracy because the inspected native location details
action does not expose measured horizontal accuracy. The Wallet and CIBC adapters
default `capture_location` to `on`; set it to `off` to skip the request. Receipt
attachments do not sample a new location for an earlier payment. Empty location
output records `unavailable` and continues. Native Shortcuts permission/GPS errors
can stop the workflow before saving; they cannot be caught by these actions.
Grant Shortcuts location access on the phone before enabling capture, or opt out.

The Mac does not infer locations from merchants, receipt metadata, or its own
current position. The map says **Phone location at capture** and shows the sample
time. A delayed bank alert can locate the phone after the purchase. Coordinates
remain outside classifier requests. They are present in the iCloud queue JSON
until normal verified ingestion/cleanup, then in the encrypted vault. Existing
transactions without coordinates cannot acquire a historical location from this
update. Real iPhone GPS, permissions and Wallet-trigger delivery require a device
check; native Mac action/serialization checks do not establish those behaviors.

## Viewing transactions and adding images on Mac

Click a transaction once to open **View transaction**, including notes, any
recorded location in Apple Maps, and attached receipt images. **Edit** opens the
transaction editor. The table has separate **Type** and **Additional data** columns;
the latter shows location, note and stored receipt-image symbols when present.
Pending, text-only and removed receipts do not claim that an image is attached.

The editor offers **Photos**, **Files…**, and **Take photo…**. Each route opens a
crop preview before staging the attachment. The shared encoder bakes orientation,
flattens transparency onto white, strips image metadata, and writes JPEG at no more
than 8 MiB. Sources are bounded to 128 MiB and downsampled to at most 6,000 pixels
on the longest edge before cropping; quality and dimensions reduce further if
needed. Camera access is requested only when the camera sheet is opened.

Receipt additions and removals commit atomically with transaction fields on
**Save transaction**. **Cancel** discards staged changes. **Remove receipt** hides
the evidence from the viewer and classifier context; the original bytes remain
in vault history under the existing reversible-removal policy. The older
**Notes & receipts…** sheet uses the same import/crop pipeline and applies changes
immediately. OCR failure does not prevent attaching a readable image.
