#!/usr/bin/env bash
# setup-attacker.sh - All-in-one setup for CDCWebSim ATTACKER on Kali
# DB is DISABLED by default (tooling/UX role); different ports

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export GIT_TERMINAL_PROMPT=0
APT_RETRIES="-o Acquire::Retries=5"
APT_FIX="--fix-missing"

ROLE="attacker"
SERVICE="ctf-attacker.service"
REPO_HTTPS="${REPO_HTTPS:-https://github.com/cobaltsixd/CDCWebSim.git}"
BRANCH="${BRANCH:-main}"
APP_USER="${APP_USER:-ctfsvc}"
APP_GROUP="${APP_GROUP:-ctfsvc}"

detect_app_base(){ if [ -d ".git" ]||[ -f "requirements.txt" ]||[ -f "manage.py" ]||[ -f "wsgi.py" ]||[ -f "app.py" ]; then pwd; else echo "/opt/maccdc/${ROLE}"; fi; }
APP_BASE="${APP_BASE:-$(detect_app_base)}"
APP_DIR_CANDIDATES=("${APP_SUBDIR:-app}" ".")
VENV_DIR_NAME="venv"

APP_PORT="${APP_PORT:-8003}"
NGINX_PORT="${NGINX_PORT:-8083}"
NGINX_SITE_NAME="maccdc-${ROLE}"

DB_ENABLED="${DB_ENABLED:-false}"
DB_NAME="${DB_NAME:-maccdc_${ROLE}}"
DB_USER="${DB_USER:-maccdc_${ROLE}}"
DB_PASS="${DB_PASS:-$(openssl rand -base64 20)}"
DB_HOST="localhost"; DB_PORT=5432

log(){ echo -e "\e[1;32m[${ROLE}]\e[0m $*"; }
warn(){ echo -e "\e[1;33m[${ROLE}]\e[0m $*"; }
err(){ echo -e "\e[1;31m[${ROLE}]\e[0m $*" >&2; }
require_root(){ [ "$(id -u)" -eq 0 ] || { err "Run with sudo/root."; exit 2; }; }

