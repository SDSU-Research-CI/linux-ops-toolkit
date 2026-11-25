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

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib-common.sh
source "$HERE/../lib-common.sh"

BLOCKERS=0
CAUTIONS=0
block() { bad "$*"; BLOCKERS=$((BLOCKERS + 1)); }
caution() { warn "$*"; CAUTIONS=$((CAUTIONS + 1)); }

printf '%sPre-patch check%s: this only looks around. It does not install or change anything.\n' "$C_BLD" "$C_RST"
printf 'Meaning of the tags:  [ OK ] fine   [WARN] review before patching   [FAIL] stop, do not patch yet\n'

section "Host"
info "$(hostname -f 2>/dev/null || hostname)  |  $(. /etc/os-release && echo "$PRETTY_NAME")  |  kernel $(uname -r)"
info "Uptime: $(uptime -p)"

section "Who is connected"
# Ignore only the terminal this script is running in (you), not the account name,
# so a second admin session or a researcher logged in still counts.
mytty=$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')
sessions=$(who 2>/dev/null | awk -v t="$mytty" '$2 != t')
nsessions=0
[[ -n "$sessions" ]] && nsessions=$(echo "$sessions" | wc -l)
if [[ -z "$sessions" ]]; then
  ok "Nobody else is connected (your own session is not counted)"
else
  block "Other people are connected:"
  echo "$sessions" | sed 's/^/       /'
  info "Columns: user, terminal, login time, where from."
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
case $rc in
  0) info "Next: create or open the ServiceNow ticket, paste the note below, then patch:"
     info "  sudo apt update && sudo apt upgrade" ;;
  1) info "Next: read each [WARN] above. If you understand them, you may patch,"
     info "then mention them in the ticket. If unsure, ask John or Alison first."
     info "To patch:  sudo apt update && sudo apt upgrade" ;;
  2) info "Next: do NOT patch yet. Read each [FAIL] above."
     info "If people are connected, ask the server owner for a restart window"
     info "and write the approval in the ServiceNow ticket. Then run this check again." ;;
esac

section "Paste into the ServiceNow ticket"
cat <<NOTE
Pre-patch check $(date '+%Y-%m-%d %H:%M') on $(hostname -s): $verdict.
Other connected users: $nsessions. Upgradable packages: $upg. Reboot pending: $([[ -f /var/run/reboot-required ]] && echo yes || echo no).
NOTE
exit $rc
