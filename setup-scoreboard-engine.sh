#!/bin/bash
# setup-scoreboard-engine.sh
# Automatic scoring engine (detectors + engine + safe simulated takedown)
# Plugs into /opt/scoreboard created by setup-scoreboard.sh
set -euo pipefail

echo "[*] Setting up Scoreboard engine..."

SCOREBOARD_DIR="/opt/scoreboard"
ENG_DIR="${SCOREBOARD_DIR}/engine"
EVENT_DIR="${ENG_DIR}/events"
LOG="/var/log/scoreboard-engine.log"
POLICY="/etc/scoreboard-policy.conf"
SERVICE_UNIT="/etc/systemd/system/scoreboard-engine.service"
TIMER_UNIT="/etc/systemd/system/scoreboard-engine.timer"
SCORE_SCRIPT="/opt/scoreboard/scripts/add_score.sh"
UPDATE_SCRIPT="/opt/scoreboard/scripts/update_scoreboard.sh"

# --- sanity: scoreboard should exist (we'll proceed anyway) ---
mkdir -p "${ENG_DIR}" "${EVENT_DIR}"
touch "${LOG}"

# --- policy (create if missing) ---
if [ ! -f "${POLICY}" ]; then
  cat > "${POLICY}" <<'EOF'
SSH_FAIL_THRESHOLD=5
SSH_FAIL_WINDOW_MIN=5
SERVICE_WHITELIST="lighttpd mariadb"
SIM_TAKEDOWN_AFTER_MIN=10
POINTS_SSH_BRUTE=1
POINTS_SERVICE_DOWN=5
POINTS_BLOCKED=1
EOF
fi
chmod 644 "${POLICY}"

# --- auto-detect installed services and rewrite whitelist ---
CANDIDATES="lighttpd nginx apache2 httpd mariadb mysql php-fpm postgresql"
FOUND=()
for s in $CANDIDATES; do systemctl status "$s" >/dev/null 2>&1 && FOUND+=("$s"); done
[ "${#FOUND[@]}" -eq 0 ] && FOUND=("lighttpd")
awk -v list="${FOUND[*]}" '
  BEGIN {done=0}
  /^SERVICE_WHITELIST=/ {print "SERVICE_WHITELIST=\"" list "\""; done=1; next}
  {print}
  END {if(!done) print "SERVICE_WHITELIST=\"" list "\""}
' "${POLICY}" > "${POLICY}.new" && mv "${POLICY}.new" "${POLICY}"

# --- detectors ---
cat > "${ENG_DIR}/service_check.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
POLICY="/etc/scoreboard-policy.conf"
LOG="/var/log/scoreboard-engine.log"
EVENT_DIR="/opt/scoreboard/engine/events"
mkdir -p "$EVENT_DIR"
. "$POLICY"

now=$(date +%s)
for svc in $SERVICE_WHITELIST; do
  if systemctl status "$svc" >/dev/null 2>&1; then
    if systemctl is-active --quiet "$svc"; then
      echo "$(date -Is) SERVICE_OK $svc" >> "$LOG"
    else
      echo "$(date -Is) SERVICE_DOWN $svc" >> "$LOG"
      printf '{"time":%s,"type":"SERVICE_DOWN","service":"%s"}\n' "$now" "$svc" > "$EVENT_DIR/service_down_${svc}_${now}.evt"
    fi
  fi
done
EOF
chmod +x "${ENG_DIR}/service_check.sh"

cat > "${ENG_DIR}/ssh_fail_detector.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
POLICY="/etc/scoreboard-policy.conf"
LOG="/var/log/scoreboard-engine.log"
EVENT_DIR="/opt/scoreboard/engine/events"
mkdir -p "$EVENT_DIR"
. "$POLICY"

FAILS=0
if command -v journalctl >/dev/null 2>&1; then
  FAILS=$(journalctl -u sshd -S "-${SSH_FAIL_WINDOW_MIN}m" -o short-iso 2>/dev/null | grep -E "Failed password" | wc -l || true)
  if [ -z "$FAILS" ] || [ "$FAILS" -eq 0 ]; then
    FAILS=$(journalctl -u ssh -S "-${SSH_FAIL_WINDOW_MIN}m" -o short-iso 2>/dev/null | grep -E "Failed password" | wc -l || true)
  fi
