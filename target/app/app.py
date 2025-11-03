#!/usr/bin/env python3
from flask import Flask, request, session, jsonify
import mysql.connector
from pathlib import Path
import os

app = Flask(__name__)
app.secret_key = os.environ.get("MACCDC_SECRET", "dev-secret-key")

DB_CONFIG = {
    'host': '127.0.0.1',
    'user': 'root',
    'password': '',   # adjust if you set a root password
    'database': 'appdb'
}

COMPROMISE_FLAG = Path("/var/target/compromised.flag")

@app.route("/health")
def health():
    return "OK", 200

@app.route("/")
def index():
    return "<h2>MACCDC Target (simulation)</h2><p>Health: <a href=/health>/health</a></p>"

@app.route("/login", methods=["GET","POST"])
def login():
    if request.method == "GET":
        return """
        <html><body>
        <form method="POST">
          <input name="username" placeholder="username"/><br/>
          <input name="password" placeholder="password" type="password"/><br/>
          <input type="submit" value="Login"/>
        </form>
        </body></html>
        """
    username = request.form.get("username","")
    password = request.form.get("password","")
    # intentionally weak seeded credential for the lab
    if username == "weakuser" and password == "weakpass":
        session['user'] = username
        return "Login OK", 200
    return "Unauthorized", 401

@app.route("/simulate_compromise", methods=["GET"])
def simulate_compromise():
    caller = request.remote_addr
    # allow if attacker IP or if previously logged in
    if session.get('user') == 'weakuser' or caller == '127.0.0.1' or caller.startswith('192.168.'):
        try:
            COMPROMISE_FLAG.write_text("compromised\n")
            return "Compromise recorded", 200
        except Exception as e:
            return f"Write error: {e}", 500
    return "Forbidden", 403

@app.route("/check_db")
def check_db():
    try:
        conn = mysql.connector.connect(**DB_CONFIG)
        cur = conn.cursor()
        cur.execute("SELECT COUNT(*) FROM flags WHERE id=1;")
        r = cur.fetchone()
        cur.close()
        conn.close()
        return jsonify({'ok': True, 'count': r[0]})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)
