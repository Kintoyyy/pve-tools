# shellcheck shell=bash
# Thin whiptail layer. Modules call these instead of whiptail directly.
#
# Data-returning widgets (menu, checklist, radiolist, input) print the result on
# stdout and return non-zero on Cancel/Esc, so callers can do: x=$(ui_menu ...) || return
# Display-only widgets draw straight to /dev/tty so they also work inside $(...).

UI_BACKTITLE=${UI_BACKTITLE:-pve-tools}

_ui_size() {
  local lines=24 cols=80 size
  size=$(stty size </dev/tty 2>/dev/null) && read -r lines cols <<<"$size"
  UI_H=$((lines - 4)); ((UI_H > 30)) && UI_H=30; ((UI_H < 15)) && UI_H=15
  UI_W=$((cols - 8));  ((UI_W > 100)) && UI_W=100; ((UI_W < 60)) && UI_W=60
  UI_LIST=$((UI_H - 8))
}

# Height that fits <text> (accounting for wrapping), capped at the screen height.
_ui_text_h() {
  local h text=${1//\\n/$'\n'} # whiptail expands literal \n too
  h=$(awk -v w=$((UI_W - 4)) '{ n += (length($0) > w) ? int((length($0) + w - 1) / w) : 1 } END { print n + 7 }' <<<"$text")
  ((h > UI_H)) && h=$UI_H
  echo "$h"
}

_wt() { whiptail --backtitle "$UI_BACKTITLE" "$@"; }

# ui_menu <title> <text> <tag> <desc> [<tag> <desc>...]
# Set UI_DEFAULT_ITEM=<tag> to preselect an entry.
ui_menu() {
  local title=$1 text=$2; shift 2
  local -a extra=()
  [[ -n ${UI_DEFAULT_ITEM:-} ]] && extra=(--default-item "$UI_DEFAULT_ITEM")
  _ui_size
  _wt --title "$title" "${extra[@]}" --menu "$text" "$UI_H" "$UI_W" "$UI_LIST" "$@" 3>&1 1>&2 2>&3
}

# ui_checklist <title> <text> <tag> <desc> <ON|OFF> [...] — one selected tag per line.
# Returns 1 when cancelled, or when nothing was selected unless UI_ALLOW_EMPTY=1.
ui_checklist() {
  local title=$1 text=$2 out; shift 2
  _ui_size
  out=$(_wt --title "$title" --separate-output --checklist "$text" "$UI_H" "$UI_W" "$UI_LIST" "$@" 3>&1 1>&2 2>&3) || return 1
  if [[ -n $out ]]; then
    printf '%s\n' "$out"
  elif [[ ${UI_ALLOW_EMPTY:-0} != 1 ]]; then
    return 1
  fi
}

# ui_radiolist <title> <text> <tag> <desc> <ON|OFF> [...]
ui_radiolist() {
  local title=$1 text=$2; shift 2
  _ui_size
  _wt --title "$title" --radiolist "$text" "$UI_H" "$UI_W" "$UI_LIST" "$@" 3>&1 1>&2 2>&3
}

# ui_input <title> <text> [default]
ui_input() {
  _ui_size
  _wt --title "$1" --inputbox "$2" 10 "$UI_W" "${3:-}" 3>&1 1>&2 2>&3
}

ui_msg() {
  _ui_size
  _wt --title "$1" --msgbox "$2" "$(_ui_text_h "$2")" "$UI_W" >/dev/tty
}

# ui_yesno <title> <text> — returns 0 for Yes.
ui_yesno() {
  _ui_size
  _wt --title "$1" --yesno "$2" "$(_ui_text_h "$2")" "$UI_W" >/dev/tty
}

# ui_confirm <title> <text> — like ui_yesno but defaults to No (for destructive actions).
ui_confirm() {
  _ui_size
  _wt --title "$1" --defaultno --yesno "$2" "$(_ui_text_h "$2")" "$UI_W" >/dev/tty
}

# ui_textbox <title> <file>
# No --scrolltext: it moves focus to the text so Enter stops closing the box.
# Long files still scroll with arrows/PgUp/PgDn without it.
ui_textbox() {
  _ui_size
  _wt --title "$1" --textbox "$2" "$UI_H" "$UI_W" >/dev/tty
}

# ui_cmd_output <title> <cmd...> — run a read-only command and show its output.
ui_cmd_output() {
  local title=$1 tmp; shift
  tmp=$(mktemp "${PVE_TOOLS_TMP:-/tmp}/out.XXXXXX")
  "$@" >"$tmp" 2>&1
  [[ -s $tmp ]] || echo "(no output)" >"$tmp"
  ui_textbox "$title" "$tmp"
  rm -f "$tmp"
}

# Leave the TUI to run something with live output in the terminal.
ui_terminal() {
  clear
  msg_title "$1"
}

# ui_pick_guests <menu|checklist> <vm|lxc|all> <running|stopped|any> <title> [include_templates]
# Prints the selected VMID(s), one per line. Returns 1 if cancelled or none match.
ui_pick_guests() {
  local mode=$1 want_type=$2 want_status=$3 title=$4 templates=${5:-0}
  local id type name status desc
  local -a items=()

  while IFS='|' read -r id type name status; do
    [[ $want_type != all && $type != "$want_type" ]] && continue
    [[ $want_status != any && $status != "$want_status" ]] && continue
    if is_template "$id"; then
      ((templates)) || continue
      status=template
    fi
    desc=$(printf '%-4s %-28s %s' "${type^^}" "$name" "$status")
    if [[ $mode == checklist ]]; then
      items+=("$id" "$desc" OFF)
    else
      items+=("$id" "$desc")
    fi
  done < <(guest_list)

  if ((${#items[@]} == 0)); then
    ui_msg "$title" "No matching guests found on node ${PVE_NODE:-this node}."
    return 1
  fi

  if [[ $mode == checklist ]]; then
    ui_checklist "$title" "Select guests (space to toggle):" "${items[@]}"
  else
    ui_menu "$title" "Select a guest:" "${items[@]}"
  fi
}

# ui_pick_storage <content-type> — e.g. "backup", "images". Prints the storage ID.
ui_pick_storage() {
  local content=$1 name type avail
  local -a items=()

  while read -r name type avail; do
    items+=("$name" "$(printf '%-10s %s free' "$type" "$avail")")
  done < <(pvesm status --content "$content" 2>/dev/null |
    awk 'NR>1 && $3=="active" { printf "%s %s %.1fGiB\n", $1, $2, $6/1048576 }')

  if ((${#items[@]} == 0)); then
    ui_msg "Storage" "No active storage with content type '$content' was found."
    return 1
  fi
  ui_menu "Storage" "Select a storage for '$content':" "${items[@]}"
}
