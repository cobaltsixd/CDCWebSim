#!/bin/bash
# setup-scoreboard-engine.sh
# Installs the automatic scoring framework (detectors, engine, simulated takedown)
# - Reuses existing scoreboard at /opt/scoreboard
# - Bash-only, idempotent, safe: NO offensive/exploit code
# - Requires root. Run: sudo ./setup-scoreboard-engine.sh
#
# Safety: this may STOP whitelisted services locally as a *simulation*. Only run in an isolated lab VM.

set -euo pipefail

### Sanity: must be root
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: must be run as root. Use sudo." >&2
  exit 2
fi

########################
# Paths & vars
########################
POLICY="/etc/scoreboard-policy.conf"
ENG_DIR="/opt/scoreboard/engine"
EVENT_DIR="${ENG_DIR}/events"
LOG="/var/log/scoreboard-engine.log"
SCORE_SCRIPT="/opt/scoreboard/scripts/add_score.sh"
UPDATE_SCRIPT="/opt/scoreboard/scripts/update_scoreboard.sh"
SERVICE_UNIT="/etc/systemd/system/scoreboard-engine.service"
TIMER_UNIT="/etc/systemd/system/scoreboard-engine.timer"

# Ensure scoreboard exists (we'll continue but warn)
if [ ! -d "/opt/scoreboard" ]; then
  echo "WARNING: /opt/scoreboard not found. The engine integrates with /opt/scoreboard/scripts/add_score.sh and update_scoreboard.sh."
  echo "Make sure the scoreboard is installed and scripts exist before relying on automated scoring."
fi

########################
# 1) Policy file
########################
cat > "${POLICY}" <<'EOF'
# /etc/scoreboard-policy.conf
# thresholds and whitelists
SSH_FAIL_THRESHOLD=5        # failed auths in window
SSH_FAIL_WINDOW_MIN=5       # minutes
# space-separated systemd service names that simulation may stop
SERVICE_WHITELIST="apache2 mysql lighttpd httpd"
SIM_TAKEDOWN_AFTER_MIN=10   # minutes vuln persists before simulated takedown
POINTS_SSH_BRUTE=1
POINTS_SERVICE_DOWN=5
POINTS_BLOCKED=1
EOF
chmod 644 "${POLICY}"
echo "[+] Wrote policy -> ${POLICY}"

########################
# 2) Engine directory & basic files
########################
mkdir -p "${ENG_DIR}" "${EVENT_DIR}"
touch "${LOG}"
chown -R root:root "${ENG_DIR}"
chmod 755 "${ENG_DIR}"
chmod 755 "${EVENT_DIR}"
chmod 644 "${LOG}"
echo "[+] Engine directories created: ${ENG_DIR} , ${EVENT_DIR}"

########################
# 3) service_check.sh
########################
cat > "${ENG_DIR}/service_check.sh" <<'EOF'
#!/bin/bash
# service_check.sh - checks systemd services in whitelist and writes events
POLICY="/etc/scoreboard-policy.conf"
LOG="/var/log/scoreboard-engine.log"
EVENT_DIR="/opt/scoreboard/engine/events"
mkdir -p "$EVENT_DIR"
source "$POLICY"

now=$(date +%s)
for svc in $SERVICE_WHITELIST; do
  if systemctl is-active --quiet "$svc"; then
    echo "$(date -Is) SERVICE_OK $svc" >> "$LOG"
  else
    echo "$(date -Is) SERVICE_DOWN $svc" >> "$LOG"
    printf '{"time":%s,"type":"SERVICE_DOWN","service":"%s"}\n' "$now" "$svc" > "$EVENT_DIR/service_down_${svc}_${now}.evt"
  fi
done
EOF
chmod 755 "${ENG_DIR}/service_check.sh"
echo "[+] Installed service_check.sh"

########################
# 4) ssh_fail_detector.sh
########################
cat > "${ENG_DIR}/ssh_fail_detector.sh" <<'EOF'
#!/bin/bash
# ssh_fail_detector.sh - count SSH failures in last N minutes and raise event
POLICY="/etc/scoreboard-policy.conf"
LOG="/var/log/scoreboard-engine.log"
EVENT_DIR="/opt/scoreboard/engine/events"
mkdir -p "$EVENT_DIR"
source "$POLICY"

FAILS=0
# Try journalctl for typical systemd systems (sshd or ssh unit)
if command -v journalctl >/dev/null 2>&1; then
  # try both common unit names
  FAILS=$(journalctl -u sshd -S "-${SSH_FAIL_WINDOW_MIN}m" -o short-iso 2>/dev/null | grep -E "Failed password" | wc -l || true)
  if [ -z "$FAILS" ] || [ "$FAILS" -eq 0 ]; then
    FAILS=$(journalctl -u ssh -S "-${SSH_FAIL_WINDOW_MIN}m" -o short-iso 2>/dev/null | grep -E "Failed password" | wc -l || true)
  fi
