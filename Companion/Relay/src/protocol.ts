import { z } from 'zod';

export const token = z.string().regex(/^[a-f0-9]{64}$/i);
export const macID = z.string().uuid();
const short = z.string().max(200);
const timestamp = z.number().finite().nonnegative();
export const snapshotSchema = z.object({
  schemaVersion: z.literal(1), id: macID, name: z.string().min(1).max(80), observedAt: timestamp,
  account: z.object({
    id: z.string().min(1).max(128), plan: short.nullish(), email: short.nullish(), accountType: short.nullish(), historyTruncated: z.boolean().nullish(), historyObservedAt: timestamp.nullish(), observedAt: timestamp,
    windows: z.array(z.object({
      id: short, name: short, remainingPercent: z.number().int().min(0).max(100), resetsAt: timestamp.nullish(),
    }).strict()).max(30),
    bankedResets: z.number().int().min(0).max(100000).nullish(),
    credits: z.array(z.object({ id: short, name: short, hasCredits: z.boolean(), unlimited: z.boolean(), balance: short.nullish() }).strict()).max(30).nullish(),
    lifetimeTokens: z.number().int().nonnegative().nullish(),
    metrics: z.object({ peakDailyTokens: z.number().int().nonnegative().nullish(), longestTurnSeconds: z.number().int().nonnegative().nullish(),
      currentStreakDays: z.number().int().nonnegative().nullish(), longestStreakDays: z.number().int().nonnegative().nullish() }).strict().nullish(),
    dailyTokens: z.array(z.object({ id: z.string().regex(/^\d{4}-\d{2}-\d{2}$/), tokens: z.number().int().nonnegative() }).strict()).max(2000),
  }).strict().nullish(),
  tasks: z.array(z.object({
    id: short, title: short, project: short.nullish(),
    state: z.enum(['running', 'needsInput', 'needsApproval', 'completed']), activity: short,
    tokensPerMinute: z.number().finite().nonnegative(), totalTokens: z.number().int().nonnegative(),
    contextPercent: z.number().finite().min(0).max(100).nullish(),
    startedAt: timestamp.nullish(), eventAt: timestamp.nullish(), agentCount: z.number().int().nonnegative(),
    observedAt: timestamp.nullish(), hasTokenObservation: z.boolean().nullish(),
    metrics: z.object({ model: short.nullish(), fiveMinuteRate: z.number().finite().nonnegative().nullish(), callsPerMinute: z.number().finite().nonnegative().nullish(),
      input: z.number().int().nonnegative().nullish(), cachedInput: z.number().int().nonnegative().nullish(), cacheWriteInput: z.number().int().nonnegative().nullish(),
      output: z.number().int().nonnegative().nullish(), reasoning: z.number().int().nonnegative().nullish(), latestOutput: z.number().int().nonnegative().nullish(),
      firstTokenMilliseconds: z.number().int().nonnegative().nullish(), lastTurnSeconds: z.number().finite().nonnegative().nullish(), contextIncludesAgent: z.boolean().nullish(), tokenTotalsComplete: z.boolean().nullish() }).strict().nullish(),
  }).strict()).max(200),
}).strict();
export type Snapshot = z.infer<typeof snapshotSchema>;
export type Scope = 'full' | 'usage';
export function presentation(snapshot: Snapshot | undefined, scope: Scope) {
  if (!snapshot) return { type: 'waiting' };
  return { type: 'snapshot', deliveryTimestamp: Math.floor(Date.now() / 1000), snapshot: { ...snapshot, tasks: scope === 'usage' ? [] : snapshot.tasks } };
}
