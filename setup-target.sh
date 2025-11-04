#!/usr/bin/env bash
# setup-target.sh
# MACCDC Target Installer (Kali) - nginx + php-fpm + MariaDB
# Modes: --vuln (default) = intentionally weak for student hardening exercises
#        --harden        = safer baseline (removes phpinfo, disables autoindex, binds DB to localhost)
#
# Save as setup-target.sh, make executable (chmod +x), run with sudo:
#   sudo ./setup-target.sh --vuln
#   sudo ./setup-target.sh --harden
set -euo pipefail

### --------------------------
### Configurable defaults (override via env)
### --------------------------
MODE="${MODE:-vuln}"                # vuln | harden
SITE_NAME="${SITE_NAME:-target}"
SITE_DIR="${SITE_DIR:-/var/www/${SITE_NAME}}"
DB_NAME="${DB_NAME:-scoredb}"
DB_USER="${DB_USER:-webapp}"
DB_PASS="${DB_PASS:-password}"
LISTEN_PORT="${LISTEN_PORT:-80}"
PHP_VERSION="${PHP_VERSION:-8.4}"   # change only if your repo lacks 8.4

### --------------------------
### Parse CLI flags
### --------------------------
usage() {
  cat <<EOF
Usage: sudo ./setup-target.sh [--vuln | --harden]
Defaults: --vuln
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

echo "[*] Running target setup (mode=${MODE})"

# Derived toggles
if [[ "${MODE}" == "vuln" ]]; then
  AUTOINDEX="on"
  PHPINFO_ON="yes"
  DB_BIND_ALL="yes"
else
  AUTOINDEX="off"
  PHPINFO_ON=""
  DB_BIND_ALL=""
fi

### --------------------------
### Helpers
### --------------------------
apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends "$@"
}

file_backup() {
  local f="$1"
  if [[ -f "$f" && ! -f "${f}.bak" ]]; then
    cp -a "$f" "${f}.bak"
  fi
}

systemctl_enable_restart_ifexists() {
  local svc="$1"
  # enable/start only if unit is available
  if systemctl list-unit-files --type=service | awk '{print $1}' | grep -qx "${svc}.service"; then
    systemctl enable --now "${svc}.service" || true
    systemctl restart "${svc}.service" || true
  else
    # try without .service for compatibility
    if systemctl list-unit-files --type=service | awk '{print $1}' | grep -qx "${svc}"; then
      systemctl enable --now "${svc}" || true
      systemctl restart "${svc}" || true
    fi
  fi
}

### --------------------------
### Stop/disable Apache if present (avoid port conflict)
### --------------------------
if systemctl list-unit-files | grep -q '^apache2'; then
  echo "[*] Stopping & disabling apache2 to avoid conflicts (if present)"
  systemctl stop apache2 || true
  systemctl disable apache2 || true
fi

### --------------------------
### Install packages
### --------------------------
echo "[*] Installing nginx, php-fpm, php-mysql, mariadb..."
apt_install nginx "php${PHP_VERSION}-fpm" "php${PHP_VERSION}-mysql" mariadb-server curl

### --------------------------
### MariaDB configuration (bind)
### --------------------------
MYSQL_CONF="/etc/mysql/mariadb.conf.d/50-server.cnf"
file_backup "$MYSQL_CONF"

if [[ -n "${DB_BIND_ALL}" ]]; then
  sed -i 's/^\s*#\?\s*bind-address\s*=.*/bind-address = 0.0.0.0/' "$MYSQL_CONF" || true
  grep -q 'bind-address' "$MYSQL_CONF" || echo "bind-address = 0.0.0.0" >> "$MYSQL_CONF"
else
  sed -i 's/^\s*#\?\s*bind-address\s*=.*/bind-address = 127.0.0.1/' "$MYSQL_CONF" || true
  grep -q 'bind-address' "$MYSQL_CONF" || echo "bind-address = 127.0.0.1" >> "$MYSQL_CONF"
fi

systemctl_enable_restart_ifexists mariadb

### --------------------------
### Create DB, user, seed schema & flags (idempotent)
### --------------------------
echo "[*] Creating database and seeding sample data..."
mysql -u root <<SQL || true
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%' , '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

