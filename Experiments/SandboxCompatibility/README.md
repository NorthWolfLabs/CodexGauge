# Codex helper sandbox compatibility

This isolated AppKit probe checks user-selected directory access, bookmark restoration, anchored file reads, filesystem events, external helper launch, and the app-server `initialize` exchange. It has its own bundle identity and defaults to synthetic data. It does not copy authentication files, start tasks, or change the real Mac beta's sandbox configuration. An explicit `--account-check` mode adds a saved-sign-in/allowance check and does not save the selected folder/helper grants across launches; obtain approval before selecting a real Codex data directory.

Quit the probe before rebuilding, then run from the repository root:

```sh
Experiments/SandboxCompatibility/build.sh read-only
open -n .build/SandboxCompatibility.app --args \
  --fixture "$PWD/.build/sandbox-fixture-read-only" \
  --helper /path/to/installed/codex
```

Select the prefilled fixture directory and the installed Codex executable through the two file pickers. Click **Test app-server handshake with fixture folder**. Repeat with `build.sh read-write` and `.build/sandbox-fixture-read-write`. The executable picker only runs `--version`; the third button initializes app-server and terminates it without issuing account or task requests. Each pending response frame is bounded to 64 KiB, the total response stream to 1 MiB, and runtime to 15 seconds; stderr goes to the probe's own container and its first 2,000 bytes are shown on next launch. Use only a disposable fixture directory for the handshake, because Codex creates SQLite databases there.

Verified September 29, 2026 on Apple silicon, macOS 27.0 (26A428), Xcode 27 (27A266a), bundled `codex-cli 0.158.0-alpha.2.1`, Developer ID signed with App Sandbox and network-client access:

| Check | Read-only selection | Read/write selection |
| --- | --- | --- |
| List selected fixture and find sessions directory | Passed | Passed |
| Launch selected helper with `--version` | Exit 0 | Exit 0 |
| App-server initialize | Failed: SQLite state runtime could not initialize | Initialize response received |

The successful response arrived promptly after switching the probe's stdout reader to `availableData`. `read(upToCount: 4096)` held the short response until termination; that was a probe defect, not a Codex startup timeout.

This establishes that selecting a helper and a writable Codex data directory can work within App Sandbox on this configuration. It does **not** establish FSEvents behavior across sleep, support for every installed Codex version, or Mac App Store approval. The current production app still auto-discovers paths and is not sandboxed. A Store variant needs directory selection with persistent security-scoped access and full integration testing before changing that.

Additional checks on the same configuration passed after fully quitting and relaunching: both folder/helper bookmarks restored without another picker, app-server initialized using the restored grants, and FSEvents received an external fixture-file change. The production `AnchoredFileAccess` reader initially failed because it opened each parent starting at `/`; a selected-directory sandbox grant does not permit that. Opening the resolved directory with `O_NOFOLLOW_ANY` fixed access while continuing to reject symlinks anywhere in the kernel path lookup. The production anchored fixture-file open then passed, as did the Mac unit-test suite. Sleep/wake and the supported OS matrix remain separate checks. No authenticated account check is claimed by these fixture results.

## Authenticated check

After explicit user approval on September 29, 2026, the read/write sandbox probe also passed against the real Codex data folder on the same OS/SDK and bundled helper version above. It completed `initialize`, `account/read` with `refreshToken: false`, and `account/rateLimits/read`; the UI reported **Saved sign-in and authenticated allowance access: OK**. This verifies saved sign-in and an authenticated allowance response, not the numerical values or all account/storage configurations.

To repeat with approval, launch the read/write build with `--account-check --fixture /path/to/codex-data --helper /path/to/installed/codex`, select both paths, then click **Check saved sign-in and allowance access**. This mode does not restore or save folder/helper bookmarks, writes no raw account response, and discards helper stderr. Codex may update its normal SQLite state; no task requests are issued. The probe and its test helper were closed after the successful check to end temporary access. The current beta's standalone helper version was not separately tested under sandbox.

Apple's [App Sandbox documentation](https://developer.apple.com/documentation/security/app-sandbox) describes the required isolation and user-selected file access. [Review guidelines 2.4.5 and 4.2.3](https://developer.apple.com/app-store/review/guidelines/) also require appropriate sandboxing, Store-delivered updates, and consideration of the dependency on another installed app. Technical compatibility alone does not settle those review questions. The directly distributed app integrates [Sparkle](https://sparkle-project.org/documentation/); its update feed and dedicated signing key remain release setup work.
