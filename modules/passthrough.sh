# shellcheck shell=bash
# PCIe passthrough: IOMMU kernel params (GRUB or systemd-boot), VFIO modules,
# vfio-pci binding (per-device / per-ID / blacklist), EFI + proxmox-boot-tool
# repair, driver recovery (ixgbe & friends) and HPE RMRR slot exclusion.
# Ported from pve-passthrough.sh; file names are kept so existing setups are recognised.

PT_VFIO_CONF=/etc/modprobe.d/pve-passthrough-vfio.conf
PT_BLACKLIST_CONF=/etc/modprobe.d/pve-passthrough-blacklist.conf
PT_UNSAFE_CONF=/etc/modprobe.d/pve-passthrough-unsafe-irq.conf
PT_IXGBE_CONF=/etc/modprobe.d/pve-passthrough-ixgbe.conf
PT_ESP_GUID=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
PT_HPE_DIR=/root/hpe-rmrr
PT_HPE_XML_URL="https://downloads.hpe.com/pub/softlib2/software1/pubsw-linux/p1472592088/v95853/conrep_rmrds.xml"

# Set when a change needs an initramfs rebuild, bootloader refresh or reboot.
PT_PENDING_INITRAMFS=0
PT_PENDING_BOOT=0
PT_PENDING_REBOOT=0

# --- detection ------------------------------------------------------------------

# Sets PT_CPU (intel|amd|unknown), PT_FW (uefi|legacy), PT_BOOT (grub|systemd-boot), PT_KVER.
pt_detect() {
  PT_CPU=unknown
  grep -q GenuineIntel /proc/cpuinfo && PT_CPU=intel
  grep -q AuthenticAMD /proc/cpuinfo && PT_CPU=amd
  if [[ -d /sys/firmware/efi ]]; then PT_FW=uefi; else PT_FW=legacy; fi
  PT_BOOT=grub
  if [[ -f /etc/kernel/cmdline ]] && command -v proxmox-boot-tool >/dev/null 2>&1 &&
    proxmox-boot-tool status 2>/dev/null | grep -Eq 'configured with: uefi|systemd-boot'; then
    PT_BOOT=systemd-boot
  fi
  PT_KVER=$(uname -r)
}

pt_kernel_ge_62() {
  local maj=${PT_KVER%%.*} min
  min=$(cut -d. -f2 <<<"$PT_KVER")
  ((maj > 6 || (maj == 6 && min >= 2)))
}

pt_has_iommu() { find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 2>/dev/null | grep -q .; }

pt_kparams_file() { [[ $PT_BOOT == systemd-boot ]] && echo /etc/kernel/cmdline || echo /etc/default/grub; }

pt_kparams_get() {
  if [[ $PT_BOOT == systemd-boot ]]; then
    tr -s ' \n' ' ' </etc/kernel/cmdline | sed 's/ *$//'
  else
    sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/\1/p' /etc/default/grub | tail -n1
  fi
}

