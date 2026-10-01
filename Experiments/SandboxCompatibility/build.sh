#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/../.."
mode="${1:-read-only}"
[[ "$mode" == read-only || "$mode" == read-write ]] || { print -u2 'Use read-only or read-write.'; exit 1; }
bundle="$PWD/.build/SandboxCompatibility.app"
mkdir -p "$bundle/Contents/MacOS" "$PWD/.build/sandbox-fixture-$mode/sessions"
uv run --no-project python - "$bundle" "$mode" <<'PY'
import plistlib, sys
from pathlib import Path
bundle, mode = Path(sys.argv[1]), sys.argv[2]
(bundle/'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'com.northwolflabs.CodexGauge.SandboxCompatibility',
    'CFBundleName': 'SandboxCompatibility', 'CFBundleExecutable': 'SandboxCompatibility',
    'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'LSMinimumSystemVersion': '14.4'}))
entitlements = plistlib.loads(Path('Experiments/SandboxCompatibility/probe.entitlements').read_bytes())
if mode == 'read-write':
    del entitlements['com.apple.security.files.user-selected.read-only']
    entitlements['com.apple.security.files.user-selected.read-write'] = True
Path('.build/sandbox-probe.entitlements').write_bytes(plistlib.dumps(entitlements))
PY
xcrun swiftc -swift-version 6 Experiments/SandboxCompatibility/main.swift CodexGauge/AnchoredFileAccess.swift \
    -o "$bundle/Contents/MacOS/SandboxCompatibility" -framework AppKit
codesign --force --sign "${PROBE_SIGNING_IDENTITY:-Developer ID Application: North Wolf Labs LLC (ALPX923Y54)}" \
    --entitlements .build/sandbox-probe.entitlements "$bundle"
codesign --verify --strict "$bundle"
print "Built sandbox probe ($mode): $bundle"
