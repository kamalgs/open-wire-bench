#!/usr/bin/env python3
"""
cost.py — resource usage and cost report for the open-wire-bench cluster.

Queries AWS for all tagged instances and NLBs, computes uptime-based cost,
and optionally prints bench results from a saved JSON file.

Usage:
  python3 scripts/cost.py
  python3 scripts/cost.py --region eu-west-1
  python3 scripts/cost.py --result results/aws-market-feed-abc123-1234567890.json
  python3 scripts/cost.py --last          # auto-pick the most recent result file
"""

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import boto3

# ── On-demand prices (us-east-1, Linux, April 2026) ──────────────────────────
# Update when switching regions or adding instance types.
ON_DEMAND_USD_HR: dict[str, float] = {
    "t3.micro":     0.0104,
    "t3.small":     0.0208,
    "t3.medium":    0.0416,
    "t3.large":     0.0832,
    "t3.xlarge":    0.1664,
    "c5.xlarge":    0.170,
    "c5.2xlarge":   0.340,
    "c5.4xlarge":   0.680,
    "c5n.large":    0.108,
    "c5n.xlarge":   0.216,
    "c5n.2xlarge":  0.432,
    "c5n.4xlarge":  0.864,
    "c5n.9xlarge":  1.944,
    "c5n.18xlarge": 3.888,
    "m5.xlarge":    0.192,
    "m5.2xlarge":   0.384,
}

# NLB base charge (us-east-1): $0.0225/hr + LCU (negligible for benchmarks)
NLB_USD_HR = 0.0225

CLUSTER_TAG = "open-wire-bench"
BOLD  = "\033[1m"
DIM   = "\033[2m"
GREEN = "\033[32m"
CYAN  = "\033[36m"
RESET = "\033[0m"


def hdr(s: str) -> None:
    print(f"\n{BOLD}{s}{RESET}")


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def hours_since(dt: datetime) -> float:
    return (now_utc() - dt).total_seconds() / 3600


def spot_price(ec2, instance_type: str, az: str) -> float | None:
    """Current spot price for an instance type in a given AZ."""
    try:
        resp = ec2.describe_spot_price_history(
            InstanceTypes=[instance_type],
            ProductDescriptions=["Linux/UNIX"],
            AvailabilityZone=az,
            MaxResults=1,
        )
        items = resp.get("SpotPriceHistory", [])
        if items:
            return float(items[0]["SpotPrice"])
    except Exception:
        pass
    return None


def instance_price(ec2, inst: dict) -> tuple[float, str]:
    """Return (price_per_hour, price_type) for an instance."""
    itype = inst["InstanceType"]
    lifecycle = inst.get("InstanceLifecycle", "on-demand")  # "spot" | "on-demand"

    if lifecycle == "spot":
        az = inst["Placement"]["AvailabilityZone"]
        price = spot_price(ec2, itype, az)
        if price is not None:
            return price, "spot"
        # fallback: use on-demand
    od = ON_DEMAND_USD_HR.get(itype)
    if od:
        return od, "on-demand"
    return 0.0, "unknown"


def tag(inst: dict, key: str, default: str = "") -> str:
    for t in inst.get("Tags", []):
        if t["Key"] == key:
            return t["Value"]
    return default


def fmt_usd(v: float) -> str:
    return f"${v:.4f}"


def fmt_hrs(h: float) -> str:
    if h < 1:
        return f"{h*60:.0f}m"
    return f"{h:.1f}h"


def report_instances(region: str) -> float:
    ec2 = boto3.client("ec2", region_name=region)
    resp = ec2.describe_instances(
        Filters=[
            {"Name": "tag:Project", "Values": [CLUSTER_TAG]},
            {"Name": "instance-state-name", "Values": ["running", "pending"]},
        ]
    )

    rows = []
    total = 0.0
    for r in resp["Reservations"]:
        for inst in r["Instances"]:
            name      = tag(inst, "Name", inst["InstanceId"])
            role      = tag(inst, "Role", "?")
            itype     = inst["InstanceType"]
            launch    = inst["LaunchTime"]
            uptime_h  = hours_since(launch)
            price, pt = instance_price(ec2, inst)
            cost      = price * uptime_h
            total    += cost
            rows.append((name, role, itype, pt, uptime_h, price, cost))

    if not rows:
        print("  (no running instances tagged Project=open-wire-bench)")
        return 0.0

    col = [28, 9, 14, 10, 8, 10, 10]
    hfmt = f"{{:<{col[0]}}} {{:<{col[1]}}} {{:<{col[2]}}} {{:<{col[3]}}} {{:>{col[4]}}} {{:>{col[5]}}} {{:>{col[6]}}}"
    rfmt = hfmt

    hdr("Instances")
    print("  " + hfmt.format("Name", "Role", "Type", "Pricing", "Uptime", "$/hr", "Cost"))
    print("  " + "  ".join("─" * w for w in col))
    for name, role, itype, pt, uh, price, cost in sorted(rows, key=lambda r: r[1]):
        print("  " + rfmt.format(name, role, itype, pt, fmt_hrs(uh), fmt_usd(price), fmt_usd(cost)))
    print("  " + " " * (sum(col[:6]) + 12) + "──────────")
    print("  " + " " * (sum(col[:6]) + 12) + f"{BOLD}{fmt_usd(total)}{RESET}")

    return total


