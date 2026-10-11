# shellcheck shell=bash
# Common helpers: output/logging, host detection, and the mutating-command runner.

PVE_TOOLS_LOG="${PVE_TOOLS_LOG:-/var/log/pve-tools.log}"
PVE_TOOLS_DRY_RUN="${PVE_TOOLS_DRY_RUN:-0}"
PVE_TOOLS_BACKUP_DIR="${PVE_TOOLS_BACKUP_DIR:-/var/backups/pve-tools}"

if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m'
else
  C_RESET='' C_BOLD='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi

# --- output -----------------------------------------------------------------

_log() {
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >>"$PVE_TOOLS_LOG" 2>/dev/null || true
}

msg_info()  { printf '%s[i]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; _log INFO "$*"; }
msg_ok()    { printf '%s[✓]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; _log OK "$*"; }
msg_warn()  { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; _log WARN "$*"; }
msg_error() { printf '%s[✗]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; _log ERROR "$*"; }
msg_title() { printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RESET"; }

die() { msg_error "$*"; exit 1; }

is_dry_run() { [[ $PVE_TOOLS_DRY_RUN == 1 ]]; }

# Wait for Enter so output stays visible before returning to the TUI.
pause() {
  local _
  read -rp $'\nPress Enter to continue...' _ </dev/tty || true
}

# --- mutating commands ------------------------------------------------------
# Every command that changes the system goes through run/write_file/append_line/
# remove_file, so --dry-run can show exactly what would happen.

run() {
  _log RUN "$*"
  if is_dry_run; then
    printf '%s[dry-run]%s %s\n' "$C_YELLOW" "$C_RESET" "$(printf '%q ' "$@")"
    return 0
  fi
  "$@"
}

# write_file <path> [mode] — write stdin to <path>, backing up any existing file.
write_file() {
  local path=$1 mode=${2:-0644} content
  content=$(cat)
  _log WRITE "$path"
  if is_dry_run; then
    printf '%s[dry-run]%s write %s (mode %s):\n%s\n' "$C_YELLOW" "$C_RESET" "$path" "$mode" "$content"
    return 0
  fi
  backup_file "$path"
  printf '%s\n' "$content" >"$path" && chmod "$mode" "$path"
}

# append_line <path> <line> — append <line> unless the file already has it.
append_line() {
  grep -qxF -- "$2" "$1" 2>/dev/null && return 0
  _log APPEND "'$2' >> $1"
  if is_dry_run; then
    printf '%s[dry-run]%s append %q to %s\n' "$C_YELLOW" "$C_RESET" "$2" "$1"
    return 0
  fi
  backup_file "$1"
  printf '%s\n' "$2" >>"$1"
}

remove_file() {
  [[ -e $1 ]] || return 0
  backup_file "$1"
  run rm -f "$1"
}

# --- backup sessions ----------------------------------------------------------
# Each pve-tools run is one backup session. The first time a file is touched, its
# original is copied to $PVE_TOOLS_SESSION_DIR/<path> (or recorded as absent) and
# listed in .manifest, so restore_session can undo the whole run later.

PVE_TOOLS_SESSION_DIR="$PVE_TOOLS_BACKUP_DIR/$(date +%Y%m%d-%H%M%S)"

# manifest_add <type> <arg> — types: saved <path>, absent <path>, driverctl <bdf>.
manifest_add() {
  is_dry_run && return 0
  mkdir -p "$PVE_TOOLS_SESSION_DIR" && printf '%s\n' "$*" >>"$PVE_TOOLS_SESSION_DIR/.manifest"
}

# backup_file <path> — snapshot <path> once per session before it is changed.
backup_file() {
  local f=$1 manifest="$PVE_TOOLS_SESSION_DIR/.manifest"
  is_dry_run && return 0
  if [[ -f $manifest ]] &&
    awk -v f="$f" '{ t = $1; p = substr($0, length($1) + 2) } (t == "saved" || t == "absent") && p == f { x = 1 } END { exit !x }' "$manifest"; then
    return 0
  fi
  if [[ -e $f ]]; then
    mkdir -p "$PVE_TOOLS_SESSION_DIR$(dirname "$f")" && cp -a "$f" "$PVE_TOOLS_SESSION_DIR$f" || return 1
    manifest_add saved "$f"
  else
    manifest_add absent "$f"
  fi
  _log BACKUP "$f"
}

# restore_session <dir> — undo every change recorded in <dir>/.manifest.
restore_session() {
  local dir=$1 type path
  while read -r type path; do
    case $type in
      saved)     run cp -a "$dir$path" "$path" ;;
      absent)    run rm -f "$path" ;;
      driverctl) command -v driverctl >/dev/null 2>&1 && run driverctl unset-override "$path" ;;
    esac
  done <"$dir/.manifest"
}

# --- host checks ------------------------------------------------------------

require_root() {
  [[ $EUID -eq 0 ]] || die "pve-tools must be run as root."
}

require_pve() {
  command -v pveversion >/dev/null 2>&1 || die "This does not look like a Proxmox VE host (pveversion not found)."
  command -v whiptail >/dev/null 2>&1 || die "whiptail is required: apt-get install whiptail"
}

# Sets PVE_VERSION, PVE_MAJOR, DEB_CODENAME, APT_FORMAT (list|deb822) and PVE_NODE.
detect_pve() {
  # pveversion prints e.g. "pve-manager/8.2.4/faa83925c9641325 (running kernel: 6.8.12-1-pve)"
  PVE_VERSION=$(pveversion 2>/dev/null | awk -F/ '{print $2}')
  PVE_MAJOR=${PVE_VERSION%%.*}
  # shellcheck disable=SC1091
  DEB_CODENAME=$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-}")

  case $PVE_MAJOR in
    7) APT_FORMAT=list;   : "${DEB_CODENAME:=bullseye}" ;;
    8) APT_FORMAT=list;   : "${DEB_CODENAME:=bookworm}" ;;
    9) APT_FORMAT=deb822; : "${DEB_CODENAME:=trixie}" ;;
    *) die "Unsupported Proxmox VE version '${PVE_VERSION:-unknown}' (supported: 7, 8, 9)." ;;
  esac

  PVE_NODE=$(hostname)
  export PVE_VERSION PVE_MAJOR DEB_CODENAME APT_FORMAT PVE_NODE
}

