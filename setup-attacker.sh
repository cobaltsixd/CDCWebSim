#!/usr/bin/env bash
# setup-attacker.sh
# Safe attacker-behavior simulator for MACCDC lab (Bash only).
# - DOES NOT scan, exploit, or send network traffic.
# - Generates realistic log entries and artifacts locally for detection exercises.
#
# Usage:
#   sudo bash setup-attacker.sh
set -euo pipefail

SIM_DIR="/opt/attacker-sim"
SIM_LOG="/var/log/attacker-sim.log"
ALERT_JSON="/var/log/attacker-sim-alerts.json"
SERVICE_NAME="attacker-sim.service"
TIMER_NAME="attacker-sim.timer"

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root (sudo). Exiting."
  exit 1
fi

echo "[*] Creating simulator directory: ${SIM_DIR}"
mkdir -p "${SIM_DIR}"
chown root:root "${SIM_DIR}"
chmod 755 "${SIM_DIR}"

echo "[*] Creating main log: ${SIM_LOG}"
touch "${SIM_LOG}"
chown root:adm "${SIM_LOG}" || true
chmod 640 "${SIM_LOG}"

# helper functions file
cat > "${SIM_DIR}/utils.sh" <<'EOF'
#!/usr/bin/env bash
# small helpers
rand_int(){ shuf -n1 -i "$1-$2"; }
rand_ip(){
  case $(rand_int 1 3) in
    1) echo "10.$(rand_int 0 255).$(rand_int 0 255).$(rand_int 1 254)";;
    2) echo "172.$(rand_int 16 31).$(rand_int 0 255).$(rand_int 1 254)";;
    3) echo "192.168.$(rand_int 0 255).$(rand_int 1 254)";;
  esac
}
rand_user(){
  arr=(root admin test guest alice bob carol devops www-data svc_backup)
  echo "${arr[$(rand_int 0 $((${#arr[@]} - 1)))]}"
}
now(){ date -u +"%b %d %H:%M:%S"; }   # syslog-like
ts_iso(){ date -u +"%Y-%m-%dT%H:%M:%SZ"; }
EOF
chmod 700 "${SIM_DIR}/utils.sh"

# generator: auth failures
cat > "${SIM_DIR}/gen_authfail.sh" <<'EOF'
#!/usr/bin/env bash
SIM_LOG="/var/log/attacker-sim.log"
TARGET_AUTH="/var/log/auth.log"
source "$(dirname "$0")/utils.sh"

src=$(rand_ip)
user=$(rand_user)
attempts=$(rand_int 2 10)

for i in $(seq 1 ${attempts}); do
  line="$(now) kali-host sshd[$$]: Failed password for ${user} from ${src} port $(rand_int 1024 65535) ssh2"
  if [ -w "${TARGET_AUTH}" ]; then
    echo "${line}" >> "${TARGET_AUTH}" || true
  else
    echo "$(ts_iso) AUTHFAIL src=${src} user=${user} attempt=${i}" >> "${SIM_LOG}" || true
  fi
  sleep 0.08
done
EOF
chmod 700 "${SIM_DIR}/gen_authfail.sh"

# generator: web probe (writes to apache/nginx logs if present else sim log)
cat > "${SIM_DIR}/gen_webprobe.sh" <<'EOF'
#!/usr/bin/env bash
SIM_LOG="/var/log/attacker-sim.log"
APACHE_LOG="/var/log/apache2/access.log"
NGINX_LOG="/var/log/nginx/access.log"
source "$(dirname "$0")/utils.sh"

paths=(/ /login /admin /wp-login.php /api/v1/items /search)
payloads=("id=1" "q=%3Cscript%3E" "id=../../etc/passwd" "user' OR '1'='1" "cmd=ls" "name=admin'--")

