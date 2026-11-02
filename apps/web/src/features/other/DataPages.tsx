import { useCallback, useEffect, useState } from 'react';
import { addDays, formatHm, startOfDay } from '@my-time/domain';
import { useData, useSync } from '../../app/data';
import { useUIActions } from '../../app/ui';
import { formatFull } from '../../app/format';
import { Group } from '../../components/Controls';
import { Icon } from '../../components/Icon';
import { db } from '../../data/db';
import { api, type BackupItem, type RestoreSession } from '../../sync/api';
import { syncEngine } from '../../sync/engine';
import { SwipeRow } from '../../ui/SwipeRow';
import { Popup } from '../../ui/Popup';

function NeedsLogin() {
  const sync = useSync();
  if (sync.me) return null;
  const off = sync.phase === 'notConfigured' || sync.phase === 'unavailable';
  // 未ログインでも案内だけで止めず、ログインへの導線を出す（バックアップ・復元はまだ何も実行していない）
  return (
    <div className="empty-state" data-testid="needs-login">
      <Icon name="cloud" size={36} />
      <strong>{off ? 'この配信先では利用できません' : 'Googleでログインすると使えます'}</strong>
      <span>{off ? 'サーバーが未設定のため、データはこの端末内だけに保存されます。' : 'バックアップと復元は、ログインしたGoogleドライブを使います。まだ何も実行していません。この端末のデータはそのまま残ります。'}</span>
      {!off && <a className="gbtn-primary glass-i" href={api.loginUrl()} data-testid="needs-login-btn">Googleでログイン</a>}
    </div>
  );
}

/** 失敗理由を利用者向けの言葉にする（技術的な詳細はサーバーの記録に残す） */
function backupErrorLabel(e: string | null): string {
  if (!e) return '原因不明';
  if (/ハッシュ|件数|検証/.test(e)) return '読み戻して確認した内容が一致しませんでした（データは削除していません）';
  if (/storageQuota|quota|容量/.test(e)) return 'Googleドライブの空き容量が足りません';
  if (/401|403|invalid_grant|権限|ログイン/.test(e)) return 'Googleドライブの権限がありません。もう一度ログインしてください';
  if (/Drive|5\d\d|fetch|network/i.test(e)) return 'Googleドライブに保存できませんでした。次回自動で再試行します';
  return e.length > 60 ? `${e.slice(0, 60)}…` : e;
}

const kb = (b: number | null) => (b == null ? '' : b < 1024 ? `${b}B` : b < 1024 * 1024 ? `${(b / 1024).toFixed(1)}KB` : `${(b / 1024 / 1024).toFixed(1)}MB`);

