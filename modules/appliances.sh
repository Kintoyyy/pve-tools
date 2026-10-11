# shellcheck shell=bash
# Appliance installers: download a vendor disk image and build a ready-to-run VM from it.
#
# Each appliance <id> provides:
#   appl_<id>_versions            "version|description" lines, newest first ("*" prefix = default)
#   appl_<id>_images <version>    "tag|description|url|firmware" lines (firmware: seabios|ovmf)
#   appl_<id>_defaults <version>  sets the A_* VM defaults
# The wizard (appl_install) collects A_* settings; appl_execute does the work.

APPL_CACHE=${APPL_CACHE:-/var/cache/pve-tools/images}
APPL_WIFI5_BASE=https://files.wifi5-soft.com/files/vendo-img
APPL_KITIFI_BASE=https://files.kitifi.com

# --- MikroTik RouterOS CHR (official images) ----------------------------------------

appl_chr_versions() {
  local ch v
  for ch in stable long-term testing; do
    # Returns e.g. "7.24.5 1790691687"
    v=$(curl -fsS --max-time 15 "https://upgrade.mikrotik.com/routeros/NEWESTa7.$ch" 2>/dev/null | cut -d' ' -f1)
    [[ -n $v ]] && echo "$v|RouterOS $v ($ch)"
  done
  echo "custom|Enter another version"
}

appl_chr_images() {
  echo "raw|Official CHR raw disk image|https://download.mikrotik.com/routeros/$1/chr-$1.img.zip|seabios"
}

appl_chr_defaults() {
  A_NAME=mikrotik-chr A_MEMORY=4096 A_CORES=2 A_SOCKETS=1 A_DISK=8G A_NICS=1
  A_SERIAL=1 A_ONBOOT=0 A_START=0 A_TEMPLATE=1
  A_NOTE="Console: qm terminal <vmid> (Ctrl+O to exit). Log in as 'admin' with an empty password.
Without a license CHR runs at 1 Mbit/s per interface; apply a trial or license under System > License."
}

# --- KiTifi ----------------------------------------------------------------------------

appl_kitifi_versions() {
  cat <<'EOF'
*ctl-v2.2|Controller v2.2 (MikroTik-based, UEFI)
ctl-v2.0|Controller v2.0 (MikroTik-based, UEFI)
sa-v2.2-beta|Standalone v2.2 beta (OpenWrt-based)
sa-v2.1-stable|Standalone v2.1 stable (OpenWrt-based)
sa-v1.3-stable|Standalone v1.3 stable (OpenWrt-based)
EOF
}

appl_kitifi_images() {
  local v sa="$APPL_KITIFI_BASE/Standalone_OpenWRT-Based/Main-Stable"
  case $1 in
    ctl-*)
      v=${1#ctl-}
      echo "uefi|UEFI image|$APPL_KITIFI_BASE/MT-Based/$v/Main/KiTifi-$v-uefi-x86.img.xz|ovmf" ;;
    sa-v1.3-stable)
      echo "uefi|UEFI (ext4)|$sa/v1.3-stable/KiTifi-OpenWRT-x86-64-generic-ext4-efi-v1.3-stable.img.gz|ovmf"
      echo "bios|Legacy BIOS (ext4)|$sa/v1.3-stable/KiTifi-OpenWRT-x86-64-generic-ext4-v1.3-stable.img.gz|seabios" ;;
    sa-*)
      v=${1#sa-}
      echo "uefi|UEFI|$sa/$v/KiTifi-OpenWRT-x86-64-generic-efi-$v.img.gz|ovmf"
      echo "bios|Legacy BIOS|$sa/$v/KiTifi-OpenWRT-x86-64-generic-$v.img.gz|seabios" ;;
  esac
}

appl_kitifi_defaults() {
  A_NAME=kitifi A_MEMORY=4096 A_CORES=2 A_SOCKETS=1 A_NICS=1
  A_SERIAL=0 A_ONBOOT=0 A_START=0 A_TEMPLATE=0 A_NOTE=""
  if [[ $1 == ctl-* ]]; then A_DISK=128G; else A_DISK=8G; fi
}

# --- WiFi5 Soft vendo -------------------------------------------------------------------

# The vendor's file server returns a JSON directory listing.
appl_wifi5_versions() {
  local v first=1
  while read -r v; do
    if [[ $v =~ -(rc|beta|Beta) ]]; then
      echo "$v|pre-release"
    elif ((first)); then
      echo "*$v|release (latest)"
      first=0
    else
      echo "$v|release"
    fi
  done < <(curl -fsS --max-time 20 "$APPL_WIFI5_BASE/" 2>/dev/null | grep -o '"name":"v[^"]*"' | cut -d'"' -f4 | sort -rV)
}

