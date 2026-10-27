"""Run one bounded job; record RSS/system headroom without process arguments."""

import argparse
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import psutil

p = argparse.ArgumentParser()
p.add_argument("--seconds", type=int, required=True)
p.add_argument("--label", required=True)
p.add_argument("--rss-gb", type=float, default=18)
p.add_argument("--runs-dir", default=".local/finetune/runs")
p.add_argument("--overall-seconds", type=int, default=4 * 3600)
p.add_argument("command", nargs=argparse.REMAINDER)
a = p.parse_args()
root = Path(a.runs_dir)
root.mkdir(parents=True, exist_ok=True)
deadline_path = root / "overall_deadline.json"
if not deadline_path.exists():
    deadline_path.write_text(
        json.dumps({"started": time.time(), "deadline": time.time() + a.overall_seconds})
    )
deadline = json.loads(deadline_path.read_text())["deadline"]
if time.time() >= deadline:
    sys.exit("Overall experiment time limit expired; start a deliberate new session to continue.")
cmd = a.command[1:] if a.command[:1] == ["--"] else a.command
start = time.time()
limit = min(start + a.seconds, deadline)
active = [
    {"pid": p.pid, "name": p.info["name"], "rss": p.info["memory_info"].rss}
    for p in psutil.process_iter(["name", "memory_info"])
    if any(t in (p.info["name"] or "").lower() for t in ["python", "ollama", "mlx"])
]
report = {
    "label": a.label,
    "command": cmd,
    "active_processes_before": active,
    "start": start,
    "time_limit_seconds": limit - start,
}
print(json.dumps({"job": a.label, "active_processes_before": active}), flush=True)
with (root / f"{a.label}.log").open("w") as log:
    proc = subprocess.Popen(
        cmd,
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        env={
            **os.environ,
            "PYTHONUNBUFFERED": "1",
            "HF_HUB_DISABLE_TELEMETRY": "1",
            "TOKENIZERS_PARALLELISM": "false",
        },
    )
    peak = 0
    minimum = psutil.virtual_memory().available
    low = 0
    reason = None
    while proc.poll() is None:
        try:
            parent = psutil.Process(proc.pid)
            rss = sum(
                p.memory_info().rss
                for p in [parent] + parent.children(recursive=True)
                if p.is_running()
            )
        except psutil.Error:
            rss = 0
        peak = max(peak, rss)
        available = psutil.virtual_memory().available
        minimum = min(minimum, available)
        low = low + 1 if available < 1_000_000_000 else 0
        if time.time() >= limit:
            reason = "time_limit"
        elif rss > a.rss_gb * 1e9:
            reason = "rss_limit"
        elif low >= 3:
            reason = "system_memory_headroom"
        if reason:
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
            break
        time.sleep(1)
    report.update(
        elapsed_seconds=time.time() - start,
        returncode=proc.wait(),
        stop_reason=reason,
        peak_process_tree_rss_bytes=peak,
        min_system_available_bytes=minimum,
    )
(root / f"{a.label}.json").write_text(json.dumps(report, indent=2))
print(json.dumps(report), flush=True)
sys.exit(report["returncode"] if not reason else 124)
