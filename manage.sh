#!/usr/bin/env bash
# manage.sh — Orchestrator for CDCWebSim role setups on Kali
# - Resolves setup scripts relative to this file's directory (SCRIPT_DIR)
# - Provides: install-all, start-everything, start-all, stop-all, status-all
# - Per-role commands: scoreboard|target|attacker with install|start|stop|status
set -euo pipefail

# --- Resolve this script's directory so it reliably finds the setup wrappers ---
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# --- Base install root (override with environment) ---
BASE_ROOT="${BASE_ROOT:-/opt/maccdc}"

# --- Setup script paths (anchored to SCRIPT_DIR so cwd doesn't matter) ---
SCOREBOARD_SCRIPT="${SCOREBOARD_SCRIPT:-${SCRIPT_DIR}/setup-scoreboard.sh}"
TARGET_SCRIPT="${TARGET_SCRIPT:-${SCRIPT_DIR}/setup-target.sh}"
ATTACKER_SCRIPT="${ATTACKER_SCRIPT:-${SCRIPT_DIR}/setup-attacker.sh}"

# --- Default role base installation directories (override with env if needed) ---
SCOREBOARD_BASE="${SCOREBOARD_BASE:-$BASE_ROOT/scoreboard}"
TARGET_BASE="${TARGET_BASE:-$BASE_ROOT/target}"
ATTACKER_BASE="${ATTACKER_BASE:-$BASE_ROOT/attacker}"

# Optional subdir inside the repo if your app lives under a subfolder (e.g., "app")
SCOREBOARD_SUBDIR="${SCOREBOARD_SUBDIR:-}"
TARGET_SUBDIR="${TARGET_SUBDIR:-}"
ATTACKER_SUBDIR="${ATTACKER_SUBDIR:-}"

# --- Helpers ---
is_root() { [ "$(id -u)" -eq 0 ]; }

need_scripts() {
  local ok=1
  for f in "$SCOREBOARD_SCRIPT" "$TARGET_SCRIPT" "$ATTACKER_SCRIPT"; do
    if [ ! -f "$f" ]; then
      echo "[manage] missing: $f" >&2
      ok=0
    fi
  done
  return $ok
}

make_exec() {
  # make sure wrapper scripts are executable (no-op if missing)
  chmod +x "$SCOREBOARD_SCRIPT" "$TARGET_SCRIPT" "$ATTACKER_SCRIPT" 2>/dev/null || true
}

# run_role role cmd base subdir
# role: scoreboard|target|attacker
# cmd: install-all | start-web | start-db | stop-all | status
run_role() {
  local role="$1"
  local cmd="$2"
  local base="$3"
  local subdir="${4:-}"
  local script

  case "$role" in
    scoreboard) script="$SCOREBOARD_SCRIPT" ;;
    target)     script="$TARGET_SCRIPT" ;;
    attacker)   script="$ATTACKER_SCRIPT" ;;
    *)
      echo "[manage] unknown role: $role" >&2
      return 2
      ;;
  esac

  mkdir -p "$base"
  if [ -n "$subdir" ]; then
    APP_BASE="$base" APP_SUBDIR="$subdir" "$script" "$cmd"
  else
    APP_BASE="$base" "$script" "$cmd"
  fi
}

usage() {
  cat <<'EOF'
Usage:
  sudo ./manage.sh install-all
  sudo ./manage.sh start-everything
  sudo ./manage.sh start-all
  sudo ./manage.sh stop-all
  sudo ./manage.sh status-all

Per-role:
  sudo ./manage.sh scoreboard install|start|stop|status
  sudo ./manage.sh target     install|start|stop|status
  sudo ./manage.sh attacker   install|start|stop|status

Environment overrides:
  BASE_ROOT=/opt/maccdc
  SCOREBOARD_BASE=/opt/maccdc/scoreboard TARGET_BASE=/opt/maccdc/target ATTACKER_BASE=/opt/maccdc/attacker
  SCOREBOARD_SUBDIR=scoreboard TARGET_SUBDIR=target ATTACKER_SUBDIR=attacker
EOF
}

main() {
  if ! is_root; then
    echo "[manage] please run with sudo/root"
    exit 2
  fi

  if ! need_scripts; then
    echo "[manage] setup scripts not found"
    exit 2
  fi

  make_exec

  case "${1:-help}" in
    install-all)
      run_role scoreboard install-all "$SCOREBOARD_BASE" "$SCOREBOARD_SUBDIR"
      run_role target     install-all "$TARGET_BASE"     "$TARGET_SUBDIR"
      run_role attacker   install-all "$ATTACKER_BASE"   "$ATTACKER_SUBDIR"
      ;;

    start-everything)
      # Full bootstrap then start everything
      "$0" install-all
      "$0" start-all
      ;;

    start-all)
      run_role scoreboard start-web "$SCOREBOARD_BASE" "$SCOREBOARD_SUBDIR"
      run_role target     start-web "$TARGET_BASE"     "$TARGET_SUBDIR"
      run_role attacker   start-web "$ATTACKER_BASE"   "$ATTACKER_SUBDIR"
      ;;

    stop-all)
      run_role scoreboard stop-all "$SCOREBOARD_BASE" "$SCOREBOARD_SUBDIR"
      run_role target     stop-all "$TARGET_BASE"     "$TARGET_SUBDIR"
      run_role attacker   stop-all "$ATTACKER_BASE"   "$ATTACKER_SUBDIR"
      ;;

    status-all)
      echo "----- SCOREBOARD -----"
      run_role scoreboard status "$SCOREBOARD_BASE" "$SCOREBOARD_SUBDIR" || true
      echo "----- TARGET -----"
      run_role target status "$TARGET_BASE" "$TARGET_SUBDIR" || true
      echo "----- ATTACKER -----"
      run_role attacker status "$ATTACKER_BASE" "$ATTACKER_SUBDIR" || true
      ;;

    scoreboard|target|attacker)
      local role="$1"
      local cmd="${2:-}"
      local base="" sub=""
      if [ "$role" = scoreboard ]; then base="$SCOREBOARD_BASE"; sub="$SCOREBOARD_SUBDIR"; fi
      if [ "$role" = target ];     then base="$TARGET_BASE";     sub="$TARGET_SUBDIR";     fi
      if [ "$role" = attacker ];   then base="$ATTACKER_BASE";   sub="$ATTACKER_SUBDIR";   fi

      case "$cmd" in
        install) run_role "$role" install-all "$base" "$sub" ;;
        start)   run_role "$role" start-web    "$base" "$sub" ;;
        stop)    run_role "$role" stop-all     "$base" "$sub" ;;
        status)  run_role "$role" status       "$base" "$sub" ;;
        *)
          usage
          exit 2
          ;;
      esac
      ;;

    help|--help|-h|"")
      usage
      ;;

    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"
