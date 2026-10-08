import { WorkerEntrypoint } from 'cloudflare:workers';
import { sendPush, sendLivePush, type PushRegistration, type PushResult } from './apns';
import type { AlertEvent } from './alerts';
import type { LiveMessage } from './live-activities';

export interface Delivery {
  id: string;
  attemptID: string;
  mac: string;
  generation: number;
  revision: number;
  device: PushRegistration;
  alert?: AlertEvent;
  live?: LiveMessage;
  urgent: boolean;
  durable: boolean;
  attempts: number;
  due: number;
  expires: number;
  leaseUntil?: number;
  revoked?: boolean;
}
export interface DeliveryBatch { receiver: string; deliveries: Delivery[] }

export async function deliverBatch(env: Env, batch: DeliveryBatch): Promise<PushResult[]> {
  const receiver = env.RECEIVERS.get(env.RECEIVERS.idFromString(batch.receiver));
  const results = await Promise.all(batch.deliveries.map(async delivery => {
    const start = Date.now();
    let result: PushResult;
    try {
      result = delivery.live
        ? await sendLivePush(env, delivery.device, delivery.live, delivery.urgent)
        : await sendPush(env, delivery.device, delivery.alert!);
    } catch { result = 'retry'; }
    // Routine accepted metrics need neither a durable receipt nor another RPC.
    // Their next observation replaces them. Lifecycle/alert receipts and errors
    // must update the durable outbox or invalidate the affected token.
    if (delivery.durable || delivery.urgent || result !== 'accepted') {
      await receiver.complete(delivery, result);
    }
    return { result, ms: Date.now() - start };
  }));
  if (results.length && (results.some(r => r.result !== 'accepted') || Math.random() < 1 / 64)) {
    console.info('relay.delivery', { count: results.length, accepted: results.filter(r => r.result === 'accepted').length,
      maxMilliseconds: Math.max(...results.map(r => r.ms)), results: [...new Set(results.map(r => r.result))] });
  }
  return results.map(r => r.result);
}

// Internal service binding only. A DO alarm hands off quickly; the Worker owns
// APNs waiting. A durable lease/alarm remains until completion, so terminating
// this waitUntil task cannot lose an accepted important event.
export class PushDelivery extends WorkerEntrypoint<Env> {
  dispatch(receiver: string): void {
    this.ctx.waitUntil((async () => {
      const stub = this.env.RECEIVERS.get(this.env.RECEIVERS.idFromString(receiver));
      await deliverBatch(this.env, { receiver, deliveries: await stub.claimPending() });
    })());
  }
}