pt_kparams_set() {
  local v=$1 f e
  f=$(pt_kparams_file)
  if [[ $PT_BOOT == systemd-boot ]]; then
    write_file "$f" <<<"$v"
  elif grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$f"; then
    backup_file "$f"
    e=${v//&/\\&}; e=${e//|/\\|}
    run sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$e\"|" "$f"
  else
    append_line "$f" "GRUB_CMDLINE_LINUX_DEFAULT=\"$v\""
  fi
}

# pt_kparam_compute "<cmdline>" +key=val -key ... — print the edited cmdline.
# "+k=v" replaces any token with the same key; "-k" removes it.
pt_kparam_compute() {
  local -a toks out
  local op key tok
  read -ra toks <<<"$1"; shift
  for op in "$@"; do
    key=${op:1}; key=${key%%=*}
    out=()
    for tok in "${toks[@]}"; do [[ ${tok%%=*} == "$key" ]] || out+=("$tok"); done
    [[ ${op:0:1} == + ]] && out+=("${op:1}")
    toks=("${out[@]}")
  done
  echo "${toks[*]}"
}

# --- PCI inventory ----------------------------------------------------------------

pt_dev_driver() {
  if [[ -e /sys/bus/pci/devices/$1/driver ]]; then
    basename "$(readlink -f "/sys/bus/pci/devices/$1/driver")"
  else
    echo none
  fi
}

pt_dev_group() {
  if [[ -e /sys/bus/pci/devices/$1/iommu_group ]]; then
    basename "$(readlink -f "/sys/bus/pci/devices/$1/iommu_group")"
  else
    echo -
  fi
}

pt_dev_module() { lspci -ks "$1" | sed -n 's/.*Kernel modules: //p' | cut -d, -f1 | tr -d ' '; }
pt_is_bridge()  { [[ $1 == 06* ]]; }
pt_is_bound()   { [[ $(pt_dev_driver "$1") == "$2" ]]; }

# Fill parallel arrays PT_BDF / PT_IDS / PT_CLS / PT_DESC / PT_DRV / PT_GRP from lspci -Dnn.
pt_pci_scan() {
  PT_BDF=() PT_IDS=() PT_CLS=() PT_DESC=() PT_DRV=() PT_GRP=()
  local line bdf
  while IFS= read -r line; do
    bdf=${line%% *}
    PT_BDF+=("$bdf")
    PT_CLS+=("$(sed -n 's/^[^ ]* [^[]*\[\([0-9a-f]\{4\}\)\]:.*/\1/p' <<<"$line")")
    PT_IDS+=("$(grep -o '\[[0-9a-f]\{4\}:[0-9a-f]\{4\}\]' <<<"$line" | tail -n1 | tr -d '[]')")
    PT_DESC+=("$(sed -e 's/^[^ ]* //' -e 's/ \[[0-9a-f]\{4\}:[0-9a-f]\{4\}\].*$//' \
      -e 's/ \[[0-9a-f]\{4\}\]:/:/' -e 's/ Corporation//' <<<"$line")")
    PT_DRV+=("$(pt_dev_driver "$bdf")")
    PT_GRP+=("$(pt_dev_group "$bdf")")
  done < <(lspci -Dnn)
}

pt_pci_idx() {
  local i
  for i in "${!PT_BDF[@]}"; do
    [[ ${PT_BDF[$i]} == "$1" ]] && { echo "$i"; return 0; }
  done
  return 1
}

# Does this PCI device carry host IP traffic (directly, or via bond/bridge)?
pt_mgmt_nic() {
  local n cur _
  for n in /sys/bus/pci/devices/"$1"/net/*; do
    [[ -e $n ]] || continue
    n=${n##*/}; cur=$n
    for _ in 1 2 3 4; do
      if ip -4 -o addr show dev "$cur" 2>/dev/null | grep -q inet; then
        if [[ $cur == "$n" ]]; then echo "$n"; else echo "$n -> $cur"; fi
        return 0
      fi
      [[ -e /sys/class/net/$cur/master ]] || break
      cur=$(basename "$(readlink -f "/sys/class/net/$cur/master")")
    done
  done
  return 1
}

pt_sysfs_write() { # <value> <path>
  _log SYSFS "'$1' > $2"
  if is_dry_run; then
    printf '%s[dry-run]%s echo %q > %s\n' "$C_YELLOW" "$C_RESET" "$1" "$2"
    return 0
  fi
  echo "$1" >"$2"
}

# --- status ---------------------------------------------------------------------------

