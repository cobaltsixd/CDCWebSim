README-ATTACKER.md

This is the Attacker Behavior Simulator for the MACCDC-style lab. It’s intentionally safe — it does not scan, exploit, or send network traffic. Instead it generates realistic attacker behavior artifacts (log lines, IDS JSON, planted indicator files, fake credential dumps) on the local Kali VM so defenders can practice detection, triage, and hardening.

Read this once, then copy the file to /opt/attacker-sim/README-ATTACKER.md or keep it with your course repo.

What this does (short)

Creates /opt/attacker-sim/ with a set of small Bash generators.

Writes believable attacker-style lines into:

/var/log/attacker-sim.log (main simulator log)

/var/log/attacker-sim-alerts.json (IDS-like JSON alerts)

if available, to real service logs such as /var/log/auth.log, /var/log/apache2/access.log, /var/log/mail.log.

Places harmless artifact files:

/var/www/html/suspicious_*.txt (indicator files)

/opt/attacker-sim/creds_dump_*.txt (fake credential dumps)

Uses a systemd oneshot service + timer to run the runner every 60 seconds.

This is aimed at teaching detection and hardening — not at doing real offensive activity.

Files & scripts (what’s in /opt/attacker-sim)

utils.sh — helper functions (random IPs, timestamps, etc.)

gen_authfail.sh — simulate SSH failed logins (writes to /var/log/auth.log if writable)

gen_webprobe.sh — simulate malicious-looking HTTP GETs (writes to Apache/Nginx access logs if writable)

gen_phish.sh — simulate phishing/mail delivery entries (writes to /var/log/mail.log if writable)

plant_webshell.sh — plant a harmless indicator file in webroot (non-executable text file)

dump_creds.sh — create a harmless credential artifact in /opt/attacker-sim/

gen_ids_alert.sh — write IDS-style JSON lines to /var/log/attacker-sim-alerts.json

runner.sh — orchestrator that runs generators in different patterns

README.txt — short operator notes (same directory)

Systemd units:

/etc/systemd/system/attacker-sim.service — oneshot service that runs runner.sh

/etc/systemd/system/attacker-sim.timer — timer that triggers the service every 60s

Quick start

(If you used setup-attacker.sh this is already done.)

Start (enable timer):

sudo systemctl enable --now attacker-sim.timer


Stop:

sudo systemctl stop attacker-sim.timer


Run a single mixed scenario immediately:

sudo /opt/attacker-sim/runner.sh


Manual generator run (one at a time):

sudo /opt/attacker-sim/gen_authfail.sh
sudo /opt/attacker-sim/gen_webprobe.sh
sudo /opt/attacker-sim/gen_phish.sh
sudo /opt/attacker-sim/gen_ids_alert.sh
sudo /opt/attacker-sim/plant_webshell.sh
sudo /opt/attacker-sim/dump_creds.sh

Where to look for evidence

Main simulator log (always present):
/var/log/attacker-sim.log

IDS-like JSON alerts:
/var/log/attacker-sim-alerts.json

If webserver present and writable:
/var/log/apache2/access.log or /var/log/nginx/access.log

If auth log writable:
/var/log/auth.log

Planted artifacts:
/var/www/html/suspicious_*.txt
/opt/attacker-sim/creds_dump_*.txt

Example lines you should expect (values randomized):

2025-11-03T21:12:34Z WEBPROBE src=10.2.3.4 path=/admin payload='id=../../etc/passwd' ua='Mozilla/5.0 (compatible; BadBot/1.0)'
2025-11-03T21:12:35Z IDS alert written WEB-ATTACK SQLi
2025-11-03T21:12:36Z PLANT file=/var/www/html/suspicious_20251103211236.txt note='planted harmless indicator in webroot'
2025-11-03T21:12:36Z ARTIFACT created=/opt/attacker-sim/creds_dump_20251103211236.txt note='fake creds dump for detection/testing'

How to verify it’s working

Run these checks as root:

Check timer:

systemctl list-timers --all | grep attacker-sim


