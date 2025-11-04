#!/bin/bash
# setup-scoreboard.sh
# MACCDC-style Scoreboard Service for CDCWebSim
# Tested on Kali Linux (fresh install, no extra dependencies)

set -e

SCOREBOARD_DIR="/opt/scoreboard"
WEBROOT="${SCOREBOARD_DIR}/www"
DATA_FILE="${SCOREBOARD_DIR}/score.db"
SERVICE_FILE="/etc/systemd/system/scoreboard.service"

echo "[*] Setting up Scoreboard..."

# --- Install lighttpd if missing ---
if ! command -v lighttpd >/dev/null 2>&1; then
  echo "[*] Installing lighttpd..."
  apt update -y && apt install -y lighttpd
fi

# --- Create directories ---
mkdir -p "${WEBROOT}"
mkdir -p "${SCOREBOARD_DIR}/scripts"

# --- Create score database (flat text file) ---
if [ ! -f "${DATA_FILE}" ]; then
  echo "team,uptime,attacks_blocked,flags_captured,last_update" > "${DATA_FILE}"
  echo "BlueTeam,0,0,0,$(date '+%Y-%m-%d %H:%M:%S')" >> "${DATA_FILE}"
fi

# --- Create HTML scoreboard page ---
cat <<'EOF' > "${WEBROOT}/index.html"
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
  </style>
</head>
<body>
  <h1>MACCDC Simulation Scoreboard</h1>
  <table>
    <tr><th>Team</th><th>Uptime (min)</th><th>Attacks Blocked</th><th>Flags Captured</th><th>Last Update</th></tr>
    <!--DATA-->
  </table>
  <p>Auto-refreshes every 10 seconds</p>
</body>
</html>
EOF

# --- Script to regenerate scoreboard table from score.db ---
cat <<'EOF' > "${SCOREBOARD_DIR}/scripts/update_scoreboard.sh"
#!/bin/bash
DATA_FILE="/opt/scoreboard/score.db"
HTML_FILE="/opt/scoreboard/www/index.html"

TMP="/tmp/score.tmp"
TABLE=$(awk -F, 'NR>1 {printf "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n", $1,$2,$3,$4,$5}' "${DATA_FILE}")

awk -v table="${TABLE}" '{gsub("<!--DATA-->", table)}1' "${HTML_FILE}" > "${TMP}"
mv "${TMP}" "${HTML_FILE}"
EOF
chmod +x "${SCOREBOARD_DIR}/scripts/update_scoreboard.sh"

# --- Cron job for refreshing scoreboard ---
if ! crontab -l | grep -q "update_scoreboard.sh"; then
  (crontab -l 2>/dev/null; echo "* * * * * /opt/scoreboard/scripts/update_scoreboard.sh >/dev/null 2>&1") | crontab -
fi

# --- Lighttpd configuration ---
LIGHTTPD_CONF="/etc/lighttpd/lighttpd.conf"
if ! grep -q "${WEBROOT}" "$LIGHTTPD_CONF"; then
  echo "[*] Updating lighttpd root to ${WEBROOT}"
  sed -i "s|server.document-root.*|server.document-root = \"${WEBROOT}\"|" "$LIGHTTPD_CONF"
fi

systemctl enable lighttpd
systemctl restart lighttpd

# --- Optional: create updater service for scoring events ---
cat <<'EOF' > "${SCOREBOARD_DIR}/scripts/add_score.sh"
#!/bin/bash
# add_score.sh <team> <uptime+> <blocks+> <flags+>
DATA_FILE="/opt/scoreboard/score.db"
TEAM=$1; UP=$2; BL=$3; FL=$4
if [ -z "$TEAM" ]; then echo "Usage: $0 <team> <uptime+> <blocks+> <flags+>"; exit 1; fi

LINE=$(grep "^$TEAM," "$DATA_FILE" || true)
if [ -z "$LINE" ]; then
  echo "$TEAM,0,0,0,$(date '+%Y-%m-%d %H:%M:%S')" >> "$DATA_FILE"
  LINE=$(grep "^$TEAM," "$DATA_FILE")
fi

IFS=',' read -r T U B F D <<< "$LINE"
U=$((U + UP))
B=$((B + BL))
F=$((F + FL))
D=$(date '+%Y-%m-%d %H:%M:%S')

grep -v "^$TEAM," "$DATA_FILE" > /tmp/scores.tmp
echo "$TEAM,$U,$B,$F,$D" >> /tmp/scores.tmp
mv /tmp/scores.tmp "$DATA_FILE"
/opt/scoreboard/scripts/update_scoreboard.sh
EOF
chmod +x "${SCOREBOARD_DIR}/scripts/add_score.sh"

echo "[*] Scoreboard installed successfully."
echo "[*] Access it at: http://localhost/"
echo "[*] Use add_score.sh to adjust scores. Example:"
echo "    /opt/scoreboard/scripts/add_score.sh BlueTeam 5 1 0"
