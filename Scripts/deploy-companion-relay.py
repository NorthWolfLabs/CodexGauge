#!/usr/bin/env -S uv run --script
"""Deploy the development relay with its APNs key from the linked Infisical project."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--secret-env", required=True, help="Infisical environment slug (independent of APNs sandbox/production)")
    parser.add_argument("--secret-path", default="/", help="Infisical folder containing APNS_PRIVATE_KEY")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    result = subprocess.run([
        "infisical", "secrets", "get", "APNS_PRIVATE_KEY", "--env", args.secret_env,
        "--path", args.secret_path, "--output=json", "--silent",
    ], cwd=root, capture_output=True, text=True)
    # Never include command output in errors: it can contain the private key.
    if result.returncode:
        raise SystemExit("Could not retrieve APNS_PRIVATE_KEY. Check Infisical login, project, and environment.")
    try:
        records = json.loads(result.stdout)
        value = next(r["secretValue"] for r in records if r["secretKey"] == "APNS_PRIVATE_KEY").strip()
    except (ValueError, KeyError, TypeError, StopIteration):
        raise SystemExit("Infisical did not return APNS_PRIVATE_KEY in the expected format.") from None
    if not value.startswith("-----BEGIN PRIVATE KEY-----"):
        raise SystemExit("APNS_PRIVATE_KEY must contain the complete multiline .p8 contents.")
    check = subprocess.run(["openssl", "pkey", "-check", "-noout"], input=value, capture_output=True, text=True)
    if check.returncode:
        raise SystemExit("APNS_PRIVATE_KEY could not be parsed as a private key.")
    # Wrangler's secrets-file input is not bundled into application code. Use a
    # permission-restricted OS temporary file and remove it even if deployment fails.
    with tempfile.TemporaryDirectory(prefix="codexgauge-push-") as directory:
        path = Path(directory) / "secrets.json"
        with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as handle:
            json.dump({"APNS_PRIVATE_KEY": value}, handle)
        deployed = subprocess.run([
            "vp", "exec", "wrangler", "deploy", "--secrets-file", str(path),
        ], cwd=root / "Companion" / "Relay", capture_output=True, text=True)
        output = deployed.stdout + deployed.stderr
        # Defense in depth if a CLI error ever quotes its input.
        output = output.replace(value, "[private key redacted]")
        output = output.replace(json.dumps(value)[1:-1], "[private key redacted]")
        for line in value.splitlines():
            if line:
                output = output.replace(line, "[private key redacted]")
        print(output, end="")
        code = deployed.returncode
    raise SystemExit(code)


if __name__ == "__main__":
    main()
