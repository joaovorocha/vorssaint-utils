#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
task_temp="$(mktemp -d /private/tmp/shadow-fcc-check.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
/usr/bin/xcrun --sdk macosx swiftc -j 1 -disable-batch-mode \
    -module-cache-path "$task_temp/ModuleCache" \
    Sources/Vorssaint/Support/ScopedCredentialStore.swift \
    Sources/Vorssaint/Services/Metrics/{FCCCoverageSupport,FCCCoverageClient}.swift \
    Tools/CheckFCCAccess.swift -o "$task_temp/check-fcc-access"
"$task_temp/check-fcc-access" "$@"
