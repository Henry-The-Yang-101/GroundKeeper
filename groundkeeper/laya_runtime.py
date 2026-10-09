"""Local Laya typed decisions with the GroundKeeper JSON contract.

The three distributions are decoded jointly over schema-valid objects. This is
a grammar constraint, not calibrated confidence or permission to auto-accept.
"""
import itertools
import math
from pathlib import Path

from .policy import CATEGORIES, TYPES, validate_answer, validate_input

MAX_LEN = 512
HEAD_MAX_LEN = 384
NULL = "not_applicable"
FALLBACK = {"type": "unknown", "category": "uncategorized", "review": True}

TYPE_CRITERIA = {
    "expense": "purchase, service, fee or interest charge",
    "income": "explicit credited payroll, benefits, earnings or interest",
    "refund": "explicit return or reimbursement of prior spending",
    "transfer": "explicit movement between own accounts",
    "card_payment": "payment of credit card balance",
    "loan_principal": "explicit principal repayment excluding interest",
    "cash_movement": "ATM withdrawal or cash deposit",
    "balance_adjustment": "explicit cash or balance adjustment",
    "unknown": "insufficient, conflicting or unsplit payment evidence",
}
CATEGORY_CRITERIA = {
    "groceries": "supermarket food",
    "dining": "restaurant or meal delivery",
    "local_transport": "transit, taxi, parking, tolls",
    "vehicle": "fuel, repairs, registration",
    "housing": "rent, upkeep, mortgage interest",
    "utilities": "energy, water, phone, internet, household waste",
    "shopping": "retail goods; mixed retailers need review",
    "medical": "treatment or prescriptions",
    "personal_care": "beauty or grooming",
    "fitness": "gym or sports",
    "entertainment": "media, games, hobbies",
    "software": "productivity software or cloud",
    "education": "tuition, courses, textbooks",
    "travel": "flights, intercity travel, lodging, rental cars",
    "insurance": "insurance premiums",
    "financial": "bank or card fees, borrowing interest",
    "taxes": "direct tax or government fees",
    "gifts": "explicit gift or charitable donation",
    "other": "known purpose outside listed categories; shipping fee",
    "uncategorized": "insufficient spending purpose or unknown type",
    NULL: "non-spending type, or refund without original category",
}
QUESTIONS = {
    "type": {
        "type": "choice",
        "instructions": "Choose transaction type from evidence only. Credit alone does not establish income or refund. A payment rail does not prove own-account transfer. Unsplit mortgage or installment is unknown. Debit withdrawal from a named merchant is a purchase wrapper.",
        "criteria": TYPE_CRITERIA,
    },
    "category": {
        "type": "choice",
        "instructions": "Choose spending purpose. Purpose beats subscription or address words. No hidden gift intent. Unspecified pharmacy, digital bill or service fee is uncategorized. Refund uses original category only if explicit. Non-spending types use not_applicable; unknown uses uncategorized.",
        "criteria": CATEGORY_CRITERIA,
    },
    "review": {
        "type": "choice",
        "instructions": "Does this decision need review under the labeling policy? Review means decision uncertainty, not merely an unfamiliar payer. Require review for conflicting or insufficient evidence, unknown type, uncategorized spending, mixed retailers, unsplit mortgage/installment, or refund with unknown original purpose.",
        "criteria": {"false": "sufficient unambiguous evidence", "true": "uncertain or policy requires review"},
    },
}


def valid_decisions():
    decisions = []
    for typ, cat, review in itertools.product(TYPES, (*CATEGORIES, None), (False, True)):
        answer = {"type": typ, "category": cat, "review": review}
        try:
            validate_answer(answer)
        except ValueError:
            continue
        decisions.append(answer)
    return decisions


DECISIONS = valid_decisions()


def training_row(row):
    validate_input(row["input"])
    answer = validate_answer(row["answer"])
    return {"id": row["id"], "state": row["input"], "questions": QUESTIONS,
            "expected": {"type": answer["type"], "category": answer["category"] or NULL,
                         "review": str(answer["review"]).lower()}}


def decode(answers):
    """Maximum product of the three distributions under existing invariants."""
    try:
        probabilities = {}
        for field, question in QUESTIONS.items():
            distribution = answers[field]["probabilities"]
            if set(distribution) != set(question["criteria"]):
                raise ValueError("Incomplete or unexpected probability keys")
            values = {key: float(value) for key, value in distribution.items()}
            if any(not math.isfinite(v) or v < 0 or v > 1 for v in values.values()) or sum(values.values()) <= 0:
                raise ValueError("Invalid probabilities")
            probabilities[field] = values
        raw = {"type": answers["type"]["choice"],
               "category": None if answers["category"]["choice"] == NULL else answers["category"]["choice"],
               "review": {"true": True, "false": False}[answers["review"]["choice"]]}
        for field in QUESTIONS:
            if answers[field]["choice"] not in probabilities[field]:
                raise ValueError("Unexpected choice")
        def score(answer):
            keys = {"type": answer["type"], "category": answer["category"] or NULL,
                    "review": str(answer["review"]).lower()}
            return sum(math.log(max(probabilities[field][key], 1e-30)) for field, key in keys.items())
        selected = dict(max(DECISIONS, key=score))
        try:
            validate_answer(raw)
            raw_valid = True
        except ValueError:
            raw_valid = False
        return selected, {"raw_prediction": raw, "raw_valid_schema": raw_valid,
                          "constraint_changed": raw != selected, "valid_schema": True}
    except (KeyError, ValueError, TypeError, OverflowError):
        return dict(FALLBACK), {"raw_prediction": None, "raw_valid_schema": False,
                               "constraint_changed": False, "valid_schema": False}


def configure_agent(agent):
    """Use identical uncalibrated fp32 inference settings before/after training."""
    import numpy as np
    import torch
    agent.temperature = np.ones(3, dtype=np.float32)
    agent.temperature_by_options = {}
    agent.amp_enabled = False
    agent.dtype = torch.float32
    return agent


class LocalLayaCategorizer:
    def __init__(self, model_path, device="mps"):
        import os
        path = Path(model_path)
        if not path.is_dir() or not (path / "model.safetensors").is_file():
            raise ValueError("Expected complete local Laya checkpoint")
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
        import laya
        self.agent = configure_agent(laya.load(str(path), device=device, backend="eager"))
        if self.agent.device.type != device or next(self.agent.model.parameters()).device.type != device:
            raise RuntimeError("Laya did not remain on the requested device")

    def predict(self, inputs):
        validate_input(inputs)
        result = self.agent.predict(inputs, QUESTIONS, max_len=MAX_LEN, head_max_len=HEAD_MAX_LEN)
        return decode(result["answers"])

    def suggest(self, inputs):
        answer, _ = self.predict(inputs)
        return {**answer, "review": True}