fi
if [ -z "$FAILS" ] || [ "$FAILS" -eq 0 ]; then
  [ -f /var/log/auth.log ] && FAILS=$(grep "Failed password" /var/log/auth.log 2>/dev/null | tail -n 500 | wc -l || true)
fi

if [ -n "$FAILS" ] && [ "$FAILS" -ge "$SSH_FAIL_THRESHOLD" ]; then
  now=$(date +%s)
  echo "$(date -Is) SSH_BRUTE_DETECTED fails=$FAILS" >> "$LOG"
  printf '{"time":%s,"type":"SSH_BRUTE","fails":%s}\n' "$now" "$FAILS" > "${EVENT_DIR}/ssh_brute_${now}.evt"
fi
EOF
chmod +x "${ENG_DIR}/ssh_fail_detector.sh"

# --- safe simulated takedown / restore ---
cat > "${ENG_DIR}/simulate_takedown.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
POLICY="/etc/scoreboard-policy.conf"
LOG="/var/log/scoreboard-engine.log"
. "$POLICY"
svc="${1:-}"
[ -n "$svc" ] || { echo "Usage: $0 <service>"; exit 2; }
allowed=0; for s in $SERVICE_WHITELIST; do [ "$s" = "$svc" ] && allowed=1 && break; done
[ $allowed -eq 1 ] || { echo "$(date -Is): non-whitelisted takedown $svc" >> "$LOG"; exit 3; }
echo "$(date -Is): Simulating takedown of $svc" >> "$LOG"
if systemctl is-enabled "$svc" >/dev/null 2>&1; then
  echo "$svc enabled" >> /opt/scoreboard/engine/takedown_markers
  systemctl disable "$svc" >/dev/null 2>&1 || true
else
  echo "$svc disabled" >> /opt/scoreboard/engine/takedown_markers
fi
systemctl stop "$svc" >/dev/null 2>&1 || true
EOF
chmod +x "${ENG_DIR}/simulate_takedown.sh"

cat > "${ENG_DIR}/restore_services.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
LOG="/var/log/scoreboard-engine.log"
MARKER="/opt/scoreboard/engine/takedown_markers"
[ -f "$MARKER" ] || { echo "No takedown markers"; exit 0; }
while read -r svc state; do
  echo "$(date -Is): Restoring $svc (was $state)" >> "$LOG"
  systemctl start "$svc" >/dev/null 2>&1 || true
  [ "$state" = "enabled" ] && systemctl enable "$svc" >/dev/null 2>&1 || true
done < "$MARKER"
rm -f "$MARKER"
EOF
chmod +x "${ENG_DIR}/restore_services.sh"

# --- engine (robust; Blue uptime on existing services only) ---
cat > "${ENG_DIR}/score_engine.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
EVENT_DIR="/opt/scoreboard/engine/events"
LOG="/var/log/scoreboard-engine.log"
POLICY="/etc/scoreboard-policy.conf"
SCORE_SCRIPT="/opt/scoreboard/scripts/add_score.sh"
SIM_SCRIPT="/opt/scoreboard/engine/simulate_takedown.sh"
UPDATE_SCRIPT="/opt/scoreboard/scripts/update_scoreboard.sh"
[ -f "$POLICY" ] && . "$POLICY" || {
  SSH_FAIL_THRESHOLD=5; SSH_FAIL_WINDOW_MIN=5; SERVICE_WHITELIST="lighttpd mariadb"
  SIM_TAKEDOWN_AFTER_MIN=10; POINTS_SSH_BRUTE=1; POINTS_SERVICE_DOWN=5; POINTS_BLOCKED=1; }
mkdir -p "$EVENT_DIR"; touch "$LOG"
log(){ echo "$(date -Is) $*" >> "$LOG"; }

