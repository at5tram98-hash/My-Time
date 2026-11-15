import { useEffect, useState } from 'react';
import { useData, useSync } from '../../app/data';
import { useUIActions } from '../../app/ui';
import { Group, Toggle } from '../../components/Controls';
import { MenuButton } from '../../components/Menu';
import { Icon } from '../../components/Icon';
import { repo } from '../../data/repo';
import { api, ApiError } from '../../sync/api';

function b64urlToBytes(s: string): Uint8Array {
  const b = atob(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4));
  return Uint8Array.from(b, (c) => c.charCodeAt(0));
}

type PushState = 'unsupported' | 'needsInstall' | 'default' | 'denied' | 'subscribed' | 'granted';

async function currentState(): Promise<PushState> {
  if (!('Notification' in window) || !('serviceWorker' in navigator)) {
    // iOS の Safari では、ホーム画面に追加した PWA でだけ通知を使える
    return /iPhone|iPad/.test(navigator.userAgent) ? 'needsInstall' : 'unsupported';
  }
  if (Notification.permission === 'denied') return 'denied';
  if (Notification.permission === 'default') return 'default';
  const reg = await navigator.serviceWorker.getRegistration();
  await reg?.pushManager?.getSubscription();
  return 'granted';
}

const LABEL: Record<PushState, string> = {
  unsupported: 'このブラウザは通知に対応していません',
  needsInstall: 'ホーム画面に追加すると使えます',
  default: '未設定',
  denied: '許可されていません（iPhoneの設定から変更）',
  granted: '許可済み（サーバー未登録）',
  subscribed: 'オン',
};

