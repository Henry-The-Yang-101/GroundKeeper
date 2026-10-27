"""Prepare/run a fictional native Shortcuts check without GPS, menus or saves.

Run --prepare, import the printed signed file, then run --run. The harness uses
the production priority actions and its own shortcut-scoped storage. Results
and fictional inputs stay under ignored .local/wallet-priority-check/.
"""

import argparse
import json
import plistlib
import subprocess
import time
import uuid
from datetime import datetime, timedelta
from pathlib import Path

import build_receipt_shortcuts as builder

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / ".local/wallet-priority-check"
NAME = "GroundKeeper Wallet Priority Check"


def prepare():
    template = plistlib.loads(
        (builder.ROOT / "GroundKeeper Capture Transaction.plist").read_bytes()
    )
    workflow = builder.Workflow(NAME, template)
    event = workflow.add("detect.dictionary", WFInput=builder.token({"Type": "ExtensionInput"}))
    workflow.setvar("Saved Event", event)
    # Supply deterministic numeric times only in this isolated test harness.
    # The production writer always uses its original native capture Date.
    seconds = workflow.get(builder.variable("Saved Event"), "test_seconds")
    sentinel = workflow.menu("Unused insertion point", [])
    workflow.endmenu(sentinel)
    builder.wallet_priority(workflow.data, captured_seconds=seconds)
    workflow.actions[:] = [
        a
        for a in workflow.actions
        if not a["WFWorkflowActionIdentifier"].endswith(".choosefrommenu")
    ]
    native_date = workflow.add("date")
    native_clock = workflow.add(
        "gettimebetweendates",
        WFInput=builder.text(native_date),
        WFTimeUntilFromDate="January 1, 2001",
        WFTimeUntilUnit="Seconds",
    )
    result = workflow.dictionary({"result": "proceed", "native_clock": native_clock})
    workflow.add("output", WFOutput=builder.text(result))
    unsigned = WORK / (NAME + ".unsigned.shortcut")
    signed = WORK / (NAME + ".shortcut")
    unsigned.write_bytes(plistlib.dumps(workflow.data))
    subprocess.run(
        [
            "/usr/bin/shortcuts",
            "sign",
            "--mode",
            "anyone",
            "--input",
            str(unsigned),
            "--output",
            str(signed),
        ],
        check=True,
        timeout=60,
    )
    print(f"Import this test-only Shortcut, then run this script with --run:\n{signed}")


def check(shortcut):
    run_id = uuid.uuid4().hex
    stamp = datetime.fromisoformat("2026-10-27T10:00:00-04:00")
    report = []

    def event(source, group, seconds=0, **fields):
        base = {
            "source": source,
            "captured_at": (stamp + timedelta(seconds=seconds)).isoformat(),
            "test_seconds": str(int(stamp.timestamp()) + seconds),
            "wallet_priority_group": f"native-test-{run_id}-{group}",
        }
        if source == "wallet_transaction":
            base.update(merchant="  Fictional Coffee  Shop ", amount="$0012.3")
        else:
            base.update(subtitle="fictional coffee shop", body="CAD 12.30")
        return base | fields

    def launch(label, payload):
        input_path, output_path = WORK / (label + ".json"), WORK / (label + ".out.json")
        input_path.write_text(json.dumps(payload))
        output_path.unlink(missing_ok=True)
        process = subprocess.Popen(
            [
                "/usr/bin/shortcuts",
                "run",
                shortcut,
                "--input-path",
                str(input_path),
                "--output-path",
                str(output_path),
                "--output-type",
                "public.json",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        return process, output_path

    def finish(label, pending, expected):
        process, output_path = pending
        stdout, stderr = process.communicate(timeout=45)
        if process.returncode:
            raise AssertionError(f"{label}: native error: {stderr or stdout}")
        result = "proceed" if output_path.exists() else "suppressed"
        if output_path.exists():
            payload = json.loads(output_path.read_text())
            assert isinstance(payload, dict), label
            # Validate the production native Date-to-seconds conversion too.
            # Native Shortcuts resolves a date-only reference at local noon.
            expected_clock = time.time() - datetime(2001, 1, 1, 12).timestamp()
            assert abs(float(payload["native_clock"]) - expected_clock) < 10, label
        assert result == expected, f"{label}: expected {expected}, got {result}"
        report.append({"case": label, "result": result})
        print(f"PASS {label}: {result}", flush=True)

    def run(label, payload, expected="proceed"):
        finish(label, launch(label, payload), expected)

    run("wallet-first", event("wallet_transaction", "matching"))
    run("matching-bank", event("bank_notification", "matching", 5), "suppressed")
    run("within-window", event("bank_notification", "matching", 89), "suppressed")
    run("expired-marker", event("bank_notification", "matching", 90))
    # Exercise real concurrent runs; a stored marker must become visible while
    # the earlier CIBC invocation is suspended in its production 15s delay.
    pending = launch("bank-first", event("bank_notification", "bank-first"))
    time.sleep(2)
    run("later-wallet", event("wallet_transaction", "bank-first", 3))
    finish("bank-first", pending, "suppressed")
    run("bank-only", event("bank_notification", "bank-only"))
    run("another-merchant", event("bank_notification", "matching", 5, subtitle="Fictional Bakery"))
    run("another-amount", event("bank_notification", "matching", 5, body="CAD 12.31"))
    run("another-currency", event("bank_notification", "matching", 5, body="USD 12.30"))
    run("another-card-group", event("bank_notification", "another-group", 5))
    run(
        "narrative-amount",
        event("bank_notification", "matching", 5, body="Paid CAD 12.30 on card 1234"),
    )
    run("refund", event("bank_notification", "matching", 5, body="-CAD 12.30"))
    run("zero-amount", event("bank_notification", "matching", 5, body="CAD 0.00"))
    run("same-source-wallet", event("wallet_transaction", "matching", 5))
    run("conflicting-currency", event("bank_notification", "matching", 5, body="CAD 12.30 USD"))

    (WORK / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"{len(report)} native checks passed. Report: {WORK / 'report.json'}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--shortcut", default=NAME, help="Installed test harness name")
    args = parser.parse_args()
    if not args.prepare and not args.run:
        parser.error("Choose --prepare or --run")
    WORK.mkdir(parents=True, exist_ok=True)
    if args.prepare:
        prepare()
    if args.run:
        check(args.shortcut)


if __name__ == "__main__":
    main()
