#!/bin/bash
# Compare what is installed on this machine against what this repository says.
# Read-only: it never writes, never restarts anything, needs no root for the
# file comparison (only the live checks at the end want sudo).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/files.sh"

ok=0; diffn=0; missing=0

cmp_one() {   # path, mode, body
  local path="$1" mode="$2" body="$3"
  if [ ! -e "$path" ]; then
    printf '  MISSING   %s\n' "$path"; missing=$((missing+1)); return
  fi
  if [ ! -r "$path" ]; then
    printf '  UNREADABLE %s (re-run with sudo to compare)\n' "$path"; missing=$((missing+1)); return
  fi
  if ! printf '%s' "$body" | diff -q - "$path" >/dev/null 2>&1; then
    printf '  DIFFERS   %s\n' "$path"; diffn=$((diffn+1))
    printf '%s' "$body" | diff -u --label REPOSITORY --label MACHINE - "$path" | sed -n '3,30p' | sed 's/^/      /'
    return
  fi
  if [ "$mode" = "0755" ] && [ ! -x "$path" ]; then
    printf '  NOT EXEC  %s (contents match, execute bit missing)\n' "$path"; diffn=$((diffn+1)); return
  fi
  printf '  OK        %s\n' "$path"; ok=$((ok+1))
}

echo "=== Files ==="
for entry in "${FILES[@]}"; do
  IFS='|' read -r path mode fn <<< "$entry"
  cmp_one "$path" "$mode" "$("$fn")"$'\n'
done

# The two machine-specific files cannot be compared literally: they carry this
# machine's root UUID and the swap file's physical offset. Check their shape.
echo
echo "=== Machine-specific files ==="
shape() {   # path, regex, description
  if [ ! -e "$1" ]; then printf '  MISSING   %s\n' "$1"; missing=$((missing+1)); return; fi
  if grep -qE "$2" "$1"; then printf '  OK        %s (%s)\n' "$1" "$3"; ok=$((ok+1));
  else printf '  DIFFERS   %s (expected %s)\n' "$1" "$3"; diffn=$((diffn+1)); fi
}
shape /etc/initramfs-tools/conf.d/resume '^RESUME=UUID=[0-9a-f-]+$' 'RESUME=UUID=...'
shape /etc/default/grub.d/99-macbook-suspend.cfg \
      'mem_sleep_default=s2idle.*pcie_port_pm=off.*resume=UUID=.*resume_offset=[0-9]+' \
      'all four kernel parameters'

echo
echo "=== Summary ==="
printf 'matching: %s | differing: %s | missing: %s\n' "$ok" "$diffn" "$missing"

echo
echo "=== Live state ==="
if [ -x /usr/local/sbin/sleep-check ]; then
  if [ "$(id -u)" -eq 0 ]; then sleep-check; else echo "  run 'sudo ./verify.sh' (or 'sudo sleep-check') for the live checks"; fi
else
  echo "  sleep-check is not installed yet"
fi

echo
echo "Neither of the above proves the sleep hooks actually run. Only this does:"
echo "  sudo rtcwake -m no -s 60; sudo systemctl suspend -i"
echo "  sudo tail -2 /var/log/macbook-sleep-wifi.log"

[ "$diffn" -eq 0 ] && [ "$missing" -eq 0 ]