fi

# fallback to /var/log/auth.log (Debian-based)
if [ -z "$FAILS" ] || [ "$FAILS" -eq 0 ]; then
  if [ -f /var/log/auth.log ]; then
    # crude best-effort: count "Failed password" in last ~500 lines
    FAILS=$(grep "Failed password" /var/log/auth.log 2>/dev/null | tail -n 500 | wc -l || true)
  fi
fi

if [ -n "$FAILS" ] && [ "$FAILS" -ge "$SSH_FAIL_THRESHOLD" ]; then
  now=$(date +%s)
  echo "$(date -Is) SSH_BRUTE_DETECTED fails=$FAILS" >> "$LOG"
  printf '{"time":%s,"type":"SSH_BRUTE","fails":%s}\n' "$now" "$FAILS" > "${EVENT_DIR}/ssh_brute_${now}.evt"
fi
EOF
chmod 755 "${ENG_DIR}/ssh_fail_detector.sh"
echo "[+] Installed ssh_fail_detector.sh"

########################
# 5) simulate_takedown.sh (safe, whitelisted)
########################
cat > "${ENG_DIR}/simulate_takedown.sh" <<'EOF'
#!/bin/bash
# simulate_takedown.sh - safely stop a whitelisted service after policy trigger
POLICY="/etc/scoreboard-policy.conf"
LOG="/var/log/scoreboard-engine.log"
source "$POLICY"
svc="$1"
if [ -z "$svc" ]; then
  echo "Usage: $0 <service>" >&2; exit 2
fi
allowed=0
for s in $SERVICE_WHITELIST; do
  [ "$s" = "$svc" ] && allowed=1 && break
done
if [ $allowed -ne 1 ]; then
  echo "$(date -Is): Attempt to simulate takedown of non-whitelisted $svc" >> "$LOG"
  exit 3
fi
echo "$(date -Is): Simulating takedown of $svc" >> "$LOG"
# record enablement state (best-effort), then stop & disable
if systemctl is-enabled "$svc" >/dev/null 2>&1; then
  systemctl disable "$svc" >/dev/null 2>&1 || true
  echo "$svc enabled" >> /opt/scoreboard/engine/takedown_markers
else
  echo "$svc disabled" >> /opt/scoreboard/engine/takedown_markers
fi
systemctl stop "$svc" >/dev/null 2>&1 || true
EOF
chmod 755 "${ENG_DIR}/simulate_takedown.sh"
echo "[+] Installed simulate_takedown.sh"

########################
# 6) restore_services.sh
########################
cat > "${ENG_DIR}/restore_services.sh" <<'EOF'
#!/bin/bash
LOG="/var/log/scoreboard-engine.log"
MARKER="/opt/scoreboard/engine/takedown_markers"
[ -f "$MARKER" ] || { echo "No takedown markers to restore"; exit 0; }
while read -r svc state; do
  echo "$(date -Is): Restoring $svc (previous state: $state)" >> "$LOG"
  systemctl start "$svc" >/dev/null 2>&1 || true
  if [ "$state" = "enabled" ]; then
    systemctl enable "$svc" >/dev/null 2>&1 || true
  fi
done < "$MARKER"
rm -f "$MARKER"
EOF
chmod 755 "${ENG_DIR}/restore_services.sh"
echo "[+] Installed restore_services.sh"

########################
# 7) score_engine.sh (main consumer)
########################
cat > "${ENG_DIR}/score_engine.sh" <<'EOF'
#!/bin/bash
# score_engine.sh - main runner: consumes events, awards points, triggers takedown
EVENT_DIR="/opt/scoreboard/engine/events"
LOG="/var/log/scoreboard-engine.log"
POLICY="/etc/scoreboard-policy.conf"
SCORE_SCRIPT="/opt/scoreboard/scripts/add_score.sh"
SIM_SCRIPT="/opt/scoreboard/engine/simulate_takedown.sh"
source "$POLICY"
mkdir -p "$EVENT_DIR"

