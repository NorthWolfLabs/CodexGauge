"""Verify a local Mac App Store installer and its effective distribution identity."""
import argparse
from datetime import datetime, timezone
from pathlib import Path
import plistlib
import subprocess
import tempfile

import importlib.util

module_path = Path(__file__).with_name("check-mac-package.py")
spec = importlib.util.spec_from_file_location("check_mac_package", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
verify = module.verify


def verify_export(package: Path) -> None:
    details = subprocess.check_output(["pkgutil", "--check-signature", str(package)], text=True)
    assert "North Wolf Labs LLC (ALPX923Y54)" in details
    assert "3rd Party Mac Developer Installer:" in details or "Mac Installer Distribution:" in details
    assert "signed by a developer certificate issued by Apple" in details
    with tempfile.TemporaryDirectory(prefix="codexgauge-store-export-") as root:
        destination = Path(root) / "expanded"
        subprocess.run(["pkgutil", "--expand-full", str(package), str(destination)], check=True)
        apps = list(destination.rglob("CodexGauge.app"))
        assert len(apps) == 1, "Expected one app in the Store package"
        app = apps[0]
        verify(app, release=True, universal=True)
        signature = subprocess.run(["codesign", "-dvv", str(app)], check=True, capture_output=True, text=True).stderr
        assert "Authority=Apple Distribution: North Wolf Labs LLC (ALPX923Y54)" in signature
        profile = plistlib.loads(subprocess.check_output([
            "security", "cms", "-D", "-i", str(app / "Contents/embedded.provisionprofile")]))
        entitlements = plistlib.loads(subprocess.check_output([
            "codesign", "-d", "--entitlements", "-", "--xml", str(app)], stderr=subprocess.DEVNULL))
        identity = "ALPX923Y54.com.northwolflabs.CodexGauge"
        assert profile["TeamIdentifier"] == ["ALPX923Y54"]
        assert not profile.get("ProvisionedDevices") and not profile.get("ProvisionsAllDevices")
        assert profile["ExpirationDate"].replace(tzinfo=timezone.utc) > datetime.now(timezone.utc)
        assert not profile["Entitlements"].get("get-task-allow")
        assert profile["Entitlements"]["com.apple.application-identifier"] == identity
        assert entitlements["com.apple.application-identifier"] == identity
        assert entitlements["com.apple.developer.team-identifier"] == "ALPX923Y54"
    print("Mac App Store installer, profile and signed identity verified:", package)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    verify_export(parser.parse_args().package)
