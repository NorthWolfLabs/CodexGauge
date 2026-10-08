// Read-only billing evidence. Run with Vite+ from Companion/Relay. Credentials
// stay in memory and are never printed or included in the report.
import { execFileSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { parseArgs } from 'node:util';
const { values } = parseArgs({ options: {
  account: { type: 'string' }, from: { type: 'string' }, to: { type: 'string' },
  namespaces: { type: 'string' }, out: { type: 'string' }, users: { type: 'string', default: '1' },
} });
const account = values.account ?? process.env.CLOUDFLARE_ACCOUNT_ID;
if (!account || !/^[a-f0-9]{32}$/.test(account)) throw new Error('Supply --account or CLOUDFLARE_ACCOUNT_ID.');
if (!values.from || !values.to) throw new Error('Supply --from and --to as UTC timestamps.');
const from = new Date(values.from).toISOString(), to = new Date(values.to).toISOString();
const days = (Date.parse(to) - Date.parse(from)) / 86_400_000, users = Number(values.users);
if (!(days > 0 && days <= 7 && Number.isInteger(users) && users > 0)) throw new Error('Choose up to seven days and a positive user count.');
let auth: { token: string };
try {
  const raw = execFileSync(process.execPath, ['node_modules/wrangler/bin/wrangler.js', 'auth', 'token', '--json'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  auth = JSON.parse(raw.slice(raw.indexOf('{')));
} catch { throw new Error('Wrangler authentication unavailable; run vp exec wrangler login first.'); }
const headers = { Authorization: `Bearer ${auth.token}`, 'Content-Type': 'application/json' };
async function api(url: string, body?: unknown) {
  const response = await fetch(url, { method: body ? 'POST' : 'GET', headers, body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(30_000) });
  if (!response.ok) throw new Error(`Cloudflare returned HTTP ${response.status}.`);
  return await response.json() as any;
}
let namespaces = values.namespaces?.split(',');
if (!namespaces) {
  const data = await api(`https://api.cloudflare.com/client/v4/accounts/${account}/workers/durable_objects/namespaces`);
  if (!data.success) throw new Error('Could not discover relay namespaces.');
  namespaces = data.result.filter((n: any) => n.script === 'codexgauge-relay-dev' && ['MacFeedV2', 'PushReceiverV2'].includes(n.class)).map((n: any) => n.id);
}
if (!namespaces?.length || !namespaces.every(n => /^[a-f0-9]{32}$/.test(n))) throw new Error('No valid protocol-2 namespaces found.');
const filter = `datetime_geq:${JSON.stringify(from)},datetime_lt:${JSON.stringify(to)},namespaceId_in:${JSON.stringify(namespaces)}`;
const result = await api('https://api.cloudflare.com/client/v4/graphql', { query: `{ viewer { accounts(filter:{accountTag:"${account}"}) {
  durableObjectsPeriodicGroups(limit:1000,filter:{${filter}}) { dimensions { namespaceId } sum { activeTime cpuTime duration rowsRead rowsWritten subrequests inboundWebsocketMsgCount } }
  durableObjectsInvocationsAdaptiveGroups(limit:1000,filter:{${filter}}) { dimensions { namespaceId type status } sum { requests errors wallTime } }
  workersInvocationsAdaptive(limit:1000,filter:{datetime_geq:${JSON.stringify(from)},datetime_lt:${JSON.stringify(to)},scriptName:"codexgauge-relay-dev"}) { dimensions { status } sum { requests errors cpuTimeUs subrequests } }
} } }` });
if (result.errors?.length) throw new Error('Cloudflare analytics rejected the query: ' + result.errors.map((e: any) => e.message).join('; '));
const data = result.data.viewer.accounts[0];
if (!data) throw new Error('No accessible account returned.');
const total = (groups: any[], field: string) => groups.reduce((sum, g) => sum + (g.sum[field] ?? 0), 0);
const periodic = data.durableObjectsPeriodicGroups;
const report = {
  capturedAt: new Date().toISOString(), from, to, days, users, namespaces,
  note: 'Analytics may be delayed or sampled. Counters are not an invoice. Worker metrics cover this script across both namespace versions; use a post-cutover interval. Normalize by actual active-user days and inspect delivery errors before estimating cost.',
  summary: {
    durableGBSeconds: total(periodic, 'duration'), durableActiveHours: total(periodic, 'activeTime') / 3_600_000_000,
    durableCPUSeconds: total(periodic, 'cpuTime') / 1_000_000,
    rowsWritten: total(periodic, 'rowsWritten'), rowsRead: total(periodic, 'rowsRead'),
    durableGBSecondsPerUserDay: total(periodic, 'duration') / days / users,
    rowsWrittenPerUserDay: total(periodic, 'rowsWritten') / days / users,
    workerRequests: total(data.workersInvocationsAdaptive, 'requests'), workerCPUSeconds: total(data.workersInvocationsAdaptive, 'cpuTimeUs') / 1_000_000,
  }, data,
};
const encoded = JSON.stringify(report, null, 2) + '\n';
if (values.out) writeFileSync(values.out, encoded, { mode: 0o600 });
console.log(JSON.stringify(report.summary, null, 2));
