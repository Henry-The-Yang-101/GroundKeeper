# Receipt capture pilot

Receipt photos are optional evidence attached to an existing payment. They never
create a second purchase or replace its monetary fields. The phone saves the
payment before showing a receipt prompt; a separate event carries OCR and an
optional image reference. The Mac preserves raw text, versions reprocessing,
and supplies a bounded excerpt to the explicitly selected classifier.

## Public image sample

Run `python3 -m scripts.download_receipt_pilot` from the repository root. It saves
100 receipt images, OCR transcripts and key-field annotations beneath the ignored
`.local/receipts/sroie-100`. The sample is selected by a fixed hash of source paths
from a pinned revision; every downloaded file is checked against its Git blob
identity and recorded with a SHA-256 hash. No model or OCR scores enter selection.

Dataset: ICDAR 2019 SROIE, Huang et al., *ICDAR2019 Competition on Scanned Receipt
OCR and Information Extraction*, DOI 10.1109/ICDAR.2019.00244.
Images/transcripts: [pinned public mirror](https://github.com/zzzDavid/ICDAR-2019-SROIE/tree/27be4271b251c256f695acbade9a801bffe85994/data).
Dataset license: CC BY 4.0, documented by the
[competition](https://rrc.cvc.uab.es/?ch=13&com=downloads) and the
[SROIE dataset curator](https://github.com/jsdnrs/ICDAR2019-SROIE/blob/77c4c11490e3c4179ee22f86611569c71c04b5f9/DATASET.md).
The mirror's code license does not replace the dataset license.

These are English-language Malaysian receipts, not Canadian bank data. Key-field
and OCR annotations are not GroundKeeper category labels. Do not score category
accuracy against labels inferred automatically from these annotations, or use
the pilot as training data. Deliberately selected classification cases must state
their provenance and expected behavior separately.

## Native processing

`ReceiptPilot`, an executable in the GroundKeeperCore Swift package, offers:

```
ReceiptPilot ocr .local/receipts/sroie-100 .local/receipts/native-ocr.jsonl
ReceiptPilot ingest .local/receipts/pilot-inbox .local/receipts/ingestion.json
```

The OCR command uses the production Apple Vision document reader. The ingestion
command uses an isolated encrypted temporary vault, reads payment and receipt
events in reverse filename order, imports images and checks classifier inputs.
Its decisions are explicit fixtures, not model predictions. It never opens the
user's live vault. Actual Shortcuts OCR and model comparisons are separate runs.

## Reproduce the comparison

Read the [recorded results](RESULTS.md) and [design assessment](../../docs/receipt-ocr.md)
before interpreting the scores. Install GK Receipt OCR on a Mac and inspect the
native Extract Text from Image action. The classifier Shortcut must use the
selected intended model, Text output, Follow Up off and web knowledge off.
Run from the repository root with the project environment:

```sh
.venv/bin/python -m scripts.download_receipt_pilot
.venv/bin/python -m scripts.receipt_pilot shortcuts-ocr
.venv/bin/python -m scripts.receipt_pilot prepare --ocr shortcuts
.venv/bin/python -m scripts.receipt_pilot classify --ocr shortcuts --provider qwen --package .local/macos/models/qwen-delaware
.venv/bin/python -m scripts.receipt_pilot classify --ocr shortcuts --provider laya --package .local/macos/models/laya
.venv/bin/python -m scripts.receipt_pilot classify --ocr shortcuts --provider apple --skip-reference
.venv/bin/python -m scripts.receipt_pilot report --ocr shortcuts
```

Adjust package directories to the actual installed packages. The classifier
command uses the production worker without the app's XPC transport; the signed
app smoke test verifies that transport separately. Apple calls send the public
sample's description and bounded OCR to the selected Shortcut/model. No personal
ledger is read. The app's separate receipt-sharing setting governs normal app
jobs; this explicitly invoked pilot sends its public fixtures directly.

The runner records successes and safe errors, stops on a quota error, resumes
only matching input hashes, and refuses to mix case/model identities. Keep new
experiments in a new `--work` directory. Do not retry errors merely to raise a
score. `report --publish` exports decisions and aggregate metrics without raw
receipt text or images into this experiment's dated results files; reserve that
option for intentionally updating the recorded pilot.

For native OCR, build ReceiptPilot with the Swift package and run its `ocr`
command above, then repeat prepare/classify/report using `--ocr native`. Use a
separate ignored scratch build directory as in the macOS development guide.
Native OCR covers all 100 images; the paired classification still uses only the
fixed 20 cases. The [case file](cases.json) defines their policy expectations and
selection rationale independently from inference inputs.

The full prompt/response and OCR logs remain in `.local/receipts`, while committed
results contain model identities, image and input hashes, decisions and metrics.
The files are evaluation artifacts, not training data or a production ledger.

Additional user-labeled examples live in [user-cases](user-cases/README.md).
They retain observed model failures and remain separate from the original
20-case pilot's published scores.
