# Release operations

## GitHub Environment

Create a protected Environment named `release` in `NorthWolfLabs/CodexGauge`.

- Require at least one reviewer.
- Disable self-approval.
- Restrict deployment branches and tags to `v*` tags.
- Keep workflow permissions at `contents: write` and `id-token: write` only.
- Do not store long-lived Apple credentials in GitHub secrets.

The workflow has one release concurrency group, so two tags cannot publish simultaneously.

## Infisical OIDC

Create an Infisical machine identity that accepts GitHub’s OIDC token only when:

- Subject: `repo:NorthWolfLabs/CodexGauge:environment:release`
- Audience: `https://github.com/NorthWolfLabs`
- Access: read-only, production release secret path only

Configure these non-secret GitHub repository variables:

- `INFISICAL_PROJECT_SLUG`
- `INFISICAL_IDENTITY_ID`
- `INFISICAL_SECRET_PATH` (for example `/github/release`)

Store these values only in Infisical:

- `DEVELOPER_ID_P12_BASE64`
- `DEVELOPER_ID_P12_PASSWORD`
- `ASC_API_KEY_P8_BASE64`
- `ASC_API_KEY_ID`
- `ASC_API_ISSUER_ID`

The project slug and identity ID are intentionally repository variables because their privileges come from the OIDC subject and audience restrictions, not from secrecy. Their actual values are environment-specific and must not be guessed in source control.

## Release candidate

1. Update `CHANGELOG.md`, `MARKETING_VERSION`, and the monotonically increasing `CURRENT_PROJECT_VERSION`.
2. Merge only after CI passes on macOS 14 and macOS 26.
3. Create and push `v1.0.0-rc.1` from a clean tree.
4. Approve the protected release deployment after reviewing the workflow inputs.
5. Download the draft release and install it on clean macOS 14 and macOS 26 Apple Silicon systems.
6. Verify menu-bar interaction, Settings and Help shortcuts, allowance refresh, local task loading, notifications, signatures, notarization, and Gatekeeper.

After acceptance, create `v1.0.0`, approve the final workflow, review the draft release and notarization logs, then publish it manually. Draft publication is intentionally separate from artifact creation.
