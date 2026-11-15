import { memo, useEffect, useState } from 'react';
import { AnimatePresence, motion, useReducedMotion } from 'motion/react';
import { SPRING } from '../ui/motion';
import { expandAll, planNotices } from '@my-time/domain';
import { useNow } from './useNow';
import { repo } from '../data/repo';
import { reconcilePush } from '../sync/pushRegistration';
import { api } from '../sync/api';
import { syncEngine } from '../sync/engine';
import { Onboarding } from '../features/onboarding/Onboarding';
import { AccountChoice } from '../features/onboarding/AccountChoice';
import { takeFlash } from '../data/db';
import { DataProvider, useData, useSync } from './data';
import { UIProvider, useUI, useUIActions } from './ui';
import { SheetHost } from './SheetHost';
import { AlertHost, ToastHost } from '../components/Overlays';
import { Icon } from '../components/Icon';
import { TabBar, type TabDef } from '../ui/TabBar';
import { ContextMenuHost } from '../ui/ContextMenu';
import { UndoHost } from '../ui/undo';
import { RunningMiniBar } from '../ui/MiniBar';
import { installGlassPointer } from '../ui/gestures';
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

// 下部タブは4つ（今日・カレンダー・タスク・振り返り）。追加はタブではなく右の丸いボタン、設定は各画面右上の歯車（IOS-001・IOS-016）
const TABS: TabDef[] = [
  { id: 'home', label: '今日', icon: 'lanes' },
  { id: 'calendar', label: 'カレンダー', icon: 'calendar' },
  { id: 'tasks', label: 'タスク', icon: 'checklist' },
  { id: 'analysis', label: '振り返り', icon: 'chart' },
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

  // ステータス領域の色をOSだけでなくアプリで選んだ外観にも同期する。
  useEffect(() => {
    const media = window.matchMedia('(prefers-color-scheme: dark)');
    const apply = () => {
      const dark = settings.theme === 'dark' || (settings.theme === 'system' && media.matches);
      document.querySelectorAll<HTMLMetaElement>('meta[name="theme-color"]').forEach((meta) => {
        meta.removeAttribute('media');
        meta.content = dark ? '#000000' : '#ffffff';
      });
    };
    apply();
    media.addEventListener('change', apply);
    return () => media.removeEventListener('change', apply);
  }, [settings.theme]);

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
  const pushSync = useSync();
  useEffect(() => {
    const account = pushSync.me?.user.id;
    if (!account) return;
    const register = () => { void reconcilePush(account).catch(() => undefined); };
    register();
    window.addEventListener('online', register);
    return () => window.removeEventListener('online', register);
  }, [pushSync.me?.user.id]);

  const { tasks, events, employers, settings } = useData();
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
    const fresh = planNotices(tasks, evs, employers, now, 60_000, { quietFrom: settings.quietFrom, quietTo: settings.quietTo, quietAllowImportant: settings.quietAllowImportant, departure: settings.departureNotify }).filter((n) => !seen.has(n.key));
    for (const n of fresh) {
      seen.add(n.key);
      showToast(`${n.title}：${n.body}`);
    }
    if (fresh.length) sessionStorageSet('mt-seen', JSON.stringify([...seen].slice(-200)));
  }, [now]); // eslint-disable-line react-hooks/exhaustive-deps
  // 通知をタップして開いたとき
  useEffect(() => {
    const open = (t: { kind: string; id: string | null } | null) => {
      if (t?.kind === 'task' && t.id) openSheet({ kind: 'info', entity: 'task', id: t.id });
      else if (t?.kind === 'event' && t.id) openSheet({ kind: 'info', entity: 'event', id: t.id });
      else if (t?.kind === 'settings') setTab('tasks');
    };
    const p = new URLSearchParams(location.search);
    if (p.get('task')) open({ kind: 'task', id: p.get('task') });
    if (p.get('event')) open({ kind: 'event', id: p.get('event') });
    // 再読み込みで同じ画面が開き直さないよう、通知から来たパラメータを消す
    if (p.get('task') || p.get('event')) { p.delete('task'); p.delete('event'); history.replaceState(history.state, '', `${location.pathname}${p.size ? `?${p}` : ''}${location.hash}`); }
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

/** Google ログインから戻ったときの結果を、どのタブにいても知らせる（以前は「その他」を開いていないと出なかった） */
function LoginReturn() {
  const { showToast } = useUIActions();
  useEffect(() => {
    const p = new URLSearchParams(location.search);
    const r = p.get('login');
    if (!r) return;
    p.delete('login');
    const reason = p.get('reason');
    p.delete('reason');
    history.replaceState(null, '', location.pathname + (p.toString() ? `?${p}` : ''));
    showToast(r === 'ok' ? 'ログインしました' : `ログインできませんでした（${reason ?? '不明'}）`);
    void syncEngine.checkAccount();
  }, [showToast]);
  return null;
}

const inertIf = (on: boolean) => (on ? ({ inert: '', 'aria-hidden': true } as Record<string, unknown>) : {});

/** 文字入力中でなければ、キーボードで「n」＝追加、「/」＝検索、「t」＝今日（IOS-034） */
function KeyShortcuts() {
  const { openSheet, setTab, setHomeDate } = useUIActions();
  const { sheets, tab } = useUI();
  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      if (e.metaKey || e.ctrlKey || e.altKey || e.isComposing) return;
      const el = e.target as HTMLElement | null;
      if (el && (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName))) return;
      if (sheets.length || document.querySelector('.popup-layer, .alert-layer [role="alertdialog"]')) return;
      if (e.key === 'n') { e.preventDefault(); openSheet({ kind: 'quickAdd' }); }
      else if (e.key === 't') { setTab('home'); setHomeDate(Date.now()); }
      else if (e.key === '/' && tab !== 'other') { const b = document.querySelector<HTMLButtonElement>('.tab-panel:not([hidden]) [data-testid$="-search"]'); if (b) { e.preventDefault(); b.click(); } }
    };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, [openSheet, setTab, setHomeDate, sheets.length, tab]);
  return null;
}

