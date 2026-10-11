# shellcheck shell=bash
# Backups (vzdump), snapshots and backup pruning.

backup_now() {
  local out storage mode
  local -a ids
  out=$(ui_pick_guests checklist all any "Back up guests" 1) || return
  mapfile -t ids <<<"$out"
  storage=$(ui_pick_storage backup) || return
  mode=$(ui_radiolist "Backup mode" "How should running guests be backed up?" \
    snapshot "Live, no downtime (recommended)"    ON \
    suspend  "Suspend guest during backup"        OFF \
    stop     "Stop guest, back up, start again"   OFF) || return

  ui_yesno "Back up" "Back up ${ids[*]} to '$storage' (mode: $mode, zstd)?" || return
  ui_terminal "Backup"
  if run vzdump "${ids[@]}" --storage "$storage" --mode "$mode" --compress zstd; then
    msg_ok "Backup finished."
  else
    msg_error "vzdump reported errors; see the output above."
  fi
  pause
}

# --- snapshots ----------------------------------------------------------------

# snapshot_pick <id> <title> — menu of existing snapshots, prints the name.
snapshot_pick() {
  local id=$1 title=$2 name time desc
  local -a items=()
  while IFS='|' read -r name time desc; do
    items+=("$name" "$( [[ -n $time ]] && date -d "@$time" '+%F %R')  ${desc}")
  done < <(guest_snapshots "$id")
  if ((${#items[@]} == 0)); then
    ui_msg "$title" "Guest $id has no snapshots."
    return 1
  fi
  ui_menu "$title" "Snapshots of $id ($(guest_name "$id")):" "${items[@]}"
}

snapshot_create() {
  local id=$1 cmd name desc
  local -a extra=()
  cmd=$(guest_cmd "$id")
  name=$(ui_input "New snapshot" "Snapshot name (letters, digits, - and _; must start with a letter):" \
    "snap-$(date +%Y%m%d-%H%M)") || return
  if [[ ! $name =~ ^[A-Za-z][A-Za-z0-9_-]{1,39}$ ]]; then
    ui_msg "New snapshot" "Invalid name '$name'.\nUse 2-40 characters: letters, digits, '-' and '_', starting with a letter."
    return
  fi
  desc=$(ui_input "New snapshot" "Description (optional):") || return
  [[ -n $desc ]] && extra+=(--description "$desc")
  if [[ $cmd == qm ]] && qm status "$id" 2>/dev/null | grep -q running &&
    ui_yesno "New snapshot" "Include the VM's RAM state?\n(Lets you resume exactly where it was, but uses more space.)"; then
    extra+=(--vmstate 1)
  fi

  ui_terminal "Create snapshot"
  run "$cmd" snapshot "$id" "$name" "${extra[@]}" && msg_ok "Snapshot '$name' created."
  pause
}

snapshot_rollback() {
  local id=$1 name
  name=$(snapshot_pick "$id" "Roll back") || return
  ui_confirm "Roll back" "Roll back $id to '$name'?\n\nAll changes since that snapshot will be LOST." || return
  ui_terminal "Roll back snapshot"
  run "$(guest_cmd "$id")" rollback "$id" "$name" && msg_ok "Rolled back to '$name'."
  pause
}

snapshot_delete() {
  local id=$1 name
  name=$(snapshot_pick "$id" "Delete snapshot") || return
  ui_confirm "Delete snapshot" "Delete snapshot '$name' of $id?" || return
  ui_terminal "Delete snapshot"
  run "$(guest_cmd "$id")" delsnapshot "$id" "$name" && msg_ok "Deleted '$name'."
  pause
}

snapshot_menu() {
  local id choice
  id=$(ui_pick_guests menu all any "Snapshots") || return
  while true; do
    choice=$(ui_menu "Snapshots" "Guest $id ($(guest_name "$id"))" \
      list     "List snapshots" \
      create   "Create a snapshot" \
      rollback "Roll back to a snapshot" \
      delete   "Delete a snapshot" \
      back     "Back") || return
    case $choice in
      list)     ui_cmd_output "Snapshots of $id" "$(guest_cmd "$id")" listsnapshot "$id" ;;
      create)   snapshot_create "$id" ;;
      rollback) snapshot_rollback "$id" ;;
      delete)   snapshot_delete "$id" ;;
      back)     return ;;
    esac
  done
}

# --- pruning ------------------------------------------------------------------

backup_prune() {
  local storage key val tmp
  local -a opts=()
  storage=$(ui_pick_storage backup) || return

  for key in last daily weekly monthly; do
    case $key in
      last) val=3 ;; daily) val=7 ;; weekly) val=4 ;; monthly) val=0 ;;
    esac
    val=$(ui_input "Prune backups" "keep-$key (0 = not used):" "$val") || return
    if [[ ! $val =~ ^[0-9]+$ ]]; then
      ui_msg "Prune backups" "'$val' is not a number."
      return
    fi
    ((val > 0)) && opts+=("--keep-$key" "$val")
  done
  if ((${#opts[@]} == 0)); then
    ui_msg "Prune backups" "Set at least one keep-* value."
    return
  fi

  # The dry run is read-only, so it runs even in --dry-run mode.
  tmp=$(mktemp "$PVE_TOOLS_TMP/prune.XXXXXX")
  pvesm prune-backups "$storage" "${opts[@]}" --dry-run 1 >"$tmp" 2>&1
  ui_textbox "Prune preview ($storage) — 'remove' entries will be deleted" "$tmp"
  rm -f "$tmp"

  ui_confirm "Prune backups" "Delete the backups marked 'remove' on '$storage'?" || return
  ui_terminal "Prune backups"
  run pvesm prune-backups "$storage" "${opts[@]}" && msg_ok "Prune finished."
  pause
}

backup_menu() {
  local choice
  while true; do
    choice=$(ui_menu "Backups & snapshots" "Node: $PVE_NODE" \
      backup   "Back up guests now (vzdump)" \
      snapshot "Manage snapshots" \
      prune    "Prune old backups" \
      jobs     "Show scheduled backup jobs" \
      back     "Back") || return
    case $choice in
      backup)   backup_now ;;
      snapshot) snapshot_menu ;;
      prune)    backup_prune ;;
      jobs)     ui_cmd_output "Backup jobs" pvesh get /cluster/backup ;;
      back)     return ;;
    esac
  done
}
