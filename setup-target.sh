#!/usr/bin/env bash
# MACCDC Target Host Setup (Kali Linux)
# Installs: Apache+PHP (web), MariaDB (db)
# Mode: --vuln (default) exposes weak configs for hardening practice
#       --harden applies safer defaults
# Re-run safe. No Python or external tooling required.

set -euo pipefail

### --------------------------
### Config (can be overridden by env or flags)
### --------------------------
MODE="${MODE:-vuln}"                 # vuln | harden
SITE_NAME="${SITE_NAME:-target}"     # Apache site name
SITE_DIR="/var/www/${SITE_NAME}"
DB_NAME="${DB_NAME:-scoredb}"
DB_USER="${DB_USER:-webapp}"
DB_PASS="${DB_PASS:-password}"       # intentionally weak in vuln mode
DB_ROOT_PASS="${DB_ROOT_PASS:-root}" # set only if MariaDB has no root pw (local socket auth by default)
LISTEN_HTTP_PORT="${LISTEN_HTTP_PORT:-80}"
# In vuln mode we'll open MariaDB to all interfaces; in harden mode we keep it local only.
DB_BIND_ALL="${DB_BIND_ALL:-}"
APACHE_EXPOSE_TOKENS_ON="${APACHE_EXPOSE_TOKENS_ON:-}"
AUTO_INDEX_ON="${AUTO_INDEX_ON:-}"
PHP_INFO_PAGE_ON="${PHP_INFO_PAGE_ON:-}"

### --------------------------
### Parse flags
### --------------------------
usage() {
  cat <<EOF
Usage: sudo ./setup-target.sh [--vuln | --harden]

Sets up a single Kali VM as the MACCDC target with:
- Apache + PHP (web)
- MariaDB (database)
- Sample app + weak defaults (in --vuln) for students to harden

Options:
  --vuln     Default. Intentionally weak service posture.
  --harden   Apply safer defaults (baseline hardening).

Environment overrides:
  MODE=vuln|harden SITE_NAME=target DB_NAME=scoredb DB_USER=webapp DB_PASS=password DB_ROOT_PASS=root LISTEN_HTTP_PORT=80

Examples:
  sudo ./setup-target.sh
  sudo MODE=harden DB_PASS='S3cure!Pass' ./setup-target.sh --harden
EOF
}

while [[ "${1:-}" =~ ^- ]]; do
  case "$1" in
    --vuln) MODE="vuln"; shift ;;
    --harden) MODE="harden"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)."
  exit 1
fi

echo "[*] Mode: ${MODE}"

if [[ "${MODE}" == "vuln" ]]; then
  DB_BIND_ALL="yes"
  APACHE_EXPOSE_TOKENS_ON="yes"
  AUTO_INDEX_ON="yes"
  PHP_INFO_PAGE_ON="yes"
else
  DB_BIND_ALL=""
  APACHE_EXPOSE_TOKENS_ON=""
  AUTO_INDEX_ON=""
  PHP_INFO_PAGE_ON=""
fi

### --------------------------
### Helpers
### --------------------------
systemd_enable_restart() {
  local svc="$1"
  systemctl daemon-reload
  systemctl enable --now "$svc"
  systemctl restart "$svc"
  systemctl status "$svc" --no-pager -l || true
}

file_backup() {
  local f="$1"
  if [[ -f "$f" && ! -f "${f}.bak" ]]; then
    cp -a "$f" "${f}.bak"
  fi
}

apt_install() {
  local pkgs=("$@")
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends "${pkgs[@]}"
}

### --------------------------
### Install packages
### --------------------------
echo "[*] Installing Apache, PHP, MariaDB..."
apt_install apache2 php libapache2-mod-php php-mysqli mariadb-server curl

### --------------------------
### MariaDB config
### --------------------------
echo "[*] Configuring MariaDB..."
# Bind-address
MYSQL_CONF="/etc/mysql/mariadb.conf.d/50-server.cnf"
file_backup "$MYSQL_CONF"

