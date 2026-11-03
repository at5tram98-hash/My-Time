import { api } from './api';
import { db, ownerOf } from '../data/db';

/** Reconcile existing browser permissions/subscription with this account's server. */
export async function reconcilePush(account: string): Promise<void> {
  if (ownerOf(db.name) !== account || typeof Notification === 'undefined' || Notification.permission !== 'granted' || !('serviceWorker' in navigator)) return;
  const reg = await navigator.serviceWorker.getRegistration();
  const sub = await reg?.pushManager?.getSubscription();
  if (sub) await api.subscribePush(sub.toJSON());
}
