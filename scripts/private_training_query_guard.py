"""Additional private-training privacy policy, separate from production matching.

Reject the whole frozen query rather than removing a suspicious suffix or
inventing a new merchant. This policy receives only the sanitized candidate,
never a transaction, note, receipt, amount, account, or classifier label.
"""

import re

VERSION = "private-training-query-v1"
# A narrow public-name exception; short names such as 3M are below the reference
# threshold. Other ambiguous long mixed names remain conservatively rejected.
PUBLIC_DIGIT_NAMES = frozenset({"7eleven"})


def private_query_rejection(query):
    """Return a fixed rejection reason, or None; inspect only query.merchant."""
    if query is None:
        return None
    merchant = query.get("merchant") if isinstance(query, dict) else None
    if not isinstance(merchant, str):
        return "invalid_merchant_candidate"
    tokens = re.findall(r"[^\W_]+(?:[.-][^\W_]+)*", merchant, flags=re.UNICODE)
    for index, token in enumerate(tokens):
        compact = "".join(character for character in token if character.isalnum())
        if compact.casefold() in PUBLIC_DIGIT_NAMES:
            continue
        letters = sum(character.isalpha() for character in compact)
        digits = sum(character.isdigit() for character in compact)
        # Production description fallback removes long references, but its
        # explicit merchant path may retain them. Also reject shorter separate
        # suffixes when their shape strongly resembles an identifier.
        if letters and digits and (len(compact) >= 6 or (index > 0 and len(compact) >= 4)):
            return "mixed_alphanumeric_reference"
    return None
