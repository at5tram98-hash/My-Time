import { useEffect, useMemo, useRef, useState } from 'react';
import { AnimatePresence, motion, useReducedMotion } from 'motion/react';
import {
  addDays, busyItems, expandAll, formatHm, parseInput, replanDay, searchItems, shiftProposal, SPEC_BY_ID, SPEC_DEFS, SPEC_GROUPS, specOf, startOfDay,
  type Candidate, type ParseResult, type SearchHit, type SpecTypeId,
} from '@my-time/domain';
import { Sheet } from '../../components/Sheet';
import { Icon } from '../../components/Icon';
import { useData } from '../../app/data';
import { useUIActions } from '../../app/ui';
import { useNow } from '../../app/useNow';
import { repo, type CandidateToSave } from '../../data/repo';
import { offerUndo } from '../../ui/undo';
import { Popup } from '../../ui/Popup';
import { SPRING } from '../../ui/motion';
import { PlanPreview } from '../plan/PlanPreview';
import { SpecBadge } from '../spec/SpecBadge';

const EXAMPLES = ['土曜日18:30〜22:00 GU 時給1300円', '金曜までに経済学のレポート 2時間', '17時に出かける', '明日は課題2つと買い物', '来週のバイト', '急用ができたので今日の課題を移して'];
const md = (t: number) => { const d = new Date(t); return `${d.getMonth() + 1}/${d.getDate()}（${'日月火水木金土'[d.getDay()]}）`; };

interface Pick { include: boolean; adopt: boolean; title: string; sourceTitle: string; prep: boolean[]; sessions: boolean[]; showWhy: boolean }

/**
 * 文章で追加（P01〜P05・IOS-020〜023）。
 * 1つの入力欄に書くと、その場で予定・タスクの候補に分けて見せる。曖昧な時刻は「候補」と根拠を付け、追加を押すまで保存しない。
 * 「来週のバイト」は検索、「〜を1時間遅らせて」は変更の差分、「今日の課題を移して」は組み直しの案として扱う。
 * 文章はこの端末の中だけで解釈する（外部には送らない）。
 */
