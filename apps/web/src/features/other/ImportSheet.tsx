import { useId, useMemo, useState } from 'react';
import { classifyImport, formatDayLabel, formatHm, parseICS, parseText, type ImportCandidate, type ImportClass } from '@my-time/domain';
import { Sheet } from '../../components/Sheet';
import { Segmented } from '../../components/Controls';
import { useData } from '../../app/data';
import { useUIActions } from '../../app/ui';
import { fromLocalInput, toLocalInput } from '../../app/format';
import { repo } from '../../data/repo';
import { Icon } from '../../components/Icon';

type Choice = 'import' | 'edit' | 'skip';

/**
 * TimeTree などからの取り込み。TimeTree の公式APIは提供終了しているため、
 * 書き出したカレンダー（.ics）またはテキストの貼り付けから取り込む（非公式な認証回避はしない）。
 * 1件ずつ「取り込む / 編集 / スキップ」を選ぶ。同じ予定は取り込み元を優先して更新し、無関係な予定は上書きしない。
 */
export function ImportSheet({ depth }: { depth: number }) {
  const { events, calendars } = useData();
  const { closeSheet, showToast } = useUIActions();
  const fid = useId();
  const [mode, setMode] = useState<'text' | 'ics'>('text');
  const [text, setText] = useState('');
  const [owner, setOwner] = useState<'me' | 'partner'>('partner');
  const [calendarId, setCalendarId] = useState(calendars[0]?.id ?? 'cal-general');
  const [items, setItems] = useState<{ c: ImportCandidate; cls: ImportClass; choice: Choice }[] | null>(null);
  const [errors, setErrors] = useState<{ line: number; text: string }[]>([]);

  const analyze = (src: string, kind: 'text' | 'ics') => {
    const parsed = kind === 'ics' ? { items: parseICS(src, owner), errors: [] } : parseText(src, Date.now());
    setErrors(parsed.errors);
    setItems(parsed.items.map((c) => ({ c, cls: classifyImport(c, events), choice: 'import' as Choice })));
  };

  const onFile = async (f: File | undefined) => {
    if (!f) return;
    if (f.size > 2_000_000) return showToast('ファイルが大きすぎます（2MBまで）');
    const t = await f.text();
    setText(t);
    analyze(t, 'ics');
  };

  const counts = useMemo(() => ({ go: items?.filter((i) => i.choice !== 'skip').length ?? 0 }), [items]);

  const apply = async () => {
    if (!items) return;
    let n = 0;
    for (const it of items) {
      if (it.choice === 'skip') continue;
      const c = { ...it.c, owner: mode === 'ics' ? owner : it.c.owner };
      await repo.importEvent(c, calendarId, mode === 'ics' ? 'ics' : 'text', it.cls.kind === 'same' ? it.cls.existing.id : null);
      n += 1;
    }
    showToast(`${n}件を取り込みました`);
    closeSheet();
  };

  return (
    <Sheet
      onClose={closeSheet}
      depth={depth}
      title="予定の取り込み"
      left={<button type="button" className="bar-btn" onClick={closeSheet}>キャンセル</button>}
      right={items ? <button type="button" className="bar-btn bold" disabled={!counts.go} onClick={() => void apply()} data-testid="apply-import">{counts.go}件を取り込む</button> : undefined}
    >
      {!items ? (
        <>
          <div className="form-center">
            <Segmented label="取り込み方法" value={mode} onChange={setMode} options={[{ value: 'text', label: 'テキスト' }, { value: 'ics', label: 'カレンダーファイル' }]} />
          </div>
          <div className="group">
            <div className="group-body">
              <div className="row">
                <label className="row-label" htmlFor={`${fid}-cal`}>追加先</label>
                <select id={`${fid}-cal`} className="select-input" value={calendarId} onChange={(e) => setCalendarId(e.target.value)}>
                  {calendars.map((c) => (
                    <option key={c.id} value={c.id}>{c.name}</option>
                  ))}
                </select>
              </div>
              {mode === 'ics' && (
                <div className="row">
                  <span className="row-label">だれの予定</span>
                  <Segmented label="だれの予定" value={owner} onChange={setOwner} options={[{ value: 'me', label: '自分' }, { value: 'partner', label: '相手' }]} />
                </div>
              )}
            </div>
          </div>
          {mode === 'text' ? (
            <div className="group">
              <div className="group-body">
                <textarea className="row-input notes-input tall" value={text} onChange={(e) => setText(e.target.value)} placeholder={'10/14 18:00-20:00 ごはん @相手\n2026/10/20 22:00-6:00 夜勤'} aria-label="取り込むテキスト" data-testid="import-text" />
              </div>
              <div className="group-footer">1行に1件。「@相手」を付けると相手の予定として取り込みます。日付をまたぐ時間も書けます。</div>
            </div>
          ) : (
            <div className="group">
              <div className="group-body padded">
                <input type="file" accept=".ics,text/calendar" onChange={(e) => void onFile(e.target.files?.[0])} aria-label="カレンダーファイル" data-testid="import-file" />
              </div>
              <div className="group-footer">TimeTree・Googleカレンダーなどから書き出した .ics ファイルを選びます。予定名・日時・カレンダー名だけを取り込みます。</div>
            </div>
          )}
          {mode === 'text' && (
            <div className="group">
              <div className="group-body">
                <button type="button" className="row row-button center" disabled={!text.trim()} onClick={() => analyze(text, 'text')} data-testid="analyze-import">
                  内容を確認
                </button>
              </div>
            </div>
          )}
        </>
      ) : (
        <>
          {errors.length > 0 && <p className="form-error">読み取れなかった行：{errors.map((e) => e.line).join('、')}行目</p>}
          <div className="import-list" data-testid="import-list">
            {items.map((it, i) => (
              <div className={`import-item ${it.choice}`} key={i} data-testid="import-item">
                <div className="import-head">
                  <span className="owner" aria-label={it.c.owner === 'partner' ? '相手の予定' : '自分の予定'}><Icon name={it.c.owner === 'partner' ? 'people' : 'person'} size={18} /></span>
                  {it.choice === 'edit' ? (
                    <input className="row-input" value={it.c.title} aria-label="予定名" onChange={(e) => setItems((l) => l!.map((x, j) => (j === i ? { ...x, c: { ...x.c, title: e.target.value } } : x)))} />
                  ) : (
                    <span className="import-title">{it.c.title}</span>
                  )}
                </div>
                {it.choice === 'edit' ? (
                  <div className="row">
                    <input type="datetime-local" className="dt-input" value={toLocalInput(it.c.start)} aria-label="開始" onChange={(e) => setItems((l) => l!.map((x, j) => (j === i ? { ...x, c: { ...x.c, start: fromLocalInput(e.target.value) ?? x.c.start } } : x)))} />
                    <input type="datetime-local" className="dt-input" value={toLocalInput(it.c.end)} aria-label="終了" onChange={(e) => setItems((l) => l!.map((x, j) => (j === i ? { ...x, c: { ...x.c, end: fromLocalInput(e.target.value) ?? x.c.end } } : x)))} />
                  </div>
                ) : (
                  <div className="import-time">{formatDayLabel(it.c.start)} {formatHm(it.c.start)}〜{formatHm(it.c.end)}</div>
                )}
                {it.cls.kind === 'same' && <div className="import-note same">取り込み済みの同じ予定{it.cls.changed ? 'があります（取り込み元の内容で更新）' : 'です（変更なし）'}</div>}
                {it.cls.kind === 'overlap' && <div className="import-note warn">「{it.cls.with[0]!.title}」と時間が重なります（既存の予定は変更しません）</div>}
                <Segmented
                  label={`${it.c.title}の扱い`}
                  value={it.choice}
                  onChange={(v) => setItems((l) => l!.map((x, j) => (j === i ? { ...x, choice: v } : x)))}
                  options={[{ value: 'import', label: it.cls.kind === 'same' ? '更新' : '取り込む' }, { value: 'edit', label: '編集' }, { value: 'skip', label: 'スキップ' }]}
                />
              </div>
            ))}
          </div>
        </>
      )}
    </Sheet>
  );
}
