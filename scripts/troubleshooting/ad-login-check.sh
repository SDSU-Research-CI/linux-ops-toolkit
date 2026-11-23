#!/usr/bin/env bash
# ad-login-check.sh
# Read-only check for "this AD user cannot log in to this Linux machine".
# Detects the domain and the permitted login groups from "realm list", so nothing
# is hardcoded. Run it on the workstation or server the user cannot log in to.
#
# Usage: ./ad-login-check.sh [username]
#   If no username is given you are asked for one (no @ID.SDSU.EDU needed).
# Run with sudo to also see sudo rights and SSSD domain status.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib-common.sh
source "$HERE/../lib-common.sh"

user="${1:-}"
if [[ -z "$user" ]]; then
  read -r -p "AD username to check (without @domain): " user
fi
[[ -z "$user" ]] && { echo "No username given."; exit 2; }
user="${user%%@*}"

section "Machine"
dom=$(detect_domain)
if [[ -z "$dom" ]]; then
  bad "This machine is not joined to a domain (realm list is empty)"
  exit 2
fi
ok "Joined to $dom"
policy=$(realm list 2>/dev/null | awk -F': ' '/login-policy:/ {print $2; exit}')
info "Login policy: $policy"

section "Does the machine know the user?"
# AD limits the legacy login name (sAMAccountName) to 20 characters, so a long
# account such as name-desktop-admin is stored cut off (name-desktop-a).
if [[ ${#user} -gt 20 ]] && ! getent passwd "$user" >/dev/null; then
  short="${user:0:20}"
  warn "'$user' is longer than 20 characters. AD stores the login name cut off; trying '$short'"
  user="$short"
fi
if ! getent passwd "$user" >/dev/null; then
  bad "getent cannot find '$user'. Check the spelling, VPN or campus network, and clock sync (timedatectl)."
  info "If the user was just created or changed in AD, wait for replication or clear the SSSD cache:"
  info "  sudo sss_cache -E"
  exit 1
fi
ok "Found: $(getent passwd "$user" | cut -d: -f1,3,4,6)"
info "Use this exact login name for ssh and for sshusers: $user"

section "Login permission (realm permit)"
mapfile -t pg < <(permitted_groups)
mapfile -t pu < <(permitted_logins)
case "$policy" in
  allow-any-login)
    ok "Policy allows every AD user to log in" ;;
  deny-any-login)
    bad "Policy denies all logins. Fix with: sudo realm permit $user  or  sudo realm permit --groups <group>" ;;
  *)
    allowed=0
    for l in "${pu[@]}"; do
      [[ -n "$l" && "${l%%@*}" == "$user" ]] && { ok "User is listed in permitted-logins"; allowed=1; }
    done
    usergroups=" $(id -nG "$user" 2>/dev/null | sed 's/@[^ ]*//g' | tr '[:upper:]' '[:lower:]') "
    for g in "${pg[@]}"; do
      [[ -z "$g" ]] && continue
      gshort=$(echo "${g%%@*}" | tr '[:upper:]' '[:lower:]')
      if [[ "$usergroups" == *" $gshort "* ]]; then
        ok "User is a member of permitted group: $g"; allowed=1
      else
        info "Permitted group the user is NOT in: $g"
      fi
    done
    if [[ $allowed -eq 0 ]]; then
      bad "User is not in permitted-logins or any permitted group."
      info "Fix in AD: add the user to one of the permitted groups above (then wait for replication or run: sudo sss_cache -E)."
    fi ;;
esac

section "Group membership seen by this machine"
info "$(id "$user" 2>/dev/null)"

section "SSH access"
if getent group sshusers >/dev/null; then
  if getent group sshusers | cut -d: -f4 | tr ',' '\n' | grep -qix "$user"; then
    ok "$user is in the sshusers group"
  else
    warn "$user is NOT in sshusers (needed only for SSH logins when AllowGroups sshusers is set)"
  fi
else
  info "No sshusers group on this machine"
fi

section "Sudo rights"
if [[ $EUID -eq 0 ]]; then
  sudo -l -U "$user" 2>/dev/null | sed 's/^/       /'
else
  info "Run this script with sudo to see sudo rights."
fi

section "SSSD domain status"
if have sssctl && [[ $EUID -eq 0 ]]; then
  sssctl domain-status "$dom" 2>/dev/null | sed 's/^/       /'
  sssctl user-checks "$user" 2>/dev/null | head -n 12 | sed 's/^/       /'
else
  info "Run with sudo for sssctl domain-status."
fi

section "Summary"
printf 'Failures: %d   Warnings: %d\n' "$FAILURES" "$WARNINGS"
exit $(( FAILURES > 0 ? 2 : (WARNINGS > 0 ? 1 : 0) ))
