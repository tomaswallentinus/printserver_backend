#!/usr/bin/env python3

"""
Rensar fastnade utskriftsjobb i CUPS.

- Tar bort ej-klara jobb (pending/held/processing/stopped) i alla köer utom FollowMe när de
  passerat en per-kö-timeout:
  - SalA214 + KunskapensHav: 5 minuter
  - Övriga köer: 20 minuter
- För jobb i tillstånd "processing" används time-at-processing (hur länge jobbet legat i
  processing); för övriga används time-at-creation. Det gör att jobb som fastnat med
  "processing since ..." rensas när de varit i processing för länge.
- Skickar e-postnotis via lokal sendmail för användare vars username innehåller en punkt (.)
  enligt domänregler:
    - Om kön är SalA214 eller KunskapensHav -> <username>@student.tabyenskilda.se
    - Annars -> <username>@tabyenskilda.se
  Om username inte innehåller punkt: ingen e-post skickas.
- Sist i körningen: om någon skrivare är pausad/disabled avpausas den (cupsenable) så att köer
  inte förblir blockerade. Körs endast när DRY_RUN=0.

Körs lämpligen som root via sudo crontab eller systemd timer.

Miljövariabler:
- TIME_LIMIT_PRIORITY_SECONDS (default 300)  # SalA214 + KunskapensHav (gäller båda om ej nedan satta)
- TIME_LIMIT_PRIORITY_PROCESSING_SECONDS  # SalA214/KunskapensHav: jobb i "processing" (annars PRIORITY)
- TIME_LIMIT_PRIORITY_QUEUED_SECONDS      # SalA214/KunskapensHav: jobb i kö, ej processing (annars PRIORITY)
- TIME_LIMIT_DEFAULT_SECONDS (default 1200)  # Övriga köer (gäller båda om ej nedan satta)
- TIME_LIMIT_DEFAULT_PROCESSING_SECONDS   # Övriga: jobb i "processing" (annars DEFAULT)
- TIME_LIMIT_DEFAULT_QUEUED_SECONDS       # Övriga: jobb i kö, ej processing (annars DEFAULT)
- DRY_RUN=1 (loggar bara, tar inte bort jobb och skickar inte mail)
"""

from __future__ import annotations

import os
import socket
import subprocess
import sys
import time
from datetime import datetime
from typing import Optional

import cups


FOLLOWME_QUEUE = "FollowMe"
STUDENT_QUEUES = {"SalA214", "KunskapensHav"}
STUDENT_DOMAIN = "student.tabyenskilda.se"
STAFF_DOMAIN = "tabyenskilda.se"

DEFAULT_TIME_LIMIT_SECONDS = 20 * 60
PRIORITY_TIME_LIMIT_SECONDS = 5 * 60


def truthy_env(name: str, default: str = "0") -> bool:
    return os.getenv(name, default).strip().lower() in {"1", "true", "yes", "y", "on"}


def extract_queue_name(printer_uri: Optional[str]) -> str:
    if not printer_uri:
        return ""
    for marker in ("/printers/", "/classes/"):
        if marker in printer_uri:
            tail = printer_uri.split(marker, 1)[1]
            return tail.split("/", 1)[0]
    # Fallback: sista segmentet
    return printer_uri.rstrip("/").rsplit("/", 1)[-1]


def recipient_for(username: Optional[str], queue_name: str) -> Optional[str]:
    if not username:
        return None
    # Endast om username innehåller en punkt enligt krav
    if "." not in username:
        return None
    # Om username redan är en e-postadress, använd den (men kravet "punkt i username" är redan uppfyllt)
    if "@" in username:
        return username
    domain = STUDENT_DOMAIN if queue_name in STUDENT_QUEUES else STAFF_DOMAIN
    return f"{username}@{domain}"


def build_email(from_addr: str, to_addr: str, subject: str, body: str) -> str:
    # Enkel RFC822-text som sendmail -t kan läsa
    return (
        f"From: {from_addr}\n"
        f"To: {to_addr}\n"
        f"Subject: {subject}\n"
        "Content-Type: text/plain; charset=UTF-8\n"
        "\n"
        f"{body}\n"
    )


