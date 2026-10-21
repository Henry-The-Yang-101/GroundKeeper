# Apple Shortcuts setup

GroundKeeper uses Shortcuts for two separate tasks: capturing transaction events
on iPhone, and optionally classifying descriptions with Apple Intelligence on
Mac. Local Qwen and Laya classification do not require Shortcuts.

## Included installers

| File | Purpose |
| --- | --- |
| [GroundKeeper Capture Transaction.shortcut](GroundKeeper%20Capture%20Transaction.shortcut) | Shared iPhone capture writer |
| [GroundKeeper Wallet Automation.shortcut](GroundKeeper%20Wallet%20Automation.shortcut) | Wallet transaction adapter; pass automation input |
| [GK Receipt OCR.shortcut](GK%20Receipt%20OCR.shortcut) | Local Apple Extract Text from Image action |
| [GroundKeeper Add Receipt.shortcut](GroundKeeper%20Add%20Receipt.shortcut) | Attach a receipt to an existing payment |
| [GroundKeeper Attach Receipt Later.shortcut](GroundKeeper%20Attach%20Receipt%20Later.shortcut) | Select the original saved payment JSON, then add a receipt |
| [GroundKeeper CIBC Automation.shortcut](GroundKeeper%20CIBC%20Automation.shortcut) | Optional experimental notification adapter |
| [GK Categorize Cloud.shortcut](GK%20Categorize%20Cloud.shortcut) | Apple Intelligence Cloud classification |
| [GK Categorize On-Device.shortcut](GK%20Categorize%20On-Device.shortcut) | Experimental on-device configuration |

Open a `.shortcut` file to import it. Inspect **Use Model** after importing:
the model selector determines where inference runs, regardless of the file or
Shortcut name. If both imports have the same internal name, rename one before
configuring the app. Your Mac must support and enable the selected Apple
Intelligence action.

For the Cloud configuration, use Text output, keep web search off,
and disable Follow Up. In GroundKeeper's **Settings > Categorization**, enter
the installed Shortcut's exact name, click **Use Apple Intelligence Shortcut**,
and process a fictional transaction.

GroundKeeper sends description, direction, and currency. In Settings, the separate
**Include receipt text with Apple Intelligence** option is off by default. Turning
it on also sends a bounded receipt excerpt to the chosen Shortcut. Cloud inference
can send that text to Apple's service. Images never enter classifier requests. The app validates the returned
`type`, `category`, and `review` fields and requires review of every suggestion.
It never switches from a local model to this provider automatically.

