# Apple Shortcuts setup

GroundKeeper uses Shortcuts for two separate tasks: capturing transaction events
on iPhone, and optionally classifying descriptions with Apple Intelligence on
Mac. Local Qwen and Laya classification do not require Shortcuts.

## Included installers

| File | Purpose |
| --- | --- |
| [GroundKeeper Capture Transaction.shortcut](GroundKeeper%20Capture%20Transaction.shortcut) | Shared iPhone capture writer |
| [GroundKeeper Wallet Automation.shortcut](GroundKeeper%20Wallet%20Automation.shortcut) | Wallet transaction adapter; pass automation input |
| [GroundKeeper CIBC Automation.shortcut](GroundKeeper%20CIBC%20Automation.shortcut) | Optional experimental notification adapter |
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

The app’s first-launch assistant and Settings include install/share buttons for
the signed capture writer, Wallet adapter, and Cloud classifier. Use Shortcuts
iCloud sync or AirDrop to get them onto your iPhone. Install the shared writer
before the adapters. The CIBC adapter is available separately as an experiment.

The distributable sources contain no personal folder bookmarks, card selections,
or device-specific automation references. Adapters read **Shortcut Input**;
create the personal automation on your phone and pass its transaction or
notification input to the adapter. If the shared writer is not resolved by name,
reselect it in the adapter’s **Run Shortcut** action.

1. Enable iCloud Drive and Shortcuts sync on both devices. Reuse
   `iCloud Drive/Shortcuts/Groundkeeper/inbox` as the capture destination.
2. Open **GroundKeeper Capture Transaction** on the iPhone. Check its Save File
   destination and grant access to that folder. The installer initially asks where
   to save; choose the inbox and turn off **Ask Where to Save** for automation. This shared writer adds the
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
5. On the Mac, connect the exact inbox in setup or **Sync > Connect folder**.
   Existing saved parent-folder connections remain supported. Process a fictional event first, then confirm captured card
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

Reviewed XML sources are in `sources/`. After edits, sign them on a Mac:

```sh
python3 scripts/sign_capture_shortcuts.py
```

The script converts each source to a binary `.shortcut` and uses Apple’s
`shortcuts sign --mode anyone` service with a bounded timeout. Do not distribute
“People Who Know Me” exports; they contain the exporter’s contact verification
metadata. The signed files in this folder use Apple’s shareable signing chain.

The app build bundles the catalog and every `.shortcut` from this folder. Source
checks verify variable references, unique-file generation, and the absence of
personal folder permissions and trigger selections. Signing and import were
checked on Mac. A synthetic CLI writer run timed out on this machine; real
Wallet input, output typing, folder permissions, and locked-phone delivery still
need device verification before relying on unattended capture.
