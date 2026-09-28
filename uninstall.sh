#!/bin/bash
# Remove everything install.sh put on this machine and return the defaults.
# The swap file is left alone: it is useful on its own and removing it is a
# separate decision. Print what would happen with --dry-run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/files.sh"

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1
[ "$(id -u)" -eq 0 ] || { echo "run me with sudo" >&2; exit 1; }

run() { if [ "$DRY" -eq 1 ]; then echo "    would run: $*"; else "$@"; fi; }

echo "==> disabling services"
run systemctl disable --now disable-wake-sources.service wifi-recover.timer

echo "==> removing files"
for entry in "${FILES[@]}"; do
  IFS='|' read -r path mode fn <<< "$entry"
  if [ -e "$path" ]; then
    if [ "$DRY" -eq 1 ]; then echo "    would remove $path"; else rm -f "$path"; echo "    removed $path"; fi
  fi
done
for path in /etc/initramfs-tools/conf.d/resume \
            /etc/default/grub.d/99-macbook-suspend.cfg \
            /etc/systemd/system/disable-wake-sources.service \
            /etc/systemd/system/wifi-recover.service \
            /etc/systemd/system/wifi-recover.timer; do
  if [ -e "$path" ]; then
    if [ "$DRY" -eq 1 ]; then echo "    would remove $path"; else rm -f "$path"; echo "    removed $path"; fi
  fi
done

echo "==> rebuilding initramfs, GRUB and the dconf database"
run systemctl daemon-reload
run dconf update
run update-initramfs -u -k all
run update-grub

cat <<'MSG'

Done. Reboot to go back to the stock behaviour.

Left in place on purpose:
  /swap.img and its /etc/fstab entry   - useful regardless; remove by hand if you want it gone
  /etc/dconf/profile/user              - harmless, other system-wide settings may rely on it
  /var/log/macbook-sleep-*.log         - your measurements
MSG
