#!/usr/bin/env bash
# manage.sh — robust orchestrator for CDCWebSim
# - Resolves its own directory (SCRIPT_DIR)
# - Prints diagnostics for the 3 wrapper scripts (ls -lb)
# - Invokes wrappers with: bash "$SCRIPT" ... (avoids noexec / missing +x issues)
# - Usage: sudo ./manage.sh install-all | start-all | status-all | scoreboard start | etc.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_ROOT="${BASE_ROOT:-/opt/maccdc}"

# anchor wrapper script paths to the script dir
SCOREBOARD_SCRIPT="${SCOREBOARD_SCRIPT:-${SCRIPT_DIR}/setup-scoreboard.sh}"
TARGET_SCRIPT="${TARGET_SCRIPT:-${SCRIPT_DIR}/setup-target.sh}"
ATTACKER_SCRIPT="${ATTACKER_SCRIPT:-${SCRIPT_DIR}/setup-attacker.sh}"

SCOREBOARD_BASE="${SCOREBOARD_BASE:-$BASE_ROOT/scoreboard}"
TARGET_BASE="${TARGET_BASE:-$BASE_ROOT/target}"
ATTACKER_BASE="${ATTACKER_BASE:-$BASE_ROOT/attacker}"

SCOREBOARD_SUBDIR="${SCOREBOARD_SUBDIR:-}"
TARGET_SUBDIR="${TARGET_SUBDIR:-}"
ATTACKER_SUBDIR="${ATTACKER_SUBDIR:-}"

is_root(){ [ "$(id -u)" -eq 0 ]; }

diagnostics(){
  echo "== manage.sh diagnostics =="
  echo "manage.sh path: $SCRIPT_DIR/manage.sh"
  echo
  echo "Checking wrapper script files (raw byte-visible names and perms):"
  for s in "$SCOREBOARD_SCRIPT" "$TARGET_SCRIPT" "$ATTACKER_SCRIPT"; do
    if [ -e "$s" ]; then
      ls -lb -d "$s"
      echo " first 2 lines:"
      sed -n '1,2p' "$s" 2>/dev/null | sed -n '1,2p' | sed -n '1,2p' || true
    else
      echo " MISSING: $s"
    fi
    echo "----"
  done
  echo
  echo "Note: wrappers will be invoked with 'bash <script> <cmd>' to avoid noexec/permission issues."
  echo "================================="
}

need_scripts(){
  for f in "$SCOREBOARD_SCRIPT" "$TARGET_SCRIPT" "$ATTACKER_SCRIPT"; do
    [ -f "$f" ] || return 1
  done
  return 0
}

# run wrapper script with bash interpreter: bash "$script" "$cmd"
run_wrapper(){
  local script_path="$1"; shift
  if [ ! -f "$script_path" ]; then
    echo "[manage] wrapper missing: $script_path" >&2
    return 2
  fi
  # call via bash so noexec / missing +x won't block it
  bash "$script_path" "$@"
  return $?
}

run_role(){
  local role="$1" cmd="$2" base="$3" subdir="${4:-}"
  local script
  case "$role" in
    scoreboard) script="$SCOREBOARD_SCRIPT" ;;
    target)     script="$TARGET_SCRIPT" ;;
    attacker)   script="$ATTACKER_SCRIPT" ;;
    *) echo "[manage] unknown role: $role" >&2; return 2 ;;
  esac

  mkdir -p "$base"
  if [ -n "$subdir" ]; then
    APP_BASE="$base" APP_SUBDIR="$subdir" run_wrapper "$script" "$cmd"
  else
    APP_BASE="$base" run_wrapper "$script" "$cmd"
  fi
}

usage(){
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

If you still see "setup scripts not found", run:
  ls -lb manage.sh setup-*.sh
  sed -n '1,3p' setup-scoreboard.sh | sed -n '1,3p'
EOF
}

main(){
  # Quick diagnostics always printed (helps spot CRLF or bad names)
  diagnostics

  if ! is_root; then
    echo "[manage] please run with sudo/root"
    exit 2
  fi

  if ! need_scripts; then
    echo "[manage] setup scripts not found (checked the absolute paths above)."
    echo "[manage] If files exist, try: sudo bash ./manage.sh status-all"
    exit 2
  fi

  case "${1:-help}" in
    install-all)
      run_role scoreboard install-all "$SCOREBOARD_BASE" "$SCOREBOARD_SUBDIR"
      run_role target     install-all "$TARGET_BASE"     "$TARGET_SUBDIR"
      run_role attacker   install-all "$ATTACKER_BASE"   "$ATTACKER_SUBDIR"
      ;;

    start-everything)
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
      local role="$1" cmd="${2:-}"
      local base="" sub=""
      [ "$role" = scoreboard ] && { base="$SCOREBOARD_BASE"; sub="$SCOREBOARD_SUBDIR"; }
      [ "$role" = target ]     && { base="$TARGET_BASE";     sub="$TARGET_SUBDIR"; }
      [ "$role" = attacker ]   && { base="$ATTACKER_BASE";   sub="$ATTACKER_SUBDIR"; }
      case "$cmd" in
        install) run_role "$role" install-all "$base" "$sub" ;;
        start)   run_role "$role" start-web    "$base" "$sub" ;;
        stop)    run_role "$role" stop-all     "$base" "$sub" ;;
        status)  run_role "$role" status       "$base" "$sub" ;;
        *) usage; exit 2 ;;
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
