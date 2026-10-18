# Laya merchant-classification follow-up (2026-09-27)

## What was actually tested

The first M0 probe used Laya 0.3.11 and PyTorch 2.14.0. This follow-up used Laya **0.3.21** with the **same English checkpoint**, `convaiinnovations/laya` at revision `55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851`, on the same M4 Pro via `laya.load(local_snapshot, device="mps")`. Its model parameter stayed on `mps:0` after prediction. The original question and the same 12 merchant strings produced the same twelve top labels under both Laya versions.

The 12 expected categories below were hand-assigned for this diagnostic. The first PRESTO input came from the supplied screenshot; its transaction-specific suffix is redacted in Git and stated only in the user-facing report. `SQ *BLUE BOTTLE` came from the original plan's proposed test; the other strings are hand-written merchant-like examples. **No real transaction history was evaluated.** A merchant can sell multiple types of goods, so the policy behind a label matters (for example, this test puts recurring Netflix under `bills`).

| Exact input sent to Laya | Expected | Ten-choice raw prediction | `answer_confidence` |
| --- | --- | --- | ---: |
| `PRESTO MOB/<redacted>` | transport | other | 0.3106 |
| `SQ *BLUE BOTTLE` | dining | other | 0.3700 |
| `LOBLAWS #1020` | groceries | bills | 0.3559 |
| `UBER TRIP` | transport | other | 0.2475 |
| `UBER EATS` | dining | other | 0.2773 |
| `NETFLIX.COM` | bills | entertainment | 0.2408 |
| `AMZN MKTP CA` | shopping | other | 0.4246 |
| `AIR CANADA` | travel | travel | 0.2952 |
| `SEPHORA CANADA` | personal_care | personal_care | 0.2610 |
| `STEAM GAMES` | entertainment | entertainment | 0.8593 |
| `HYDRO ONE` | bills | other | 0.2571 |
| `DOLLARAMA #254` | shopping | other | 0.3215 |

The original question was a single `choice` named `spend_category` with these **exact** instructions and criteria:

```json
{
  "type": "choice",
  "instructions": "Classify the merchant for a personal spending transaction. Choose the most likely spending category.",
  "criteria": {
    "groceries": "Food and household staples from supermarkets or grocery stores",
    "dining": "Restaurants, cafés, takeaway food, and food delivery",
    "transport": "Local transit, rideshare rides, parking, and fuel",
    "shopping": "General retail goods, online marketplaces, and nonfood stores",
    "bills": "Utilities, recurring subscriptions, telecom, and other bills",
    "entertainment": "Games, movies, events, and recreation",
    "health": "Medical care, pharmacies, and health products",
    "travel": "Air travel, hotels, and trips",
    "personal_care": "Beauty, grooming, cosmetics, and salons",
    "other": "Spending that fits no listed category"
  }
}
```

The question definitions, all nonsensitive inputs, every run's per-case predictions and per-option probabilities are in [laya_eval.py](laya_eval.py) and [laya_eval_results.json](laya_eval_results.json). The JSON records the selected model revision, the Laya/PyTorch versions and a SHA-256 of the exact first merchant input. The local model path and screenshot merchant suffix were replaced with placeholders in the committed result. To reproduce this exact run, download that revision with `huggingface_hub.snapshot_download`, place the first raw merchant from the screenshot in a private file outside Git, then run `python research/laya_eval.py <checkpoint-directory> --presto-merchant-file <private-file>` in an environment with the pinned dependencies. Omitting that option runs a redacted surrogate and may change its prediction.

## Variants and outcomes

| Run | Exact change from original question/input | Correct |
| --- | --- | ---: |
| Original ten choices, raw merchant | None | 3/12 |
| Original ten choices, reversed option order | Same question text and criteria, only insertion order reversed | 1/12; four predictions changed |
| Original ten choices, minimally normalized merchant | Replace `SQ *` with empty text; replace `AMZN MKTP CA` with `Amazon marketplace`; leave all other inputs untouched | 4/12 |
| Nine choices, raw merchant | Remove `other`, keep other criteria and instructions | 4/12 |
| Nine choices, short context | Same nine choices; state is `Canadian consumer card purchase at merchant: <raw merchant>` | 4/12 |
| Ten choices, shorter criteria | Replace the question and category descriptions with the exact `SHORT_QUESTION` in the script; raw input | 3/12 |
| Shorter criteria, structured state | State is a dictionary with `transaction: consumer card purchase`, `merchant_raw`, and `merchant_clean` from minimal normalization | **0/12**; `other` for all twelve |
| Four broad groups | Map the ten fine categories to `food`, `mobility`, `retail`, `services`; raw input | 4/12 **broad-group** labels, so this is not directly comparable with fine-category accuracy |
| Original question, one merchant per call | `predict` twelve times instead of one `predict_batch(..., batch_size=12)` | 3/12; same twelve top labels |