if [[ -n "$DB_BIND_ALL" ]]; then
  sed -i 's/^\s*#\?\s*bind-address\s*=.*/bind-address = 0.0.0.0/' "$MYSQL_CONF" || true
  # if line absent, append
  grep -q 'bind-address' "$MYSQL_CONF" || echo "bind-address = 0.0.0.0" >> "$MYSQL_CONF"
else
  sed -i 's/^\s*#\?\s*bind-address\s*=.*/bind-address = 127.0.0.1/' "$MYSQL_CONF" || true
  grep -q 'bind-address' "$MYSQL_CONF" || echo "bind-address = 127.0.0.1" >> "$MYSQL_CONF"
fi

systemd_enable_restart mariadb

# Create DB + user (idempotent)
echo "[*] Creating database and user..."
mysql -u root <<SQL || true
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%' , '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

# Schema and seed
mysql -u root "${DB_NAME}" <<'SQL' || true
CREATE TABLE IF NOT EXISTS users (
  id INT AUTO_INCREMENT PRIMARY KEY,
  username VARCHAR(64) UNIQUE,
  password VARCHAR(64),
  role VARCHAR(32) DEFAULT 'user'
);
INSERT IGNORE INTO users (id, username, password, role) VALUES
  (1,'admin','admin123','admin'),
  (2,'student','student','user'),
  (3,'guest','guest','user');
CREATE TABLE IF NOT EXISTS flags (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(64),
  value VARCHAR(255)
);
INSERT IGNORE INTO flags (id, name, value) VALUES
  (1,'welcome','wvu6or7{target_ready}'),
  (2,'db_access','wvu6or7{mysql_basics}'),
  (3,'web_misconfig','wvu6or7{fix_the_headers}');
SQL

### --------------------------
### Apache + PHP site
### --------------------------
echo "[*] Configuring Apache vhost and content..."
mkdir -p "${SITE_DIR}"

# Basic index + guidance (safe to show)
cat > "${SITE_DIR}/index.php" <<'PHP'
<?php
$mode = getenv('TARGET_MODE') ?: 'vuln';
?>
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>MACCDC Target</title>
</head>
<body>
  <h1>MACCDC Target Host</h1>
  <p>Welcome to the target web service.</p>
  <ul>
    <li><a href="/app/login.php">Sample App (login)</a></li>
<?php if ($mode === 'vuln'): ?>
    <li><a href="/app/search.php">User Search (SQLi-prone)</a></li>
    <li><a href="/phpinfo.php">phpinfo()</a> (should be removed in hardening)</li>
<?php endif; ?>
  </ul>
  <p><em>Mode:</em> <?php echo htmlspecialchars($mode); ?></p>
</body>
</html>
PHP

# Sample "intentionally weak" app pages (for hardening practice)
mkdir -p "${SITE_DIR}/app"

cat > "${SITE_DIR}/app/login.php" <<'PHP'
<?php
/* Intentionally simple login to teach SQL injection prevention & auth hardening */
$mysqli = @new mysqli(getenv('DB_HOST') ?: '127.0.0.1', getenv('DB_USER') ?: 'webapp',
                      getenv('DB_PASS') ?: 'password', getenv('DB_NAME') ?: 'scoredb', 3306);
$err = $mysqli->connect_error ? "DB connect failed: ".$mysqli->connect_error : "";
$msg = "";
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
  $u = $_POST['username'] ?? '';
  $p = $_POST['password'] ?? '';
  // VULN: string concat query — students should replace with prepared statements
  $sql = "SELECT username, role FROM users WHERE username='$u' AND password='$p' LIMIT 1";
  $res = $mysqli->query($sql);
  if ($res && $res->num_rows === 1) {
    $row = $res->fetch_assoc();
    $msg = "Login OK: ".$row['username']." (".$row['role'].")";
  } else {
    $msg = "Login failed.";
  }
}
?>
<!doctype html><html><head><meta charset="utf-8"><title>Login</title></head><body>
<h2>Sample Login</h2>
<?php if($err) echo "<p style='color:red'>".$err."</p>"; ?>
<form method="post" autocomplete="off">
  <label>User: <input name="username"></label><br>
  <label>Pass: <input name="password" type="password"></label><br>
  <button type="submit">Login</button>
