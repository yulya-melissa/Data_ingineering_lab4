"""Координатор: выбор лидера через ZooKeeper, расчёт пар по частям с чекпоинтами."""
import json
import os
import sys
import time
import urllib.error
import urllib.request
from collections import Counter

from kazoo.client import KazooClient
from kazoo.exceptions import BadVersionError, NodeExistsError

from common import (CHUNK_DELAY, CHUNKS, SESSION_TIMEOUT, SINK_URL, STATE_DIR, ZK_HOSTS, ZK_ROOT,
                    count_pairs, load_skill_lists, pairs_digest, setup_logging)

NODE = sys.argv[1]                      # coord1 или coord2
log = setup_logging(NODE)
CKPT_DIR = STATE_DIR / "checkpoints"
CKPT_DIR.mkdir(parents=True, exist_ok=True)


def next_epoch(zk):
    """Эпоха — счётчик в ZooKeeper: каждый новый лидер увеличивает его на 1."""
    path = f"{ZK_ROOT}/epoch"
    try:
        zk.create(path, b"0")
    except NodeExistsError:
        pass
    while True:
        raw, stat = zk.get(path)
        try:
            zk.set(path, str(int(raw) + 1).encode(), version=stat.version)
            return int(raw) + 1
        except BadVersionError: 
            pass


def save_checkpoint(epoch, next_chunk, pairs):
    path = CKPT_DIR / f"epoch{epoch}.json"
    tmp = CKPT_DIR / f"epoch{epoch}.tmp"
    tmp.write_text(json.dumps({"next_chunk": next_chunk, "pairs": [[a, b, n] for (a, b), n in pairs.items()]}))
    os.replace(tmp, path)        

def load_checkpoint():
    """Берём самый продвинутый чекпоинт из всех эпох."""
    best, pairs = 0, Counter()
    for path in CKPT_DIR.glob("epoch*.json"):
        data = json.loads(path.read_text())
        if data["next_chunk"] > best:
            best = data["next_chunk"]
            pairs = Counter({(a, b): n for a, b, n in data["pairs"]})
    return best, pairs


def publish(epoch, result):
    req = urllib.request.Request(SINK_URL + "/publish", method="POST",
                                 data=json.dumps({"epoch": epoch, "node": NODE, "result": result}).encode())
    try:
        resp = urllib.request.urlopen(req, timeout=10)
        ok = 200 <= resp.status < 300
        if not ok:
            log.info("publish HTTP %s (epoch=%d)", resp.status, epoch)
        return ok
    except urllib.error.HTTPError as e:
        log.info("publish HTTP %s (epoch=%d)", e.code, epoch)
        return False
    except Exception as e:
        log.info("publish error: %s (epoch=%d)", e, epoch)
        return False


def lead(zk):
    epoch = next_epoch(zk)
    log.info("BECAME_LEADER epoch=%d", epoch)

    skill_lists = load_skill_lists()
    start, pairs = load_checkpoint()
    if start >= CHUNKS:
        log.info("расчёт уже завершён, делать нечего")
        return
    if start:
        log.info("RESUME с чекпоинта: продолжаю с части %d из %d", start + 1, CHUNKS)
    else:
        log.info("чекпоинта нет, начинаю с начала")

    for i in range(start, CHUNKS):
        count_pairs(skill_lists[i * len(skill_lists) // CHUNKS:(i + 1) * len(skill_lists) // CHUNKS], pairs)
        save_checkpoint(epoch, i + 1, pairs)
        log.info("chunk %d/%d done (epoch=%d)", i + 1, CHUNKS, epoch)
        time.sleep(CHUNK_DELAY)

    if publish(epoch, pairs_digest(pairs)):
        log.info("PUBLISHED результат принят (epoch=%d)", epoch)
    else:
        log.info("PUBLISH_REJECTED результат отклонён получателем (epoch=%d)", epoch)


def main():
    zk = KazooClient(hosts=ZK_HOSTS, timeout=SESSION_TIMEOUT)
    zk.add_listener(lambda state: log.info("сессия ZooKeeper: %s", state))
    while True:                     
        try:
            zk.start(timeout=10)
            break
        except Exception:
            log.info("жду ZooKeeper...")
    zk.ensure_path(ZK_ROOT)
    log.info("STANDBY жду очереди на лидерство")
    zk.Election(f"{ZK_ROOT}/election", NODE).run(lambda: lead(zk))  
    log.info("DONE")
    zk.stop()


if __name__ == "__main__":
    main()