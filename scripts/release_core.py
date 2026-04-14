import cups
import traceback
import subprocess

def extract_queue_name(printer_uri):
    if not printer_uri:
        return ""
    return printer_uri.split("/printers/")[-1].split("/")[0]

def release_jobs_for_user(printer_uri, username):
    FOLLOWME_QUEUE = "FollowMe"
    target_queue = extract_queue_name(printer_uri)
    conn = cups.Connection()
    jobs = conn.getJobs(which_jobs='all')
    released = 0

    for jobid in jobs:
        jobid_int = int(jobid)
        attrs = conn.getJobAttributes(jobid)
        user_ok = attrs.get('job-originating-user-name') == username
        held = attrs.get('job-state') == 4  # held/waiting

        job_queues = set([
            extract_queue_name(attrs.get('printer-uri')),
            extract_queue_name(attrs.get('job-printer-uri'))
        ])

        is_printer = target_queue in job_queues
        is_followme = FOLLOWME_QUEUE in job_queues

        if user_ok and held:
            try:
                if is_printer:
                    # Släpp jobb i aktuell kö
                    conn.setJobHoldUntil(jobid_int, 'no-hold')
                    released += 1
                elif is_followme:
                    # Flytta från FollowMe → aktuell kö och släpp
                    result = subprocess.run(["lpmove", str(jobid_int), target_queue])
                    if result.returncode != 0:
                        print(f"  Kunde inte flytta jobb {jobid_int} med lpmove, returncode={result.returncode}")
                    else:
                        conn.setJobHoldUntil(jobid_int, 'no-hold')
                        released += 1
            except Exception as e:
                print(f"  Kunde inte släppa/flytta jobb {jobid}: {e}")
                traceback.print_exc()

    return released

# CLI-test
if __name__ == "__main__":
    import sys
    if len(sys.argv) < 3:
        print("Användning: python3 release_core.py <printer_uri> <username>")
    else:
        antal = release_jobs_for_user(sys.argv[1], sys.argv[2])
        print(f"Släppte totalt {antal} jobb.")
