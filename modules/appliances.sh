# shellcheck shell=bash
# Appliance installers: download a vendor disk image (or ISO) and build a ready-to-run VM.
#
# Each appliance <id> provides:
#   appl_<id>_versions            "version|description" lines, newest first ("*" prefix = default)
#   appl_<id>_images <version>    "tag|description|url|firmware[|kind]" lines
#                                 firmware: seabios|ovmf   kind: img (default)|iso
#   appl_<id>_defaults <version>  sets the A_* VM defaults
# appl_install collects A_* settings; appl_execute does the work.
# OpenWrt is a container, not a VM: it has its own wizard (appl_openwrt_install)
# and only provides appl_openwrt_versions.

APPL_CACHE=${APPL_CACHE:-/var/cache/pve-tools/images}
APPL_ISO_CACHE=${APPL_ISO_CACHE:-/var/lib/vz/template/iso}
APPL_WIFI5_BASE=https://files.wifi5-soft.com/files/vendo-img
APPL_KITIFI_BASE=https://files.kitifi.com
APPL_OPENWRT_BASE=https://downloads.openwrt.org


# --- MikroTik CHR / RouterOS x86 (elseif/MikroTikPatch) ---------------------

APPL_CHR_API="https://api.github.com/repos/elseif/MikroTikPatch/releases"

# jq is required for CHR version/image parsing. All output goes to stderr so
# callers using mapfile < <(...) never see it as a menu entry.
appl_need_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  msg_info "Installing jq..." >&2
  run apt-get install -y jq >&2 || return 1
  command -v jq >/dev/null 2>&1
}

# Fetch every release page (GitHub caps at 100/page) so the menu lists all versions.
# Pre-releases are never marked default: the first *stable* release is.
appl_chr_versions() {
  appl_need_jq || { echo "custom|Enter another version"; return 0; }

  local page=1 releases all=""

  while :; do
    releases=$(curl -fsSL --max-time 30 \
      "$APPL_CHR_API?per_page=100&page=$page") || {
        (( page == 1 )) && { echo "custom|Enter another version"; return 0; }
        break
      }

    [[ $(jq 'length' <<< "$releases") -eq 0 ]] && break

    all+=$releases
    ((page++))
  done

  # Newest first; the first non-prerelease gets the "*" default marker exactly once.
  jq -rs '
    add
    | [.[] | select(.draft == false)]
    | sort_by(.published_at)
    | reverse
    | .[]
    | .tag_name as $v
    | if .prerelease then
        $v + "|RouterOS " + $v + " (pre-release)"
      else
        $v + "|RouterOS " + $v
      end
  ' <<< "$all" |
  awk '
    !marked && $0 !~ /pre-release/ { print "*" $0; marked=1; next }
    { print }
  '

  echo "custom|Enter another version"
}

# Assets in elseif/MikroTikPatch:
#   chr-<v>.img.zip             -> CHR UEFI disk image (recommended)
#   chr-<v>-legacy-bios.img.zip -> CHR Legacy BIOS disk image
#   mikrotik-<v>.iso            -> plain RouterOS x86 installer ISO
# Ranked explicitly inside jq so UEFI is always the first line of the menu,
# independent of the order GitHub happens to list assets in.
appl_chr_images() {
  appl_need_jq || return 1

  local v="$1" release

  release=$(curl -fsSL --max-time 20 \
    "https://api.github.com/repos/elseif/MikroTikPatch/releases/tags/$v") ||
    return 1

  jq -r --arg v "$v" '
    .assets
    | map(
        if   .name == ("chr-" + $v + ".img.zip") then
          {rank: 0, tag: "uefi",
           desc: "CHR UEFI disk image (recommended)",
           url: .browser_download_url, fw: "ovmf", kind: "img"}
        elif .name == ("chr-" + $v + "-legacy-bios.img.zip") then
          {rank: 1, tag: "bios",
           desc: "CHR Legacy BIOS disk image",
           url: .browser_download_url, fw: "seabios", kind: "img"}
        elif .name == ("mikrotik-" + $v + ".iso") then
          {rank: 2, tag: "iso",
           desc: "RouterOS x86 installer ISO",
           url: .browser_download_url, fw: "seabios", kind: "iso"}
        else empty
        end
      )
    | sort_by(.rank)
    | .[]
    | "\(.tag)|\(.desc)|\(.url)|\(.fw)|\(.kind)"
  ' <<< "$release"
}

