import { useEffect, useMemo, useRef, useState } from 'react';
import { newId, resolveItemIcon, searchParts, studioImpact, STUDIO_PARTS, UNITS, unitLabel, type StudioField, type StudioType } from '@my-time/domain';
import { useData } from '../../app/data';
import { useUIActions } from '../../app/ui';
import { Group, Toggle } from '../../components/Controls';
import { Icon } from '../../components/Icon';
import { repo } from '../../data/repo';
import { Popup } from '../../ui/Popup';
import { openContextMenu } from '../../ui/ContextMenu';
import { useLongPress } from '../../ui/gestures';
import { ColorStrip, IconStrip } from '../editor/pickers';
import { StudioFieldsForm } from './StudioFieldsForm';

const TYPE_LABEL = Object.fromEntries(STUDIO_PARTS.map((p) => [p.type, p.label])) as Record<StudioField['type'], string>;

function blank(target: 'calendar' | 'task'): StudioType {
  const now = Date.now();
  // 空白から作る（テンプレート・固定項目を自動で入れない：Q83）
  return { id: newId(), target, name: '', icon: target === 'task' ? 'star' : 'calendar', color: '#BF5AF2', status: 'draft', version: 1, revisions: [], sections: [{ id: newId(), title: '基本' }], fields: [], progress: { mode: 'none', fieldId: null, target: null }, createdAt: now, updatedAt: now };
}

/** Create Studio（Q54・Q82〜91）：自分専用のカレンダー・タスクの種類を空白から作る */
export function StudioPage() {
  const { studioTypes, tasks, events } = useData();
  const { confirm, showToast } = useUIActions();
  const [edit, setEdit] = useState<{ type: StudioType; isNew: boolean } | null>(null);
  const usage = (id: string) => tasks.filter((t) => t.extra?.studio?.typeId === id).length + events.filter((e) => e.extra?.studio?.typeId === id).length;

  const duplicate = async (t: StudioType) => {
    const now = Date.now();
    await repo.saveStudioType({ ...t, id: newId(), name: `${t.name}のコピー`.slice(0, 40), status: 'draft', version: 1, revisions: [], createdAt: now, updatedAt: now }, true);
    showToast('複製しました（下書き）');
  };
  const remove = async (t: StudioType) => {
    const n = usage(t.id);
    if (!(await confirm({ title: `「${t.name}」を削除しますか？`, message: `${n ? `この種類を使っている予定・タスク${n}件と入力済みの値は消えずに残ります。` : ''}種類の定義だけを削除します。`, confirmLabel: '削除', destructive: true }))) return;
    await repo.deleteStudioType(t.id);
    showToast('削除しました');
  };

  if (edit) return <StudioDesigner initial={edit.type} isNew={edit.isNew} usage={usage(edit.type.id)} onDone={() => setEdit(null)} />;
  return (
    <>
      <div className="studio-hero">
        <span className="studio-mark" aria-hidden><Icon name="sparkles" size={30} /></span>
        <p>入力したい項目を、部品を探して1つずつ組み込みます。テンプレートは使わず、空白から作ります。</p>
      </div>
      <Group header="新規作成">
        <button type="button" className="row row-button" onClick={() => setEdit({ type: blank('calendar'), isNew: true })} data-testid="studio-new-calendar"><Icon name="calendar" size={20} className="tint" /><span className="row-label tint">カレンダーの種類を作る</span></button>
        <button type="button" className="row row-button" onClick={() => setEdit({ type: blank('task'), isNew: true })} data-testid="studio-new-task"><Icon name="checklist" size={20} className="tint" /><span className="row-label tint">タスクの種類を作る</span></button>
      </Group>
      {(['calendar', 'task'] as const).map((target) => {
        const list = studioTypes.filter((t) => t.target === target);
        if (!list.length) return null;
        return (
          <div key={target}>
            <div className="group-header">{target === 'calendar' ? 'カレンダーの種類' : 'タスクの種類'}</div>
            <div className="studio-cards">
              {list.map((t) => <StudioCard key={t.id} t={t} used={usage(t.id)} onOpen={() => setEdit({ type: t, isNew: false })} onDuplicate={() => void duplicate(t)} onDelete={() => void remove(t)} />)}
            </div>
          </div>
        );
      })}
    </>
  );
}

