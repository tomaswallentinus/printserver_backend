#!/usr/bin/env python3

"""
Listar pågående (ej-klara) CUPS-jobb med hur länge de legat i kö.

Exempel:
  python3 /srv/printserver/scripts/list_jobs_with_age.py
"""

from __future__ import annotations

import time

import cups


def extract_queue_name(printer_uri: str | None) -> str:
    if not printer_uri:
        return ""
    for marker in ("/printers/", "/classes/"):
        if marker in printer_uri:
            tail = printer_uri.split(marker, 1)[1]
            return tail.split("/", 1)[0]
    return printer_uri.rstrip("/").rsplit("/", 1)[-1]


def fmt_age(seconds: float) -> str:
    if seconds < 0:
        seconds = 0
    m = int(seconds // 60)
    s = int(seconds % 60)
    if m >= 60:
        h = m // 60
        m = m % 60
        return f"{h}h{m:02d}m"
    return f"{m}m{s:02d}s"


def main() -> int:
    conn = cups.Connection()
    now = time.time()

    done_states = {cups.IPP_JOB_CANCELED, cups.IPP_JOB_ABORTED, cups.IPP_JOB_COMPLETED}
    # Viktigt: my_jobs=False för att se ALLAS jobb (inte bara den som kör skriptet)
    jobs = conn.getJobs(which_jobs="all", my_jobs=False)

    rows: list[tuple[int, str, str, str, int, str]] = []
    for jobid in jobs:
        attrs = conn.getJobAttributes(jobid)
        state = attrs.get("job-state")
        if state in done_states:
            continue
        created_epoch = attrs.get("time-at-creation")
        age = now - float(created_epoch) if created_epoch else 0
        queue = extract_queue_name(attrs.get("job-printer-uri") or attrs.get("printer-uri"))
        user = attrs.get("job-originating-user-name") or ""
        title = attrs.get("job-name") or ""
        state_map = {
            cups.IPP_JOB_PENDING: "pending",
            cups.IPP_JOB_HELD: "held",
            cups.IPP_JOB_PROCESSING: "processing",
            cups.IPP_JOB_STOPPED: "stopped",
        }
        state_txt = state_map.get(state, str(state))
        rows.append((int(jobid), queue, user, title, int(age), state_txt))

    if not rows:
        print("Inga pågående jobb hittades.")
        return 0

    # sortera: äldst först
    rows.sort(key=lambda r: r[4], reverse=True)

    print(f"{'JOBID':>6}  {'KÖ':<20}  {'ÅLDER':>8}  {'STATE':>10}  {'ANVÄNDARE':<25}  TITEL")
    print("-" * 110)
    for jobid, queue, user, title, age, state in rows:
        print(f"{jobid:>6}  {queue:<20.20}  {fmt_age(age):>8}  {state:>10.10}  {user:<25.25}  {title}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

