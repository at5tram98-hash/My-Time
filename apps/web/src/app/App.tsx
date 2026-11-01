import { memo, useEffect, useState } from 'react';
import { AnimatePresence } from 'motion/react';
import { expandAll, planNotices } from '@my-time/domain';
import { useNow } from './useNow';
import { repo } from '../data/repo';
import { api } from '../sync/api';
import { syncEngine } from '../sync/engine';
import { Onboarding } from '../features/onboarding/Onboarding';
import { AccountChoice } from '../features/onboarding/AccountChoice';
import { takeFlash } from '../data/db';
import { DataProvider, useAttention, useData, useSync } from './data';
import { UIProvider, useUI, type TabId, useUIActions } from './ui';
import { SheetHost } from './SheetHost';
import { AlertHost, ToastHost } from '../components/Overlays';
import { Icon, type IconName } from '../components/Icon';
import { HomeScreen } from '../features/home/HomeScreen';
import { CalendarScreen } from '../features/calendar/CalendarScreen';
import { TasksScreen } from '../features/tasks/TasksScreen';
import { AnalysisScreen } from '../features/analysis/AnalysisScreen';
import { OtherScreen } from '../features/other/OtherScreen';

// タブ切替でほかのタブの画面を再描画しない（各画面は自分のデータ・日付の変化でだけ描き直す）
const Home = memo(HomeScreen);
const Calendar = memo(CalendarScreen);
const Tasks = memo(TasksScreen);
const Analysis = memo(AnalysisScreen);
const Other = memo(OtherScreen);

const TABS: { id: TabId; label: string; icon: IconName }[] = [
  { id: 'home', label: 'ホーム', icon: 'house' },
  { id: 'calendar', label: 'カレンダー', icon: 'calendar' },
  { id: 'tasks', label: 'タスク', icon: 'checklist' },
  { id: 'analysis', label: '分析', icon: 'chart' },
  { id: 'other', label: 'その他', icon: 'moreCircle' },
];

const TEXT_SIZE_PX = { small: '15px', large: '19px', xlarge: '22px' } as const;

function AppearanceSync() {
  const { settings } = useData();
  useEffect(() => {
    const root = document.documentElement;
    if (settings.theme === 'system') root.removeAttribute('data-theme');
    else root.setAttribute('data-theme', settings.theme);
    if (settings.textSize === 'system') root.style.removeProperty('--base-size');
    else root.style.setProperty('--base-size', TEXT_SIZE_PX[settings.textSize]);
    root.dataset.textSize = settings.textSize;
  }, [settings.theme, settings.textSize]);

  // iOS のソフトウェアキーボード表示中は、その高さだけシートを持ち上げて入力欄・保存ボタンを隠さない
  useEffect(() => {
    const vv = window.visualViewport;
    if (!vv) return;
    const update = () => {
      const kb = Math.max(0, window.innerHeight - vv.height - vv.offsetTop);
      document.documentElement.style.setProperty('--kb', `${Math.round(kb)}px`);
    };
    update();
    vv.addEventListener('resize', update);
    vv.addEventListener('scroll', update);
    return () => {
      vv.removeEventListener('resize', update);
      vv.removeEventListener('scroll', update);
    };
  }, []);
  return null;
}

/** 同期の開始、AR の反映、アプリ表示中の通知、通知タップからの遷移 */
function Background() {
  const { tasks, events, employers } = useData();
  const { openSheet, setTab, showToast } = useUIActions();
  const now = useNow(30_000);
  useEffect(() => {
    void syncEngine.start();
    return () => syncEngine.stop();
  }, []);
  // アカウントの切り替え・ログアウト後に一度だけ出す案内
  useEffect(() => {
    const f = takeFlash();
    if (f) showToast(f);
  }, [showToast]);
  useEffect(() => {
    void repo.applyAutoReservations();
  }, [now]);
  // アプリを開いている間の通知（Push と重複しないよう画面内の表示のみ。同じものは二度出さない）
  useEffect(() => {
    const seen = new Set<string>(JSON.parse(sessionStorageGet('mt-seen') ?? '[]') as string[]);
    const evs = expandAll(events, now - 86_400_000 * 2, now + 86_400_000 * 2);
    const fresh = planNotices(tasks, evs, employers, now, 60_000).filter((n) => !seen.has(n.key));
    for (const n of fresh) {
      seen.add(n.key);
      showToast(`${n.title}：${n.body}`);
    }
    if (fresh.length) sessionStorageSet('mt-seen', JSON.stringify([...seen].slice(-200)));
  }, [now]); // eslint-disable-line react-hooks/exhaustive-deps
  // 通知をタップして開いたとき
  useEffect(() => {
    const open = (t: { kind: string; id: string | null } | null) => {
      if (t?.kind === 'task' && t.id) openSheet({ kind: 'task', id: t.id });
      else if (t?.kind === 'event' && t.id) openSheet({ kind: 'editEvent', eventId: t.id });
      else if (t?.kind === 'settings') setTab('tasks');
    };
    const p = new URLSearchParams(location.search);
    if (p.get('task')) open({ kind: 'task', id: p.get('task') });
    if (p.get('event')) open({ kind: 'event', id: p.get('event') });
    const onMsg = (e: MessageEvent<{ type: string; target: { kind: string; id: string | null } | null }>) => e.data?.type === 'open' && open(e.data.target);
    navigator.serviceWorker?.addEventListener('message', onMsg);
    return () => navigator.serviceWorker?.removeEventListener('message', onMsg);
  }, [openSheet, setTab]);
  return null;
}

