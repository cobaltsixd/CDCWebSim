#!/bin/bash
# setup-scoreboard-engine.sh
# Single-file scoring engine (detectors + scoring + rendering) for CDCWebSim
# - No separate detector scripts. Everything lives in /opt/scoreboard/engine/engine.sh
# - Safe in a lab; NO offensive actions. Optional simulated takedown is whitelisted.
set -euo pipefail

echo "[*] Installing single-file scoreboard engine..."

SCOREBOARD_DIR="/opt/scoreboard"
ENG_DIR="${SCOREBOARD_DIR}/engine"
ENGINE="${ENG_DIR}/engine.sh"
LOG="/var/log/scoreboard-engine.log"
POLICY="/etc/scoreboard-policy.conf"
SERVICE_UNIT="/etc/systemd/system/scoreboard-engine.service"
TIMER_UNIT="/etc/systemd/system/scoreboard-engine.timer"
SCORE_SCRIPT="/opt/scoreboard/scripts/add_score.sh"
UPDATE_SCRIPT="/opt/scoreboard/scripts/update_scoreboard.sh"

mkdir -p "${ENG_DIR}"
touch "${LOG}"
chmod 644 "${LOG}" || true

# --- Policy defaults (created if missing) ---
if [ ! -f "${POLICY}" ]; then
  cat > "${POLICY}" <<'EOF'
# /etc/scoreboard-policy.conf
SSH_FAIL_THRESHOLD=5
SSH_FAIL_WINDOW_MIN=5
# This whitelist is auto-detected below; these are just safe defaults
SERVICE_WHITELIST="lighttpd mariadb"
SIM_TAKEDOWN_AFTER_MIN=10
POINTS_SSH_BRUTE=1
POINTS_SERVICE_DOWN=5
POINTS_BLOCKED=1
# Blue uptime: +1 when a majority of existing services are UP
# Block de-dupe window (seconds) per source IP
BLOCK_DEDUPE_SECONDS=300
EOF
fi
chmod 644 "${POLICY}"

# --- Auto-detect present services & rewrite whitelist in policy ---
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

# --- Single-file engine with built-in detectors ---
cat > "${ENGINE}" <<'EOF'
#!/bin/bash
# /opt/scoreboard/engine/engine.sh
# One script to detect, score, and render.
set -euo pipefail

POLICY="/etc/scoreboard-policy.conf"
LOG="/var/log/scoreboard-engine.log"
SCORE_SCRIPT="/opt/scoreboard/scripts/add_score.sh"
UPDATE_SCRIPT="/opt/scoreboard/scripts/update_scoreboard.sh"

# Load policy (with sane fallbacks)
if [ -f "$POLICY" ]; then
  # shellcheck source=/dev/null
  . "$POLICY"
else
  SSH_FAIL_THRESHOLD=5
  SSH_FAIL_WINDOW_MIN=5
  SERVICE_WHITELIST="lighttpd mariadb"
  SIM_TAKEDOWN_AFTER_MIN=10
  POINTS_SSH_BRUTE=1
  POINTS_SERVICE_DOWN=5
  POINTS_BLOCKED=1
  BLOCK_DEDUPE_SECONDS=300
fi

log(){ echo "$(date -Is) $*" >> "$LOG"; }

# ------------------------------
# Helpers: existence checks
# ------------------------------
svc_exists(){ systemctl status "$1" >/dev/null 2>&1; }
svc_active(){ systemctl is-active --quiet "$1"; }

# ------------------------------
# Detector A: SSH brute attempts (last N minutes)
# awards RedTeam flags for detected brute window
# ------------------------------
detect_ssh_brute(){
  local fails=0
  if command -v journalctl >/dev/null 2>&1; then
    fails=$(journalctl -u sshd -S "-${SSH_FAIL_WINDOW_MIN}m" -o short-iso 2>/dev/null | grep -c "Failed password" || true)
    if [ "$fails" -eq 0 ]; then
      fails=$(journalctl -u ssh -S "-${SSH_FAIL_WINDOW_MIN}m" -o short-iso 2>/dev/null | grep -c "Failed password" || true)
    fi
  fi
  if [ "$fails" -eq 0 ] && [ -f /var/log/auth.log ]; then
    fails=$(grep "Failed password" /var/log/auth.log 2>/dev/null | tail -n 500 | wc -l || true)
  fi
  if [ "$fails" -ge "$SSH_FAIL_THRESHOLD" ]; then
    log "SSH_BRUTE fails=$fails (window ${SSH_FAIL_WINDOW_MIN}m)"
    [ -x "$SCORE_SCRIPT" ] && "$SCORE_SCRIPT" RedTeam 0 0 "$POINTS_SSH_BRUTE" >/dev/null 2>&1 || true
  fi
}

