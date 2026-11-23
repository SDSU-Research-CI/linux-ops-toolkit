#!/usr/bin/env bash
# Shared helpers for linux-ops-toolkit scripts. Source this file, do not run it.

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLD=""; C_RST=""
fi

section() { printf '\n%s== %s ==%s\n' "$C_BLD" "$1" "$C_RST"; }
ok()      { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()    { printf '%s[WARN]%s %s\n' "$C_YEL" "$C_RST" "$*"; WARNINGS=$((WARNINGS + 1)); }
bad()     { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$*"; FAILURES=$((FAILURES + 1)); }
info()    { printf '       %s\n' "$*"; }
have()    { command -v "$1" >/dev/null 2>&1; }

WARNINGS=0
FAILURES=0

# Print the AD domain this machine is joined to (empty if not joined).
detect_domain() {
  have realm || return 0
  realm list --name-only 2>/dev/null | head -n1
}

# Print the permitted login groups from "realm list" (one per line, empty if none).
permitted_groups() {
  have realm || return 0
  realm list 2>/dev/null | awk -F': ' '/permitted-groups:/ {gsub(/, /,"\n",$2); print $2}'
}

# Print the permitted login users from "realm list" (one per line, empty if none).
permitted_logins() {
  have realm || return 0
  realm list 2>/dev/null | awk -F': ' '/permitted-logins:/ {gsub(/, /,"\n",$2); print $2}'
}
