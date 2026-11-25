#!/usr/bin/env bash
# Simple launcher so you do not have to go into the scripts folder.
# Usage, from the repo folder:  bash patch-check.sh
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/patching/pre-patch-check.sh" "$@"
