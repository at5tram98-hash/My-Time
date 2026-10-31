import { useEffect, useState, type ReactNode } from 'react';
import { AnimatePresence, motion, useReducedMotion } from 'motion/react';
import { useLiveQuery } from 'dexie-react-hooks';
import { formatDayLabel, formatHm } from '@my-time/domain';
import { useAttention, useData, useSync } from '../../app/data';
import { useUI } from '../../app/ui';
import { Group, Toggle } from '../../components/Controls';
import { Icon, type IconName } from '../../components/Icon';
import { MenuButton } from '../../components/Menu';
import { db, type TextSizePref, type ThemePref } from '../../data/db';
import { repo } from '../../data/repo';
import { api } from '../../sync/api';
import { syncEngine } from '../../sync/engine';
import { CalendarsPage, EmployersPage, SubjectsPage } from './ManagePages';
import { BackupsPage, NoticesPage, RestorePage } from './DataPages';
import { DeviceTransferPage } from './DeviceTransferPage';
import { NotificationSettings } from './NotificationSettings';

const THEME_LABEL: Record<ThemePref, string> = { system: 'システムに合わせる', light: 'ライト', dark: 'ダーク' };
const SIZE_LABEL: Record<TextSizePref, string> = { system: 'システムに合わせる', small: '小', large: '大', xlarge: '特大' };

export type OtherPage = 'root' | 'calendars' | 'subjects' | 'employers' | 'backups' | 'restore' | 'notices' | 'notifications' | 'transfer';

const PAGE_TITLE: Record<OtherPage, string> = {
  root: 'その他',
  transfer: 'データの移行',
  calendars: 'カレンダー',
  subjects: '授業の科目',
  employers: '勤務先',
  backups: 'バックアップ管理',
  restore: '期間指定の復元',
  notices: 'お知らせ',
  notifications: '通知',
};

export function SettingIcon({ name, color }: { name: IconName; color: string }) {
  return (
    <span className="set-icon" style={{ background: color }} aria-hidden>
      <Icon name={name} size={18} strokeWidth={2.1} />
    </span>
  );
}

export function NavRow({ icon, color, label, value, onClick, badge, testId }: { icon: IconName; color: string; label: string; value?: ReactNode; onClick: () => void; badge?: number; testId?: string }) {
  return (
    <button type="button" className="row row-button" onClick={onClick} data-testid={testId}>
      <SettingIcon name={icon} color={color} />
      <span className="row-label">{label}</span>
      {badge ? <span className="count-badge" aria-label={`${badge}件`}>{badge}</span> : null}
      {value != null && <span className="row-value muted">{value}</span>}
      <Icon name="chevronRight" size={16} className="chev" />
    </button>
  );
}

function SubPage({ title, onBack, children }: { title: string; onBack: () => void; children: ReactNode }) {
  const reduce = useReducedMotion();
  return (
    <motion.div className="subpage" initial={reduce ? { opacity: 0 } : { x: '100%' }} animate={reduce ? { opacity: 1 } : { x: 0 }} exit={reduce ? { opacity: 0 } : { x: '100%' }} transition={reduce ? { duration: 0.12 } : { type: 'spring', stiffness: 420, damping: 42 }}>
      <header className="nav">
        <button type="button" className="back-btn" onClick={onBack} data-testid="back">
          <Icon name="chevronLeft" size={22} strokeWidth={2.4} />
          その他
        </button>
        <h1 className="nav-center-title">{title}</h1>
        <span className="nav-spacer" />
      </header>
      <div className="scroll-body">{children}</div>
    </motion.div>
  );
}