</form>
<p><?php echo htmlspecialchars($msg); ?></p>
</body></html>
PHP

cat > "${SITE_DIR}/app/search.php" <<'PHP'
<?php
/* Simple "user search" to show errors, listing, and input sanitization gaps */
$mysqli = @new mysqli(getenv('DB_HOST') ?: '127.0.0.1', getenv('DB_USER') ?: 'webapp',
                      getenv('DB_PASS') ?: 'password', getenv('DB_NAME') ?: 'scoredb', 3306);
$q = $_GET['q'] ?? '';
$rows = [];
$err = '';
if ($q !== '') {
  // VULN: LIKE with unsanitized input
  $sql = "SELECT id, username, role FROM users WHERE username LIKE '%$q%'";
  $res = $mysqli->query($sql);
  if ($res) { while($r = $res->fetch_assoc()) $rows[] = $r; } else { $err = $mysqli->error; }
}
?>
<!doctype html><html><head><meta charset="utf-8"><title>User Search</title></head><body>
<h2>User Search</h2>
<form method="get">
  <input name="q" value="<?php echo htmlspecialchars($q); ?>" placeholder="try ' or 1=1 -- ">
  <button type="submit">Search</button>
</form>
<?php if ($err) echo "<pre style='color:red'>Error: ".htmlspecialchars($err)."</pre>"; ?>
<table border="1" cellpadding="4" cellspacing="0">
<tr><th>ID</th><th>Username</th><th>Role</th></tr>
<?php foreach($rows as $r): ?>
<tr><td><?php echo (int)$r['id']; ?></td>
    <td><?php echo htmlspecialchars($r['username']); ?></td>
    <td><?php echo htmlspecialchars($r['role']); ?></td></tr>
<?php endforeach; ?>
</table>
</body></html>
PHP

# Optional phpinfo page in vuln mode
if [[ -n "$PHP_INFO_PAGE_ON" ]]; then
  cat > "${SITE_DIR}/phpinfo.php" <<'PHP'
<?php phpinfo();
PHP
else
  rm -f "${SITE_DIR}/phpinfo.php" || true
fi

# robots.txt that leaks paths in vuln mode
if [[ -n "$AUTO_INDEX_ON" ]]; then
  cat > "${SITE_DIR}/robots.txt" <<'TXT'
User-agent: *
Disallow: /app/
Allow: /app/search.php
Sitemap: /sitemap.xml
# Hint: clean this up during hardening
TXT
else
  cat > "${SITE_DIR}/robots.txt" <<'TXT'
User-agent: *
Disallow:
TXT
fi

# Apache vhost
VHOST_CONF="/etc/apache2/sites-available/${SITE_NAME}.conf"
cat > "$VHOST_CONF" <<EOF
<VirtualHost *:${LISTEN_HTTP_PORT}>
    ServerName ${SITE_NAME}.local
    DocumentRoot ${SITE_DIR}

    <Directory ${SITE_DIR}>
        Options ${AUTO_INDEX_ON:+Indexes} FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${SITE_NAME}_error.log
    CustomLog \${APACHE_LOG_DIR}/${SITE_NAME}_access.log combined

    # Headers students should fix in hardening:
    ${APACHE_EXPOSE_TOKENS_ON:+ServerSignature On}
    ${APACHE_EXPOSE_TOKENS_ON:+ServerTokens Full}
    Header always set X-Powered-By "PHP/5 forever"   # intentionally bad; remove in hardening
</VirtualHost>
EOF

# Apache ports config
APACHE_PORTS="/etc/apache2/ports.conf"
file_backup "$APACHE_PORTS"
if ! grep -q "Listen ${LISTEN_HTTP_PORT}" "$APACHE_PORTS"; then
  echo "Listen ${LISTEN_HTTP_PORT}" >> "$APACHE_PORTS"