On the structured-state run, the chosen-label probabilities averaged **0.863**, despite all twelve labels being wrong under the hand-assigned policy. This is a narrow demonstration that a more structured input can make this checkpoint confidently worse; it is not a general claim about JSON states. The shorter criteria also raised probabilities without improving accuracy. These variants were explored on the same twelve cases, so the highest score here is **not** a held-out estimate or a selected production prompt.

## Which confidence number to use

The previous M0 write-up called `confidence` simply “confidence.” Laya's current docs distinguish two fields: `confidence` on a `choice` answer is **one minus normalized entropy** of the whole distribution; `answer_confidence` is the **probability of the selected label**. Laya 0.3.21's `min_confidence` policy uses `answer_confidence` ([API/README](https://github.com/NandhaKishorM/laya#automated-confidence-gating)). For this original ten-choice run, both fields happened to put only one case above 0.6, but they have different meanings and cannot be substituted generally.

I tested `min_confidence=0.6` directly. On the original raw ten-choice run, it flagged 11/12 for review and accepted only the correctly labelled `STEAM GAMES`. On the structured-state variant, it flagged **0/12** and accepted **0/12 correct**. A threshold therefore cannot rescue a bad input/question definition. Laya's [calibration guidance](https://github.com/NandhaKishorM/laya#calibration) and [staged-adoption guide](https://nandhakishorm.github.io/laya/staged-adoption/) both require a representative held-out set and task-specific review policy; the shipped checkpoint's probabilities are not sufficient evidence for automatic categorization.

## Setup recommendation for GroundKeeper

1. **Parse transactions deterministically.** Keep bank/Wallet amount, sign, currency, card, and merchant extraction in parsers. Laya is a category chooser, not a field extractor. Preserve the raw merchant and a normalized merchant key.
2. **Define a category policy before evaluating.** Decide recurring services versus entertainment, marketplace purchases versus groceries, travel versus local transport, and how to handle merchants selling mixed goods. An unknown item-level purchase at Amazon or Dollarama may be impossible to classify from the merchant name alone.
3. **Use user-confirmed merchant rules for known merchants.** Let those rules win. For unrecognized merchants, Laya can suggest a category in a review queue, but this small test does not justify accepting its suggestion unattended. Avoid a generic `other` option as a substitute for abstention; removing it merely shifted the model's bias toward `shopping` here.
4. **Evaluate on real, private, reviewed data.** Log checkpoint revision, schema version, normalized/raw merchant, Laya probabilities, chosen category, user correction, and language without leaking transaction contents to plaintext logs. Hold out later transactions and previously unseen merchants separately: repeated merchants test the rule layer, while unseen merchants test Laya's generalization. Report accuracy **and** the precision/coverage of any proposed auto-accept threshold. Laya ships an [evaluation harness](https://github.com/NandhaKishorM/laya/blob/main/docs/evals.md) with JSONL `state`, `questions`, and `expected` rows and metrics such as choice accuracy and calibration error.
5. **Only then choose an automatic threshold or fine-tune.** With Laya 0.3.21, use `answer_confidence` or `min_confidence` only after validating that exact checkpoint, schema, device/batch shape, and threshold on held-out data. The maintainers describe the base checkpoints as weak on unfamiliar zero-shot decision tasks and provide a [domain fine-tuning notebook](https://github.com/NandhaKishorM/laya#fine-tuning). Training Laya on this Mac was **not** tested; model adaptation belongs after enough reviewed GroundKeeper examples exist.
6. **Keep the deployment pinned and check MPS after inference.** The M0 hardware test already established MPS viability. Pin both package and checkpoint revision, keep CPU fallback off unless an upgrade requires it, and re-run this evaluation when the schema or checkpoint changes. If French alerts become a category input, evaluate a multilingual checkpoint separately; the maintainers note that routing/language and checkpoint choice affect accuracy ([model documentation](https://github.com/NandhaKishorM/laya#honest-limits)).

The current decision is to use Laya in **shadow/review mode** behind deterministic merchant rules. The user still needs to supply a representative, privately labelled corpus before GroundKeeper can choose an auto-categorization threshold or justify fine-tuning.