function syncLabel(s: ReturnType<typeof useSync>, pending: number): string {
  switch (s.phase) {
    case 'unavailable':
      return 'この配信先では利用できません';
    case 'notConfigured':
      return 'サーバー未設定';
    case 'loggedOut':
      return '未ログイン';
    case 'syncing':
      return '同期中…';
    case 'offline':
      return `オフライン · 未送信 ${pending}件`;
    case 'error':
      return `再試行待ち · 未送信 ${pending}件`;
    case 'chooseAccount':
      return 'データの移行を確認中';
    case 'switching':
      return '切り替え中…';
    case 'idle':
      return pending ? `未送信 ${pending}件` : s.lastSuccessAt ? `同期済み ${formatHm(s.lastSuccessAt)}` : '同期済み';
    default:
      return '確認中…';
  }
}

export function OtherScreen() {
  const { settings, tasks, events, outboxPending } = useData();
  const { openSheet, confirm, showToast } = useUI();
  const sync = useSync();
  const attention = useAttention();
  const [page, setPage] = useState<OtherPage>('root');
  const logCount = useLiveQuery(() => db.operationLog.count(), []) ?? 0;
  const loggedIn = Boolean(sync.me);

  // ログインから戻ったときの結果を知らせる
  useEffect(() => {
    const p = new URLSearchParams(location.search);
    const r = p.get('login');
    if (!r) return;
    showToast(r === 'ok' ? 'ログインしました' : `ログインできませんでした（${p.get('reason') ?? '不明'}）`);
    history.replaceState(null, '', location.pathname);
    if (r === 'ok') void syncEngine.checkAccount();
  }, [showToast]);

  const logout = async () => {
    if (outboxPending > 0 && !(await confirm({ title: 'ログアウトしますか？', message: `まだ送信していない変更が${outboxPending}件あります。この端末には残り、同じアカウントでログインし直すと送信します。`, confirmLabel: 'ログアウト', destructive: true }))) return;
    await syncEngine.logout();
  };
  const area = syncEngine.owner;

  return (
    <div className="screen other" data-testid="other-screen">
      <header className="nav large">
        <div className="nav-row"><h1 className="large-title">その他</h1></div>
      </header>
      <div className="scroll-body">
        <Group header="アカウントと同期" footer={sync.phase === 'unavailable' ? 'この配信先にはサーバーがないため、データはこの端末内だけに保存されます。' : 'データはまず端末に保存され、オンラインのときにクラウドへ送られます。オフラインでも使えます。'}>
          <div className="row" data-testid="account-row">
            <SettingIcon name="person" color="#8E8E93" />
            <span className="row-label">Googleアカウント</span>
            {loggedIn ? (
              <span className="row-value">{sync.me!.user.email}</span>
            ) : sync.phase === 'notConfigured' || sync.phase === 'unavailable' ? (
              <span className="row-value muted">未設定</span>
            ) : (
              <a className="pill-btn primary small" href={api.loginUrl()} data-testid="login">Googleでログイン</a>
            )}
          </div>
          <div className="row" data-testid="data-area">
            <SettingIcon name="stack" color="#5AC8FA" />
            <span className="row-label">表示中のデータ</span>
            <span className="row-value muted">{area ? (loggedIn ? 'このアカウント' : 'アカウント（再ログインが必要）') : 'この端末（ログインなし）'}</span>
          </div>
          <button type="button" className="row row-button" onClick={() => void syncEngine.syncNow()} disabled={!loggedIn} data-testid="sync-row">
            <SettingIcon name="cloud" color="#34C759" />
            <span className="row-label">同期</span>
            <span className="row-value muted" data-testid="sync-status">{syncLabel(sync, outboxPending)}</span>
          </button>
          <NavRow icon="stack" color="#FF9500" label="Driveバックアップ" value={loggedIn ? (sync.me!.drive.connected ? '毎日22時' : '未接続') : '—'} onClick={() => setPage('backups')} testId="nav-backups" />
          <NavRow icon="stack" color="#30B0C7" label="データの移行" onClick={() => setPage('transfer')} testId="nav-transfer" />
          <NavRow icon="undo" color="#5856D6" label="期間指定の復元" onClick={() => setPage('restore')} testId="nav-restore" />
          <NavRow icon="bell" color="#FF3B30" label="お知らせ" badge={attention} onClick={() => setPage('notices')} testId="nav-notices" />
          {loggedIn && (
            <button type="button" className="row row-button destructive" onClick={() => void logout()} data-testid="logout">
              <span className="row-label">ログアウト</span>
            </button>
          )}
        </Group>

        <Group header="表示">
          <div className="row">
            <SettingIcon name="paint" color="#5856D6" />
            <span className="row-label">外観</span>
            <MenuButton label="外観" className="row-menu-btn" testId="theme-menu" items={(Object.keys(THEME_LABEL) as ThemePref[]).map((k) => ({ label: THEME_LABEL[k], checked: settings.theme === k, onSelect: () => void repo.updateSettings({ theme: k }) }))}>
              {THEME_LABEL[settings.theme]}
              <Icon name="arrowUpDown" size={14} />
            </MenuButton>
          </div>
          <div className="row">
            <SettingIcon name="textsize" color="#007AFF" />
            <span className="row-label">文字サイズ</span>
            <MenuButton label="文字サイズ" className="row-menu-btn" testId="size-menu" items={(Object.keys(SIZE_LABEL) as TextSizePref[]).map((k) => ({ label: SIZE_LABEL[k], checked: settings.textSize === k, onSelect: () => void repo.updateSettings({ textSize: k }) }))}>
              {SIZE_LABEL[settings.textSize]}
              <Icon name="arrowUpDown" size={14} />
            </MenuButton>
          </div>
          <div className="row">
            <SettingIcon name="daysN" color="#30B0C7" />
            <span className="row-label">カレンダーを広げたときの日数</span>
            <MenuButton label="広げたときの日数" className="row-menu-btn" items={Array.from({ length: 7 }, (_, i) => ({ label: `${i + 1}日`, checked: settings.expandedDays === i + 1, onSelect: () => void repo.updateSettings({ expandedDays: i + 1 }) }))}>
              {settings.expandedDays}日
              <Icon name="arrowUpDown" size={14} />
            </MenuButton>
          </div>
        </Group>

        <Group header="カレンダー">
          <NavRow icon="calendar" color="#FF3B30" label="カレンダー" onClick={() => setPage('calendars')} testId="nav-calendars" />
          <NavRow icon="checklist" color="#5E5CE6" label="授業の科目" onClick={() => setPage('subjects')} testId="nav-subjects" />
          <NavRow icon="flag" color="#FF9F0A" label="勤務先" onClick={() => setPage('employers')} testId="nav-employers" />
        </Group>

        <Group header="タスクと分析" footer="一時停止したタスク・自動開始/終了（AR）したタスクは、初期設定では分析の集計に含めません。授業・アルバイトの予定は常に対象外です。">
          <div className="row">
            <label className="row-label" htmlFor="opt-paused">一時停止したタスクを含める</label>
            <Toggle id="opt-paused" label="一時停止したタスクを含める" checked={settings.analysisIncludePaused} onChange={(v) => void repo.updateSettings({ analysisIncludePaused: v })} />
          </div>
          <div className="row">
            <label className="row-label" htmlFor="opt-auto">自動開始・終了したタスクを含める</label>
            <Toggle id="opt-auto" label="自動開始・終了したタスクを含める" checked={settings.analysisIncludeAuto} onChange={(v) => void repo.updateSettings({ analysisIncludeAuto: v })} />
          </div>
          <div className="row">
            <span className="row-label">新しいタスクの通知</span>
            <MenuButton label="新しいタスクの通知" className="row-menu-btn" items={[null, 0, 5, 10, 30, 60].map((m) => ({ label: m == null ? 'なし' : m === 0 ? '開始時刻' : `${m}分前`, checked: settings.defaultNotifyMinutes === m, onSelect: () => void repo.updateSettings({ defaultNotifyMinutes: m }) }))}>
              {settings.defaultNotifyMinutes == null ? 'なし' : settings.defaultNotifyMinutes === 0 ? '開始時刻' : `${settings.defaultNotifyMinutes}分前`}
              <Icon name="arrowUpDown" size={14} />
            </MenuButton>
          </div>
        </Group>

        <Group header="通知">
          <NavRow icon="bell" color="#FF2D55" label="通知" onClick={() => setPage('notifications')} testId="nav-notifications" />
        </Group>

        <Group header="入力・操作" footer="予定やタスクの時間が重なったときに提案する空き時間の範囲です。既存の予定は自動では動かしません。">
          <div className="row">
            <span className="row-label">提案する時間帯</span>
            <MenuButton label="提案の開始時刻" className="row-menu-btn" items={[5, 6, 7, 8, 9, 10].map((h) => ({ label: `${h}時から`, checked: settings.suggestFromHour === h, onSelect: () => void repo.updateSettings({ suggestFromHour: h }) }))}>
              {settings.suggestFromHour}時
            </MenuButton>
            〜
            <MenuButton label="提案の終了時刻" className="row-menu-btn" items={[20, 21, 22, 23, 24].map((h) => ({ label: `${h}時まで`, checked: settings.suggestToHour === h, onSelect: () => void repo.updateSettings({ suggestToHour: h }) }))}>
              {settings.suggestToHour}時
            </MenuButton>
          </div>
          <div className="row">
            <span className="row-label">提案の刻み</span>
            <MenuButton label="提案の刻み" className="row-menu-btn" items={([15, 30, 60] as const).map((m) => ({ label: `${m}分`, checked: settings.suggestStepMin === m, onSelect: () => void repo.updateSettings({ suggestStepMin: m }) }))}>
              {settings.suggestStepMin}分
              <Icon name="arrowUpDown" size={14} />
            </MenuButton>
          </div>
        </Group>

        <Group header="共有・連携" footer="TimeTree の公式APIは提供が終了しているため、書き出したカレンダーファイル（.ics）またはテキストから取り込みます。">
          <NavRow icon="link" color="#34C759" label="予定の取り込み（TimeTreeなど）" onClick={() => openSheet({ kind: 'import' })} testId="nav-import" />
        </Group>

        <Group header="この端末のデータ">
          <div className="row"><span className="row-label">タスク</span><span className="row-value" data-testid="count-tasks">{tasks.length}件</span></div>
          <div className="row"><span className="row-label">予定</span><span className="row-value">{events.length}件</span></div>
          <div className="row"><span className="row-label">操作ログ</span><span className="row-value">{logCount}件</span></div>
          <div className="row"><span className="row-label">未送信の変更</span><span className="row-value">{outboxPending}件</span></div>
        </Group>

        <Group header="このアプリについて" footer="終了から30日を過ぎた予定・タスクは、Googleドライブへの保存を確認してから通常の画面から削除されます。削除したデータは「期間指定の復元」で見返せます。">
          <div className="row"><span className="row-label">バージョン</span><span className="row-value muted">0.2.0（Phase 2）</span></div>
          <button type="button" className="row row-button" onClick={() => void repo.updateSettings({ onboarded: false })}>
            <span className="row-label tint">はじめの設定をもう一度見る</span>
          </button>
        </Group>
      </div>

      <AnimatePresence>
        {page !== 'root' && (
          <SubPage key={page} title={PAGE_TITLE[page]} onBack={() => setPage('root')}>
            {page === 'calendars' && <CalendarsPage />}
            {page === 'subjects' && <SubjectsPage />}
            {page === 'employers' && <EmployersPage />}
            {page === 'backups' && <BackupsPage />}
            {page === 'restore' && <RestorePage />}
            {page === 'notices' && <NoticesPage />}
            {page === 'transfer' && <DeviceTransferPage />}
            {page === 'notifications' && <NotificationSettings />}
          </SubPage>
        )}
      </AnimatePresence>
    </div>
  );
}

export const fmtDate = (t: number) => formatDayLabel(t);