# File names changed from x86-64-*.img.gz to x86_64-*.img.gz in v3.5.89, so read them from the listing.
appl_wifi5_images() {
  local f
  curl -fsS --max-time 20 "$APPL_WIFI5_BASE/$1/" 2>/dev/null |
    grep -o '"name":"x86[-_]64[^"]*\.img\.gz"' | cut -d'"' -f4 |
    while read -r f; do
      if [[ $f == *efi* ]]; then
        echo "uefi|UEFI ($f)|$APPL_WIFI5_BASE/$1/$f|ovmf"
      else
        echo "bios|Legacy BIOS ($f)|$APPL_WIFI5_BASE/$1/$f|seabios"
      fi
    done | sort -t'|' -k1,1r
}

appl_wifi5_defaults() {
  A_NAME=wifi5 A_MEMORY=4096 A_CORES=2 A_SOCKETS=1 A_DISK=128G A_NICS=2
  A_SERIAL=0 A_ONBOOT=1 A_START=1 A_TEMPLATE=0 A_NOTE=""
}

# --- helpers ---------------------------------------------------------------------------

# qm's import-from disk option needs PVE 7.2+.
appl_supported() {
  local minor
  minor=$(cut -d. -f2 <<<"$PVE_VERSION")
  ((PVE_MAJOR > 7 || minor >= 2))
}

appl_bridges() { ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | sort; }

appl_onoff() { if (($1)); then echo ON; else echo OFF; fi; }

# Build APPL_ARGS (the qm create command) from the A_* settings.
appl_qm_args() {
  local i
  APPL_ARGS=(qm create "$A_VMID" --name "$A_NAME" --ostype l26
    --memory "$A_MEMORY" --cores "$A_CORES" --sockets "$A_SOCKETS" --cpu host
    --scsihw virtio-scsi-single
    --scsi0 "$A_STORAGE:0,import-from=$A_IMG,discard=on,iothread=1"
    --boot order=scsi0)
  for i in "${!A_BRIDGES[@]}"; do
    APPL_ARGS+=("--net$i" "virtio,bridge=${A_BRIDGES[$i]}")
  done
  # pre-enrolled-keys=0: Secure Boot keys would refuse these unsigned images.
  [[ $A_FIRMWARE == ovmf ]] && APPL_ARGS+=(--bios ovmf --efidisk0 "$A_STORAGE:1,efitype=4m,pre-enrolled-keys=0")
  ((A_SERIAL)) && APPL_ARGS+=(--serial0 socket --vga serial0)
  ((A_ONBOOT)) && APPL_ARGS+=(--onboot 1)
  return 0
}

appl_need_tool() {
  local tool
  case $1 in
    *.zip) tool=unzip ;;
    *.xz)  tool=xz ;;
    *)     return 0 ;;
  esac
  command -v "$tool" >/dev/null 2>&1 && return 0
  msg_info "Installing $tool..."
  run apt-get install -y "$([[ $tool == xz ]] && echo xz-utils || echo "$tool")"
}

# appl_extract <archive> <dest.img> — unpack a .zip/.gz/.xz disk image.
appl_extract() {
  local src=$1 dest=$2 member rc
  _log EXTRACT "$src -> $dest"
  if is_dry_run; then
    printf '%s[dry-run]%s extract %s -> %s\n' "$C_YELLOW" "$C_RESET" "$src" "$dest"
    return 0
  fi
  case $src in
    *.zip)
      member=$(unzip -Z1 "$src" 2>/dev/null | grep -m1 -i '\.img$') || return 1
      unzip -p "$src" "$member" >"$dest" ;;
    *.gz)
      gzip -dc "$src" >"$dest"
      rc=$?
      # OpenWrt images carry trailing metadata that gzip reports as a warning (exit 2).
      ((rc == 0 || rc == 2)) ;;
    *.xz)
      xz -dc "$src" >"$dest" ;;
    *)
      cp "$src" "$dest" ;;
  esac
}

