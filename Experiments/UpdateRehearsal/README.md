# Signed update rehearsal

This disposable host compiles the production `AppUpdater.swift` unchanged, with a separate `AppIdentity` constant. It has its own bundle ID, preferences and synthetic Keychain item. It never reads Codex data. Both app versions are Developer ID signed; this is not notarization or a tagged release.

After resolving the Mac project's pinned Sparkle package into `.build/companion-beta`:

1. Start `uv run --no-project python Experiments/UpdateRehearsal/server.py .build/update-rehearsal/public` (create the directory first).
2. Start `cloudflared tunnel --no-autoupdate --url http://127.0.0.1:8876` and note its temporary HTTPS origin.
3. Run `uv run --script Experiments/UpdateRehearsal/build.py <https-origin>`. The build refuses to replace existing test app directories; use a clean rehearsal directory for another run. It creates a dedicated Ed25519 test key outside the two-file server allowlist, with mode 0600. That key is never a production credential.
4. Run `uv run --no-project python Experiments/UpdateRehearsal/feed.py empty`, then launch `.build/update-rehearsal/installed/CodexGauge Update Rehearsal.app`. Click **Check for Updates…** and verify “up to date.”
5. Select the `unavailable` feed scenario and check again; verify a recoverable retrieval error. Select `bad-signature`, check, and attempt installation; verify signature rejection with build 1 intact.
6. Select `valid`, check, install and relaunch. Verify **Installed build: 2**, **Preference preserved: yes**, and **Keychain link preserved: yes**. Version 2 does not create replacement sentinel values if they are missing.
7. Close the test app, stop both server processes, and delete `.build/update-rehearsal/test-private-key`. The retained app/feed artifacts are disposable. The synthetic Keychain service is `com.northwolflabs.CodexGauge.UpdateRehearsal`, account `test-link-sentinel`; it contains no actual viewing credential.

Verified September 29, 2026 on Apple silicon, macOS 27.0 (26A428), Xcode 27 (27A266a), Sparkle 2.10.0:

- Empty feed: native “You’re up to date” dialog.
- HTTP 503: native retrieval-error dialog, followed by a successful retry.
- Invalid Ed25519 signature: native “improperly signed” rejection; build 1 retained.
- Valid signature: HTTPS download, extraction, **Install and Relaunch**, process replacement, installed build 2, preference and Keychain sentinels preserved.
- Private-key/source/listing paths were rejected by the server/tunnel (404 or 400).
- Temporary HTTPS tunnel and local server stopped; private test key removed.

This verifies the real updater code and Sparkle installation path with an isolated host. It does not verify notarization, the eventual production feed/signing key, Intel execution, macOS 14.4 execution, or upgrading an already-published CodexGauge release. Those checks remain part of release qualification. [Sparkle publishing](https://sparkle-project.org/documentation/publishing/) describes archive/signature requirements; [Cloudflare Quick Tunnels](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/) describes the temporary HTTPS transport used here.
