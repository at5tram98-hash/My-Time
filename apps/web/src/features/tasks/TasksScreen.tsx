import { useMemo, useRef, useState } from 'react';
import { AnimatePresence, motion, useReducedMotion } from 'motion/react';
import { actualProgress, addDays, needsSetup, startOfDay, taskAnchor, type Task } from '@my-time/domain';
import { useData } from '../../app/data';
import { useUIActions } from '../../app/ui';
import { useNow } from '../../app/useNow';
import { Icon, type IconName } from '../../components/Icon';
import { MenuButton } from '../../components/Menu';
import { repo } from '../../data/repo';
import type { TaskGroup, TaskKindFilter, TaskScope, TaskSort } from '../../data/db';
import { EventBadge } from '../../components/Identity';
import { ChoicePopup } from '../editor/inputs';
import { subTimeText } from './TaskDetailSheet';
import { TaskRow } from './TaskRow';
import { useProgressive } from '../../components/useProgressive';
import { SwipeRow } from '../../ui/SwipeRow';
import { KindButtons } from '../../ui/KindButtons';
import { deleteWithUndo } from '../../ui/undo';
import { InlineSearch } from '../search/InlineSearch';
import { Ring } from '../../ui/Ring';
import { SPRING } from '../../ui/motion';

const SCOPE_LABEL: Record<TaskScope, string> = { today: '今日', upcoming: '近日', all: 'すべて', flagged: 'フラグ', done: '完了' };
const SCOPE_ICON: Record<TaskScope, { icon: IconName; color: string }> = { today: { icon: 'today', color: '#0A84FF' }, upcoming: { icon: 'calendar', color: '#FF3B30' }, all: { icon: 'tray', color: '#3A3A3C' }, flagged: { icon: 'flag', color: '#FF9500' }, done: { icon: 'check', color: '#8E8E93' } };
const GROUP_LABEL: Record<TaskGroup, string> = { category: 'カテゴリー', tag: 'タグ', date: '日付' };
const SORT_LABEL: Record<TaskSort, string> = { due: '期限順', priority: '優先度順', manual: '手動' };

/** 一覧に表示する対象（Q40）：今日＝今日が予定・確認日、または期限切れの未完了 / 近日＝7日以内 / すべて */
export function inScope(t: Task, scope: TaskScope, now: number): boolean {
  const isDone = t.status === 'done' || !!t.checked;
  if (scope === 'done') return isDone;
  if (scope === 'flagged') return t.flagged && !isDone;
  if (scope === 'all') return true;
  const a = taskAnchor(t);
  const today = startOfDay(now);
  if (a == null) return scope === 'upcoming' ? false : needsSetup(t);
  if (scope === 'today') return (a >= today && a < addDays(today, 1)) || (a < today && t.status !== 'done' && !t.checked);
  return a >= today && a < addDays(today, 8);
}

export function sortTasks(list: Task[], sort: TaskSort, manual: string[]): Task[] {
  const due = (t: Task) => taskAnchor(t) ?? Number.MAX_SAFE_INTEGER;
  if (sort === 'priority') return [...list].sort((a, b) => b.priority - a.priority || due(a) - due(b));
  if (sort === 'manual') {
    const idx = new Map(manual.map((id, i) => [id, i]));
    return [...list].sort((a, b) => (idx.get(a.id) ?? 1e9) - (idx.get(b.id) ?? 1e9) || due(a) - due(b));
  }
  return [...list].sort((a, b) => due(a) - due(b));
}

/**
 * タスク一覧（Q32〜41）。iOS リマインダー風のグループ化リスト。
 * 種類（すべて・実行・確認）は非ガラスの独立ボタン、期間（今日・近日・すべて）・並び順は別の操作。
 */
