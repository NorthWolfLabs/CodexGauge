# Release operations

## GitHub Environment

Create a protected Environment named `release` in `NorthWolfLabs/CodexGauge`.

- Require at least one reviewer.
- Allow self-approval while the project has a single maintainer.
- Restrict deployment branches and tags to `v*` tags.
- Keep the release job's workflow permission at `contents: write` only.
- Store Apple release credentials as secrets on the `release` Environment, not as repository secrets.

The workflow has one release concurrency group, so two tags cannot publish simultaneously.

## Release credentials

Add these GitHub Environment secrets to `release`:

- `DEVELOPER_ID_P12_BASE64`
- `DEVELOPER_ID_P12_PASSWORD`
- `ASC_API_KEY_P8_BASE64`
- `ASC_API_KEY_ID`
- `ASC_API_ISSUER_ID`

The workflow exposes the certificate and private key only to the signing-environment step. It imports the certificate into an ephemeral Keychain, writes the App Store Connect key to a temporary directory, and destroys both in an unconditional cleanup step. The notarization step receives only the App Store Connect key ID and issuer ID from GitHub Secrets; the private key is referenced through its temporary path.

GitHub does not allow a secret to be retrieved or renamed after it is saved. Verify all five names in the Environment before creating a release tag. Keep offline, access-controlled backups of the original Developer ID export and App Store Connect private key.

## Release candidate

1. Update `CHANGELOG.md`, `MARKETING_VERSION`, and the monotonically increasing `CURRENT_PROJECT_VERSION`.
2. Merge only after CI passes on macOS 14 and macOS 26.
3. Create and push `v1.0.0-rc.1` from a clean tree.
4. Approve the protected release deployment after reviewing the workflow inputs.
5. Download the draft release and install it on clean macOS 14 and macOS 26 Apple Silicon systems.
6. Verify menu-bar interaction, Settings and Help shortcuts, allowance refresh, local task loading, notifications, signatures, notarization, and Gatekeeper.

After acceptance, create `v1.0.0`, approve the final workflow, review the draft release and notarization logs, then publish it manually. Draft publication is intentionally separate from artifact creation.
