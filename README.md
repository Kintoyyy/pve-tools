# pve-tools

A Bash toolkit for Proxmox VE hosts with a whiptail TUI. It covers post-install setup, VM/LXC management, appliance installers (VMs and an OpenWrt container), backups and snapshots, PCIe passthrough, and routine maintenance. It supports **Proxmox VE 7, 8 and 9**.

## Install

Run as root on the Proxmox host:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Kintoyyy/pve-tools/main/install.sh)"
```

This installs to `/opt/pve-tools` and links the `pve-tools` command into `/usr/local/bin`. To install a specific branch, tag or commit, set `PVE_TOOLS_REF`:

```bash
PVE_TOOLS_REF=v0.2.0 bash -c "$(curl -fsSL https://raw.githubusercontent.com/Kintoyyy/pve-tools/main/install.sh)"
```

To install from a local clone, run `./install.sh --local`.

## Usage

```
pve-tools              # open the menu
pve-tools --dry-run    # browse the menu; changes are printed, not executed
pve-tools passthrough  # open the PCIe passthrough menu directly
pve-tools passthrough status   # print the passthrough status report (no TUI)
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

**Appliance installers**

Each installer downloads a vendor disk image and builds a ready-to-run VM from it. A wizard walks through version, image (UEFI or BIOS), VM ID, name, storage, bridges, CPU/RAM/disk, and options (start at boot, start when done, convert to template).

| Appliance | Source | Defaults |
|---|---|---|
| MikroTik RouterOS CHR | Official `download.mikrotik.com` image. The stable, long-term and testing versions are looked up live. | SeaBIOS, serial console, 8G disk, converted to a template |
| KiTifi | Controller v2.0/v2.2 (MikroTik-based) or Standalone v1.3/v2.1/v2.2-beta (OpenWrt-based) | UEFI. 128G disk for the controller, 8G for standalone |
| WiFi5 Soft vendo | Version list read live from `files.wifi5-soft.com`. Defaults to the newest non-rc release. | UEFI, 2 NICs, 128G disk, start at boot, started when done |
| OpenWrt (LXC) | x86-64 rootfs from `downloads.openwrt.org`. The newest release of each recent series is looked up live, plus the daily snapshot. | Unprivileged container with nesting, 256 MB, 2 cores, 0.5G rootfs. WAN on eth0 (DHCP), LAN on eth1 (static, 192.168.0.1/24). Optional root password. LuCI comes with releases and is installed from the feed for snapshots |

All VMs use `virtio-scsi-single` with `iothread` and `discard`, `cpu host`, and virtio NICs. UEFI images get an EFI disk without pre-enrolled Secure Boot keys, so the unsigned images can boot. Downloads are cached in `/var/cache/pve-tools/images`, and the cache can be cleared from the menu. The VM installers require PVE 7.2 or newer, for `import-from`. OpenWrt is set up through `pct exec` after first boot: it patches dnsmasq's procd jail, which cannot start in an unprivileged container, and writes the WAN/LAN config with UCI.

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
- Undo: restore every file changed in a previous pve-tools session.

**PCIe passthrough**
- Status and preflight report: IOMMU state, IRQ remapping, VFIO modules, devices on vfio-pci, devices with no driver, and the passthrough modprobe configs.
- Enable IOMMU on the kernel cmdline, for GRUB (`/etc/default/grub`) or systemd-boot (`/etc/kernel/cmdline`). Options: `iommu=pt`, ACS override, `relax_rmrr`. A before/after preview is shown.
- Add the VFIO modules to `/etc/modules`. On kernel 6.2+, `vfio_virqfd` is handled correctly.
- Bind devices to vfio-pci in one of three ways: per-device with `driverctl`, by `vendor:device` IDs, or by blacklisting the driver. It warns when:
  - a selected NIC carries host traffic;
  - other devices share the IOMMU group;
  - an ID or blacklist rule would also capture devices you didn't select.
- Toggle `allow_unsafe_interrupts` and view the IOMMU groups.
- Repair EFI boot: initialize the ESP with `proxmox-boot-tool`, or switch from `grub-pc` to `grub-efi`.
- Recover a device that has no driver (e.g. ixgbe with an unsupported SFP+ module).
- HPE ProLiant RMRR slot exclusion with `conrep`.
- Apply changes (initramfs and bootloader refresh). Pending changes are flagged in the menu, and you're prompted to apply them on exit.

## Safety

- Every command that changes the system goes through a single wrapper. `--dry-run` uses it to print the commands without running them.
- Each run is a backup session. Before a file is first changed, its original is saved under `/var/backups/pve-tools/<session>/`, and new files are recorded so they can be removed. **Maintenance → Undo** (also in the passthrough menu) restores a whole session.
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
modules/*.sh         postinstall, guests, appliances, backup, maintenance, passthrough
```

## Development

Contributors on Windows: `.gitattributes` forces LF line endings. Check the result with `git ls-files --eol`.

Lint with `shellcheck -x pve-tools install.sh lib/*.sh modules/*.sh`.
