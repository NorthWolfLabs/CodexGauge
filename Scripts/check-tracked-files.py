"""Reject local build, review and credential artifacts in the Git index."""
import re
import subprocess
from pathlib import PurePosixPath


def main() -> None:
    entries = subprocess.check_output(["git", "ls-files", "--stage", "-z"]).decode().split("\0")
    failures = []
    local_directories = {".build", "DerivedData", "TestArtifacts", "xcuserdata", "__pycache__",
                         ".venv", "node_modules", ".wrangler", ".swiftpm"}
    local_extensions = {".log", ".pyc", ".pyo", ".p12", ".p8", ".key", ".pem", ".cer", ".crt",
                        ".mobileprovision", ".provisionprofile", ".keychain-db", ".xcresult",
                        ".xcarchive", ".dmg", ".pkg", ".zip", ".profraw", ".profdata", ".trace"}
    for entry in filter(None, entries):
        metadata, name = entry.split("\t", 1)
        mode, object_id, stage = metadata.split()
        path = PurePosixPath(name)
        if stage != "0":
            failures.append((name, "unresolved merge"))
            continue
        if (local_directories.intersection(path.parts) or path.suffix in local_extensions
                or path.name.startswith((".env", ".dev.vars")) or path.name == ".infisical.json"
                or name.startswith("Review/") and (len(path.parts) > 2 or path.suffix != ".md")):
            failures.append((name, "local/generated/credential artifact"))
            continue
        if mode not in {"100644", "100755", "120000"}:
            failures.append((name, "unexpected Git object mode"))
            continue
        size = int(subprocess.check_output(["git", "cat-file", "-s", object_id]))
        if size > 5 * 1024 * 1024:
            failures.append((name, "unexpected file over 5 MiB"))
            continue
        data = subprocess.check_output(["git", "cat-file", "blob", object_id])
        if (re.search(rb"-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----\s+[A-Za-z0-9+/=\r\n]{80,}-----END", data)
                or re.search(rb"\bsk-(?:proj-)?[A-Za-z0-9_-]{40,}", data)):
            failures.append((name, "possible private credential"))
    if failures:
        for name, reason in failures:
            print(f"{name}: {reason}")
        raise SystemExit("Git index hygiene check failed.")
    print("Git index hygiene check passed.")


if __name__ == "__main__":
    main()
