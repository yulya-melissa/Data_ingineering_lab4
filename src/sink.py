"""Получатель результата. При FENCING=1 сам отклоняет записи со старой эпохой."""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

from common import FENCING, STATE_DIR, setup_logging

log = setup_logging("sink")
RESULTS_DIR = STATE_DIR / "sink" / "results"
RESULTS_DIR.mkdir(parents=True, exist_ok=True)
max_epoch = 0  
accepted = 0    


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass 

    def reply(self, code, body):
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):
        global max_epoch, accepted
        data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        epoch, node = data["epoch"], data["node"]

        if FENCING and epoch < max_epoch:
            log.info("REJECTED  результат от %s: эпоха %d < %d", node, epoch, max_epoch)
            return self.reply(409, {"reason": f"устаревшая эпоха {epoch} < {max_epoch}"})

        accepted += 1
        max_epoch = max(max_epoch, epoch)
        name = f"result_{accepted}_epoch{epoch}_{node}.json"
        (RESULTS_DIR / name).write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        log.info("ACCEPTED  результат от %s: эпоха %d -> %s", node, epoch, name)
        self.reply(200, {"file": name})


if __name__ == "__main__":
    log.info("sink запущен, FENCING=%d", FENCING)
    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()