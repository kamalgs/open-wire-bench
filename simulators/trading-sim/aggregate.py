#!/usr/bin/env python3
"""aggregate.py — merge per-shard trading-sim results into a unified report.

Usage:
    python3 aggregate.py results/*.json
    python3 aggregate.py results/users-*.json results/market-*.json

Each input file is the JSON output of one trading-sim process. The script
merges them by:
  - Summing published and received counts
  - Summing histogram bucket counts across shards for accurate cross-shard
    percentile computation (averaging percentiles is statistically wrong)
  - Reporting per-channel p50 / p99 / p99.9 from the merged histogram

All shards must use the same bucket boundaries (they will, since they share
the same binary and OTel configuration).

Output: a single JSON object to stdout.
"""

import json
import math
import sys
from collections import defaultdict


def pct_from_histogram(bounds_us: list[float], counts: list[int], p: float) -> float:
    """Compute percentile p (0–100) in µs from a histogram using linear interpolation."""
    total = sum(counts)
    if total == 0:
        return 0.0
    target = total * p / 100.0
    cum = 0.0
    for i, count in enumerate(counts):
        cum += count
        if cum < target:
            continue
        lower = bounds_us[i - 1] if i > 0 else 0.0
        if i < len(bounds_us):
            upper = bounds_us[i]
        else:
            # Overflow bucket: extend by one bucket width.
            n = len(bounds_us)
            if n >= 2:
                upper = bounds_us[-1] + (bounds_us[-1] - bounds_us[-2])
            elif n == 1:
                upper = bounds_us[0] * 2
            else:
                upper = 1_000_000.0  # 1s in µs
        prev_cum = cum - count
        frac = (target - prev_cum) / count if count > 0 else 0.0
        return lower + frac * (upper - lower)
    return bounds_us[-1] if bounds_us else 0.0


def merge_channel(results: list[dict], key: str) -> dict:
    total_pub = 0
    total_rx = 0
    total_gaps = 0
    total_dups = 0
    elapsed_sum = 0.0
    n = 0
    merged_bounds: list[float] | None = None
    merged_counts: list[int] | None = None

    for r in results:
        ch = r.get(key, {})
        total_pub += ch.get("published", 0)
        total_rx += ch.get("received", 0)
        total_gaps += ch.get("gaps", 0)
        total_dups += ch.get("dups", 0)
        elapsed_sum += r.get("elapsed_s", 0)
        n += 1

        hist = ch.get("histogram")
        if hist:
            bounds = hist.get("bounds_us", [])
            counts = hist.get("counts", [])
            if merged_bounds is None:
                merged_bounds = bounds
                merged_counts = list(counts)
            elif bounds == merged_bounds:
                for i, c in enumerate(counts):
                    merged_counts[i] += c
            else:
                print(
                    f"Warning: histogram bounds mismatch in {key} — skipping bucket merge",
                    file=sys.stderr,
                )

    avg_elapsed = elapsed_sum / n if n else 1.0

    result: dict = {
        "published": total_pub,
        "received": total_rx,
        "msg_per_sec": round(total_rx / avg_elapsed, 1) if avg_elapsed else 0,
    }

    if total_gaps > 0 or total_dups > 0:
        result["gaps"] = total_gaps
        result["dups"] = total_dups
        expected = total_rx + total_gaps
        result["delivery_ratio"] = round(total_rx / expected, 6) if expected > 0 else 0.0

    if merged_bounds is not None and merged_counts is not None:
        result["p50_us"] = round(pct_from_histogram(merged_bounds, merged_counts, 50), 2)
        result["p99_us"] = round(pct_from_histogram(merged_bounds, merged_counts, 99), 2)
        result["p999_us"] = round(pct_from_histogram(merged_bounds, merged_counts, 99.9), 2)
        result["histogram"] = {
            "bounds_us": merged_bounds,
            "counts": merged_counts,
            "total_samples": sum(merged_counts),
        }

    return result


def main():
    if len(sys.argv) < 2:
        print("Usage: aggregate.py result1.json [result2.json ...]", file=sys.stderr)
        sys.exit(1)

    results = []
    for path in sys.argv[1:]:
        try:
            with open(path) as f:
                results.append(json.load(f))
        except Exception as e:
            print(f"Warning: could not read {path}: {e}", file=sys.stderr)

    if not results:
        print("No valid result files found.", file=sys.stderr)
        sys.exit(1)

    shards_by_role: dict[str, int] = defaultdict(int)
    for r in results:
        shards_by_role[r.get("role", "unknown")] += 1

    total_users = max((r.get("subscriptions", {}).get("users", 0) for r in results), default=0)
    total_algo = max((r.get("subscriptions", {}).get("algo_users", 0) for r in results), default=0)
    visible_per_user = max(
        (r.get("subscriptions", {}).get("visible_per_user", 0) for r in results), default=0
    )

    total_scroll = sum(r.get("scroll_events", 0) for r in results)
    avg_elapsed = sum(r.get("elapsed_s", 0) for r in results) / len(results)

    report = {
        "shards": dict(shards_by_role),
        "elapsed_s": round(avg_elapsed, 2),
        "subscriptions": {
            "total_users": total_users,
            "algo_users": total_algo,
            "visible_per_user": visible_per_user,
            "scroll_events": total_scroll,
            "scroll_rate_per_s": round(total_scroll / avg_elapsed, 1) if avg_elapsed else 0,
        },
        "market": merge_channel(results, "market"),
        "orders": merge_channel(results, "orders"),
        "trades": merge_channel(results, "trades"),
    }

    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
