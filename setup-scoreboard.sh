#!/bin/bash
# setup-scoreboard.sh
# MACCDC-style Scoreboard Service for CDCWebSim (Kali Linux, Bash-only)
# - Serves a simple scoreboard via lighttpd
# - Stores scores in a flat text file
# - Auto-detects port conflicts (keeps nginx on :80, moves lighttpd to :8080)
# - Idempotent: safe to re-run

set -euo pipefail

# -------------------------
# Configurable paths
# -------------------------
SCOREBOARD_DIR="/opt/scoreboard"
WEBROOT="${SCOREBOARD_DIR}/www"
DATA_FILE="${SCOREBOARD_DIR}/score.db"
SCRIPTS_DIR="${SCOREBOARD_DIR}/scripts"
LIGHTTPD_CONF="/etc/lighttpd/lighttpd.conf"
LIGHTTPD_USER="www-data"
CRON_LINE="* * * * * ${SCRIPTS_DIR}/update_scoreboard.sh >/dev/null 2>&1"

echo "[*] Setting up Scoreboard..."

# -------------------------
# Ensure lighttpd present
# -------------------------
if ! command -v lighttpd >/dev/null 2>&1; then
  echo "[*] Installing lighttpd..."
  apt update -y && apt install -y lighttpd
fi

# -------------------------
# Create directories/files
# -------------------------
mkdir -p "${WEBROOT}" "${SCRIPTS_DIR}"

# Data file
if [ ! -f "${DATA_FILE}" ]; then
  echo "team,uptime,attacks_blocked,flags_captured,last_update" > "${DATA_FILE}"
  echo "BlueTeam,0,0,0,$(date '+%Y-%m-%d %H:%M:%S')" >> "${DATA_FILE}"
fi

# HTML template
cat > "${WEBROOT}/index.html" <<'EOF'
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

# -------------------------
# Render helper scripts
# -------------------------

# Renders table rows from score.db into index.html
cat > "${SCRIPTS_DIR}/update_scoreboard.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
DATA_FILE="/opt/scoreboard/score.db"
HTML_FILE="/opt/scoreboard/www/index.html"

TMP="$(mktemp)"
TABLE="$(awk -F, 'NR>1 {printf "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n", $1,$2,$3,$4,$5}' "${DATA_FILE}")"

# Replace marker in HTML
awk -v table="${TABLE}" '{gsub("<!--DATA-->", table)}1' "${HTML_FILE}" > "${TMP}"
cat "${TMP}" > "${HTML_FILE}"
rm -f "${TMP}"
EOF
chmod +x "${SCRIPTS_DIR}/update_scoreboard.sh"

# Increments a team's counters and re-renders
cat > "${SCRIPTS_DIR}/add_score.sh" <<'EOF'
#!/bin/bash
# Usage: add_score.sh <team> <uptime+> <blocks+> <flags+>
set -euo pipefail
DATA_FILE="/opt/scoreboard/score.db"

TEAM="${1:-}"
UP="${2:-0}"
BL="${3:-0}"
FL="${4:-0}"

if [ -z "$TEAM" ]; then
  echo "Usage: $0 <team> <uptime+> <blocks+> <flags+>"
  exit 1
fi

# Ensure team exists (create if needed)
if ! grep -q "^${TEAM}," "$DATA_FILE"; then
  echo "${TEAM},0,0,0,$(date '+%Y-%m-%d %H:%M:%S')" >> "$DATA_FILE"
fi

# Read existing line
LINE="$(grep "^${TEAM}," "$DATA_FILE")"
IFS=',' read -r _TEAM U B F D <<< "$LINE"

# Safe arithmetic (default to zero if empty)
U=$(( ${U:-0} + ${UP:-0} ))
B=$(( ${B:-0} + ${BL:-0} ))
F=$(( ${F:-0} + ${FL:-0} ))
D="$(date '+%Y-%m-%d %H:%M:%S')"

# Write back
grep -v "^${TEAM}," "$DATA_FILE" > "${DATA_FILE}.tmp"
echo "${TEAM},${U},${B},${F},${D}" >> "${DATA_FILE}.tmp"
mv "${DATA_FILE}.tmp" "$DATA_FILE"

/opt/scoreboard/scripts/update_scoreboard.sh
EOF
chmod +x "${SCRIPTS_DIR}/add_score.sh"

# -------------------------
# Cron: refresh scoreboard every minute
# -------------------------
# Add once (if not present)
( crontab -l 2>/dev/null | grep -v -F "${SCRIPTS_DIR}/update_scoreboard.sh" || true
  echo "${CRON_LINE}"
) | crontab -

# Render once immediately
"${SCRIPTS_DIR}/update_scoreboard.sh"

# -------------------------
# Configure lighttpd
# -------------------------

# Backup config once per run
if [ -f "${LIGHTTPD_CONF}" ]; then
  cp -a "${LIGHTTPD_CONF}" "${LIGHTTPD_CONF}.bak.$(date +%s)"
fi

# Ensure document-root points to our WEBROOT (replace if present, else append)
if grep -qE '^\s*server\.document-root' "${LIGHTTPD_CONF}"; then
  sed -i "s@^\s*server\.document-root.*@server.document-root = \"${WEBROOT}\"@" "${LIGHTTPD_CONF}"
else
  printf '\nserver.document-root = "%s"\n' "${WEBROOT}" >> "${LIGHTTPD_CONF}"
fi

# If port 80 is taken (e.g., nginx), switch lighttpd to 8080
PORT_IN_USE="$(ss -tln | awk '$4 ~ /:80$/ {print $4}' || true)"
if [ -n "${PORT_IN_USE}" ]; then
  echo "[*] Port 80 is in use (likely nginx). Setting lighttpd to port 8080."
  if grep -qE '^\s*server\.port' "${LIGHTTPD_CONF}"; then
    sed -i 's/^\s*server\.port.*/server.port = 8080/' "${LIGHTTPD_CONF}"
  else
    printf '\nserver.port = 8080\n' >> "${LIGHTTPD_CONF}"
  fi
  SCOREBOARD_URL="http://localhost:8080/"
else
  # Keep/default to port 80
  if grep -qE '^\s*server\.port' "${LIGHTTPD_CONF}"; then
    sed -i 's/^\s*server\.port.*/server.port = 80/' "${LIGHTTPD_CONF}"
  else
    printf '\nserver.port = 80\n' >> "${LIGHTTPD_CONF}"
  fi
  SCOREBOARD_URL="http://localhost/"
fi

# -------------------------
# Permissions for web server
# -------------------------
chown -R "${LIGHTTPD_USER}:${LIGHTTPD_USER}" "${SCOREBOARD_DIR}"
chmod -R 755 "${SCOREBOARD_DIR}"

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
echo "[*] lighttpd status:"
systemctl --no-pager --full status lighttpd || true

echo "[*] Listening sockets on :80 or :8080:"
(ss -tlnp | grep -E ':80\b|:8080\b') || true

echo
echo "[*] Scoreboard installed."
echo "    Data file: ${DATA_FILE}"
echo "    Add score: ${SCRIPTS_DIR}/add_score.sh BlueTeam 5 1 0"
echo "    View at  : ${SCOREBOARD_URL}"
echo
echo "[*] If you want nginx to serve it at /scoreboard, add this to your nginx server block and reload nginx:"
cat <<'NGINX_HINT'

location /scoreboard/ {
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_pass http://127.0.0.1:8080/;
}
# then run:
#   nginx -t && systemctl reload nginx
NGINX_HINT
