#!/bin/bash
# setup-scoreboard.sh
# MACCDC-style Scoreboard (web UI + flat-file DB) on Kali
# - Serves via lighttpd on :8080 (safe alongside nginx on :80)
# - Stable perms (www-data), no recurring 403s
# - Cron refresh as www-data
set -euo pipefail

echo "[*] Setting up Scoreboard web service..."

SCOREBOARD_DIR="/opt/scoreboard"
WEBROOT="${SCOREBOARD_DIR}/www"
SCRIPT_DIR="${SCOREBOARD_DIR}/scripts"
DATA_FILE="${SCOREBOARD_DIR}/score.db"
LIGHTTPD_CONF="/etc/lighttpd/lighttpd.conf"

# --- install lighttpd if missing ---
if ! command -v lighttpd >/dev/null 2>&1; then
  echo "[*] installing lighttpd..."
  apt update -y && apt install -y lighttpd
fi

# --- create dirs ---
mkdir -p "${WEBROOT}" "${SCRIPT_DIR}"
chmod 755 /opt "${SCOREBOARD_DIR}" "${WEBROOT}" "${SCRIPT_DIR}" || true

# --- initial DB (flat csv) ---
if [ ! -f "${DATA_FILE}" ]; then
  cat > "${DATA_FILE}" <<'EOF'
team,uptime,attacks_blocked,flags_captured,last_update
BlueTeam,0,0,0,REPLACEME
EOF
  sed -i "s/REPLACEME/$(date '+%Y-%m-%d %H:%M:%S')/" "${DATA_FILE}"
fi

# --- HTML template + first publish ---
cat > "${WEBROOT}/index.tpl" <<'EOF'
<!DOCTYPE html>
<html>
<head>
  <meta http-equiv="refresh" content="10">
  <title>MACCDC Scoreboard</title>
  <style>
    body { font-family: monospace; background:#111; color:#0f0; text-align:center; }
    h1 { color:#0f0; }
    table { margin:20px auto; border-collapse:collapse; }
    td, th { border:1px solid #0f0; padding:6px 12px; }
    .muted { color:#7f7; font-size:12px; margin-top:10px; }
  </style>
</head>
<body>
  <h1>MACCDC Simulation Scoreboard</h1>
  <table>
    <tr><th>Team</th><th>Uptime (min)</th><th>Attacks Blocked</th><th>Flags Captured</th><th>Last Update</th></tr>
    <!--DATA-->
  </table>
  <p class="muted">Auto-refreshes every 10 seconds</p>
</body>
</html>
EOF

# --- renderer: update_scoreboard.sh (safe perms, runs as www-data) ---
cat > "${SCRIPT_DIR}/update_scoreboard.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
umask 022
DATA_FILE="/opt/scoreboard/score.db"
HTML_TPL="/opt/scoreboard/www/index.tpl"
HTML_OUT="/opt/scoreboard/www/index.html"
OWNER="www-data"; GROUP="www-data"

[ -f "$DATA_FILE" ] || { echo "Missing $DATA_FILE"; exit 1; }
[ -f "$HTML_TPL" ]  || { echo "Missing $HTML_TPL"; exit 1; }
grep -q "<!--DATA-->" "$HTML_TPL" || { echo "Template missing <!--DATA-->"; exit 1; }

TABLE="$(awk -F, 'NR>1 {printf "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n",$1,$2,$3,$4,$5}' "$DATA_FILE")"
TMP="$(mktemp --tmpdir index.XXXXXX)"
awk -v table="$TABLE" '{gsub("<!--DATA-->", table)}1' "$HTML_TPL" > "$TMP"

if id "$OWNER" >/dev/null 2>&1; then
  install -o "$OWNER" -g "$GROUP" -m 0644 "$TMP" "$HTML_OUT"
else
  install -m 0644 "$TMP" "$HTML_OUT"
fi
rm -f "$TMP"
EOF
chmod +x "${SCRIPT_DIR}/update_scoreboard.sh"

# --- score adjuster (used by engine or manual) ---
cat > "${SCRIPT_DIR}/add_score.sh" <<'EOF'
#!/bin/bash
# add_score.sh <team> <uptime+> <blocks+> <flags+>
set -euo pipefail
DATA_FILE="/opt/scoreboard/score.db"
UPD="/opt/scoreboard/scripts/update_scoreboard.sh"

TEAM="${1:-}"; UP="${2:-0}"; BL="${3:-0}"; FL="${4:-0}"
if [ -z "$TEAM" ]; then
  echo "Usage: $0 <team> <uptime+> <blocks+> <flags+>" >&2; exit 2
fi

touch "$DATA_FILE"
LINE="$(grep -m1 "^${TEAM}," "$DATA_FILE" || true)"
if [ -z "$LINE" ]; then
  echo "$TEAM,0,0,0,$(date '+%Y-%m-%d %H:%M:%S')" >> "$DATA_FILE"
  LINE="$(grep -m1 "^${TEAM}," "$DATA_FILE")"
fi

IFS=',' read -r T U B F D <<< "$LINE"
U=$(( U + UP )); B=$(( B + BL )); F=$(( F + FL )); D="$(date '+%Y-%m-%d %H:%M:%S')"

# rewrite atomically
TMP="$(mktemp)"; grep -v "^${TEAM}," "$DATA_FILE" > "$TMP"
echo "$TEAM,$U,$B,$F,$D" >> "$TMP"
mv "$TMP" "$DATA_FILE"

# render page
"$UPD" >/dev/null 2>&1 || true
EOF
chmod +x "${SCRIPT_DIR}/add_score.sh"

# --- first render & perms ---
"${SCRIPT_DIR}/update_scoreboard.sh" || true
chown -R www-data:www-data "${SCOREBOARD_DIR}" || true
chmod 755 "${SCOREBOARD_DIR}" "${WEBROOT}" "${SCRIPT_DIR}" || true
chmod 644 "${WEBROOT}/"*.html "${WEBROOT}/"*.tpl 2>/dev/null || true
chmod 755 "${SCRIPT_DIR}/"*.sh 2>/dev/null || true

# --- cron refresh every minute as www-data ---
if ! crontab -l 2>/dev/null | grep -q 'update_scoreboard.sh'; then
  ( crontab -l 2>/dev/null; echo '* * * * * runuser -u www-data -- /opt/scoreboard/scripts/update_scoreboard.sh >/dev/null 2>&1' ) | crontab -
fi

# --- configure lighttpd: move to :8080 and point at WEBROOT ---
# switch port if 80 is busy, else still prefer 8080 for coexistence with nginx
if ss -tlnp | grep -qE '(:|^|\s)80\b'; then
  WANT_PORT=8080
else
  WANT_PORT=8080
fi

# ensure server.port and server.document-root are set properly
if grep -q '^server.port' "$LIGHTTPD_CONF"; then
  sed -i "s|^server.port.*|server.port = ${WANT_PORT}|" "$LIGHTTPD_CONF"
else
  echo "server.port = ${WANT_PORT}" >> "$LIGHTTPD_CONF"
fi

if grep -q '^server.document-root' "$LIGHTTPD_CONF"; then
  sed -i "s|^server.document-root.*|server.document-root = \"${WEBROOT}\"|" "$LIGHTTPD_CONF"
else
  echo "server.document-root = \"${WEBROOT}\"" >> "$LIGHTTPD_CONF"
fi

systemctl enable lighttpd >/dev/null 2>&1 || true
systemctl restart lighttpd

echo
echo "[✓] Scoreboard installed."
echo "    Web:  http://localhost:8080/"
echo "    Add:  /opt/scoreboard/scripts/add_score.sh BlueTeam 5 1 0"
