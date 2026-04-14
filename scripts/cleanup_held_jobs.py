#!/usr/bin/env python3

import cups
import time
from datetime import datetime

# Gräns i sekunder (1 timme)
TIME_LIMIT = 3600

def main():
    conn = cups.Connection()
    now = time.time()
    jobs = conn.getJobs(which_jobs='all')
    removed = 0
    for jobid in jobs:
        attrs = conn.getJobAttributes(jobid)
        # 4 = held
        if attrs.get('job-state') == 4:
            created_epoch = attrs.get('time-at-creation')
            if created_epoch is None:
                print(f"Kunde inte hitta tid för jobb {jobid}, hoppar över.")
                continue
            age = now - created_epoch
            if age > TIME_LIMIT:
                try:
                    print(f"Tar bort held-jobb {jobid} (ålder: {int(age)} sekunder)")
                    conn.cancelJob(jobid)
                    removed += 1
                except Exception as e:
                    print(f"  Kunde inte ta bort jobb {jobid}: {e}")
    print(f"Totalt borttagna jobb: {removed}")

if __name__ == "__main__":
    main()