export function QuickAddSheet({ depth, text: initialText = '', at }: { depth: number; text?: string; at?: { start: number; end: number; entity: 'event' | 'task' } }) {
  const { tasks, events, employers, subtasksByTask, settings } = useData();
  const { closeSheet, openSheet, showToast } = useUIActions();
  const now = useNow(60_000);
  const reduce = useReducedMotion() ?? false;
  const [text, setText] = useState(initialText);
  const [debounced, setDebounced] = useState(initialText);
  const [picks, setPicks] = useState<Record<string, Pick>>({});
  const [typeOpen, setTypeOpen] = useState(false);
  const [target, setTarget] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  useEffect(() => { requestAnimationFrame(() => inputRef.current?.focus()); }, []);
  useEffect(() => { const t = window.setTimeout(() => setDebounced(text), 220); return () => window.clearTimeout(t); }, [text]);

  const subs = useMemo(() => [...subtasksByTask.values()].flat(), [subtasksByTask]);
  const evs = useMemo(() => expandAll(events, now - 14 * 86_400_000, now + 60 * 86_400_000), [events, now]);
  const opts = { fromHour: settings.suggestFromHour, toHour: settings.suggestToHour, stepMin: settings.suggestStepMin };
  const result: ParseResult | null = useMemo(() => {
    if (!debounced.trim()) return null;
    const r = parseInput(debounced, { now, events: evs, tasks, subtasks: subs, employers, opts });
    if (r.intent === 'create' && at) for (const c of r.candidates) if (c.start == null && c.entity === at.entity) { c.start = at.start; c.end = at.end; c.timeCertain = true; c.reasons.push('時間軸で選んだ時間を使いました'); }
    return r;
  }, [debounced, now, evs, tasks, subs, employers]); // eslint-disable-line react-hooks/exhaustive-deps

  // 新しい候補には既定の選択（含める・時間を使う・準備と作業枠も含める）
  useEffect(() => {
    if (result?.intent !== 'create') return;
    setPicks((old) => {
      const next: Record<string, Pick> = {};
      for (const c of result.candidates) {
        const o = old[c.key];
        // 同じ候補（読み取ったタイトルと準備・作業枠の数が同じ）なら、利用者の選択と書き換えたタイトルを保つ
        next[c.key] = o && o.sourceTitle === c.title && o.prep.length === c.prep.length && o.sessions.length === c.sessions.length ? o : { include: true, adopt: c.start != null, title: c.title, sourceTitle: c.title, prep: c.prep.map(() => true), sessions: c.sessions.map(() => true), showWhy: false };
      }
      return next;
    });
    setTarget(null);
  }, [result]);

  const chosen = result?.intent === 'create' ? result.candidates.filter((c) => picks[c.key]?.include !== false) : [];
  const save = async () => {
    if (result?.intent !== 'create' || !chosen.length) return;
    setSaving(true);
    try {
      const items: CandidateToSave[] = chosen.map((c) => {
        const p = picks[c.key] ?? { include: true, adopt: true, title: c.title, sourceTitle: c.title, prep: [], sessions: [], showWhy: false };
        const timed = c.entity === 'event' || p.adopt;
        return {
          entity: c.entity, spec: c.spec, title: (p.title || c.title).trim() || c.title, start: timed ? c.start : null, end: timed ? c.end : null, allDay: !!c.details.__allDay,
          due: c.due ?? (!timed && c.start != null ? startOfDay(c.start) + 86_400_000 - 60_000 : null), estimateMinutes: c.estimateMinutes ?? (!timed && c.start != null && c.end != null ? Math.round((c.end - c.start) / 60_000) : null),
          details: c.details, workplace: c.workplace, employerId: c.employerId,
          prep: c.prep.filter((_, i) => p.prep[i] !== false), sessions: c.sessions.filter((_, i) => p.sessions[i] !== false),
        };
      });
      const made = await repo.createFromCandidates(items);
      const n = made.events.length + made.tasks.length;
      offerUndo('quick-add', `${n}件を追加しました`, async () => { await repo.undoCreated(made); showToast('追加を取り消しました'); });
      closeSheet();
    } catch (e) {
      showToast(e instanceof Error ? e.message : '追加できませんでした（入力は残っています）');
    } finally { setSaving(false); }
  };

  const detail = (c?: Candidate) => {
    const mode = c?.entity ?? at?.entity ?? 'task';
    const defaults: Record<string, unknown> = c ? { title: picks[c.key]?.title || c.title, specType: c.spec, specDetails: c.details, ...(c.start != null ? (mode === 'event' ? { start: c.start, end: c.end } : { plannedStart: c.start, plannedEnd: c.end }) : mode === 'task' ? { plannedStart: null } : {}), ...(c.estimateMinutes != null ? { estimateMinutes: c.estimateMinutes } : {}) } : at ? (at.entity === 'event' ? { start: at.start, end: at.end } : { plannedStart: at.start, plannedEnd: at.end }) : {};
    closeSheet();
    openSheet({ kind: 'edit', mode, defaults });
  };
  const pickType = (t: SpecTypeId) => {
    setTypeOpen(false);
    const def = SPEC_BY_ID[t];
    closeSheet();
    openSheet({ kind: 'edit', mode: def.entity, defaults: { specType: t, title: text.trim() || '' } });
  };

  const setPick = (k: string, p: Partial<Pick>) => setPicks((o) => ({ ...o, [k]: { ...o[k]!, ...p } }));

  // ---- 検索・変更・組み直し ----
  const busy = useMemo(() => busyItems(evs, tasks, subs), [evs, tasks, subs]);
  const hits: SearchHit[] = useMemo(() => {
    if (!result) return [];
    if (result.intent === 'search') return searchItems(result.query, evs, tasks);
    if (result.intent === 'shift' || result.intent === 'move') return searchItems({ ...result.target, from: result.target.from ?? startOfDay(now), to: result.target.to ?? addDays(startOfDay(now), 14) }, evs, tasks).filter((h) => h.at != null);
    return [];
  }, [result, evs, tasks, now]);
  const chosenHit = target ? hits.find((h) => `${h.entity}:${h.id}` === target) : hits.length === 1 ? hits[0] : undefined;
  const changeProposal = useMemo(() => {
    if (!result || !chosenHit || (result.intent !== 'shift' && result.intent !== 'move')) return null;
    const item = chosenHit.entity === 'event' ? evs.find((e) => e.id === chosenHit.id) : undefined;
    const task = chosenHit.entity === 'task' ? tasks.find((t) => t.id === chosenHit.id) : undefined;
    const start = item?.start ?? task?.plannedStart ?? null;
    const end = item?.end ?? task?.plannedEnd ?? null;
    if (start == null || end == null) return null;
    const delta = result.intent === 'shift' ? result.deltaMin : Math.round((result.toDay - startOfDay(start)) / 60_000);
    return shiftProposal(chosenHit.entity, { id: chosenHit.id, title: chosenHit.title, start, end }, delta, tasks, busy);
  }, [result, chosenHit, evs, tasks, busy]);
  const replan = useMemo(() => (result?.intent === 'replan' ? replanDay(result.day, evs, tasks, subs, now, result.spec ? (t) => specOf(t)?.type === result.spec : undefined, opts) : null), [result, evs, tasks, subs, now]); // eslint-disable-line react-hooks/exhaustive-deps

  const intentLabel = !result ? null : result.intent === 'create' ? (result.candidates.length ? `${result.candidates.length}件の候補` : null) : result.intent === 'search' ? '検索' : result.intent === 'replan' ? '組み直し' : '変更';

  return (
    <Sheet onClose={closeSheet} depth={depth} detent="large" dirty={!!text.trim()} testId="quick-add-sheet" title="追加"
      left={<button type="button" className="bar-btn" onClick={closeSheet}>キャンセル</button>}
      right={result?.intent === 'create' ? <button type="button" className="gbtn-primary glass-i" disabled={!chosen.length || saving} onClick={() => void save()} data-testid="quick-save">{chosen.length ? `${chosen.length}件を追加` : '追加'}</button> : <span />}
      footer={
        <div className="qa-footer glass">
          <button type="button" className="gpill glass glass-i" onClick={() => setTypeOpen(true)} data-testid="quick-types"><Icon name="stack" size={16} />種類から選ぶ</button>
          <button type="button" className="gpill glass glass-i" onClick={() => detail(result?.intent === 'create' ? chosen[0] : undefined)} data-testid="quick-detail"><Icon name="pencil" size={16} />詳しく入力</button>
        </div>
      }>
      <div className="qa-input-wrap">
        <Icon name="wand" size={20} className="qa-wand" />
        <textarea ref={inputRef} className="qa-input" rows={2} value={text} onChange={(e) => setText(e.target.value)} placeholder="やりたいこと・予定を書く（例：明日18時からバイト、金曜までにレポート2時間）" aria-label="追加する内容（文章）" enterKeyHint="done" data-testid="quick-input"
          onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) { e.preventDefault(); setDebounced(text); if (result?.intent === 'create') void save(); } }} />
        {intentLabel && <span className="qa-intent" data-testid="quick-intent">{intentLabel}</span>}
      </div>
      <p className="qa-privacy">文章はこの端末の中だけで読み取ります。曖昧な時刻は「候補」として示し、追加を押すまで保存しません。</p>

      {!text.trim() && (
        <div className="qa-examples" aria-label="入力の例">
          {EXAMPLES.map((x) => <button key={x} type="button" className="qa-example" onClick={() => { setText(x); setDebounced(x); }}>{x}</button>)}
        </div>
      )}

      {result?.intent === 'create' && (
        <div className="qa-cands" data-testid="quick-candidates">
          {result.notes.map((n) => <p key={n} className="muted small">{n}</p>)}
          <AnimatePresence initial={false}>
            {result.candidates.map((c, idx) => {
              const p = picks[c.key];
              if (!p) return null;
              const def = c.spec ? SPEC_BY_ID[c.spec] : null;
              const timed = c.entity === 'event' || p.adopt;
              return (
                <motion.div key={c.key} layout={!reduce} initial={reduce ? { opacity: 0 } : { opacity: 0, y: 12 }} animate={{ opacity: p.include ? 1 : 0.45, y: 0 }} exit={{ opacity: 0 }} transition={reduce ? { duration: 0.1 } : { ...SPRING.pop, delay: Math.min(idx, 5) * 0.03 }}
                  className={`qa-card ${c.entity}`} data-testid="quick-candidate" data-spec={c.spec ?? ''} data-entity={c.entity}>
                  <div className="qa-card-head">
                    <SpecBadge type={c.spec} entity={c.entity} size={34} />
                    <div className="qa-card-main">
                      <input className="qa-title" value={p.title} onChange={(e) => setPick(c.key, { title: e.target.value })} aria-label="タイトル" data-testid="quick-cand-title" />
                      <div className="qa-meta">
                        <span className={`qa-kind ${c.entity}`}>{c.entity === 'event' ? '予定' : 'タスク'}{def ? `・${def.name}` : ''}</span>
                        {timed && c.start != null ? <span data-testid="quick-cand-time">{c.details.__allDay ? `${md(c.start)} 終日` : `${md(c.start)} ${formatHm(c.start)}〜${c.end != null ? formatHm(c.end) : ''}`}</span> : <span>未割当</span>}
                        {c.due != null && <span>締切 {md(c.due)}</span>}
                        {c.estimateMinutes != null && <span>見積{c.estimateMinutes}分</span>}
                        {timed && c.start != null && !c.timeCertain && !c.details.__allDay && <span className="tag-candidate" data-testid="quick-cand-tentative">候補</span>}
                      </div>
                    </div>
                    <button type="button" className={`qa-include ${p.include ? 'on' : ''}`} role="checkbox" aria-checked={p.include} aria-label={`「${p.title}」を追加する`} onClick={() => setPick(c.key, { include: !p.include })} data-testid="quick-cand-include"><Icon name="check" size={15} strokeWidth={3} /></button>
                  </div>
                  {p.include && (
                    <>
                      {c.entity === 'task' && c.start != null && (
                        <div className="qa-row"><span>この時間に入れる</span><button type="button" role="switch" aria-checked={p.adopt} className={`mini-switch ${p.adopt ? 'on' : ''}`} onClick={() => setPick(c.key, { adopt: !p.adopt })} aria-label="この時間に入れる" data-testid="quick-cand-adopt"><span /></button></div>
                      )}
                      {c.prep.length > 0 && (
                        <div className="qa-sub" aria-label="準備">
                          <div className="qa-sub-head"><Icon name="checklist" size={14} />準備（右のレーンに置きます・時間は目安）</div>
                          {c.prep.map((x, i) => <label key={i} className="qa-subrow"><input type="checkbox" checked={p.prep[i] !== false} onChange={(e) => setPick(c.key, { prep: p.prep.map((v, j) => (j === i ? e.target.checked : v)) })} /><span>{x.title}</span><span className="muted">{formatHm(x.start)}〜{formatHm(x.end)}</span></label>)}
                        </div>
                      )}
                      {c.sessions.length > 0 && (
                        <div className="qa-sub" aria-label="作業枠">
                          <div className="qa-sub-head"><Icon name="split" size={14} />作業枠の候補（締切は動かしません）</div>
                          {c.sessions.map((x, i) => <label key={i} className="qa-subrow"><input type="checkbox" checked={p.sessions[i] !== false} onChange={(e) => setPick(c.key, { sessions: p.sessions.map((v, j) => (j === i ? e.target.checked : v)) })} /><span>{x.title}</span><span className="muted">{md(x.start)} {formatHm(x.start)}〜{formatHm(x.end)}</span></label>)}
                        </div>
                      )}
                      {c.reasons.length > 0 && (
                        <button type="button" className="qa-why" aria-expanded={p.showWhy} onClick={() => setPick(c.key, { showWhy: !p.showWhy })}>
                          <Icon name="info" size={13} />どう読み取ったか
                        </button>
                      )}
                      {p.showWhy && <ul className="qa-reasons">{c.reasons.map((r) => <li key={r}>{r}</li>)}</ul>}
                      <button type="button" className="link-btn small qa-edit" onClick={() => detail(c)}>この候補を詳しく編集</button>
                    </>
                  )}
                </motion.div>
              );
            })}
          </AnimatePresence>
        </div>
      )}

      {result?.intent === 'search' && (
        <div className="group" data-testid="quick-search">
          <div className="group-header">「{result.query.label}」の検索結果</div>
          <div className="group-body">
            {hits.length ? hits.slice(0, 30).map((h) => (
              <button key={`${h.entity}:${h.id}`} type="button" className="row row-button" onClick={() => { closeSheet(); openSheet({ kind: 'info', entity: h.entity, id: h.id }); }} data-testid="quick-hit">
                <SpecBadge type={h.spec} entity={h.entity} size={26} />
                <span className="row-label" data-user-text>{h.title}</span>
                <span className="row-value">{h.at != null ? `${md(h.at)} ${formatHm(h.at)}` : ''}</span>
              </button>
            )) : <div className="row"><span className="row-label muted">見つかりませんでした</span></div>}
          </div>
        </div>
      )}

      {(result?.intent === 'shift' || result?.intent === 'move') && (
        <div data-testid="quick-change">
          {hits.length === 0 && <p className="muted small center">変える対象が見つかりませんでした。名前や日付を足してください。</p>}
          {hits.length > 1 && (
            <div className="group">
              <div className="group-header">どれを変えますか？（{hits.length}件が一致）</div>
              <div className="group-body">
                {hits.slice(0, 10).map((h) => (
                  <button key={`${h.entity}:${h.id}`} type="button" role="radio" aria-checked={target === `${h.entity}:${h.id}`} className="row row-button" onClick={() => setTarget(`${h.entity}:${h.id}`)} data-testid="quick-target">
                    <span className={`sel-mark ${target === `${h.entity}:${h.id}` ? 'on' : ''}`} aria-hidden><Icon name="check" size={12} strokeWidth={3} /></span>
                    <span className="row-label" data-user-text>{h.title}</span>
                    <span className="row-value">{h.at != null ? `${md(h.at)} ${formatHm(h.at)}` : ''}</span>
                  </button>
                ))}
              </div>
            </div>
          )}
          {changeProposal && <div className="group"><div className="group-body padded"><PlanPreview proposal={changeProposal} onApplied={closeSheet} testId="quick-change-preview" /></div></div>}
        </div>
      )}

      {result?.intent === 'replan' && replan && (
        <div className="group" data-testid="quick-replan"><div className="group-header">組み直しの案</div><div className="group-body padded"><PlanPreview proposal={replan} onApplied={closeSheet} testId="quick-replan-preview" /></div></div>
      )}

      <Popup open={typeOpen} title="種類から選ぶ" onClose={() => setTypeOpen(false)} testId="spec-type-popup" tall>
        <SpecTypeGrid onPick={pickType} />
      </Popup>
    </Sheet>
  );
}

/** 25種類を、用途のまとまりごとに並べる（普段は隠し、選ぶときだけ見せる：IOS-024） */
export function SpecTypeGrid({ onPick, value, entity }: { onPick: (t: SpecTypeId) => void; value?: SpecTypeId | null; entity?: 'event' | 'task' }) {
  return (
    <div className="spec-grid">
      {SPEC_GROUPS.map((g) => (
        <section key={g.id} className="spec-group" aria-label={g.label}>
          <div className="group-header">{g.label}</div>
          <div className="spec-tiles">
            {SPEC_DEFS.filter((d) => d.group === g.id).map((d) => (
              <button key={d.id} type="button" className={`spec-tile ${value === d.id ? 'on' : ''} ${entity && entity !== d.entity ? 'other' : ''}`} aria-pressed={value === d.id} onClick={() => onPick(d.id)} data-testid={`spec-${d.id}`}>
                <SpecBadge type={d.id} size={32} />
                <span className="spec-name">{d.name}</span>
                <span className="spec-blurb">{d.blurb}</span>
                <span className="spec-kind">{d.entity === 'event' ? '予定' : 'タスク'}</span>
              </button>
            ))}
          </div>
        </section>
      ))}
    </div>
  );
}