def send_email_via_sendmail(message: str) -> tuple[bool, str]:
    # Försök vanliga vägar
    candidates = ["/usr/sbin/sendmail", "/usr/bin/sendmail", "sendmail"]
    last_err = ""
    for cmd in candidates:
        try:
            proc = subprocess.run(
                [cmd, "-t", "-oi"],
                input=message,
                text=True,
                capture_output=True,
            )
            if proc.returncode == 0:
                return True, ""
            last_err = (proc.stderr or proc.stdout or "").strip() or f"sendmail returncode={proc.returncode}"
        except FileNotFoundError:
            last_err = f"Hittade inte {cmd}"
        except Exception as e:
            last_err = str(e)
    return False, last_err


def time_limit_for(queue_name: str, is_processing: bool) -> int:
    """Timeout i sekunder. is_processing=True = jobb i state processing (time-at-processing), annars queued (time-at-creation)."""
    if queue_name in STUDENT_QUEUES:
        fallback = os.getenv("TIME_LIMIT_PRIORITY_SECONDS", str(PRIORITY_TIME_LIMIT_SECONDS))
        key = "TIME_LIMIT_PRIORITY_PROCESSING_SECONDS" if is_processing else "TIME_LIMIT_PRIORITY_QUEUED_SECONDS"
        return int(os.getenv(key, fallback))
    fallback = os.getenv("TIME_LIMIT_DEFAULT_SECONDS", str(DEFAULT_TIME_LIMIT_SECONDS))
    key = "TIME_LIMIT_DEFAULT_PROCESSING_SECONDS" if is_processing else "TIME_LIMIT_DEFAULT_QUEUED_SECONDS"
    return int(os.getenv(key, fallback))


