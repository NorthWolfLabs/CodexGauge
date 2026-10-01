# /// script
# requires-python = ">=3.11"
# dependencies = ["cryptography>=44"]
# ///
"""Build disposable, signed versions; never modify the real beta or stable app."""
import base64
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

repo = Path(__file__).resolve().parents[2]
root = repo / ".build/update-rehearsal"
sparkle = repo / ".build/companion-beta/SourcePackages/artifacts/sparkle/Sparkle"
framework = sparkle / "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
identity = "Developer ID Application: North Wolf Labs LLC (ALPX923Y54)"
feed_base = sys.argv[1].rstrip("/")
assert feed_base.startswith("https://") and ".trycloudflare.com" in feed_base
root.mkdir(parents=True, exist_ok=True)
public = root / "public"; public.mkdir(exist_ok=True)
keyfile = root / "test-private-key"
if keyfile.exists():
    key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(keyfile.read_bytes()))
else:
    key = Ed25519PrivateKey.generate()
    fd = os.open(keyfile, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "wb") as output:
        output.write(base64.b64encode(key.private_bytes_raw()))
pubkey = base64.b64encode(key.public_key().public_bytes_raw()).decode()

def run(*args):
    subprocess.run([str(a) for a in args], check=True)

def sign(path):
    run("codesign", "--force", "--options", "runtime", "--timestamp=none", "--sign", identity, path)

for version in ("1", "2"):
    app = root / ("installed" if version == "1" else "candidate") / "CodexGauge Update Rehearsal.app"
    if app.exists():
        raise SystemExit(f"Refusing to overwrite an existing rehearsal app: {app}")
    contents = app / "Contents"; (contents / "MacOS").mkdir(parents=True)
    (contents / "Frameworks").mkdir()
    run("ditto", framework, contents / "Frameworks/Sparkle.framework")
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.northwolflabs.CodexGauge.UpdateRehearsal",
        "CFBundleName": "CodexGauge Update Rehearsal", "CFBundleExecutable": "Rehearsal",
        "CFBundlePackageType": "APPL", "CFBundleVersion": version,
        "CFBundleShortVersionString": f"1.0.{version}", "LSMinimumSystemVersion": "14.4",
        "SUFeedURL": feed_base + "/appcast.xml", "SUPublicEDKey": pubkey,
        "SUEnableAutomaticChecks": False, "SUAutomaticallyUpdate": False,
        "SUVerifyUpdateBeforeExtraction": True, "SUSendProfileInfo": False,
    }))
    run("xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
        repo / "Experiments/UpdateRehearsal/main.swift", repo / "CodexGauge/AppUpdater.swift",
        "-F", framework.parent, "-framework", "Sparkle", "-framework", "AppKit", "-framework", "Security",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        "-o", contents / "MacOS/Rehearsal")
    embedded = contents / "Frameworks/Sparkle.framework"
    for child in ("Versions/B/XPCServices/Installer.xpc", "Versions/B/XPCServices/Downloader.xpc",
                  "Versions/B/Autoupdate", "Versions/B/Updater.app"):
        sign(embedded / child)
    sign(embedded); sign(app)
    run("codesign", "--verify", "--deep", "--strict", app)
run("ditto", "-c", "-k", "--keepParent", root / "candidate/CodexGauge Update Rehearsal.app", public / "update.zip")
signature = subprocess.check_output([str(sparkle / "bin/sign_update"), "--ed-key-file", str(keyfile), "-p", str(public / "update.zip")], text=True).strip()
(root / "signature.txt").write_text(signature)
(root / "base-url.txt").write_text(feed_base)
print("Rehearsal versions built and signed; private test key stays outside the served directory.")