fix_kali_sources_and_key(){
  log "Repairing apt trust/time/sources…"
  timedatectl set-ntp true || true
  systemctl restart systemd-timesyncd || true
  sleep 2
  apt-get update -y $APT_RETRIES $APT_FIX || true
  apt-get install -y ca-certificates curl gnupg $APT_RETRIES $APT_FIX || true
  mkdir -p /usr/share/keyrings /etc/apt/keyrings /root/.gnupg
  chmod 700 /root/.gnupg || true
  [ -s /usr/share/keyrings/kali-archive-keyring.gpg ] || \
    curl -fsSL https://archive.kali.org/archive-key.asc | gpg --dearmor >/usr/share/keyrings/kali-archive-keyring.gpg || true
  curl -fsSL https://archive.kali.org/archive-key.asc | apt-key add - || true
  cat >/etc/apt/sources.list <<'EOF'
deb [signed-by=/usr/share/keyrings/kali-archive-keyring.gpg] http://http.kali.org/kali kali-rolling main non-free non-free-firmware contrib
EOF
  rm -rf /var/lib/apt/lists/* /var/cache/apt/pkgcache.bin /var/cache/apt/srcpkgcache.bin
  apt-get -o Acquire::Check-Valid-Until=false update --allow-releaseinfo-change -y $APT_RETRIES || true
}
apt_install_safe(){
  apt-get update -y $APT_RETRIES $APT_FIX || true
  if ! apt-get install -y "$@" $APT_RETRIES $APT_FIX; then
    warn "apt install failed; cleaning and retrying…"
    apt-get clean
    rm -rf /var/lib/apt/lists/*
    apt-get -o Acquire::Check-Valid-Until=false update --allow-releaseinfo-change -y $APT_RETRIES $APT_FIX || true
    apt-get install -y "$@" $APT_RETRIES $APT_FIX
  fi
}

ensure_user(){ id -u "$APP_USER" >/dev/null 2>&1 || useradd --system -m -d "/home/$APP_USER" -s /usr/sbin/nologin "$APP_USER"; }
ensure_dirs(){ mkdir -p "$APP_BASE"; chown -R "$APP_USER:$APP_GROUP" "$APP_BASE" || true; }
ensure_packages(){
  fix_kali_sources_and_key
  apt_install_safe git curl rsync build-essential python3 python3-venv python3-pip python3-dev pkg-config nginx openssl
  # DB disabled by default; install Postgres only if explicitly enabled
  if [ "${DB_ENABLED}" = "true" ]; then apt_install_safe postgresql postgresql-contrib libpq-dev libssl-dev; fi
  # Attacker quality-of-life (optional): common tools — uncomment if you want automatic install
  # apt_install_safe nmap gobuster sqlmap wfuzz hydra john seclists
  python3 -m pip install --upgrade pip setuptools wheel >/dev/null 2>&1 || true
}

APP_PATH=""; VENV_PATH=""
resolve_app_path(){
  for cand in "${APP_DIR_CANDIDATES[@]}"; do
    local p; [ "$cand" = "." ] && p="$APP_BASE" || p="$APP_BASE/$cand"
    if [ -d "$p" ] && { [ -f "$p/requirements.txt" ] || [ -f "$p/manage.py" ] || [ -f "$p/wsgi.py" ] || [ -f "$p/app.py" ] || [ -f "$p/run.py" ]; }; then APP_PATH="$p"; break; fi
  done
  [ -n "$APP_PATH" ] || APP_PATH="$APP_BASE"
  VENV_PATH="$APP_PATH/$VENV_DIR_NAME"
}

clone_or_update(){
  local tar_url="https://github.com/cobaltsixd/CDCWebSim/archive/refs/heads/${BRANCH}.tar.gz"
  if [ ! -d "$APP_BASE/.git" ]; then
    log "Cloning repo → $APP_BASE (branch $BRANCH)"
    rm -rf "$APP_BASE" && mkdir -p "$APP_BASE"
    if ! git clone --branch "$BRANCH" --depth 1 "$REPO_HTTPS" "$APP_BASE"; then
      warn "git clone failed; using ZIP snapshot…"
      curl -L "$tar_url" | tar xz -C "$APP_BASE" --strip-components=1
    fi
  else
    log "Updating existing repo…"
    git -C "$APP_BASE" remote set-url origin "$REPO_HTTPS" || true
    if ! (git -C "$APP_BASE" fetch --all --prune && git -C "$APP_BASE" reset --hard "origin/$BRANCH"); then
      warn "git pull failed; refreshing from ZIP…"
      local t; t="$(mktemp -d)"; curl -L "$tar_url" | tar xz -C "$t"
      rsync -a --delete "$t"/CDCWebSim-*"/" "$APP_BASE"/; rm -rf "$t"
    fi
  fi
  chown -R "$APP_USER:$APP_GROUP" "$APP_BASE"
}

create_venv(){
  resolve_app_path
  [ -d "$VENV_PATH" ] || { log "Creating venv at $VENV_PATH"; python3 -m venv "$VENV_PATH"; "$VENV_PATH/bin/pip" install --upgrade pip; }
  if [ -f "$APP_PATH/requirements.txt" ]; then
    log "Installing requirements…"
    sudo -u "$APP_USER" bash -lc "source '$VENV_PATH/bin/activate' && pip install -r '$APP_PATH/requirements.txt'"
  fi
  if ! sudo -u "$APP_USER" bash -lc "source '$VENV_PATH/bin/activate' && python -c 'import gunicorn' 2>/dev/null"; then
    sudo -u "$APP_USER" bash -lc "source '$VENV_PATH/bin/activate' && pip install gunicorn"
  fi
}

setup_postgres(){
  [ "${DB_ENABLED}" = "true" ] || return 0
  systemctl enable --now postgresql
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1 || sudo -u postgres psql -c "CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASS}';"
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 || sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"
}

write_env(){
  resolve_app_path
  cat >"$APP_PATH/.env" <<EOF
DATABASE_URL=$( [ "${DB_ENABLED}" = "true" ] && echo "postgresql://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}" || echo "" )
APP_PORT=${APP_PORT}
SECRET_KEY=${SECRET_KEY:-$(openssl rand -hex 32)}
ENV=production
ROLE=${ROLE}
EOF
  chown "$APP_USER:$APP_GROUP" "$APP_PATH/.env"; chmod 640 "$APP_PATH/.env"
}

detect_app_type(){
  resolve_app_path
  if   [ -f "$APP_PATH/manage.py" ]; then echo django
  elif [ -f "$APP_PATH/wsgi.py" ] || [ -f "$APP_PATH/app.py" ] || [ -f "$APP_PATH/run.py" ]; then echo wsgi
  else echo unknown; fi
}

write_systemd(){
  resolve_app_path
  local unit="/etc/systemd/system/${SERVICE}"
  local module="wsgi:app"; local t; t="$(detect_app_type)"
  if [ "$t" = "django" ]; then
    local d; d="$(find "$APP_PATH" -maxdepth 2 -type f -name wsgi.py -printf '%h\n' | head -n1 || true)"
    if [ -n "$d" ]; then local rel="${d#"$APP_PATH/"}"; rel="${rel//\//.}"; module="${rel}.wsgi:application"; else module="wsgi:application"; fi
  else
    [ -f "$APP_PATH/wsgi.py" ] && module="wsgi:app"
    [ -f "$APP_PATH/app.py"  ] && module="app:app"
    [ -f "$APP_PATH/run.py"  ] && module="run:app"
  fi
  cat >"$unit" <<EOF
[Unit]
Description=CDCWebSim ${ROLE} (gunicorn)
After=network.target $( [ "${DB_ENABLED}" = "true" ] && echo postgresql.service )
Wants=$( [ "${DB_ENABLED}" = "true" ] && echo postgresql.service )

[Service]
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${APP_PATH}
EnvironmentFile=${APP_PATH}/.env
ExecStart=${VENV_PATH}/bin/gunicorn --workers 3 --bind 127.0.0.1:${APP_PORT} ${module}
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE"
}

write_nginx(){
  local site="/etc/nginx/sites-available/${NGINX_SITE_NAME}"
  local link="/etc/nginx/sites-enabled/${NGINX_SITE_NAME}"
  cat >"$site" <<EOF
server {
    listen ${NGINX_PORT};
    server_name _;

    access_log /var/log/nginx/${NGINX_SITE_NAME}.access.log;
    error_log  /var/log/nginx/${NGINX_SITE_NAME}.error.log;

    location / {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_redirect off;
    }
}
EOF
  ln -sf "$site" "$link"
  nginx -t
  systemctl restart nginx
}

run_db_setup(){
  [ "${DB_ENABLED}" = "true" ] || return 0
  local t; t="$(detect_app_type)"
  if [ "$t" = "django" ]; then
    sudo -u "$APP_USER" bash -lc "source '$VENV_PATH/bin/activate' && cd '$APP_PATH' && python manage.py migrate --noinput"
    grep -Rqi "STATIC_ROOT" "$APP_PATH" 2>/dev/null && sudo -u "$APP_USER" bash -lc "source '$VENV_PATH/bin/activate' && cd '$APP_PATH' && python manage.py collectstatic --noinput" || true
  elif [ -x "$APP_PATH/scripts/db_setup.sh" ]; then
    sudo -u "$APP_USER" bash -lc "cd '$APP_PATH' && scripts/db_setup.sh"
  elif [ -x "$APP_PATH/db_init.sh" ]; then
    sudo -u "$APP_USER" bash -lc "cd '$APP_PATH' && ./db_init.sh"
  fi
}

summary(){
  cat <<EOF

== ${ROLE} ready ==
App:        $APP_PATH
Venv:       $VENV_PATH
Service:    $SERVICE  (gunicorn -> 127.0.0.1:${APP_PORT})
Nginx:      ${NGINX_SITE_NAME} (listen ${NGINX_PORT} → app)
Visit:      http://<vm-ip>:${NGINX_PORT}

DB:         ${DB_ENABLED}

EOF
}

install_all(){ require_root; ensure_user; ensure_dirs; ensure_packages; clone_or_update; create_venv; setup_postgres; write_env; write_systemd; write_nginx; summary; log "install-all complete."; }
start_db(){ require_root; [ "${DB_ENABLED}" = "true" ] || { log "DB disabled for ${ROLE}"; return 0; }; systemctl enable --now postgresql; clone_or_update; create_venv; write_env; run_db_setup; log "DB setup complete."; }
start_web(){ require_root; clone_or_update; create_venv; write_env; systemctl daemon-reload; systemctl restart "$SERVICE"; systemctl restart nginx; log "Web started."; }
start_everything(){ install_all; start_db; start_web; log "Everything started."; }
stop_all(){ require_root; systemctl stop "$SERVICE" || true; log "Stopped ${SERVICE}."; }
status(){ systemctl status "$SERVICE" --no-pager || true; echo "----- nginx -----"; systemctl status nginx --no-pager || true; echo "----- logs -----"; journalctl -u "$SERVICE" -n 40 --no-pager || true; }

case "${1:-help}" in
  install-all) install_all ;;
  start-db) start_db ;;
  start-web) start_web ;;
  start-everything) start_everything ;;
  stop-all) stop_all ;;
  status) status ;;
  *) echo "Usage: sudo ./setup-${ROLE}.sh {install-all|start-db|start-web|start-everything|stop-all|status}"; exit 2 ;;
esac
