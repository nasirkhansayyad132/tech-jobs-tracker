#!/usr/bin/env bash
set -e

mkdir -p "$HOME/jobsaf/data" "$HOME/jobsaf/web" "$HOME/jobsaf/scraper"

cat <<'EOF' > $HOME/jobsaf/notify.py
#!/usr/bin/env python3
import csv
import json
import os
import re
import shutil
import subprocess
from datetime import date, datetime
from email.message import EmailMessage
from pathlib import Path
from typing import Any, Dict, List, Optional

from dateutil import parser

BASE_DIR = Path.home() / "jobsaf"
DATA_DIR = BASE_DIR / "data"
INPUT_JSON = DATA_DIR / "jobs_full_open.json"
OUTPUT_JSON = DATA_DIR / "jobs_full_open.json"
OUTPUT_CSV = DATA_DIR / "jobs_full_open.csv"
STATE_FILE = DATA_DIR / "last_state.json"
SUMMARY_FILE = DATA_DIR / "summary.txt"

EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
AF_MOBILE_RE = re.compile(r"(?:\+?93|0093)?\s*0?7\d{8}\b")
PHONE_CHUNK_RE = re.compile(r"(?:\+|00)?\d[\d\s().-]{6,}\d")


def extract_emails(text: str) -> List[str]:
    if not text:
        return []
    found = {m.group(0).lower() for m in EMAIL_RE.finditer(text)}
    return sorted(found)


def normalize_phone(raw: str) -> str:
    raw = raw.strip()
    digits = re.sub(r"\D", "", raw)
    if digits.startswith("0093"):
        digits = digits[2:]
    if digits.startswith("93"):
        return "+" + digits
    if raw.startswith("+"):
        return "+" + digits
    return digits


def extract_phones(text: str) -> List[str]:
    if not text:
        return []
    phones = set()
    for match in AF_MOBILE_RE.finditer(text):
        phones.add(normalize_phone(match.group(0)))
    for match in PHONE_CHUNK_RE.finditer(text):
        raw = match.group(0)
        digits = re.sub(r"\D", "", raw)
        if len(digits) < 7 or len(digits) > 15:
            continue
        if raw.startswith("+") or digits.startswith(("0", "7", "93", "0093")):
            phones.add(normalize_phone(raw))
    return sorted(p for p in phones if p)


def parse_date(value: str) -> Optional[date]:
    if not value:
        return None
    try:
        parsed = parser.parse(value, dayfirst=True, fuzzy=True)
        return parsed.date()
    except Exception:
        return None


