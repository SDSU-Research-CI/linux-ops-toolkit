#!/usr/bin/env bash
# linux-health-check.sh
# Read-only health snapshot of an Ubuntu workstation or server.
# Safe to run on any machine. Nothing is changed. Run it first when a ticket says
# "the computer is slow", "I cannot log in", or "the server is down".
#
# Usage (from the repo folder):  bash health-check.sh [--save]
#   --save   also write the report to ~/health-check-<hostname>-<date>.txt
#            (handy to attach to the ServiceNow ticket)
# Reading the result: [ OK ] fine, [WARN] look at it, [FAIL] needs fixing.
# Sections that do not apply (for example Active Directory on a server that is
# not joined to the domain) are skipped and never count as a failure.
#
# Values (domain, groups, gateway) are detected, nothing is hardcoded.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib-common.sh
source "$HERE/../lib-common.sh"

SAVE=0
[[ "${1:-}" == "--save" ]] && SAVE=1
if [[ $SAVE -eq 1 ]]; then
  OUT="$HOME/health-check-$(hostname -s)-$(date +%Y%m%d-%H%M).txt"
  exec > >(tee "$OUT") 2>&1
fi

DISK_WARN=85
MEM_WARN=90

section "System"
info "Host:    $(hostname -f 2>/dev/null || hostname)"
info "OS:      $(. /etc/os-release && echo "$PRETTY_NAME")"
info "Kernel:  $(uname -r)"
info "Uptime:  $(uptime -p)"
info "Load:    $(cut -d' ' -f1-3 /proc/loadavg) (CPUs: $(nproc))"
if [[ -f /var/run/reboot-required ]]; then
  warn "A reboot is pending (/var/run/reboot-required exists)"
else
  ok "No reboot pending"
fi

diskwarn=0
section "Disk"
while read -r _fs size used avail pct mnt; do
  p="${pct%\%}"
  if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= DISK_WARN )); then
    warn "$mnt is ${pct} full ($used of $size used, $avail free)"; diskwarn=1
  else
    ok "$mnt ${pct} used ($avail free)"
  fi
done < <(df -hP -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | tail -n +2)
while read -r _fs _inodes _iused _ifree ipct mnt; do
  p="${ipct%\%}"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= DISK_WARN )) && warn "$mnt inodes ${ipct} used"
done < <(df -iP -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | tail -n +2)

if (( diskwarn )); then
  info "To find what is using the space:  sudo du -xh / --max-depth=2 | sort -h | tail -15"
  info "Safe first steps:  sudo apt autoremove --purge   and   sudo apt clean"
  info "Do not delete user data. Ask the server owner or John if unsure."
fi

section "Memory"
read -r mtotal mused < <(free -m | awk '/^Mem:/ {print $2, $3}')
mpct=$(( mused * 100 / mtotal ))
if (( mpct >= MEM_WARN )); then warn "Memory ${mpct}% used (${mused} of ${mtotal} MB)"; else ok "Memory ${mpct}% used (${mused} of ${mtotal} MB)"; fi
swap_used=$(free -m | awk '/^Swap:/ {print $3}')
[[ "${swap_used:-0}" -gt 0 ]] && info "Swap in use: ${swap_used} MB"

section "Services"
failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')
if [[ -z "$failed" ]]; then
  ok "No failed systemd units"
else
  while read -r u; do bad "Failed unit: $u"; done <<< "$failed"
fi
for svc in ssh sssd; do
  if systemctl list-unit-files "$svc.service" 2>/dev/null | grep -q "$svc.service"; then
    if systemctl is-active --quiet "$svc"; then ok "$svc is running"; else bad "$svc is installed but not running"; fi
  fi
done

section "Network"
info "$(ip -br -4 addr show scope global 2>/dev/null | tr '\n' ' ')"
gw=$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')
if [[ -z "$gw" ]]; then
  bad "No default route"
else
  if ping -c1 -W2 "$gw" >/dev/null 2>&1; then ok "Gateway $gw answers ping"; else warn "Gateway $gw does not answer ping (may be blocked)"; fi
fi
dom=$(detect_domain)
target="${dom:-sdsu.edu}"
if getent hosts "$target" >/dev/null 2>&1; then ok "DNS resolves $target"; else bad "DNS cannot resolve $target"; fi
if have ufw; then info "Firewall: $(ufw status 2>/dev/null | head -n1)"; fi

section "Time sync"
if have timedatectl; then
  sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
  if [[ "$sync" == "yes" ]]; then ok "Clock is synchronized"; else bad "Clock is NOT synchronized (try: sudo timedatectl set-ntp true. Logins to AD fail when the clock is off)"; fi
fi

section "Active Directory"
if [[ -z "$dom" ]]; then
  info "Not joined to a domain (realm list is empty)"
else
  ok "Joined to $dom"
  info "Login policy: $(realm list 2>/dev/null | awk -F': ' '/login-policy:/ {print $2; exit}')"
  g=$(permitted_groups); [[ -n "$g" ]] && info "Permitted groups: $(echo "$g" | tr '\n' ' ')"
  u=$(permitted_logins); [[ -n "$u" ]] && info "Permitted users:  $(echo "$u" | tr '\n' ' ')"
  if have sssctl; then
    status=$(sssctl domain-status "$dom" 2>/dev/null | awk -F': ' '/Online status/ {print $2}')
    if [[ "$status" == "Online" ]]; then ok "SSSD domain status: Online"; else warn "SSSD domain status: ${status:-unknown} (needs sudo or VPN or campus network)"; fi
  fi
fi

section "SSH"
if have sshd || [[ -x /usr/sbin/sshd ]]; then
  cfg=$(grep -hiE '^\s*(AllowGroups|AllowUsers|PermitRootLogin|PasswordAuthentication)' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null)
  [[ -n "$cfg" ]] && echo "$cfg" | sed 's/^/       /'
  if getent group sshusers >/dev/null; then info "sshusers members: $(getent group sshusers | cut -d: -f4)"; fi
else
  info "openssh-server is not installed"
fi

section "Recent errors (journal, last 15)"
if have journalctl; then
  journalctl -p err -n 15 --no-pager -q 2>/dev/null | cut -c1-160 | sed 's/^/       /' || true
fi

section "Summary"
printf 'Failures: %d   Warnings: %d\n' "$FAILURES" "$WARNINGS"
if (( FAILURES > 0 )); then
  info "Next: fix each [FAIL] above, starting with the first one. Ask John or Alison if you are stuck."
elif (( WARNINGS > 0 )); then
  info "Next: read each [WARN]. Many are harmless, but note them in the ticket."
else
  info "Everything looks fine. If the problem continues, note the exact error message in the ticket."
fi
info "Tip: run again with --save to keep a copy for the ServiceNow ticket."
[[ $SAVE -eq 1 ]] && info "Saved to $OUT"
exit $(( FAILURES > 0 ? 2 : (WARNINGS > 0 ? 1 : 0) ))
