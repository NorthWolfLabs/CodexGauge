"""Validate the actual mobile app and widget bundles before a TestFlight upload."""
import argparse
import plistlib
import subprocess
import tempfile
import zipfile
from pathlib import Path


DEVICE_NAME = "com.apple.developer.device-information.user-assigned-device-name"


def verify(app: Path, distribution: bool, device_name: bool) -> None:
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    host = plistlib.loads((app / "Info.plist").read_bytes())
    assert host["CFBundleDisplayName"] == "TokenTach"
    assert host["CFBundleIdentifier"] == "com.northwolflabs.CodexGauge"
    assert host.get("ITSAppUsesNonExemptEncryption") is False
    assert {"tokentach", "codexgauge"} <= set(host["CFBundleURLTypes"][0]["CFBundleURLSchemes"])
    widgets = list((app / "PlugIns").glob("*.appex"))
    assert len(widgets) == 1, "Expected the widget/Live Activity extension"
    assert not list(app.rglob("*.xctest")), "Tests must not ship"
    for bundle in [app, *widgets]:
        info = plistlib.loads((bundle / "Info.plist").read_bytes())
        assert info["CFBundleShortVersionString"] == host["CFBundleShortVersionString"]
        assert info["CFBundleVersion"] == host["CFBundleVersion"]
        if bundle != app:
            assert info["CFBundleIdentifier"] == "com.northwolflabs.CodexGauge.widgets"
            assert info["CFBundleDisplayName"] == "TokenTach Widgets"
        privacy = plistlib.loads((bundle / "PrivacyInfo.xcprivacy").read_bytes())
        assert privacy["NSPrivacyTracking"] is False
        defaults = next(entry for entry in privacy["NSPrivacyAccessedAPITypes"]
                        if entry["NSPrivacyAccessedAPIType"] == "NSPrivacyAccessedAPICategoryUserDefaults")
        assert {"CA92.1", "1C8F.1"} <= set(defaults["NSPrivacyAccessedAPITypeReasons"])
        if distribution:
            signature = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(bundle)],
                                       check=True, capture_output=True)
            entitlements = plistlib.loads(signature.stdout)
            assert not entitlements.get("get-task-allow"), "Distribution must not be debuggable"
            assert entitlements["com.apple.developer.team-identifier"] == "ALPX923Y54"
            assert "group.com.northwolflabs.CodexGauge" in entitlements["com.apple.security.application-groups"]
            profile = plistlib.loads(subprocess.check_output(
                ["security", "cms", "-D", "-i", str(bundle / "embedded.mobileprovision")]))
            assert not profile.get("ProvisionedDevices"), "Expected App Store distribution profile"
            assert profile["Entitlements"].get("beta-reports-active") is True
            if bundle == app:
                assert entitlements.get("aps-environment") == "production"
                if device_name:
                    assert entitlements.get(DEVICE_NAME) is True
                    assert profile["Entitlements"].get(DEVICE_NAME) is True
            else:
                assert not entitlements.get(DEVICE_NAME), "Only the host app needs device-name access"
    print("Mobile package verified:", app)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("--distribution", action="store_true")
    parser.add_argument("--device-name", action="store_true")
    args = parser.parse_args()
    if args.package.suffix == ".ipa":
        with tempfile.TemporaryDirectory(prefix="tokentach-ipa-") as folder:
            with zipfile.ZipFile(args.package) as archive:
                archive.extractall(folder)
            apps = list((Path(folder) / "Payload").glob("*.app"))
            assert len(apps) == 1
            verify(apps[0], args.distribution, args.device_name)
    else:
        verify(args.package, args.distribution, args.device_name)