fi

# Enable required modules and site
a2enmod php* >/dev/null 2>&1 || true
a2enmod headers >/dev/null 2>&1 || true
[[ -n "$AUTO_INDEX_ON" ]] && a2enmod autoindex >/dev/null 2>&1 || a2dismod autoindex >/dev/null 2>&1 || true

a2dissite 000-default >/dev/null 2>&1 || true
a2ensite "${SITE_NAME}" >/dev/null

chown -R www-data:www-data "${SITE_DIR}"
chmod -R 0755 "${SITE_DIR}"

systemd_enable_restart apache2

### --------------------------
### Environment hints for PHP app
### --------------------------
echo "[*] Writing app env hints..."
APP_ENV_FILE="${SITE_DIR}/.env.sample"
cat > "$APP_ENV_FILE" <<EOF
# Copy to .env and adjust as needed. Apache doesn't read this automatically;
# it's here as teaching material.
DB_HOST=127.0.0.1
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
TARGET_MODE=${MODE}
EOF

# Export basic env for Apache via systemd drop-in (teaching-friendly)
APACHE_ENV_DIR="/etc/systemd/system/apache2.service.d"
mkdir -p "$APACHE_ENV_DIR"
cat > "${APACHE_ENV_DIR}/env.conf" <<EOF
[Service]
Environment=DB_HOST=127.0.0.1
Environment=DB_NAME=${DB_NAME}
Environment=DB_USER=${DB_USER}
Environment=DB_PASS=${DB_PASS}
Environment=TARGET_MODE=${MODE}
EOF

systemctl daemon-reload
systemctl restart apache2

### --------------------------
### Optional: very light iptables guidance (commented out)
### --------------------------
IPT_HINT="/root/iptables.example.sh"
cat > "$IPT_HINT" <<'BASH'
#!/usr/bin/env bash
# Example only. Review before using!
# iptables -F
# iptables -P INPUT DROP
# iptables -P FORWARD DROP
# iptables -P OUTPUT ACCEPT
# iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# iptables -A INPUT -i lo -j ACCEPT
# iptables -A INPUT -p tcp --dport 80 -j ACCEPT
# iptables -A INPUT -p tcp --dport 3306 -s 10.0.0.0/8 -j ACCEPT   # tighten as needed
# iptables -A INPUT -p icmp -j ACCEPT
BASH
chmod +x "$IPT_HINT"

### --------------------------
### Health checks + summary
### --------------------------
echo "[*] Verifying services..."
systemctl is-active --quiet apache2 && echo "Apache: active" || (echo "Apache NOT active"; exit 1)
systemctl is-active --quiet mariadb && echo "MariaDB: active" || (echo "MariaDB NOT active"; exit 1)

echo
echo "========== TARGET SETUP COMPLETE =========="
echo "Mode:            ${MODE}"
echo "Web root:        ${SITE_DIR}"
echo "Site URL:        http://$(hostname -I | awk '{print $1}'):${LISTEN_HTTP_PORT}/"
echo "Sample app:      /app/login.php  and  /app/search.php"
[[ -n "$PHP_INFO_PAGE_ON" ]] && echo "phpinfo():       /phpinfo.php  (remove in hardening)"
echo
echo "Database:        ${DB_NAME}"
echo "DB user/pass:    ${DB_USER} / ${DB_PASS}"
echo "DB host:         $( [[ -n "$DB_BIND_ALL" ]] && echo '0.0.0.0 (remote allowed)' || echo '127.0.0.1 (local only)' )"
echo
echo "Next steps for students (hardening ideas):"
echo "  - Remove phpinfo, disable ServerTokens/Signature, scrub X-Powered-By."
echo "  - Replace string-concat SQL with prepared statements."
echo "  - Lock MariaDB to 127.0.0.1, rotate DB creds, enforce least privilege."
echo "  - Tighten file perms, disable directory indexing, add security headers."
echo "  - Add firewall rules (see ${IPT_HINT})."
echo "==========================================="