def main() -> int:
    dry_run = truthy_env("DRY_RUN", "0")

    if not dry_run and os.geteuid() != 0:
        print(
            "Varning: körs inte som root – avbrytande av andras jobb kan misslyckas. "
            "Kör med sudo eller via sudo crontab.",
            file=sys.stderr,
        )

    conn = cups.Connection()
    now = time.time()

    # I pycups finns dessa konstanter; vi filtrerar bort jobb som redan är avslutade.
    done_states = {cups.IPP_JOB_CANCELED, cups.IPP_JOB_ABORTED, cups.IPP_JOB_COMPLETED}

    # Viktigt: my_jobs=False för att rensa ALLAS jobb (inte bara den som kör skriptet)
    jobs = conn.getJobs(which_jobs="all", my_jobs=False)
    removed = 0
    emailed = 0
    errors = 0
    report_lines: list[str] = []  # Raderna som ska loggas när något raderats/avpausats

    for jobid in jobs:
        try:
            attrs = conn.getJobAttributes(jobid)
            state = attrs.get("job-state")
            if state in done_states:
                continue

            queue_name = extract_queue_name(attrs.get("job-printer-uri") or attrs.get("printer-uri"))
            if not queue_name or queue_name == FOLLOWME_QUEUE:
                continue

            # För jobb som är "processing" mäter vi hur länge de legat i processing (stuck),
            # annars hur länge sedan jobbet skapades.
            created_epoch = attrs.get("time-at-creation")
            processing_epoch = attrs.get("time-at-processing")
            if state == cups.IPP_JOB_PROCESSING and processing_epoch is not None:
                ref_epoch = float(processing_epoch)
            elif created_epoch is not None:
                ref_epoch = float(created_epoch)
            else:
                print(f"Hoppar över jobb {jobid}: saknar time-at-creation (och time-at-processing)", file=sys.stderr)
                continue

            age_seconds = now - ref_epoch
            is_processing = state == cups.IPP_JOB_PROCESSING
            time_limit = time_limit_for(queue_name, is_processing)
            if age_seconds <= time_limit:
                continue

            username = attrs.get("job-originating-user-name") or ""
            title = attrs.get("job-name") or "(utan titel)"

            if dry_run:
                print(
                    f"Jobb {jobid} i kö {queue_name} är {int(age_seconds)}s gammalt (state={state}). "
                    "DRY_RUN: skulle radera..."
                )
            else:
                report_lines.append(
                    f"Jobb {jobid} i kö {queue_name} är {int(age_seconds)}s gammalt (state={state}). Raderar..."
                )

            if not dry_run:
                conn.cancelJob(int(jobid))
                removed += 1

                # Mail (endast om username innehåller punkt)
                to_addr = recipient_for(username, queue_name)
                if to_addr:
                    fqdn = socket.getfqdn() or "localhost"
                    from_addr = f"printserver@{fqdn}"
                    age_min = max(1, int(age_seconds // 60))
                    subject = f"Utskrift raderad efter timeout: {title}"
                    body = (
                        "Ditt utskriftsjobb har tagits bort eftersom det tog för lång tid att komma ut.\n"
                        "\n"
                        f"Kö: {queue_name}\n"
                        f"Jobb-ID: {jobid}\n"
                        f"Titel: {title}\n"
                        f"Användare: {username}\n"
                        f"Ålder: {age_min} minuter\n"
                    )
                    msg = build_email(from_addr, to_addr, subject, body)
                    ok, err = send_email_via_sendmail(msg)
                    if ok:
                        emailed += 1
                    else:
                        errors += 1
                        print(f"  Kunde inte skicka e-post till {to_addr}: {err}", file=sys.stderr)
            elif dry_run:
                to_addr = recipient_for(username, queue_name)
                if to_addr:
                    print(f"  DRY_RUN: skulle skicka mail till {to_addr} om radering sker.")

        except Exception as e:
            errors += 1
            print(f"Fel vid hantering av jobb {jobid}: {e}", file=sys.stderr)

    # Sist av allt: avpausa skrivare som är pausade/disabled så att köer inte förblir blockerade
    enabled_count = 0
    if not dry_run:
        try:
            proc = subprocess.run(
                ["lpstat", "-p"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            if proc.returncode == 0 and proc.stdout:
                for line in proc.stdout.splitlines():
                    line_lower = line.lower()
                    if "paused" in line_lower or "disabled" in line_lower:
                        # lpstat -p format: "printer NAME is idle.  enabled since ..." eller "printer NAME disabled since ..."
                        parts = line.split()
                        if len(parts) >= 2 and parts[0] == "printer":
                            printer_name = parts[1]
                            enable_proc = subprocess.run(
                                ["cupsenable", printer_name],
                                capture_output=True,
                                text=True,
                                timeout=5,
                            )
                            if enable_proc.returncode == 0:
                                report_lines.append(f"Avpausade skrivare: {printer_name}")
                                enabled_count += 1
                            else:
                                err = (enable_proc.stderr or enable_proc.stdout or "").strip()
                                print(f"Kunde inte avpausa {printer_name}: {err}", file=sys.stderr)
                                errors += 1
            if enabled_count:
                report_lines.append(f"Totalt avpausade skrivare: {enabled_count}")
        except FileNotFoundError:
            print("lpstat eller cupsenable hittades inte, hoppar över avpausning.", file=sys.stderr)
        except subprocess.TimeoutExpired:
            print("Timeout vid kontroll av skrivarstatus.", file=sys.stderr)
            errors += 1
        except Exception as e:
            print(f"Fel vid avpausning av skrivare: {e}", file=sys.stderr)
            errors += 1
    elif dry_run:
        # I DRY_RUN kan vi ändå visa om det finns pausade skrivare
        try:
            proc = subprocess.run(["lpstat", "-p"], capture_output=True, text=True, timeout=10)
            if proc.returncode == 0 and proc.stdout:
                paused = []
                for line in proc.stdout.splitlines():
                    line_lower = line.lower()
                    if ("paused" in line_lower or "disabled" in line_lower) and line.strip().startswith("printer "):
                        parts = line.split()
                        if len(parts) >= 2:
                            paused.append(parts[1])
                if paused:
                    print(f"DRY_RUN: skulle avpausa skrivare: {', '.join(paused)}")
        except Exception:
            pass

    # Sammanfattning: endast till loggfil när något raderats eller avpausats, med tidsstämpel
    summary = (
        f"Klart. Matchade jobb: {len(jobs)} totalt, raderade: {removed}, mail: {emailed}, fel: {errors}."
        + (" (DRY_RUN)" if dry_run else "")
    )
    if dry_run:
        print(summary)
    elif report_lines:
        report_lines.append(summary)
        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        for line in report_lines:
            print(f"[{ts}] {line}")

    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())

