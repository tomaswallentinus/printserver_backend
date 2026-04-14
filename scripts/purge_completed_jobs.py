#!/usr/bin/env python3

import cups

def main():
    conn = cups.Connection()
    jobs = conn.getJobs(which_jobs='all')
    removed = 0
    for jobid in jobs:
        try:
            print(f"Tar bort jobb {jobid}")
            conn.cancelJob(jobid)
            removed += 1
        except Exception as e:
            print(f"  Kunde inte ta bort jobb {jobid}: {e}")
    print(f"Totalt borttagna completed-jobb: {removed}")

if __name__ == "__main__":
    main()
