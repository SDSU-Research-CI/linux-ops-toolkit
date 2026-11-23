#!/usr/bin/env bash
# pre-patch-check.sh
# Read-only check to run BEFORE patching a server or workstation.
# Rule of thumb: patch only when nobody is connected. If someone is, ask for
# approval and a restart window first. Nothing is changed by this script.
#
# Usage: ./pre-patch-check.sh
# Exit code: 0 safe to patch, 1 patch with caution, 2 do not patch now.
# At the end it prints a note you can paste into the ServiceNow ticket.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib-common.sh
source "$HERE/../lib-common.sh"

BLOCKERS=0
CAUTIONS=0
block() { bad "$*"; BLOCKERS=$((BLOCKERS + 1)); }
caution() { warn "$*"; CAUTIONS=$((CAUTIONS + 1)); }

section "Host"
info "$(hostname -f 2>/dev/null || hostname)  |  $(. /etc/os-release && echo "$PRETTY_NAME")  |  kernel $(uname -r)"
info "Uptime: $(uptime -p)"

section "Who is connected"
sessions=$(who 2>/dev/null)
if [[ -z "$sessions" ]]; then
  ok "No interactive sessions"
else
  block "Users are connected:"
  echo "$sessions" | sed 's/^/       /'
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

section "Disk space needed for updates"
for m in / /boot /var; do
  mountpoint -q "$m" 2>/dev/null || [[ "$m" == "/" ]] || continue
  avail=$(df -Pm "$m" | awk 'NR==2 {print $4}')
  if (( avail < 1024 )); then block "$m has only ${avail} MB free"; else ok "$m has ${avail} MB free"; fi
done

section "Package state"
if pgrep -x apt >/dev/null || pgrep -x apt-get >/dev/null || pgrep -x dpkg >/dev/null || pgrep -f unattended-upgr >/dev/null; then
  block "apt, dpkg or unattended-upgrades is already running"
else
  ok "No other package manager running"
fi
held=$(apt-mark showhold 2>/dev/null)
[[ -n "$held" ]] && caution "Held packages: $(echo "$held" | tr '\n' ' ')"
upg=$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)
info "Upgradable packages: $upg (run 'sudo apt update' first for fresh numbers)"
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

section "Paste into the ServiceNow ticket"
cat <<NOTE
Pre-patch check $(date '+%Y-%m-%d %H:%M') on $(hostname -s): $verdict.
Connected users: $(who | wc -l). Upgradable packages: $upg. Reboot pending: $([[ -f /var/run/reboot-required ]] && echo yes || echo no).
NOTE
exit $rc