# Download, extract, create the VM and run the post-create steps for the A_* settings.
appl_execute() {
  local archive="$APPL_CACHE/$A_ID-$A_VERSION-${A_URL##*/}"

  msg_title "Download ${A_URL##*/}"
  if [[ -s $archive ]]; then
    msg_ok "Using cached ${archive##*/}"
  elif ! { run mkdir -p "$APPL_CACHE" &&
    run curl -fL --retry 3 --progress-bar -o "$archive.part" "$A_URL" &&
    run mv "$archive.part" "$archive"; }; then
    msg_error "Download failed: $A_URL"
    run rm -f "$archive.part"
    return 1
  fi

  msg_title "Extract"
  appl_need_tool "$archive" || return 1
  if ! appl_extract "$archive" "$A_IMG"; then
    msg_error "Could not extract ${archive##*/}; removed it from the cache so the next attempt downloads it again."
    run rm -f "$archive" "$A_IMG"
    return 1
  fi
  msg_ok "Extracted ${A_IMG##*/}"

  msg_title "Create VM $A_VMID"
  appl_qm_args
  if ! run "${APPL_ARGS[@]}"; then
    msg_error "qm create failed."
    run rm -f "$A_IMG"
    return 1
  fi
  run rm -f "$A_IMG"

  msg_title "Resize disk to $A_DISK"
  run qm resize "$A_VMID" scsi0 "$A_DISK" ||
    msg_warn "Resize failed (the image may already be larger than $A_DISK)."

  if ((A_TEMPLATE)); then
    msg_title "Convert to template"
    run qm template "$A_VMID"
  elif ((A_START)); then
    msg_title "Start VM"
    run qm start "$A_VMID"
  fi

  if ! is_dry_run; then
    msg_title "VM $A_VMID"
    qm config "$A_VMID"
  fi
  msg_ok "VM $A_VMID ($A_NAME) is ready."
  [[ -n $A_NOTE ]] && printf '\n%s\n' "${A_NOTE//<vmid>/$A_VMID}"
  return 0
}

# --- wizard ------------------------------------------------------------------------------

