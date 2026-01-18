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
