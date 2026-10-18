# Apple Shortcuts setup

GroundKeeper uses Shortcuts for two separate tasks: capturing transaction events
on iPhone, and optionally classifying descriptions with Apple Intelligence on
Mac. Local Qwen and Laya classification do not require Shortcuts.

## Included classifier exports

| File | Purpose |
| --- | --- |
| [GK Categorize Cloud.shortcut](GK%20Categorize%20Cloud.shortcut) | Apple Intelligence Cloud classification |
| [GK Categorize On-Device.shortcut](GK%20Categorize%20On-Device.shortcut) | Experimental on-device configuration |

Open a `.shortcut` file to import it. Inspect **Use Model** after importing:
the model selector determines where inference runs, regardless of the file or
Shortcut name. If both imports have the same internal name, rename one before
configuring the app. Your Mac must support and enable the selected Apple
Intelligence action.

For the Cloud configuration, use Text output, enable Broad World Knowledge,
and disable Follow Up. In GroundKeeper's **Settings > Categorization**, enter
the installed Shortcut's exact name, click **Use Apple Intelligence Shortcut**,
and process a fictional transaction.

GroundKeeper sends only description, direction, and currency. Cloud inference
can send that text to Apple's service. The app validates the returned
`type`, `category`, and `review` fields and requires review of every suggestion.
It never switches from a local model to this provider automatically.

Cloud usage limits can stop processing. The latest signed app check hit that
limit; a successful app-to-Shortcut prediction still needs verification.
The on-device export failed the output contract frequently in the recorded
benchmark and is included for experiments, not recommended for routine use.
See the [benchmark report](https://github.com/Henry-The-Yang-101/GroundKeeper/blob/main/experiments/apple-shortcuts/README.md).

## iPhone capture setup

The capture, Wallet, and CIBC adapter exports are still pending. Apple's
shareable export service returned `NSURLErrorDomain error 500` during export,
including a retry. The two files above classify text; they do not install
capture automation. New users can start with CSV import or manual entry.

For an existing capture installation:

1. Enable iCloud Drive and Shortcuts sync on both devices. Reuse
   `iCloud Drive/Shortcuts/Groundkeeper/inbox` as the capture destination.
2. Open **GroundKeeper Capture Transaction** on the iPhone. Check its Save File
   destination and grant access to that folder. This shared writer adds the
   schema version, event ID, and capture time to the input dictionary.
3. Open **GroundKeeper Wallet Automation**. Check that its **Run Shortcut**
   action targets the shared capture writer. Its dictionary uses
   `source: wallet_transaction`, `app: Wallet`, and the trigger's card/pass,
   merchant, amount, name, and transaction values. Re-select those variables
   on the receiving phone if needed.
4. In the iPhone's Shortcuts **Automation** tab, configure the supported Wallet
   transaction trigger for your selected cards. Ensure its input reaches the
   Wallet adapter. Importing a shared Shortcut does not establish the phone's
   personal automation or card selection.
5. On the Mac, use **Sync > Connect folder** and select the Groundkeeper folder
   or its `inbox`. Process a fictional event first, then confirm captured card
   labels against your accounts. The importer preserves source files and
   detects repeated deliveries.

The CIBC adapter is experimental and remains off in the development setup. It
passes notification fields to the same writer with `notification_fields` as
the input shape. Enable it only after checking which notification fields and
triggers your phone actually supplies. Do not assume every banking notification
format is recognized.

Sample event processing was checked in earlier development work. Real Wallet
taps, locked-phone delivery, and CIBC triggering still need device testing.
The app preserves unrecognized events for review.

## Maintaining the exports

On the Mac, open each capture Shortcut and choose **File > Export > Anyone**
when Apple's service is available again. Save the resulting `.shortcut` files
here, import them on a second device, and verify the shared writer reference,
folder selection, and input variables. Add the verified files to Git; the
release workflow includes every `.shortcut` in this directory automatically.
Keep personal sample transactions and account details out of the exports.
