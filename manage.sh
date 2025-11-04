#!/usr/bin/env bash
# manage.sh - Orchestrator for CDCWebSim role setups on Kali
# Drives: setup-scoreboard.sh, setup-target.sh, setup-attacker.sh

set -euo pipefail

# --- Settings you can override via env if needed ---
APP_BASE_DEFAULT="$(pwd)"   # repo root by default
SCOREBOARD_SCRIPT="${SCOREBOARD_SCRIPT:-./setup-scoreboard.sh}"
TARGET_SCRIPT="${TARGET_SCRIPT:-./setup-target.sh}"
ATTACKER_SCRIPT="${ATTACKER_SCRIPT:-./setup-attacker.sh}"

# Optional per-role subdirs (if your code for each role lives in subfolders)
SCOREBOARD_SUBDIR="${SCOREBOARD_SUBDIR:-}"
TARGET_SUBDIR="${TARGET_SUBDIR:-}"
ATTACKER_SUBDIR="${ATTACKER_SUBDIR:-}"

is_root(){ [ "$(id -u)" -eq 0 ]; }

need_scripts(){
  local missing=0
  for f in "$SCOREBOARD_SCRIPT" "$TARGET_SCRIPT" "$ATTACKER_SCRIPT"; do
    if [ ! -f "$f" ]; then
      echo "[manage] missing: $f" >&2
      missing=1
    fi
  done
  [ "$missing" -eq 0 ]
}

make_exec(){
  chmod +x "$SCOREBOARD_SCRIPT" "$TARGET_SCRIPT" "$ATTACKER_SCRIPT" 2>/dev/null || true
}

run_role(){
  # $1 = role name (scoreboard|target|attacker)
  # $2 = command for the role script (install-all|start-everything|start-web|start-db|stop-all|status)
  # $3 = optional APP_SUBDIR
  local role="$1" cmd="$2" subdir="${3:-}"
  local script
  case "$role" in
    scoreboard) script="$SCOREBOARD_SCRIPT" ;;
    target)     script="$TARGET_SCRIPT" ;;
    attacker)   script="$ATTACKER_SCRIPT" ;;
    *) echo "[manage] unknown role: $role" >&2; exit 2 ;;
  esac

  local APP_BASE="${APP_BASE:-$APP_BASE_DEFAULT}"
  # If a role-specific subdir is set, pass it along
  if [ -n "$subdir" ]; then
    APP_SUBDIR="$subdir" APP_BASE="$APP_BASE" "$script" "$cmd"
  else
    APP_BASE="$APP_BASE" "$script" "$cmd"
  fi
}

usage(){
cat <<'EOF'
Usage:
  sudo ./manage.sh install-all           # install scoreboard + target + attacker
  sudo ./manage.sh start-everything      # install-all + start all services
  sudo ./manage.sh start-all             # start all services (no install)
  sudo ./manage.sh stop-all              # stop all role services
  sudo ./manage.sh status-all            # status for all role services

Per-role:
  sudo ./manage.sh scoreboard install
  sudo ./manage.sh scoreboard start
  sudo ./manage.sh scoreboard stop
  sudo ./manage.sh scoreboard status

  sudo ./manage.sh target install|start|stop|status
  sudo ./manage.sh attacker install|start|stop|status

Env overrides:
  APP_BASE=/path/to/repo/root
  SCOREBOARD_SUBDIR=scoreboard  TARGET_SUBDIR=target  ATTACKER_SUBDIR=attacker
  SCOREBOARD_SCRIPT=./custom-scoreboard.sh (and similarly for others)

EOF
}

main(){
  if ! is_root; then echo "[manage] please run with sudo/root"; exit 2; fi
  if ! need_scripts; then
    echo "[manage] expected setup scripts not found at:"
    echo "  $SCOREBOARD_SCRIPT"
    echo "  $TARGET_SCRIPT"
    echo "  $ATTACKER_SCRIPT"
    exit 2
  fi
  make_exec

  local cmd="${1:-help}"
  case "$cmd" in
    install-all)
      run_role scoreboard install-all "$SCOREBOARD_SUBDIR"
      run_role target     install-all "$TARGET_SUBDIR"
      run_role attacker   install-all "$ATTACKER_SUBDIR"
      ;;
    start-everything)
      # Full bootstrap, then start
      "$0" install-all
      "$0" start-all
      ;;
    start-all)
      run_role scoreboard start-web "$SCOREBOARD_SUBDIR"
      run_role target     start-web "$TARGET_SUBDIR"
      run_role attacker   start-web "$ATTACKER_SUBDIR"
      ;;
    stop-all)
      run_role scoreboard stop-all "$SCOREBOARD_SUBDIR"
      run_role target     stop-all "$TARGET_SUBDIR"
      run_role attacker   stop-all "$ATTACKER_SUBDIR"
      ;;
    status-all)
      echo "----- SCOREBOARD -----"; run_role scoreboard status "$SCOREBOARD_SUBDIR" || true
      echo "----- TARGET -----";     run_role target     status "$TARGET_SUBDIR"   || true
      echo "----- ATTACKER -----";   run_role attacker   status "$ATTACKER_SUBDIR" || true
      ;;
    scoreboard|target|attacker)
      case "${2:-}" in
        install) run_role "$cmd" install-all "$( [ "$cmd" = scoreboard ] && echo "$SCOREBOARD_SUBDIR" || [ "$cmd" = target ] && echo "$TARGET_SUBDIR" || echo "$ATTACKER_SUBDIR")" ;;
        start)   run_role "$cmd" start-web    "$( [ "$cmd" = scoreboard ] && echo "$SCOREBOARD_SUBDIR" || [ "$cmd" = target ] && echo "$TARGET_SUBDIR" || echo "$ATTACKER_SUBDIR")" ;;
        stop)    run_role "$cmd" stop-all     "$( [ "$cmd" = scoreboard ] && echo "$SCOREBOARD_SUBDIR" || [ "$cmd" = target ] && echo "$TARGET_SUBDIR" || echo "$ATTACKER_SUBDIR")" ;;
        status)  run_role "$cmd" status       "$( [ "$cmd" = scoreboard ] && echo "$SCOREBOARD_SUBDIR" || [ "$cmd" = target ] && echo "$TARGET_SUBDIR" || echo "$ATTACKER_SUBDIR")" ;;
        *) usage; exit 2 ;;
      esac
      ;;
    help|--help|-h|"")
      usage
      ;;
    *)
      usage; exit 2 ;;
  esac
}

main "$@"
