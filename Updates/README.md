# Mac update distribution

The directly distributed Mac app uses Sparkle 2.10.0, pinned by version and package resolution. Only a non-Debug build with the stable bundle ID and valid HTTPS feed/Ed25519 public key starts it. Beta builds never check or install stable updates. The menu and General settings expose **Check for Updates…** only when configured. Automatic checks default to off; users can opt in. Automatic download/install and system-profile reporting default to off.

No production feed, production update-signing key, tagged release, or update publication has been created as part of mobile development. A [disposable signed-update rehearsal](../Experiments/UpdateRehearsal/README.md) passed over temporary HTTPS, including rejection, installation, relaunch and saved-state preservation. The temporary test key and server are retired.

## Release setup

1. Use Sparkle’s `bin/generate_keys` once to create a dedicated Ed25519 update-signing key in the release operator’s Keychain. This is separate from APNs and Developer ID. Back up its private material in Infisical; never commit it or bundle it. Follow Sparkle’s [key management instructions](https://sparkle-project.org/documentation/).
2. Choose an HTTPS appcast location under a controlled domain. Set `CODEXGAUGE_UPDATE_FEED_URL` and `CODEXGAUGE_UPDATE_PUBLIC_KEY` as Xcode build settings. The latter is the 32-byte base64 public key. Local `Scripts/release.sh` accepts both as environment values; the release workflow uses repository variables with those names. Neither value is secret. Leaving them empty disables the updater.
3. Build, sign, and notarize the actual release using the existing release process. Keep `CFBundleVersion` increasing. Retain the Sparkle framework symlinks when archiving; use `ditto`. The isolated CI signing job explicitly permits only the expected app/Sparkle executable paths and internal framework links, then signs nested code before the outer app. It never executes an artifact from the unsigned build with release credentials.
4. Put the notarized DMG/ZIP and any matching release notes in a dedicated update directory. Run the pinned Sparkle distribution’s `bin/generate_appcast` against it to generate signed enclosures. Inspect its `--help` for `--download-url-prefix` and feed URL options. Keep old releases there as needed; the tool may move old artifacts into `old_updates`.
5. Upload the immutable release artifact before its appcast. Confirm every download URL, bundle ID, version, and Ed25519 signature. Publish only after the owner requests a release. CI does not yet publish an appcast or retrieve a Sparkle private key; keep the existing draft-release approval boundary.

The tools are available after package resolution at `<DerivedData>/SourcePackages/artifacts/sparkle/Sparkle/bin/`. A future CI appcast job should retrieve the dedicated key from Infisical using a narrowly scoped workload identity instead of copying APNs credentials or a Developer ID private key.

## Required upgrade rehearsal

Use two disposable signed app copies and a staging HTTPS feed with a dedicated test key. Verify manual checks, no-update and network-error states, signature rejection, installation of the newer build, relaunch, and preservation of preferences/Keychain links. Check both Intel and Apple silicon and the supported macOS minimum. Keep production app copies and the running beta out of this rehearsal. A Store variant must omit Sparkle and use Store-delivered updates.

Current verification: configuration isolation tests pass; Debug and Universal 2 Release compile; an isolated host using the production updater code successfully downloaded and installed a signed update over HTTPS, relaunched, and retained preferences and a synthetic Keychain link. Invalid signatures and unavailable feeds were handled correctly. Notarized production distribution and the Intel/minimum-OS execution matrix remain unverified; device/widget validation is independent.