pt_status_report() {
  pt_detect
  local groups irq vfio unsafe x i
  groups=$(find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
  irq=$(dmesg 2>/dev/null | grep -Eo 'DMAR-IR: Enabled IRQ remapping[^]]*|AMD-Vi: Interrupt remapping enabled' | head -n1)
  vfio=$(lsmod 2>/dev/null | awk '/^vfio/ {print $1}' | xargs)
  unsafe=$(cat /sys/module/vfio_iommu_type1/parameters/allow_unsafe_interrupts 2>/dev/null || echo n/a)

  echo "Host             : $(hostname)  $(pveversion 2>/dev/null | head -n1)"
  echo "CPU vendor       : $PT_CPU"
  echo "Firmware         : $PT_FW"
  echo "Bootloader       : $PT_BOOT   (params in $(pt_kparams_file))"
  echo "Kernel           : $PT_KVER"
  echo "Running cmdline  : $(cat /proc/cmdline)"
  echo "Configured params: $(pt_kparams_get)"
  if ((groups > 0)); then echo "IOMMU            : ACTIVE ($groups groups)"; else echo "IOMMU            : NOT active"; fi
  echo "IRQ remapping    : ${irq:-not reported (consider unsafe interrupts)}"
  echo "VFIO modules     : ${vfio:-none loaded}"
  echo "Unsafe interrupts: $unsafe"
  if dmesg 2>/dev/null | grep -q 'RMRRs are relaxable'; then
    echo "relax_rmrr       : ACTIVE"
  elif grep -q relax_rmrr /proc/cmdline; then
    echo "relax_rmrr       : on cmdline but NOT active (kernel not patched?)"
  else
    echo "relax_rmrr       : off"
  fi
  x=$(dmesg 2>/dev/null | grep -ci 'ineligible.*RMRR')
  echo "RMRR ineligible  : $x message(s)"
  x=$(dmesg 2>/dev/null | grep -ci 'unsupported SFP')
  ((x)) && echo "Unsupported SFP  : $x message(s) — see 'Recover a device with no driver'"
  echo

  pt_pci_scan
  echo "Devices on vfio-pci:"
  x=0
  for i in "${!PT_BDF[@]}"; do
    [[ ${PT_DRV[$i]} == vfio-pci ]] || continue
    echo "  ${PT_BDF[$i]} [${PT_IDS[$i]}] g${PT_GRP[$i]} ${PT_DESC[$i]}"; x=1
  done
  ((x)) || echo "  (none)"
  echo "Devices with NO driver:"
  x=0
  for i in "${!PT_BDF[@]}"; do
    pt_is_bridge "${PT_CLS[$i]}" && continue
    [[ ${PT_DRV[$i]} == none ]] || continue
    echo "  ${PT_BDF[$i]} [${PT_IDS[$i]}] ${PT_DESC[$i]}"; x=1
  done
  ((x)) || echo "  (none)"
  if command -v driverctl >/dev/null 2>&1; then
    echo "driverctl overrides:"
    driverctl list-overrides 2>/dev/null | sed 's/^/  /'
  fi
  for x in "$PT_VFIO_CONF" "$PT_BLACKLIST_CONF" "$PT_UNSAFE_CONF" "$PT_IXGBE_CONF"; do
    [[ -f $x ]] && { echo; echo "--- $x"; cat "$x"; }
  done
  echo
  echo "Pending (this session): initramfs=$PT_PENDING_INITRAMFS bootloader=$PT_PENDING_BOOT reboot=$PT_PENDING_REBOOT"
  echo "Session backups  : $PVE_TOOLS_SESSION_DIR"
}

# --- IOMMU kernel parameters ------------------------------------------------------------

pt_setup_iommu() {
  local title="Enable IOMMU" cur pt=ON acs=OFF rr=OFF sel old new
  local -a opts ops=()
  pt_detect
  if [[ $PT_CPU == unknown ]]; then
    ui_msg "$title" "Could not detect an Intel or AMD CPU. Aborting."
    return
  fi
  [[ $PT_FW == legacy ]] &&
    ui_msg "$title" "Note: the host booted in Legacy/CSM mode. Passthrough works best with UEFI; consider switching in the BIOS."

  cur=" $(pt_kparams_get) "
  [[ $cur == *" iommu="* && $cur != *" iommu=pt "* ]] && pt=OFF
  [[ $cur == *"pcie_acs_override="* ]] && acs=ON
  [[ $cur == *relax_rmrr* ]] && rr=ON
  opts=(pt  "iommu=pt  (passthrough mode, recommended)" "$pt"
        acs "pcie_acs_override  (split IOMMU groups; weakens isolation)" "$acs")
  [[ $PT_CPU == intel ]] && opts+=(rmrr "relax_rmrr  (ONLY with a relaxable-RMRR patched kernel)" "$rr")

  sel=$(UI_ALLOW_EMPTY=1 ui_checklist "$title" \
    "CPU: $PT_CPU   Bootloader: $PT_BOOT\n${PT_CPU}_iommu=on is always set. Choose extras:" "${opts[@]}") || return
  sel=$'\n'"$sel"$'\n'

  if [[ $PT_CPU == intel ]]; then
    if [[ $sel == *$'\n'rmrr$'\n'* ]]; then ops+=("+intel_iommu=on,relax_rmrr"); else ops+=("+intel_iommu=on"); fi
  else
    ops+=("+amd_iommu=on")
  fi
  if [[ $sel == *$'\n'pt$'\n'* ]]; then ops+=("+iommu=pt"); else ops+=("-iommu"); fi
  if [[ $sel == *$'\n'acs$'\n'* ]]; then ops+=("+pcie_acs_override=downstream,multifunction"); else ops+=("-pcie_acs_override"); fi

  old=$(pt_kparams_get)
  new=$(pt_kparam_compute "$old" "${ops[@]}")
  if [[ $old == "$new" ]]; then
    ui_msg "$title" "Kernel parameters are already set:\n\n$new"
  elif ui_yesno "$title" "File: $(pt_kparams_file)\n\nBefore:\n  $old\n\nAfter:\n  $new\n\nWrite this change?"; then
    pt_kparams_set "$new" >/dev/null
    PT_PENDING_BOOT=1 PT_PENDING_REBOOT=1
  else
    return
  fi
  ui_yesno "$title" "Also add the VFIO modules to /etc/modules (needed for passthrough)?" &&
    pt_ensure_vfio_modules quiet
  ui_msg "$title" "Done. Use 'Apply changes' from the passthrough menu, then reboot."
}

# --- VFIO modules -------------------------------------------------------------------------

pt_ensure_vfio_modules() {
  local -a mods=(vfio vfio_iommu_type1 vfio_pci)
  local m
  pt_detect
  pt_kernel_ge_62 || mods+=(vfio_virqfd) # merged into vfio since 6.2
  {
    for m in "${mods[@]}"; do append_line /etc/modules "$m"; done
    if pt_kernel_ge_62 && grep -qx vfio_virqfd /etc/modules 2>/dev/null; then
      backup_file /etc/modules
      run sed -i '/^vfio_virqfd$/d' /etc/modules
    fi
  } >/dev/null
  PT_PENDING_INITRAMFS=1
  [[ ${1:-} == quiet ]] ||
    ui_msg "VFIO modules" "VFIO modules ensured in /etc/modules:\n\n  ${mods[*]}\n\nRebuild the initramfs via 'Apply changes'."
}

# --- bind devices to vfio-pci -------------------------------------------------------------

pt_bind_devices() {
  local title="Bind devices" i st d out warn="" gwarn="" b n g dv cls method
  local -a items=() sel
  local -A seen=()

  pt_detect
  pt_pci_scan
  if ! pt_has_iommu; then
    ui_yesno "$title" "IOMMU is not active yet (no IOMMU groups). Bindings can still be prepared; they take effect once IOMMU is enabled and you reboot.\n\nContinue?" || return
  fi

  _ui_size
  for i in "${!PT_BDF[@]}"; do
    pt_is_bridge "${PT_CLS[$i]}" && continue
    st=OFF; [[ ${PT_DRV[$i]} == vfio-pci ]] && st=ON
    d="g${PT_GRP[$i]} ${PT_DESC[$i]} (${PT_DRV[$i]})"
    items+=("${PT_BDF[$i]}" "${d:0:$((UI_W - 26))}" "$st")
  done
  out=$(ui_checklist "$title" "Select device(s) to reserve for VMs (space to toggle):" "${items[@]}") || return
  mapfile -t sel <<<"$out"

  # Safety: a selected NIC that carries the host's own IP traffic.
  for b in "${sel[@]}"; do
    n=$(pt_mgmt_nic "$b") && warn+="  $b carries host IP traffic ($n)\n"
  done
  if [[ -n $warn ]]; then
    ui_confirm "!! DANGER !!" "${warn}\nBinding it to vfio-pci will cut host networking (you may lose SSH and the web UI).\n\nContinue anyway?" || return
  fi

  # Safety: other members of the same IOMMU group.
  for b in "${sel[@]}"; do
    g=$(pt_dev_group "$b")
    [[ $g == - || -n ${seen[$g]:-} ]] && continue
    seen[$g]=1
    for dv in /sys/kernel/iommu_groups/"$g"/devices/*; do
      dv=${dv##*/}
      [[ " ${sel[*]} " == *" $dv "* ]] && continue
      cls=$(cat "/sys/bus/pci/devices/$dv/class" 2>/dev/null)
      [[ $cls == 0x06* ]] && continue
      gwarn+="  group $g: $dv $(lspci -s "$dv" | cut -d' ' -f2-)\n"
    done
  done
  if [[ -n $gwarn ]]; then
    ui_yesno "$title" "These devices share an IOMMU group with your selection and must go to the same VM (or use ACS override):\n\n${gwarn}\nContinue?" || return
  fi

  method=$(ui_menu "$title" "How should the host release these devices?" \
    driverctl "Per-device override by PCI address (recommended)" \
    ids       "vfio-pci ids= by vendor:device (hits ALL identical cards)" \
    blacklist "Blacklist host driver (hits EVERY device on that driver)" \
    none      "No host change; Proxmox rebinds at VM start") || return

  case $method in
    none)
      ui_msg "$title" "OK. Proxmox detaches the device and binds vfio-pci automatically when the VM starts.\nOnly pre-bind if the host driver misbehaves (crashes, won't release, GPU console, etc.)."
      ;;
    driverctl)
      ui_terminal "Binding via driverctl"
      if ! command -v driverctl >/dev/null 2>&1; then
        run apt-get install -y driverctl || { pause; return; }
      fi
      for b in "${sel[@]}"; do
        run driverctl set-override "$b" vfio-pci && manifest_add driverctl "$b"
      done
      pt_ensure_vfio_modules quiet
      PT_PENDING_REBOOT=1
      echo
      for b in "${sel[@]}"; do echo "  $b -> $(pt_dev_driver "$b")"; done
      pause
      ;;
    ids | blacklist)
      pt_bind_by_config "$method" "${sel[@]}"
      ;;
  esac
}

