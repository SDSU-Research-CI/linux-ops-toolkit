#!/usr/bin/env bash
# post-patch-check.sh
# Read-only check to run AFTER patching and rebooting. It compares the server
# with what pre-patch-check.sh saw before, and prints a note for the ServiceNow ticket.
# Nothing is changed by this script.
#
# Usage (from the repo folder):  bash after-patch-check.sh
# Exit code: 0 all good, 1 review the warnings, 2 a problem needs fixing.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib-common.sh
source "$HERE/../lib-common.sh"

PROBLEMS=0
REVIEW=0
problem() { bad "$*"; PROBLEMS=$((PROBLEMS + 1)); }
review() { warn "$*"; REVIEW=$((REVIEW + 1)); }

printf '%sAfter-patch check%s: this only looks around. It does not change anything.\n' "$C_BLD" "$C_RST"
printf 'Meaning of the tags:  [ OK ] fine   [WARN] review   [FAIL] needs fixing\n'

state="/var/tmp/patch-check-$(hostname -s)"
PRE_DATE=""; PRE_KERNEL=""; PRE_BOOTID=""; PRE_COUNT=""; PRE_KERNEL_UPDATE=""
have_state=0
if [[ -r "$state.env" ]]; then
  # shellcheck disable=SC1090
  source "$state.env"; have_state=1
fi

section "Host"
info "$(hostname -f 2>/dev/null || hostname)  |  $(. /etc/os-release && echo "$PRETTY_NAME")"
if (( have_state )); then
  info "Compared with the pre-patch check from: $PRE_DATE"
else
  review "No saved pre-patch check found. Next time run patch-check.sh before patching. Only a basic check follows"
fi

section "Reboot"
now_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
rebooted="unknown"
if (( have_state )); then
  if [[ "$now_boot" != "$PRE_BOOTID" ]]; then
    rebooted="yes"; ok "The server was rebooted since the pre-patch check ($(uptime -p))"
  else
    rebooted="no"; review "The server has NOT been rebooted since the pre-patch check. Reboot with:  sudo reboot"
  fi
else
  info "Up since: $(uptime -s 2>/dev/null)"
fi
if [[ -f /var/run/reboot-required ]]; then review "Still waiting for a reboot (reboot-required is set)"; else ok "No reboot pending"; fi

section "Kernel"
now_kernel=$(uname -r)
latest=$(ls /boot/vmlinuz-* 2>/dev/null | sed 's|/boot/vmlinuz-||' | sort -V | tail -n1)
if (( have_state )); then info "Before: $PRE_KERNEL    Now: $now_kernel"; else info "Running kernel: $now_kernel"; fi
if [[ -n "$latest" && "$latest" != "$now_kernel" ]]; then
  review "Newest installed kernel is $latest but $now_kernel is running. Reboot to use it"
else
  ok "Running the newest installed kernel"
fi
kernel_changed="no"; [[ -n "$PRE_KERNEL" && "$PRE_KERNEL" != "$now_kernel" ]] && kernel_changed="yes"

section "What was installed"
installed=0
if (( have_state )) && [[ -r /var/log/dpkg.log ]]; then
  installed=$(awk -v t="$PRE_DATE" '($1" "$2) >= t && $3=="upgrade"' /var/log/dpkg.log 2>/dev/null | wc -l)
  info "Packages upgraded since the pre-patch check: $installed (expected about $PRE_COUNT)"
  if (( installed == 0 && ${PRE_COUNT:-0} > 0 )); then review "No upgrades were recorded. Did 'sudo apt upgrade' run?"; fi
fi
remaining=$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)
if (( remaining == 0 )); then ok "No updates left to install"; else review "$remaining update(s) still waiting (held back or newly released). Run: apt list --upgradable"; fi

section "Services"
for svc in ssh sssd; do
  if systemctl list-unit-files "$svc.service" 2>/dev/null | grep -q "$svc.service"; then
    if systemctl is-active --quiet "$svc"; then ok "$svc running"; else problem "$svc is NOT running (try: sudo systemctl restart $svc)"; fi
  fi
done
failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
if [[ -n "$failed" ]]; then problem "Failed services: $failed (look with: systemctl status NAME)"; else ok "No failed services"; fi
if have nvidia-smi; then
  if nvidia-smi -L >/dev/null 2>&1; then ok "GPU driver is working"; else problem "GPU driver not responding (kernel update may need the driver rebuilt)"; fi
fi
dom=$(detect_domain)
[[ -n "$dom" ]] && info "Joined to domain: $dom"
avail=$(df -Pm / | awk 'NR==2 {print $4}')
info "Free space on /: ${avail} MB"

section "Verdict"
if (( PROBLEMS > 0 )); then verdict="PROBLEM ($PROBLEMS item(s) need fixing)"; rc=2
elif (( REVIEW > 0 )); then verdict="REVIEW ($REVIEW item(s))"; rc=1
else verdict="ALL GOOD"; rc=0; fi
printf '%s%s%s\n' "$C_BLD" "$verdict" "$C_RST"
case $rc in
  0) info "Next: paste the note below into the ServiceNow ticket and close the patching task." ;;
  1) info "Next: read each [WARN]. Fix or explain them in the ticket." ;;
  2) info "Next: fix each [FAIL] first. Ask John or Alison if you are stuck. Do not close the ticket yet."
     info "For a full look at the machine:  bash health-check.sh --save   (keeps a copy for the ticket)" ;;
esac

section "Paste into the ServiceNow ticket (after patching)"
echo "Post-patch check $(date '+%Y-%m-%d %H:%M') on $(hostname -s): $verdict."
echo "Packages upgraded: $installed. Updates still waiting: $remaining."
echo "Kernel: ${PRE_KERNEL:-unknown} -> $now_kernel (updated: $kernel_changed)."
echo "Rebooted: $rebooted. Up since: $(uptime -s 2>/dev/null)."
echo "Services: ssh $(systemctl is-active ssh 2>/dev/null || echo n/a), sssd $(systemctl is-active sssd 2>/dev/null || echo n/a). Failed units: ${failed:-none}."
exit $rc