/** 通知の許可は必要になったときだけ求め、強制しない。配信時刻はOSや配信サービスの都合で保証できない */
export function NotificationSettings() {
  const { settings } = useData();
  const sync = useSync();
  const { showToast } = useUIActions();
  const accountId = sync.me?.user.id;
  const [state, setState] = useState<PushState>('default');
  useEffect(() => {
    let active = true;
    const check = async () => {
      const next = await currentState();
      if (active) setState(next);
      if (next !== 'granted' || !accountId) return;
      const reg = await navigator.serviceWorker.getRegistration();
      const sub = await reg?.pushManager?.getSubscription();
      if (!sub) return;
      await api.subscribePush(sub.toJSON());
      if (active) setState('subscribed');
    };
    void check().catch(() => { if (active) setState('granted'); });
    return () => { active = false; };
  }, [accountId]);

  const enable = async () => {
    try {
      if (!('PushManager' in window)) return showToast('ホーム画面に追加したアプリから設定してください');
      const perm = await Notification.requestPermission();
      if (perm !== 'granted') {
        setState(perm === 'denied' ? 'denied' : 'default');
        return;
      }
      const key = sync.config?.pushPublicKey;
      if (!key || !sync.me) {
        setState('granted');
        showToast(!sync.me ? 'Googleでログインしてから、もう一度通知を登録してください' : 'サーバーの通知設定を確認してください');
        return;
      }
      const reg = await navigator.serviceWorker.ready;
      const sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64urlToBytes(key) });
      await api.subscribePush(sub.toJSON());
      setState('subscribed');
      showToast('通知をオンにしました');
    } catch (e) {
      showToast(e instanceof Error ? e.message : '通知を設定できませんでした');
    }
  };

  const disable = async () => {
    const reg = await navigator.serviceWorker.getRegistration();
    const sub = await reg?.pushManager.getSubscription();
    if (sub) {
      await api.unsubscribePush(sub.endpoint).catch(() => undefined);
      await sub.unsubscribe();
    }
    setState(await currentState());
  };

  const hours = Array.from({ length: 24 }, (_, h) => h);
  const quietOn = settings.quietFrom != null && settings.quietTo != null;
  return (
    <>
      {/* 静穏時間と出発の通知（P42・P43）。設定は同期され、サーバーからの Push にも使う */}
      <Group header="通知を控える時間" footer="この時間に当たる通知は送りません（あとからまとめて送ることもしません）。「重要な通知」は出発の時刻・勤務の前・開始の時刻です。">
        <div className="row"><span className="row-label">通知を控える時間</span><Toggle label="通知を控える時間" checked={quietOn} onChange={(b) => void repo.updateSettings(b ? { quietFrom: 23, quietTo: 7 } : { quietFrom: null, quietTo: null })} /></div>
        {quietOn && (
          <div className="row" data-testid="quiet-range"><span className="row-label">時間</span><span className="row-value">
            <select className="select-input" value={settings.quietFrom!} onChange={(e) => void repo.updateSettings({ quietFrom: Number(e.target.value) })} aria-label="開始">{hours.map((h) => <option key={h} value={h}>{h}:00</option>)}</select>
            〜
            <select className="select-input" value={settings.quietTo!} onChange={(e) => void repo.updateSettings({ quietTo: Number(e.target.value) })} aria-label="終了">{hours.map((h) => <option key={h} value={h}>{h}:00</option>)}</select>
          </span></div>
        )}
        {quietOn && <div className="row"><span className="row-label">重要な通知は送る</span><Toggle label="重要な通知は送る" checked={settings.quietAllowImportant} onChange={(b) => void repo.updateSettings({ quietAllowImportant: b })} /></div>}
      </Group>
      <Group footer="場所と移動時間を入れた予定だけ、移動時間ぶん前に知らせます。位置情報は使いません。">
        <div className="row"><span className="row-label">出発の時刻を知らせる</span><Toggle label="出発の時刻を知らせる" checked={settings.departureNotify} onChange={(b) => void repo.updateSettings({ departureNotify: b })} /></div>
      </Group>
      <Group footer="iPhoneでは、Safariの共有メニューから「ホーム画面に追加」したアプリで通知を受け取れます。通知はOSと配信サービスを経由するため、届く時刻は前後することがあります。">
        <div className="row" data-testid="push-state">
          <span className="row-label">プッシュ通知</span>
          <span className="row-value muted">{LABEL[state]}</span>
        </div>
        {(state === 'default' || state === 'granted') && (
          <button type="button" className="row row-button center tint bold" onClick={() => void enable()} data-testid="enable-push">
            通知を許可する
          </button>
        )}
        {state === 'subscribed' && (
          <button type="button" className="row row-button center destructive" onClick={() => void disable()}>
            通知をオフにする
          </button>
        )}
        {!sync.config?.pushPublicKey && <div className="row"><span className="row-label muted small">サーバーの通知設定が未完了のため、アプリを閉じている間の通知は届きません。</span></div>}
      </Group>
      {state === 'subscribed' && <Group header="受信の確認" footer="送信後、この端末に通知が表示されるか確認してください。">
        <button type="button" className="row row-button tint" data-testid="test-push" onClick={() => { void (async () => { const sub = await (await navigator.serviceWorker.ready).pushManager.getSubscription(); if (!sub) throw new Error('通知を再登録してください'); await api.testPush(sub.endpoint); showToast('通知サービスへ送信しました。受信を確認してください'); })().catch(async (e: Error) => { if (e instanceof ApiError && e.status === 410) { const sub = await (await navigator.serviceWorker.ready).pushManager.getSubscription(); await sub?.unsubscribe(); setState('granted'); } showToast(e.message); }); }}>テスト通知を送る</button>
      </Group>}
      {!sync.me && <p className="note-text">アプリを閉じている間の通知には、Googleログインとこの端末の通知登録が必要です。</p>}
      <Group header="送る通知" footer="授業・アルバイトなど通常の予定には「未開始」の通知を送りません。未設定の課題・テスト対策のお知らせは1日1回までです。">
        <div className="row"><Icon name="clock" size={18} className="tint" /><span className="row-label">タスクの予定時刻を5分過ぎても未開始</span></div>
        <div className="row"><Icon name="bell" size={18} className="tint" /><span className="row-label">タスク・確認タスクのリマインダー（各タスクで設定）</span></div>
        <div className="row">
          <Icon name="flag" size={18} className="tint" />
          <span className="row-label">アルバイトの勤務前（新しい勤務先の初期値）</span>
          <MenuButton label="勤務前の通知" className="row-menu-btn" items={[1, 2, 3, 4, 6].map((h) => ({ label: `${h}時間前`, checked: settings.defaultJobReminderHours === h, onSelect: () => void repo.updateSettings({ defaultJobReminderHours: h }) }))}>
            {settings.defaultJobReminderHours}時間前
          </MenuButton>
        </div>
        <div className="row"><Icon name="tray" size={18} className="tint" /><span className="row-label">作業時間が未入力の課題・テスト対策（20時）</span></div>
      </Group>
    </>
  );
}
