import os
import json
import logging
from flask import Flask, jsonify, request
import psycopg2
from psycopg2.extras import RealDictCursor

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


def get_db_connection():
    """Open a fresh connection using environment variables."""
    return psycopg2.connect(
        host=os.environ["DB_HOST"],
        port=int(os.environ.get("DB_PORT", 5432)),
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        connect_timeout=5,
    )


@app.route("/")
def index():
    """Root endpoint: returns DB status and basic request metadata."""
    db_status = "unavailable"
    db_version = None
    error_detail = None

    try:
        conn = get_db_connection()
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute("SELECT version();")
            row = cur.fetchone()
            db_version = row["version"]
        conn.close()
        db_status = "connected"
    except Exception as exc:
        error_detail = str(exc)
        logger.error("DB connection failed: %s", exc)

    payload = {
        "status": "ok",
        "database": {
            "status": db_status,
            "version": db_version,
            "error": error_detail,
        },
        "request": {
            "method": request.method,
            "path": request.path,
            "remote_addr": request.headers.get("X-Real-IP", request.remote_addr),
            "host": request.headers.get("Host"),
        },
    }
    http_status = 200 if db_status == "connected" else 503
    return jsonify(payload), http_status


@app.route("/health")
def health():
    """Lightweight health check for Docker and load-balancer probes."""
    return jsonify({"status": "healthy"}), 200


@app.route("/db-check")
def db_check():
    """Verbose DB connectivity check."""
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute("SELECT current_database(), current_user, now();")
            db_name, db_user, db_time = cur.fetchone()
        conn.close()
        return jsonify({
            "connected": True,
            "database": db_name,
            "user": db_user,
            "server_time": str(db_time),
        }), 200
    except Exception as exc:
        logger.error("DB check failed: %s", exc)
        return jsonify({"connected": False, "error": str(exc)}), 503


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