Cloud usage limits can stop processing. An earlier signed app check hit that
limit. The receipt pilot completed 40 direct worker-to-Shortcut calls: 39 valid
responses and one invalid output. This is separate from app-level provider testing.
The on-device export failed the output contract frequently in the recorded
benchmark and is included for experiments, not recommended for routine use.
See the [benchmark report](https://github.com/Henry-The-Yang-101/GroundKeeper/blob/main/experiments/apple-shortcuts/README.md).

## iPhone capture setup

The app’s first-launch assistant and Settings include install/share buttons for
the signed capture writer, receipt helpers, Wallet adapter, and Cloud classifier. Use Shortcuts
iCloud sync or AirDrop to get them onto your iPhone. Install the shared writer
before the adapters. The CIBC adapter is available separately as an experiment.

The distributable sources contain no personal folder bookmarks, card selections,
or device-specific automation references. Adapters read **Shortcut Input**;
create the personal automation on your phone and pass its transaction or
notification input to the adapter. If the shared writer is not resolved by name,
reselect it in the adapter’s **Run Shortcut** action.
Check every Run Shortcut target after importing: Wallet/CIBC → Capture Transaction;
Capture Transaction → GK Receipt OCR; Add Receipt → GK Receipt OCR and Capture
Transaction; Attach Receipt Later → Add Receipt. Select the installed helper explicitly if necessary.

1. Enable iCloud Drive and Shortcuts sync on both devices. Reuse
   `iCloud Drive/Shortcuts/Groundkeeper/inbox` as the capture destination.
2. Open **GroundKeeper Capture Transaction** on the iPhone. Check its Save File
   destination and grant access to that folder. The final Save File action writes
   JSON to the inbox; the earlier image Save File action belongs in `inbox/assets`.
   The installer initially asks where to save; configure both destinations and
   turn off **Ask Where to Save**. The writer adds the schema version, event ID
   and capture time, collects optional details, then saves the completed envelope.
3. Open **GroundKeeper Wallet Automation**. Check that its **Run Shortcut**
   action targets the shared capture writer. Its dictionary uses
   `source: wallet_transaction`, `app: Wallet`, and the trigger's card/pass,
   merchant, amount, name, and transaction values. Re-select those variables
   on the receiving phone if needed.
4. In the iPhone's Shortcuts **Automation** tab, configure the supported Wallet
   transaction trigger for your selected cards. Ensure its input reaches the
   Wallet adapter. Importing a shared Shortcut does not establish the phone's
   personal automation or card selection.
5. On the Mac, connect the exact inbox in setup or **Sync > Connect folder**.
   Existing saved parent-folder connections remain supported. Process a fictional event first, then confirm captured card
   labels against your accounts. The importer preserves source files and
   detects repeated deliveries.

### Optional Wallet category hint

The Wallet adapter dictionary has an optional `wallet_category_raw` text entry,
blank by default. The transaction property picker inspected in macOS Shortcuts
offers Transaction, Card or Pass, Merchant, Amount and Name; it does **not** offer
Category. Do not bind this entry to an invented Category property or use Name as
a category substitute.

For **Any Category**, leave the entry blank. To capture the category via the
trigger, create an iPhone automation restricted to one Wallet category. Copy the
adapter's Dictionary and Run Shortcut actions into that automation, reselect its
trigger variables, and put the exact filter label in `wallet_category_raw`
before calling **GroundKeeper Capture Transaction**. A single shared adapter
with one fixed label cannot represent several different category filters.
Each category needs its own filtered automation; avoid
overlapping an enabled Any Category automation, which would capture twice.
This setup still requires an iPhone check; no category-filtered automations are
installed by these exports. The shared writer preserves the entry in the JSON.

At classification time the Mac reads the hint from the original linked Wallet
payload. Missing, empty, malformed and conflicting hints are ignored. The value
is stored only in that original payload; no category column or merchant record
is added. Classifier audit records retain a source-event reference and a hash of
the actual input. Models use the label as uncertain supporting evidence, with
explicit purchase/receipt evidence taking priority. It never directly assigns
a GroundKeeper category or bypasses review. Update the selected GK Categorize
Shortcut too when using the Apple Shortcut provider so it includes these rules.

## Success notifications

Wallet and CIBC adapters show a custom notification only after the shared writer
returns a successfully saved capture. The title is **GroundKeeper Wallet
Automation** or **GroundKeeper CIBC Automation**. The body is
`Successfully captured and saved <transaction description>!`, using the saved
Wallet merchant or bank subtitle. Cancelled or failed captures do not show a
success notification. This confirms the capture file was saved, not that the
Mac has imported it or that iCloud has finished uploading it.

You can leave the personal automation's **Notify When Run** disabled. The custom
Show Notification action is separate. When upgrading, replace both adapter
Shortcuts and **GroundKeeper Capture Transaction**, then check the writer's
inbox/assets destinations and each adapter's Run Shortcut target again.

## Optional receipts and notes

The shared writer first offers **Add receipt**, **Add note**, or **Skip adding
receipt**. After adding a receipt, choose **Add note** or **Save transaction**.
After adding a note, choose **Add receipt** or **Skip adding receipt**. Both are
optional; there is no combined receipt-and-note button. Cancelling a menu, note,
camera or photo picker aborts the capture. Choosing Skip deliberately saves the
transaction with whatever details were already completed.

No capture JSON is written until all chosen steps and validation finish. The
result is one schema 4 payment with optional `note` and `receipt` fields. An
empty selected image, blank requested note, empty text-only OCR, or an action
error stops the run. Notes are limited to 2,000 characters and receipt OCR to
8,000; a conservative serialized-size check protects the Mac's 64 KiB bound.

Filenames use `<transaction description>_<app>_CAPTURE_<timestamp>.json`, e.g.
`Fictional_Coffee_Shop_Wallet_CAPTURE_2026-10-20_14-30-45-123.json`. The description
is the Wallet merchant or bank subtitle, not the optional note. Spaces and other
characters outside ASCII letters, digits, `_` and `-` become underscores. Each
descriptive component is capped at 60 characters. The timestamp includes
milliseconds; overwrite stays off. Event IDs inside JSON still provide replay
identity, independently of names or renaming.

Receipts offer **Take photo** or **Choose image**, then **Text only** or **Keep
image**. **GK Receipt OCR** uses Apple's native Extract Text from Image action.
For retained images, create `assets` inside the inbox. Configure Capture
Transaction's image Save File action and Add Receipt's image Save File action to
that folder, with overwrite off. Configure Capture Transaction's final JSON Save
File action to the inbox itself. Images are saved only after all menus finish,
immediately before JSON. Shortcuts cannot atomically save two files: a final
JSON save failure can leave an unreferenced image, but creates no payment JSON.

To attach a receipt later, run **GroundKeeper Attach Receipt Later** and select
the original payment JSON. This still creates an independent schema 3 receipt
with an explicit parent identity. Do not select a receipt event or use a global
last-payment variable. Install all updated helpers together when upgrading.

On the Mac, **Notes & receipts…** displays the phone note alongside receipt
evidence. Captured notes are preserved separately from editable transaction
notes and are not sent to classifiers. Receipt text/image processing and
classification consent remain unchanged. The importer accepts both old and new
captures and does not rely on the filename. Source JSON stays in the inbox;
optional images can arrive later and are imported into the local vault.

Receiving-phone camera behavior, permissions, automation input and locked-phone
menus still require a device check. See the [capture contract](../contracts/capture/README.md).

The CIBC adapter is experimental and remains off in the development setup. It
passes notification fields to the same writer with `notification_fields` as
the input shape. Enable it only after checking which notification fields and
triggers your phone actually supplies. Do not assume every banking notification
format is recognized.

Sample event processing was checked in earlier development work. Real Wallet
taps, locked-phone delivery, and CIBC triggering still need device testing.
The app preserves unrecognized events for review.

## Maintaining the exports

Reviewed XML sources are in `sources/`. After edits, sign them on a Mac:

```sh
python3 scripts/sign_capture_shortcuts.py
```

The script converts each source to a binary `.shortcut` and uses Apple’s
`shortcuts sign --mode anyone` service with a bounded timeout. Do not distribute
“People Who Know Me” exports; they contain the exporter’s contact verification
metadata. The signed files in this folder use Apple’s shareable signing chain.

The app build bundles the catalog and every `.shortcut` from this folder. Source
checks verify variable references, native text-token serialization, filename construction and final-write ordering, and the absence of personal folder permissions and trigger selections.
Signing and native action checks are distinct from a real Wallet trigger.
See the [receipt pilot](../experiments/receipts/README.md) for earlier measured OCR
results. Physical iPhone triggers, cancellation, folder permissions and image
saving still need verification on the receiving device.

### Capture-details verification (2026-10-20)

Native Mac Shortcuts checks produced the descriptive filename, a note-only
capture, a capture with both receipt text and a quoted Unicode note, and no
output after cancelling the first menu. The receipt-menu check substituted
fictional photo/OCR outputs; it did not exercise a camera or photo permission.
The final Save File action was replaced by CLI output into an isolated local
directory. Those three native JSON outputs were imported into an isolated
SQLCipher vault: three transactions, two captured notes, one receipt, no
quarantined files and a passing integrity check. The app built successfully;
29 Swift core tests and 39 Python capture/schema checks passed.