def load_jobs(path: Path) -> List[Dict[str, Any]]:
    if not path.exists():
        return []
    try:
        with path.open("r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, list):
            return [item for item in data if isinstance(item, dict)]
    except Exception:
        return []
    return []


def load_state(path: Path) -> Dict[str, Any]:
    if not path.exists():
        return {"seen_urls": [], "last_run": ""}
    try:
        with path.open("r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            if "seen_urls" not in data:
                data["seen_urls"] = []
            if "last_run" not in data:
                data["last_run"] = ""
            return data
    except Exception:
        pass
    return {"seen_urls": [], "last_run": ""}


def save_state(path: Path, seen_urls: List[str], last_run: str, last_new_urls: List[str]) -> None:
    payload = {
        "seen_urls": seen_urls,
        "last_run": last_run,
        "last_new_urls": last_new_urls,
    }
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def normalize_jobs(jobs: List[Dict[str, Any]], seen_urls: set, today: date) -> List[Dict[str, Any]]:
    normalized: List[Dict[str, Any]] = []
    seen_in_run = set()
    for job in jobs:
        url = str(job.get("url", "")).strip()
        if not url or url in seen_in_run:
            continue
        seen_in_run.add(url)

        description = str(job.get("description", "") or "")
        details = str(job.get("details", "") or "")
        combined = description + "\n" + details

        emails = extract_emails(combined)
        phones = extract_phones(combined)
        apply_url = str(job.get("apply_url", "")).strip()

        if apply_url:
            apply_method = "apply_url"
        elif emails:
            apply_method = "email"
        else:
            apply_method = "unknown"

        job["emails"] = emails
        job["phones"] = phones
        job["apply_method"] = apply_method
        job["source"] = "jobs.af"

        close_raw = str(job.get("closing_date", "") or job.get("closing_date_raw", "") or "").strip()
        close_date = parse_date(close_raw)
        if close_date:
            job["closing_date"] = close_date.isoformat()
        if close_date and close_date < today:
            continue

        job["is_new"] = url not in seen_urls
        normalized.append(job)
    return normalized


def write_json(path: Path, jobs: List[Dict[str, Any]]) -> None:
    path.write_text(json.dumps(jobs, ensure_ascii=False, indent=2), encoding="utf-8")


def write_csv(path: Path, jobs: List[Dict[str, Any]]) -> None:
    fieldnames = [
        "url",
        "title",
        "company",
        "location",
        "closing_date",
        "closing_date_raw",
        "apply_url",
        "apply_method",
        "emails",
        "phones",
        "source",
        "description",
        "details",
        "is_new",
    ]
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for job in jobs:
            row = {key: job.get(key, "") for key in fieldnames}
            if isinstance(row.get("emails"), list):
                row["emails"] = "; ".join(row["emails"])
            if isinstance(row.get("phones"), list):
                row["phones"] = "; ".join(row["phones"])
            writer.writerow(row)


def compute_expiring(jobs: List[Dict[str, Any]], today: date):
    exp_today = []
    exp_soon = []
    for job in jobs:
        close_raw = str(job.get("closing_date", "") or job.get("closing_date_raw", "") or "").strip()
        close_date = parse_date(close_raw)
        if not close_date:
            continue
        delta = (close_date - today).days
        if delta == 0:
            exp_today.append(job)
        elif 1 <= delta <= 2:
            exp_soon.append(job)
    return exp_today, exp_soon


def build_summary(run_ts: str, new_jobs, exp_today, exp_soon):
    lines = []
    lines.append("Jobs.af Tracker summary")
    lines.append(f"Run: {run_ts}")
    lines.append("")
    lines.append(f"New jobs: {len(new_jobs)}")
    if new_jobs:
        for job in new_jobs:
            title = job.get("title") or "Untitled"
            url = job.get("url") or ""
            lines.append(f"- {title} | {url}")
    lines.append("")
    lines.append(f"Expiring today: {len(exp_today)}")
    if exp_today:
        for job in exp_today:
            title = job.get("title") or "Untitled"
            url = job.get("url") or ""
            lines.append(f"- {title} | {url}")
    lines.append("")
    lines.append(f"Expiring soon (1-2 days): {len(exp_soon)}")
    if exp_soon:
        for job in exp_soon:
            title = job.get("title") or "Untitled"
            url = job.get("url") or ""
            lines.append(f"- {title} | {url}")
    lines.append("")
    return "\n".join(lines)


def send_termux_notification(summary: str) -> None:
    if shutil.which("termux-notification") is None:
        return
    try:
        subprocess.run(
            [
                "termux-notification",
                "--title",
                "Jobs.af Tracker",
                "--content",
                summary,
                "--priority",
                "high",
            ],
            check=False,
        )
    except Exception:
        pass


def send_email(summary_text: str) -> None:
    host = os.getenv("JOBSAF_SMTP_HOST")
    user = os.getenv("JOBSAF_SMTP_USER")
    password = os.getenv("JOBSAF_SMTP_PASS")
    to_addr = os.getenv("JOBSAF_SMTP_TO")
    if not (host and user and password and to_addr):
        return
    port = int(os.getenv("JOBSAF_SMTP_PORT", "587"))
    from_addr = os.getenv("JOBSAF_SMTP_FROM", user)
    use_tls = os.getenv("JOBSAF_SMTP_TLS", "1") != "0"

    msg = EmailMessage()
    msg["Subject"] = "Jobs.af Tracker summary"
    msg["From"] = from_addr
    msg["To"] = to_addr
    msg.set_content(summary_text)

    try:
        import smtplib

        with smtplib.SMTP(host, port, timeout=20) as server:
            if use_tls:
                server.starttls()
            server.login(user, password)
            server.send_message(msg)
    except Exception:
        pass


def main() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    jobs = load_jobs(INPUT_JSON)
    state = load_state(STATE_FILE)
    seen_urls = set(state.get("seen_urls", []))

    today = date.today()
    normalized = normalize_jobs(jobs, seen_urls, today)
    new_jobs = [job for job in normalized if job.get("is_new")]
    exp_today, exp_soon = compute_expiring(normalized, today)

    write_json(OUTPUT_JSON, normalized)
    write_csv(OUTPUT_CSV, normalized)

    run_ts = datetime.now().isoformat(timespec="seconds")
    summary_text = build_summary(run_ts, new_jobs, exp_today, exp_soon)
    SUMMARY_FILE.write_text(summary_text, encoding="utf-8")

    summary_line = (
        f"New: {len(new_jobs)} | Expiring today: {len(exp_today)} | "
        f"Expiring soon: {len(exp_soon)}"
    )
    send_termux_notification(summary_line)
    send_email(summary_text)

    save_state(
        STATE_FILE,
        [job.get("url") for job in normalized if job.get("url")],
        run_ts,
        [job.get("url") for job in new_jobs],
    )


if __name__ == "__main__":
    main()
EOF

cat <<'EOF' > $HOME/jobsaf/run_now.sh
#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$HOME/jobsaf"
DATA_DIR="$BASE_DIR/data"
LOCK_FILE="$DATA_DIR/run.lock"
SCRAPER="$BASE_DIR/scraper/jobsaf_ui_scrape_v1.py"

mkdir -p "$DATA_DIR"

if [ -f "$LOCK_FILE" ]; then
  read -r old_pid old_ts < "$LOCK_FILE" || true
  if [ -n "${old_pid:-}" ] && kill -0 "$old_pid" 2>/dev/null; then
    echo "RUNNING"
    exit 2
  fi
  rm -f "$LOCK_FILE"
fi

echo "$$ $(date -u +%s)" > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

if [ ! -f "$SCRAPER" ]; then
  echo "Missing scraper: $SCRAPER" >&2
  exit 1
fi

python "$SCRAPER"

if [ ! -s "$DATA_DIR/jobs_full_open.json" ]; then
  echo "Missing output: $DATA_DIR/jobs_full_open.json" >&2
  exit 1
fi

python "$BASE_DIR/notify.py"
EOF

cat <<'EOF' > $HOME/jobsaf/server.py
#!/usr/bin/env python3
import json
import mimetypes
import os
import subprocess
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BASE_DIR = Path.home() / "jobsaf"
WEB_DIR = BASE_DIR / "web"
DATA_DIR = BASE_DIR / "data"
RUN_SCRIPT = BASE_DIR / "run_now.sh"
LOCK_FILE = DATA_DIR / "run.lock"
RUN_MUTEX = threading.Lock()


def lock_active() -> bool:
    if not LOCK_FILE.exists():
        return False
    try:
        contents = LOCK_FILE.read_text(encoding="utf-8").strip()
    except Exception:
        return True
    if not contents:
        return True
    try:
        pid = int(contents.split()[0])
    except ValueError:
        return True
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        try:
            LOCK_FILE.unlink()
        except Exception:
            pass
        return False
    except PermissionError:
        return True


class Handler(BaseHTTPRequestHandler):
    server_version = "JobsAfTracker/1.0"

    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path.startswith("/data/"):
            rel = parsed.path[len("/data/") :]
            if not rel:
                self.send_error(404, "Missing file")
                return
            self.serve_file(DATA_DIR, rel)
            return
        if parsed.path == "/api/run":
            self.send_json({"ok": False, "error": "Use POST /api/run"})
            return
        rel = parsed.path.lstrip("/")
        if rel == "":
            rel = "index.html"
        self.serve_file(WEB_DIR, rel)

    def do_POST(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/api/run":
            self.handle_run()
            return
        self.send_error(404, "Not found")

    def handle_run(self) -> None:
        with RUN_MUTEX:
            if lock_active():
                self.send_json({"ok": True, "status": "busy"})
                return
            if not RUN_SCRIPT.exists():
                self.send_json(
                    {"ok": False, "status": "error", "error": "run_now.sh not found"}
                )
                return
            try:
                proc = subprocess.Popen(["bash", str(RUN_SCRIPT)], cwd=str(BASE_DIR))
            except Exception as exc:
                self.send_json({"ok": False, "status": "error", "error": str(exc)})
                return
            self.send_json({"ok": True, "status": "started", "pid": proc.pid})

    def serve_file(self, root: Path, rel: str) -> None:
        root = root.resolve()
        target = (root / rel).resolve()
        if not str(target).startswith(str(root)):
            self.send_error(403, "Forbidden")
            return
        if not target.exists() or not target.is_file():
            self.send_error(404, "Not found")
            return
        ctype = mimetypes.guess_type(str(target))[0] or "application/octet-stream"
        if ctype.startswith("text/") or ctype == "application/json":
            ctype += "; charset=utf-8"
        try:
            with target.open("rb") as f:
                data = f.read()
        except Exception:
            self.send_error(500, "Failed to read file")
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_json(self, payload: dict) -> None:
        data = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt: str, *args) -> None:
        return


def main() -> None:
    WEB_DIR.mkdir(parents=True, exist_ok=True)
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", 8080), Handler)
    print("Jobs.af Tracker server on http://127.0.0.1:8080/")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
EOF

cat <<'EOF' > $HOME/jobsaf/web/index.html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Jobs.af Tracker</title>
    <style>
      :root {
        --bg: #f7f1e6;
        --bg-2: #e6f2eb;
        --ink: #1b1b1f;
        --muted: #5f666d;
        --accent: #d97706;
        --accent-2: #0f766e;
        --card: #ffffff;
        --border: #e2ddd0;
        --chip-new: #2563eb;
        --chip-soon: #dc2626;
        --chip-today: #b91c1c;
        --chip-info: #0f766e;
      }

      * {
        box-sizing: border-box;
      }

      body {
        margin: 0;
        font-family: "Noto Sans", "Liberation Sans", sans-serif;
        color: var(--ink);
        background: radial-gradient(circle at 20% 20%, #fff7e8 0, transparent 40%),
          radial-gradient(circle at 90% 10%, #e3f1ff 0, transparent 35%),
          linear-gradient(135deg, var(--bg), var(--bg-2));
        min-height: 100vh;
      }

      .wrap {
        max-width: 860px;
        margin: 0 auto;
        padding: 24px 16px 48px;
      }

      .hero {
        display: grid;
        gap: 12px;
        background: rgba(255, 255, 255, 0.8);
        border: 1px solid var(--border);
        border-radius: 18px;
        padding: 18px;
        box-shadow: 0 10px 30px rgba(0, 0, 0, 0.08);
        backdrop-filter: blur(6px);
      }

      .hero h1 {
        margin: 0;
        font-size: 28px;
        letter-spacing: 0.3px;
      }

      .hero p {
        margin: 0;
        color: var(--muted);
      }

      .controls {
        display: grid;
        gap: 12px;
      }

      .run-btn {
        width: 100%;
        border: none;
        background: linear-gradient(135deg, var(--accent), #f59e0b);
        color: #1f1300;
        font-weight: 700;
        padding: 12px 16px;
        border-radius: 12px;
        cursor: pointer;
        transition: transform 0.2s ease, box-shadow 0.2s ease;
        box-shadow: 0 10px 18px rgba(217, 119, 6, 0.3);
      }

      .run-btn:disabled {
        opacity: 0.7;
        cursor: default;
        box-shadow: none;
      }

      .run-btn:active {
        transform: translateY(1px);
      }

      .status {
        font-size: 13px;
        color: var(--muted);
      }

      .search-row {
        margin-top: 18px;
        display: grid;
        gap: 12px;
      }

      .search-row input {
        width: 100%;
        padding: 14px 16px;
        border-radius: 14px;
        border: 1px solid var(--border);
        font-size: 16px;
        background: rgba(255, 255, 255, 0.9);
      }

      .meta {
        display: flex;
        flex-wrap: wrap;
        gap: 12px;
        font-size: 13px;
        color: var(--muted);
      }

      .list {
        margin-top: 20px;
        display: grid;
        gap: 16px;
      }

      .card {
        display: grid;
        gap: 10px;
        padding: 16px;
        border-radius: 16px;
        border: 1px solid var(--border);
        background: var(--card);
        text-decoration: none;
        color: inherit;
        box-shadow: 0 12px 28px rgba(17, 24, 39, 0.08);
        opacity: 0;
        transform: translateY(12px);
        animation: rise 0.6s ease forwards;
      }

      .card h3 {
        margin: 0;
        font-size: 18px;
        line-height: 1.3;
      }

      .company {
        font-size: 14px;
        color: var(--muted);
      }

      .card-meta {
        display: flex;
        flex-wrap: wrap;
        gap: 10px 16px;
        font-size: 13px;
        color: var(--muted);
      }

      .badges {
        display: flex;
        flex-wrap: wrap;
        gap: 8px;
      }

      .badge {
        font-size: 12px;
        padding: 4px 8px;
        border-radius: 999px;
        background: #f3f4f6;
        color: #111827;
        border: 1px solid #e5e7eb;
        text-transform: uppercase;
        letter-spacing: 0.5px;
      }

      .badge.new {
        background: rgba(37, 99, 235, 0.15);
        color: #1d4ed8;
        border-color: rgba(37, 99, 235, 0.4);
      }

      .badge.soon {
        background: rgba(220, 38, 38, 0.12);
        color: var(--chip-soon);
        border-color: rgba(220, 38, 38, 0.3);
      }

      .badge.today {
        background: rgba(185, 28, 28, 0.15);
        color: var(--chip-today);
        border-color: rgba(185, 28, 28, 0.35);
      }

      .badge.info {
        background: rgba(15, 118, 110, 0.12);
        color: var(--chip-info);
        border-color: rgba(15, 118, 110, 0.3);
      }

      .empty {
        text-align: center;
        color: var(--muted);
        padding: 28px 18px;
        background: rgba(255, 255, 255, 0.7);
        border: 1px dashed var(--border);
        border-radius: 16px;
      }

      @keyframes rise {
        0% {
          opacity: 0;
          transform: translateY(12px);
        }
        100% {
          opacity: 1;
          transform: translateY(0);
        }
      }

      @media (min-width: 720px) {
        .hero {
          grid-template-columns: 1.2fr 1fr;
          align-items: center;
        }
        .controls {
          justify-items: end;
        }
        .run-btn {
          width: auto;
        }
      }
    </style>
  </head>
  <body>
    <main class="wrap">
      <header class="hero">
        <div>
          <h1>Jobs.af Tracker</h1>
          <p>Local job feed with alerts for new and expiring roles.</p>
        </div>
        <div class="controls">
          <button id="runBtn" class="run-btn">Run Scrape</button>
          <div id="runStatus" class="status">Idle</div>
        </div>
      </header>

      <section class="search-row">
        <input
          id="searchInput"
          type="search"
          placeholder="Search title, company, or location"
          aria-label="Search jobs"
        />
        <div class="meta">
          <span id="countMeta">0 jobs</span>
          <span id="newMeta">New: 0</span>
          <span id="expMeta">Expiring soon: 0</span>
          <span id="lastRunMeta">Last run: --</span>
        </div>
      </section>

      <section id="jobsList" class="list"></section>
    </main>

    <script>
      const DATA_URL = "/data/jobs_full_open.json";
      const STATE_URL = "/data/last_state.json";

      const runBtn = document.getElementById("runBtn");
      const runStatus = document.getElementById("runStatus");
      const searchInput = document.getElementById("searchInput");
      const listEl = document.getElementById("jobsList");
      const countMeta = document.getElementById("countMeta");
      const newMeta = document.getElementById("newMeta");
      const expMeta = document.getElementById("expMeta");
      const lastRunMeta = document.getElementById("lastRunMeta");

      let allJobs = [];
      let lastState = {};

      const msPerDay = 24 * 60 * 60 * 1000;

      function startOfToday() {
        const d = new Date();
        d.setHours(0, 0, 0, 0);
        return d;
      }

      function parseDate(value) {
        if (!value) return null;
        const d = new Date(value);
        if (Number.isNaN(d.getTime())) return null;
        d.setHours(0, 0, 0, 0);
        return d;
      }

      function daysLeft(job) {
        const dateValue = job.closing_date || job.closing_date_raw;
        const d = parseDate(dateValue);
        if (!d) return null;
        const diff = Math.round((d - startOfToday()) / msPerDay);
        return diff;
      }

      function isNew(job) {
        if (job.is_new) return true;
        const lastNew = lastState.last_new_urls || [];
        return lastNew.includes(job.url);
      }

      function formatApply(method) {
        if (method === "apply_url") return "Apply link";
        if (method === "email") return "Email";
        return "Unknown";
      }

      function formatClosing(job) {
        return job.closing_date || job.closing_date_raw || "Unknown";
      }

      function sortJobs(a, b) {
        const da = parseDate(a.closing_date || a.closing_date_raw);
        const db = parseDate(b.closing_date || b.closing_date_raw);
        if (da && db) return da - db;
        if (da) return -1;
        if (db) return 1;
        return 0;
      }

      function renderList() {
        const query = searchInput.value.trim().toLowerCase();
        let filtered = allJobs;
        if (query) {
          filtered = allJobs.filter((job) => {
            const hay = `${job.title || ""} ${job.company || ""} ${job.location || ""}`
              .toLowerCase()
              .trim();
            return hay.includes(query);
          });
        }
        filtered = filtered.slice().sort(sortJobs);

        listEl.innerHTML = "";
        if (!filtered.length) {
          const empty = document.createElement("div");
          empty.className = "empty";
          empty.textContent = query
            ? "No matches. Try a different search."
            : "No job data yet. Run a scrape.";
          listEl.appendChild(empty);
          countMeta.textContent = "0 jobs";
          return;
        }

        filtered.forEach((job, index) => {
          const card = document.createElement("a");
          card.className = "card";
          card.style.animationDelay = `${index * 40}ms`;
          card.href = `job.html?u=${encodeURIComponent(job.url)}`;

          const title = document.createElement("h3");
          title.textContent = job.title || "Untitled";

          const company = document.createElement("div");
          company.className = "company";
          company.textContent = job.company || "Unknown company";

          const meta = document.createElement("div");
          meta.className = "card-meta";
          const loc = document.createElement("span");
          loc.textContent = job.location || "Location unknown";
          const closing = document.createElement("span");
          closing.textContent = `Closing: ${formatClosing(job)}`;
          meta.append(loc, closing);

          const badges = document.createElement("div");
          badges.className = "badges";

          const days = daysLeft(job);
          if (days === 0) {
            const badge = document.createElement("span");
            badge.className = "badge today";
            badge.textContent = "Closing today";
            badges.appendChild(badge);
          } else if (days === 1 || days === 2) {
            const badge = document.createElement("span");
            badge.className = "badge soon";
            badge.textContent = `${days} day${days === 1 ? "" : "s"} left`;
            badges.appendChild(badge);
          } else if (days !== null) {
            const badge = document.createElement("span");
            badge.className = "badge info";
            badge.textContent = `${days} days left`;
            badges.appendChild(badge);
          }

          if (isNew(job)) {
            const badge = document.createElement("span");
            badge.className = "badge new";
            badge.textContent = "New";
            badges.appendChild(badge);
          }

          const apply = document.createElement("div");
          apply.className = "card-meta";
          apply.textContent = `Apply method: ${formatApply(job.apply_method)}`;

          card.append(title, company, meta, badges, apply);
          listEl.appendChild(card);
        });

        countMeta.textContent = `${filtered.length} jobs`;
      }

      async function loadState() {
        try {
          const res = await fetch(STATE_URL, { cache: "no-store" });
          if (!res.ok) return;
          lastState = await res.json();
          lastRunMeta.textContent = `Last run: ${lastState.last_run || "--"}`;
        } catch (err) {
          lastRunMeta.textContent = "Last run: --";
        }
      }

      async function loadJobs() {
        runStatus.textContent = "Loading jobs...";
        try {
          const res = await fetch(DATA_URL, { cache: "no-store" });
          if (!res.ok) throw new Error("Missing data");
          const data = await res.json();
          allJobs = Array.isArray(data) ? data : [];
          updateStats();
          renderList();
          runStatus.textContent = "Ready";
        } catch (err) {
          allJobs = [];
          renderList();
          runStatus.textContent = "No data yet";
        }
      }

      function updateStats() {
        let newCount = 0;
        let expSoon = 0;
        allJobs.forEach((job) => {
          const days = daysLeft(job);
          if (isNew(job)) newCount += 1;
          if (days === 0 || days === 1 || days === 2) expSoon += 1;
        });
        newMeta.textContent = `New: ${newCount}`;
        expMeta.textContent = `Expiring soon: ${expSoon}`;
      }

      async function runScrape() {
        runBtn.disabled = true;
        runStatus.textContent = "Starting scrape...";
        let previousRun = lastState.last_run || "";
        try {
          const res = await fetch("/api/run", { method: "POST" });
          const data = await res.json();
          if (data.status === "busy") {
            runStatus.textContent = "Scrape already running";
            runBtn.disabled = false;
            return;
          }
          if (!data.ok) {
            runStatus.textContent = "Failed to start";
            runBtn.disabled = false;
            return;
          }
          runStatus.textContent = "Scrape running...";
        } catch (err) {
          runStatus.textContent = "Failed to start";
          runBtn.disabled = false;
          return;
        }

        const start = Date.now();
        const poll = async () => {
          if (Date.now() - start > 15 * 60 * 1000) {
            runStatus.textContent = "Still running. Check again.";
            runBtn.disabled = false;
            return;
          }
          await loadState();
          if (lastState.last_run && lastState.last_run !== previousRun) {
            await loadJobs();
            runStatus.textContent = "Updated";
            runBtn.disabled = false;
            return;
          }
          setTimeout(poll, 5000);
        };
        setTimeout(poll, 5000);
      }

      searchInput.addEventListener("input", () => {
        renderList();
      });
      runBtn.addEventListener("click", runScrape);

      (async () => {
        await loadState();
        await loadJobs();
      })();
    </script>
  </body>
</html>
EOF

cat <<'EOF' > $HOME/jobsaf/web/job.html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Job Details - Jobs.af Tracker</title>
    <style>
      :root {
        --bg: #f7f1e6;
        --bg-2: #e6f2eb;
        --ink: #1b1b1f;
        --muted: #5f666d;
        --accent: #d97706;
        --accent-2: #0f766e;
        --card: #ffffff;
        --border: #e2ddd0;
        --chip-new: #2563eb;
        --chip-soon: #dc2626;
        --chip-today: #b91c1c;
        --chip-info: #0f766e;
      }

      * {
        box-sizing: border-box;
      }

      body {
        margin: 0;
        font-family: "Noto Sans", "Liberation Sans", sans-serif;
        color: var(--ink);
        background: radial-gradient(circle at 20% 20%, #fff7e8 0, transparent 40%),
          radial-gradient(circle at 90% 10%, #e3f1ff 0, transparent 35%),
          linear-gradient(135deg, var(--bg), var(--bg-2));
        min-height: 100vh;
      }

      .wrap {
        max-width: 860px;
        margin: 0 auto;
        padding: 24px 16px 48px;
        display: grid;
        gap: 18px;
      }

      .back {
        display: inline-flex;
        align-items: center;
        gap: 8px;
        color: var(--accent-2);
        text-decoration: none;
        font-weight: 600;
      }

      .hero {
        display: grid;
        gap: 10px;
        padding: 18px;
        border-radius: 18px;
        border: 1px solid var(--border);
        background: rgba(255, 255, 255, 0.9);
        box-shadow: 0 12px 28px rgba(17, 24, 39, 0.08);
      }

      .hero h1 {
        margin: 0;
        font-size: 24px;
      }

      .hero .company {
        color: var(--muted);
      }

      .badges {
        display: flex;
        flex-wrap: wrap;
        gap: 8px;
      }

      .badge {
        font-size: 12px;
        padding: 4px 8px;
        border-radius: 999px;
        background: #f3f4f6;
        color: #111827;
        border: 1px solid #e5e7eb;
        text-transform: uppercase;
        letter-spacing: 0.5px;
      }

      .badge.new {
        background: rgba(37, 99, 235, 0.15);
        color: #1d4ed8;
        border-color: rgba(37, 99, 235, 0.4);
      }

      .badge.soon {
        background: rgba(220, 38, 38, 0.12);
        color: var(--chip-soon);
        border-color: rgba(220, 38, 38, 0.3);
      }

      .badge.today {
        background: rgba(185, 28, 28, 0.15);
        color: var(--chip-today);
        border-color: rgba(185, 28, 28, 0.35);
      }

      .badge.info {
        background: rgba(15, 118, 110, 0.12);
        color: var(--chip-info);
        border-color: rgba(15, 118, 110, 0.3);
      }

      .panel {
        padding: 16px;
        border-radius: 16px;
        border: 1px solid var(--border);
        background: var(--card);
        box-shadow: 0 10px 22px rgba(17, 24, 39, 0.06);
      }

      .panel h2 {
        margin-top: 0;
      }

      .rows {
        display: grid;
        gap: 10px;
      }

      .row {
        display: grid;
        gap: 6px;
      }

      .label {
        font-size: 12px;
        text-transform: uppercase;
        letter-spacing: 0.5px;
        color: var(--muted);
      }

      .value a {
        color: var(--accent-2);
        text-decoration: none;
      }

      .text-block {
        white-space: pre-wrap;
        line-height: 1.5;
      }

      .contacts {
        display: grid;
        gap: 16px;
      }

      .contact-list {
        display: grid;
        gap: 6px;
      }

      .contact-list a {
        color: var(--accent-2);
        text-decoration: none;
      }

      @media (min-width: 720px) {
        .rows {
          grid-template-columns: repeat(2, minmax(0, 1fr));
        }
        .contacts {
          grid-template-columns: repeat(2, minmax(0, 1fr));
        }
      }
    </style>
  </head>
  <body>
    <main class="wrap">
      <a class="back" href="index.html">Back to list</a>

      <section class="hero">
        <h1 id="title">Loading...</h1>
        <div class="company" id="company"></div>
        <div class="badges" id="badges"></div>
      </section>

      <section class="panel">
        <div class="rows">
          <div class="row">
            <div class="label">Location</div>
            <div class="value" id="location"></div>
          </div>
          <div class="row">
            <div class="label">Closing date</div>
            <div class="value" id="closingDate"></div>
          </div>
          <div class="row">
            <div class="label">Apply method</div>
            <div class="value" id="applyMethod"></div>
          </div>
          <div class="row" id="applyRow">
            <div class="label">Apply link</div>
            <div class="value"><a id="applyLink" href="#"></a></div>
          </div>
          <div class="row" id="sourceRow">
            <div class="label">Source</div>
            <div class="value"><a id="sourceLink" href="#"></a></div>
          </div>
        </div>
      </section>

      <section class="panel">
        <h2>Description</h2>
        <div id="description" class="text-block"></div>
      </section>

      <section class="panel">
        <h2>Details</h2>
        <div id="details" class="text-block"></div>
      </section>

      <section class="panel">
        <h2>Contacts</h2>
        <div class="contacts">
          <div>
            <div class="label">Emails</div>
            <div id="emails" class="contact-list"></div>
          </div>
          <div>
            <div class="label">Phones</div>
            <div id="phones" class="contact-list"></div>
          </div>
        </div>
      </section>
    </main>

    <script>
      const DATA_URL = "/data/jobs_full_open.json";
      const params = new URLSearchParams(window.location.search);
      const jobUrl = params.get("u");

      const titleEl = document.getElementById("title");
      const companyEl = document.getElementById("company");
      const badgesEl = document.getElementById("badges");
      const locationEl = document.getElementById("location");
      const closingDateEl = document.getElementById("closingDate");
      const applyMethodEl = document.getElementById("applyMethod");
      const applyRow = document.getElementById("applyRow");
      const applyLink = document.getElementById("applyLink");
      const sourceLink = document.getElementById("sourceLink");
      const descriptionEl = document.getElementById("description");
      const detailsEl = document.getElementById("details");
      const emailsEl = document.getElementById("emails");
      const phonesEl = document.getElementById("phones");

      const msPerDay = 24 * 60 * 60 * 1000;

      function startOfToday() {
        const d = new Date();
        d.setHours(0, 0, 0, 0);
        return d;
      }

      function parseDate(value) {
        if (!value) return null;
        const d = new Date(value);
        if (Number.isNaN(d.getTime())) return null;
        d.setHours(0, 0, 0, 0);
        return d;
      }

      function daysLeft(job) {
        const dateValue = job.closing_date || job.closing_date_raw;
        const d = parseDate(dateValue);
        if (!d) return null;
        return Math.round((d - startOfToday()) / msPerDay);
      }

      function addBadge(text, className) {
        const badge = document.createElement("span");
        badge.className = `badge ${className}`;
        badge.textContent = text;
        badgesEl.appendChild(badge);
      }

      function formatApply(method) {
        if (method === "apply_url") return "Apply link";
        if (method === "email") return "Email";
        return "Unknown";
      }

      function renderContacts(container, list, scheme) {
        container.innerHTML = "";
        if (!list || !list.length) {
          const empty = document.createElement("div");
          empty.textContent = "None found";
          container.appendChild(empty);
          return;
        }
        list.forEach((item) => {
          const link = document.createElement("a");
          link.href = `${scheme}:${item}`;
          link.textContent = item;
          container.appendChild(link);
        });
      }

      async function loadJob() {
        if (!jobUrl) {
          titleEl.textContent = "Missing job link";
          return;
        }
        try {
          const res = await fetch(DATA_URL, { cache: "no-store" });
          if (!res.ok) throw new Error("Missing data");
          const data = await res.json();
          const job = Array.isArray(data)
            ? data.find((item) => item.url === jobUrl)
            : null;
          if (!job) {
            titleEl.textContent = "Job not found";
            return;
          }

          titleEl.textContent = job.title || "Untitled";
          companyEl.textContent = job.company || "Unknown company";
          locationEl.textContent = job.location || "Location unknown";
          closingDateEl.textContent = job.closing_date || job.closing_date_raw || "Unknown";
          applyMethodEl.textContent = formatApply(job.apply_method);

          badgesEl.innerHTML = "";
          const days = daysLeft(job);
          if (days === 0) addBadge("Closing today", "today");
          if (days === 1 || days === 2)
            addBadge(`${days} day${days === 1 ? "" : "s"} left`, "soon");
          if (days !== null && days > 2) addBadge(`${days} days left`, "info");
          if (job.is_new) addBadge("New", "new");

          descriptionEl.textContent = job.description || "";
          detailsEl.textContent = job.details || "";

          if (job.apply_url) {
            applyLink.href = job.apply_url;
            applyLink.textContent = job.apply_url;
          } else {
            applyRow.style.display = "none";
          }

          sourceLink.href = job.url;
          sourceLink.textContent = job.url;

          renderContacts(emailsEl, job.emails || [], "mailto");
          renderContacts(phonesEl, job.phones || [], "tel");
        } catch (err) {
          titleEl.textContent = "Failed to load job";
        }
      }

      loadJob();
    </script>
  </body>
</html>
EOF

chmod +x "$HOME/jobsaf/run_now.sh"

