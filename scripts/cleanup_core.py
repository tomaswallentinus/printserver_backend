import cups

def extract_queue_name(printer_uri):
    if not printer_uri:
        return ""
    return printer_uri.split("/printers/")[-1].split("/")[0]

def cleanup_jobs_for_user(printer_uri, username=None, job_id=None):
    FOLLOWME_QUEUE = "FollowMe"
    target_queue = extract_queue_name(printer_uri)
    conn = cups.Connection()
    removed = 0

    # Om job_id är angivet: ta bort bara det jobbet (ingen username-matchning krävs)
    if job_id is not None:
        try:
            conn.cancelJob(int(job_id))
            removed += 1
        except Exception as e:
            print(f"  Kunde inte ta bort jobb {job_id}: {e}")
        return removed

    # Annars: ta bort alla användarens jobb (som tidigare)
    jobs = conn.getJobs(which_jobs='all')
    for jobid in jobs:
        attrs = conn.getJobAttributes(jobid)
        user_ok = attrs.get('job-originating-user-name') == username if username else True
        held = attrs.get('job-state') == 4  # held/waiting

        job_queues = set([
            extract_queue_name(attrs.get('printer-uri')),
            extract_queue_name(attrs.get('job-printer-uri'))
        ])

        printer_ok = target_queue in job_queues
        followme_ok = FOLLOWME_QUEUE in job_queues

        if user_ok and held and (printer_ok or followme_ok):
            try:
                conn.cancelJob(jobid)
                removed += 1
            except Exception as e:
                print(f"  Kunde inte ta bort jobb {jobid}: {e}")

    return removed

# CLI-test
if __name__ == "__main__":
    import sys
    # usage: cleanup_core.py <printer_uri> [username] [job_id]
    if len(sys.argv) < 2:
        print("Användning: python3 cleanup_core.py <printer_uri> [username] [job_id]")
    else:
        printer_uri = sys.argv[1]
        username = sys.argv[2] if len(sys.argv) > 2 else None
        job_id = sys.argv[3] if len(sys.argv) > 3 else None
        antal = cleanup_jobs_for_user(printer_uri, username, job_id)
        print(f"Tog bort totalt {antal} jobb.")