function StudioCard({ t, used, onOpen, onDuplicate, onDelete }: { t: StudioType; used: number; onOpen: () => void; onDuplicate: () => void; onDelete: () => void }) {
  const ref = useRef<HTMLButtonElement>(null);
  const lp = useLongPress({ onLongPress: () => ref.current && openContextMenu({ anchor: ref.current, label: t.name, preview: <div className="ctx-card"><strong>{t.name}</strong><span>{t.fields.filter((f) => !f.hidden).length}項目</span></div>, items: [{ label: '編集', icon: 'pencil', onSelect: onOpen }, { label: '複製', icon: 'copy', onSelect: onDuplicate }, 'separator', { label: '削除', icon: 'trash', destructive: true, onSelect: onDelete }] }) });
  return (
    <button ref={ref} type="button" className="studio-card" style={{ ['--c' as string]: t.color }} {...lp} onClick={() => { if (!lp.consumedClick()) onOpen(); }} data-testid={`studio-card-${t.name}`}>
      <span className="ed-preview-icon" aria-hidden><Icon name={resolveItemIcon(t.icon).id} size={22} /></span>
      <span className="studio-card-name">{t.name || '（名前なし）'}</span>
      <span className="studio-card-sub">{t.status === 'draft' ? '下書き' : `${t.fields.filter((f) => !f.hidden).length}項目`}{used ? ` · 使用${used}件` : ''}</span>
    </button>
  );
}

