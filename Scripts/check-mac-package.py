"""Check the signed Mac package, independently of Xcode's build settings."""
import argparse
import plistlib
import subprocess
from pathlib import Path


def verify(app: Path, *, release: bool, universal: bool) -> None:
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    signature = subprocess.run(
        ["codesign", "-d", "--entitlements", "-", "--xml", str(app)],
        check=True, capture_output=True,
    )
    entitlements = plistlib.loads(signature.stdout)
    required = {
        "com.apple.security.app-sandbox",
        "com.apple.security.files.user-selected.read-write",
        "com.apple.security.files.bookmarks.app-scope",
        "com.apple.security.network.client",
    }
    for key in required:
        assert entitlements.get(key) is True, f"Missing signed entitlement: {key}"
    if release:
        assert {key for key in entitlements if key.startswith("com.apple.security.")} <= required, "Unexpected sandbox/security entitlement"
        assert not list(app.rglob("CodexGaugeTestPeer")), "Unit-test peer must not ship"
        assert not list(app.rglob("*.xctest")), "Unit tests must not ship"
        assert not entitlements.get("com.apple.security.get-task-allow"), "Release is debuggable"
        assert not any("temporary-exception" in key for key in entitlements), "Release contains sandbox exceptions"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    assert info["CFBundleIdentifier"] in {
        "com.northwolflabs.CodexGauge", "com.northwolflabs.CodexGauge.beta",
        "com.northwolflabs.CodexGauge.store-preview",
    }, "Unexpected package identity"
    assert not any(key.startswith("SU") for key in info), "External updater configuration remains"
    assert not list(app.rglob("Sparkle.framework")), "External updater remains embedded"
    binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
    libraries = subprocess.check_output(["otool", "-L", str(binary)], text=True)
    assert "Sparkle" not in libraries, "External updater remains linked"
    if universal:
        architectures = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()
        assert set(architectures) == {"arm64", "x86_64"}, f"Unexpected architectures: {architectures}"
    privacy = plistlib.loads((app / "Contents/Resources/PrivacyInfo.xcprivacy").read_bytes())
    assert privacy.get("NSPrivacyTracking") is False
    reasons = {entry["NSPrivacyAccessedAPIType"] for entry in privacy["NSPrivacyAccessedAPITypes"]}
    assert reasons == {"NSPrivacyAccessedAPICategoryUserDefaults", "NSPrivacyAccessedAPICategoryFileTimestamp", "NSPrivacyAccessedAPICategorySystemBootTime"}
    if info["CFBundleIdentifier"] != "com.northwolflabs.CodexGauge.store-preview":
        migration = plistlib.loads((app / "Contents/Resources/container-migration.plist").read_bytes())
        support_name = "CodexGauge Beta" if info["CFBundleIdentifier"].endswith(".beta") else "CodexGauge"
        assert migration == {"Move": ["${ApplicationSupport}/" + support_name, "${Library}/Preferences/${BundleId}.plist"]}, "Migration must retain only this identity's state"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--release", action="store_true")
    parser.add_argument("--universal", action="store_true")
    args = parser.parse_args()
    verify(args.app, release=args.release, universal=args.universal)
    print("Signed sandbox package verified:", args.app)
