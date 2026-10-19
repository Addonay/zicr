#!/usr/bin/env python3
"""Run independently verified C/raw/public GPU samples in rotating process order."""
import argparse
from datetime import datetime, timezone
import json
import hashlib
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import shlex


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, default=Path("zig-out/bin/zicr-bench-gl"))
    parser.add_argument("--output", type=Path, default=Path("bench/results/latest-gl.json"))
    parser.add_argument("--launcher", default="", help="Optional argv prefix, e.g. wine; executed without a shell")
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--draws", type=int, default=10000)
    parser.add_argument("--resources", type=int, default=1000)
    parser.add_argument("--bytes", type=int, default=4 * 1024 * 1024)
    parser.add_argument("--samples", type=int, default=9)
    parser.add_argument("--warmup", type=int, default=3)
    args = parser.parse_args()
    if not 1 <= args.rounds <= 30:
        parser.error("--rounds must be 1..30")
    executable = args.executable.resolve(strict=True)
    binary_hash = hashlib.sha256(executable.read_bytes()).hexdigest()
    modes = ["c", "raw", "public"]
    runs = []
    groups = {}
    identity = None
    for round_index in range(args.rounds):
        order = modes[round_index % 3:] + modes[:round_index % 3]
        for mode in order:
            command = [*shlex.split(args.launcher), str(executable), "--mode", mode]
            for name in ("draws", "resources", "bytes", "samples", "warmup"):
                command += ["--" + name, str(getattr(args, name))]
            print(f"round {round_index + 1}/{args.rounds}, {mode}", file=sys.stderr, flush=True)
            if hashlib.sha256(executable.read_bytes()).hexdigest() != binary_hash:
                raise RuntimeError("Benchmark executable changed during measurement")
            process = subprocess.run(command, text=True, capture_output=True, timeout=180)
            if hashlib.sha256(executable.read_bytes()).hexdigest() != binary_hash:
                raise RuntimeError("Benchmark executable changed during measurement")
            if process.returncode:
                raise RuntimeError(f"Benchmark failed ({process.returncode}): {process.stderr}")
            result = json.loads(process.stdout)
            if result["mode"] != mode or result["validation"] or result["statistics"] or result["optimize"] != "fast":
                raise RuntimeError("Benchmark settings do not match the baseline contract")
            current = (result["backend"], result["adapter"], result["zig"], result["cpu"])
            if identity is not None and current != identity:
                raise RuntimeError("Adapter/compiler/CPU changed between benchmark modes")
            identity = current
            runs.append({"round": round_index, "command": command, "result": result})
            for item in result["results"]:
                key = (mode, item["workload"])
                group = groups.setdefault(key, {"samples": [], "operations": item["operations"], "bytes": item["bytes"]})
                if (group["operations"], group["bytes"]) != (item["operations"], item["bytes"]):
                    raise RuntimeError("Workload dimensions changed between samples")
                group["samples"].extend(item["samples_ns"])
    summary = []
    for (mode, workload), group in groups.items():
        values = group["samples"]
        median = statistics.median(values)
        mean = statistics.mean(values)
        deviation = statistics.stdev(values) if len(values) > 1 else 0
        item = {"mode": mode, "workload": workload, "samples": len(values),
                "median_ns": median, "min_ns": min(values), "max_ns": max(values),
                "mean_ns": mean, "stdev_ns": deviation,
                "coefficient_of_variation": deviation / mean if mean else None,
                "cpu_ns_per_operation": median / group["operations"],
                "operations": group["operations"], "bytes": group["bytes"]}
        if group["bytes"]:
            item["GiB_per_second"] = group["bytes"] * 1e9 / median / (1024 ** 3)
        summary.append(item)
    for item in summary:
        baseline = groups[("c", item["workload"])]["samples"]
        item["time_relative_to_c"] = item["median_ns"] / statistics.median(baseline)
    report = {"schema": 1, "timestamp_utc": datetime.now(timezone.utc).isoformat(),
              "platform": platform.platform(), "machine": platform.machine(),
              "binary_sha256": binary_hash,
              "method": "rotating process order; warmups excluded; checked pixels and bytes outside timing; GPU drained between samples",
              "c_readback": "native API equivalent because upstream sokol has no readback API",
              "runs": runs, "summary": summary}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    temporary.write_text(json.dumps(report, indent=2) + "\n")
    temporary.replace(args.output)
    for item in summary:
        print(f"{item['mode']:6s} {item['workload']:8s}: {item['median_ns']/1e6:9.3f} ms, "
              f"CV {item['coefficient_of_variation']:.1%}, C time ratio {item['time_relative_to_c']:.3f}")
    print(f"raw samples and metadata: {args.output}")


if __name__ == "__main__":
    main()
