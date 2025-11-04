#!/bin/bash
# setup-scoreboard.sh
# MACCDC-style Scoreboard Service for CDCWebSim (Kali Linux, Bash-only)
# - Serves a simple scoreboard via lighttpd
# - Stores scores in a flat text file
# - Uses a persistent HTML template so updates always work
# - Makes outputs world-readable on every render (no recurring 403)
# - Auto-detects port conflicts (keeps nginx on :80, moves lighttpd to :8080)
# - Idempotent: safe to re-run
# Usage: sudo ./setup-scoreboard.sh

set -euo pipefail

# -------------------------
# Configurable paths & vars
# -------------------------
SCOREBOARD_DIR="/opt/scoreboard"
WEBROOT="${SCOREBOARD_DIR}/www"
DATA_FILE="${SCOREBOARD_DIR}/score.db"
SCRIPTS_DIR="${SCOREBOARD_DIR}/scripts"
LIGHTTPD_CONF="/etc/lighttpd/lighttpd.conf"
LIGHTTPD_USER="www-data"
CRON_CMD="runuser -u ${LIGHTTPD_USER} -- ${SCRIPTS_DIR}/update_scoreboard.sh >/dev/null 2>&1"
CRON_LINE="* * * * * ${CRON_CMD}"

echo "[*] Setting up Scoreboard..."

# -------------------------
# Ensure lighttpd present
# -------------------------
if ! command -v lighttpd >/dev/null 2>&1; then
  echo "[*] Installing lighttpd..."
  apt update -y
  apt install -y lighttpd
fi

# -------------------------
# Create directories/files
# -------------------------
mkdir -p "${WEBROOT}" "${SCRIPTS_DIR}"

# Data file (CSV header + BlueTeam default)
if [ ! -f "${DATA_FILE}" ]; then
  echo "team,uptime,attacks_blocked,flags_captured,last_update" > "${DATA_FILE}"
  echo "BlueTeam,0,0,0,$(date '+%Y-%m-%d %H:%M:%S')" >> "${DATA_FILE}"
fi

