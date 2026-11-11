#!/bin/bash
# mac-claude-migration — front-door command for the two tools.
#
#   mac-claude-migration                  interactive menu (terminal only)
#   mac-claude-migration backup ...       pass-through to backup.sh
#   mac-claude-migration restore ...      pass-through to restore.sh
#   mac-claude-migration --help           overview of both commands
#
# Non-terminal runs never prompt: bare invocation prints the overview and exits 2.
# Menu chrome goes to stderr; numbers are actions, q quits (menu grammar rule).
# Usage: mac-claude-migration.sh [--help] [backup|restore] [args...]
set -u
SELF_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
BACKUP_SH="$SELF_DIR/backup.sh"
RESTORE_SH="$SELF_DIR/restore.sh"
VER=""
[ -f "$SELF_DIR/VERSION" ] && VER=$(tr -d '[:space:]' < "$SELF_DIR/VERSION")

usage() {  # overview of the two real commands; $1 = stream ("stdout"/"stderr")
  local v=""; [ -n "$VER" ] && v=" $VER"
  if [ "$1" = "stdout" ]; then
    printf '📦 mac-claude-migration%s — front door for the two commands:\n' "$v"
    printf '  mac-claude-backup [OUTDIR]    create the migration archive\n'
    printf '  mac-claude-restore ARCHIVE    restore from an archive on the new Mac\n'
    printf '  mac-claude-migration backup|restore ...   passes straight through\n'
  else
    printf '📦 mac-claude-migration%s — front door for the two commands:\n' "$v" >&2
    printf '  mac-claude-backup [OUTDIR]    create the migration archive\n' >&2
    printf '  mac-claude-restore ARCHIVE    restore from an archive on the new Mac\n' >&2
    printf '  mac-claude-migration backup|restore ...   passes straight through\n' >&2
  fi
}

case "${1:-}" in
  --help|-h) usage stdout; exit 0 ;;
  backup)  shift; exec "$BACKUP_SH" "$@" ;;
  restore) shift; exec "$RESTORE_SH" "$@" ;;
  "") ;;
  *) printf 'unknown command: %s\n' "$1" >&2; usage stderr; exit 2 ;;
esac

# No args: menu on a terminal, overview + exit 2 otherwise (never prompt off-terminal).
VTXT=""; [ -n "$VER" ] && VTXT=" $VER"
if [ -t 0 ] && [ -t 1 ]; then
  printf '\n📦 mac-claude-migration%s\n' "$VTXT" >&2
  printf '   1) mac-claude-backup   — capture this Mac state into an archive\n' >&2
  printf '   2) mac-claude-restore  — rebuild from an archive on a new Mac\n' >&2
  printf '   q) quit\n\n' >&2
  read -r ans || ans="q"
  case "$ans" in
    ""|1) exec "$BACKUP_SH" ;;
    2)  exec "$RESTORE_SH" ;;
    q|Q) exit 0 ;;
    *) printf '  Unrecognized: %s\n' "$ans" >&2; exit 2 ;;
  esac
else
  usage stderr
  exit 2
fi
