import { useEffect, useState } from 'react';
import { useData, useSync } from '../../app/data';
import { useUIActions } from '../../app/ui';
import { Group } from '../../components/Controls';
import { MenuButton } from '../../components/Menu';
import { Icon } from '../../components/Icon';
import { repo } from '../../data/repo';
import { api } from '../../sync/api';

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
  const sub = await reg?.pushManager?.getSubscription();
  return sub ? 'subscribed' : 'granted';
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
  const [state, setState] = useState<PushState>('default');
  useEffect(() => {
    void currentState().then(setState);
  }, []);

  const enable = async () => {
    try {
      const perm = await Notification.requestPermission();
      if (perm !== 'granted') {
        setState(perm === 'denied' ? 'denied' : 'default');
        return;
      }
      const key = sync.config?.pushPublicKey;
      if (!key || !sync.me) {
        setState('granted');
        showToast('通知を許可しました。アプリを開いている間は画面で知らせます');
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

  return (
    <>
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
