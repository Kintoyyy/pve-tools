# shellcheck shell=bash
# Post-install setup: repositories, subscription nag, HA services, upgrade.

APT_DIR=/etc/apt/sources.list.d
PROXMOX_KEYRING=/usr/share/keyrings/proxmox-archive-keyring.gpg
NAG_SCRIPT=/usr/local/sbin/pve-tools-nag-patch
NAG_HOOK=/etc/apt/apt.conf.d/99-pve-tools-nag

# apt_repo_enabled <regex> — true if an enabled .list line or .sources stanza file matches.
apt_repo_enabled() {
  local pat=$1 f
  grep -Eqs "^[[:space:]]*deb[[:space:]].*$pat" /etc/apt/sources.list "$APT_DIR"/*.list && return 0
  for f in "$APT_DIR"/*.sources; do
    [[ -f $f ]] || continue
    grep -Eqs -- "$pat" "$f" || continue
    grep -Eqis '^Enabled:[[:space:]]*(no|false)' "$f" && continue
    return 0
  done
  return 1
}

# Ceph release to use: existing repo > installed ceph > default for this PVE major.
ceph_release() {
  local rel
  rel=$(grep -Ehos 'ceph-[a-z]+' "$APT_DIR"/*.list "$APT_DIR"/*.sources 2>/dev/null | head -n1)
  if [[ -n $rel ]]; then echo "${rel#ceph-}"; return; fi
  if command -v ceph >/dev/null 2>&1; then
    # "ceph version 18.2.4 (...) reef (stable)"
    rel=$(ceph --version 2>/dev/null | awk '{print $(NF-1)}')
    [[ -n $rel ]] && { echo "$rel"; return; }
  fi
  case $PVE_MAJOR in
    7) echo quincy ;;
    8) echo reef ;;
    *) echo squid ;;
  esac
}

# Step title with a "[n/total]" counter; PI_STEP/PI_TOTAL are set by postinstall_menu.
pi_title() { msg_title "[${PI_STEP:-1}/${PI_TOTAL:-1}] $*"; }

pi_disable_enterprise() {
  local f found=0
  pi_title "Disable enterprise repositories"
  for f in "$APT_DIR"/*.list "$APT_DIR"/*.sources; do
    grep -qs 'enterprise.proxmox.com' "$f" || continue
    found=1
    backup_file "$f"
    if [[ $f == *.sources ]]; then
      # deb822: (re)write an "Enabled: false" line into every stanza.
      run sed -i -e '/^Enabled:/d' -e '/^Types:/a Enabled: false' "$f"
    else
      run sed -i -E 's/^([[:space:]]*)deb[[:space:]]/# deb /' "$f"
    fi
    msg_ok "Disabled $f"
  done
  ((found)) || msg_info "No enterprise repositories found."
}

pi_add_no_subscription() {
  pi_title "Add pve-no-subscription repository"
  if apt_repo_enabled 'pve-no-subscription'; then
    msg_ok "pve-no-subscription is already enabled."
    return
  fi
  if [[ $APT_FORMAT == deb822 ]]; then
    write_file "$APT_DIR/proxmox.sources" <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: $DEB_CODENAME
Components: pve-no-subscription
Signed-By: $PROXMOX_KEYRING
EOF
  else
    write_file "$APT_DIR/pve-no-subscription.list" <<EOF
deb http://download.proxmox.com/debian/pve $DEB_CODENAME pve-no-subscription
EOF
  fi
  msg_ok "Added pve-no-subscription for $DEB_CODENAME."
}

pi_add_ceph_no_subscription() {
  local rel
  rel=$(ceph_release)
  pi_title "Add Ceph $rel no-subscription repository"
  if apt_repo_enabled "download.proxmox.com/debian/ceph-$rel"; then
    msg_ok "Ceph $rel no-subscription is already enabled."
    return
  fi
  if [[ $APT_FORMAT == deb822 ]]; then
    write_file "$APT_DIR/ceph-no-subscription.sources" <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/ceph-$rel
Suites: $DEB_CODENAME
Components: no-subscription
Signed-By: $PROXMOX_KEYRING
EOF
  else
    write_file "$APT_DIR/ceph-no-subscription.list" <<EOF
deb http://download.proxmox.com/debian/ceph-$rel $DEB_CODENAME no-subscription
EOF
  fi
  msg_ok "Added Ceph $rel no-subscription."
}

pi_remove_nag() {
  pi_title "Remove subscription nag"
  # Patch script is idempotent; the apt hook re-applies it after widget-toolkit upgrades.
  write_file "$NAG_SCRIPT" 0755 <<'EOF'
#!/bin/sh
# Installed by pve-tools: removes the "No valid subscription" dialog from the web UI.
JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
[ -s "$JS" ] || exit 0
grep -q NoMoreNagging "$JS" && exit 0
sed -E -i "s/(data\.status\.toLowerCase\(\)[[:space:]]*)!==[[:space:]]*(['\"])active(['\"])/\1== \2NoMoreNagging\3/" "$JS"
grep -q NoMoreNagging "$JS" || echo "pve-tools: subscription check not found in $JS (UI changed?)" >&2
exit 0
EOF
  msg_ok "Installed patch script $NAG_SCRIPT"
  write_file "$NAG_HOOK" <<EOF
DPkg::Post-Invoke { "if [ -x $NAG_SCRIPT ]; then $NAG_SCRIPT; fi"; };
EOF
  msg_ok "Installed apt hook $NAG_HOOK (re-applies the patch after upgrades)"
  msg_info "Patching proxmoxlib.js..."
  run "$NAG_SCRIPT"
  # Reload, not restart: a restart drops open connections, which kills the web UI
  # shell this script may be running in. Reload leaves existing connections alone.
  msg_info "Reloading pveproxy..."
  run systemctl reload pveproxy.service
  msg_ok "Subscription nag removed. Clear your browser cache (Ctrl+Shift+R) to see it."
}

pi_disable_ha() {
  pi_title "Disable HA services"
  if is_clustered; then
    msg_warn "This node is part of a cluster; leaving HA/corosync alone."
    return
  fi
  run systemctl disable --now pve-ha-lrm.service pve-ha-crm.service corosync.service
  msg_ok "Disabled pve-ha-lrm, pve-ha-crm and corosync."
}

pi_upgrade() {
  pi_title "Upgrade system"
  run apt-get update || { msg_error "apt-get update failed; check your repositories."; return 1; }
  # Progress-Fancy draws apt's "Progress: [ 42%]" bar at the bottom of the terminal.
  run env DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Progress-Fancy=1 \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade
}

# True when a newer kernel than the running one is installed.
kernel_reboot_needed() {
  local newest
  newest=$(find /boot -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' 2>/dev/null | sed 's/^vmlinuz-//' | sort -V | tail -n1)
  [[ -n $newest && $newest != "$(uname -r)" ]]
}

postinstall_menu() {
  local -a items steps
  local out step PI_STEP=0 PI_TOTAL

  items=(
    enterprise "Disable enterprise repositories"            ON
    nosub      "Enable pve-no-subscription repository"      ON
    ceph       "Enable Ceph no-subscription repository"     ON
    nag        "Remove subscription nag from the web UI"    ON
  )
  is_clustered || items+=(ha "Disable HA services (standalone node only)" OFF)
  items+=(upgrade "apt update && dist-upgrade" ON)

  out=$(ui_checklist "Post-install setup" \
    "Proxmox VE $PVE_VERSION ($DEB_CODENAME). Select the steps to run:" "${items[@]}") || return
  mapfile -t steps <<<"$out"

  if [[ " ${steps[*]} " == *" ha "* ]] &&
    ! ui_confirm "Disable HA" "Disabling HA stops pve-ha-lrm, pve-ha-crm and corosync.\nOnly do this on a standalone node you will not join to a cluster.\n\nContinue?"; then
    mapfile -t steps < <(printf '%s\n' "${steps[@]}" | grep -vx ha)
  fi
  PI_TOTAL=${#steps[@]}

  ui_terminal "Post-install setup"
  for step in "${steps[@]}"; do
    ((++PI_STEP))
    case $step in
      enterprise) pi_disable_enterprise ;;
      nosub)      pi_add_no_subscription ;;
      ceph)       pi_add_ceph_no_subscription ;;
      nag)        pi_remove_nag ;;
      ha)         pi_disable_ha ;;
      upgrade)    pi_upgrade ;;
    esac
  done
  msg_ok "Post-install steps finished."
  pause

  if ! is_dry_run && kernel_reboot_needed &&
    ui_yesno "Reboot" "A newer kernel is installed than the one running ($(uname -r)).\n\nReboot now?"; then
    run reboot
  fi
}
