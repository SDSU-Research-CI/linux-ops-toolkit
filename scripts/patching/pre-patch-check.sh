#!/usr/bin/env bash
# pre-patch-check.sh
# Read-only check to run BEFORE patching a server or workstation.
# Rule of thumb: patch only when nobody is connected. If someone is, ask for
# approval and a restart window first. Nothing is changed by this script.
#
# Usage (from the repo folder):  bash patch-check.sh
# Exit code: 0 safe to patch, 1 patch with caution, 2 do not patch now.
# At the end it prints a note you can paste into the ServiceNow ticket.
# The person running the check is not counted as "someone connected".
#
# Order of work:  1) bash patch-check.sh   2) sudo apt upgrade   3) sudo reboot
#                 4) bash after-patch-check.sh  (confirms it all worked)
# This script refreshes the package list (apt update) but installs nothing.
# It saves what it found so after-patch-check.sh can compare before and after.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib-common.sh
source "$HERE/../lib-common.sh"

BLOCKERS=0
CAUTIONS=0
REASONS=()
block() { bad "$*"; BLOCKERS=$((BLOCKERS + 1)); REASONS+=("$*"); }
caution() { warn "$*"; CAUTIONS=$((CAUTIONS + 1)); }

printf '%sPre-patch check%s: this only looks around. It does not install or change anything.\n' "$C_BLD" "$C_RST"
printf 'Meaning of the tags:  [ OK ] fine   [WARN] review before patching   [FAIL] stop, do not patch yet\n'

section "Host"
info "$(hostname -f 2>/dev/null || hostname)  |  $(. /etc/os-release && echo "$PRETTY_NAME")  |  kernel $(uname -r)"
info "Uptime: $(uptime -p)"

section "Who is connected"
# Admin accounts that never count as "someone connected" (extra stsadmin
# sessions are usually a dropped connection or a forgotten logout).
# Add more names separated by spaces if needed.
ADMIN_USERS="stsadmin"
mytty=$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')
sessions=$(who 2>/dev/null | awk -v t="$mytty" -v a="$ADMIN_USERS" 'BEGIN{n=split(a,x," "); for(i=1;i<=n;i++) adm[x[i]]=1} $2 != t && !($1 in adm)')
admin_other=$(who 2>/dev/null | awk -v t="$mytty" -v a="$ADMIN_USERS" 'BEGIN{n=split(a,x," "); for(i=1;i<=n;i++) adm[x[i]]=1} $2 != t && ($1 in adm)')
nsessions=0
[[ -n "$sessions" ]] && nsessions=$(echo "$sessions" | wc -l)
if [[ -z "$sessions" ]]; then
  ok "Nobody else is connected (admin sessions are not counted)"
else
  block "Other people are connected:"
  REASONS[-1]="Other people are connected: $(echo "$sessions" | awk '{print $1}' | sort -u | tr '\n' ' ' | sed 's/ $//')"
  echo "$sessions" | sed 's/^/       /'
  info "Columns: user, terminal, login time, where from."
fi
if [[ -n "$admin_other" ]]; then
  info "Other admin sessions (ignored, may be old or forgotten):"
  echo "$admin_other" | sed 's/^/       /'