function StudioDesigner({ initial, isNew, usage, onDone }: { initial: StudioType; isNew: boolean; usage: number; onDone: () => void }) {
  const { settings, calendars, tasks, events } = useData();
  const { confirm, showToast } = useUIActions();
  const draftKey = `studio:${initial.id}`;
  const [t, setT] = useState<StudioType>(initial);
  const [q, setQ] = useState('');
  const [fieldEdit, setFieldEdit] = useState<{ f: StudioField; isNew: boolean } | null>(null);
  const [preview, setPreview] = useState(false);
  const [previewVals, setPreviewVals] = useState<Record<string, unknown>>({});
  const listRef = useRef<HTMLDivElement>(null);
  const dirty = JSON.stringify(t) !== JSON.stringify(initial);

  // 途中で閉じても下書きから復元（Q90）
  useEffect(() => { void repo.getDraft(draftKey).then((d) => { if (d && JSON.stringify(d.data) !== JSON.stringify(initial)) setT(d.data as unknown as StudioType); }); }, []); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { if (!dirty) return; const h = window.setTimeout(() => void repo.saveDraft(draftKey, t as unknown as Record<string, unknown>), 500); return () => window.clearTimeout(h); }, [t, dirty, draftKey]);

  const parts = useMemo(() => searchParts(q), [q]);
  const fields = t.fields.filter((f) => !f.hidden);

  const addPart = (type: StudioField['type']) => {
    const p = STUDIO_PARTS.find((x) => x.type === type)!;
    // 検索語が単位なら数値部品に単位と項目名を入れておく（例：「ページ」→ ページ数・単位ページ）
    const word = q.trim();
    const unit = type === 'number' && word ? UNITS.find((u) => u.label === word || u.id === word.toLowerCase())?.id : undefined;
    setFieldEdit({ isNew: true, f: { id: newId(), type, label: unit ? `${word}数` : p.label, showInInfo: type !== 'note', sectionId: t.sections[0]!.id, ...(type === 'number' ? { unit: unit ?? 'times', precision: 0 } : {}), ...(type === 'select' || type === 'multiselect' ? { options: ['A', 'B'] } : {}) } });
    setQ('');
  };
  const saveField = () => {
    if (!fieldEdit) return;
    const f = { ...fieldEdit.f, label: fieldEdit.f.label.trim() || TYPE_LABEL[fieldEdit.f.type] };
    setT((o) => ({ ...o, fields: fieldEdit.isNew ? [...o.fields, f] : o.fields.map((x) => (x.id === f.id ? f : x)) }));
    setFieldEdit(null);
  };
  const removeField = async (f: StudioField) => {
    const used = [...tasks, ...events].filter((r) => r.extra?.studio?.typeId === t.id && r.extra.studio.values[f.id] != null).length;
    if (!(await confirm({ title: `「${f.label}」を外しますか？`, message: used ? `${used}件の記録に入力済みの値は消えずに残ります（項目を非表示にします）。` : '', confirmLabel: '外す', destructive: true }))) return;
    // 既に保存済みの項目は論理的に非表示（過去の値を失わない：Q91）
    setT((o) => ({ ...o, fields: initial.fields.some((x) => x.id === f.id) ? o.fields.map((x) => (x.id === f.id ? { ...x, hidden: true } : x)) : o.fields.filter((x) => x.id !== f.id) }));
  };
  const startDrag = (e: React.PointerEvent, id: string) => {
    e.preventDefault();
    const items = [...(listRef.current?.querySelectorAll<HTMLElement>('[data-field-id]') ?? [])];
    const ids = items.map((x) => x.dataset.fieldId!);
    const rects = items.map((x) => x.getBoundingClientRect());
    const from = ids.indexOf(id);
    const el = items[from]!;
    const y0 = e.clientY;
    let to = from;
    el.classList.add('dragging');
    const move = (ev: PointerEvent) => { const dy = ev.clientY - y0; el.style.transform = `translateY(${dy}px)`; const cy = rects[from]!.top + rects[from]!.height / 2 + dy; const i = rects.findIndex((r) => cy < r.bottom); to = i === -1 ? ids.length - 1 : i; };
    const up = () => {
      window.removeEventListener('pointermove', move); window.removeEventListener('pointerup', up); window.removeEventListener('pointercancel', up);
      el.classList.remove('dragging'); el.style.transform = '';
      if (to === from) return;
      // 移動先の項目と同じセクションに入れる
      const target = t.fields.find((x) => x.id === ids[to]);
      setT((o) => {
        const arr = o.fields.filter((x) => x.id !== id);
        const moved = { ...o.fields.find((x) => x.id === id)!, sectionId: target?.sectionId ?? o.sections[0]!.id };
        const at = arr.findIndex((x) => x.id === ids[to]);
        arr.splice(to > from ? at + 1 : at, 0, moved);
        return { ...o, fields: arr };
      });
    };
    window.addEventListener('pointermove', move); window.addEventListener('pointerup', up); window.addEventListener('pointercancel', up);
  };

  const save = async (status: 'draft' | 'active') => {
    if (!t.name.trim()) return showToast('名前を入力してください');
    if (status === 'active' && !fields.length) return showToast('項目を1つ以上追加してください');
    if (!isNew && usage > 0) {
      const records = [...tasks, ...events].filter((r) => r.extra?.studio?.typeId === t.id).map((r) => ({ values: r.extra!.studio!.values }));
      const imp = studioImpact(initial, { fields: t.fields.map((f) => (f.hidden ? { ...f } : f)).filter((f) => !f.hidden) }, records);
      if ((imp.removed.length || imp.retyped.length) && !(await confirm({ title: '使用中の種類を変更します', message: `この種類を使う記録${usage}件のうち${imp.affected}件に、外す・型を変える項目の値があります。値は消えずに残り、変更前の定義は履歴から戻せます。`, confirmLabel: '変更する' }))) return;
    }
    const saved = await repo.saveStudioType({ ...t, name: t.name.trim(), status }, isNew);
    // カレンダーの種類は、対応する専用カレンダーを作成・更新（Q54）
    if (saved.target === 'calendar' && status === 'active') {
      const cal = calendars.find((c) => c.studioTypeId === saved.id);
      const now = Date.now();
      await repo.saveCalendar(cal ? { ...cal, name: saved.name, color: saved.color, icon: saved.icon } : { id: newId(), name: saved.name, color: saved.color, icon: saved.icon, kind: 'general', studioTypeId: saved.id, visible: true, order: calendars.length, createdAt: now, updatedAt: now }, !cal);
    }
    await repo.clearDraft(draftKey);
    showToast(status === 'draft' ? '下書きを保存しました' : '保存しました');
    onDone();
  };
  const cancel = async () => {
    if (dirty && !(await confirm({ title: '変更を破棄しますか？', message: '下書きは端末に残り、次に開くと復元されます。', confirmLabel: '閉じる', cancelLabel: '編集を続ける' }))) return;
    onDone();
  };

  return (
    <div className="studio-designer" data-testid="studio-designer">
      <div className="studio-bar">
        <button type="button" className="bar-btn" onClick={() => void cancel()}>戻る</button>
        <span className="muted small">{t.target === 'calendar' ? 'カレンダーの種類' : 'タスクの種類'}{!isNew ? ` · 版${t.version}` : ''}</span>
        <button type="button" className="gpill glass glass-i" onClick={() => { setPreviewVals({}); setPreview(true); }} data-testid="studio-preview">プレビュー</button>
      </div>
      {/* 作成の順：名前 → アイコン → 色 → 項目（Q82） */}
      <Group header="名前"><input className="row-input big" value={t.name} onChange={(e) => setT({ ...t, name: e.target.value })} placeholder={t.target === 'calendar' ? '例：ゼミ' : '例：読書'} aria-label="種類の名前" maxLength={40} data-testid="studio-name" /></Group>
      <div className="group-header">アイコン</div>
      <div className="group"><div className="group-body"><IconStrip value={t.icon} onChange={(id) => setT({ ...t, icon: id })} recent={settings.recentIcons} target={t.target === 'task' ? 'task' : 'event'} /></div></div>
      <div className="group-header">色</div>
      <div className="group"><div className="group-body"><ColorStrip value={t.color} onChange={(c) => setT({ ...t, color: c ?? '#BF5AF2' })} recent={settings.recentColors} /></div></div>

      <div className="group-header">項目</div>
      <div className="search-field"><Icon name="search" size={17} /><input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="部品を探す（例：実行時間・ページ・休憩）" aria-label="部品を探す" data-testid="studio-part-search" /></div>
      {q.trim() && (
        <div className="group" data-testid="studio-parts"><div className="group-body">
          {parts.length === 0 && <div className="row muted">見つかりません</div>}
          {parts.map((p) => <button key={p.type} type="button" className="row row-button" onClick={() => addPart(p.type)} data-testid={`part-${p.type}`}><Icon name="plus" size={18} className="tint" /><span className="row-label">{p.label}<span className="sub-label">{p.desc}</span></span></button>)}
        </div></div>
      )}
      {!q.trim() && !fields.length && <p className="note-text">まだ項目はありません。上の検索欄から部品を探して追加してください。</p>}
      <div ref={listRef}>
        {t.sections.map((s) => {
          const fs = fields.filter((f) => f.sectionId === s.id);
          return (
            <div key={s.id} className="studio-section">
              <input className="studio-section-title" value={s.title} onChange={(e) => setT({ ...t, sections: t.sections.map((x) => (x.id === s.id ? { ...x, title: e.target.value } : x)) })} aria-label="セクション名" />
              {fs.map((f) => (
                <div key={f.id} className="field-card" data-field-id={f.id} data-testid={`field-${f.label}`}>
                  <button type="button" className="field-main" onClick={() => setFieldEdit({ f, isNew: false })}>
                    <span className="field-label">{f.label}{f.required ? <span className="req">必須</span> : null}</span>
                    <span className="field-sub">{TYPE_LABEL[f.type]}{f.unit ? ` · ${unitLabel(f.unit)}` : ''}{f.showInInfo ? ' · 情報に表示' : ''}</span>
                  </button>
                  <button type="button" className="icon-btn subtle" aria-label={`${f.label}を外す`} onClick={() => void removeField(f)}><Icon name="close" size={16} /></button>
                  <span className="drag-handle" role="button" tabIndex={0} aria-label={`${f.label}の並び替え`} onPointerDown={(e) => startDrag(e, f.id)}><Icon name="arrowUpDown" size={18} /></span>
                </div>
              ))}
            </div>
          );
        })}
      </div>
      <button type="button" className="row row-button tint-row" onClick={() => setT({ ...t, sections: [...t.sections, { id: newId(), title: `セクション${t.sections.length + 1}` }] })} data-testid="studio-add-section"><Icon name="plus" size={18} /><span className="row-label">セクションを追加</span></button>

      {t.target === 'task' && (
        <Group header="進捗の方式" footer="数値は現在値/目標値、チェックはチェック済み/項目数、時間は実行時間/目標時間で進捗を計算します。">
          <div className="row">
            <span className="seg-mini" role="group" aria-label="進捗の方式">
              {([['none', 'なし'], ['time', '時間'], ['number', '数値'], ['checklist', 'チェック'], ['manual', '手動']] as const).map(([m, l]) => <button key={m} type="button" aria-pressed={t.progress.mode === m} onClick={() => setT({ ...t, progress: { ...t.progress, mode: m, fieldId: m === 'number' ? fields.find((f) => f.type === 'number')?.id ?? null : m === 'manual' ? fields.find((f) => f.type === 'progress')?.id ?? null : null } })} data-testid={`progress-${m}`}>{l}</button>)}
            </span>
          </div>
          {(t.progress.mode === 'number' || t.progress.mode === 'time') && (
            <div className="row">
              <span className="row-label">{t.progress.mode === 'time' ? '目標時間（分）' : '目標値'}</span>
              {t.progress.mode === 'number' && (
                <select className="select-input" value={t.progress.fieldId ?? ''} onChange={(e) => setT({ ...t, progress: { ...t.progress, fieldId: e.target.value || null } })} aria-label="進捗に使う項目">
                  <option value="">項目を選ぶ</option>
                  {fields.filter((f) => f.type === 'number').map((f) => <option key={f.id} value={f.id}>{f.label}</option>)}
                </select>
              )}
              <input className="num-input" type="number" inputMode="decimal" value={t.progress.target ?? ''} onChange={(e) => setT({ ...t, progress: { ...t.progress, target: e.target.value === '' ? null : Number(e.target.value) } })} aria-label="目標値" data-testid="progress-target" />
            </div>
          )}
        </Group>
      )}

      <div className="studio-save">
        <button type="button" className="gpill glass glass-i" onClick={() => void save('draft')} data-testid="studio-save-draft">下書き保存</button>
        <button type="button" className="gbtn-primary glass-i" onClick={() => void save('active')} data-testid="studio-save">保存して使う</button>
      </div>
      {!isNew && t.revisions.length > 0 && (
        <Group header="変更履歴" footer="以前の版の項目構成に戻せます（入力済みの値は消えません）。">
          {t.revisions.slice().reverse().slice(0, 5).map((r) => (
            <button key={r.version} type="button" className="row row-button" onClick={() => setT({ ...t, ...r.definition })}><span className="row-label">版{r.version}<span className="sub-label">{new Date(r.at).toLocaleString('ja-JP')}</span></span><span className="row-value tint">この版に戻す</span></button>
          ))}
        </Group>
      )}

      <Popup open={!!fieldEdit} title={fieldEdit?.isNew ? '部品を追加' : '項目の設定'} onClose={() => setFieldEdit(null)} onDone={saveField} doneLabel={fieldEdit?.isNew ? '追加' : '完了'} testId="field-editor" tall>
        {fieldEdit && <FieldSettings f={fieldEdit.f} sections={t.sections} onChange={(f) => setFieldEdit({ ...fieldEdit, f })} />}
      </Popup>
      {/* プレビュー：実データは作らない（Q90） */}
      <Popup open={preview} title="プレビュー" onClose={() => setPreview(false)} testId="studio-preview-popup" tall>
        <p className="note-text">作成画面の「{t.name || '専用'}」タブの見え方です。ここで入力しても保存されません。</p>
        <StudioFieldsForm type={{ ...t, fields }} values={previewVals} onChange={setPreviewVals} />
      </Popup>
    </div>
  );
}