mysql -u root "${DB_NAME}" <<'SQL' || true
CREATE TABLE IF NOT EXISTS users (
  id INT AUTO_INCREMENT PRIMARY KEY,
  username VARCHAR(64) UNIQUE,
  password VARCHAR(128),
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
  (3,'web_misconfig','wvu6or7{nginx_fastcgi}');
SQL

### --------------------------
### Prepare web root (sample app intentionally weak in vuln mode)
### --------------------------
echo "[*] Preparing web root: ${SITE_DIR}"
mkdir -p "${SITE_DIR}/app"
chown -R www-data:www-data "${SITE_DIR}"
chmod -R 0755 "${SITE_DIR}"

cat > "${SITE_DIR}/index.php" <<'PHP'
<?php
$mode = getenv('TARGET_MODE') ?: 'vuln';
?>
<!doctype html><html><head><meta charset="utf-8"><title>MACCDC Target</title></head><body>
  <h1>MACCDC Target Host (nginx)</h1>
  <p>Mode: <?php echo htmlspecialchars($mode); ?></p>
  <ul>
    <li><a href="/app/login.php">Sample Login</a></li>
<?php if ($mode === 'vuln'): ?>
    <li><a href="/app/search.php">User Search (SQLi-prone)</a></li>
    <li><a href="/phpinfo.php">phpinfo()</a></li>
<?php endif; ?>
  </ul>
</body></html>
PHP

cat > "${SITE_DIR}/app/login.php" <<'PHP'
<?php
$mysqli = @new mysqli(getenv('DB_HOST') ?: '127.0.0.1', getenv('DB_USER') ?: 'webapp',
                      getenv('DB_PASS') ?: 'password', getenv('DB_NAME') ?: 'scoredb', 3306);
$err = $mysqli->connect_error ? "DB connect failed: ".$mysqli->connect_error : "";
$msg = "";
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
  $u = $_POST['username'] ?? '';
  $p = $_POST['password'] ?? '';
  # intentionally insecure query for exercise
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
$mysqli = @new mysqli(getenv('DB_HOST') ?: '127.0.0.1', getenv('DB_USER') ?: 'webapp',
                      getenv('DB_PASS') ?: 'password', getenv('DB_NAME') ?: 'scoredb', 3306);
$q = $_GET['q'] ?? '';
$rows = [];
$err = '';
if ($q !== '') {
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

# phpinfo (only in vuln mode)
if [[ -n "${PHPINFO_ON}" ]]; then
  cat > "${SITE_DIR}/phpinfo.php" <<'PHP'
<?php phpinfo();
PHP
else
  rm -f "${SITE_DIR}/phpinfo.php" || true
fi

# robots
cat > "${SITE_DIR}/robots.txt" <<'TXT'
User-agent: *
Disallow:
TXT

chown -R www-data:www-data "${SITE_DIR}"
chmod -R 0755 "${SITE_DIR}"

### --------------------------
### Detect php-fpm socket (robust)
### --------------------------
PHP_SOCK_CANDIDATES=(
  "/run/php/php${PHP_VERSION}-fpm.sock"
  "/run/php/php-fpm.sock"
  "/var/run/php/php${PHP_VERSION}-fpm.sock"
)
FASTCGI_PASS="127.0.0.1:9000"  # default fallback

for s in "${PHP_SOCK_CANDIDATES[@]}"; do
  if [[ -S "$s" ]]; then
    FASTCGI_PASS="unix:${s}"
    break
  fi
done

### --------------------------
### Create nginx site config (fixed autoindex handling)
### --------------------------
NGINX_CONF="/etc/nginx/sites-available/${SITE_NAME}"
file_backup "${NGINX_CONF}"

# Ensure a valid autoindex value
if [[ "${AUTOINDEX}" != "on" && "${AUTOINDEX}" != "off" ]]; then
  AUTOINDEX="off"
fi

cat > "${NGINX_CONF}" <<EOF
server {
    listen ${LISTEN_PORT} default_server;
    listen [::]:${LISTEN_PORT} default_server;

    server_name _;

    root ${SITE_DIR};
    index index.php index.html index.htm;

    access_log /var/log/nginx/${SITE_NAME}_access.log;
    error_log  /var/log/nginx/${SITE_NAME}_error.log;

    # Basic security headers - students should review and improve
    add_header X-Frame-Options "DENY";
    add_header X-Content-Type-Options "nosniff";
    add_header Referrer-Policy "no-referrer-when-downgrade";

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass ${FASTCGI_PASS};
    }

    location ~ /\. {
      deny all;
      access_log off;
      log_not_found off;
    }

    autoindex ${AUTOINDEX};
}
EOF

# Enable site
ln -sf "${NGINX_CONF}" "/etc/nginx/sites-enabled/${SITE_NAME}"
# Remove default to avoid conflicts
rm -f /etc/nginx/sites-enabled/default

### --------------------------
### .env.sample (teaching)
### --------------------------
cat > "${SITE_DIR}/.env.sample" <<EOF
DB_HOST=127.0.0.1
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
TARGET_MODE=${MODE}
EOF
chown www-data:www-data "${SITE_DIR}/.env.sample" || true

### --------------------------
### Start/enable php-fpm & nginx (robust)
### --------------------------
PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
# Prefer the exact versioned service; fall back to generic only if needed
if systemctl list-unit-files --type=service | awk '{print $1}' | grep -qx "${PHP_FPM_SERVICE}.service"; then
  systemctl_enable_restart_ifexists "${PHP_FPM_SERVICE}"
else
  systemctl_enable_restart_ifexists "php-fpm"
fi

# Ensure nginx starts
systemctl_enable_restart_ifexists nginx

### --------------------------
### Final checks & guidance
### --------------------------
echo
echo "==== TARGET SETUP COMPLETE ===="
echo "Mode:            ${MODE}"
echo "Web root:        ${SITE_DIR}"
echo "Site URL:        http://$(hostname -I | awk '{print $1}'):${LISTEN_PORT}/"
echo "DB:              ${DB_NAME}"
echo "DB user/pass:    ${DB_USER} / ${DB_PASS}"
echo "php-fpm fastcgi: ${FASTCGI_PASS}"
echo
echo "If nginx failed: run 'nginx -t' then 'journalctl -xeu nginx.service' to inspect details."
echo
echo "Teaching/hardening checklist:"
echo "  - Replace concatenated SQL with prepared statements (in app/*.php)."
echo "  - Remove phpinfo.php in hardened mode."
echo "  - Rotate DB credentials; restrict MariaDB to 127.0.0.1 (hardened mode does this)."
echo "  - Add stricter headers (CSP, HSTS), limit request sizes, tune fastcgi params."
echo "  - Add firewall rules to limit access to 3306 / 80 as appropriate."
echo "================================"