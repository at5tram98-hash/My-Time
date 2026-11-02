import { useRef, useState, type ReactNode } from 'react';
import { AnimatePresence, motion, useMotionValue, useReducedMotion } from 'motion/react';
import { useLiveQuery } from 'dexie-react-hooks';
import { formatDayLabel, formatHm } from '@my-time/domain';
import { useAttention, useData, useSync } from '../../app/data';
import { useUIActions } from '../../app/ui';
import { Group } from '../../components/Controls';
import { Icon, type IconName } from '../../components/Icon';
import { db, type TextSizePref, type ThemePref } from '../../data/db';
import { repo } from '../../data/repo';
import { api, APP_HOME, NO_API_HOST } from '../../sync/api';
import { syncEngine } from '../../sync/engine';
import { CalendarsPage, EmployersPage, SubjectsPage } from './ManagePages';
import { BackupsPage, NoticesPage, RestorePage } from './DataPages';
import { DeviceTransferPage } from './DeviceTransferPage';
import { NotificationSettings } from './NotificationSettings';
import { LimitsPage } from './LimitsPage';
import { AdvancedPage, CategoriesPage, TimeTreePage } from './MorePages';
import { StudioPage } from '../studio/StudioPage';
import { useEdgeSwipeBack } from '../../ui/gestures';

const THEME_LABEL: Record<ThemePref, string> = { system: 'システムに合わせる', light: 'ライト', dark: 'ダーク' };
const SIZE_LABEL: Record<TextSizePref, string> = { system: 'システムに合わせる', small: '小', large: '大', xlarge: '特大' };

