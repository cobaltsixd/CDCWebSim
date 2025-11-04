cp manage.sh manage.sh.bak
cat > manage.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_ROOT="${BASE_ROOT:-/opt/maccdc}"
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
need_scripts(){
  local ok=1
  for f in "$SCOREBOARD_SCRIPT" "$TARGET_SCRIPT" "$ATTACKER_SCRIPT"; do
    if [ ! -f "$f" ]; then
      echo "[manage] missing: $f" >&2; ok=0
    fi
  done
  return $ok
}
make_exec(){ chmod +x "$SCOREBOARD_SCRIPT" "$TARGET_SCRIPT" "$ATTACKER_SCRIPT" 2>/dev/null || true; }
run_role(){ local role="$1" cmd="$2" base="$3" subdir="${4:-}" script; case "$role" in scoreboard) script="$SCOREBOARD_SCRIPT" ;; target) script="$TARGET_SCRIPT" ;; attacker) script="$ATTACKER_SCRIPT" ;; *) echo "[manage] unknown role: $role" >&2; exit 2 ;; esac; mkdir -p "$base"; if [ -n "$subdir" ]; then APP_BASE="$base" APP_SUBDIR="$subdir" "$script" "$cmd"; else APP_BASE="$base" "$script" "$cmd"; fi }
usage(){ cat <<'EOF'
Usage:
  sudo ./manage.sh install-all
  sudo ./manage.sh start-everything
  sudo ./manage.sh start-all
  sudo ./manage.sh stop-all
  sudo ./manage.sh status-all
Per-role:
  sudo ./manage.sh scoreboard install|start|stop|status
EOF
}
main(){
  is_root || { echo "[manage] please run with sudo/root"; exit 2; }
  need_scripts || { echo "[manage] setup scripts not found"; exit 2; }
  make_exec
  case "${1:-help}" in
    install-all) run_role scoreboard install-all "$SCOREBOARD_BASE" "$SCOREBOARD_SUBDIR"; run_role target install-all "$TARGET_BASE" "$TARGET_SUBDIR"; run_role attacker install-all "$ATTACKER_BASE" "$ATTACKER_SUBDIR";;
    start-everything) "$0" install-all; "$0" start-all;;
    start-all) run_role scoreboard start-web "$SCOREBOARD_BASE" "$SCOREBOARD_SUBDIR"; run_role target start-web "$TARGET_BASE" "$TARGET_SUBDIR"; run_role attacker start-web "$ATTACKER_BASE" "$ATTACKER_SUBDIR";;
    stop-all) run_role scoreboard stop-all "$SCOREBOARD_BASE" "$SCOREBOARD_SUBDIR"; run_role target stop-all "$TARGET_BASE" "$TARGET_SUBDIR"; run_role attacker stop-all "$ATTACKER_BASE" "$ATTACKER_SUBDIR";;
    status-all) echo "----- SCOREBOARD -----"; run_role scoreboard status "$SCOREBOARD_BASE" "$SCOREBOARD_SUBDIR" || true; echo "----- TARGET -----"; run_role target status "$TARGET_BASE" "$TARGET_SUBDIR" || true; echo "----- ATTACKER -----"; run_role attacker status "$ATTACKER_BASE" "$ATTACKER_SUBDIR" || true;;
    scoreboard|target|attacker) role="$1"; sub=""; base=""; [ "$role" = scoreboard ] && { base="$SCOREBOARD_BASE"; sub="$SCOREBOARD_SUBDIR"; }; [ "$role" = target ] && { base="$TARGET_BASE"; sub="$TARGET_SUBDIR"; }; [ "$role" = attacker ] && { base="$ATTACKER_BASE"; sub="$ATTACKER_SUBDIR"; }; case "${2:-}" in install) run_role "$role" install-all "$base" "$sub" ;; start) run_role "$role" start-web "$base" "$sub" ;; stop) run_role "$role" stop-all "$base" "$sub" ;; status) run_role "$role" status "$base" "$sub" ;; *) usage; exit 2 ;; esac ;;
    help|--help|-h|"") usage ;;
    *) usage; exit 2 ;;
  esac
}
main "$@"
EOF
chmod +x manage.sh
echo "manage.sh replaced (backup saved as manage.sh.bak). Try: sudo ./manage.sh install-all"