for i in $(seq 1 $(rand_int 1 6)); do
  src=$(rand_ip)
  path=${paths[$(rand_int 0 $((${#paths[@]} - 1)))]}
  payload=${payloads[$(rand_int 0 $((${#payloads[@]} - 1)))]}
  ua="Mozilla/5.0 (compatible; BadBot/1.0)"
  logline="${src} - - [$(date -u +'%d/%b/%Y:%H:%M:%S +0000')] \"GET ${path}?${payload} HTTP/1.1\" 200 1234 \"-\" \"${ua}\""
  if [ -w "${APACHE_LOG}" ]; then
    echo "${logline}" >> "${APACHE_LOG}" || true
  elif [ -w "${NGINX_LOG}" ]; then
    echo "${logline}" >> "${NGINX_LOG}" || true
  else
    echo "$(ts_iso) WEBPROBE src=${src} path=${path} payload='${payload}' ua='${ua}'" >> "${SIM_LOG}" || true
  fi
done
EOF
chmod 700 "${SIM_DIR}/gen_webprobe.sh"

# generator: phishing/mail-like logs
cat > "${SIM_DIR}/gen_phish.sh" <<'EOF'
#!/usr/bin/env bash
SIM_LOG="/var/log/attacker-sim.log"
MAIL_LOG="/var/log/mail.log"
source "$(dirname "$0")/utils.sh"

subjects=("Invoice Attached" "Please Reset Password" "New Document Shared" "Urgent: Verify Account")
domains=("example.com" "corp.internal" "finance.local")
for i in $(seq 1 $(rand_int 1 4)); do
  src="mailer@${domains[$(rand_int 0 $((${#domains[@]} - 1)))]}"
  dst="$(rand_user)@${domains[$(rand_int 0 $((${#domains[@]} - 1)))]}"
  subj="${subjects[$(rand_int 0 $((${#subjects[@]} - 1)))]}"
  line="$(now) kali-mail postfix/smtp[$$]: to=<${dst}>, relay=none, delay=0.1, status=deferred (simulated)"
  if [ -w "${MAIL_LOG}" ]; then
    echo "${line}" >> "${MAIL_LOG}" || true
  else
    echo "$(ts_iso) PHISH src=${src} dst=${dst} subject='${subj}' action=delivered" >> "${SIM_LOG}" || true
  fi
done
EOF
chmod 700 "${SIM_DIR}/gen_phish.sh"

# plant harmless file in webroot
cat > "${SIM_DIR}/plant_webshell.sh" <<'EOF'
#!/usr/bin/env bash
DOCROOT="/var/www/html"
SIM_LOG="/var/log/attacker-sim.log"
source "$(dirname "$0")/utils.sh"

mkdir -p "${DOCROOT}"
fn="suspicious_$(date -u +%Y%m%d%H%M%S).txt"
echo "# harmless indicator file - do not execute" > "${DOCROOT}/${fn}"
echo "created_by=attacker-sim created_at=$(ts_iso) note='indicator file for detection exercises'" >> "${DOCROOT}/${fn}"
chmod 644 "${DOCROOT}/${fn}" || true
echo "$(ts_iso) PLANT file=${DOCROOT}/${fn} note='planted harmless indicator in webroot'" >> "${SIM_LOG}" || true
EOF
chmod 700 "${SIM_DIR}/plant_webshell.sh"

# create harmless credential dump artifact
cat > "${SIM_DIR}/dump_creds.sh" <<'EOF'
#!/usr/bin/env bash
OUT="/opt/attacker-sim/creds_dump_$(date -u +%Y%m%d%H%M%S).txt"
SIM_LOG="/var/log/attacker-sim.log"
source "$(dirname "$0")/utils.sh"

echo "# fake creds dump - harmless" > "${OUT}"
echo "admin:AdminPass123" >> "${OUT}"
echo "service:ServicePass!" >> "${OUT}"
chmod 600 "${OUT}" || true
echo "$(ts_iso) ARTIFACT created=${OUT} note='fake creds dump for detection/testing'" >> "${SIM_LOG}" || true
EOF
chmod 700 "${SIM_DIR}/dump_creds.sh"

# IDS-like JSON alerts
cat > "${SIM_DIR}/gen_ids_alert.sh" <<'EOF'
#!/usr/bin/env bash
SIM_LOG="/var/log/attacker-sim.log"
ALERT_FILE="/var/log/attacker-sim-alerts.json"
source "$(dirname "$0")/utils.sh"

types=("ET SCAN SYN Stealth" "WEB-ATTACK SQLi" "MALWARE C2" "SUSPICIOUS AUTH")
for i in $(seq 1 $(rand_int 1 4)); do
  alert="${types[$(rand_int 0 $((${#types[@]} - 1)))]}"
  obj="{\"timestamp\":\"$(ts_iso)\",\"alert\":\"${alert}\",\"src\":\"$(rand_ip)\",\"dst\":\"$(rand_ip)\",\"signature_id\":$(rand_int 1000 9999)}"
  echo "${obj}" >> "${ALERT_FILE}" || true
  echo "$(ts_iso) IDS alert written ${alert}" >> "${SIM_LOG}" || true
done
EOF
chmod 700 "${SIM_DIR}/gen_ids_alert.sh"

# orchestrator runner
cat > "${SIM_DIR}/runner.sh" <<'EOF'
#!/usr/bin/env bash
SIM_LOG="/var/log/attacker-sim.log"
SIM_DIR="$(dirname "$0")"
source "${SIM_DIR}/utils.sh"

# rotate sim log if large
if [ -f "${SIM_LOG}" ]; then
  lines=$(wc -l < "${SIM_LOG}" || echo 0)
  if [ "${lines}" -gt 20000 ]; then
    mv "${SIM_LOG}" "${SIM_LOG}.$(date -u +%Y%m%d%H%M%S)" || true
    touch "${SIM_LOG}"
    chmod 640 "${SIM_LOG}" || true
  fi
fi

case $(rand_int 1 10) in
  1|2|3)
    "${SIM_DIR}/gen_webprobe.sh"
    ;;
  4|5|6)
    "${SIM_DIR}/gen_authfail.sh"
    sleep 0.2
    "${SIM_DIR}/gen_webprobe.sh"
    ;;
  7|8)
    "${SIM_DIR}/gen_phish.sh"
    "${SIM_DIR}/gen_ids_alert.sh"
    ;;
  9)
    "${SIM_DIR}/plant_webshell.sh"
    "${SIM_DIR}/dump_creds.sh"
    "${SIM_DIR}/gen_ids_alert.sh"
    ;;
  10)
    "${SIM_DIR}/gen_authfail.sh"
    sleep 0.1
    "${SIM_DIR}/gen_webprobe.sh"
    sleep 0.1
    "${SIM_DIR}/gen_phish.sh"
    sleep 0.1
    "${SIM_DIR}/gen_ids_alert.sh"
    "${SIM_DIR}/plant_webshell.sh"
    ;;
esac

# occasional marker event for escalation playbooks
if [ "$(rand_int 1 20)" -eq 1 ]; then
  echo "$(ts_iso) EVENT escalation=simulated_priv_esc note='no exploit executed; marker for playbook' " >> "${SIM_LOG}" || true
fi
EOF
chmod 700 "${SIM_DIR}/runner.sh"

# systemd service and timer
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
TIMER_PATH="/etc/systemd/system/${TIMER_NAME}"

cat > "${SERVICE_PATH}" <<EOF
[Unit]
Description=Attacker Behavior Simulator (harmless)
After=network.target

[Service]
Type=oneshot
ExecStart=${SIM_DIR}/runner.sh
User=root
Group=root
Nice=10
TimeoutStartSec=120
EOF

cat > "${TIMER_PATH}" <<EOF
[Unit]
Description=Run attacker-behavior-simulator every 60s

[Timer]
OnBootSec=30
OnUnitActiveSec=60
Unit=${SERVICE_NAME}

[Install]
WantedBy=timers.target
EOF

echo "[*] Reloading systemd and enabling timer..."
systemctl daemon-reload
systemctl enable --now "${TIMER_NAME}"

# README
cat > "${SIM_DIR}/README.txt" <<'EOF'
Attacker Behavior Simulator (safe)
---------------------------------
Location: /opt/attacker-sim
Main log: /var/log/attacker-sim.log
Alert JSON: /var/log/attacker-sim-alerts.json
Artifacts: /opt/attacker-sim/creds_dump_*.txt
Planted files: /var/www/html/suspicious_*.txt

Scripts:
 - gen_authfail.sh    : simulate ssh auth failures (writes to /var/log/auth.log if writable)
 - gen_webprobe.sh    : simulate web requests (writes to apache/nginx logs if present)
 - gen_phish.sh       : simulated mail/phishing log entries
 - plant_webshell.sh  : plants harmless indicator file in webroot
 - dump_creds.sh      : creates harmless credential dump file (local)
 - gen_ids_alert.sh   : emits IDS-like JSON alert lines
 - runner.sh          : orchestrator (invoked by systemd timer every minute)

Notes:
 - No network scanning or exploitation is performed.
 - To stop: sudo systemctl stop ${TIMER_NAME}
 - To remove: sudo systemctl disable --now ${TIMER_NAME}; rm -rf ${SIM_DIR}; rm -f ${SERVICE_PATH} ${TIMER_PATH}
EOF

echo
echo "[*] Setup complete."
echo " - Simulator dir: ${SIM_DIR}"
echo " - Main log: ${SIM_LOG}"
echo " - Alert JSON: ${ALERT_JSON}"
echo " - Systemd timer: ${TIMER_NAME} (runs every 60s)"
echo
echo "Quick checks:"
echo "  systemctl status ${TIMER_NAME}"
echo "  tail -n 80 ${SIM_LOG}"
echo "  tail -n 80 ${ALERT_JSON}"
echo "  ls -l ${SIM_DIR}"
echo
echo "Manual test (run a mixed scenario now):"
echo "  sudo ${SIM_DIR}/runner.sh && tail -n 60 ${SIM_LOG}"
echo
exit 0