def report_nlbs(region: str) -> float:
    elbv2 = boto3.client("elbv2", region_name=region)
    lbs = elbv2.describe_load_balancers()["LoadBalancers"]

    rows = []
    total = 0.0
    for lb in lbs:
        name = lb["LoadBalancerName"]
        if CLUSTER_TAG not in name:
            continue
        created   = lb["CreatedTime"]
        uptime_h  = hours_since(created)
        cost      = NLB_USD_HR * uptime_h
        total    += cost
        rows.append((name, uptime_h, cost))

    if not rows:
        return 0.0

    hdr("Network Load Balancers")
    col = [50, 8, 10]
    hfmt = f"{{:<{col[0]}}} {{:>{col[1]}}} {{:>{col[2]}}}"
    print("  " + hfmt.format("Name", "Uptime", "Cost"))
    print("  " + "  ".join("─" * w for w in col))
    for name, uh, cost in rows:
        print("  " + hfmt.format(name, fmt_hrs(uh), fmt_usd(cost)))
    print("  " + " " * (col[0] + col[1] + 4) + "──────────")
    print("  " + " " * (col[0] + col[1] + 4) + f"{BOLD}{fmt_usd(total)}{RESET}")

    return total


def report_bench_result(path: str) -> None:
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception as e:
        print(f"  Could not read result file: {e}")
        return

    hdr(f"Bench result — {data.get('scenario','?')} / {data.get('env','?')}")

    def ms(broker: str, key: str) -> str:
        v = data.get(broker, {}).get("sub" if "sub" in key else "pub", {}).get(key)
        if v is None:
            return "?"
        try:
            return f"{float(v):,.0f}"
        except Exception:
            return str(v)

    def us(broker: str, key: str) -> str:
        v = data.get(broker, {}).get("sub", {}).get(key)
        if v is None:
            return "?"
        try:
            return f"{float(v):.0f} µs"
        except Exception:
            return str(v)

    col = [24, 18, 18]
    hfmt = f"  {{:<{col[0]}}} {{:>{col[1]}}} {{:>{col[2]}}}"
    div  = "  " + f"{'─'*col[0]}  {'─'*col[1]}  {'─'*col[2]}"

    print(hfmt.format("", "open-wire :4222", "nats-server :4333"))
    print(div)
    def sub_ms(broker: str) -> str:
        v = data.get(broker, {}).get("sub", {}).get("msg_per_sec")
        if v is None:
            return "?"
        try:
            return f"{float(v):,.0f}"
        except Exception:
            return str(v)

    print(hfmt.format("Published (msg/s)",  ms("open_wire","msg_per_sec"),  ms("nats_server","msg_per_sec")))
    print(hfmt.format("Delivered (msg/s)",  sub_ms("open_wire"),  sub_ms("nats_server")))
    print(hfmt.format("Latency p50",        us("open_wire","p50_us"),  us("nats_server","p50_us")))
    print(hfmt.format("Latency p99",        us("open_wire","p99_us"),  us("nats_server","p99_us")))

    start = data.get("bench_start")
    end   = data.get("bench_end")
    if start and end:
        dur = end - start
        print(f"\n  Duration: {dur}s   SHA: {data.get('sha','?')}")


def latest_result(results_dir: str) -> str | None:
    p = Path(results_dir)
    if not p.is_dir():
        return None
    files = sorted(p.glob("*.json"), key=lambda f: f.stat().st_mtime, reverse=True)
    return str(files[0]) if files else None


def main() -> None:
    ap = argparse.ArgumentParser(description="open-wire-bench cost + resource report")
    ap.add_argument("--region",  default="us-east-1")
    ap.add_argument("--result",  default=None, help="path to bench result JSON")
    ap.add_argument("--last",    action="store_true", help="use most recent result file")
    ap.add_argument("--results-dir", default="results")
    args = ap.parse_args()

    print(f"\n{BOLD}open-wire-bench — cost report{RESET}  {DIM}{now_utc().strftime('%Y-%m-%d %H:%M UTC')}{RESET}")
    print(f"  region: {args.region}  tag: Project={CLUSTER_TAG}")

    instance_cost = report_instances(args.region)
    nlb_cost      = report_nlbs(args.region)
    total         = instance_cost + nlb_cost

    hdr("Total estimated cost")
    print(f"  Instances : {fmt_usd(instance_cost)}")
    print(f"  NLBs      : {fmt_usd(nlb_cost)}")
    print(f"  {'-'*18}")
    print(f"  {BOLD}Total     : {fmt_usd(total)}{RESET}")
    print(f"\n  {DIM}Note: spot prices are current market rate, not exact billed amount.{RESET}")
    print(f"  {DIM}NLB cost excludes LCU charges (typically <$0.01 for bench workloads).{RESET}")

    result_path = args.result
    if args.last:
        result_path = latest_result(args.results_dir)
    if result_path:
        report_bench_result(result_path)

    print()


if __name__ == "__main__":
    main()