fi
if have tmux && tmux ls >/dev/null 2>&1; then caution "tmux sessions exist for the current user"; fi
if have screen && screen -ls 2>/dev/null | grep -q Socket; then caution "screen sessions exist for the current user"; fi
mapfile -t others < <(ps -eo user:20,pid,etimes,pcpu,comm --sort=-pcpu 2>/dev/null | awk 'NR>1 && $1!="root" && $1!="systemd+" && $1!="syslog" && $1!="message+" && $1!="www-data" && $1!="sssd" && $4>=25.0 {print}' | head -n 5)
if (( ${#others[@]} > 0 )); then
  caution "User processes using 25 percent CPU or more (possible long jobs):"
  printf '       %s\n' "${others[@]}"
else
  ok "No heavy user processes"
fi
if have nvidia-smi; then
  gpu=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null)
  if [[ -n "$gpu" ]]; then block "GPU jobs are running:"; echo "$gpu" | sed 's/^/       /'; else ok "No GPU jobs"; fi
fi

lowdisk=0
section "Disk space needed for updates"
for m in / /boot /var; do
  mountpoint -q "$m" 2>/dev/null || [[ "$m" == "/" ]] || continue
  avail=$(df -Pm "$m" | awk 'NR==2 {print $4}')
  if (( avail < 1024 )); then block "$m has only ${avail} MB free (updates need about 1 GB)"; lowdisk=1; else ok "$m has ${avail} MB free"; fi
done
if (( lowdisk )); then
  info "To free space: run  bash health-check.sh  for a full look at the disk."
  info "Safe first steps:  sudo apt autoremove --purge   and   sudo apt clean"
  info "Find big folders:  sudo du -xh / --max-depth=2 | sort -h | tail -15"
  info "Do not delete user data. Ask the server owner or John if unsure."
fi

section "Package state"
# unattended-upgrade-shutdown is a helper that always runs on Ubuntu, so it is ignored.
busy=$(
  { pgrep -a -x 'apt|apt-get|dpkg' 2>/dev/null
    pgrep -af 'unattended-upgr|apt.systemd.daily' 2>/dev/null | grep -v 'unattended-upgrade-shutdown'
  } | sort -u
)
if [[ -n "$busy" ]]; then
  block "An update is already running on this machine:"
  echo "$busy" | sed 's/^/       /'
  info "Wait a few minutes and run this check again."
else
  ok "No other package manager running"
fi
held=$(apt-mark showhold 2>/dev/null)
[[ -n "$held" ]] && caution "Held packages: $(echo "$held" | tr '\n' ' ')"
if [[ -z "$busy" ]]; then
  SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"
  info "Refreshing the package list (apt update). This installs nothing."
  if $SUDO apt-get update -qq >/dev/null 2>&1; then
    ok "Package list is fresh"
  else
    caution "Could not refresh the package list (sudo or network problem). The numbers below may be old"
  fi
fi
upg_list=$(apt list --upgradable 2>/dev/null | tail -n +2)
upg=0
[[ -n "$upg_list" ]] && upg=$(echo "$upg_list" | wc -l)
info "Updates waiting to be installed: $upg"
kernel_update="no"
echo "$upg_list" | cut -d/ -f1 | grep -qE '^linux-(image|generic|modules|headers)' && kernel_update="yes"
reboot_expected="no"
echo "$upg_list" | cut -d/ -f1 | grep -qE '^(linux-image|libc6|systemd$|dbus$)' && reboot_expected="yes"
[[ "$kernel_update" == "yes" ]] && info "A new kernel is included. A reboot will be required."
if [[ -f /var/run/reboot-required ]]; then caution "A reboot is already pending from an earlier update"; else ok "No reboot pending"; fi
last=$(grep -h '^Start-Date' /var/log/apt/history.log 2>/dev/null | tail -n1 | sed 's/Start-Date: //')
info "Last apt activity: ${last:-unknown}"

section "Services that should survive a restart"
for svc in ssh sssd; do
  if systemctl list-unit-files "$svc.service" 2>/dev/null | grep -q "$svc.service"; then
    if systemctl is-active --quiet "$svc"; then ok "$svc running"; else caution "$svc is not running now"; fi
  fi
done
failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
[[ -n "$failed" ]] && caution "Already failed before patching: $failed"

section "Verdict"
if (( BLOCKERS > 0 )); then
  verdict="DO NOT PATCH NOW ($BLOCKERS blocker(s))"; rc=2
elif (( CAUTIONS > 0 )); then
  verdict="PATCH WITH CAUTION ($CAUTIONS item(s) to review)"; rc=1
else
  verdict="SAFE TO PATCH"; rc=0
fi
printf '%s%s%s\n' "$C_BLD" "$verdict" "$C_RST"
state="/var/tmp/patch-check-$(hostname -s)"
{
  echo "PRE_DATE='$(date '+%Y-%m-%d %H:%M:%S')'"
  echo "PRE_KERNEL='$(uname -r)'"
  echo "PRE_BOOTID='$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)'"
  echo "PRE_COUNT='$upg'"
  echo "PRE_KERNEL_UPDATE='$kernel_update'"
  echo "PRE_VERDICT='$verdict'"
} > "$state.env" 2>/dev/null
echo "$upg_list" | cut -d/ -f1 > "$state.pkgs" 2>/dev/null

case $rc in
  0|1)
    (( rc == 1 )) && info "Read each [WARN] above first. If unsure, ask John or Alison."
    info "IMPORTANT: patching needs a reboot afterwards (always after a kernel update)."
    info "Make sure the server owner knows about the restart. Next steps:"
    info "  1. sudo apt upgrade"
    info "  2. sudo reboot"
    info "  3. log in again, then run:  bash after-patch-check.sh" ;;
  2)
    info "Do NOT patch yet. Fix or get approval for each [FAIL] above."
    info "Paste the request below into the ServiceNow ticket and ask the server owner"
    info "for a restart window. When approved or fixed, run this check again."
    info "For a full look at the machine:  bash health-check.sh" ;;
esac

if (( rc == 2 )); then
  section "Paste into the ServiceNow ticket (request approval)"
  echo "Pre-patch check $(date '+%Y-%m-%d %H:%M') on $(hostname -s): patching is ON HOLD."
  echo "Reasons:"
  for r in "${REASONS[@]}"; do echo "- $r"; done
  echo "Waiting to install: $upg updates (kernel update: $kernel_update). A reboot will be required."
  echo "Requesting approval and a restart window from the server owner."
else
  section "Paste into the ServiceNow ticket (before patching)"
  echo "Pre-patch check $(date '+%Y-%m-%d %H:%M') on $(hostname -s): $verdict."
  echo "Checked: connected users (none other), running jobs, GPU jobs, disk space, held packages, services."
  echo "Updates to install: $upg (kernel update: $kernel_update). Reboot pending from before: $([[ -f /var/run/reboot-required ]] && echo yes || echo no)."
  echo "Plan: apt upgrade, then reboot, then run the after-patch check."
fi
exit $rc
