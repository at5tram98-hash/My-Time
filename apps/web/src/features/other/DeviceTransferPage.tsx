import { useRef, useState } from 'react';
import { Group } from '../../components/Controls';
import { useUI } from '../../app/ui';
import { db, ownerOf } from '../../data/db';
import { exportDevice, importDevice, readDevice } from '../../data/transfer';
import { syncEngine } from '../../sync/engine';

export function DeviceTransferPage() {
  const { confirm, showToast } = useUI();
  const input = useRef<HTMLInputElement>(null);
  const [busy, setBusy] = useState(false);
  const [file, setFile] = useState<{ text: string; count: number; owner: string | null } | null>(null);
  const [error, setError] = useState('');
  const download = async () => {
    setBusy(true);
    try {
      const text = await exportDevice(db, location.origin);
      const url = URL.createObjectURL(new Blob([text], { type: 'application/json' }));
      const a = document.createElement('a');
      a.href = url;
      a.download = `MyTime-device-${new Date().toISOString().slice(0, 10)}.json`;
      a.click();
      setTimeout(() => URL.revokeObjectURL(url), 60_000);
      showToast('移行ファイルを作成しました。ファイルに保存してください');
    } catch (e) { setError(e instanceof Error ? e.message : '書き出せませんでした'); }
    finally { setBusy(false); }
  };
  const select = async (f?: File) => {
    setFile(null); setError('');
    if (!f) return;
    try {
      if (f.size > 50 * 1024 * 1024) throw new Error('移行ファイルは50MB以内にしてください');
      const text = await f.text();
      const parsed = await readDevice(text);
      const count = ['tasks', 'events', 'subtasks', 'calendars', 'subjects', 'employers'].reduce((n, k) => n + (parsed.body.tables[k]?.length ?? 0), 0);
      setFile({ text, count, owner: parsed.body.owner });
    } catch (e) { setError(e instanceof Error ? e.message : '読めませんでした'); }
  };
  const restore = async () => {
    if (!file) return;
    if (file.owner !== ownerOf(db.name)) { setError(file.owner ? '元と同じGoogleアカウントでログインしてください' : 'ログアウトしてから取り込んでください'); return; }
    const destination = syncEngine.snapshot.me?.user.email ?? 'この端末（ログインなし）';
    if (!await confirm({ title: 'データを取り込みますか？', message: `${file.count}件を「${destination}」に取り込みます。同じIDの内容が異なる場合は中止し、元のデータは削除しません。`, confirmLabel: '取り込む' })) return;
    setBusy(true);
    try {
      const n = await importDevice(db, file.text);
      setFile(null);
      showToast(`${n}件を取り込みました`);
      await syncEngine.syncNow();
    } catch (e) { setError(e instanceof Error ? e.message : '取り込めませんでした'); }
    finally { setBusy(false); }
  };
  return <>
    <Group header="端末データの移行" footer="GitHub Pages版で書き出してファイルに保存し、Cloudflare版で同じファイルを選択してください。元のデータは残ります。アカウントのデータは同じGoogleアカウントにだけ取り込めます。">
      <button type="button" className="row row-button center tint" disabled={busy} onClick={() => void download()} data-testid="export-device">移行ファイルを書き出す</button>
      <button type="button" className="row row-button center tint" disabled={busy} onClick={() => input.current?.click()}>移行ファイルを選ぶ</button>
      <input ref={input} hidden aria-label="移行ファイル" type="file" accept=".json,application/json" disabled={busy} onChange={(e) => void select(e.target.files?.[0])} />
      {file && <button type="button" className="row row-button center tint" disabled={busy} onClick={() => void restore()} data-testid="import-device">{file.count}件を取り込む</button>}
      {error && <div className="row" role="alert">{error}</div>}
    </Group>
    <p className="section-footer">移行ファイルには予定・メモ・設定・操作ログ・同期前の変更・競合時の退避データが含まれます。安全な場所に保管してください。Googleの認証情報は含みません。</p>
  </>;
}