appl_chr_defaults() {
  # Defaults for the CHR image case; appl_install adjusts them for the ISO.
  A_NAME=mikrotik A_MEMORY=4096 A_CORES=2 A_SOCKETS=1 A_DISK=8G A_NICS=1
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
      echo "uefi|UEFI image|$APPL_KITIFI_BASE/MT-Based/$v/Main/KiTifi-$v-uefi-x86.img.xz|ovmf|img" ;;
    sa-v1.3-stable)
      echo "uefi|UEFI (ext4)|$sa/v1.3-stable/KiTifi-OpenWRT-x86-64-generic-ext4-efi-v1.3-stable.img.gz|ovmf|img"
      echo "bios|Legacy BIOS (ext4)|$sa/v1.3-stable/KiTifi-OpenWRT-x86-64-generic-ext4-v1.3-stable.img.gz|seabios|img" ;;
    sa-*)
      v=${1#sa-}
      echo "uefi|UEFI|$sa/$v/KiTifi-OpenWRT-x86-64-generic-efi-$v.img.gz|ovmf|img"
      echo "bios|Legacy BIOS|$sa/$v/KiTifi-OpenWRT-x86-64-generic-$v.img.gz|seabios|img" ;;
  esac
}

appl_kitifi_defaults() {
  A_NAME=kitifi A_MEMORY=4096 A_CORES=2 A_SOCKETS=1 A_NICS=1
  A_SERIAL=0 A_ONBOOT=0 A_START=0 A_TEMPLATE=0 A_NOTE=""
  if [[ $1 == ctl-* ]]; then A_DISK=128G; else A_DISK=8G; fi
}

# --- WiFi5 Soft vendo -------------------------------------------------------------------

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

# Tags are made unique by folding the filename into the tag, so two EFI files
# can never share the same tag and pick the wrong URL.
appl_wifi5_images() {
  local f
  curl -fsS --max-time 20 "$APPL_WIFI5_BASE/$1/" 2>/dev/null |
    grep -o '"name":"x86[-_]64[^"]*\.img\.gz"' | cut -d'"' -f4 |
    while read -r f; do
      if [[ $f == *efi* ]]; then
        echo "uefi:$f|UEFI ($f)|$APPL_WIFI5_BASE/$1/$f|ovmf|img"
      else
        echo "bios:$f|Legacy BIOS ($f)|$APPL_WIFI5_BASE/$1/$f|seabios|img"
      fi
    done | sort -t'|' -k1,1r
}

appl_wifi5_defaults() {
  A_NAME=wifi5 A_MEMORY=4096 A_CORES=2 A_SOCKETS=1 A_DISK=128G A_NICS=2
  A_SERIAL=0 A_ONBOOT=1 A_START=1 A_TEMPLATE=0 A_NOTE=""
}

# --- OpenWrt (LXC) ------------------------------------------------------------------------
# Ported from Kintoyyy/openwrt-proxmox-lxc: the x86-64 rootfs becomes an unprivileged
# container with WAN on eth0 (DHCP) and LAN on eth1 (static), set up through UCI.

# The newest release of each of the last four series (or its latest rc if the series has
# no release yet), then the daily snapshot.
appl_openwrt_versions() {
  curl -fsS --max-time 20 "$APPL_OPENWRT_BASE/releases/" 2>/dev/null |
    grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?/"' | cut -d'"' -f2 | tr -d / | sort -V |
    awk -F. '
      { s = $1 "." $2; if (!(s in seen)) { seen[s] = 1; order[++n] = s } }
      /-rc/ { rc[s] = $0; next }
      { final[s] = $0 }
      END {
        for (i = n; i > 0 && i > n - 4; i--) {
          s = order[i]
          if (s in final) printf "%s%s|OpenWrt %s\n", (marked++ ? "" : "*"), final[s], final[s]
          else printf "%s|OpenWrt %s (release candidate)\n", rc[s], rc[s]
        }
      }'
  echo "snapshot|Daily snapshot (LuCI not included)"
  echo "custom|Enter another version"
}

