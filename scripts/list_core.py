import cups

def extract_queue_name(printer_uri):
    if not printer_uri:
        return ""
    return printer_uri.split("/printers/")[-1].split("/")[0]

def list_jobs_for_user(printer_uri, username):
    FOLLOWME_QUEUE = "FollowMe"
    target_queue = extract_queue_name(printer_uri)
    conn = cups.Connection()
    jobs = conn.getJobs(which_jobs='all')
    result = []
    for jobid in jobs:
        attrs = conn.getJobAttributes(jobid)
        user_ok = attrs.get('job-originating-user-name') == username
        held = attrs.get('job-state') == 4  # held/waiting

        # Matcha ENDAST på queue-name
        job_queues = set([
            extract_queue_name(attrs.get('printer-uri')),
            extract_queue_name(attrs.get('job-printer-uri')),
        ])
        printer_ok = target_queue in job_queues
        followme_ok = FOLLOWME_QUEUE in job_queues

        if user_ok and held and (printer_ok or followme_ok):
            job_info = {
                "jobid": jobid,
                "printer_uri": attrs.get('printer-uri'),
                "job_state": attrs.get('job-state'),
                "job_state_reasons": attrs.get('job-state-reasons'),
                "title": attrs.get('job-name', ''),
                "pages": max(1, attrs.get('job-media-sheets-completed', 1)),
                "submitted": attrs.get('time-at-creation'),
                "source": "followme" if followme_ok else "printer"
            }
            result.append(job_info)
    return result
