#!/usr/bin/env bash
# Run this after patching and rebooting.
# Usage, from the repo folder:  bash after-patch-check.sh
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/patching/post-patch-check.sh" "$@"