export function TasksScreen() {
  const { tasks, subtasksByTask, settings, categories } = useData();
  const { openSheet, showToast } = useUIActions();
  const now = useNow();
  const reduce = useReducedMotion();
  const [showDone, setShowDone] = useState(false);
  const [editing, setEditing] = useState(false);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [openSubs, setOpenSubs] = useState<Set<string>>(new Set());
  const { taskKind: kind, taskScope: scope, taskSort: sort } = settings;
  const setPref = (p: Partial<{ taskKind: TaskKindFilter; taskScope: TaskScope; taskSort: TaskSort }>) => void repo.updateSettings(p);

  const group: TaskGroup = settings.taskGroup ?? 'category';
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  const [groupPick, setGroupPick] = useState(false);

  // スマートリストの件数（task.id で重複なし：C29）
  const counts = useMemo(() => {
    const k = tasks.filter((t) => kind === 'all' || t.kind === kind);
    const open = (t: Task) => t.status !== 'done' && !t.checked;
    return Object.fromEntries((['today', 'upcoming', 'all', 'flagged', 'done'] as TaskScope[]).map((sc) => [sc, k.filter((t) => inScope(t, sc, now) && (sc === 'done' || open(t))).length])) as Record<TaskScope, number>;
  }, [tasks, kind, now]);

  const sections = useMemo(() => {
    const base = tasks.filter((t) => (kind === 'all' || t.kind === kind) && inScope(t, scope, now));
    const isDone = (t: Task) => t.status === 'done' || !!t.checked;
    const open = scope === 'done' ? base : base.filter((t) => !isDone(t));
    const done = scope === 'done' ? [] : base.filter(isDone).sort((a, b) => (b.actualEnd ?? b.checkedAt ?? 0) - (a.actualEnd ?? a.checkedAt ?? 0));
    const unscheduled = scope === 'done' ? [] : sortTasks(open.filter(needsSetup), sort, settings.taskManualOrder);
    const rest = open.filter((x) => scope === 'done' || !needsSetup(x));
    const groups = new Map<string, Task[]>();
    const push = (key: string, t: Task) => { const g = groups.get(key); if (g) g.push(t); else groups.set(key, [t]); };
    const today = startOfDay(now);
    const dateKey = (t: Task) => {
      const a = taskAnchor(t);
      if (a == null) return '日時なし';
      if (a < today && !isDone(t)) return '期限切れ';
      if (a < addDays(today, 1)) return a < today ? '過去' : '今日';
      if (a < addDays(today, 2)) return '明日';
      if (a < addDays(today, 8)) return '7日以内';
      return 'それ以降';
    };
    for (const t of rest) {
      if (group === 'category') push(t.category ?? 'カテゴリーなし', t);
      else if (group === 'tag') { if (t.tags.length) for (const tag of new Set(t.tags)) push(`#${tag}`, t); else push('タグなし', t); }
      else push(dateKey(t), t);
    }
    const catOrder = new Map(categories.map((c, i) => [c.name, i]));
    const DATE_ORDER = ['期限切れ', '今日', '明日', '7日以内', 'それ以降', '過去', '日時なし'];
    const last = group === 'category' ? 'カテゴリーなし' : group === 'tag' ? 'タグなし' : '';
    const sorted = [...groups.entries()]
      .sort(([a], [b]) => group === 'date' ? DATE_ORDER.indexOf(a) - DATE_ORDER.indexOf(b) : (a === last ? 1 : b === last ? -1 : group === 'category' ? (catOrder.get(a) ?? 999) - (catOrder.get(b) ?? 999) || a.localeCompare(b, 'ja') : a.localeCompare(b, 'ja')))
      .map(([name, ts]) => ({ name, tasks: sortTasks(ts, sort, settings.taskManualOrder) }));
    // 件数は重複なし（複数タグのタスクは各グループに出るが1件として数える）
    return { unscheduled, groups: sorted, done, flat: sortTasks(open, sort, settings.taskManualOrder), total: open.length };
  }, [tasks, kind, scope, sort, now, settings.taskManualOrder, categories, group]);

  const { limit, more } = useProgressive(sections.total + (showDone ? sections.done.length : 0), `${kind}-${scope}-${sort}-${showDone}`);
  let budget = limit;
  const take = (list: Task[]) => { const out = list.slice(0, Math.max(0, budget)); budget -= out.length; return out; };
  const unscheduledRows = take(sections.unscheduled);
  const groupRows = sections.groups.map((g) => ({ ...g, rows: take(g.tasks) })).filter((g) => g.rows.length > 0);
  const doneRows = showDone ? take(sections.done) : [];

  const complete = async (t: Task) => {
    try {
      if (t.kind === 'check') await repo.toggleCheck(t.id);
      else if (t.status === 'notStarted') { await repo.taskAction(t.id, 'start'); await repo.taskAction(t.id, 'finish'); }
      else if (t.status === 'running' || t.status === 'paused') await repo.taskAction(t.id, 'finish');
      showToast(`「${t.title}」を完了しました`);
    } catch (e) { showToast(e instanceof Error ? e.message : '完了できませんでした'); }
  };
  const remove = (t: Task) => deleteWithUndo(`task:${t.id}`, `「${t.title}」`, () => repo.deleteTask(t.id));

  const row = (t: Task, showDate = true) => {
    const subs = subtasksByTask.get(t.id) ?? [];
    const openS = openSubs.has(t.id);
    const inner = (
      <div className={`task-li ${editing ? 'editing' : ''}`} data-task-id={t.id}>
        {editing && (
          <button type="button" role="checkbox" aria-checked={selected.has(t.id)} aria-label={`${t.title}を選択`} className={`check-circle ${selected.has(t.id) ? 'on' : ''}`} onClick={() => setSelected((s) => { const n = new Set(s); if (n.has(t.id)) n.delete(t.id); else n.add(t.id); return n; })}>
            {selected.has(t.id) && <Icon name="check" size={14} strokeWidth={3} />}
          </button>
        )}
        <div className="task-li-main"><TaskRow task={t} subtasks={subs} now={now} showDate={showDate} /></div>
        {!editing && subs.length > 0 && (
          <button type="button" className="sub-toggle" aria-expanded={openS} aria-label={`サブタスク${subs.length}件を${openS ? '閉じる' : '開く'}`} onClick={() => setOpenSubs((s) => { const n = new Set(s); if (n.has(t.id)) n.delete(t.id); else n.add(t.id); return n; })} data-testid={`subs-toggle-${t.id}`}>
            <span className="sub-count">{subs.filter((x) => x.done).length}/{subs.length}</span>
            <Icon name={openS ? 'chevronDown' : 'chevronRight'} size={14} strokeWidth={2.4} />
          </button>
        )}
        {editing && sort === 'manual' && <span className="drag-handle" aria-hidden onPointerDown={(e) => startReorder(e, t.id)}><Icon name="reorder" size={20} /></span>}
      </div>
    );
    return (
      <motion.div key={t.id} layout={reduce ? false : 'position'} transition={SPRING.capsule}>
        {editing ? inner : (
          <SwipeRow
            testId={`swipe-${t.id}`}
            left={t.status === 'done' || t.checked ? [] : [{ label: '完了', icon: 'check', color: 'green', onAct: () => void complete(t) }]}
            right={[{ label: '削除', icon: 'trash', color: 'red', onAct: () => remove(t) }, { label: '編集', icon: 'pencil', color: 'blue', onAct: () => openSheet({ kind: 'edit', mode: 'task', id: t.id }) }]}
          >
            {inner}
          </SwipeRow>
        )}
        <AnimatePresence initial={false}>
          {openS && !editing && (
            <motion.div className="subtask-list" initial={{ height: 0, opacity: 0 }} animate={{ height: 'auto', opacity: 1 }} exit={{ height: 0, opacity: 0 }} transition={reduce ? { duration: 0 } : SPRING.sheet}>
              {subs.map((s) => (
                <div key={s.id} className="subtask-li">
                  <button type="button" role="checkbox" aria-checked={s.done} aria-label={`${s.title}を完了`} className={`check-circle small ${s.done ? 'on' : ''}`} onClick={() => void repo.toggleSubtask(s.id)}>
                    {s.done && <Icon name="check" size={12} strokeWidth={3} />}
                  </button>
                  <span className={`sub-title ${s.done ? 'struck' : ''}`}>{s.title}{subTimeText(s) && <span className="sub-label">{subTimeText(s)}</span>}</span>
                </div>
              ))}
              <div className="subtask-li parent-progress"><Ring value={actualProgress(t, subs).value ?? 0} size={22} /><span className="muted small">親タスクの進捗に反映</span></div>
            </motion.div>
          )}
        </AnimatePresence>
      </motion.div>
    );
  };

  // ---- 編集モード：専用ハンドルでドラッグ並び替え（矢印ボタンは使わない：Q39・Q55）----
  const listRef = useRef<HTMLDivElement>(null);
  const startReorder = (e: React.PointerEvent, id: string) => {
    e.preventDefault();
    const el = (e.currentTarget as HTMLElement).closest('.task-li') as HTMLElement | null;
    if (!el || !listRef.current) return;
    const items = [...listRef.current.querySelectorAll<HTMLElement>('.task-li[data-task-id]')];
    const ids = items.map((x) => x.dataset.taskId!);
    const rects = items.map((x) => x.getBoundingClientRect());
    const y0 = e.clientY;
    const from = ids.indexOf(id);
    let to = from;
    el.classList.add('dragging');
    const move = (ev: PointerEvent) => {
      const dy = ev.clientY - y0;
      el.style.transform = `translateY(${dy}px)`;
      const cy = rects[from]!.top + rects[from]!.height / 2 + dy;
      to = Math.max(0, Math.min(ids.length - 1, rects.findIndex((r) => cy < r.bottom) === -1 ? ids.length - 1 : rects.findIndex((r) => cy < r.bottom)));
    };
    const up = () => {
      window.removeEventListener('pointermove', move);
      window.removeEventListener('pointerup', up);
      window.removeEventListener('pointercancel', up);
      el.classList.remove('dragging');
      el.style.transform = '';
      if (to === from) return;
      const next = [...ids];
      next.splice(to, 0, next.splice(from, 1)[0]!);
      const rest = settings.taskManualOrder.filter((x) => !next.includes(x));
      void repo.updateSettings({ taskManualOrder: [...next, ...rest].slice(0, 2000) });
    };
    window.addEventListener('pointermove', move);
    window.addEventListener('pointerup', up);
    window.addEventListener('pointercancel', up);
  };

  const bulk = async (what: 'done' | 'delete') => {
    const list = tasks.filter((t) => selected.has(t.id));
    if (what === 'done') for (const t of list) await complete(t);
    else for (const t of list) remove(t);
    setSelected(new Set());
    setEditing(false);
  };

  return (
    <div className="screen tasks" data-testid="tasks-screen">
      <header className="nav large">
        <div className="nav-row">
          <h1 className="large-title">タスク</h1>
          <div className="nav-actions gap">
            <InlineSearch target="tasks" scope="tasks" />
            <MenuButton label="並び順と表示" className="gbtn glass glass-i" testId="tasks-sort" items={[
              ...(['due', 'priority', 'manual'] as TaskSort[]).map((s) => ({ label: SORT_LABEL[s], checked: sort === s, onSelect: () => setPref({ taskSort: s }) })),
              'separator',
              { label: '完了済みを表示', checked: showDone, onSelect: () => setShowDone((v) => !v) },
            ]}>
              <Icon name="arrowUpDown" size={19} />
            </MenuButton>
            <button type="button" className="gpill glass glass-i" aria-pressed={editing} onClick={() => { setEditing((v) => !v); setSelected(new Set()); }} data-testid="tasks-edit">{editing ? '完了' : '編集'}</button>
            <button type="button" className="gbtn glass glass-i tint" aria-label="新規タスク" onClick={() => openSheet({ kind: 'edit', mode: 'task', defaults: kind === 'check' ? { kind: 'check' } : {} })} data-testid="tasks-add"><Icon name="plus" size={20} strokeWidth={2.2} /></button>
          </div>
        </div>
      </header>
      <div className="scroll-body" ref={listRef}>
        {/* スマートリスト・種類・グループは一覧と一緒にスクロール（一覧の表示域を狭めない） */}
        <div className="tasks-top">
        {/* スマートリスト（C29）：今日・近日・すべて・フラグ・完了の件数カード */}
        <div className="smart-lists" role="group" aria-label="表示するタスク">
          {(['today', 'upcoming', 'all', 'flagged', 'done'] as TaskScope[]).map((sc) => (
            <button key={sc} type="button" className={`smart-card ${scope === sc ? 'on' : ''} ${sc === 'done' ? 'wide' : ''}`} aria-pressed={scope === sc} onClick={() => setPref({ taskScope: sc })} data-testid={`scope-${sc}`}>
              <span className="smart-ico" style={{ background: SCOPE_ICON[sc].color }} aria-hidden><Icon name={SCOPE_ICON[sc].icon} size={17} strokeWidth={2.2} /></span>
              <span className="smart-count">{counts[sc]}</span>
              <span className="smart-label">{SCOPE_LABEL[sc]}</span>
            </button>
          ))}
        </div>
        {/* 種類：実行は赤・確認は青の独立ボタン。選択中が最も大きい（C10・C30） */}
        <KindButtons
          label="タスクの種類"
          value={kind}
          onChange={(k) => setPref({ taskKind: k })}
          options={[
            { value: 'all', label: 'すべて', tone: 'neutral', testId: 'kind-all' },
            { value: 'do', label: '実行', tone: 'do', testId: 'kind-do' },
            { value: 'check', label: '確認', tone: 'check', testId: 'kind-check' },
          ]}
        />
        <div className="list-tools">
          <button type="button" className="tool-chip" onClick={() => setGroupPick(true)} data-testid="tasks-group">グループ：{GROUP_LABEL[group]}<Icon name="chevronDown" size={13} strokeWidth={2.4} /></button>
          {sort !== 'due' && <span className="chip">{SORT_LABEL[sort]}<button type="button" aria-label="並び順を期限順に戻す" onClick={() => setPref({ taskSort: 'due' })}><Icon name="close" size={12} strokeWidth={2.6} /></button></span>}
        </div>
        </div>
        {editing && sort === 'manual' ? (
          <section className="task-section"><h2 className="section-title">並び替え</h2><div className="rows card">{take(sections.flat).map((t) => row(t))}</div></section>
        ) : (
          <>
            {editing && sort !== 'manual' && <p className="note-text">並び替えるには、並び順を「手動」にしてください。</p>}
            {unscheduledRows.length > 0 && (
              <section className="task-section" data-testid="section-unscheduled">
                <h2 className="section-title">未設定</h2>
                <div className="rows card">{unscheduledRows.map((t) => row(t, false))}</div>
              </section>
            )}
            {groupRows.map((g) => {
              const cat = group === 'category' ? categories.find((c) => c.name === g.name) : undefined;
              const isCol = collapsed.has(g.name);
              return (
                <section className="task-section" key={g.name} data-testid={`group-${g.name}`}>
                  <button type="button" className="group-head" aria-expanded={!isCol} onClick={() => setCollapsed((c) => { const n = new Set(c); if (n.has(g.name)) n.delete(g.name); else n.add(g.name); return n; })}>
                    {cat ? <EventBadge icon={cat.icon} color={cat.color} size={26} /> : <span className="group-dot" aria-hidden><Icon name={group === 'tag' ? 'tray' : group === 'date' ? 'calendar' : 'stack'} size={14} /></span>}
                    <span className="group-name">{g.name}</span>
                    <span className="group-count">{g.tasks.length}</span>
                    <Icon name="chevronRight" size={15} className={`chev ${isCol ? '' : 'rot90'}`} />
                  </button>
                  {!isCol && <div className="rows card">{g.rows.map((t) => row(t))}</div>}
                </section>
              );
            })}
            {doneRows.length > 0 && (
              <section className="task-section done" data-testid="section-done">
                <h2 className="section-title">完了済み</h2>
                <div className="rows card">{doneRows.map((t) => row(t))}</div>
              </section>
            )}
          </>
        )}
        {more}
        {sections.total === 0 && !showDone && (
          <div className="empty-list tall">
            <Icon name="checklist" size={40} strokeWidth={1.4} className="muted" />
            <p>「{SCOPE_LABEL[scope]}」{kind !== 'all' ? `・${kind === 'do' ? '実行' : '確認'}` : ''}のタスクは0件です</p>
            {(scope !== 'all' || kind !== 'all') && <button type="button" className="link-btn" onClick={() => setPref({ taskScope: 'all', taskKind: 'all' })}>絞り込みを解除</button>}
            <button type="button" className="link-btn" onClick={() => openSheet({ kind: 'edit', mode: 'task' })}>新規タスク</button>
          </div>
        )}
      </div>
      <ChoicePopup open={groupPick} title="グループ表示" value={group === 'category' ? '' : group} noneLabel="カテゴリー" onClose={() => setGroupPick(false)} onPick={(g) => { setGroupPick(false); void repo.updateSettings({ taskGroup: (g || 'category') as TaskGroup }); }}
        items={[{ value: 'tag', label: 'タグ', sub: '複数のタグがあるタスクは、それぞれのタグに表示' }, { value: 'date', label: '日付', sub: '期限切れ・今日・明日・7日以内・それ以降' }]} testId="group-popup" />
      {/* 複数選択の操作バー（下部に浮かぶガラス：Q39） */}
      <AnimatePresence>
        {editing && selected.size > 0 && (
          <motion.div className="multi-bar glass" initial={{ y: 40, opacity: 0 }} animate={{ y: 0, opacity: 1 }} exit={{ y: 40, opacity: 0 }} transition={SPRING.capsule} data-testid="multi-bar">
            <span className="muted">{selected.size}件を選択</span>
            <button type="button" className="gpill glass-i" onClick={() => void bulk('done')}><Icon name="check" size={16} />完了</button>
            <button type="button" className="gpill glass-i danger" onClick={() => void bulk('delete')}><Icon name="trash" size={16} />削除</button>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}