function sessionStorageGet(k: string): string | null {
  try {
    return sessionStorage.getItem(k);
  } catch {
    return null;
  }
}
function sessionStorageSet(k: string, v: string) {
  try {
    sessionStorage.setItem(k, v);
  } catch {
    /* 保存できない環境では毎回表示しうるが、機能は維持 */
  }
}

/** 期間指定の復元で過去データを表示している間のお知らせ */
function RestoreBanner() {
  const { restoredKeys } = useData();
  const sync = useSync();
  const { confirm, showToast } = useUIActions();
  const [busy, setBusy] = useState(false);
  if (restoredKeys.size === 0) return null;
  const end = async () => {
    if (!(await confirm({ title: '閲覧を終了しますか？', message: '戻した過去データを通常の画面から外します。Googleドライブの保管データは残ります。', confirmLabel: '閲覧を終了' }))) return;
    setBusy(true);
    try {
      const { items } = await api.restoreSessions();
      for (const s of items) await api.endRestore(s.id);
      await syncEngine.syncNow();
    } catch (e) {
      showToast(e instanceof Error ? e.message : '終了できませんでした');
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className="restore-banner" role="status" data-testid="restore-banner">
      <Icon name="undo" size={16} />
      <span>過去のデータを{restoredKeys.size}件表示中</span>
      <button type="button" className="pill-btn small" disabled={busy || !sync.me} onClick={() => void end()} data-testid="banner-end-restore">閲覧を終了</button>
    </div>
  );
}

function Shell() {
  const { tab, setTab } = useUI();
  const { ready, settings } = useData();
  const attention = useAttention();
  return (
    <div className="app-shell">
      <AppearanceSync />
      {ready && <Background />}
      <RestoreBanner />
      <main className="app-main">
        {ready ? (
          <>
            <div className="tab-panel" hidden={tab !== 'home'}><Home /></div>
            <div className="tab-panel" hidden={tab !== 'calendar'}>{tab === 'calendar' && <Calendar />}</div>
            <div className="tab-panel" hidden={tab !== 'tasks'}>{tab === 'tasks' && <Tasks />}</div>
            <div className="tab-panel" hidden={tab !== 'analysis'}>{tab === 'analysis' && <Analysis />}</div>
            <div className="tab-panel" hidden={tab !== 'other'}>{tab === 'other' && <Other />}</div>
          </>
        ) : (
          <div className="loading" aria-busy="true" />
        )}
      </main>
      <nav className="tabbar" aria-label="タブ" data-testid="tabbar">
        <div className="tabbar-glass" style={{ ['--tab-index' as string]: Math.max(0, TABS.findIndex((t) => t.id === tab)) }}>
          <span className="tab-capsule" aria-hidden />
          {TABS.map((t) => {
            const on = tab === t.id;
            return (
              <button key={t.id} type="button" className={`tab ${on ? 'active' : ''}`} aria-current={on ? 'page' : undefined} onClick={() => setTab(t.id)} data-testid={`tab-${t.id}`}>
                <span className="tab-icon">
                  <Icon name={t.icon} size={24} strokeWidth={on ? 2.2 : 1.8} />
                  {t.id === 'other' && attention > 0 && <span className="tab-alert" role="img" aria-label="確認が必要なお知らせがあります" data-testid="other-alert"><Icon name="exclamation" size={11} strokeWidth={3.4} /></span>}
                </span>
                <span className="tab-label">{t.label}</span>
              </button>
            );
          })}
        </div>
      </nav>
      <SheetHost />
      <AnimatePresence>{ready && !settings.onboarded && <Onboarding key="onboarding" />}</AnimatePresence>
      {ready && <AccountChoice />}
      <AlertHost />
      <ToastHost />
    </div>
  );
}

export function App() {
  return (
    <DataProvider>
      <UIProvider>
        <Shell />
      </UIProvider>
    </DataProvider>
  );
}
