"""Общее: настройки, логи, чтение данных, подсчёт пар, контрольные числа."""
import csv
import hashlib
import json
import logging
import os
import sys
import time
from itertools import combinations
from pathlib import Path

RUN_ID = os.getenv("RUN_ID", "manual")
FENCING = os.getenv("FENCING", "0") == "1"
ZK_HOSTS = os.getenv("ZK_HOSTS", "zoo1:2181,zoo2:2181,zoo3:2181")
ZK_ROOT = os.getenv("ZK_ROOT", f"/failover/{RUN_ID}")
SESSION_TIMEOUT = float(os.getenv("SESSION_TIMEOUT", "10"))
CHUNKS = int(os.getenv("CHUNKS", "30"))
CHUNK_DELAY = float(os.getenv("CHUNK_DELAY", "1.0"))
SINK_URL = os.getenv("SINK_URL", "http://sink:8080")
DATA_FILE = Path(os.getenv("DATA_FILE", "/data/php_vacancies.csv"))
STATE_DIR = Path(os.getenv("STATE_DIR", "/state"))
LOG_DIR = Path(os.getenv("LOG_DIR", "/logs")) / RUN_ID


def setup_logging(name):
    """Лог в консоль и в файл logs/<RUN_ID>/<name>.log, время UTC с миллисекундами."""
    fmt = logging.Formatter("%(asctime)s.%(msecs)03dZ [%(name)s] %(message)s", "%Y-%m-%dT%H:%M:%S")
    fmt.converter = time.gmtime
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger(name)
    logger.setLevel(logging.INFO)
    for handler in (logging.StreamHandler(sys.stdout), logging.FileHandler(LOG_DIR / f"{name}.log", encoding="utf-8")):
        handler.setFormatter(fmt)
        logger.addHandler(handler)
    return logger


def load_skill_lists():
    """Списки навыков каждой вакансии (столбец skills_json из прошлого ДЗ)."""
    csv.field_size_limit(10**9)
    with open(DATA_FILE, encoding="utf-8", newline="") as f:
        return [json.loads(row["skills_json"]) for row in csv.DictReader(f)]


def count_pairs(skill_lists, counter):
    """Пары навыков, как в MapReduce из прошлого ДЗ."""
    for skills in skill_lists:
        counter.update(combinations(skills, 2))


def pairs_digest(pairs):
    """Контрольные числа: число пар, сумма частот, топ-5 и хэш всего списка."""
    digest, total = hashlib.sha256(), 0
    for (a, b), n in sorted(pairs.items()):
        digest.update(f"{a}\t{b}\t{n}\n".encode("utf-8"))
        total += n
    top = sorted(pairs.items(), key=lambda kv: (-kv[1], kv[0]))[:5]
    return {"unique_pairs": len(pairs), "total_frequency": total,
            "top5": [[a, b, n] for (a, b), n in top], "sha256": digest.hexdigest()}


def reference_pairs(csv_path):
    """Эталон: results/mapreduce_pairs.csv из прошлого ДЗ."""
    with open(csv_path, encoding="utf-8", newline="") as f:
        return {(r["skill_1"], r["skill_2"]): int(float(r["frequency"])) for r in csv.DictReader(f)}