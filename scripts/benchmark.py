#!/usr/bin/env python3
"""Reproducible MoonBit native/JS vs node-symspell comparison (stdlib only)."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
BENCH = ROOT / "benchmarks"
CACHE = BENCH / ".cache"
GENERATED = BENCH / "generated"
SOURCE_COMMIT = "c239062ae02961df18ab7da1671d01b4388204e0"
SOURCE_URL = (
    f"https://raw.githubusercontent.com/wolfgarbe/SymSpell/{SOURCE_COMMIT}"
    "/SymSpell/frequency_dictionary_en_82_765.txt"
)
SOURCE_SHA256 = "c604e1121e398ae7c7fbf777f11e0a0f2fa66eda932cb9fba1321466cf3acd7b"
BASELINE_VERSION = "0.1.0"
SEED = 20261017


def run(command: list[str], *, cwd: Path = ROOT, timeout: int = 240) -> str:
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        diagnostics = []
        for line in result.stdout.splitlines():
            try:
                item = json.loads(line)
                if isinstance(item, dict) and item.get("level") == "error":
                    diagnostics.append({key: item[key] for key in ("path", "loc", "message") if key in item})
            except json.JSONDecodeError:
                pass
        details = json.dumps(diagnostics, indent=2) if diagnostics else result.stdout[-8000:]
        raise RuntimeError(
            f"Command failed ({result.returncode}): {command!r}\n"
            f"{details}\n{result.stderr[-8000:]}"
        )
    return result.stdout


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def prepare_data(word_limit: int, query_count: int) -> tuple[dict, dict]:
    CACHE.mkdir(parents=True, exist_ok=True)
    source = CACHE / "frequency_dictionary_en_82_765.txt"
    if not source.exists():
        print("Downloading the pinned upstream frequency dictionary...", flush=True)
        with urlopen(SOURCE_URL, timeout=60) as response:
            downloaded = response.read()
        if digest(downloaded) != SOURCE_SHA256:
            raise ValueError("Downloaded dictionary SHA-256 does not match the pinned source")
        source.write_bytes(downloaded)
    raw = source.read_bytes()
    if digest(raw) != SOURCE_SHA256:
        raise ValueError(f"Cached dictionary checksum mismatch: remove {source} and retry")
    entries = []
    # Shared code-point/UTF-16 semantics and exact Number/Int64 frequencies.
    for line in raw.decode("utf-8-sig").splitlines():
        term, count = line.split()
        if re.fullmatch("[a-z]+", term):
            count = int(count)
            if not 0 < count <= 2**53 - 1:
                raise ValueError("The comparison requires exact JavaScript integer frequencies")
            entries.append((term, count))
    if word_limit:
        entries = entries[:word_limit]
    words = [term for term, _ in entries]
    if len(set(words)) != len(words):
        raise ValueError("Duplicate dictionary terms")
    eligible = [word for word in words if len(word) >= 4]
    rng = random.Random(SEED)
    selected = [rng.choice(eligible) for _ in range(query_count)]
    typos = []
    for index, word in enumerate(selected):
        position = rng.randrange(len(word) - 1)
        if index % 4 == 0:
            changed = word[:position] + word[position + 1 :]
        elif index % 4 == 1:
            changed = word[:position] + rng.choice("abcdefghijklmnopqrstuvwxyz") + word[position:]
        elif index % 4 == 2:
            replacement = rng.choice([letter for letter in "abcdefghijklmnopqrstuvwxyz" if letter != word[position]])
            changed = word[:position] + replacement + word[position + 1 :]
        else:
            changed = word[:position] + word[position + 1] + word[position] + word[position + 2 :]
        typos.append(changed)
    # In-range lengths prevent the max-word-length rejection from dominating.
    misses = ["".join(rng.choice("jqxz") for _ in range(rng.randint(5, 12))) for _ in range(query_count)]
    common = [word for word in words[:1000] if 3 <= len(word) <= 8]
    compounds = []
    segments = []
    for index in range(32):
        a, b, c = [rng.choice(common) for _ in range(3)]
        compounds.append(a + b + " " + c if index % 2 else a + " " + b[:-1] + " " + c)
        segments.append(a + b + c)
    corpus_words = [rng.choice(words[: min(4096, len(words))]) for _ in range(16384)]
    data = {
        "dictionary_text": "".join(f"{term} {count}\n" for term, count in entries),
        "corpus_text": ", ".join(corpus_words),
        "exact_queries": selected,
        "typo_queries": typos,
        "miss_queries": misses,
        "compound_queries": compounds,
        "segmentation_queries": segments,
    }
    encoded = json.dumps(data, sort_keys=True, separators=(",", ":")).encode()
    (CACHE / "workload.json").write_bytes(encoded)
    metadata = {
        "source_url": SOURCE_URL,
        "source_sha256": SOURCE_SHA256,
        "workload_sha256": digest(encoded),
        "words": len(entries),
        "requested_words": word_limit,
        "queries_per_lookup_case": query_count,
        "compound_queries": len(compounds),
        "segmentation_queries": len(segments),
        "corpus_tokens": len(corpus_words),
        "seed": SEED,
        "alphabet": "lowercase ASCII; complete eligible prefix of the frequency-ranked upstream dictionary",
        "typos": "equal counts of one deletion, insertion, replacement, and adjacent transposition; some edits may form existing words",
    }
    return data, metadata


def prepare_drivers(data: dict, install: bool) -> dict[str, list[str]]:
    package = BENCH / "node_modules/node-symspell/package.json"
    if install or not package.exists():
        print("Installing the locked JavaScript comparison dependencies...", flush=True)
        run(["npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund"], cwd=BENCH)
    if json.loads(package.read_text())["version"] != BASELINE_VERSION:
        raise ValueError("Incorrect baseline version; rerun with --install")
    GENERATED.mkdir(exist_ok=True)
    (GENERATED / "moon.pkg").write_text(
        'import {\n  "albertoforni/symspell",\n  "moonbitlang/core/bench",\n'
        '  "moonbitlang/core/env",\n  "moonbitlang/core/string",\n}\n'
        'pkgtype(kind: "executable")\nsupported_targets = "js+native"\n'
        'options(targets: {"gc_js.mbt": ["js"], "gc_native.mbt": ["native"]})\n'
    )
    (GENERATED / "gc_js.mbt").write_text(
        '///|\nextern "js" fn collect_garbage() -> Unit =\n'
        '  #| () => { if (globalThis.gc) globalThis.gc(); }\n'
        '///|\nfn argument_offset() -> Int { 2 }\n'
    )
    (GENERATED / "gc_native.mbt").write_text('///|\nfn collect_garbage() -> Unit { () }\n///|\nfn argument_offset() -> Int { 1 }\n')
    (GENERATED / "main.mbt").write_text((BENCH / "driver.mbt.in").read_text())
    blocks = ["// Generated from the checksummed benchmark workload. Do not commit.\n"]
    for name, value in data.items():
        annotation = "String" if isinstance(value, str) else "Array[String]"
        literal = (
            " +\n  ".join(json.dumps(value[index : index + 4096]) for index in range(0, len(value), 4096))
            if isinstance(value, str)
            else json.dumps(value, indent=2)
        )
        blocks.append(f"///|\nlet {name} : {annotation} = {literal}\n")
    (GENERATED / "data.mbt").write_text("\n".join(blocks))
    commands = {
        "javascript": ["node", "--expose-gc", str(BENCH / "javascript.cjs"), str(CACHE / "workload.json")]
    }
    for target in ("js", "native"):
        print(f"Building MoonBit {target} in release mode...", flush=True)
        output = run(["moon", "build", "--release", "--deny-warn", "--target", target, "benchmarks/generated", "--output-json"])
        (CACHE / f"build-{target}.jsonl").write_text(output)
        suffix = ".js" if target == "js" else ".exe"
        artifact = ROOT / f"_build/{target}/release/build/benchmarks/generated/generated{suffix}"
        if not artifact.exists():
            raise ValueError(f"Expected artifact missing: {artifact}; see {CACHE / f'build-{target}.jsonl'}")
        commands[f"moonbit_{target}"] = ["node", "--expose-gc", str(artifact)] if target == "js" else [str(artifact)]
    return commands


def parse_validation(output: str) -> dict:
    parsed: dict = {"words": {}, "compound": {}, "segmentation": {}, "stats": {}}
    for line in output.splitlines():
        parts = line.split("\t")
        if parts[0] == "stat":
            parsed["stats"][parts[1]] = int(parts[2])
        elif parts[0] == "query":
            parsed["words"][parts[1], int(parts[2])] = []
        elif parts[0] == "word":
            parsed["words"][parts[1], int(parts[2])].append((parts[3], int(parts[4]), int(parts[5])))
        elif parts[0] == "compound":
            parsed["compound"][int(parts[1])] = (parts[2], int(parts[3]), int(parts[4]))
        elif parts[0] == "segmentation":
            parsed["segmentation"][int(parts[1])] = (parts[2], int(parts[3]), float(parts[4]))
        else:
            raise ValueError(f"Unexpected validation output: {line[:200]}")
    return parsed


def compare_validations(reference: dict, candidate: dict) -> dict:
    if reference["words"].keys() != candidate["words"].keys():
        raise ValueError("Drivers did not validate the same word queries")
    differences: dict[str, list] = {}
    for (name, index), expected in reference["words"].items():
        actual = candidate["words"][name, index]
        # Lexical tiebreaking is deliberately stronger in the MoonBit port.
        # TOP may choose another term only when both distance and count tie.
        equal = (
            [item[1:] for item in expected] == [item[1:] for item in actual]
            if name.endswith("_top")
            else sorted(expected) == sorted(actual)
        )
        if not equal:
            differences.setdefault(name, []).append({"query_index": index, "expected": expected, "actual": actual})
    for name in ("compound", "segmentation"):
        if reference[name].keys() != candidate[name].keys():
            raise ValueError(f"Drivers did not validate the same {name} queries")
        for index, expected in reference[name].items():
            actual = candidate[name][index]
            equal = expected == actual if name == "compound" else (
                expected[:2] == actual[:2] and math.isclose(expected[2], actual[2], rel_tol=0.0, abs_tol=1e-9)
            )
            if not equal:
                differences.setdefault(name, []).append({"query_index": index, "expected": expected, "actual": actual})
    for name in ("words", "corpus_tokens", "corpus_words"):
        if reference["stats"].get(name) != candidate["stats"].get(name):
            raise ValueError(f"Dictionary/corpus validation mismatch: {name}")
    return {"mismatch_counts": {name: len(items) for name, items in differences.items()}, "examples": {name: items[:3] for name, items in differences.items()}}


def timed_run(command: list[str]) -> tuple[str, int | None]:
    if sys.platform.startswith("linux") and hasattr(os, "wait4"):
        # wait4 returns the kernel's actual per-child high-water RSS. Reaping
        # our own child avoids cumulative RUSAGE_CHILDREN maxima, sampling
        # estimates, and a dependency on the optional GNU time executable.
        with tempfile.TemporaryFile(mode="w+t") as stdout, tempfile.TemporaryFile(mode="w+t") as stderr:
            process = subprocess.Popen(command, cwd=ROOT, stdout=stdout, stderr=stderr, text=True)
            deadline = time.monotonic() + 300
            try:
                while True:
                    pid, status, usage = os.wait4(process.pid, os.WNOHANG)
                    if pid:
                        process.returncode = os.waitstatus_to_exitcode(status)
                        break
                    if time.monotonic() > deadline:
                        raise subprocess.TimeoutExpired(command, 300)
                    time.sleep(0.05)
            finally:
                if process.returncode is None:
                    process.kill()
                    _, status, _ = os.wait4(process.pid, 0)
                    process.returncode = os.waitstatus_to_exitcode(status)
            stdout.seek(0)
            stderr.seek(0)
            output, errors = stdout.read(), stderr.read()
        if process.returncode:
            raise RuntimeError(f"Benchmark failed ({process.returncode}): {command!r}\n{output[-3000:]}\n{errors[-3000:]}")
        return output, usage.ru_maxrss
    timer = Path("/usr/bin/time")
    if not timer.exists():
        return run(command), None
    result = subprocess.run([str(timer), "-f", "BENCH_RSS_KIB=%M", *command], cwd=ROOT, text=True, capture_output=True, timeout=300)
    if result.returncode:
        raise RuntimeError(f"Benchmark failed: {command!r}\n{result.stdout[-3000:]}\n{result.stderr[-3000:]}")
    match = re.search(r"BENCH_RSS_KIB=(\d+)", result.stderr)
    return result.stdout, int(match[1]) if match else None


def summarize(samples: list[float]) -> dict:
    return {"median": statistics.median(samples), "min": min(samples), "max": max(samples), "samples": samples}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--words", type=int, default=10000, help="frequency-ranked dictionary prefix; 0 uses all eligible words")
    parser.add_argument("--queries", type=int, default=512)
    parser.add_argument("--samples", type=int, default=5, help="independent fresh processes per engine")
    parser.add_argument("--warmup-ms", type=float, default=250)
    parser.add_argument("--sample-ms", type=float, default=500)
    parser.add_argument("--install", action="store_true", help="reinstall locked npm dependencies")
    parser.add_argument("--cpu", type=int, help="pin this process and its children to one available CPU")
    parser.add_argument("--output", type=Path, help="JSON report path; default benchmarks/.cache/latest.json")
    args = parser.parse_args()
    if args.words < 0 or (args.words and args.words < 100) or args.queries < 4 or args.samples < 1 or args.warmup_ms <= 0 or args.sample_ms <= 0:
        parser.error("use words=0 or >=100, queries>=4, samples>=1, and positive timing windows")
    if args.cpu is not None:
        os.sched_setaffinity(0, {args.cpu})
    data, workload = prepare_data(args.words, args.queries)
    commands = prepare_drivers(data, args.install)
    print(f"Validating {workload['words']:,} words and all query results...", flush=True)
    validations = {}
    for engine, command in commands.items():
        output = run([*command, "validate"])
        (CACHE / f"validation-{engine}.tsv").write_text(output)
        validations[engine] = parse_validation(output)
    cross_target = compare_validations(validations["moonbit_js"], validations["moonbit_native"])
    if cross_target["mismatch_counts"] or validations["moonbit_js"]["stats"] != validations["moonbit_native"]["stats"]:
        raise ValueError(f"MoonBit target mismatch: {cross_target}")
    comparison = compare_validations(validations["javascript"], validations["moonbit_js"])
    word_mismatches = {name: count for name, count in comparison["mismatch_counts"].items() if name not in ("compound", "segmentation")}
    if word_mismatches:
        raise ValueError(f"Word lookup mismatch; refusing timing claims: {comparison}")
    print(f"Validation: {comparison['mismatch_counts'] or 'all results agree'}", flush=True)
    measurements = {engine: {} for engine in commands}
    suite_rss = {engine: [] for engine in commands}
    dictionary_rss = {}
    for engine, command in commands.items():
        _, memory = timed_run([*command, "memory"])
        dictionary_rss[engine] = memory
    engines = list(commands)
    for sample in range(args.samples):
        # Rotate engines between independent process trials to reduce order bias.
        order = engines[sample % len(engines) :] + engines[: sample % len(engines)]
        for engine in order:
            print(f"Sample {sample + 1}/{args.samples}: {engine}", flush=True)
            output, memory = timed_run([*commands[engine], str(args.warmup_ms), str(args.sample_ms)])
            (CACHE / f"sample-{sample}-{engine}.tsv").write_text(output)
            suite_rss[engine].append(memory)
            for line in output.splitlines():
                parts = line.split("\t")
                if parts[0] == "metric":
                    elapsed, operations = float(parts[2]), int(parts[3])
                    if operations <= 0 or not math.isfinite(elapsed) or elapsed <= 0:
                        raise ValueError(f"Invalid benchmark measurement: {line}")
                    measurements[engine].setdefault(parts[1], []).append(elapsed / operations)
    expected_common = {"build", "corpus", "exact_top", "typo_top", "typo_closest", "typo_all", "miss_top", "compound", "segmentation"}
    for engine, cases in measurements.items():
        expected = expected_common if engine == "javascript" else expected_common | {"snapshot_save", "snapshot_restore"}
        if cases.keys() != expected or any(len(values) != args.samples for values in cases.values()):
            raise ValueError(f"Missing or duplicate measurements for {engine}")
    metrics = {engine: {case: summarize(values) for case, values in cases.items()} for engine, cases in measurements.items()}
    speedups = {}
    for engine in ("moonbit_js", "moonbit_native"):
        speedups[engine] = {
            case: metrics["javascript"][case]["median"] / timing["median"]
            for case, timing in metrics[engine].items()
            if case in metrics["javascript"] and case not in comparison["mismatch_counts"]
        }
    cpu_model = next((line.split(":", 1)[1].strip() for line in Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name")), platform.processor()) if Path("/proc/cpuinfo").exists() else platform.processor()
    report = {
        "schema_version": 1,
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "environment": {
            "platform": platform.platform(), "cpu": cpu_model,
            "python": platform.python_version(),
            "cpu_affinity": sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None,
            "node": run(["node", "--version"]).strip(),
            "moon": run(["moon", "version", "--all"]).strip(),
            "baseline": f"node-symspell@{BASELINE_VERSION}",
            "baseline_lock_sha256": digest((BENCH / "package-lock.json").read_bytes()),
            "git_commit": run(["git", "rev-parse", "HEAD"]).strip(),
            "git_status": run(["git", "status", "--short"]).strip(),
            "driver_sha256": digest((BENCH / "driver.mbt.in").read_bytes()),
            "javascript_driver_sha256": digest((BENCH / "javascript.cjs").read_bytes()),
            "symspell_source_sha256": digest(b"".join(path.read_bytes() for path in sorted(ROOT.glob("*.mbt")) if not path.name.endswith(("_test.mbt", "_wbtest.mbt")))),
        },
        "workload": workload,
        "configuration": {"samples": args.samples, "warmup_ms": args.warmup_ms, "minimum_sample_ms": args.sample_ms, "max_edit_distance": 2, "prefix_length": 7, "count_threshold": 1},
        "validation": comparison,
        "snapshot_bytes": validations["moonbit_js"]["stats"]["snapshot_bytes"],
        "microseconds_per_operation": metrics,
        "speedup_vs_node_symspell": speedups,
        "dictionary_process_peak_rss_kib": dictionary_rss,
        "suite_process_peak_rss_kib": suite_rss,
        "notes": [
            "Medians of per-process batch means; these are not individual-query tail latencies.",
            "Compilation, process startup, source I/O, dictionary setup for queries, and validation are excluded from timings.",
            "Build includes parsing valid frequency text and constructing the index. Corpus uses 16,384 deterministic synthetic tokens from real dictionary words.",
            "JavaScript file-loading methods are adapted to in-memory input using the package's unmodified insertion and tokenization methods.",
            "Memory is Linux process peak RSS including runtime, workload input, and index; not isolated retained dictionary size.",
            "No snapshot speedup is claimed: the JavaScript baseline has no equivalent API. Phrase speedups are suppressed if outputs differ.",
            "TOP validation permits lexical ties with identical distance/frequency; CLOSEST and ALL compare full result sets outside timings.",
        ],
    }
    destination = args.output or CACHE / "latest.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(report, indent=2) + "\n")
    for case, timing in metrics["javascript"].items():
        ratios = " ".join(
            f"{engine}={speedups[engine][case]:.2f}x" if case in speedups[engine] else f"{engine}=outputs differ"
            for engine in speedups
        )
        print(f"{case:18s} JS baseline={timing['median']:10.3f} us/op  {ratios}")
    print(f"Report: {destination}")
    # Keep subsequent normal moon fmt/info/check runs free of generated inputs.
    # Failed runs retain the driver package for diagnosis.
    shutil.rmtree(GENERATED)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, OSError, subprocess.TimeoutExpired) as error:
        sys.exit(str(error))