# appl_openwrt_url <version|snapshot> — the rootfs tarball URL, read from the directory
# listing because older releases name it ...-x86-64-generic-rootfs.tar.gz.
appl_openwrt_url() {
  local dir f
  if [[ $1 == snapshot ]]; then
    dir="$APPL_OPENWRT_BASE/snapshots/targets/x86/64"
  else
    dir="$APPL_OPENWRT_BASE/releases/$1/targets/x86/64"
  fi
  f=$(curl -fsS --max-time 20 "$dir/" 2>/dev/null |
    grep -oE 'href="openwrt-[^"]*x86-64(-generic)?-rootfs\.tar\.gz"' | cut -d'"' -f2 | head -1)
  [[ -n $f ]] && echo "$dir/$f"
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

# Convert a Proxmox size string (e.g. 8G, 128G, 1T) to GiB as an integer.
appl_size_gib() {
  local s=${1^^} n
  if [[ $s == *T ]]; then
    n=${s%T}; echo $((n * 1024))
  else
    echo "${s%G}"
  fi
}

# appl_netmask <prefix> — dotted netmask for a prefix length, e.g. 24 -> 255.255.255.0.
appl_netmask() {
  local m=$(((0xffffffff << (32 - $1)) & 0xffffffff))
  echo "$((m >> 24 & 255)).$((m >> 16 & 255)).$((m >> 8 & 255)).$((m & 255))"
}

# appl_pick_bridge <title> <text> <default> [allow_none] — prints a bridge, or "none".
appl_pick_bridge() {
  local title=$1 text=$2 def=$3 allow_none=${4:-0} b bridge
  local -a bridges items=()
  mapfile -t bridges < <(appl_bridges)
  if ((${#bridges[@]})); then
    for b in "${bridges[@]}"; do items+=("$b" "Linux bridge"); done
    ((allow_none)) && items+=(none "Not connected")
    bridge=$(UI_DEFAULT_ITEM=$def ui_menu "$title" "$text:" "${items[@]}") || return 1
  else
    bridge=$(ui_input "$title" "$text (none detected):" "$def") || return 1
  fi
  if [[ $bridge != none && ! $bridge =~ ^[A-Za-z0-9._-]+$ ]]; then
    ui_msg "$title" "Invalid bridge '$bridge'."
    return 1
  fi
  printf '%s\n' "$bridge"
}

# appl_download <url> [max_age_min] — download <url> into the cache, or reuse the cached
# copy, and set APPL_ARCHIVE. A cached copy older than max_age_min is downloaded again.
# The name carries a hash of the URL: the official and elseif CHR downloads are both
# chr-<v>.img.zip, and reusing the official one (ext2 boot partition, no EFI loader)
# under OVMF leaves no bootable device.
appl_download() {
  local url=$1 max_age=${2:-0} key
  key=$(printf '%s' "$url" | md5sum | cut -c1-8)
  APPL_ARCHIVE="$APPL_CACHE/$A_ID-$A_VERSION-$key-${url##*/}"

  msg_title "Download ${url##*/}"
  if [[ -s $APPL_ARCHIVE ]] &&
    { ((max_age == 0)) || [[ -z $(find "$APPL_ARCHIVE" -mmin +"$max_age") ]]; }; then
    msg_ok "Using cached ${APPL_ARCHIVE##*/}"
    return 0
  fi
  if ! { run mkdir -p "$APPL_CACHE" &&
    run curl -fL --retry 3 --progress-bar -o "$APPL_ARCHIVE.part" "$url" &&
    run mv "$APPL_ARCHIVE.part" "$APPL_ARCHIVE"; }; then
    msg_error "Download failed: $url"
    run rm -f "$APPL_ARCHIVE.part"
    return 1
  fi
}

# Build APPL_ARGS (the qm create command) from the A_* settings.
appl_qm_args() {
  local i
  APPL_ARGS=(qm create "$A_VMID" --name "$A_NAME" --ostype l26
    --memory "$A_MEMORY" --cores "$A_CORES" --sockets "$A_SOCKETS" --cpu host
    --scsihw virtio-scsi-single)

  if [[ $A_KIND == iso ]]; then
    # A new (empty) disk takes a bare size in GiB, not storage:8G (that syntax
    # means "the existing volume named 8G"). Convert G/T to GiB correctly.
    local size_gib
    size_gib=$(appl_size_gib "$A_DISK")
    APPL_ARGS+=(--scsi0 "$A_STORAGE:$size_gib,discard=on,iothread=1"
                --ide2 "$A_ISO_VOLID,media=cdrom"
                --boot order='ide2;scsi0')
  else
    APPL_ARGS+=(--scsi0 "$A_STORAGE:0,import-from=$A_IMG,discard=on,iothread=1"
                --boot order=scsi0)
  fi

  for i in "${!A_BRIDGES[@]}"; do
    APPL_ARGS+=("--net$i" "virtio,bridge=${A_BRIDGES[$i]}")
  done
  # pre-enrolled-keys=0: the elseif images are unsigned, so Secure Boot would
  # refuse to boot them under OVMF.
  [[ $A_FIRMWARE == ovmf ]] && APPL_ARGS+=(--bios ovmf --efidisk0 "$A_STORAGE:1,efitype=4m,pre-enrolled-keys=0")
  # --vga serial0 routes all display output to the serial console, so the VM
  # has no graphical screen. Only do that when the appliance actually uses one.
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
  msg_info "Installing $tool..." >&2
  run apt-get install -y "$([[ $tool == xz ]] && echo xz-utils || echo "$tool")" >&2
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
      # OpenWrt images carry trailing metadata that gzip reports as a warning
      # (exit 2) even though the data is intact.
      ((rc == 0 || rc == 2)) ;;
    *.xz)
      xz -dc "$src" >"$dest" ;;
    *)
      cp "$src" "$dest" ;;
  esac
}

# Resolve the on-disk path for an ISO on <storage>. Returns 1 if the storage
# cannot be resolved, rather than guessing a path that may not exist.
appl_iso_path() {
  local storage=$1 name=$2 path dir

  path=$(pvesm path "$storage:iso/$name" 2>/dev/null) && [[ -n $path ]] && {
    printf '%s\n' "$path"; return 0
  }

  # Fall back to reading the storage's path from storage.cfg. Match the line
  # that starts with "<type>: <storage>", then the next "path <dir>" line.
  dir=$(awk -v s="$storage" '
    $1 ~ /^(dir|nfs|cifs|glusterfs):$/ && $2 == s { found=1; next }
    found && $1 == "path" { print $2; exit }
    found && /^[a-z]+:/ { exit }
  ' /etc/pve/storage.cfg)

  [[ -n $dir ]] || return 1

  # pvesm's iso volid maps to <dir>/template/iso/<name> for dir-backed storage.
  printf '%s/template/iso/%s\n' "$dir" "$name"
}

# Copy an ISO into an iso-capable storage and echo the resulting volid.
# Usage: appl_import_iso <src> <storage> <name>
# <name> is the on-storage file name; the caller controls it so the volid it
# computes matches what is actually written.
appl_import_iso() {
  local src=$1 storage=$2 name=$3 path
  _log IMPORT-ISO "$src -> $storage:$name"

  path=$(appl_iso_path "$storage" "$name") || {
    msg_error "Cannot resolve an iso path on storage '$storage'."
    return 1
  }
  run mkdir -p "$(dirname "$path")"
  run cp "$src" "$path" || return 1

  printf '%s:iso/%s\n' "$storage" "$name"
}

appl_execute() {
  local archive
  appl_download "$A_URL" || return 1
  archive=$APPL_ARCHIVE

  if [[ $A_KIND == iso ]]; then
    # The on-storage name is the vendor's file name (from the URL), not the
    # cache name. The volid is computed from that same name so dry-run and a
    # real run agree, and so qm create points at a volume that exists.
    local iso_name="${A_URL##*/}"
    A_ISO_VOLID="$A_ISO_STORAGE:iso/$iso_name"

    msg_title "Import ISO to $A_ISO_STORAGE"
    if is_dry_run; then
      printf '%s[dry-run]%s import %s -> %s\n' "$C_YELLOW" "$C_RESET" "$archive" "$A_ISO_VOLID"
    else
      if ! appl_import_iso "$archive" "$A_ISO_STORAGE" "$iso_name"; then
        msg_error "Could not import ISO into $A_ISO_STORAGE."
        return 1
      fi
      msg_ok "ISO ready as $A_ISO_VOLID"
    fi

    msg_title "Create VM $A_VMID"
    appl_qm_args
    if ! run "${APPL_ARGS[@]}"; then
      msg_error "qm create failed."
      return 1
    fi

    if ((A_START)); then
      msg_title "Start VM"
      run qm start "$A_VMID"
    fi

    if ! is_dry_run; then
      msg_title "VM $A_VMID"
      qm config "$A_VMID"
    fi
    msg_ok "VM $A_VMID ($A_NAME) is ready."
    printf '\nOpen the noVNC console in the Proxmox web UI to run the installer.\n'
    [[ -n $A_NOTE ]] && printf '\n%s\n' "${A_NOTE//<vmid>/$A_VMID}"
    return 0
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

# appl_pick_version <id> <title> — version menu from appl_<id>_versions; prints the choice.
# jq install messages are on stderr, so they don't pollute the menu.
appl_pick_version() {
  local id=$1 title=$2 line v desc def="" ver
  local -a lines items=()

  mapfile -t lines < <(appl_"${id}"_versions)
  for line in "${lines[@]}"; do
    [[ -n $line ]] || continue
    v=${line%%|*} desc=${line#*|}
    if [[ $v == \** ]]; then v=${v#\*}; def=$v; fi
    items+=("$v" "$desc")
  done
  if ((${#items[@]} == 0)); then
    ver=$(ui_input "$title" "Could not fetch the version list. Enter a version:") || return 1
  else
    ver=$(UI_DEFAULT_ITEM=$def ui_menu "$title" "Choose a version:" "${items[@]}") || return 1
  fi
  if [[ $ver == custom ]]; then
    ver=$(ui_input "$title" "Version:" "$def") || return 1
  fi
  if [[ ! $ver =~ ^[A-Za-z0-9._-]+$ ]]; then
    ui_msg "$title" "Invalid version '$ver'."
    return 1
  fi
  printf '%s\n' "$ver"
}

# appl_install <id> <label>
# Expects appl_<id>_versions / _images / _defaults to exist (see the header).
appl_install() {
  local id=$1 title="Install $2"
  local line desc ver tag out i bridge summary
  local -a lines items bridges

  if ! appl_supported; then
    ui_msg "$title" "Appliance installers need Proxmox VE 7.2 or newer (qm import-from)."
    return
  fi

  ver=$(appl_pick_version "$id" "$title") || return

  # Image variant (tag|description|url|firmware[|kind])
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
    # CHR lists uefi first (ranked in jq), so uefi is the default; for other
    # appliances we just take the first entry.
    tag=$(UI_DEFAULT_ITEM=uefi ui_menu "$title" "Choose the image (UEFI is recommended):" "${items[@]}") || return
    for line in "${lines[@]}"; do [[ ${line%%|*} == "$tag" ]] && break; done
  fi
  IFS='|' read -r tag desc A_URL A_FIRMWARE A_KIND <<<"$line"
  A_KIND=${A_KIND:-img}
  A_ID=$id A_VERSION=$ver
  appl_"${id}"_defaults "$ver"

  # The ISO variant is plain RouterOS x86: it installs to disk, so no template,
  # a graphical console (the installer only draws to the screen), and an
  # ISO-specific note about detaching the CD.
  if [[ $A_KIND == iso ]]; then
    A_NAME=mikrotik
    A_DISK=8G A_TEMPLATE=0 A_SERIAL=0
    A_NOTE="Open the noVNC console in the Proxmox web UI and run the RouterOS
installer, then reboot. After the first reboot, detach the ISO (Hardware >
CD/DVD > Remove) and set Options > Boot Order to scsi0, otherwise the VM
boots the installer again."
  fi

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

  # Storage
  A_STORAGE=$(ui_pick_storage images) || return
  if [[ $A_KIND == iso ]]; then
    A_IMG=""
    A_ISO_STORAGE=$(ui_pick_storage iso) || return
  else
    A_IMG="$APPL_CACHE/import-$A_VMID.img"
    A_ISO_STORAGE=""
  fi

  # Network
  mapfile -t bridges < <(appl_bridges)
  A_BRIDGES=()
  for ((i = 0; i < A_NICS; i++)); do
    bridge=$(appl_pick_bridge "$title" "Bridge for net$i" "${bridges[i]:-vmbr$i}" $((i > 0))) || return
    [[ $bridge == none ]] && break
    A_BRIDGES+=("$bridge")
  done

  # Resources
  A_CORES=$(ui_input "$title" "CPU cores:" "$A_CORES") || return
  A_MEMORY=$(ui_input "$title" "Memory (MB):" "$A_MEMORY") || return
  A_DISK=$(ui_input "$title" "Disk size (e.g. 8G, 128G, 1T):" "$A_DISK") || return
  if [[ ! $A_CORES =~ ^[1-9][0-9]*$ || ! $A_MEMORY =~ ^[1-9][0-9]+$ || ! $A_DISK =~ ^[1-9][0-9]*[GT]$ ]]; then
    ui_msg "$title" "Invalid cores ($A_CORES), memory ($A_MEMORY) or disk size ($A_DISK)."
    return
  fi

  # Options (template only makes sense for preinstalled img appliances)
  local -a opt_items=(
    onboot   "Start at host boot"     "$(appl_onoff "$A_ONBOOT")"
    start    "Start the VM when done" "$(appl_onoff "$A_START")"
  )
  [[ $A_KIND == img ]] && opt_items+=(template "Convert to a template" "$(appl_onoff "$A_TEMPLATE")")

  out=$(UI_ALLOW_EMPTY=1 ui_checklist "$title" "Options:" "${opt_items[@]}") || return
  out=$'\n'"$out"$'\n'
  A_ONBOOT=0 A_START=0 A_TEMPLATE=0
  [[ $out == *$'\n'onboot$'\n'* ]] && A_ONBOOT=1
  [[ $out == *$'\n'start$'\n'* ]] && A_START=1
  [[ $out == *$'\n'template$'\n'* ]] && A_TEMPLATE=1
  if ((A_START && A_TEMPLATE)); then
    ui_msg "$title" "A template can't be started. Choose either 'start' or 'template'."
    return
  fi

  local kind_desc after
  if [[ $A_KIND == iso ]]; then
    kind_desc="ISO installer (boot from CD, install to disk)"
    after=$( ((A_START)) && echo "start, then run the installer in noVNC" || echo "leave stopped; use noVNC to install" )
  else
    kind_desc="Disk image (imported onto scsi0)"
    after=$( ((A_TEMPLATE)) && echo "convert to template" || { ((A_START)) && echo "start"; } || echo "leave stopped" )
  fi

  summary="VM       $A_VMID ($A_NAME)
Kind     $kind_desc
Image    ${A_URL##*/}
Version  $ver, $([[ $A_FIRMWARE == ovmf ]] && echo "UEFI (OVMF)" || echo "SeaBIOS")
Storage  $A_STORAGE, disk $A_DISK$([[ $A_KIND == iso ]] && echo "
ISO      $A_ISO_STORAGE")
CPU/RAM  $A_CORES cores, $A_MEMORY MB
Network  ${A_BRIDGES[*]:-none}$( ((A_SERIAL)) && echo "
Console  serial (qm terminal $A_VMID)")
After    $after$( ((A_ONBOOT)) && echo ", start at boot")

The download is cached in $APPL_CACHE."
  ui_yesno "$title" "$summary\n\nCreate this VM?" || return

  ui_terminal "$title"
  appl_execute
  pause
}

appl_openwrt_execute() {
  local ip=${A_LAN%/*} mask i
  local -a args
  mask=$(appl_netmask "${A_LAN#*/}")

  # Snapshots are rebuilt daily, so a cached one older than a day is fetched again.
  appl_download "$A_URL" "$([[ $A_VERSION == snapshot ]] && echo 1440 || echo 0)" || return 1

  msg_title "Create container $A_VMID"
  args=(pct create "$A_VMID" "$APPL_ARCHIVE" --arch amd64 --ostype unmanaged
    --hostname "$A_NAME" --rootfs "$A_STORAGE:$A_DISK"
    --memory "$A_MEMORY" --cores "$A_CORES" --unprivileged 1 --features nesting=1)
  [[ $A_WAN != none ]] && args+=(--net0 "name=eth0,bridge=$A_WAN")
  [[ $A_LAN_BRIDGE != none ]] && args+=(--net1 "name=eth1,bridge=$A_LAN_BRIDGE")
  ((A_ONBOOT)) && args+=(--onboot 1)
  if ! run "${args[@]}"; then
    msg_error "pct create failed."
    return 1
  fi

  msg_title "Start container"
  run pct start "$A_VMID" || { msg_error "pct start failed."; return 1; }
  if ! is_dry_run; then
    # Wait for netifd, so the first-boot network config exists before it is changed.
    for ((i = 0; i < 30; i++)); do
      pct exec "$A_VMID" -- ubus call network.interface dump >/dev/null 2>&1 && break
      sleep 1
    done
  fi

  msg_title "Configure network"
  # dnsmasq's procd jail cannot be set up in an unprivileged container.
  run pct exec "$A_VMID" -- sed -i 's!procd_add_jail!: procd_add_jail!g' /etc/init.d/dnsmasq ||
    msg_warn "Could not patch /etc/init.d/dnsmasq; DHCP on the LAN may not start."
  run pct exec "$A_VMID" -- sh -c "
    uci set network.wan=interface
    uci set network.wan.proto='dhcp'
    uci set network.wan.device='eth0'
    uci set network.wan6=interface
    uci set network.wan6.proto='dhcpv6'
    uci set network.wan6.device='eth0'
    uci set network.lan=interface
    uci set network.lan.proto='static'
    uci set network.@device[0].ports='eth1'
    uci set network.lan.ipaddr='$ip'
    uci set network.lan.netmask='$mask'
    uci commit network
    /etc/init.d/network restart
    /etc/init.d/dnsmasq restart" ||
    msg_warn "Network configuration failed; check it with: pct exec $A_VMID -- uci show network"

  if ((A_LUCI)); then
    msg_title "Install LuCI"
    # WAN may still be waiting for its DHCP lease, so retry for up to 30 seconds.
    run pct exec "$A_VMID" -- sh -c '
      for i in 1 2 3 4 5 6; do
        if command -v apk >/dev/null; then
          apk update && apk add luci && exit 0
        else
          opkg update && opkg install luci && exit 0
        fi
        sleep 5
      done
      exit 1' ||
      msg_warn "LuCI install failed. Once WAN is up: pct exec $A_VMID -- apk add luci (or opkg install luci)"
  fi

  if [[ -n $A_PASSWORD ]]; then
    msg_title "Set root password"
    printf '%s\n%s\n' "$A_PASSWORD" "$A_PASSWORD" | run pct exec "$A_VMID" -- passwd ||
      msg_warn "Could not set the root password; set it with: pct exec $A_VMID -- passwd"
  fi

  if ! is_dry_run; then
    msg_title "Container $A_VMID"
    pct config "$A_VMID"
  fi
  msg_ok "Container $A_VMID ($A_NAME) is running."
  printf '\nShell: pct enter %s\nLuCI:  http://%s from the LAN side (login root, %s)\n' \
    "$A_VMID" "$ip" "$([[ -n $A_PASSWORD ]] && echo "the password you set" || echo "no password yet")"
  return 0
}

appl_openwrt_install() {
  local title="Install OpenWrt" ver pw pw2 out summary wan_desc lan_desc
  local -a bridges opt_items

  ver=$(appl_pick_version openwrt "$title") || return
  A_URL=$(appl_openwrt_url "$ver")
  if [[ -z $A_URL ]]; then
    ui_msg "$title" "No x86-64 rootfs found for OpenWrt $ver."
    return
  fi
  A_ID=openwrt A_VERSION=$ver
  A_NAME=openwrt A_MEMORY=256 A_CORES=2 A_DISK=0.5 A_LAN=192.168.0.1/24 A_ONBOOT=0
  # Release rootfs tarballs include LuCI; snapshots do not.
  A_LUCI=0
  [[ $ver == snapshot ]] && A_LUCI=1

  # Container id and hostname
  A_VMID=$(ui_input "$title" "Container ID:" "$(pvesh get /cluster/nextid 2>/dev/null)") || return
  if [[ ! $A_VMID =~ ^[1-9][0-9]*$ ]] || ! pvesh get /cluster/nextid --vmid "$A_VMID" >/dev/null 2>&1; then
    ui_msg "$title" "Container ID '$A_VMID' is invalid or already in use."
    return
  fi
  A_NAME=$(ui_input "$title" "Hostname:" "$A_NAME") || return
  if [[ ! $A_NAME =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
    ui_msg "$title" "Invalid hostname '$A_NAME' (letters, digits, '-' and '.')."
    return
  fi

  A_STORAGE=$(ui_pick_storage rootdir) || return

  # Network: WAN on eth0, LAN on eth1. Either may be left off, but not both.
  mapfile -t bridges < <(appl_bridges)
  A_WAN=$(appl_pick_bridge "$title" "WAN bridge (eth0, DHCP)" "${bridges[0]:-vmbr0}" 1) || return
  A_LAN_BRIDGE=$(appl_pick_bridge "$title" "LAN bridge (eth1, static)" "${bridges[1]:-none}" 1) || return
  if [[ $A_WAN == none && $A_LAN_BRIDGE == none ]]; then
    ui_msg "$title" "Connect at least one of WAN or LAN."
    return
  fi
  A_LAN=$(ui_input "$title" "LAN address/prefix (eth1):" "$A_LAN") || return
  if [[ ! $A_LAN =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] ||
    ((BASH_REMATCH[1] > 255 || BASH_REMATCH[2] > 255 || BASH_REMATCH[3] > 255 ||
      BASH_REMATCH[4] > 255 || BASH_REMATCH[5] < 8 || BASH_REMATCH[5] > 30)); then
    ui_msg "$title" "Invalid LAN address '$A_LAN' (e.g. 192.168.0.1/24, prefix 8-30)."
    return
  fi

  # Resources
  A_CORES=$(ui_input "$title" "CPU cores:" "$A_CORES") || return
  A_MEMORY=$(ui_input "$title" "Memory (MB):" "$A_MEMORY") || return
  A_DISK=$(ui_input "$title" "Disk size in GiB (e.g. 0.5, 1, 2):" "$A_DISK") || return
  if [[ ! $A_CORES =~ ^[1-9][0-9]*$ || ! $A_MEMORY =~ ^[1-9][0-9]+$ ||
    ! $A_DISK =~ ^[0-9]+(\.[0-9]+)?$ || $A_DISK =~ ^0+(\.0+)?$ ]]; then
    ui_msg "$title" "Invalid cores ($A_CORES), memory ($A_MEMORY) or disk size ($A_DISK)."
    return
  fi

  # Root password (optional)
  pw=$(ui_password "$title" "Root password (leave empty to set it later):") || return
  if [[ -n $pw ]]; then
    pw2=$(ui_password "$title" "Confirm the root password:") || return
    if [[ $pw != "$pw2" ]]; then
      ui_msg "$title" "The passwords do not match."
      return
    fi
  fi
  A_PASSWORD=$pw

  # Options
  opt_items=(onboot "Start at host boot" "$(appl_onoff "$A_ONBOOT")")
  ((A_LUCI)) && opt_items+=(luci "Install LuCI (web UI) from the package feed" ON)
  out=$(UI_ALLOW_EMPTY=1 ui_checklist "$title" "Options:" "${opt_items[@]}") || return
  out=$'\n'"$out"$'\n'
  A_ONBOOT=0 A_LUCI=0
  [[ $out == *$'\n'onboot$'\n'* ]] && A_ONBOOT=1
  [[ $out == *$'\n'luci$'\n'* ]] && A_LUCI=1

  wan_desc="eth0 on $A_WAN, DHCP + DHCPv6"
  [[ $A_WAN == none ]] && wan_desc="not connected"
  lan_desc="eth1 on $A_LAN_BRIDGE, $A_LAN"
  [[ $A_LAN_BRIDGE == none ]] && lan_desc="not connected ($A_LAN once eth1 is added)"
  summary="CT       $A_VMID ($A_NAME), unprivileged, nesting
Image    ${A_URL##*/}
Version  $ver
Storage  $A_STORAGE, rootfs ${A_DISK}G
CPU/RAM  $A_CORES cores, $A_MEMORY MB
WAN      $wan_desc
LAN      $lan_desc
Password $([[ -n $A_PASSWORD ]] && echo set || echo "not set")
LuCI     $([[ $ver != snapshot ]] && echo included || { ((A_LUCI)) && echo "install from the feed" || echo "not installed"; })
After    start$( ((A_ONBOOT)) && echo ", start at boot")

The download is cached in $APPL_CACHE."
  ui_yesno "$title" "$summary\n\nCreate this container?" || return

  ui_terminal "$title"
  appl_openwrt_execute
  pause
}

appliances_menu() {
  local choice size
  while true; do
    size=$(du -sh "$APPL_CACHE" 2>/dev/null | cut -f1)
    choice=$(ui_menu "Appliance installers" "Download an appliance image and create a VM or container from it:" \
      chr     "MikroTik RouterOS (CHR image or x86 ISO)" \
      kitifi  "KiTifi (controller or standalone)" \
      wifi5   "WiFi5 Soft vendo" \
      openwrt "OpenWrt (LXC container)" \
      cache   "Clear download cache (${size:-empty})" \
      back    "Back") || return
    case $choice in
      chr)     appl_install chr "MikroTik" ;;
      kitifi)  appl_install kitifi "KiTifi" ;;
      wifi5)   appl_install wifi5 "WiFi5 Soft" ;;
      openwrt) appl_openwrt_install ;;
      cache)
        ui_confirm "Download cache" "Delete all cached images in $APPL_CACHE (${size:-empty})?" &&
          run rm -rf "$APPL_CACHE" >/dev/null ;;
      back)    return ;;
    esac
  done
}