# process event files
for evt in "$EVENT_DIR"/*.evt; do
  [ -e "$evt" ] || continue
  payload=$(cat "$evt")
  type=$(echo "$payload" | sed -n 's/.*"type":"\([^"]*\)".*/\1/p')
  case "$type" in
    SSH_BRUTE)
      fails=$(echo "$payload" | sed -n 's/.*"fails":\([0-9]*\).*/\1/p')
      echo "$(date -Is): SSH brute detected, fails=$fails" >> "$LOG"
      # award red team flag points (configurable)
      $SCORE_SCRIPT RedTeam 0 0 $POINTS_SSH_BRUTE >/dev/null 2>&1 || true
      ;;
    SERVICE_DOWN)
      svc=$(echo "$payload" | sed -n 's/.*"service":"\([^"]*\)".*/\1/p')
      echo "$(date -Is): Service down detected: $svc" >> "$LOG"
      $SCORE_SCRIPT RedTeam 0 0 $POINTS_SERVICE_DOWN >/dev/null 2>&1 || true
      # persist for potential simulated takedown
      echo "$svc $(date +%s)" >> /opt/scoreboard/engine/down_persist
      ;;
    *)
      echo "$(date -Is): Unknown event: $payload" >> "$LOG"
      ;;
  esac
  rm -f "$evt"
done

# handle persisted downs - if older than threshold, simulate takedown
if [ -f /opt/scoreboard/engine/down_persist ]; then
  TMP="/opt/scoreboard/engine/down_persist.tmp.$$"
  > "$TMP"
  while read -r svc ts; do
    age_min=$(( ( $(date +%s) - ts ) / 60 ))
    if [ "$age_min" -ge "$SIM_TAKEDOWN_AFTER_MIN" ]; then
      $SIM_SCRIPT "$svc" >/dev/null 2>&1 || true
      $SCORE_SCRIPT RedTeam 0 0 $POINTS_SERVICE_DOWN >/dev/null 2>&1 || true
    else
      echo "$svc $ts" >> "$TMP"
    fi
  done < /opt/scoreboard/engine/down_persist
  mv "$TMP" /opt/scoreboard/engine/down_persist
fi

# Optionally: auto-award BlueTeam uptime if services healthy (simple heuristic)
# If most services in whitelist are active, give BlueTeam +1 uptime per run
active_count=0; total_count=0
for s in $SERVICE_WHITELIST; do
  total_count=$((total_count+1))
  if systemctl is-active --quiet "$s"; then active_count=$((active_count+1)); fi
done
# require >50% up to award uptime
if [ "$total_count" -gt 0 ] && [ "$active_count" -gt $(( total_count / 2 )) ]; then
  $SCORE_SCRIPT BlueTeam 1 0 0 >/dev/null 2>&1 || true
fi

# Render scoreboard (if existing update script)
if [ -x "$UPDATE_SCRIPT" ]; then
  $UPDATE_SCRIPT >/dev/null 2>&1 || true
fi
EOF
chmod 755 "${ENG_DIR}/score_engine.sh"
echo "[+] Installed score_engine.sh"

########################
# 8) Ensure ownership & perms are sane
########################
chown -R root:root "${ENG_DIR}"
chmod -R 755 "${ENG_DIR}"
chmod 644 "${LOG}" || true

########################
# 9) systemd service + timer
########################
cat > "${SERVICE_UNIT}" <<'EOF'
[Unit]
Description=Scoreboard engine runner (detectors + engine)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/scoreboard/engine/ssh_fail_detector.sh
ExecStartPost=/opt/scoreboard/engine/service_check.sh
ExecStartPost=/opt/scoreboard/engine/score_engine.sh
User=root
Nice=10
EOF

cat > "${TIMER_UNIT}" <<'EOF'
[Unit]
Description=Run scoreboard engine every minute

[Timer]
OnBootSec=30
OnUnitActiveSec=1min
AccuracySec=1s
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now scoreboard-engine.timer
echo "[+] Installed and started scoreboard-engine.timer (runs detectors+engine every minute)"

########################
# 10) initial run & smoke tests
########################
echo "[*] Running one manual iteration for smoke test..."
/opt/scoreboard/engine/ssh_fail_detector.sh || true
/opt/scoreboard/engine/service_check.sh || true
/opt/scoreboard/engine/score_engine.sh || true

echo
echo "=== quick checks ==="
systemctl --no-pager status scoreboard-engine.timer || true
journalctl -u scoreboard-engine.timer -n 50 --no-pager || true
echo "Events dir: $(ls -la ${EVENT_DIR} || true)"
echo "Engine log tail:"
tail -n 40 "${LOG}" || true

# show current scoreboard if available and web server on 8080
if command -v curl >/dev/null 2>&1; then
  echo
  echo "Attempting to fetch scoreboard page (127.0.0.1:8080):"
  curl -sS --max-time 5 http://127.0.0.1:8080/ | sed -n '1,40p' || echo "(no response on 8080)"
fi

echo
echo "Installation complete. Review /etc/scoreboard-policy.conf to adjust thresholds and whitelist."
echo "To restore services after simulated takedown: /opt/scoreboard/engine/restore_services.sh"
echo "To inspect or replay events, check: ${EVENT_DIR} and ${LOG}"
echo
echo "NOTE: This framework only *simulates* takedowns by stopping whitelisted services on the local VM. Do NOT run on production hosts."
exit 0