/** バックアップ一覧と古い日次バックアップの整理。アーカイブ（削除データの保管先）と最新の検証済みは削除できない */
export function BackupsPage() {
  const sync = useSync();
  const { confirm, showToast } = useUIActions();
  const [items, setItems] = useState<BackupItem[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [drilling, setDrilling] = useState<string | null>(null);
  const [preview, setPreview] = useState<BackupItem | null>(null);
  const load = useCallback(() => {
    if (!sync.me) return;
    api.backups().then((r) => setItems(r.items)).catch((e: Error) => showToast(e.message));
  }, [sync.me, showToast]);
  useEffect(load, [load]);
  if (!sync.me) return <NeedsLogin />;
  const latestVerified = items?.find((i) => i.kind === 'daily' && i.status === 'verified')?.id;

  const run = async () => {
    setBusy(true);
    try {
      await syncEngine.syncNow();
      const r = await api.runBackup();
      showToast(r.ok ? 'バックアップを保存し、読み戻して確認しました' : `失敗しました：${r.error}`);
    } catch (e) {
      showToast(e instanceof Error ? e.message : '失敗しました');
    } finally {
      setBusy(false);
      load();
    }
  };

  /** 復元試験：Drive から読み戻して、復元したら現在のデータと一致するかを確かめる（データは変えない） */
  const drill = async (b: BackupItem) => {
    setDrilling(b.id);
    try {
      const r = await api.restoreDrill(b.id);
      const diff = r.missingNow.length + r.extraNow.length + r.changed.length;
      showToast(
        r.ok
          ? `復元試験OK：${r.matched}件すべて一致${r.kind === 'daily' ? `（設定${r.extras.settings}・操作ログ${r.extras.operationLog}・削除の印${r.extras.tombstones}件も保存済み）` : ''}`
          : `読み戻し・検証はOK。バックアップ後の変更 ${diff}件（一致 ${r.matched}件）`,
      );
    } catch (e) {
      showToast(e instanceof Error ? e.message : '復元試験に失敗しました');
    } finally {
      setDrilling(null);
    }
  };

  const remove = async (b: BackupItem) => {
    if (!(await confirm({ title: 'このバックアップを削除しますか？', message: 'Googleドライブからも削除します。', confirmLabel: '削除', destructive: true }))) return;
    try {
      await api.deleteBackup(b.id);
      load();
    } catch (e) {
      showToast(e instanceof Error ? e.message : '削除できませんでした');
    }
  };

  return (
    <>
      <Group footer={`毎日22時ごろ（日本時間）に、Googleドライブの「My Time Backup」フォルダーへ自動保存します。保存後に読み戻して件数とハッシュを確認できたものだけを成功として扱います。${sync.me.drive.connected ? '' : ' 現在ドライブの権限がありません。もう一度ログインしてください。'}`}>
        <div className="row" data-testid="retention-mode">
          <span className="row-label">30日後の期限削除</span>
          <span className={`row-value ${sync.config?.retentionMode === 'on' ? '' : 'muted'}`}>{sync.config?.retentionMode === 'on' ? '有効' : sync.config?.retentionMode === 'dry-run' ? '試運転（削除しない）' : '停止中'}</span>
        </div>
        <button type="button" className="row row-button center tint bold" disabled={busy || !sync.me.drive.connected} onClick={() => void run()} data-testid="run-backup">
          {busy ? '保存中…' : '今すぐバックアップ'}
        </button>
      </Group>
      <Group header="保存済み" footer="アーカイブは期限削除したデータの保管先なので削除できません。">
        {items == null && <div className="row"><span className="row-label muted">読み込み中…</span></div>}
        {items?.length === 0 && <div className="row"><span className="row-label muted">まだありません</span></div>}
        {items?.map((b) => {
          const counts = b.counts ? (JSON.parse(b.counts) as Record<string, number>) : {};
          return (
            <div className="row backup-row" key={b.id} data-testid="backup-row">
              <span className={`status-dot ${b.status}`} aria-label={b.status === 'verified' ? '確認済み' : b.status === 'failed' ? '失敗' : '処理中'} />
              <span className="row-label row-tap" role="button" tabIndex={0} onClick={() => setPreview(b)} onKeyDown={(e) => { if (e.key === 'Enter') setPreview(b); }} data-testid="backup-open">
                {b.kind === 'daily' ? '日次' : 'アーカイブ'} · {formatFull(b.created_at)}
                <span className="sub-label">{b.status === 'failed' ? `失敗：${backupErrorLabel(b.error)}` : `予定${counts.event ?? 0}・タスク${counts.task ?? 0} ${kb(b.bytes)}`}</span>
              </span>
              {b.status === 'verified' && (
                <button type="button" className="pill-btn small" disabled={drilling != null} onClick={() => void drill(b)} data-testid="drill-backup">
                  {drilling === b.id ? '確認中…' : '復元試験'}
                </button>
              )}
              {b.kind === 'daily' && b.id !== latestVerified && (
                <button type="button" className="icon-btn subtle" aria-label="削除" onClick={() => void remove(b)}>
                  <Icon name="trash" size={16} />
                </button>
              )}
            </div>
          );
        })}
      </Group>
      <Popup open={!!preview} title="バックアップの内容" onClose={() => setPreview(null)} testId="backup-preview">
        {preview && <BackupPreview b={preview} />}
        {preview?.status === 'verified' && (
          <div className="popup-actions">
            <button type="button" className="gpill glass glass-i" disabled={drilling != null} onClick={() => void drill(preview)}>{drilling === preview.id ? '確認中…' : '復元試験（データは変えません）'}</button>
          </div>
        )}
      </Popup>
    </>
  );
}

const ENTITY_LABEL: Record<string, string> = { event: '予定', task: 'タスク', subtask: 'サブタスク', calendar: 'カレンダー', subject: '授業の科目', employer: '勤務先', category: 'カテゴリー', studioType: 'Studioの種類', settings: '設定', operationLog: '操作ログ', tombstones: '削除の印' };

/** バックアップ履歴の中身の確認（Q58）。件数・大きさ・検証の状態だけを表示し、データは変更しない */
function BackupPreview({ b }: { b: BackupItem }) {
  const counts = b.counts ? (JSON.parse(b.counts) as Record<string, number>) : {};
  const rows = Object.entries(counts).filter(([, n]) => typeof n === 'number');
  return (
    <>
      <div className="group"><div className="group-body">
        <div className="row"><span className="row-label">種類</span><span className="row-value">{b.kind === 'daily' ? '日次バックアップ' : 'アーカイブ（期限削除の保管）'}</span></div>
        <div className="row"><span className="row-label">保存日時</span><span className="row-value">{formatFull(b.created_at)}</span></div>
        <div className="row"><span className="row-label">状態</span><span className="row-value">{b.status === 'verified' ? `読み戻し確認済み${b.verified_at ? `（${formatHm(b.verified_at)}）` : ''}` : b.status === 'failed' ? `失敗：${backupErrorLabel(b.error)}` : '処理中'}</span></div>
        {b.range_from != null && b.range_to != null && <div className="row"><span className="row-label">対象期間</span><span className="row-value">{formatFull(b.range_from)}〜{formatFull(b.range_to)}</span></div>}
        <div className="row"><span className="row-label">大きさ</span><span className="row-value">{kb(b.bytes)}</span></div>
        {b.drive_file_name && <div className="row"><span className="row-label">ファイル名</span><span className="row-value small wrap">{b.drive_file_name}</span></div>}
      </div></div>
      {rows.length > 0 && (
        <>
          <div className="group-header">含まれるデータ</div>
          <div className="group"><div className="group-body" data-testid="backup-counts">
            {rows.map(([k, n]) => <div className="row" key={k}><span className="row-label">{ENTITY_LABEL[k] ?? k}</span><span className="row-value">{n}件</span></div>)}
          </div></div>
        </>
      )}
    </>
  );
}

const toDateInput = (t: number) => {
  const d = new Date(t);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
};
const fromDateInput = (v: string) => {
  const [y, m, d] = v.split('-').map(Number);
  return new Date(y!, m! - 1, d!).getTime();
};

/** 30日を過ぎて削除したデータを期間指定で Drive から戻し、通常のカレンダーに表示。「閲覧を終了」で再び外す */
export function RestorePage() {
  const sync = useSync();
  const { showToast, confirm } = useUIActions();
  const [from, setFrom] = useState(toDateInput(Date.now() - 60 * 86_400_000));
  const [to, setTo] = useState(toDateInput(Date.now() - 30 * 86_400_000));
  const [sessions, setSessions] = useState<RestoreSession[]>([]);
  const [busy, setBusy] = useState(false);
  const load = useCallback(() => {
    if (sync.me) api.restoreSessions().then((r) => setSessions(r.items)).catch(() => undefined);
  }, [sync.me]);
  useEffect(load, [load]);
  if (!sync.me) return <NeedsLogin />;

  const restore = async () => {
    const f = fromDateInput(from);
    const t = fromDateInput(to) + 86_400_000;
    if (t <= f) return showToast('期間が正しくありません');
    setBusy(true);
    try {
      const r = await api.restore(f, t);
      await syncEngine.syncNow();
      showToast(r.restored ? `${r.restored}件を表示しました。カレンダーで確認できます` : 'この期間に保管されたデータはありません');
      load();
    } catch (e) {
      showToast(e instanceof Error ? e.message : '復元できませんでした');
    } finally {
      setBusy(false);
    }
  };

  const end = async (s: RestoreSession) => {
    if (!(await confirm({ title: '閲覧を終了しますか？', message: '戻したデータを通常の画面から外します。Googleドライブの保管データはそのまま残ります。', confirmLabel: '閲覧を終了' }))) return;
    await api.endRestore(s.id);
    await syncEngine.syncNow();
    load();
  };

  return (
    <>
      <Group footer="Googleドライブのアーカイブを確認してから、通常のカレンダー・タスクに一時的に表示します。「閲覧を終了」を押すまでは自動で削除されません。">
        <div className="row">
          <label className="row-label" htmlFor="rs-from">開始日</label>
          <input id="rs-from" type="date" className="dt-input" value={from} onChange={(e) => setFrom(e.target.value)} data-testid="restore-from" />
        </div>
        <div className="row">
          <label className="row-label" htmlFor="rs-to">終了日</label>
          <input id="rs-to" type="date" className="dt-input" value={to} onChange={(e) => setTo(e.target.value)} data-testid="restore-to" />
        </div>
        <button type="button" className="row row-button center tint bold" disabled={busy} onClick={() => void restore()} data-testid="run-restore">{busy ? '確認中…' : '復元して表示'}</button>
      </Group>
      {sessions.length > 0 && (
        <Group header="表示中の過去データ">
          {sessions.map((s) => (
            <div className="row" key={s.id} data-testid="restore-session">
              <span className="row-label">
                {formatFull(s.range_from).split(' ')[0]}〜{formatFull(s.range_to - 1).split(' ')[0]}
                <span className="sub-label">{s.restored_count}件</span>
              </span>
              <button type="button" className="pill-btn small" onClick={() => void end(s)} data-testid="end-restore">閲覧を終了</button>
            </div>
          ))}
        </Group>
      )}
    </>
  );
}

/** お知らせ（同期・バックアップの失敗、容量不足、権限など）。同じ内容は1件にまとめて表示 */
export function NoticesPage() {
  const sync = useSync();
  const { localNotices } = useData();
  const { showToast } = useUIActions();
  // 開いた時点で未読だったもの（既読処理の後も、この画面を見ている間は青い点を残す）
  const [unread] = useState(() => new Set(sync.notices.filter((n) => !n.read_at).map((n) => n.id)));
  const [hidden, setHidden] = useState<Set<string>>(() => new Set());
  const items = [
    ...localNotices.map((n) => ({ id: `l-${n.key}`, level: n.level, title: n.title, body: n.body, at: n.createdAt, resolved: n.resolvedAt != null, local: n.key as string | null })),
    ...sync.notices.map((n) => ({ id: n.id, level: n.level, title: n.title, body: n.body, at: n.created_at, resolved: n.resolved_at != null, local: null as string | null })),
  ].filter((n) => !hidden.has(n.id)).sort((a, b) => Number(a.resolved) - Number(b.resolved) || b.at - a.at);
  useEffect(() => {
    for (const n of sync.notices) if (!n.read_at) void api.readNotice(n.id).catch(() => undefined);
  }, [sync.notices]);
  const today = startOfDay(Date.now());
  const groups: [string, typeof items][] = [
    ['今日', items.filter((n) => n.at >= today)],
    ['昨日', items.filter((n) => n.at < today && n.at >= addDays(today, -1))],
    ['それ以前', items.filter((n) => n.at < addDays(today, -1))],
  ];
  const canDelete = (n: (typeof items)[number]) => n.resolved || n.level === 'info';
  const remove = async (n: (typeof items)[number]) => {
    setHidden((h) => new Set(h).add(n.id));
    try {
      if (n.local) await db.notices.delete(n.local);
      else await api.deleteNotice(n.id);
    } catch {
      setHidden((h) => { const x = new Set(h); x.delete(n.id); return x; });
      showToast('削除できませんでした（オンラインで再度お試しください）');
    }
  };
  if (items.length === 0) return <div className="empty-state" data-testid="notices-empty"><Icon name="tray" size={36} /><strong>お知らせはありません</strong><span>同期・バックアップの結果や、対応が必要なことをここでお知らせします。</span></div>;
  return (
    <>
      {groups.filter(([, xs]) => xs.length).map(([label, xs]) => (
        <div key={label} data-testid={`notice-group-${label}`}>
          <div className="group-header">{label}</div>
          <div className="group"><div className="group-body">
            {xs.map((n) => {
              const row = (
                <div className={`notice-row ${n.resolved ? 'resolved' : ''}`} data-testid="notice-row">
                  <span className={`notice-icon ${n.level}`} aria-hidden><Icon name={n.level === 'info' ? 'info' : 'warning'} size={16} strokeWidth={2.2} /></span>
                  <div className="notice-text">
                    <div className="notice-title">{unread.has(n.id) && <span className="unread-dot" aria-label="未読" />}{n.title}{n.resolved && <span className="sub-label"> · 解決済み</span>}</div>
                    <div className="notice-body">{n.body}</div>
                    <div className="notice-time">{label === 'それ以前' ? formatFull(n.at) : formatHm(n.at)}</div>
                  </div>
                  {canDelete(n) && <button type="button" className="icon-btn subtle" aria-label={`「${n.title}」を削除`} onClick={() => void remove(n)}><Icon name="close" size={14} /></button>}
                </div>
              );
              return canDelete(n) ? <SwipeRow key={n.id} testId={`notice-swipe-${n.id}`} right={[{ label: '削除', icon: 'trash', color: 'red', onAct: () => void remove(n) }]}>{row}</SwipeRow> : <div key={n.id}>{row}</div>;
            })}
          </div></div>
        </div>
      ))}
      <p className="note-text">解決済みとお知らせ（青）は左へスワイプで削除できます。対応が必要な警告は、解決すると消せるようになります。{sync.lastSuccessAt ? ` 最終同期 ${formatHm(sync.lastSuccessAt)}` : ''}</p>
    </>
  );
}
