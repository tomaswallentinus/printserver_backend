import os

from flask import Flask, request, jsonify, abort
from release_core import release_jobs_for_user
from list_core import list_jobs_for_user
from cleanup_core import cleanup_jobs_for_user

API_TOKEN = os.getenv("API_TOKEN")

if not API_TOKEN:
    raise RuntimeError("API_TOKEN is not set in environment")

app = Flask(__name__)

def check_token():
    token = request.args.get("token") or request.headers.get("X-API-Token")
    if token != API_TOKEN:
        abort(401, description="Invalid API token")

@app.route('/release', methods=['POST'])
def release():
    data = request.get_json(force=True)
    printer_uri = data.get('printer_uri')
    username = data.get('username')
    if not printer_uri or not username:
        return jsonify({"error": "Both printer_uri and username required"}), 400
    released = release_jobs_for_user(printer_uri, username)
    return jsonify({
        "released": released,
        "printer_uri": printer_uri,
        "username": username
    })

@app.route('/list', methods=['GET'])
def list_jobs():
    check_token()
    printer_uri = request.args.get('printer_uri')
    username = request.args.get('username')
    if not printer_uri or not username:
        return jsonify({"error": "Both printer_uri and username required"}), 400
    jobs = list_jobs_for_user(printer_uri, username)
    return jsonify({
        "printer_uri": printer_uri,
        "username": username,
        "jobs": jobs
    })

@app.route('/cleanup', methods=['POST'])
def cleanup():
    check_token()
    data = request.get_json(force=True)
    printer_uri = data.get('printer_uri')
    username = data.get('username')
    job_id = data.get('job_id')
    if not printer_uri or not username:
        return jsonify({"error": "Both printer_uri and username required"}), 400
    cleaned = cleanup_jobs_for_user(printer_uri, username, job_id)
    return jsonify({
        "cleaned": cleaned,
        "printer_uri": printer_uri,
        "username": username,
        "job_id": job_id
    })

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