# consume events
for evt in "$EVENT_DIR"/*.evt; do
  [ -e "$evt" ] || continue
  payload=$(cat "$evt")
  type=$(echo "$payload" | sed -n 's/.*"type":"\([^"]*\)".*/\1/p' || true)
  case "$type" in
    SSH_BRUTE)
      fails=$(echo "$payload" | sed -n 's/.*"fails":\([0-9]*\).*/\1/p' || echo 0)
      log "SSH brute detected fails=$fails"
      [ -x "$SCORE_SCRIPT" ] && "$SCORE_SCRIPT" RedTeam 0 0 "$POINTS_SSH_BRUTE" >/dev/null 2>&1 || true
      ;;
    SERVICE_DOWN)
      svc=$(echo "$payload" | sed -n 's/.*"service":"\([^"]*\)".*/\1/p' || true)
      log "Service down: $svc"
      [ -x "$SCORE_SCRIPT" ] && "$SCORE_SCRIPT" RedTeam 0 0 "$POINTS_SERVICE_DOWN" >/dev/null 2>&1 || true
      echo "$svc $(date +%s)" >> /opt/scoreboard/engine/down_persist
      ;;
    *)
      log "Unknown event: $payload"
      ;;
  esac
  rm -f "$evt"
done

# simulate takedown after persistence threshold
if [ -f /opt/scoreboard/engine/down_persist ]; then
  TMP="/opt/scoreboard/engine/down_persist.tmp.$$"; >"$TMP"
  while read -r svc ts; do
    [ -n "$svc" ] || continue
    age_min=$(( ( $(date +%s) - ts ) / 60 ))
    if [ "$age_min" -ge "${SIM_TAKEDOWN_AFTER_MIN:-10}" ]; then
      [ -x "$SIM_SCRIPT" ] && "$SIM_SCRIPT" "$svc" >/dev/null 2>&1 || log "simulate_takedown failed $svc"
      [ -x "$SCORE_SCRIPT" ] && "$SCORE_SCRIPT" RedTeam 0 0 "${POINTS_SERVICE_DOWN:-5}" >/dev/null 2>&1 || true
    else
      echo "$svc $ts" >> "$TMP"
    fi
  done < /opt/scoreboard/engine/down_persist
  mv "$TMP" /opt/scoreboard/engine/down_persist
fi

# Blue uptime: consider only services that exist
active=0; total=0
for s in $SERVICE_WHITELIST; do
  if systemctl status "$s" >/dev/null 2>&1; then
    total=$((total+1))
    systemctl is-active --quiet "$s" && active=$((active+1))
  fi
done
if [ "$total" -gt 0 ]; then
  majority=$(( (total + 1) / 2 ))
  if [ "$active" -ge "$majority" ]; then
    [ -x "$SCORE_SCRIPT" ] && "$SCORE_SCRIPT" BlueTeam 1 0 0 >/dev/null 2>&1 || true
    log "Blue +1 uptime (active=$active/total=$total)"
  else
    log "Blue uptime not awarded (active=$active/total=$total)"
  fi
else
  log "No existing services from whitelist; skip Blue uptime"
fi

[ -x "$UPDATE_SCRIPT" ] && "$UPDATE_SCRIPT" >/dev/null 2>&1 || true
exit 0
EOF
chmod +x "${ENG_DIR}/score_engine.sh"

# --- sanitize endings and ensure shebang/exec for all engine scripts ---
for f in "${ENG_DIR}"/*.sh; do
  sed -i 's/\r$//' "$f"
  grep -q '^#!' "$f" || sed -i '1i #!/bin/bash' "$f"
  chmod +x "$f"
done
chmod 644 "${LOG}" || true

# --- systemd service + timer ---
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
systemctl restart scoreboard-engine.service || true

echo
echo "[✓] Scoreboard engine installed."
echo "    Policy:   ${POLICY}"
echo "    Events:   ${EVENT_DIR}"
echo "    Restore:  /opt/scoreboard/engine/restore_services.sh"
echo "    Timer:    systemctl status scoreboard-engine.timer --no-pager"
echo
echo "Detected whitelist: $(. ${POLICY}; echo $SERVICE_WHITELIST)"
