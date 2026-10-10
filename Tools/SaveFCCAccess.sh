#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_temp="$(mktemp -d /private/tmp/shadow-fcc-access.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
/usr/bin/xcrun --sdk macosx swiftc -j 1 -disable-batch-mode \
    -module-cache-path "$task_temp/ModuleCache" \
    "$task_root/Sources/Vorssaint/Support/ScopedCredentialStore.swift" \
    "$task_root/Tools/SaveFCCAccess.swift" -o "$task_temp/save-fcc-access"
"$task_temp/save-fcc-access" "$@"
