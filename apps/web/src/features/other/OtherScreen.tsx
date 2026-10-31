import { useLiveQuery } from 'dexie-react-hooks';
import { useData } from '../../app/data';
import { Group } from '../../components/Controls';
import { Icon, type IconName } from '../../components/Icon';
import { MenuButton } from '../../components/Menu';
import { db, type TextSizePref, type ThemePref } from '../../data/db';
import { repo } from '../../data/repo';

const THEME_LABEL: Record<ThemePref, string> = { system: 'システムに合わせる', light: 'ライト', dark: 'ダーク' };
const SIZE_LABEL: Record<TextSizePref, string> = { system: 'システムに合わせる', small: '小', large: '大', xlarge: '特大' };

function SettingIcon({ name, color }: { name: IconName; color: string }) {
  return (
    <span className="set-icon" style={{ background: color }} aria-hidden>
      <Icon name={name} size={18} strokeWidth={2.1} />
    </span>
  );
}

export function OtherScreen() {
  const { settings, calendars, tasks, events, outboxPending } = useData();
  const logCount = useLiveQuery(() => db.operationLog.count(), []) ?? 0;

  return (
    <div className="screen other" data-testid="other-screen">
      <header className="nav large">
        <div className="nav-row"><h1 className="large-title">その他</h1></div>
      </header>
      <div className="scroll-body">
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
        </Group>

        <Group header="カレンダー" footer="カレンダーの追加・色・並び替え、授業/アルバイトのテンプレートは Phase 2 で追加します。">
          {calendars.map((c) => (
            <div className="row" key={c.id}>
              <span className="cal-dot big" style={{ background: c.color }} />
              <span className="row-label">{c.name}</span>
              <span className="row-value muted">{c.kind === 'class' ? '授業' : c.kind === 'job' ? 'アルバイト' : '一般'}</span>
            </div>
          ))}
        </Group>

        <Group header="アカウントと同期" footer="Phase 1 ではデータはこの端末内（IndexedDB）だけに保存されます。クラウド同期・Googleドライブへのバックアップはまだ動作しません。">
          <div className="row">
            <SettingIcon name="person" color="#8E8E93" />
            <span className="row-label">Googleアカウント</span>
            <span className="row-value muted">未設定（準備中）</span>
          </div>
          <div className="row">
            <SettingIcon name="cloud" color="#34C759" />
            <span className="row-label">同期</span>
            <span className="row-value muted" data-testid="sync-status">未接続 · 未同期 {outboxPending}件</span>
          </div>
          <div className="row">
            <SettingIcon name="stack" color="#FF9500" />
            <span className="row-label">Driveバックアップ</span>
            <span className="row-value muted">準備中</span>
          </div>
        </Group>

        <Group header="この端末のデータ">
          <div className="row"><span className="row-label">タスク</span><span className="row-value" data-testid="count-tasks">{tasks.length}件</span></div>
          <div className="row"><span className="row-label">予定</span><span className="row-value">{events.length}件</span></div>
          <div className="row"><span className="row-label">操作ログ</span><span className="row-value">{logCount}件</span></div>
        </Group>

        <Group header="お知らせ">
          <div className="row">
            <SettingIcon name="bell" color="#FF3B30" />
            <span className="row-label">お知らせはありません</span>
          </div>
        </Group>

        <Group header="このアプリについて">
          <div className="row"><span className="row-label">バージョン</span><span className="row-value muted">0.1.0（Phase 1）</span></div>
          <div className="row"><span className="row-label">自動削除</span><span className="row-value muted">無効（バックアップ検証後に有効化）</span></div>
        </Group>
      </div>
    </div>
  );
}
