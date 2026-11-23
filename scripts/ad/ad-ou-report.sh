#!/usr/bin/env bash
# ad-ou-report.sh
# Read-only report of where this machine's computer account lives in AD (its OU)
# and, optionally, who is in an AD security group. Use it to verify a realm join
# landed in the right OU, or to check a lab access group before adding users.
#
# Usage:
#   ./ad-ou-report.sh                      report for this machine
#   ./ad-ou-report.sh --group GROUPNAME    also list members of an AD group
#   ./ad-ou-report.sh --admin USERNAME     AD account to sign in with (asked if omitted)
#
# Needs: a joined machine, network access (campus or VPN), and packages
#   krb5-user and ldap-utils (sudo apt install krb5-user ldap-utils).
# Coworkers only have rights in the COS OU, so results outside it may be empty.
# The domain and base DN are detected from "realm list", nothing is hardcoded.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib-common.sh
source "$HERE/../lib-common.sh"

group=""
admin=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --group) group="${2:-}"; shift 2 ;;
    --admin) admin="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 2 ;;
  esac
done

for cmd in realm klist kinit ldapsearch; do
  have "$cmd" || { bad "Missing command: $cmd (sudo apt install realmd krb5-user ldap-utils)"; exit 2; }
done

dom=$(detect_domain)
[[ -z "$dom" ]] && { bad "This machine is not joined to a domain"; exit 2; }
realm_upper=$(echo "$dom" | tr '[:lower:]' '[:upper:]')
base_dn="DC=$(echo "$dom" | sed 's/\./,DC=/g')"
host_short=$(hostname -s)

section "Domain"
info "Domain:  $dom"
info "Base DN: $base_dn"

section "Kerberos ticket"
if klist -s 2>/dev/null; then
  ok "Existing Kerberos ticket: $(klist 2>/dev/null | awk '/Default principal/ {print $3}')"
else
  [[ -z "$admin" ]] && read -r -p "AD username to sign in with (without @domain): " admin
  [[ -z "$admin" ]] && { echo "No username given."; exit 2; }
  echo "Enter the password for ${admin}@${realm_upper} when asked."
  kinit "${admin%%@*}@${realm_upper}" || { bad "kinit failed (wrong password, locked account, or clock skew)"; exit 1; }
  trap 'kdestroy -q 2>/dev/null' EXIT
fi

ldap() { ldapsearch -LLL -Q -Y GSSAPI -H "ldap://${dom}" -b "$base_dn" "$@" 2>/dev/null; }

section "Computer account for $host_short"
res=$(ldap "(&(objectClass=computer)(sAMAccountName=${host_short^^}\$))" distinguishedName operatingSystem dNSHostName)
if [[ -z "$res" ]]; then
  warn "No computer object found for ${host_short^^}\$ (not visible with this account, or hostname differs from AD name)"
else
  dn=$(echo "$res" | awk -F': ' '/^distinguishedName:/ {print $2}')
  info "$res"
  ou="${dn#*,}"
  ok "OU: $ou"
fi

if [[ -n "$group" ]]; then
  section "Group: $group"
  gres=$(ldap "(&(objectClass=group)(sAMAccountName=${group}))" distinguishedName member description)
  if [[ -z "$gres" ]]; then
    bad "Group '$group' not found (check the exact group name in AD)"
  else
    ok "Group exists"
    echo "$gres" | awk -F': ' '/^distinguishedName:|^description:/ {print "       "$0}'
    n=$(echo "$gres" | grep -c '^member:')
    info "Members: $n"
    echo "$gres" | awk -F': ' '/^member:/ {print $2}' | sed -E 's/^CN=([^,]+),.*/       \1/' | sort
    if realm list 2>/dev/null | grep -qi "permitted-groups:.*${group}"; then
      ok "This machine permits logins for $group"
    else
      info "This machine does not list $group in permitted-groups (see: sudo realm permit --groups $group)"
    fi
  fi
fi
