# Slack status artwork

Original geometric artwork for CodexGauge, licensed under the repository's MIT
license. No third-party artwork or extracted Codex images are used.

The 80×80 transparent assets target Slack's current 20×20 context-image slot:
an 8px blue dot and an approximately 11px gray spinner. Transparent padding
controls visible size. Actual rendering remains controlled by Slack clients.

Regenerate on macOS with `uv run --with pillow generate.py`. The PNG and GIF are
checked in, so building CodexGauge does not require Python or an image toolchain.
The script also produces local preview images, which are not shipping assets.

Use commit-pinned public CDN URLs in Slack messages. Local bundle paths are not
reachable by Slack. The animation is decorative; it cannot indicate whether the
Mac is still connected. Status text remains readable without the images.