# ------------------------------
# Detector B: Service health (whitelist)
# - awards RedTeam flags when service is down
# - persists "down since" to /opt/scoreboard/engine/down_persist
# - simulates takedown after threshold (stop/disable) ONLY for whitelisted names
# ------------------------------
persist_file="/opt/scoreboard/engine/down_persist"
simulate_takedown(){
  local svc="$1"
  # Only act on svc that is in whitelist per policy
  local allowed=0 s
  for s in $SERVICE_WHITELIST; do [ "$s" = "$svc" ] && allowed=1 && break; done
  [ $allowed -eq 1 ] || { log "Takedown skipped (not whitelisted): $svc"; return 0; }
  log "Simulating takedown of $svc"
  # Remember enablement state and stop/disable (best-effort)
  if systemctl is-enabled "$svc" >/dev/null 2>&1; then
    echo "$svc enabled" >> /opt/scoreboard/engine/takedown_markers
    systemctl disable "$svc" >/dev/null 2>&1 || true
  else
    echo "$svc disabled" >> /opt/scoreboard/engine/takedown_markers
  fi
  systemctl stop "$svc" >/dev/null 2>&1 || true
}

detect_services(){
  local now ts svc age_min
  mkdir -p "$(dirname "$persist_file")"
  # mark down services and award Red points once per tick
  for svc in $SERVICE_WHITELIST; do
    if svc_exists "$svc"; then
      if svc_active "$svc"; then
        log "SERVICE_OK $svc"
      else
        log "SERVICE_DOWN $svc"
        [ -x "$SCORE_SCRIPT" ] && "$SCORE_SCRIPT" RedTeam 0 0 "$POINTS_SERVICE_DOWN" >/dev/null 2>&1 || true
        echo "$svc $(date +%s)" >> "$persist_file"
      fi
    fi
  done

  # simulate takedown if down persisted >= threshold
  if [ -f "$persist_file" ]; then
    local tmp="${persist_file}.tmp.$$"; : > "$tmp"
    while read -r svc ts; do
      [ -n "${svc:-}" ] || continue
      age_min=$(( ( $(date +%s) - ts ) / 60 ))
      if [ "$age_min" -ge "$SIM_TAKEDOWN_AFTER_MIN" ]; then
        simulate_takedown "$svc" || true
        [ -x "$SCORE_SCRIPT" ] && "$SCORE_SCRIPT" RedTeam 0 0 "$POINTS_SERVICE_DOWN" >/dev/null 2>&1 || true
      else
        echo "$svc $ts" >> "$tmp"
      fi
    done < "$persist_file"
    mv "$tmp" "$persist_file"
  fi
}

# ------------------------------
# Detector C: "Attacks Blocked" (Blue)
# Multiple sources, best-effort, all inline, with de-dupe per IP
#  - Fail2Ban: /var/log/fail2ban.log or journalctl -u fail2ban
#  - Kernel / rsyslog drops: grep "DROP" lines in recent logs (best-effort)
#  - Suricata eve.json (simple grep for \"action\":\"drop\"|\"reject\" if present; no jq)
# Awards: BlueTeam 0 1 0 (per deduped IP within BLOCK_DEDUPE_SECONDS)
# ------------------------------
seen_file="/opt/scoreboard/engine/blocked_seen"
dedupe_ok(){
  local ip="$1" now last
  now=$(date +%s)
  if [ -f "$seen_file" ] && grep -q "^${ip} " "$seen_file"; then
    last=$(grep "^${ip} " "$seen_file" | tail -n1 | awk '{print $2}')
    [ -z "$last" ] && last=0
    if [ $(( now - last )) -lt "${BLOCK_DEDUPE_SECONDS:-300}" ]; then
      return 1
    fi
  fi
  # record/update
  (grep -v "^${ip} " "$seen_file" 2>/dev/null || true) > "${seen_file}.tmp" 2>/dev/null || true
  echo "$ip $now" >> "${seen_file}.tmp"
  mv "${seen_file}.tmp" "$seen_file"
  return 0
}

award_block_ip(){
  local ip="$1" src="$2"
  [ -z "$ip" ] && return 0
  if dedupe_ok "$ip"; then
    log "BLOCKED $ip source=$src (+${POINTS_BLOCKED} Blue)"
    [ -x "$SCORE_SCRIPT" ] && "$SCORE_SCRIPT" BlueTeam 0 1 0 >/dev/null 2>&1 || true
  else
    log "BLOCKED duplicate within window: $ip source=$src (ignored)"
  fi
}

