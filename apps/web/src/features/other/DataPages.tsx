import { useCallback, useEffect, useState } from 'react';
import { formatHm } from '@my-time/domain';
import { useData, useSync } from '../../app/data';
import { useUI } from '../../app/ui';
import { formatFull } from '../../app/format';
import { Group } from '../../components/Controls';
import { Icon } from '../../components/Icon';
import { db } from '../../data/db';
import { api, type BackupItem, type RestoreSession } from '../../sync/api';
import { syncEngine } from '../../sync/engine';

function NeedsLogin() {
  const sync = useSync();
  if (sync.me) return null;
  return (
    <Group>
      <div className="row"><span className="row-label muted">{sync.phase === 'notConfigured' || sync.phase === 'unavailable' ? 'サーバーが未設定のため利用できません。' : 'Googleでログインすると利用できます。'}</span></div>
    </Group>
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
  const { confirm, showToast } = useUI();
  const [items, setItems] = useState<BackupItem[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [drilling, setDrilling] = useState<string | null>(null);
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
              <span className="row-label">
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
  const { showToast, confirm } = useUI();
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
  const items = [
    ...localNotices.map((n) => ({ id: `l-${n.key}`, level: n.level, title: n.title, body: n.body, at: n.createdAt, resolved: n.resolvedAt != null, local: n.key })),
    ...sync.notices.map((n) => ({ id: n.id, level: n.level, title: n.title, body: n.body, at: n.created_at, resolved: n.resolved_at != null, local: null as string | null })),
  ].sort((a, b) => Number(a.resolved) - Number(b.resolved) || b.at - a.at);
  useEffect(() => {
    for (const n of sync.notices) if (!n.read_at) void api.readNotice(n.id).catch(() => undefined);
  }, [sync.notices]);
  return (
    <Group>
      {items.length === 0 && <div className="row"><span className="row-label muted">お知らせはありません</span></div>}
      {items.map((n) => (
        <div className={`notice-row ${n.resolved ? 'resolved' : ''}`} key={n.id} data-testid="notice-row">
          <span className={`notice-icon ${n.level}`} aria-hidden>{n.level === 'error' ? '!' : n.level === 'warn' ? '!' : 'i'}</span>
          <div className="notice-text">
            <div className="notice-title">{n.title}{n.resolved && <span className="sub-label"> · 解決済み</span>}</div>
            <div className="notice-body">{n.body}</div>
            <div className="notice-time">{formatFull(n.at)}</div>
          </div>
          {n.local && n.resolved && (
            <button type="button" className="icon-btn subtle" aria-label="消去" onClick={() => void db.notices.delete(n.local!)}>
              <Icon name="close" size={14} />
            </button>
          )}
        </div>
      ))}
      {sync.lastSuccessAt && <div className="group-footer">最終同期 {formatHm(sync.lastSuccessAt)}</div>}
    </Group>
  );
}
