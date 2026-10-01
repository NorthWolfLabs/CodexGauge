#!/usr/bin/env -S uv run --script
"""Write a synthetic task into the disposable sandbox fixture. Never touches ~/.codex."""
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

root = Path(__file__).resolve().parents[2] / '.build/sandbox-fixture-read-write'
identifier = '11111111-2222-4333-8444-555555555555'
folder = root / 'sessions/2026/09/29'
folder.mkdir(parents=True, exist_ok=True)
(root / 'thread-writer-locks').mkdir(exist_ok=True)
rollout = folder / f'rollout-2026-09-29T20-00-00-{identifier}.jsonl'
now = datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
action = sys.argv[1] if len(sys.argv) > 1 else 'working'
if action not in ('working', 'completed'):
    raise SystemExit('Expected working or completed')
def record(kind, payload):
    return json.dumps({'timestamp': now, 'type': kind, 'payload': payload}) + '\n'
if action == 'working':
    rollout.write_text(record('session_meta', {'id': identifier, 'cwd': '/tmp/SandboxPreviewProject', 'model': 'fixture'})
                       + record('event_msg', {'type': 'task_started'}))
    (root / 'session_index.jsonl').write_text(json.dumps({'id': identifier, 'thread_name': 'Sandbox monitoring check'}) + '\n')
    (root / '.codex-global-state.json').write_text(json.dumps({'local-projects': {'fixture': {'name': 'Sandbox Preview Project', 'rootPaths': ['/tmp/SandboxPreviewProject']}}}))
else:
    with rollout.open('a') as stream:
        stream.write(record('event_msg', {'type': 'task_complete'}))
print(f'Synthetic task: {action}')
