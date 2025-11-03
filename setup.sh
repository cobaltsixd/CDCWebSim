#!/usr/bin/env bash
# setup.sh - Kali VM installer/manager for MACCDC simulation (web + db) for CDCWebSim
#
# Usage (run as root/sudo):
#   sudo ./setup.sh install-all
#   sudo ./setup.sh start-db
#   sudo ./setup.sh start-web
#   sudo ./setup.sh start-everything
#   sudo ./setup.sh stop-all
#   sudo ./setup.sh status
#   sudo ./setup.sh help
#
# Idempotent-ish: safe to re-run. No GitHub credential prompts (HTTPS only; ZIP fallback).

set -euo pipefail

### === CONFIG (adjust if needed) ===
REPO_HTTPS="https://github.com/cobaltsixd/CDCWebSim.git"
BRANCH="${BRANCH:-main}"

APP_USER="ctfsvc"
APP_GROUP="ctfsvc"
APP_BASE="/opt/maccdc"             # repo root on disk
APP_DIR_CANDIDATES=("app" ".")     # auto-detect app dir: try 'app', then repo root
VENV_DIR_NAME="venv"
APP_PORT="${APP_PORT:-8000}"       # gunicorn binds here (localhost)
NGINX_SITE_NAME="maccdc"

# Database (override via env before running if you want fixed creds)
DB_NAME="${DB_NAME:-maccdc}"
DB_USER="${DB_USER:-maccdc}"
DB_PASS="${DB_PASS:-$(openssl rand -base64 20)}"
DB_HOST="localhost"
DB_PORT=5432

WEB_SERVICE="ctf-web.service"

export DEBIAN_FRONTEND=noninteractive
export GIT_TERMINAL_PROMPT=0

