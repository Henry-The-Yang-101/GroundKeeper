"""Audit a known receipt against a manually transcribed reference.

This measures text preservation and adjacency, not general receipt extraction.
It deliberately does not repair OCR errors or infer a missing decimal point.
"""
import argparse
from decimal import Decimal
import json
from pathlib import Path
import re

from groundkeeper.receipts import context_from_text

MONEY = r"(?<!\d)\d{1,3}\.\d{2}(?!\d)"


def cents(value):
    return int(Decimal(value) * 100)


def sku_pattern(sku):
    return r"[, ]*".join(sku)


def audit(text, reference):
    items = []
    starts = {item["sku"]: re.search(r"^\s*" + sku_pattern(item["sku"]) + r"(?!\d)", text, re.M) for item in reference["items"]}
    for expected in reference["items"]:
        # A SKU can occupy a line by itself; inspect the following text until
        # the first literal price, rather than requiring one OCR line per item.
        start = starts[expected["sku"]]
        end = min((m.start() for m in starts.values() if m and start and m.start() > start.start()), default=len(text))
        price = re.search(MONEY, text[start.end():end]) if start else None
        observed_name = " ".join(text[start.end():start.end() + price.start()].split()) if start and price else None
        observed_price = cents(price.group()) if price else None
        items.append({"sku": expected["sku"], "expected_name": expected["name"], "observed_name": observed_name,
                      "sku_present": start is not None, "name_exact": observed_name == expected["name"],
                      "expected_price_cents": expected["price_cents"], "observed_next_price_cents": observed_price,
                      "next_price_matches": observed_price == expected["price_cents"]})
    discounts = []
    for expected in reference["discounts"]:
        match = re.search(r"/\s*" + sku_pattern(expected["sku"]) + r"[^\n]*\n\s*(" + MONEY + r")-", text)
        observed = -cents(match.group(1)) if match else None
        discounts.append({"sku": expected["sku"], "expected_cents": expected["amount_cents"], "observed_cents": observed,
                          "matches": observed == expected["amount_cents"]})
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    footer = {}
    for label, expected in reference["footer_cents"].items():
        positions = [i for i, line in enumerate(lines) if line.lstrip("* ") == label]
        next_line = lines[positions[-1] + 1] if positions and positions[-1] + 1 < len(lines) else None
        observed = cents(next_line) if next_line and re.fullmatch(MONEY, next_line) else None
        footer[label] = {"label_present": bool(positions), "expected_cents": expected,
                         "expected_decimal_literal_present": bool(re.search(r"(?<!\d)" + re.escape(f"{expected // 100}.{expected % 100:02d}") + r"(?!\d)", text)),
                         "next_line": next_line, "literal_next_value_cents": observed, "adjacent_pair_matches": observed == expected}
    return {"item_count": len(items), "sku_matches": sum(r["sku_present"] for r in items),
            "exact_name_matches": sum(r["name_exact"] for r in items),
            "next_price_matches": sum(r["next_price_matches"] for r in items),
            "discount_matches": sum(r["matches"] for r in discounts), "items": items, "discounts": discounts, "footer": footer,
            "limits": "SKU/next-price and label/next-line diagnostics on this reference; not a production structured receipt parser"}


def audit_layout(layout, reference):
    rows = [row for table in layout["tables"] for row in table["rows"]]
    results = []
    for item in reference["items"]:
        matches = [row for row in rows if any(re.search(r"^\s*" + sku_pattern(item["sku"]) + r"(?!\d)", cell["text"]) for cell in row)]
        results.append({"sku": item["sku"], "present_in_table": bool(matches),
                        "same_row_price_matches": any(any(cents(m.group()) == item["price_cents"] for cell in row for m in re.finditer(MONEY, cell["text"])) for row in matches)})
    return {"table_count": len(layout["tables"]), "row_count": len(rows), "items": results,
            "item_skus_in_tables": sum(r["present_in_table"] for r in results),
            "same_row_price_matches": sum(r["same_row_price_matches"] for r in results),
            "footer_rows": [[cell["text"] for cell in row] for row in rows if any(cell["text"].lstrip("* ") in reference["footer_cents"] for cell in row)]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--shortcuts-text", type=Path, required=True)
    parser.add_argument("--native-jsonl", type=Path, required=True)
    parser.add_argument("--case", type=Path, required=True)
    parser.add_argument("--layout-json", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    reference = json.loads(args.reference.read_text())
    native = json.loads(args.native_jsonl.read_text().strip())
    case = json.loads(args.case.read_text())
    context = context_from_text(case["receipt_ocr"]["text"])
    result = {"reference": reference["id"], "shortcuts": audit(args.shortcuts_text.read_text(), reference),
              "native": audit(native["text"], reference), "native_tables_detected": native["table_count"],
              "classifier_context": {"truncated": context["truncated"], "bytes": len(context["text"].encode()),
                                     "audit": audit(context["text"], reference)},
              "production_structure": "Plain OCR transcript plus table count; table cells and normalized receipt fields are not preserved"}
    if args.layout_json:
        result["native_layout"] = audit_layout(json.loads(args.layout_json.read_text()), reference)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: {k: v[k] for k in ("sku_matches", "exact_name_matches", "next_price_matches", "discount_matches")} for key, v in result.items() if key in ("shortcuts", "native")}, indent=2))


if __name__ == "__main__":
    main()
