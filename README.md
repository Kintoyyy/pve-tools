# pve-tools

A Bash toolkit for Proxmox VE hosts with a whiptail TUI. It covers post-install setup, VM/LXC management, backups and snapshots, and routine maintenance. It supports **Proxmox VE 7, 8 and 9**.

## Install

Run as root on the Proxmox host:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Kintoyyy/pve-tools/main/install.sh)"
```

This installs to `/opt/pve-tools` and links the `pve-tools` command into `/usr/local/bin`. To install a specific branch, tag or commit, set `PVE_TOOLS_REF`:

```bash
PVE_TOOLS_REF=v0.1.0 bash -c "$(curl -fsSL https://raw.githubusercontent.com/Kintoyyy/pve-tools/main/install.sh)"
```

To install from a local clone, run `./install.sh --local`.

## Usage

```
pve-tools              # open the menu
pve-tools --dry-run    # browse the menu; changes are printed, not executed
pve-tools update       # update to the latest version
pve-tools uninstall    # remove pve-tools
pve-tools version
```

## Features

**Post-install setup**
- Disable the enterprise repos. Both `.list` and the deb822 `.sources` format (PVE 9) are handled.
- Enable the `pve-no-subscription` repo and the matching Ceph no-subscription repo.
- Remove the "No valid subscription" dialog. An apt hook re-applies the patch after `proxmox-widget-toolkit` upgrades.
- Disable the HA services, offered on standalone nodes only.
- `apt dist-upgrade`, with a reboot prompt when a newer kernel is installed.

**VM / LXC management**
- Overview of every guest on the node.
- Start, shut down, reboot or stop several guests at once.
- Start all / shut down all, which follows the guests' boot order.
- Container console (`pct enter`) or VM serial console (`qm terminal`).
- View a guest's config.

**Backups & snapshots**
- Run `vzdump` on demand to any backup storage, in snapshot, suspend or stop mode.
- Create, list, roll back and delete snapshots, optionally including VM RAM state.
- Prune backups with keep-last/daily/weekly/monthly. A dry-run preview is shown before anything is deleted.
- List the scheduled backup jobs.

**System maintenance**
- Remove old kernels. The running, newest and pinned kernels are protected, and you see apt's removal list before confirming.
- Storage and disk health: `pvesm`, `df`, ZFS pool status and SMART.
- Node and cluster info.
- Update packages inside running containers (Debian/Ubuntu, Alpine, Fedora/RHEL family, Arch, openSUSE).
- `apt autoremove` and `apt clean`.

## Safety

- Every command that changes the system goes through a single wrapper. `--dry-run` uses it to print the commands without running them.
- Before any system file is edited, a copy is saved under `/var/backups/pve-tools/`.
- Every action is logged to `/var/log/pve-tools.log`.
- Destructive actions (stop, rollback, delete, prune, kernel purge) default to **No**.

## Uninstall

```bash
pve-tools uninstall
```

This removes the tool, the nag patch script and its apt hook. Repository changes are left in place. To bring back the stock subscription dialog, run `apt-get install --reinstall proxmox-widget-toolkit`.

## Layout

```
pve-tools            entrypoint (CLI + main menu)
install.sh           installer / uninstaller
lib/common.sh        logging, PVE detection, run() / write_file() wrappers, guest helpers
lib/ui.sh            whiptail wrappers and guest/storage pickers
modules/*.sh         postinstall, guests, backup, maintenance
```

## Development

Contributors on Windows: `.gitattributes` forces LF line endings. Check the result with `git ls-files --eol`.

Lint with `shellcheck -x pve-tools install.sh lib/*.sh modules/*.sh`.
