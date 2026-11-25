#!/usr/bin/env bash
# First look at any machine that has a problem.
# Usage, from the repo folder:  bash health-check.sh      (add --save to keep a copy)
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/troubleshooting/linux-health-check.sh" "$@"