/** ホーム画面のショートカット・URL から開く（P44）：?action=add / ?tab=tasks など */
function LaunchActions() {
  const { openSheet, setTab } = useUIActions();
  useEffect(() => {
    const p = new URLSearchParams(location.search);
    const action = p.get('action');
    const tab = p.get('tab');
    if (!action && !tab) return;
    if (tab === 'home' || tab === 'calendar' || tab === 'tasks' || tab === 'analysis') setTab(tab);
    if (action === 'add') openSheet({ kind: 'quickAdd' });
    if (action === 'inbox') openSheet({ kind: 'inbox' });
    p.delete('action'); p.delete('tab');
    history.replaceState(history.state, '', `${location.pathname}${p.size ? `?${p}` : ''}${location.hash}`);
  }, [openSheet, setTab]);
  return null;
}

function Shell() {
  const { tab, setTab, baseTab, closeSettings } = useUI();
  const { ready, settings } = useData();
  const { openSheet } = useUIActions();
  const reduce = useReducedMotion() ?? false;
  useEffect(() => installGlassPointer(), []);
  const base = baseTab;
  const settingsOpen = tab === 'other';
  return (
    <div className="app-shell">
      <AppearanceSync />
      <LoginReturn />
      {ready && <Background />}
      <RestoreBanner />
      <main className="app-main">
        {ready ? (
          <>
            <div className="tab-panel" hidden={base !== 'home'} {...inertIf(settingsOpen)}><Home /></div>
            <div className="tab-panel" hidden={base !== 'calendar'} {...inertIf(settingsOpen)}>{base === 'calendar' && <Calendar />}</div>
            <div className="tab-panel" hidden={base !== 'tasks'} {...inertIf(settingsOpen)}>{base === 'tasks' && <Tasks />}</div>
            <div className="tab-panel" hidden={base !== 'analysis'} {...inertIf(settingsOpen)}>{base === 'analysis' && <Analysis />}</div>
            {/* 設定は右から重ねて開く（戻ると元の画面のまま：IOS-016・IOS-040） */}
            <AnimatePresence>
              {settingsOpen && (
                <motion.div key="settings" className="settings-push" data-testid="settings-push"
                  initial={reduce ? { opacity: 0 } : { x: '100%' }} animate={reduce ? { opacity: 1 } : { x: 0 }} exit={reduce ? { opacity: 0 } : { x: '100%' }}
                  transition={reduce ? { duration: 0.12 } : SPRING.sheet}>
                  <Other onClose={closeSettings} />
                </motion.div>
              )}
            </AnimatePresence>
          </>
        ) : (
          <div className="loading" aria-busy="true" />
        )}
      </main>
      <TabBar tabs={TABS} current={base} onSelect={setTab}
        accessory={<button type="button" className="tabbar-add glass glass-i" aria-label="追加（文章で入力）" onClick={() => openSheet({ kind: 'quickAdd' })} data-testid="quick-add"><Icon name="plus" size={26} strokeWidth={2.3} /></button>} />
      <KeyShortcuts />
      {ready && <LaunchActions />}
      <SheetHost />
      <AnimatePresence>{ready && !settings.onboarded && <Onboarding key="onboarding" />}</AnimatePresence>
      {ready && <AccountChoice />}
      <RunningMiniBar />
      <ContextMenuHost />
      <UndoHost />
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
