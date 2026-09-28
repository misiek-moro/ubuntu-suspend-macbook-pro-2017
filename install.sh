#!/bin/bash
# Install the suspend/hibernate configuration for a MacBookPro14,1 running
# Ubuntu 24.04. Safe to run more than once: every step is idempotent.
#
#   sudo ./install.sh --dry-run    show what would change, touch nothing
#   sudo ./install.sh              install
#   sudo ./install.sh --force      install on a machine that is not a 14,1
#
# What it does NOT do: reboot, or change anything about your kernel packages.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/files.sh"

DRY=0; FORCE=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --force)   FORCE=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "run me with sudo" >&2; exit 1; }

MODEL="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
echo "==> machine: $MODEL, kernel $(uname -r)"
if [ "$MODEL" != "MacBookPro14,1" ] && [ "$FORCE" -eq 0 ]; then
  cat >&2 <<MSG

This configuration was measured on a MacBookPro14,1 only. Other models have
different PCIe controllers and a different Wi-Fi chip, so the fixes here may do
nothing, or may make suspend worse. Re-run with --force if you know that.
MSG
  exit 1
fi

say() { echo "==> $*"; }
run() { if [ "$DRY" -eq 1 ]; then echo "    would run: $*"; else "$@"; fi; }

SWAP=/swap.img
SWAP_MIN=$((17*1000*1000*1000))   # 16 GiB with room to spare

# ---------------------------------------------------------------- swap file
cur=$(swapon --show=NAME,SIZE --bytes --noheadings 2>/dev/null | awk -v s="$SWAP" '$1==s{print $2}')
if [ -n "${cur:-}" ] && [ "$cur" -ge "$SWAP_MIN" ]; then
  say "swap file already $((cur/1000/1000/1000)) GB, leaving it alone"
else
  say "creating a 20 GB swap file at $SWAP (hibernation needs to fit RAM in it)"
  if [ "$DRY" -eq 0 ]; then
    swapoff "$SWAP" 2>/dev/null || true
    rm -f "$SWAP"
    fallocate -l 20G "$SWAP"
    chmod 600 "$SWAP"
    mkswap "$SWAP" >/dev/null
    swapon "$SWAP"
  else
    echo "    would recreate $SWAP at 20G"
  fi
fi
if ! grep -qE "^[^#]*[[:space:]]$SWAP[[:space:]]" /etc/fstab && ! grep -qE "^$SWAP[[:space:]]" /etc/fstab; then
  say "adding $SWAP to /etc/fstab"
  [ "$DRY" -eq 1 ] || printf '%s none swap sw 0 0\n' "$SWAP" >> /etc/fstab
fi

# ------------------------------------------------- kernel parameters, resume
ROOT_UUID=$(findmnt -no UUID / || true)
[ -n "$ROOT_UUID" ] || [ "$DRY" -eq 0 ] || ROOT_UUID="<this machine's root UUID>"
if [ -f "$SWAP" ]; then
  OFFSET=$(filefrag -v "$SWAP" 2>/dev/null | awk '$1=="0:"{print $4}' | tr -d '.')
elif [ "$DRY" -eq 1 ]; then
  OFFSET="<computed once the swap file exists>"
else
  OFFSET=""
fi
[ -n "$ROOT_UUID" ] && [ -n "$OFFSET" ] || { echo "could not read root UUID or swap offset" >&2; exit 1; }
say "root UUID $ROOT_UUID, swap offset $OFFSET"

write_generated() {   # path, mode, content
  local path="$1" mode="$2" body="$3"
  if [ -f "$path" ] && [ "$(cat "$path")" = "$body" ]; then
    echo "    unchanged $path"; return
  fi
  if [ "$DRY" -eq 1 ]; then echo "    would write $path"; return; fi
  mkdir -p "$(dirname "$path")"
  printf '%s' "$body" > "$path"
  chmod "$mode" "$path"
  echo "    wrote     $path"
}

say "kernel parameters and hibernation image location"
write_generated /etc/initramfs-tools/conf.d/resume 0644 "RESUME=UUID=$ROOT_UUID
"
write_generated /etc/default/grub.d/99-macbook-suspend.cfg 0644 "GRUB_CMDLINE_LINUX_DEFAULT=\"\$GRUB_CMDLINE_LINUX_DEFAULT mem_sleep_default=s2idle pcie_port_pm=off resume=UUID=$ROOT_UUID resume_offset=$OFFSET\"
"

# ------------------------------------------------------------- static files
say "configuration files, hooks and tools"
for entry in "${FILES[@]}"; do
  IFS='|' read -r path mode fn <<< "$entry"
  body="$("$fn")"$'\n'
  if [ -f "$path" ] && [ "$(cat "$path")" = "$body" ] && [ "$(stat -c '%a' "$path")" = "${mode#0}" ]; then
    echo "    unchanged $path"; continue
  fi
  if [ "$DRY" -eq 1 ]; then echo "    would write $path"; continue; fi
  mkdir -p "$(dirname "$path")"
  printf '%s' "$body" > "$path"
  chmod "$mode" "$path"
  echo "    wrote     $path"
done

# ------------------------------------------------------------- activation
say "rebuilding initramfs and GRUB configuration"
run update-initramfs -u -k all
run update-grub

say "applying the GNOME desktop defaults"
[ -f /etc/dconf/profile/user ] || { say "creating /etc/dconf/profile/user"; \
  [ "$DRY" -eq 1 ] || printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user; }
run dconf update

say "enabling services"
run systemctl daemon-reload
run systemctl enable --now disable-wake-sources.service
run systemctl enable --now wifi-recover.timer

if [ "$DRY" -eq 1 ]; then
  echo; echo "Dry run finished. Nothing was changed."
  exit 0
fi

cat <<'MSG'

Done. Two things left, in this order:

  1. Reboot. Kernel parameters and the logind settings only take effect then.
  2. Run ./verify.sh and then, as the document insists, one real suspend:

         sudo rtcwake -m no -s 60; sudo systemctl suspend -i
         sudo tail -2 /var/log/macbook-sleep-wifi.log

     Two fresh entries there are the only proof the sleep hooks actually run.
     Their absence is silent: everything else looks fine and hibernation fails
     days later.
MSG