function FieldSettings({ f, sections, onChange }: { f: StudioField; sections: StudioType['sections']; onChange: (f: StudioField) => void }) {
  const [custom, setCustom] = useState(f.unit?.startsWith('custom:') ? f.unit.slice(7) : '');
  return (
    <>
      <div className="group"><div className="group-body">
        <input className="row-input big" value={f.label} onChange={(e) => onChange({ ...f, label: e.target.value.slice(0, 60) })} placeholder="項目名" aria-label="項目名" data-testid="field-label" />
        <div className="row"><span className="row-label">部品</span><span className="row-value">{TYPE_LABEL[f.type]}</span></div>
        <div className="row"><span className="row-label">セクション</span>
          <select className="select-input" value={f.sectionId} onChange={(e) => onChange({ ...f, sectionId: e.target.value })} aria-label="セクション">{sections.map((s) => <option key={s.id} value={s.id}>{s.title}</option>)}</select>
        </div>
        {f.type !== 'note' && <div className="row"><span className="row-label">必須</span><Toggle label="必須" checked={!!f.required} onChange={(b) => onChange({ ...f, required: b })} /></div>}
        {f.type !== 'note' && <div className="row"><span className="row-label">情報確認に表示</span><Toggle label="情報確認に表示" checked={f.showInInfo} onChange={(b) => onChange({ ...f, showInInfo: b })} /></div>}
      </div></div>
      {f.type === 'number' && (
        <>
          <div className="group-header">単位</div>
          <div className="group"><div className="group-body">
            <div className="chips padded">
              {UNITS.map((u) => <button key={u.id} type="button" className={`chip-opt ${f.unit === u.id ? 'on' : ''}`} aria-pressed={f.unit === u.id} onClick={() => onChange({ ...f, unit: u.id })} data-testid={`unit-${u.id}`}>{u.label}</button>)}
              <button type="button" className={`chip-opt ${f.unit?.startsWith('custom:') ? 'on' : ''}`} aria-pressed={!!f.unit?.startsWith('custom:')} onClick={() => onChange({ ...f, unit: `custom:${custom || '単位'}` })}>自由入力</button>
            </div>
            {f.unit?.startsWith('custom:') && <input className="row-input" value={custom} onChange={(e) => { setCustom(e.target.value.slice(0, 20)); onChange({ ...f, unit: `custom:${e.target.value.slice(0, 20) || '単位'}` }); }} placeholder="例：問・km" aria-label="自由入力の単位" />}
            <div className="row"><span className="row-label">小数点以下</span>
              <span className="seg-mini">{[0, 1, 2].map((p) => <button key={p} type="button" aria-pressed={(f.precision ?? 0) === p} onClick={() => onChange({ ...f, precision: p })}>{p}桁</button>)}</span>
            </div>
            <div className="row"><span className="row-label">範囲</span>
              <span className="dur-inputs"><input type="number" value={f.min ?? ''} onChange={(e) => onChange({ ...f, min: e.target.value === '' ? null : Number(e.target.value) })} aria-label="最小値" placeholder="最小" />〜<input type="number" value={f.max ?? ''} onChange={(e) => onChange({ ...f, max: e.target.value === '' ? null : Number(e.target.value) })} aria-label="最大値" placeholder="最大" /></span>
            </div>
          </div></div>
        </>
      )}
      {(f.type === 'select' || f.type === 'multiselect') && (
        <>
          <div className="group-header">選択肢</div>
          <div className="group"><div className="group-body">
            {(f.options ?? []).map((o, i) => (
              <div className="row" key={i}>
                <input className="row-input" value={o} onChange={(e) => onChange({ ...f, options: (f.options ?? []).map((x, j) => (j === i ? e.target.value.slice(0, 60) : x)) })} aria-label={`選択肢${i + 1}`} />
                <button type="button" className="icon-btn subtle" aria-label="選択肢を外す" onClick={() => onChange({ ...f, options: (f.options ?? []).filter((_, j) => j !== i) })}><Icon name="close" size={16} /></button>
              </div>
            ))}
            <button type="button" className="row row-button tint-row" onClick={() => onChange({ ...f, options: [...(f.options ?? []), `選択肢${(f.options?.length ?? 0) + 1}`].slice(0, 50) })}><Icon name="plus" size={18} /><span className="row-label">選択肢を追加</span></button>
          </div></div>
        </>
      )}
      {f.type === 'note' && <div className="group"><div className="group-body"><textarea className="row-input notes-input" value={f.body ?? ''} onChange={(e) => onChange({ ...f, body: e.target.value.slice(0, 2000) })} placeholder="説明文" aria-label="説明文" rows={3} /></div></div>}
    </>
  );
}
