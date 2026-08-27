#!/usr/bin/env bash
# verify-install.sh - assert a machine installed from this image is actually correct.
#
# Run it on the box, or over ssh:
#   ssh <host> 'sudo bash -s' < scripts/verify-install.sh
#
# This exists because checking that services are RUNNING is not the same as
# checking the install is right. A box can have every unit green and still be
# pointed at the wrong image, in which case the next auto-update replaces the
# customised OS with its upstream base. That is the failure this catches first.
set -uo pipefail

EXPECTED_IMAGE="${EXPECTED_IMAGE:-ghcr.io/aniravi24/iot-devbox}"
FAILED=0

ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILED=$((FAILED + 1)); }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$*"; }

[ "$(id -u)" = 0 ] || { echo "run as root (bootc status needs it)" >&2; exit 2; }

echo "== image identity =="
# The check that matters most. An ISO built with `generate-iso recipe` records
# the recipe's base-image here instead of the published one, leaving the box
# with no route to updates - and `bootc upgrade` would then pull stock Fedora
# over the top of everything this image adds.
BOOTED="$(bootc status --format=json 2>/dev/null \
  | jq -r '.status.booted.image.image.image // empty')"
if [ -z "$BOOTED" ]; then
  bad "cannot read the booted image ref from bootc status"
elif [ "${BOOTED%%:*}" = "${EXPECTED_IMAGE%%:*}" ] || [ "$BOOTED" = "$EXPECTED_IMAGE" ]; then
  ok "booted image is $BOOTED"
else
  bad "booted image is $BOOTED, expected $EXPECTED_IMAGE"
  echo "       Fix:  bootc switch $EXPECTED_IMAGE && systemctl reboot"
fi

# Contacts the registry. `bootc status` does not - it only prints local state,
# so it passes on a box that can no longer reach its image at all.
if bootc upgrade --check >/dev/null 2>&1; then
  ok "registry reachable (bootc upgrade --check)"
else
  bad "cannot reach the update registry"
fi

echo "== autopilot =="
for u in bootc-fetch-apply-updates.timer greenboot-healthcheck.service; do
  if systemctl is-enabled "$u" >/dev/null 2>&1; then ok "$u enabled"; else bad "$u not enabled"; fi
done
# Stock timing is every 8h with 2h jitter, and the service reboots when it
# stages an update - so an unpinned timer can reboot the box mid-afternoon.
CAL="$(systemctl show bootc-fetch-apply-updates.timer -p TimersCalendar --value 2>/dev/null)"
case "$CAL" in
  *04:00:00*) ok "updates apply at 04:00" ;;
  *)          bad "update timer is not pinned to 04:00 (got: ${CAL:-stock 8-hourly})" ;;
esac

echo "== services =="
for u in sshd docker tailscaled firewalld avahi-daemon auditd; do
  if systemctl is-active --quiet "$u"; then ok "$u active"; else bad "$u not active"; fi
done

echo "== reachability =="
# `is-active` is true for a tailscaled that has never logged in, and a box with
# no tailnet identity is LAN-only - which defeats the point of a headless annex.
if [ "$(tailscale status --json 2>/dev/null | jq -r .BackendState)" = Running ]; then
  ok "tailscale logged in"
else
  bad "tailscale running but not logged in - run: tailscale up"
fi

echo "== console / panel =="
if grep -q 'consoleblank=' /proc/cmdline; then ok "consoleblank set"; else bad "consoleblank missing from cmdline"; fi
if grep -q 'loglevel=3'    /proc/cmdline; then ok "kernel chatter off the console"; else bad "loglevel not set - audit spam will hit the panel"; fi
# Fedora builds without CONFIG_FB_DEVICE, so /sys/class/graphics/fb0 never
# exists and anything keyed on it cannot work here. Report rather than fail.
if [ -e /sys/class/graphics/fb0/blank ]; then
  ok "fbdev present - panel blanking can mirror the console"
else
  warn "no fbdev on this kernel: console blanks but the backlight stays powered"
fi

echo "== disk =="
# Anaconda's default LVM layout does not fill the disk: a 931 GB NVMe came out
# of a stock install with a 15 GB root and the rest idle in the volume group.
# A dev box exhausts that on one repo clone plus a container pull, and the
# symptom is an unrelated "no space left on device" mid-operation. Reported,
# not fixed: resizing a filesystem is your call, not something to do silently
# on every boot.
AVAIL_G=$(df -BG --output=avail /var 2>/dev/null | tail -1 | tr -dc '0-9')
VGFREE_G=$(vgs --noheadings -o vg_free --units g --nosuffix 2>/dev/null | tr -d ' ' | head -1 | cut -d. -f1)
if [ -n "${AVAIL_G:-}" ] && [ "$AVAIL_G" -lt 10 ]; then
  bad "only ${AVAIL_G}G free on /var"
else
  ok "${AVAIL_G:-?}G free on /var"
fi
if [ -n "${VGFREE_G:-}" ] && [ "$VGFREE_G" -gt 20 ]; then
  warn "${VGFREE_G}G is unallocated in the volume group - root does not fill the disk"
  echo "       To claim it:  lvextend -l +100%FREE $(findmnt -no SOURCE /var | sed 's/\[.*//') && xfs_growfs /var"
  echo "       (/sysroot is read-only on ostree; grow through /var)"
fi

echo "== health =="
N="$(systemctl --failed --no-legend | wc -l)"
if [ "$N" -eq 0 ]; then
  ok "no failed units"
else
  bad "$N failed unit(s)"
  systemctl --failed --no-legend | sed 's/^/       /'
fi

echo
if [ "$FAILED" -eq 0 ]; then
  printf '\033[32mall checks passed\033[0m\n'
else
  printf '\033[31m%s check(s) failed\033[0m\n' "$FAILED"
fi
exit "$FAILED"