# -------------------------
# Create persistent HTML template (index.tpl)
# -------------------------
cat > "${WEBROOT}/index.tpl" <<'EOF'
<!DOCTYPE html>
<html>
<head>
  <meta http-equiv="refresh" content="10">
  <title>MACCDC Scoreboard</title>
  <style>
    body { font-family: monospace; background: #111; color: #0f0; text-align: center; }
    h1 { color: #0f0; }
    table { margin: 20px auto; border-collapse: collapse; }
    td, th { border: 1px solid #0f0; padding: 6px 12px; }
    .note { color: #8f8; margin-top: 10px; }
  </style>
</head>
<body>
  <h1>MACCDC Simulation Scoreboard</h1>
  <table>
    <tr><th>Team</th><th>Uptime (min)</th><th>Attacks Blocked</th><th>Flags Captured</th><th>Last Update</th></tr>
    <!--DATA-->
  </table>
  <div class="note">Auto-refreshes every 10 seconds</div>
</body>
</html>
EOF

# If index.html is missing, render once from template
if [ ! -f "${WEBROOT}/index.html" ]; then
  cp "${WEBROOT}/index.tpl" "${WEBROOT}/index.html"
fi

# -------------------------
# Render helper scripts
# -------------------------

# update_scoreboard.sh - render template -> index.html using score.db
cat > "${SCRIPTS_DIR}/update_scoreboard.sh" <<'EOF'
#!/bin/bash
# Renders /opt/scoreboard/www/index.html from index.tpl and score.db
# Ensures output is world-readable to avoid recurring 403s.
set -euo pipefail
umask 022   # files 0644, dirs 0755

DATA_FILE="/opt/scoreboard/score.db"
HTML_TPL="/opt/scoreboard/www/index.tpl"
HTML_OUT="/opt/scoreboard/www/index.html"
OWNER="www-data"
GROUP="www-data"

[ -f "$DATA_FILE" ] || { echo "Missing $DATA_FILE"; exit 1; }
[ -f "$HTML_TPL" ]  || { echo "Missing $HTML_TPL"; exit 1; }
grep -q "<!--DATA-->" "$HTML_TPL" || { echo "Template missing <!--DATA--> marker"; exit 1; }

TABLE="$(awk -F, 'NR>1 {printf "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n",$1,$2,$3,$4,$5}' "$DATA_FILE")"

TMP="$(mktemp --tmpdir update_scoreboard.XXXXXX)"
awk -v table="$TABLE" '{gsub("<!--DATA-->", table)}1' "$HTML_TPL" > "$TMP"

# Publish atomically with correct perms/owner
if id "$OWNER" >/dev/null 2>&1; then
  install -o "$OWNER" -g "$GROUP" -m 0644 "$TMP" "$HTML_OUT"
else
  install -m 0644 "$TMP" "$HTML_OUT"
fi
rm -f "$TMP"
EOF
chmod +x "${SCRIPTS_DIR}/update_scoreboard.sh"

# add_score.sh - increment counters and trigger update
cat > "${SCRIPTS_DIR}/add_score.sh" <<'EOF'
#!/bin/bash
# Usage: add_score.sh <team> <uptime+> <blocks+> <flags+>
set -euo pipefail
umask 022
DATA_FILE="/opt/scoreboard/score.db"

TEAM="${1:-}"
UP="${2:-0}"
BL="${3:-0}"
FL="${4:-0}"

if [ -z "$TEAM" ]; then
  echo "Usage: $0 <team> <uptime+> <blocks+> <flags+>"
  exit 1
fi

# ensure team row exists
if ! grep -q "^${TEAM}," "$DATA_FILE"; then
  echo "${TEAM},0,0,0,$(date '+%Y-%m-%d %H:%M:%S')" >> "$DATA_FILE"
fi

LINE="$(grep "^${TEAM}," "$DATA_FILE")"
IFS=',' read -r _TEAM U B F D <<< "$LINE"

U=$(( ${U:-0} + ${UP:-0} ))
B=$(( ${B:-0} + ${BL:-0} ))
F=$(( ${F:-0} + ${FL:-0} ))
D="$(date '+%Y-%m-%d %H:%M:%S')"

# rewrite file
grep -v "^${TEAM}," "$DATA_FILE" > "${DATA_FILE}.tmp"
echo "${TEAM},${U},${B},${F},${D}" >> "${DATA_FILE}.tmp"
mv "${DATA_FILE}.tmp" "$DATA_FILE"

# keep ownership stable for web user if present
if id www-data >/dev/null 2>&1; then
  chown www-data:www-data "$DATA_FILE"
fi

# render
/opt/scoreboard/scripts/update_scoreboard.sh
EOF
chmod +x "${SCRIPTS_DIR}/add_score.sh"

# -------------------------
# Cron: refresh scoreboard every minute (root crontab)
# (Runs updater as www-data so ownership/perms stay consistent)
# -------------------------
CRONTAB_TMP="$(mktemp)"
crontab -l 2>/dev/null | grep -v -F "${CRON_CMD}" > "${CRONTAB_TMP}" || true
echo "${CRON_LINE}" >> "${CRONTAB_TMP}"
crontab "${CRONTAB_TMP}"
rm -f "${CRONTAB_TMP}"

# render once immediately (safe)
"${SCRIPTS_DIR}/update_scoreboard.sh"

# -------------------------
# Configure lighttpd
# -------------------------
# Backup config
if [ -f "${LIGHTTPD_CONF}" ]; then
  cp -a "${LIGHTTPD_CONF}" "${LIGHTTPD_CONF}.bak.$(date +%s)"
fi

# Ensure document-root points to our WEBROOT (replace if present, else append)
if grep -qE '^\s*server\.document-root' "${LIGHTTPD_CONF}"; then
  sed -i "s@^\s*server\.document-root.*@server.document-root = \"${WEBROOT}\"@" "${LIGHTTPD_CONF}"
else
  printf '\nserver.document-root = "%s"\n' "${WEBROOT}" >> "${LIGHTTPD_CONF}"
fi

# If port 80 is in use (e.g., nginx), switch lighttpd to 8080
if ss -tln | grep -qE ':80\b'; then
  echo "[*] Port 80 in use; setting lighttpd to port 8080"
  if grep -qE '^\s*server\.port' "${LIGHTTPD_CONF}"; then
    sed -i 's/^\s*server\.port.*/server.port = 8080/' "${LIGHTTPD_CONF}"
  else
    printf '\nserver.port = 8080\n' >> "${LIGHTTPD_CONF}"
  fi
  SCOREBOARD_URL="http://localhost:8080/"
else
  if grep -qE '^\s*server\.port' "${LIGHTTPD_CONF}"; then
    sed -i 's/^\s*server\.port.*/server.port = 80/' "${LIGHTTPD_CONF}"
  else
    printf '\nserver.port = 80\n' >> "${LIGHTTPD_CONF}"
  fi
  SCOREBOARD_URL="http://localhost/"
fi

# Minimal, known-good module set if not present (defensive)
if ! grep -q "^server.modules" "${LIGHTTPD_CONF}"; then
cat >> "${LIGHTTPD_CONF}" <<'EOF'

server.modules = (
  "mod_access",
  "mod_accesslog"
)
index-file.names = ( "index.html" )
dir-listing.activate = "disable"
mimetype.assign = ( ".html" => "text/html" )
EOF
fi

# -------------------------
# Fix permissions so lighttpd can read everything (prevents 403)
# -------------------------
echo "[*] Setting safe permissions for scoreboard files..."

# Ensure execute bits on parent directories (webserver needs +x to traverse)
chmod 755 /opt || true
chmod 755 /opt/scoreboard || true
chmod 755 /opt/scoreboard/www || true

# Ensure web content is world-readable
chmod 644 /opt/scoreboard/www/*.html 2>/dev/null || true
chmod 644 /opt/scoreboard/www/*.tpl  2>/dev/null || true

# Ensure scripts are executable (for root/cron) and readable
chmod 755 /opt/scoreboard/scripts/*.sh 2>/dev/null || true

# Ownership to web user so reads never fail
if id "${LIGHTTPD_USER}" >/dev/null 2>&1; then
  chown -R "${LIGHTTPD_USER}:${LIGHTTPD_USER}" "${SCOREBOARD_DIR}"
fi

# -------------------------
# Validate & (re)start service
# -------------------------
echo "[*] Testing lighttpd config..."
lighttpd -t -f "${LIGHTTPD_CONF}"

echo "[*] Enabling and restarting lighttpd..."
systemctl enable lighttpd >/dev/null 2>&1 || true
systemctl restart lighttpd

# -------------------------
# Final checks & output
# -------------------------
echo
echo "[*] lighttpd status:"
systemctl --no-pager --full status lighttpd || true

echo
echo "[*] Listening sockets on :80 or :8080:"
(ss -tlnp | grep -E ':80\b|:8080\b') || true

echo
echo "[*] Verifying web files (mode/owner):"
ls -l /opt/scoreboard/www/index.tpl /opt/scoreboard/www/index.html || true

echo
echo "[*] Scoreboard installed."
echo "    Data file: ${DATA_FILE}"
echo "    Add score: ${SCRIPTS_DIR}/add_score.sh BlueTeam 5 1 0"
echo "    View at  : ${SCOREBOARD_URL}"

exit 0