detect_blocks(){
  local lines ip

  # Fail2Ban
  if command -v journalctl >/dev/null 2>&1; then
    lines=$(journalctl -u fail2ban -S "-2m" -o short-iso 2>/dev/null | grep "Ban" || true)
    while IFS= read -r l; do
      ip=$(echo "$l" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tail -n1 || true)
      [ -n "$ip" ] && award_block_ip "$ip" "fail2ban-journal"
    done <<< "$lines"
  fi
  if [ -f /var/log/fail2ban.log ]; then
    lines=$(grep "Ban" /var/log/fail2ban.log 2>/dev/null | tail -n 50 || true)
    while IFS= read -r l; do
      ip=$(echo "$l" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tail -n1 || true)
      [ -n "$ip" ] && award_block_ip "$ip" "fail2ban-log"
    done <<< "$lines"
  fi

  # Kernel/ufw/iptables drops in syslog (best-effort)
  for cand in /var/log/kern.log /var/log/syslog /var/log/messages; do
    [ -f "$cand" ] || continue
    lines=$(tail -n 200 "$cand" | grep -E 'DROP|REJECT' || true)
    while IFS= read -r l; do
      ip=$(echo "$l" | grep -oE 'SRC=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | cut -d= -f2 || true)
      [ -n "$ip" ] && award_block_ip "$ip" "kernel"
    done <<< "$lines"
  done

  # Suricata eve.json (no jq): simple grep for action lines, pull ip heuristically
  if [ -f /var/log/suricata/eve.json ]; then
    lines=$(tail -n 200 /var/log/suricata/eve.json | grep -E '"action":"(drop|reject)"' || true)
    while IFS= read -r l; do
      ip=$(echo "$l" | grep -oE '"src_ip":"[^"]+"' | head -n1 | cut -d: -f2 | tr -d '"' || true)
      [ -z "$ip" ] && ip=$(echo "$l" | grep -oE '"dest_ip":"[^"]+"' | head -n1 | cut -d: -f2 | tr -d '"' || true)
      [ -n "$ip" ] && award_block_ip "$ip" "suricata"
    done <<< "$lines"
  fi
}

# ------------------------------
# Blue uptime heuristic:
# +1 minute if >= half (rounded up) of EXISTING services in whitelist are active
# ------------------------------
score_blue_uptime(){
  local total=0 active=0 s
  for s in $SERVICE_WHITELIST; do
    if svc_exists "$s"; then
      total=$((total+1))
      svc_active "$s" && active=$((active+1))
    fi
  done
  if [ "$total" -gt 0 ]; then
    local majority=$(( (total + 1) / 2 ))
    if [ "$active" -ge "$majority" ]; then
      [ -x "$SCORE_SCRIPT" ] && "$SCORE_SCRIPT" BlueTeam 1 0 0 >/dev/null 2>&1 || true
      log "Blue +1 uptime (active=$active/total=$total)"
    else
      log "Blue uptime not awarded (active=$active/total=$total)"
    fi
  else
    log "No existing services from whitelist; skip Blue uptime"
  fi
}

# ------------------------------
# RUN all detectors, then render
# ------------------------------
detect_ssh_brute
detect_services
detect_blocks
score_blue_uptime

[ -x "$UPDATE_SCRIPT" ] && "$UPDATE_SCRIPT" >/dev/null 2>&1 || true
exit 0
EOF

# Ensure proper shebang/permissions and strip any CRLF
sed -i 's/\r$//' "${ENGINE}"
grep -q '^#!' "${ENGINE}" || sed -i '1i #!/bin/bash' "${ENGINE}"
chmod 755 "${ENGINE}"
chown root:root "${ENGINE}"

# --- systemd: call only this engine script ---
cat > "${SERVICE_UNIT}" <<'EOF'
[Unit]
Description=Scoreboard engine (single-file detector+scorer+renderer)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/scoreboard/engine/engine.sh
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
# kick one run now
systemctl start scoreboard-engine.service || true

echo
echo "[✓] Single-file engine installed."
echo "    Engine:   ${ENGINE}"
echo "    Policy:   ${POLICY}"
echo "    Log:      ${LOG}"
echo "    Timer:    systemctl status scoreboard-engine.timer --no-pager"
echo "    Quick DB: head -n 5 /opt/scoreboard/score.db"
