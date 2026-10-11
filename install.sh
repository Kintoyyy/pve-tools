#!/usr/bin/env bash
# pve-tools installer.
#
#   Install / update:  bash -c "$(curl -fsSL https://raw.githubusercontent.com/Kintoyyy/pve-tools/main/install.sh)"
#   From a clone:      ./install.sh --local
#   Uninstall:         pve-tools uninstall   (or: install.sh --uninstall)
#
# Env: PVE_TOOLS_REPO (owner/name), PVE_TOOLS_REF (branch, tag or commit), PVE_TOOLS_PREFIX.
#
# Everything runs inside main(), called on the last line, so a truncated
# download never executes a partial script.

set -euo pipefail

REPO="${PVE_TOOLS_REPO:-Kintoyyy/pve-tools}"
REF="${PVE_TOOLS_REF:-main}"
PREFIX="${PVE_TOOLS_PREFIX:-/opt/pve-tools}"
BIN_LINK=/usr/local/bin/pve-tools
NAG_SCRIPT=/usr/local/sbin/pve-tools-nag-patch
NAG_HOOK=/etc/apt/apt.conf.d/99-pve-tools-nag

say() { printf '\e[34m[i]\e[0m %s\n' "$*"; }
ok()  { printf '\e[32m[✓]\e[0m %s\n' "$*"; }
err() { printf '\e[31m[✗]\e[0m %s\n' "$*" >&2; exit 1; }

# preflight <local|remote>
preflight() {
  [[ $EUID -eq 0 ]] || err "Run the installer as root."
  command -v pveversion >/dev/null 2>&1 || err "This is not a Proxmox VE host (pveversion not found)."
  if [[ $1 == remote ]]; then
    local tool
    for tool in curl tar; do
      command -v "$tool" >/dev/null 2>&1 || err "Missing required tool: $tool"
    done
  fi
  if ! command -v whiptail >/dev/null 2>&1; then
    say "Installing whiptail..."
    { apt-get install -y whiptail || { apt-get update && apt-get install -y whiptail; }; } >/dev/null ||
      err "Could not install whiptail."
  fi
}

# fetch_source <dest-dir> — download and unpack $REPO@$REF into <dest-dir>.
fetch_source() {
  local dest=$1 url="https://github.com/$REPO/archive/$REF.tar.gz"
  say "Downloading $REPO@$REF..."
  curl -fsSL "$url" | tar -xz -C "$dest" --strip-components=1 ||
    err "Download failed: $url"
}

do_install() {
  local mode=$1 src
  preflight "$mode"
  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT

  if [[ $mode == local ]]; then
    src=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
    say "Installing from local checkout $src"
  else
    src="$TMP_DIR/src"
    mkdir -p "$src"
    fetch_source "$src"
  fi
  [[ -f $src/pve-tools && -d $src/lib && -d $src/modules ]] || err "Source at $src does not look like pve-tools."

  # Stage next to the target, then swap, so a failed copy never leaves a broken install.
  rm -rf "$PREFIX.new" "$PREFIX.old"
  mkdir -p "$PREFIX.new"
  cp -R "$src/." "$PREFIX.new/"
  rm -rf "$PREFIX.new/.git"
  chmod 0755 "$PREFIX.new/pve-tools" "$PREFIX.new/install.sh"
  [[ -d $PREFIX ]] && mv "$PREFIX" "$PREFIX.old"
  mv "$PREFIX.new" "$PREFIX"
  rm -rf "$PREFIX.old"

  mkdir -p "$(dirname "$BIN_LINK")"
  ln -sfn "$PREFIX/pve-tools" "$BIN_LINK"

  ok "Installed pve-tools $("$PREFIX/pve-tools" version) to $PREFIX"
  ok "Run it with: pve-tools"
}

do_uninstall() {
  [[ $EUID -eq 0 ]] || err "Run the uninstaller as root."
  rm -f "$BIN_LINK" "$NAG_HOOK" "$NAG_SCRIPT"
  rm -rf "$PREFIX"
  ok "pve-tools removed."
  say "Repository changes were left in place."
  say "To restore the subscription notice: apt-get install --reinstall proxmox-widget-toolkit"
}

usage() {
  cat <<EOF
Usage: install.sh [--local | --uninstall]
  (none)        Download $REPO@$REF and install to $PREFIX
  --local       Install from the directory this script is in
  --uninstall   Remove pve-tools
EOF
}

main() {
  case ${1:-} in
    "")                    do_install remote ;;
    --local)               do_install local ;;
    --uninstall)           do_uninstall ;;
    -h | --help)           usage ;;
    *)                     usage >&2; exit 1 ;;
  esac
}

main "$@"
