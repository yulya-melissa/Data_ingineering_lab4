#!/usr/bin/env python3
"""Сверка принятых результатов с mapreduce_pairs.csv из предыдущего ДЗ."""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
from common import pairs_digest, reference_pairs  # noqa: E402


def check(results_dir: Path, reference_csv: Path) -> tuple[bool, list[str]]:
    ref = pairs_digest(reference_pairs(reference_csv))
    lines = [f"Эталон (ДЗ №3): пар={ref['unique_pairs']}, сумма частот={ref['total_frequency']}, "
             f"sha256={ref['sha256'][:16]}…, топ-1={ref['top5'][0]}"]
    files = sorted(results_dir.glob("result_*.json"))
    ok = bool(files)
    for path in files:
        data = json.loads(path.read_text(encoding="utf-8"))
        res = data["result"]
        same = res["sha256"] == ref["sha256"] and res["unique_pairs"] == ref["unique_pairs"] \
            and res["total_frequency"] == ref["total_frequency"]
        ok &= same
        lines.append(f"{path.name}: эпоха={data['epoch']} узел={data['node']} пар={res['unique_pairs']} "
                     f"сумма={res['total_frequency']} sha256={res['sha256'][:16]}… -> "
                     f"{'СОВПАЛО' if same else 'НЕ СОВПАЛО'}")
    lines.append(f"Принятых результатов: {len(files)}")
    return ok, lines


if __name__ == "__main__":
    good, out = check(ROOT / "state" / "sink" / "results", ROOT / "data" / "mapreduce_pairs.csv")
    print("\n".join(out))
    sys.exit(0 if good else 1)