export type OtherPage = 'root' | 'calendars' | 'subjects' | 'employers' | 'backups' | 'restore' | 'notices' | 'notifications' | 'transfer' | 'limits' | 'categories' | 'studio' | 'timetree' | 'advanced' | 'appearance' | 'textsize';

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
  limits: '使える範囲と制限',
  categories: 'タスクの種類とカテゴリー',
  studio: 'Create Studio',
  timetree: 'TimeTree の読み込み',
  advanced: '詳細設定',
  appearance: '外観',
  textsize: '文字サイズ',
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
  const ref = useRef<HTMLDivElement>(null);
  const x = useMotionValue(0);
  // 左端から右へスワイプで戻る（Q98）。指に追従し、離した位置で戻るか決める
  useEdgeSwipeBack(ref, onBack, (p) => x.set(p * (ref.current?.clientWidth ?? 0)));
  return (
    <motion.div ref={ref} className="subpage" style={{ translateX: x }} initial={reduce ? { opacity: 0 } : { x: '100%' }} animate={reduce ? { opacity: 1 } : { x: 0 }} exit={reduce ? { opacity: 0 } : { x: '100%' }} transition={reduce ? { duration: 0.12 } : { type: 'spring', stiffness: 420, damping: 42 }}>
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
  const { settings, outboxPending } = useData();
  const { openSheet, confirm } = useUIActions();
  const sync = useSync();
  const attention = useAttention();
  const [page, setPage] = useState<OtherPage>('root');
  const logCount = useLiveQuery(() => db.operationLog.count(), []) ?? 0;
  const loggedIn = Boolean(sync.me);

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
      <div className="scroll-body other-body">
        {/* アカウント（Q52・Q57）：状態はカードで、細かい項目はリストで */}
        <section className="status-card" data-testid="account-row">
          <span className="avatar" aria-hidden><Icon name="person" size={26} /></span>
          <div className="status-main">
            <div className="status-title">{loggedIn ? sync.me!.user.email : 'Googleアカウント'}</div>
            <button type="button" className={`sync-chip ${sync.phase === 'error' ? 'err' : ''}`} onClick={() => openSheet({ kind: 'syncStatus' })} data-testid="sync-row">
              <Icon name={sync.phase === 'error' ? 'warning' : 'cloud'} size={14} strokeWidth={2.2} />
              <span data-testid="sync-status">{syncLabel(sync, outboxPending)}</span>
            </button>
            <div className="muted small" data-testid="data-area">{area ? (loggedIn ? 'このアカウントのデータを表示中' : 'アカウントのデータ（再ログインが必要）') : 'この端末のデータを表示中（ログインなし）'}</div>
          </div>
          {loggedIn ? (
            <button type="button" className="gpill glass glass-i danger" onClick={() => void logout()} data-testid="logout">ログアウト</button>
          ) : sync.phase === 'notConfigured' || (sync.phase === 'unavailable' && !NO_API_HOST) ? (
            <span className="muted small">未設定</span>
          ) : (
            <a className="gbtn-primary glass-i" href={api.loginUrl()} data-testid="login">ログイン</a>
          )}
        </section>
        {sync.phase === 'unavailable' && (NO_API_HOST
          ? <p className="note-text" data-testid="pages-note">このページ（GitHub Pages）にはサーバーがないため、ここではログインできません。「ログイン」を押すと本体アプリ（{APP_HOME.replace('https://', '').replace(/\/$/, '')}）でログインします。iPhone のホーム画面には本体アプリの方を追加してください。</p>
          : <p className="note-text">この配信先にはサーバーがないため、データはこの端末内だけに保存されます。</p>)}

        <Group header="カレンダーとタスクの管理">
          <NavRow icon="calendar" color="#FF3B30" label="カレンダー" onClick={() => setPage('calendars')} testId="nav-calendars" />
          <NavRow icon="tray" color="#A2845E" label="タスクの種類とカテゴリー" onClick={() => setPage('categories')} testId="nav-categories" />
          <NavRow icon="sparkles" color="#BF5AF2" label="Create Studio" value="自分専用の種類" onClick={() => setPage('studio')} testId="nav-studio" />
          <NavRow icon="graduation" color="#5E5CE6" label="授業の科目" onClick={() => setPage('subjects')} testId="nav-subjects" />
          <NavRow icon="briefcase" color="#FF9F0A" label="勤務先" onClick={() => setPage('employers')} testId="nav-employers" />
        </Group>

        <Group header="通知と外観">
          <NavRow icon="bell" color="#FF2D55" label="通知" onClick={() => setPage('notifications')} testId="nav-notifications" />
          <NavRow icon="tray" color="#FF3B30" label="お知らせ" badge={attention} onClick={() => setPage('notices')} testId="nav-notices" />
          {/* 設定は一覧から直接変えず、詳細画面に入って選ぶ（C35） */}
          <NavRow icon="paint" color="#5856D6" label="外観" value={THEME_LABEL[settings.theme]} onClick={() => setPage('appearance')} testId="nav-appearance" />
          <NavRow icon="textsize" color="#007AFF" label="文字サイズ" value={SIZE_LABEL[settings.textSize]} onClick={() => setPage('textsize')} testId="nav-textsize" />
        </Group>

        <Group header="データとバックアップ" footer={`30日後の期限削除：${sync.config?.retentionMode === 'on' ? '有効' : sync.config?.retentionMode === 'dry-run' ? '試運転（削除しない）' : '停止中（自動では削除しません）'}`}>
          <NavRow icon="cloud" color="#FF9500" label="Driveバックアップ" value={loggedIn ? (sync.me!.drive.connected ? '毎日22時' : '未接続') : '—'} onClick={() => setPage('backups')} testId="nav-backups" />
          <NavRow icon="undo" color="#5856D6" label="期間指定の復元" onClick={() => setPage('restore')} testId="nav-restore" />
          <NavRow icon="stack" color="#30B0C7" label="データの移行" onClick={() => setPage('transfer')} testId="nav-transfer" />
          <NavRow icon="link" color="#34C759" label="予定の取り込み（TimeTreeなど）" onClick={() => openSheet({ kind: 'import' })} testId="nav-import" />
          <NavRow icon="calendar" color="#34C759" label="TimeTree の読み込み設定" onClick={() => setPage('timetree')} testId="nav-timetree" />
        </Group>

        <Group header="詳細設定">
          <NavRow icon="chart" color="#8E8E93" label="分析・入力・端末のデータ" onClick={() => setPage('advanced')} testId="nav-advanced" />
        </Group>

        <Group header="ヘルプとアプリ情報">
          <NavRow icon="info" color="#8E8E93" label="使える範囲と制限" onClick={() => setPage('limits')} testId="nav-limits" />
          <button type="button" className="row row-button" onClick={() => void repo.updateSettings({ onboarded: false })}>
            <SettingIcon name="play" color="#0A84FF" />
            <span className="row-label">はじめの設定をもう一度見る</span>
          </button>
          <div className="row"><SettingIcon name="info" color="#C7C7CC" /><span className="row-label">バージョン</span><span className="row-value muted">0.4.0</span></div>
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
            {page === 'limits' && <LimitsPage />}
            {page === 'categories' && <CategoriesPage />}
            {page === 'studio' && <StudioPage />}
            {page === 'timetree' && <TimeTreePage />}
            {page === 'advanced' && <AdvancedPage logCount={logCount} />}
            {page === 'appearance' && <ChoicePage label="外観" value={settings.theme} options={(Object.keys(THEME_LABEL) as ThemePref[]).map((k) => ({ value: k, label: THEME_LABEL[k] }))} onPick={(k) => void repo.updateSettings({ theme: k })} preview={<AppearancePreview />} footer="システムに合わせると、iPhone の設定（ライト／ダーク）に従います。" testId="theme" />}
            {page === 'textsize' && <ChoicePage label="文字サイズ" value={settings.textSize} options={(Object.keys(SIZE_LABEL) as TextSizePref[]).map((k) => ({ value: k, label: SIZE_LABEL[k] }))} onPick={(k) => void repo.updateSettings({ textSize: k })} preview={<p className="text-preview">今日のタスク・財政学レポート 10:00〜12:00</p>} footer="システムに合わせると、iPhone の「さらに大きな文字」の設定に従います。" testId="size" />}
          </SubPage>
        )}
      </AnimatePresence>
    </div>
  );
}

export const fmtDate = (t: number) => formatDayLabel(t);

/** 選ぶだけの設定の詳細画面（C35）。選んだ時点で保存し、戻ると一覧の要約に反映 */
function ChoicePage<T extends string>({ label, value, options, onPick, preview, footer, testId }: { label: string; value: T; options: { value: T; label: string }[]; onPick: (v: T) => void; preview?: ReactNode; footer?: string; testId: string }) {
  return (
    <>
      {preview && <div className="setting-preview" aria-hidden>{preview}</div>}
      <Group footer={footer}>
        <div role="radiogroup" aria-label={label}>
          {options.map((o) => (
            <button key={o.value} type="button" role="radio" aria-checked={value === o.value} className="row row-button" onClick={() => onPick(o.value)} data-testid={`${testId}-${o.value}`}>
              <span className="row-label">{o.label}</span>
              {value === o.value && <Icon name="check" size={18} strokeWidth={2.6} className="tint" />}
            </button>
          ))}
        </div>
      </Group>
    </>
  );
}

function AppearancePreview() {
  return (
    <div className="ap-prev">
      <div className="ap-card light"><span className="ap-bar" /><span className="ap-line" /><span className="ap-line short" /><span className="ap-name">ライト</span></div>
      <div className="ap-card dark"><span className="ap-bar" /><span className="ap-line" /><span className="ap-line short" /><span className="ap-name">ダーク</span></div>
    </div>
  );
}
