#!/usr/bin/env python3
import time, requests, mysql.connector, logging, os
from datetime import datetime

HEALTH_URL = "http://127.0.0.1/health"      # adjust to target if remote
DB_CONFIG = { 'host': '127.0.0.1', 'user': 'scorebot', 'password': 'scorepass', 'database': 'appdb' }
COMPROMISE_FLAG_PATH = "/var/target/compromised.flag"
POLL_INTERVAL = int(os.environ.get("MACCDC_POLL_INTERVAL", "15"))

LOGFILE = "/var/log/maccdc/score_log.csv"
logging.basicConfig(filename=LOGFILE, level=logging.INFO, format='%(message)s')

if not os.path.exists(LOGFILE) or os.path.getsize(LOGFILE) == 0:
    logging.info("timestamp,http_up,db_up,compromised")

def http_check():
    try:
        r = requests.get(HEALTH_URL, timeout=5)
        return r.status_code == 200
    except Exception:
        return False

def db_check():
    try:
        cnx = mysql.connector.connect(**DB_CONFIG, connection_timeout=5)
        cur = cnx.cursor()
        cur.execute("SELECT 1")
        cur.fetchall()
        cur.close()
        cnx.close()
        return True
    except Exception:
        return False

def compromise_check():
    return os.path.exists(COMPROMISE_FLAG_PATH)

def main():
    while True:
        t = datetime.utcnow().isoformat()
        h = http_check()
        d = db_check()
        c = compromise_check()
        logging.info(f"{t},{int(h)},{int(d)},{int(c)}")
        time.sleep(POLL_INTERVAL)

if __name__ == "__main__":
    main()