### === Helpers ===
log() { echo -e "\e[1;32m[setup]\e[0m $*"; }
info() { echo -e "\e[1;34m[info]\e[0m $*"; }
warn() { echo -e "\e[1;33m[warn]\e[0m $*"; }
err() { echo -e "\e[1;31m[error]\e[0m $*" >&2; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "Run as root (sudo)."; exit 2
  fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

ensure_user() {
  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    log "Creating system user: $APP_USER"
    useradd --system --create-home --home-dir "/home/$APP_USER" --shell /usr/sbin/nologin "$APP_USER"
  else
    log "User $APP_USER exists."
  fi
}

ensure_dirs() {
  mkdir -p "$APP_BASE"
  chown -R "$APP_USER":"$APP_GROUP" "$APP_BASE" || true
}

ensure_packages() {
  log "Updating apt metadata and installing dependencies..."
  apt-get update -y
  apt-get install -y \
    git curl rsync ca-certificates \
    build-essential python3 python3-venv python3-pip python3-dev pkg-config \
    nginx postgresql postgresql-contrib libpq-dev \
    openssl
  # Keep Python tooling fresh
  python3 -m pip install --upgrade pip setuptools wheel >/dev/null 2>&1 || true
}

# Auto-detect app dir (repo root vs ./app)
APP_PATH="" ; VENV_PATH=""
resolve_app_path() {
  for cand in "${APP_DIR_CANDIDATES[@]}"; do
    if [ "$cand" = "." ]; then
      local path="$APP_BASE"
    else
      local path="$APP_BASE/$cand"
    fi
    # Heuristics: has requirements.txt or a common entrypoint
    if [ -d "$path" ] && { [ -f "$path/requirements.txt" ] || [ -f "$path/manage.py" ] || [ -f "$path/wsgi.py" ] || [ -f "$path/app.py" ] || [ -f "$path/run.py" ]; }; then
      APP_PATH="$path"
      break
    fi
  done
  # fallback to repo root
  if [ -z "$APP_PATH" ]; then APP_PATH="$APP_BASE"; fi
  VENV_PATH="$APP_PATH/$VENV_DIR_NAME"
}

clone_or_update_repo() {
  local tar_url="https://github.com/cobaltsixd/CDCWebSim/archive/refs/heads/${BRANCH}.tar.gz"

  if [ ! -d "$APP_BASE/.git" ]; then
    log "Cloning public repo (no creds): $REPO_HTTPS -> $APP_BASE (branch $BRANCH)"
    rm -rf "$APP_BASE" && mkdir -p "$APP_BASE"
    if git clone --branch "$BRANCH" --depth 1 "$REPO_HTTPS" "$APP_BASE"; then
      :
    else
      warn "git clone failed; falling back to ZIP snapshot..."
      curl -L "$tar_url" | tar xz -C "$APP_BASE" --strip-components=1
    fi
  else
    log "Updating existing repo in $APP_BASE..."
    # force remote to HTTPS (avoid SSH)
    git -C "$APP_BASE" remote set-url origin "$REPO_HTTPS" || true
    if git -C "$APP_BASE" fetch --all --prune && git -C "$APP_BASE" reset --hard "origin/$BRANCH"; then
      :
    else
      warn "git fetch/reset failed; refreshing from ZIP snapshot..."
      local tmpdir; tmpdir="$(mktemp -d)"
      curl -L "$tar_url" | tar xz -C "$tmpdir"
      rsync -a --delete "$tmpdir"/CDCWebSim-*"/" "$APP_BASE"/
      rm -rf "$tmpdir"
    fi
  fi

  chown -R "$APP_USER":"$APP_GROUP" "$APP_BASE"
}

create_python_venv() {
  resolve_app_path
  if [ ! -d "$VENV_PATH" ]; then
    log "Creating Python venv at $VENV_PATH"
    python3 -m venv "$VENV_PATH"
    "$VENV_PATH/bin/pip" install --upgrade pip
  else
    log "Python venv exists at $VENV_PATH"
  fi

  if [ -f "$APP_PATH/requirements.txt" ]; then
    log "Installing Python requirements..."
    sudo -u "$APP_USER" bash -lc "source '$VENV_PATH/bin/activate' && pip install -r '$APP_PATH/requirements.txt'"
  else
    warn "No requirements.txt at $APP_PATH/requirements.txt — skipping pip install."
  fi
}

setup_postgres() {
  log "Ensuring PostgreSQL is enabled and running..."
  systemctl enable --now postgresql

  sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1 || {
    log "Creating PostgreSQL role ${DB_USER}"
    sudo -u postgres psql -c "CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASS}';"
  }

  sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 || {
    log "Creating PostgreSQL database ${DB_NAME} (owner ${DB_USER})"
    sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"
  }
}

write_env_file() {
  resolve_app_path
  local envfile="$APP_PATH/.env"
  log "Writing app environment file: $envfile"
  cat > "$envfile" <<EOF
# Generated by setup.sh
DATABASE_URL=postgresql://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}
APP_PORT=${APP_PORT}
SECRET_KEY=${SECRET_KEY:-$(openssl rand -hex 32)}
ENV=production
EOF
  chown "$APP_USER":"$APP_GROUP" "$envfile"
  chmod 640 "$envfile"
}

detect_app_type() {
  resolve_app_path
  if [ -f "$APP_PATH/manage.py" ]; then
    echo "django"
  elif [ -f "$APP_PATH/wsgi.py" ] || [ -f "$APP_PATH/app.py" ] || [ -f "$APP_PATH/run.py" ]; then
    echo "wsgi"
  else
    echo "unknown"
  fi
}

write_systemd_web_unit() {
  resolve_app_path
  local unit="/etc/systemd/system/$WEB_SERVICE"
  local wsgi_module="wsgi:app"  # default guess
  local app_type; app_type="$(detect_app_type)"

  if [ "$app_type" = "django" ]; then
    local projdir
    projdir="$(find "$APP_PATH" -maxdepth 2 -type f -name 'wsgi.py' -printf '%h\n' | head -n1 || true)"
    if [ -n "${projdir:-}" ]; then
      local rel="${projdir#"$APP_PATH/"}"; rel="${rel//\//.}"
      wsgi_module="${rel}.wsgi:application"
    else
      wsgi_module="wsgi:application"
    fi
  else
    if   [ -f "$APP_PATH/wsgi.py" ]; then wsgi_module="wsgi:app"
    elif [ -f "$APP_PATH/app.py"  ]; then wsgi_module="app:app"
    elif [ -f "$APP_PATH/run.py"  ]; then wsgi_module="run:app"
    fi
  fi

  log "Creating systemd unit for web (module: $wsgi_module)"
  cat > "$unit" <<EOF
[Unit]
Description=CDCWebSim web service (gunicorn)
After=network.target postgresql.service
Wants=postgresql.service

[Service]
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${APP_PATH}
EnvironmentFile=${APP_PATH}/.env
ExecStart=${VENV_PATH}/bin/gunicorn --workers 3 --bind 127.0.0.1:${APP_PORT} ${wsgi_module}
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$WEB_SERVICE"
  chown root:root "$unit"
  chmod 644 "$unit"
}

write_nginx_site() {
  local site="/etc/nginx/sites-available/${NGINX_SITE_NAME}"
  local link="/etc/nginx/sites-enabled/${NGINX_SITE_NAME}"

  log "Writing nginx reverse proxy config -> $site"
  cat > "$site" <<EOF
server {
    listen 80;
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
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl restart nginx
}

run_app_db_setup() {
  resolve_app_path
  local app_type; app_type="$(detect_app_type)"
  log "DB setup for app type: $app_type"

  if [ "$app_type" = "django" ]; then
    log "Running Django migrations (and collectstatic when applicable)..."
    sudo -u "$APP_USER" bash -lc "source '$VENV_PATH/bin/activate' && cd '$APP_PATH' && python manage.py migrate --noinput"
    if grep -Rqi "STATIC_ROOT" "$APP_PATH" 2>/dev/null; then
      sudo -u "$APP_USER" bash -lc "source '$VENV_PATH/bin/activate' && cd '$APP_PATH' && python manage.py collectstatic --noinput" || true
    fi
  else
    # Convention: if your repo has scripts/db_setup.sh or db_init.sh, run it
    if [ -x "$APP_PATH/scripts/db_setup.sh" ]; then
      sudo -u "$APP_USER" bash -lc "cd '$APP_PATH' && scripts/db_setup.sh"
    elif [ -x "$APP_PATH/db_init.sh" ]; then
      sudo -u "$APP_USER" bash -lc "cd '$APP_PATH' && ./db_init.sh"
    else
      info "No app-specific DB setup script found. Skipping."
    fi
  fi
}

print_summary() {
  resolve_app_path
  cat <<EOF

========== CDCWebSim setup summary ==========
Repo path:      $APP_BASE
App path:       $APP_PATH
Python venv:    $VENV_PATH
Web service:    $WEB_SERVICE (gunicorn -> 127.0.0.1:${APP_PORT})
Nginx site:     ${NGINX_SITE_NAME} (reverse proxy on :80)

Database:
  name:         ${DB_NAME}
  user:         ${DB_USER}
  pass:         ${DB_PASS}
  host:         ${DB_HOST}
  port:         ${DB_PORT}

Useful commands:
  sudo ./setup.sh status
  sudo ./setup.sh start-web
  sudo ./setup.sh stop-all
Logs:
  journalctl -u ${WEB_SERVICE} -f
  tail -f /var/log/nginx/${NGINX_SITE_NAME}.error.log
=============================================
EOF
}

# ---- Public subcommands ----
do_install_all() {
  require_root
  ensure_user
  ensure_dirs
  ensure_packages
  clone_or_update_repo
  create_python_venv
  setup_postgres
  write_env_file
  write_systemd_web_unit
  write_nginx_site
  print_summary
  info "install-all complete. Next: sudo ./setup.sh start-everything"
}

do_start_db() {
  require_root
  systemctl enable --now postgresql
  clone_or_update_repo
  create_python_venv
  write_env_file
  run_app_db_setup
  info "DB setup complete."
}

do_start_web() {
  require_root
  clone_or_update_repo
  create_python_venv
  write_env_file
  systemctl daemon-reload
  systemctl restart "$WEB_SERVICE"
  systemctl restart nginx
  info "Web started."
}

do_start_everything() {
  require_root
  do_install_all
  do_start_db
  do_start_web
  info "Everything started."
}

do_stop_all() {
  require_root
  systemctl stop "$WEB_SERVICE" || true
  systemctl stop nginx || true
  info "Stopped web and nginx (postgres kept running)."
}

do_status() {
  resolve_app_path
  echo "----- ${WEB_SERVICE} -----"
  systemctl status "$WEB_SERVICE" --no-pager || true
  echo "----- nginx -----"
  systemctl status nginx --no-pager || true
  echo "----- postgresql -----"
  systemctl status postgresql --no-pager || true
  echo "----- recent web logs -----"
  journalctl -u "$WEB_SERVICE" -n 40 --no-pager || true
  echo "----- nginx error (tail) -----"
  tail -n 40 "/var/log/nginx/${NGINX_SITE_NAME}.error.log" 2>/dev/null || true
}

show_help() {
  sed -n '1,60p' "$0" | sed 's/^# \{0,1\}//' | sed '/^set -euo pipefail/,$d'
  cat <<'EOF'

Environment overrides:
  BRANCH, APP_PORT, DB_NAME, DB_USER, DB_PASS

Examples:
  sudo DB_PASS="classroom!" ./setup.sh install-all
  sudo ./setup.sh start-everything
  sudo ./setup.sh status

EOF
}

# ---- Main ----
case "${1:-help}" in
  install-all)        do_install_all ;;
  start-db)           do_start_db ;;
  start-web)          do_start_web ;;
  start-everything)   do_start_everything ;;
  stop-all)           do_stop_all ;;
  status)             do_status ;;
  help|--help|-h)     show_help ;;
  *) err "Unknown command: $1"; show_help; exit 2 ;;
esac