You should see attacker-sim.timer with NEXT time within ~60s.

Check last service run / journal:

systemctl status attacker-sim.service
journalctl -u attacker-sim.service -n 200 --no-pager


Tail logs live:

tail -n 0 -F /var/log/attacker-sim.log /var/log/attacker-sim-alerts.json 2>/dev/null | sed '/^$/d'


Let it run for ~60–90s and you should see new lines.

Manual mixed run + tail:

sudo /opt/attacker-sim/runner.sh && tail -n 60 /var/log/attacker-sim.log


If anything errors, check:

scripts are executable: ls -l /opt/attacker-sim/*.sh

CRLFs removed: sed -n '1,2p' /opt/attacker-sim/runner.sh | xxd (should show no 0d)

main sim log writable: ls -l /var/log/attacker-sim.log

Troubleshooting (quick)

bad substitution or syntax error near unexpected token → strip CRLFs and ensure scripts are executable:

for f in /opt/attacker-sim/*.sh; do sed -i 's/\r$//' "$f"; chmod +x "$f"; done


permission denied when writing logs → ensure /var/log/attacker-sim.log exists and is writable by root:

touch /var/log/attacker-sim.log
chown root:adm /var/log/attacker-sim.log || true
chmod 640 /var/log/attacker-sim.log


If a generator is not writing to a real service log, it will fall back to the sim log. That’s expected.

Safety note (important)

This simulator does not perform network scans, brute force attacks, or exploits. All activity is local and inert:

planted files are text indicators only (do not run them).

credential dumps are fake, for detection practice only.

If you later want to run real offensive tooling, do it only in a properly isolated, authorized lab and follow your institution’s rules.

How to use this in the lab (suggestions)

Detection drills: have students write rules (Suricata, Sigma, Splunk queries, grep/awk) to find bursts of AUTHFAIL, WEBPROBE, PLANT, or IDS JSON alerts.

Hardening drills: before running the simulator, harden the target (SSH keys only, fail2ban, WAF, file perms) and then run specific generators to prove the hardening prevented an outcome (for example, webroot rejects plant_webshell.sh).

Playbook exercises: feed /var/log/attacker-sim-alerts.json into the scoreboard/SIEM and require students to follow a short playbook (isolate host, collect artifacts, run triage).

Scoring idea: score both prevention (did hardening block writing to service logs/webroot?) and detection (did SIEM/IDS generate an alert? did student acknowledge and act?).

Scoring rubric (simple 10-point example)

Use this if you want a quick scoreboard. Tweak to your rules:

SSH: PasswordAuthentication no — 1 pt

SSH: PermitRootLogin no — 1 pt

Fail2ban/sshguard blocks after burst — 1 pt

WAF/ModSecurity blocks web-probe payloads or logs them as blocked — 1 pt

Webroot permissions non-writable by attacker account — 1 pt

File Integrity Monitor (AIDE/Tripwire) alerts on planted file — 1 pt

SIEM ingests /var/log/attacker-sim-alerts.json within X sec — 1 pt

Student runs playbook after IDS alert (isolate + collect) — 1 pt

Evidence collection present (screenshots/journals/PCAP) — 1 pt
(Total = 10 pts)

Customization ideas

Change timer frequency: edit /etc/systemd/system/attacker-sim.timer.

Add more generators: copy an existing generator and tweak payload lists.

Make it non-root for tougher tests: run runner under a restricted account that has only write access to certain logs — then hardening must be evaluated accordingly.

Add Windows-event-style logs (for Windows target VM) — I can supply templates.

Removal / cleanup

To stop and remove the sim:

sudo systemctl disable --now attacker-sim.timer
sudo rm -f /etc/systemd/system/attacker-sim.service /etc/systemd/system/attacker-sim.timer
sudo systemctl daemon-reload
sudo rm -rf /opt/attacker-sim
sudo rm -f /var/log/attacker-sim.log /var/log/attacker-sim-alerts.json
sudo rm -f /var/www/html/suspicious_*.txt /opt/attacker-sim/creds_dump_*.txt