is_clustered() { [[ -f /etc/pve/corosync.conf ]]; }

# --- guests -----------------------------------------------------------------

# guest_list — print "id|type|name|status" for every guest on this node, sorted by id.
guest_list() {
  {
    qm list 2>/dev/null | awk 'NR>1 {print $1 "|vm|" $2 "|" $3}'
    # pct list has an optional Lock column, so the name is always the last field.
    pct list 2>/dev/null | awk 'NR>1 {print $1 "|lxc|" $NF "|" $2}'
  } | sort -t'|' -k1,1n
}

guest_conf() {
  if [[ -f /etc/pve/qemu-server/$1.conf ]]; then
    printf '%s' "/etc/pve/qemu-server/$1.conf"
  else
    printf '%s' "/etc/pve/lxc/$1.conf"
  fi
}

guest_type() { [[ -f /etc/pve/qemu-server/$1.conf ]] && echo vm || echo lxc; }
guest_cmd()  { [[ -f /etc/pve/qemu-server/$1.conf ]] && echo qm || echo pct; }
guest_name() { guest_list | awk -F'|' -v id="$1" '$1==id {print $3}'; }
is_template() { grep -qs '^template: 1' "$(guest_conf "$1")"; }

# guest_snapshots <id> — print "name|unix-time|description" for each snapshot.
guest_snapshots() {
  awk '
    /^\[/ {
      s = substr($0, 2, length($0) - 2)
      if (s == "PENDING" || s ~ /^special:/) s = ""
      else names[++n] = s
      next
    }
    s != "" && /^snaptime:/ { t[s] = $2 }
    s != "" && /^description:/ { sub(/^description: */, ""); d[s] = $0 }
    END { for (i = 1; i <= n; i++) print names[i] "|" t[names[i]] "|" d[names[i]] }
  ' "$(guest_conf "$1")" 2>/dev/null
}