# appl_install <id> <label>
appl_install() {
  local id=$1 title="Install $2"
  local line v desc def="" ver tag out i b bridge summary
  local -a lines items bridges

  if ! appl_supported; then
    ui_msg "$title" "Appliance installers need Proxmox VE 7.2 or newer (qm import-from)."
    return
  fi

  # Version
  mapfile -t lines < <(appl_"${id}"_versions)
  items=()
  for line in "${lines[@]}"; do
    [[ -n $line ]] || continue
    v=${line%%|*} desc=${line#*|}
    if [[ $v == \** ]]; then v=${v#\*}; def=$v; fi
    items+=("$v" "$desc")
  done
  if ((${#items[@]} == 0)); then
    ver=$(ui_input "$title" "Could not fetch the version list. Enter a version:") || return
  else
    ver=$(UI_DEFAULT_ITEM=$def ui_menu "$title" "Choose a version:" "${items[@]}") || return
  fi
  if [[ $ver == custom ]]; then
    def=${items[0]}
    [[ $def == custom ]] && def="" # the version lookup failed; nothing to suggest
    ver=$(ui_input "$title" "Version (e.g. 7.24.5):" "$def") || return
  fi
  if [[ ! $ver =~ ^[A-Za-z0-9._-]+$ ]]; then
    ui_msg "$title" "Invalid version '$ver'."
    return
  fi

  # Image variant
  mapfile -t lines < <(appl_"${id}"_images "$ver")
  if ((${#lines[@]} == 0)) || [[ -z ${lines[0]} ]]; then
    ui_msg "$title" "No x86-64 image found for version $ver."
    return
  fi
  line=${lines[0]}
  if ((${#lines[@]} > 1)); then
    items=()
    for line in "${lines[@]}"; do
      IFS='|' read -r tag desc _ <<<"$line"
      items+=("$tag" "$desc")
    done
    tag=$(ui_menu "$title" "Choose the image (UEFI is recommended):" "${items[@]}") || return
    for line in "${lines[@]}"; do [[ ${line%%|*} == "$tag" ]] && break; done
  fi
  IFS='|' read -r tag desc A_URL A_FIRMWARE <<<"$line"
  A_ID=$id A_VERSION=$ver
  appl_"${id}"_defaults "$ver"

  # VM id and name
  A_VMID=$(ui_input "$title" "VM ID:" "$(pvesh get /cluster/nextid 2>/dev/null)") || return
  if [[ ! $A_VMID =~ ^[1-9][0-9]*$ ]] || ! pvesh get /cluster/nextid --vmid "$A_VMID" >/dev/null 2>&1; then
    ui_msg "$title" "VM ID '$A_VMID' is invalid or already in use."
    return
  fi
  A_NAME=$(ui_input "$title" "VM name:" "$A_NAME") || return
  if [[ ! $A_NAME =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
    ui_msg "$title" "Invalid name '$A_NAME' (letters, digits, '-' and '.')."
    return
  fi
  A_IMG="$APPL_CACHE/import-$A_VMID.img"

  # Storage
  A_STORAGE=$(ui_pick_storage images) || return

  # Network
  mapfile -t bridges < <(appl_bridges)
  A_BRIDGES=()
  for ((i = 0; i < A_NICS; i++)); do
    if ((${#bridges[@]})); then
      items=()
      for b in "${bridges[@]}"; do items+=("$b" "Linux bridge"); done
      ((i > 0)) && items+=(none "No net$i")
      bridge=$(UI_DEFAULT_ITEM=${bridges[i]:-} ui_menu "$title" "Bridge for net$i:" "${items[@]}") || return
    else
      bridge=$(ui_input "$title" "Bridge for net$i (none detected):" "vmbr$i") || return
    fi
    [[ $bridge == none ]] && break
    if [[ ! $bridge =~ ^[A-Za-z0-9._-]+$ ]]; then
      ui_msg "$title" "Invalid bridge '$bridge'."
      return
    fi
    A_BRIDGES+=("$bridge")
  done

  # Resources
  A_CORES=$(ui_input "$title" "CPU cores:" "$A_CORES") || return
  A_MEMORY=$(ui_input "$title" "Memory (MB):" "$A_MEMORY") || return
  A_DISK=$(ui_input "$title" "Disk size (e.g. 8G, 128G):" "$A_DISK") || return
  if [[ ! $A_CORES =~ ^[1-9][0-9]*$ || ! $A_MEMORY =~ ^[1-9][0-9]+$ || ! $A_DISK =~ ^[1-9][0-9]*[GT]$ ]]; then
    ui_msg "$title" "Invalid cores ($A_CORES), memory ($A_MEMORY) or disk size ($A_DISK)."
    return
  fi

  # Options
  out=$(UI_ALLOW_EMPTY=1 ui_checklist "$title" "Options:" \
    onboot   "Start at host boot"          "$(appl_onoff "$A_ONBOOT")" \
    start    "Start the VM when done"      "$(appl_onoff "$A_START")" \
    template "Convert to a template"       "$(appl_onoff "$A_TEMPLATE")") || return
  out=$'\n'"$out"$'\n'
  A_ONBOOT=0 A_START=0 A_TEMPLATE=0
  [[ $out == *$'\n'onboot$'\n'* ]] && A_ONBOOT=1
  [[ $out == *$'\n'start$'\n'* ]] && A_START=1
  [[ $out == *$'\n'template$'\n'* ]] && A_TEMPLATE=1
  if ((A_START && A_TEMPLATE)); then
    ui_msg "$title" "A template can't be started. Choose either 'start' or 'template'."
    return
  fi

  summary="VM       $A_VMID ($A_NAME)
Image    ${A_URL##*/}
Version  $ver, $([[ $A_FIRMWARE == ovmf ]] && echo "UEFI (OVMF)" || echo "SeaBIOS")
Storage  $A_STORAGE, disk $A_DISK
CPU/RAM  $A_CORES cores, $A_MEMORY MB
Network  ${A_BRIDGES[*]:-none}$( ((A_SERIAL)) && echo "
Console  serial (qm terminal $A_VMID)")
After    $( ((A_TEMPLATE)) && echo "convert to template" || { ((A_START)) && echo "start"; } || echo "leave stopped")$( ((A_ONBOOT)) && echo ", start at boot")

The download is cached in $APPL_CACHE."
  ui_yesno "$title" "$summary\n\nCreate this VM?" || return

  ui_terminal "$title"
  appl_execute
  pause
}

appliances_menu() {
  local choice size
  while true; do
    size=$(du -sh "$APPL_CACHE" 2>/dev/null | cut -f1)
    choice=$(ui_menu "Appliance installers" "Download an appliance image and create a VM from it:" \
      chr    "MikroTik RouterOS CHR (official image)" \
      kitifi "KiTifi (controller or standalone)" \
      wifi5  "WiFi5 Soft vendo" \
      cache  "Clear download cache (${size:-empty})" \
      back   "Back") || return
    case $choice in
      chr)    appl_install chr "MikroTik CHR" ;;
      kitifi) appl_install kitifi "KiTifi" ;;
      wifi5)  appl_install wifi5 "WiFi5 Soft" ;;
      cache)
        ui_confirm "Download cache" "Delete all cached images in $APPL_CACHE (${size:-empty})?" &&
          run rm -rf "$APPL_CACHE" >/dev/null ;;
      back)   return ;;
    esac
  done
}
