# shellcheck shell=bash
# System maintenance: kernels, storage health, node info, LXC updates, apt cleanup.

# --- kernel cleanup -------------------------------------------------------------

# Print installed kernel image packages as "version package" lines.
# Matches pve-kernel-X.Y.Z-N-pve (PVE 7) and proxmox-kernel-X.Y.Z-N-pve[-signed] (PVE 8/9);
# meta packages like proxmox-kernel-6.8 are skipped.
kernel_packages() {
  dpkg-query -W -f='${Package} ${db:Status-Status}\n' 'pve-kernel-*' 'proxmox-kernel-*' 2>/dev/null |
    awk '$2 == "installed" { print $1 }' |
    sed -nE 's/^((pve|proxmox)-kernel-([0-9]+\.[0-9]+\.[0-9]+-[0-9]+-pve)(-signed)?)$/\3 \1/p'
}

kernel_cleanup() {
  local running newest pinned ver pkg out tmp
  local -a items=() selected=() purge=() ver_pkgs
  declare -A pkgs=()

  while read -r ver pkg; do
    pkgs[$ver]+="$pkg "
  done < <(kernel_packages)

  running=$(uname -r)
  newest=$(printf '%s\n' "${!pkgs[@]}" | sort -V | tail -n1)
  pinned=$(cat /etc/kernel/proxmox-boot-pin 2>/dev/null)

  while read -r ver; do
    [[ -z $ver || $ver == "$running" || $ver == "$newest" || $ver == "$pinned" ]] && continue
    items+=("$ver" "${pkgs[$ver]}" OFF)
  done < <(printf '%s\n' "${!pkgs[@]}" | sort -V)

  if ((${#items[@]} == 0)); then
    ui_msg "Kernel cleanup" "Nothing to remove.\n\nRunning: $running\nNewest:  ${newest:-?}${pinned:+\nPinned:  $pinned}"
    return
  fi

  out=$(ui_checklist "Kernel cleanup" \
    "Running ($running), newest ($newest)${pinned:+ and pinned ($pinned)} kernels are protected.\nSelect old kernels to remove:" \
    "${items[@]}") || return
  mapfile -t selected <<<"$out"

  for ver in "${selected[@]}"; do
    read -ra ver_pkgs <<<"${pkgs[$ver]}"
    purge+=("${ver_pkgs[@]}")
    # Also drop matching headers if installed.
    for pkg in "pve-headers-$ver" "proxmox-headers-$ver"; do
      dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null | grep -q '^installed$' && purge+=("$pkg")
    done
  done

  # Show exactly what apt would remove (catches meta packages pulled along).
  tmp=$(mktemp "$PVE_TOOLS_TMP/kernel.XXXXXX")
  apt-get -s purge "${purge[@]}" 2>&1 | grep -E '^(Purg|Remv) ' >"$tmp"
  ui_textbox "apt will remove" "$tmp"
  rm -f "$tmp"
  ui_confirm "Kernel cleanup" "Purge ${#purge[@]} package(s)?" || return

  ui_terminal "Kernel cleanup"
  run apt-get -y purge "${purge[@]}" || { pause; return; }
  if command -v proxmox-boot-tool >/dev/null 2>&1; then
    run proxmox-boot-tool refresh
  else
    run update-grub
  fi
  msg_ok "Old kernels removed."
  pause
}

# --- health & info ----------------------------------------------------------------

storage_report() {
  local disk
  echo "=== Proxmox storage ==="
  pvesm status
  echo
  echo "=== Filesystems ==="
  df -hT -x tmpfs -x devtmpfs -x overlay -x squashfs
  if command -v zpool >/dev/null 2>&1 && [[ -n $(zpool list -H 2>/dev/null) ]]; then
    echo
    echo "=== ZFS pools ==="
    zpool list
    echo
    zpool status -x
  fi
  if command -v smartctl >/dev/null 2>&1; then
    echo
    echo "=== SMART health ==="
    while read -r disk; do
      printf '%-12s %s\n' "/dev/$disk" \
        "$(smartctl -H "/dev/$disk" 2>/dev/null | grep -Ei 'overall-health|health status' | sed 's/.*: *//')"
    done < <(lsblk -dno NAME,TYPE | awk '$2 == "disk" && $1 !~ /^(zd|rbd|nbd|zram|loop)/ {print $1}')
  fi
}

node_report() {
  echo "=== Node ==="
  echo "Host:    $PVE_NODE"
  echo "Version: $(pveversion)"
  echo "Kernel:  $(uname -r)"
  echo "Uptime: $(uptime)"
  echo
  free -h
  if is_clustered; then
    echo
    echo "=== Cluster ==="
    pvecm status
  fi
  echo
  echo "=== Package versions ==="
  pveversion -v
}

# --- LXC updates -------------------------------------------------------------------

# Update command for a container, chosen from its /etc/os-release ID / ID_LIKE.
lxc_update_cmd() {
  local os word
  # shellcheck disable=SC2016 # expanded inside the container
  os=$(pct exec "$1" -- sh -c '. /etc/os-release 2>/dev/null; echo "$ID $ID_LIKE"' 2>/dev/null)
  for word in $os; do
    case $word in
      debian | ubuntu | devuan | kali)
        echo 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold dist-upgrade'
        return ;;
      alpine)                      echo 'apk -U upgrade'; return ;;
      fedora | rhel | centos | rocky | almalinux)
        echo 'if command -v dnf >/dev/null; then dnf -y upgrade; else yum -y update; fi'; return ;;
      arch | archlinux)            echo 'pacman -Syu --noconfirm'; return ;;
      opensuse* | suse | sles)     echo 'zypper -n up'; return ;;
    esac
  done
  return 1
}

lxc_update_all() {
  local out id cmd
  local -a ids ok=() failed=() skipped=()
  out=$(ui_pick_guests checklist lxc running "Update containers") || return
  mapfile -t ids <<<"$out"

  ui_terminal "Update containers"
  for id in "${ids[@]}"; do
    msg_title "CT $id ($(guest_name "$id"))"
    if ! cmd=$(lxc_update_cmd "$id"); then
      msg_warn "Unknown distribution, skipping."
      skipped+=("$id")
      continue
    fi
    if run pct exec "$id" -- sh -c "$cmd"; then
      ok+=("$id")
    else
      msg_error "Update failed."
      failed+=("$id")
    fi
  done

  msg_title "Summary"
  msg_ok   "Updated: ${ok[*]:-none}"
  ((${#skipped[@]})) && msg_warn  "Skipped: ${skipped[*]}"
  ((${#failed[@]}))  && msg_error "Failed:  ${failed[*]}"
  pause
}

apt_cleanup() {
  ui_yesno "APT cleanup" "Run 'apt-get autoremove --purge' and 'apt-get clean'?" || return
  ui_terminal "APT cleanup"
  run apt-get -y autoremove --purge
  run apt-get clean
  msg_ok "APT cache cleaned."
  pause
}

maintenance_menu() {
  local choice
  while true; do
    choice=$(ui_menu "System maintenance" "Node: $PVE_NODE" \
      kernels "Remove old kernels" \
      storage "Storage & disk health" \
      node    "Node / cluster info" \
      lxcupd  "Update packages inside containers" \
      aptcln  "APT autoremove & clean" \
      back    "Back") || return
    case $choice in
      kernels) kernel_cleanup ;;
      storage) ui_cmd_output "Storage & disk health" storage_report ;;
      node)    ui_cmd_output "Node info" node_report ;;
      lxcupd)  lxc_update_all ;;
      aptcln)  apt_cleanup ;;
      back)    return ;;
    esac
  done
}
