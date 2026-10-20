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
