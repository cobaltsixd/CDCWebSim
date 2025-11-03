#!/usr/bin/env python3
import time, requests, os

WAIT_SECONDS = int(os.environ.get("WAIT_SECONDS", os.environ.get("MACCDC_WAIT_SECONDS", "1200")))  # default 20m
LOGIN_URL = os.environ.get("MACCDC_LOGIN_URL", "http://127.0.0.1/login")
SIM_URL = os.environ.get("MACCDC_SIM_URL", "http://127.0.0.1/simulate_compromise")
CREDENTIALS = {'username': os.environ.get("MACCDC_WEAK_USER", "weakuser"),
               'password': os.environ.get("MACCDC_WEAK_PASS", "weakpass")}

def do_simulation():
    try:
        s = requests.Session()
        r = s.post(LOGIN_URL, data=CREDENTIALS, timeout=5)
        print("login status", r.status_code)
        if r.status_code == 200:
            rr = s.get(SIM_URL, timeout=5)
            print("simulate result", rr.status_code, rr.text)
        else:
            print("login failed - simulation did not mark compromise")
    except Exception as e:
        print("attacker error", e)

if __name__ == "__main__":
    print(f"Attacker sleeping {WAIT_SECONDS} seconds before starting")
    time.sleep(WAIT_SECONDS)
    do_simulation()
