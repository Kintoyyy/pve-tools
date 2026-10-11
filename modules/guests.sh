# shellcheck shell=bash
# VM / LXC management on the local node.

guests_overview() {
  local tmp id type name status mem conf
  tmp=$(mktemp "$PVE_TOOLS_TMP/guests.XXXXXX")
  {
    printf '%-6s %-4s %-28s %-10s %8s\n' VMID TYPE NAME STATUS "MEM(MB)"
    printf '%.0s-' {1..60}; echo
    while IFS='|' read -r id type name status; do
      conf=$(guest_conf "$id")
      mem=$(awk -F': ' '/^memory:/ {print $2; exit}' "$conf" 2>/dev/null)
      is_template "$id" && status=template
      printf '%-6s %-4s %-28s %-10s %8s\n' "$id" "${type^^}" "$name" "$status" "${mem:-default}"
    done < <(guest_list)
  } >"$tmp"
  ui_textbox "Guests on $PVE_NODE" "$tmp"
  rm -f "$tmp"
}

# guests_action <start|shutdown|stop|reboot>
guests_action() {
  local action=$1 want=running out id cmd ok=0 fail=0
  local -a ids
  [[ $action == start ]] && want=stopped

  out=$(ui_pick_guests checklist all "$want" "${action^} guests") || return
  mapfile -t ids <<<"$out"

  if [[ $action == stop ]] &&
    ! ui_confirm "Stop" "'stop' is a hard power-off and may lose data.\nUse 'shutdown' for a clean stop.\n\nStop ${#ids[@]} guest(s) anyway?"; then
    return
  fi

  ui_terminal "${action^} guests"
  for id in "${ids[@]}"; do
    cmd=$(guest_cmd "$id")
    msg_info "$cmd $action $id ($(guest_name "$id"))"
    if run "$cmd" "$action" "$id"; then
      msg_ok "$id: $action OK"; ((ok++))
    else
      msg_error "$id: $action failed"; ((fail++))
    fi
  done
  msg_title "Done: $ok succeeded, $fail failed"
  pause
}

guests_bulk() {
  local action=$1
  case $action in
    startall)
      ui_yesno "Start all" "Start every guest with 'Start at boot' enabled, in boot order?" || return ;;
    stopall)
      ui_confirm "Shutdown all" "Shut down ALL running guests on $PVE_NODE (clean shutdown, then force after timeout)?" || return ;;
  esac
  ui_terminal "${action}"
  run pvesh create "/nodes/$PVE_NODE/$action"
  pause
}

guests_console() {
  local id
  id=$(ui_pick_guests menu all running "Console") || return
  clear
  if [[ $(guest_type "$id") == lxc ]]; then
    msg_info "Entering container $id. Type 'exit' to return."
    pct enter "$id"
  else
    if ! grep -qs '^serial0:' "$(guest_conf "$id")"; then
      ui_msg "Console" "VM $id has no serial port (serial0).\nAdd one with: qm set $id --serial0 socket\nand configure the guest OS for a serial console."
      return
    fi
    msg_info "Attaching to VM $id serial console. Press Ctrl+O to exit."
    qm terminal "$id"
  fi
  pause
}

guests_config() {
  local id
  id=$(ui_pick_guests menu all any "Show config" 1) || return
  ui_cmd_output "Config of $id ($(guest_name "$id"))" "$(guest_cmd "$id")" config "$id"
}

guests_menu() {
  local choice
  while true; do
    choice=$(ui_menu "VM / LXC management" "Node: $PVE_NODE" \
      overview "Overview of all guests" \
      start    "Start guests" \
      shutdown "Shut down guests (clean)" \
      reboot   "Reboot guests" \
      stop     "Stop guests (hard power-off)" \
      startall "Start all (onboot guests, in boot order)" \
      stopall  "Shut down all running guests" \
      console  "Open a console" \
      config   "Show a guest's config" \
      back     "Back") || return
    case $choice in
      overview)                   guests_overview ;;
      start | shutdown | reboot | stop) guests_action "$choice" ;;
      startall | stopall)         guests_bulk "$choice" ;;
      console)                    guests_console ;;
      config)                     guests_config ;;
      back)                       return ;;
    esac
  done
}
