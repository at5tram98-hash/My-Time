import { useState } from 'react';
import { AnimatePresence, motion, useReducedMotion } from 'motion/react';
import {
  canAddSubtask, checks, list, members, slots, specInsights, SPEC_BY_ID, str, type CalEvent, type SpecValue, type Task,
} from '@my-time/domain';
import { Icon } from '../../components/Icon';
import { Toggle } from '../../components/Controls';
import { useData } from '../../app/data';
import { useUIActions } from '../../app/ui';
import { useNow } from '../../app/useNow';
import { repo } from '../../data/repo';
import { SPRING } from '../../ui/motion';
import { SpecBadge } from './SpecBadge';

const dt = (t: number) => { const d = new Date(t); return `${d.getMonth() + 1}/${d.getDate()} ${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`; };

/**
 * 情報シートの専門カード（S01〜S25）。最初は要点だけ（給与見込み・残り時間・出発の目安など）。
 * 「詳しく」で、チェックリスト・入金や支払いの確認などをその場で操作できる（入力の画面に行かずに済む）。
 * 推定値には「見込み」を付け、未入力・未確認はそのまま示す。
 */
export function SpecCard({ item, entity, spec }: { item: Task | CalEvent; entity: 'task' | 'event'; spec: SpecValue }) {
  const { tasks, events, subtasksByTask, employers } = useData();
  const { showToast, openSheet } = useUIActions();
  const now = useNow(30_000);
  const reduce = useReducedMotion() ?? false;
  const [open, setOpen] = useState(false);
  const def = SPEC_BY_ID[spec.type];
  const subtasks = [...subtasksByTask.values()].flat();
  const insights = specInsights(item, spec, { now, tasks, events, subtasks, employers });
  const d = spec.details;
  const patch = (p: Record<string, unknown>) => repo.updateSpecDetails(entity, item.id, p).catch((e: Error) => showToast(e.message));
  const run = async (f: () => Promise<unknown>, done: string) => { try { await f(); showToast(done); } catch (e) { showToast(e instanceof Error ? e.message : 'できませんでした'); } };

  const checklistFields = def.fields.filter((f) => f.type === 'checklist');
  const toggleFields = def.fields.filter((f) => f.type === 'toggle');
  const selectFields = def.fields.filter((f) => f.type === 'select' && f.key !== 'destTimeZone');
  const listFields = def.fields.filter((f) => ['list', 'text', 'url', 'multiline'].includes(f.type) && (Array.isArray(d[f.key]) ? list(d[f.key]).length : str(d[f.key])));
  const task = entity === 'task' ? (item as Task) : null;
  const canSteps = !!task && !!(def.steps?.length || (spec.type === 'routine' && Array.isArray(d.steps))) && canAddSubtask(task);
  const canPrep = entity === 'event' && !!def.prep?.length;
  const hasDetail = checklistFields.length || toggleFields.length || selectFields.length || listFields.length || spec.type === 'groupWork' || spec.type === 'shiftRequest';

  return (
    <section className="spec-card" data-testid="spec-card" data-spec={spec.type} aria-label={`${def.name}の情報`}>
      <div className="spec-card-head">
        <SpecBadge type={spec.type} entity={entity} size={30} />
        <div className="spec-card-title"><strong>{def.name}</strong><span>{def.blurb}</span></div>
      </div>
      {insights.length > 0 && (
        <dl className="spec-insights">
          {insights.map((x) => (
            <div key={x.label} className={`spec-insight ${x.tone ?? ''}`} data-testid="spec-insight" data-label={x.label}>
              <dt>{x.label}</dt>
              <dd>
                <span className="v">{x.value}</span>
                {x.tone === 'estimate' && <span className="tag-estimate">見込み</span>}
                {x.note && <span className="n">{x.note}</span>}
              </dd>
            </div>
          ))}
        </dl>
      )}
      {(hasDetail || canSteps || canPrep || spec.type === 'cooking' || ['assignment', 'report', 'exam'].includes(spec.type)) && (
        <button type="button" className="spec-more" aria-expanded={open} onClick={() => setOpen(!open)} data-testid="spec-more">
          {open ? 'たたむ' : '詳しく'}<Icon name="chevronDown" size={14} strokeWidth={2.6} style={{ transform: open ? 'rotate(180deg)' : undefined, transition: 'transform 220ms var(--spring)' }} />
        </button>
      )}
      <AnimatePresence initial={false}>
        {open && (
          <motion.div key="more" className="spec-detail" initial={reduce ? { opacity: 0 } : { opacity: 0, height: 0 }} animate={reduce ? { opacity: 1 } : { opacity: 1, height: 'auto' }} exit={reduce ? { opacity: 0 } : { opacity: 0, height: 0 }} transition={reduce ? { duration: 0.1 } : SPRING.sheet} style={{ overflow: 'hidden' }}>
            {checklistFields.map((f) => {
              const items = checks(d[f.key]);
              return (
                <div key={f.key} className="spec-check-group">
                  <div className="spec-sub">{f.label}</div>
                  {items.length ? items.map((x, i) => (
                    <button key={x.id + i} type="button" role="checkbox" aria-checked={x.done} className="spec-check" onClick={() => void patch({ [f.key]: items.map((y, j) => (j === i ? { ...y, done: !y.done } : y)) })} data-testid="spec-check">
                      <span className={`check-circle small ${x.done ? 'on' : ''}`} aria-hidden>{x.done && <Icon name="check" size={12} strokeWidth={3} />}</span>
                      <span className={x.done ? 'struck' : ''}>{x.name}</span>
                    </button>
                  )) : <p className="muted small">編集画面で追加できます</p>}
                </div>
              );
            })}
            {toggleFields.map((f) => <div key={f.key} className="row"><span className="row-label">{f.label}</span><Toggle label={f.label} checked={d[f.key] === true} onChange={(b) => void patch({ [f.key]: b })} /></div>)}
            {selectFields.map((f) => (
              <div key={f.key} className="row"><span className="row-label">{f.label}</span>
                <select className="select-input" value={str(d[f.key]) || f.options![0]} onChange={(e) => void patch({ [f.key]: e.target.value })} aria-label={f.label}>{f.options!.map((o) => <option key={o} value={o}>{o}</option>)}</select>
              </div>
            ))}
            {listFields.map((f) => <div key={f.key} className="row"><span className="row-label">{f.label}</span><span className="row-value wrap">{Array.isArray(d[f.key]) ? list(d[f.key]).join('、') : str(d[f.key])}</span></div>)}
            {spec.type === 'groupWork' && members(d.members).map((m, i) => (
              <div key={i} className="row"><span className="row-label">{m.name || '担当者'}{m.mine ? '（自分）' : ''}</span><span className="row-value">{m.part || '担当'}・{{ todo: '未着手', waiting: '待っている', done: '完了' }[m.status]}</span></div>
            ))}
            {spec.type === 'shiftRequest' && slots(d.wishes).map((w, i) => <div key={i} className="row"><span className="row-label">希望{i + 1}</span><span className="row-value">{dt(w.start)}〜{dt(w.end).slice(-5)}</span></div>)}
            <div className="spec-actions">
              {canSteps && <button type="button" className="gpill glass glass-i" onClick={() => void run(() => repo.createSpecSteps(item.id), '工程を追加しました')} data-testid="spec-steps"><Icon name="checklist" size={15} />工程を作る</button>}
              {canPrep && <button type="button" className="gpill glass glass-i" onClick={() => void run(() => repo.createPrepTasks(item.id), '準備のタスクを作りました')} data-testid="spec-prep"><Icon name="checklist" size={15} />準備を作る</button>}
              {spec.type === 'cooking' && <button type="button" className="gpill glass glass-i" onClick={() => void run(() => repo.shoppingFromCooking(item.id), '買い物のタスクを作りました')} data-testid="spec-shopping"><Icon name="cart" size={15} />足りない材料を買い物へ</button>}
              {spec.type === 'shiftRequest' && <button type="button" className="gpill glass glass-i" onClick={() => void run(async () => { await navigator.clipboard?.writeText(slots(d.wishes).map((w) => `${dt(w.start)}〜${dt(w.end).slice(-5)}`).concat(list(d.unavailable).map((x) => `× ${x}`)).join('\n')); }, '提出用の一覧をコピーしました')} data-testid="spec-copy"><Icon name="copy" size={15} />提出用にコピー</button>}
              {task && ['assignment', 'report', 'exam'].includes(spec.type) && task.status !== 'done' && <button type="button" className="gpill glass glass-i" onClick={() => openSheet({ kind: 'reschedule', taskId: task.id, mode: 'split' })} data-testid="spec-sessions"><Icon name="split" size={15} />作業時間を置く</button>}
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </section>
  );
}