# pt_bind_by_config <ids|blacklist> <bdf>... — write a modprobe.d file that frees the devices.
pt_bind_by_config() {
  local method=$1 b ix drv i collateral="" content conf
  shift
  local -a sel=("$@")
  local -A IDS=() DRV=()

  for b in "${sel[@]}"; do
    ix=$(pt_pci_idx "$b")
    IDS[${PT_IDS[$ix]}]=1
    drv=${PT_DRV[$ix]}
    [[ $drv == none || $drv == vfio-pci ]] && drv=$(pt_dev_module "$b")
    [[ -n $drv && $drv != vfio-pci ]] && DRV[$drv]=1
  done

  for i in "${!PT_BDF[@]}"; do
    [[ " ${sel[*]} " == *" ${PT_BDF[$i]} "* ]] && continue
    if [[ $method == ids && -n ${IDS[${PT_IDS[$i]}]:-} ]] ||
      [[ $method == blacklist && -n ${DRV[${PT_DRV[$i]}]:-} ]]; then
      collateral+="  ${PT_BDF[$i]} ${PT_DESC[$i]} (${PT_DRV[$i]})\n"
    fi
  done
  if [[ -n $collateral ]]; then
    ui_confirm "Bind devices" "These UNSELECTED devices will ALSO be taken from the host:\n\n${collateral}\nUse 'driverctl' instead to bind by PCI address.\n\nContinue anyway?" || return
  fi

  content="# Managed by pve-tools — $(date '+%F %T')"
  if [[ $method == ids ]]; then
    content+=$'\n'"options vfio-pci ids=$(IFS=,; echo "${!IDS[*]}")"
    for drv in "${!DRV[@]}"; do content+=$'\n'"softdep $drv pre: vfio-pci"; done
    conf=$PT_VFIO_CONF
  else
    if ((${#DRV[@]} == 0)); then
      ui_msg "Bind devices" "No host driver found to blacklist."
      return
    fi
    for drv in "${!DRV[@]}"; do content+=$'\n'"blacklist $drv"; done
    conf=$PT_BLACKLIST_CONF
  fi
  write_file "$conf" <<<"$content" >/dev/null
  pt_ensure_vfio_modules quiet
  PT_PENDING_INITRAMFS=1 PT_PENDING_REBOOT=1
  ui_msg "Bind devices" "Written to $conf:\n\n$content\n\nRun 'Apply changes' and reboot."
}

# --- unsafe interrupts ------------------------------------------------------------------------

pt_toggle_unsafe() {
  local title="Unsafe interrupts"
  if [[ -f $PT_UNSAFE_CONF ]]; then
    ui_yesno "$title" "Unsafe interrupts are ENABLED ($PT_UNSAFE_CONF).\n\nDisable them?" || return
    remove_file "$PT_UNSAFE_CONF" >/dev/null
  else
    ui_confirm "$title" "Enable allow_unsafe_interrupts=1?\n\nOnly needed when the platform lacks interrupt remapping (dmesg shows no IRQ remapping and VM start fails with interrupt errors). It weakens isolation between VM and host.\n\nEnable?" || return
    write_file "$PT_UNSAFE_CONF" <<<"options vfio_iommu_type1 allow_unsafe_interrupts=1" >/dev/null
  fi
  PT_PENDING_INITRAMFS=1 PT_PENDING_REBOOT=1
  ui_msg "$title" "Updated. Run 'Apply changes' and reboot."
}

# --- IOMMU groups -------------------------------------------------------------------------------

pt_groups_report() {
  local g d
  for g in $(find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 -printf '%f\n' | sort -n); do
    echo "Group $g:"
    for d in /sys/kernel/iommu_groups/"$g"/devices/*; do
      d=${d##*/}
      echo "    $(lspci -Dnns "$d")  {$(pt_dev_driver "$d")}"
    done
  done
}

pt_show_groups() {
  if ! pt_has_iommu; then
    ui_msg "IOMMU groups" "No IOMMU groups: IOMMU is not active.\nEnable VT-d/AMD-Vi in the BIOS and use 'Enable IOMMU'."
    return
  fi
  ui_cmd_output "IOMMU groups" pt_groups_report
}

# --- EFI boot / proxmox-boot-tool -----------------------------------------------------------------

pt_fix_efi() {
  local title="Fix EFI boot" st l esp mp NAME PARTTYPE SIZE MOUNTPOINT UUID
  local -a items=()
  pt_detect
  if [[ $PT_FW != uefi ]]; then
    ui_msg "$title" "The host booted in Legacy/CSM mode (/sys/firmware/efi is missing).\n\nReboot into the BIOS, set Boot Mode = UEFI Only and disable CSM, then re-run."
    return
  fi
  if ! command -v proxmox-boot-tool >/dev/null 2>&1; then
    ui_msg "$title" "proxmox-boot-tool not found."
    return
  fi

  if [[ $PT_BOOT == grub ]] && dpkg -s grub-pc >/dev/null 2>&1 && ! dpkg -s grub-efi-amd64 >/dev/null 2>&1; then
    if ui_yesno "$title" "The system booted in UEFI mode but 'grub-pc' (BIOS) is installed.\n\nReplace it with 'grub-efi-amd64'?"; then
      ui_terminal "Installing grub-efi-amd64"
      run apt-get install -y grub-efi-amd64
      pause
    fi
  fi

  st=$(proxmox-boot-tool status 2>&1)
  if grep -q 'proxmox-boot-uuids does not exist' <<<"$st"; then
    while read -r l; do
      NAME="" PARTTYPE="" SIZE="" MOUNTPOINT="" UUID=""
      eval "$l" # lsblk -P prints shell-quoted KEY="value" pairs
      [[ ${PARTTYPE,,} == "$PT_ESP_GUID" ]] || continue
      items+=("$NAME" "$SIZE uuid=$UUID ${MOUNTPOINT:+[mounted $MOUNTPOINT]}")
    done < <(lsblk -pPno NAME,PARTTYPE,SIZE,MOUNTPOINT,UUID)
    if ((${#items[@]} == 0)); then
      ui_msg "$title" "No EFI System Partition found (GPT type $PT_ESP_GUID)."
      return
    fi
    esp=$(ui_menu "$title" "/etc/kernel/proxmox-boot-uuids is missing.\nSelect the ESP to initialize (verify the UUID with blkid!):" "${items[@]}") || return
    mp=$(lsblk -no MOUNTPOINT "$esp" | head -n1)
    if [[ -n $mp ]]; then
      ui_yesno "$title" "$esp is mounted on $mp. proxmox-boot-tool refuses to initialize a mounted ESP.\n\nUnmount it and comment out its /etc/fstab entry?" || return
      ui_terminal "Releasing $esp"
      if ! run umount "$mp" && ! run umount -l "$mp"; then
        echo "Could not unmount. Blockers:"
        fuser -vm "$mp"
        pause
        return
      fi
      backup_file /etc/fstab
      run sed -i "\|[[:space:]]${mp}[[:space:]]|s|^\([^#]\)|#\1|" /etc/fstab
    else
      ui_terminal "$title"
    fi
    msg_title "proxmox-boot-tool init $esp"
    if [[ $PT_BOOT == grub ]]; then
      run proxmox-boot-tool init "$esp" grub
    else
      run proxmox-boot-tool init "$esp"
    fi
  else
    ui_terminal "$title"
  fi
  msg_title "proxmox-boot-tool refresh"
  run proxmox-boot-tool refresh
  msg_title "Status"
  proxmox-boot-tool status
  pause
}

# --- recover a device with no driver ------------------------------------------------------------------

pt_nic_rebind() {
  local title="Recover device" i bdf ix ids drv bl f
  local -a items=()
  pt_pci_scan
  for i in "${!PT_BDF[@]}"; do
    pt_is_bridge "${PT_CLS[$i]}" && continue
    [[ ${PT_DRV[$i]} == none ]] && items+=("${PT_BDF[$i]}" "[${PT_IDS[$i]}] ${PT_DESC[$i]:0:70}")
  done
  if ((${#items[@]} == 0)); then
    ui_msg "$title" "Every non-bridge PCI device has a driver bound. Nothing to recover."
    return
  fi
  bdf=$(ui_menu "$title" "Devices with NO driver in use:" "${items[@]}") || return
  ix=$(pt_pci_idx "$bdf"); ids=${PT_IDS[$ix]}
  drv=$(ui_input "$title" "Driver to bind for $bdf [$ids]:" "$(pt_dev_module "$bdf")") || return
  [[ -n $drv ]] || return

  if command -v driverctl >/dev/null 2>&1 && driverctl list-overrides 2>/dev/null | grep -q "^$bdf"; then
    ui_yesno "$title" "$bdf has a driverctl override (probably vfio-pci for passthrough).\n\nRemove it?" &&
      run driverctl unset-override "$bdf" >/dev/null
  fi
  bl=$(grep -rlsE "^[[:space:]]*blacklist[[:space:]]+$drv([[:space:]]|$)" /etc/modprobe.d/ || true)
  if [[ -n $bl ]] &&
    ui_yesno "$title" "'$drv' is blacklisted in:\n\n$bl\n\nRemove those blacklist lines? (Needed for the host to use it; NOT if you pass it to a VM.)"; then
    for f in $bl; do
      backup_file "$f"
      run sed -i -E "/^[[:space:]]*blacklist[[:space:]]+$drv([[:space:]]|$)/d" "$f" >/dev/null
    done
    PT_PENDING_INITRAMFS=1
  fi
  if [[ $drv == ixgbe ]] && dmesg 2>/dev/null | grep -qi 'unsupported SFP' &&
    ui_yesno "$title" "dmesg shows 'unsupported SFP+ module', the usual reason an 82599 has no driver.\n\nWrite 'options ixgbe allow_unsupported_sfp=1'?"; then
    write_file "$PT_IXGBE_CONF" <<<"options ixgbe allow_unsupported_sfp=1" >/dev/null
    PT_PENDING_INITRAMFS=1
  fi

  ui_terminal "Recovering $bdf with $drv"
  run modprobe "$drv"
  pt_sysfs_write "$bdf" /sys/bus/pci/drivers_probe 2>/dev/null
  sleep 1
  if ! pt_is_bound "$bdf" "$drv" && [[ -d /sys/bus/pci/drivers/$drv ]]; then
    echo "-> trying new_id ${ids/:/ }"
    pt_sysfs_write "${ids/:/ }" "/sys/bus/pci/drivers/$drv/new_id" 2>/dev/null
    sleep 1
  fi
  if ! pt_is_bound "$bdf" "$drv" && ui_yesno "$title" "Still unbound. Remove $bdf from the PCI bus and rescan?"; then
    pt_sysfs_write 1 "/sys/bus/pci/devices/$bdf/remove"
    sleep 1
    pt_sysfs_write 1 /sys/bus/pci/rescan
    sleep 2
  fi
  if ! pt_is_bound "$bdf" "$drv" &&
    ui_confirm "$title" "Still unbound. Reload the '$drv' module?\n\nWARNING: this drops ALL interfaces using $drv for a few seconds."; then
    run modprobe -r "$drv"
    run modprobe "$drv"
    sleep 2
  fi

  echo
  if is_dry_run; then
    msg_info "Dry run: binding was not attempted."
  elif pt_is_bound "$bdf" "$drv"; then
    msg_ok "$(lspci -ks "$bdf" | grep 'driver in use')"
    find "/sys/bus/pci/devices/$bdf/net" -mindepth 1 -maxdepth 1 -printf '   interface: %f\n' 2>/dev/null
  else
    msg_error "Still no driver. Recent kernel messages:"
    dmesg | grep -iE "$drv|$bdf" | tail -n15
    echo
    echo "Next: try another PCIe slot / SFP+ module, check the BIOS (ASPM, PCIe gen),"
    echo "or reinstall firmware: apt install --reinstall pve-firmware  (NOT linux-firmware on PVE)"
  fi
  pause
}

# --- HPE RMRR exclusion ------------------------------------------------------------------------------

pt_hpe_rmrr() {
  local title="HPE RMRR exclusion" vendor inel i bdf slot k kr=/usr/share/keyrings/hpe-sdr.gpg tmpkr
  local -a items=()
  vendor=$(dmidecode -s system-manufacturer 2>/dev/null || echo unknown)
  if [[ ! $vendor =~ HP ]]; then
    ui_confirm "$title" "System manufacturer: '$vendor'. This tool is for HPE ProLiant servers only.\n\nContinue anyway?" || return
  fi
  inel=$(dmesg 2>/dev/null | grep -i 'ineligible.*RMRR' | tail -n5)

  pt_pci_scan
  for i in "${!PT_BDF[@]}"; do
    pt_is_bridge "${PT_CLS[$i]}" && continue
    items+=("${PT_BDF[$i]}" "${PT_DESC[$i]:0:70}")
  done
  bdf=$(ui_menu "$title" "RMRR messages in dmesg:\n${inel:-  (none)}\n\nDevice to exclude:" "${items[@]}") || return
  slot=$(lspci -vvv -s "$bdf" | sed -n 's/.*Physical Slot: \([0-9]\+\).*/\1/p' | head -n1)
  if [[ -z $slot ]]; then
    ui_msg "$title" "$bdf has no Physical Slot (onboard / FlexibleLOM).\nconrep can only exclude add-in PCIe slots; use relax_rmrr with a patched kernel instead."
    return
  fi

  if ! command -v conrep >/dev/null 2>&1; then
    ui_yesno "$title" "conrep not found. Add the HPE SDR repository and install hp-scripting-tools?" || return
    ui_terminal "Installing hp-scripting-tools"
    if is_dry_run; then
      printf '%s[dry-run]%s fetch HPE SDR signing keys into %s\n' "$C_YELLOW" "$C_RESET" "$kr"
    else
      tmpkr=$(mktemp "$PVE_TOOLS_TMP/hpe.XXXXXX")
      for k in hpPublicKey2048_key1.pub hpePublicKey2048_key1.pub hpPublicKey2048.pub hpPublicKey1024.pub; do
        curl -fsSL "https://downloads.linux.hpe.com/SDR/$k" | gpg --dearmor >>"$tmpkr" 2>/dev/null
      done
      backup_file "$kr"
      install -m 0644 "$tmpkr" "$kr"
    fi
    write_file /etc/apt/sources.list.d/hpe-sdr.list <<<"deb [signed-by=$kr] https://downloads.linux.hpe.com/SDR/repo/stk/ xenial/current non-free"
    if ! { run apt-get update && run apt-get install -y hp-scripting-tools; }; then
      pause
      return
    fi
  else
    ui_terminal "$title"
  fi

  msg_title "Excluding slot $slot from RMRR"
  run mkdir -p "$PT_HPE_DIR"
  if [[ ! -s $PT_HPE_DIR/conrep_rmrds.xml ]]; then
    run curl -fsSL -o "$PT_HPE_DIR/conrep_rmrds.xml" "$PT_HPE_XML_URL" || { pause; return; }
  fi
  write_file "$PT_HPE_DIR/exclude.dat" <<EOF
<Conrep>
  <Section name="RMRDS_Slot${slot}" helptext=".">Endpoints_Excluded</Section>
</Conrep>
EOF
  run conrep -l -x "$PT_HPE_DIR/conrep_rmrds.xml" -f "$PT_HPE_DIR/exclude.dat"
  run conrep -s -x "$PT_HPE_DIR/conrep_rmrds.xml" -f "$PT_HPE_DIR/verify.dat"
  echo
  if grep -q "RMRDS_Slot${slot}\".*Endpoints_Excluded" "$PT_HPE_DIR/verify.dat" 2>/dev/null; then
    msg_ok "Slot $slot excluded. A full power cycle is required."
    PT_PENDING_REBOOT=1
  elif ! is_dry_run; then
    msg_error "Could not verify the exclusion; check $PT_HPE_DIR/verify.dat"
  fi
  pause
}

# --- apply / leave ---------------------------------------------------------------------------------------

pt_apply_changes() {
  pt_detect
  if ((!PT_PENDING_INITRAMFS && !PT_PENDING_BOOT)); then
    ui_yesno "Apply changes" "No pending changes this session. Rebuild the initramfs and bootloader config anyway?" || return
  fi
  ui_terminal "Apply changes"
  msg_title "update-initramfs -u -k all"
  run update-initramfs -u -k all
  if [[ $PT_BOOT == grub ]]; then
    msg_title "update-grub"
    run update-grub
  fi
  if proxmox-boot-tool status >/dev/null 2>&1; then
    msg_title "proxmox-boot-tool refresh"
    run proxmox-boot-tool refresh
  fi
  PT_PENDING_INITRAMFS=0 PT_PENDING_BOOT=0
  pause
  if ((PT_PENDING_REBOOT)) && ui_yesno "Reboot" "Changes applied. Reboot now?"; then
    run reboot
  fi
}

# pt_leave <menu|exit|update> — offer to apply anything still pending. With "exit" (pve-tools is
# quitting) also remind about a pending reboot.
pt_leave() {
  if ((PT_PENDING_INITRAMFS || PT_PENDING_BOOT)); then
    ui_yesno "Pending changes" "You have passthrough changes that aren't applied yet (initramfs/bootloader).\n\nApply them now?" &&
      pt_apply_changes
  elif [[ ${1:-} == exit ]] && ((PT_PENDING_REBOOT)); then
    ui_msg "Reboot needed" "Reminder: reboot to activate the passthrough changes."
  fi
  return 0
}

passthrough_menu() {
  local choice tag
  if ! command -v lspci >/dev/null 2>&1; then
    ui_yesno "PCIe passthrough" "lspci is required. Install pciutils now?" || return
    run apt-get install -y pciutils >/dev/null || return
  fi
  while true; do
    tag=""
    ((PT_PENDING_INITRAMFS || PT_PENDING_BOOT)) && tag+="  [APPLY PENDING]"
    ((PT_PENDING_REBOOT)) && tag+="  [REBOOT NEEDED]"
    choice=$(ui_menu "PCIe passthrough" "IOMMU / VFIO helper$tag" \
      status "Status / preflight report" \
      iommu  "Enable IOMMU (kernel cmdline)" \
      vfio   "Load VFIO modules" \
      bind   "Bind devices to vfio-pci" \
      unsafe "Toggle unsafe interrupts" \
      groups "Show IOMMU groups" \
      efi    "Fix EFI boot / proxmox-boot-tool" \
      rebind "Recover a device with no driver (ixgbe etc.)" \
      hpe    "HPE RMRR slot exclusion (conrep)" \
      apply  "Apply changes (initramfs + bootloader) & reboot" \
      undo   "Undo changes from a backup session" \
      back   "Back") || choice=back
    case $choice in
      status) ui_cmd_output "Passthrough status" pt_status_report ;;
      iommu)  pt_setup_iommu ;;
      vfio)   pt_ensure_vfio_modules ;;
      bind)   pt_bind_devices ;;
      unsafe) pt_toggle_unsafe ;;
      groups) pt_show_groups ;;
      efi)    pt_fix_efi ;;
      rebind) pt_nic_rebind ;;
      hpe)    pt_hpe_rmrr ;;
      apply)  pt_apply_changes ;;
      undo)   restore_menu ;;
      back)   pt_leave menu; return ;;
    esac
  done
}
