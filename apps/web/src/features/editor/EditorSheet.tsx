import { useEffect, useMemo, useRef, useState } from 'react';
import {
  addDays, checkPlacement, crossesDate, DEFAULT_TASK_ICON, expandAll, placementItems, defaultCalendarIcon, expandEvent, formatHm, HOUR, makeEvent, makeTask, newId, parseOccurrenceId, previewConversion, resolveItemIcon, startOfDay,
  type Attachment, type CalEvent, type ClassAssignment, type ClassQuiz, type LinkValue, type PlaceValue, type RecurrenceRule, type SpecialKind, type Task, type TaskKind,
} from '@my-time/domain';
import { Sheet } from '../../components/Sheet';
import { Icon, type IconName } from '../../components/Icon';
import { Toggle } from '../../components/Controls';
import { useData, useSync } from '../../app/data';
import { usePlacementGuard } from '../../app/usePlacementGuard';
import { useUIActions, useUIDates, useUI } from '../../app/ui';
import { db } from '../../data/db';
import { repo } from '../../data/repo';
import { api } from '../../sync/api';
import { useAskScope } from '../timeline/useTimelineActions';
import { Popup } from '../../ui/Popup';
import { KindButtons } from '../../ui/KindButtons';
import { EventBadge, TaskBadge } from '../../components/Identity';
import { ColorStrip, DatePickerPopup, describeRule, IconStrip, NotifyPopup, notifySummary, RecurrencePopup, TimeWheelPopup } from './pickers';
import { PlaceTravelPopup, placeSummary } from './place';
import { ChoicePopup, normalizeTags, PriorityButtons, PRIO_TONE, TagInput } from './inputs';
import { StudioFieldsForm } from '../studio/StudioFieldsForm';

type Page = 'basic' | 'option' | 'special';
const pad = (n: number) => String(n).padStart(2, '0');
const fmtDate = (t: number) => { const d = new Date(t); return `${d.getMonth() + 1}月${d.getDate()}日（${'日月火水木金土'[d.getDay()]}）`; };
const fmtTime = (t: number) => { const d = new Date(t); return `${pad(d.getHours())}:${pad(d.getMinutes())}`; };

/** 次のきりのよい時刻（その日の範囲内） */
export function defaultStartFor(day: number, now: number): number {
  const base = startOfDay(day) === startOfDay(now) ? now : startOfDay(day) + 9 * HOUR;
  const d = new Date(base);
  d.setMinutes(d.getMinutes() > 0 ? 60 : 0, 0, 0);
  return d.getTime();
}

function Row({ icon, color, label, children, onClick, testId, expanded }: { icon: IconName; color: string; label: string; children?: React.ReactNode; onClick?: () => void; testId?: string; expanded?: boolean }) {
  const inner = (
    <>
      <span className="ed-row-icon" style={{ background: color }} aria-hidden><Icon name={icon} size={17} strokeWidth={2.1} /></span>
      <span className="ed-row-label">{label}</span>
      <span className="ed-row-value">{children}</span>
      {onClick && <Icon name="chevronRight" size={16} className="chev" />}
    </>
  );
  return onClick ? <button type="button" className="ed-row" onClick={onClick} data-testid={testId} aria-expanded={expanded}>{inner}</button> : <div className="ed-row" data-testid={testId}>{inner}</div>;
}

/**
 * 日時の行（C09）：ラベル・日付ボタン・時刻ボタンの3役。幅が足りれば1行、足りなければ「ラベル」と「日付・時刻」の2段。
 * 判定は端末名ではなく行の実幅（コンテナクエリ）。日付・時刻は折り返さず、各ボタンは44px以上。
 */
function DateTimeRow({ icon, label, date, time, onDate, onTime, danger, testIds }: { icon: IconName; label: string; date: string; time?: string | null; onDate: () => void; onTime?: () => void; danger?: boolean; testIds: [string, string?] }) {
  return (
    <div className="ed-dt">
      <div className="ed-dt-in">
        <span className="ed-row-icon" style={{ background: '#0A84FF' }} aria-hidden><Icon name={icon} size={17} strokeWidth={2.1} /></span>
        <span className="ed-dt-label">{label}</span>
        <span className="ed-dt-values">
          <button type="button" className={`ed-chipbtn ${danger ? 'danger' : ''}`} onClick={onDate} aria-label={`${label}の日付 ${date}`} data-testid={testIds[0]}>{date}</button>
          {time != null && onTime && <button type="button" className={`ed-chipbtn time ${danger ? 'danger' : ''}`} onClick={onTime} aria-label={`${label}の時刻 ${time}`} data-testid={testIds[1]}>{time}</button>}
        </span>
      </div>
    </div>
  );
}

interface Draft {
  mode: 'event' | 'task';
  title: string;
  icon: string;
  color: string | null;
  start: number;
  end: number;
  allDay: boolean;
  timed: boolean;
  taskKind: TaskKind;
  checkAt: number | null;
  estimate: number | null;
  rule: RecurrenceRule | null;
  calendarId: string;
  taskCalendarId: string;
  category: string;
  special: SpecialKind;
  asgContent: string; asgMethod: string; asgTo: string; asgDeadline: number | null;
  examAt: number | null; prepSubject: string;
  subjectName: string; subjectId: string | null; room: string; assignments: ClassAssignment[]; quizzes: ClassQuiz[]; employerId: string | null;
  hideAfterEnd: boolean;
  place: PlaceValue | null; travelMinutes: number | null; meetingUrl: string; notifies: number[]; urls: LinkValue[]; attachments: Attachment[];
  notes: string;
  priority: 0 | 1 | 2 | 3; flagged: boolean; tags: string[];
  studioTypeId: string | null; studioValues: Record<string, unknown>;
}

/**
 * 共通の作成・編集シート（Q38・Q62〜81）。
 * - ＋から直接開き、最上部で予定／タスクを切り替える（入力値は保持：Q63・Q77）
 * - 下部のガラスタブで「基本」「オプション」「専用」（専用は種類があるときだけ：Q64・Q70）
 * - 未保存で閉じると確認。入力は端末に下書き保存し、次に開いたとき復元できる（Q81）
 */
export function EditorSheet({ mode: initialMode, id, defaults, depth }: { mode: 'event' | 'task'; id?: string; defaults?: Record<string, unknown>; depth: number }) {
  const { events, tasks, calendars, calendarById, subjects, employers, settings, categories, studioTypes } = useData();
  const sync = useSync();
  const { homeDate, calDate } = useUIDates();
  const { tab } = useUI();
  const { closeSheet, confirm, choose, showToast, openSheet } = useUIActions();
  const guard = usePlacementGuard();
  const askScope = useAskScope();

  const occ = id && initialMode === 'event' ? parseOccurrenceId(id) : null;
  const exEvent = initialMode === 'event' && id ? events.find((e) => e.id === (occ?.masterId ?? id)) : undefined;
  const exTask = initialMode === 'task' && id ? tasks.find((t) => t.id === id) : undefined;
  const instance = useMemo(() => (exEvent && occ ? expandEvent(exEvent, occ.originalStart - 8 * 86_400_000, occ.originalStart + 8 * 86_400_000).find((o) => o.id === id) : undefined), [exEvent, occ?.originalStart, id]); // eslint-disable-line react-hooks/exhaustive-deps
  const isNew = !exEvent && !exTask;
  const draftKey = `edit:${initialMode}:${id ?? 'new'}`;

  const initial = useMemo<Draft>(() => {
    const d = defaults ?? {};
    const baseDay = tab === 'calendar' ? calDate : homeDate;
    const s0 = (instance?.start ?? exEvent?.start ?? exTask?.plannedStart ?? (d.start as number | undefined) ?? (d.plannedStart as number | undefined) ?? defaultStartFor(baseDay, Date.now()));
    const e0 = (instance?.end ?? exEvent?.end ?? exTask?.plannedEnd ?? (d.end as number | undefined) ?? (d.plannedEnd as number | undefined) ?? s0 + HOUR);
    const x = exEvent?.extra ?? exTask?.extra ?? {};
    const cal0 = exEvent?.calendarId ?? (d.calendarId as string | undefined) ?? calendars[0]?.id ?? 'cal-general';
    return {
      mode: initialMode,
      title: instance?.title ?? exEvent?.title ?? exTask?.title ?? (d.title as string | undefined) ?? '',
      icon: exTask?.icon ?? (d.icon as string | undefined) ?? (initialMode === 'event' ? resolveItemIcon(calendarById.get(cal0)?.icon, defaultCalendarIcon(calendarById.get(cal0)?.kind ?? 'general')).id : DEFAULT_TASK_ICON),
      color: x.color ?? null,
      start: s0, end: e0 > s0 ? e0 : s0 + HOUR,
      allDay: x.allDay ?? false,
      timed: exTask ? exTask.plannedStart != null : d.plannedStart !== null,
      taskKind: exTask?.kind ?? (d.kind as TaskKind | undefined) ?? 'do',
      checkAt: exTask?.checkAt ?? null,
      estimate: exTask?.estimateMinutes ?? null,
      rule: exEvent?.recurrence ?? (exTask?.repeat ? { freq: exTask.repeat.freq, interval: exTask.repeat.interval, byWeekday: null, until: null } : null),
      calendarId: cal0,
      taskCalendarId: exTask?.calendarId ?? '',
      category: exTask?.category ?? '',
      special: exTask?.special ?? (d.special as SpecialKind | undefined) ?? 'normal',
      asgContent: exTask?.assignment?.content ?? '', asgMethod: exTask?.assignment?.submitMethod ?? '', asgTo: exTask?.assignment?.submitTo ?? '', asgDeadline: exTask?.assignment?.deadline ?? null,
      examAt: exTask?.testPrep?.examAt ?? null, prepSubject: exTask?.testPrep?.subjectName ?? '',
      subjectName: exEvent?.classInfo?.subjectName ?? '', subjectId: exEvent?.classInfo?.subjectId ?? null, room: exEvent?.classInfo?.room ?? '',
      assignments: exEvent?.classInfo?.assignments ?? [], quizzes: exEvent?.classInfo?.quizzes ?? [], employerId: exEvent?.employerId ?? employers[0]?.id ?? null,
      hideAfterEnd: exEvent?.hideAfterEnd ?? false,
      place: x.place ?? (exTask?.location ? { name: exTask.location, address: '', lat: null, lng: null } : null),
      travelMinutes: x.travelMinutes ?? null, meetingUrl: x.meetingUrl ?? '',
      notifies: x.notifies ?? (exTask?.notifyMinutesBefore != null ? [exTask.notifyMinutesBefore] : isNew && initialMode === 'task' && settings.defaultNotifyMinutes != null ? [settings.defaultNotifyMinutes] : []),
      urls: x.urls ?? [], attachments: x.attachments ?? [],
      notes: instance?.notes ?? exEvent?.notes ?? exTask?.notes ?? '',
      priority: exTask?.priority ?? 0, flagged: exTask?.flagged ?? false, tags: exTask?.tags ?? [],
      studioTypeId: x.studio?.typeId ?? (initialMode === 'event' ? calendarById.get(cal0)?.studioTypeId ?? null : null), studioValues: x.studio?.values ?? {},
    };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const [v, setV] = useState<Draft>(initial);
  const set = <K extends keyof Draft>(k: K, val: Draft[K]) => setV((o) => ({ ...o, [k]: val }));
  const dirty = JSON.stringify(v) !== JSON.stringify(initial);
  const [page, setPage] = useState<Page>('basic');
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [restorable, setRestorable] = useState<Draft | null>(null);
  const [pick, setPick] = useState<null | 'sDate' | 'sTime' | 'eDate' | 'eTime' | 'cDate' | 'cTime' | 'rule' | 'notify' | 'place' | 'type' | 'category' | 'calendar' | 'asgDate' | 'examDate'>(null);
  const scrollMem = useRef<Record<Page, number>>({ basic: 0, option: 0, special: 0 });

  // 下書き：開いたときに前回の未保存入力があれば復元を提案。入力中は少し待って保存（Q81）
  useEffect(() => { void repo.getDraft(draftKey).then((d) => { if (d && Date.now() - d.at < 7 * 86_400_000 && JSON.stringify(d.data) !== JSON.stringify(initial)) setRestorable(d.data as unknown as Draft); }); }, []); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (!dirty) return;
    const t = window.setTimeout(() => void repo.saveDraft(draftKey, v as unknown as Record<string, unknown>), 600);
    return () => window.clearTimeout(t);
  }, [v, dirty, draftKey]);

  const calendar = calendarById.get(v.calendarId);
  const evKind = calendar?.kind ?? 'general';
  const studioType = v.studioTypeId ? studioTypes.find((t) => t.id === v.studioTypeId) : undefined;
  const hasSpecial = v.mode === 'event' ? evKind === 'class' || evKind === 'job' || !!studioType : v.special !== 'normal' || !!studioType;
  const typeLabel = v.mode === 'event' ? calendar?.name ?? '一般' : studioType?.name ?? { normal: '一般', assignment: '課題', testPrep: 'テスト対策' }[v.special];
  const previewColor = v.color ?? (v.mode === 'event' ? calendar?.color : studioType?.color) ?? '#0A84FF';

  const switchPage = (p: Page) => {
    const body = document.querySelector(`[data-testid="editor-sheet"] .sheet-body`) as HTMLElement | null;
    if (body) scrollMem.current[page] = body.scrollTop;
    setPage(p);
    requestAnimationFrame(() => { if (body) body.scrollTop = scrollMem.current[p]; });
  };
  useEffect(() => { if (!hasSpecial && page === 'special') setPage('basic'); }, [hasSpecial, page]);

  // 開始を動かしたら長さを保って終了も動かす（Q67・Q72）。終了だけ動かしたら長さが変わる
  // 入力中も重なりを表示（保存時には改めてアラートで確認する。既存の予定は動かさない）
  const timedRange = (v.mode === 'event' && !v.allDay) || (v.mode === 'task' && v.taskKind === 'do' && v.timed);
  const { conflicts, suggestion } = useMemo(() => {
    if (!timedRange || v.end <= v.start) return { conflicts: [], suggestion: null };
    const target = { id: v.mode === 'event' ? `event:${id ?? '__new'}` : `task:${id ?? '__new'}`, start: v.start, end: v.end };
    const around = expandAll(events, v.start - 2 * 86_400_000, v.end + 3 * 86_400_000);
    return checkPlacement(target, placementItems(around, tasks));
  }, [timedRange, v.start, v.end, v.mode, events, tasks, id]);
  const moveStart = (ns: number) => setV((o) => ({ ...o, start: ns, end: ns + Math.max(15 * 60_000, o.end - o.start) }));
  const setTime = (base: number, t: number) => { const a = new Date(base); const b = new Date(t); a.setHours(b.getHours(), b.getMinutes(), 0, 0); return a.getTime(); };
  const setDay = (base: number, day: number) => { const a = new Date(base); const b = new Date(day); a.setFullYear(b.getFullYear(), b.getMonth(), b.getDate()); return a.getTime(); };

  const permission = typeof Notification === 'undefined' ? 'unsupported' : Notification.permission;

  const remember = async () => {
    const icons = [v.icon, ...settings.recentIcons.filter((x) => x !== v.icon)].slice(0, 12);
    const colors = v.color ? [v.color, ...settings.recentColors.filter((x) => x !== v.color)].slice(0, 8) : settings.recentColors;
    const places = v.place ? [v.place, ...settings.placeHistory.filter((p) => p.name !== v.place!.name || p.address !== v.place!.address)].slice(0, 20) : settings.placeHistory;
    await repo.updateSettings({ recentIcons: icons, recentColors: colors, placeHistory: places });
  };

  const extra = (prev: CalEvent['extra'] | Task['extra']) => ({
    ...(prev ?? {}),
    ...(v.mode === 'event' ? { allDay: v.allDay } : {}),
    color: v.color,
    place: v.place,
    travelMinutes: v.travelMinutes,
    meetingUrl: v.meetingUrl.trim() || null,
    notifies: v.notifies,
    urls: v.urls.filter((u) => u.url.trim()),
    attachments: v.attachments,
    studio: studioType ? { typeId: studioType.id, version: studioType.version, values: v.studioValues } : prev?.studio && !v.studioTypeId ? null : prev?.studio ?? null,
  });

  const save = async () => {
    setError(null);
    if (!v.title.trim()) { setPage('basic'); return setError('タイトルを入力してください'); }
    // Studio の必須項目・数値範囲（Q107）
    if (studioType) {
      for (const f of studioType.fields.filter((x) => !x.hidden)) {
        const val = v.studioValues[f.id];
        if (f.required && (val == null || val === '' || (Array.isArray(val) && !val.length))) { setPage('special'); return setError(`「${f.label}」を入力してください`); }
        if (typeof val === 'number' && ((f.min != null && val < f.min) || (f.max != null && val > f.max))) { setPage('special'); return setError(`「${f.label}」は${f.min ?? ''}〜${f.max ?? ''}の範囲で入力してください`); }
      }
    }
    setSaving(true);
    try {
      if (v.mode === 'event') await saveEvent();
      else await saveTask();
    } finally { setSaving(false); }
  };

  const allDayRange = () => { const s = startOfDay(v.start); const e = Math.max(s + 86_400_000, startOfDay(v.end) + 86_400_000); return { start: s, end: e }; };

  const saveEvent = async () => {
    const r0 = v.allDay ? allDayRange() : { start: v.start, end: v.end };
    if (r0.end <= r0.start) return setError('終了は開始より後にしてください');
    if (v.rule?.freq === 'weekly' && !v.rule.byWeekday?.length) return setError('繰り返す曜日を選んでください');
    let { start, end } = r0;
    const changed = isNew || !exEvent || (instance?.start ?? exEvent.start) !== start || (instance?.end ?? exEvent.end) !== end;
    if (!v.allDay && changed) {
      const decision = await guard({ id: `event:${id ?? '__new'}`, start, end }, '保存');
      if (!decision) return;
      ({ start, end } = decision);
    }
    const classInfo = evKind === 'class' ? { subjectId: v.subjectId, subjectName: v.subjectName.trim() || v.title.trim(), room: v.room.trim(), assignments: v.assignments, quizzes: v.quizzes } : null;
    const crossing = crossesDate({ start, end });
    const fields = { title: v.title.trim(), calendarId: v.calendarId, start, end, notes: v.notes, recurrence: v.rule, classInfo, employerId: evKind === 'job' ? v.employerId : null, hideAfterEnd: crossing && !v.rule ? v.hideAfterEnd : false, extra: extra(exEvent?.extra) };
    try {
      let createTasks = false;
      if (classInfo) {
        const mid = exEvent?.id ?? '';
        const made = new Set(tasks.filter((t) => t.sourceEventId === mid).map((t) => t.sourceKey));
        const fresh = [...classInfo.assignments.map((a) => `class:${mid}:assignment:${a.key}`), ...classInfo.quizzes.map((q) => `class:${mid}:quiz:${q.key}`)].filter((k) => !made.has(k));
        if (fresh.length) createTasks = await confirm({ title: '課題・テスト対策のタスクを作成しますか？', message: `${fresh.length}件をタスク一覧に追加します。作業時間が未入力のものは「未設定」に入ります。`, confirmLabel: '作成', cancelLabel: '作成しない' });
      }
      if (!exEvent) {
        const r = await repo.saveEventWithClassTasks(makeEvent(fields, Date.now()), true, createTasks);
        showToast(r.created ? `予定とタスク${r.created}件を追加しました` : '予定を追加しました');
      } else if (occ && exEvent.recurrence) {
        const ruleChanged = JSON.stringify(v.rule) !== JSON.stringify(exEvent.recurrence);
        const scope = ruleChanged ? 'future' : await askScope('変更');
        if (!scope) return;
        await repo.editOccurrence(exEvent.id, occ.originalStart, scope === 'this' ? { start, end, title: fields.title, notes: v.notes } : fields, scope);
        showToast('保存しました');
      } else {
        const r = await repo.saveEventWithClassTasks({ ...exEvent, ...fields }, false, createTasks);
        showToast(r.created ? `保存し、タスク${r.created}件を追加しました` : '保存しました');
      }
      await finish();
    } catch (e) { setError(e instanceof Error ? e.message : '保存できませんでした（入力は残っています）'); }
  };

  const saveTask = async () => {
    const isDo = v.taskKind === 'do';
    let ps = isDo && v.timed ? v.start : null;
    let pe = isDo && v.timed ? v.end : null;
    if (ps != null && pe != null && pe <= ps) return setError('終了は開始より後にしてください');
    if (ps != null && pe != null && (!exTask || exTask.plannedStart !== ps || exTask.plannedEnd !== pe)) {
      const decision = await guard({ id: `task:${exTask?.id ?? '__new'}`, start: ps, end: pe }, '保存');
      if (!decision) return;
      [ps, pe] = [decision.start, decision.end];
    }
    const fields: Partial<Task> = {
      title: v.title.trim(), icon: v.icon, calendarId: v.taskCalendarId || null, category: v.category.trim() || null, notes: v.notes, special: v.special,
      assignment: v.special === 'assignment' ? { content: v.asgContent.trim(), submitMethod: v.asgMethod.trim(), submitTo: v.asgTo.trim(), deadline: v.asgDeadline } : null,
      testPrep: v.special === 'testPrep' ? { examAt: v.examAt, subjectId: subjects.find((x) => x.name === v.prepSubject.trim())?.id ?? null, subjectName: v.prepSubject.trim() } : null,
      estimateMinutes: v.estimate != null ? Math.max(1, Math.min(10_000, Math.round(v.estimate))) : null,
      priority: v.priority, flagged: v.flagged,
      tags: normalizeTags(v.tags),
      notifyMinutesBefore: v.notifies[0] ?? null,
      location: v.place?.name ?? null,
      repeat: v.rule ? { freq: v.rule.freq, interval: v.rule.interval } : null,
      extra: extra(exTask?.extra),
      ...(isDo ? { plannedStart: ps, plannedEnd: pe } : { checkAt: v.checkAt }),
    };
    try {
      if (!exTask) {
        await repo.saveTask(makeTask({ ...(defaults as Partial<Task> | undefined), ...fields, title: v.title.trim(), kind: v.taskKind }, Date.now()), true);
        showToast('タスクを追加しました');
      } else {
        if (exTask.kind !== v.taskKind) {
          const pv = previewConversion(exTask, v.taskKind);
          if (!(await confirm({ title: v.taskKind === 'check' ? '確認タスクに変更しますか？' : '実行タスクに変更しますか？', message: pv.warnings.join('\n') || '実績の記録は保持されます。', confirmLabel: '変更' }))) return;
          await repo.convertTask(exTask.id, v.taskKind);
        }
        // 親の日時を動かしたとき、日時のあるサブタスクをどうするか明示的に選ぶ（C07）。取消なら何も保存しない
        const delta = isDo && exTask.plannedStart != null && ps != null ? ps - exTask.plannedStart : 0;
        const timedSubs = delta ? (await db.subtasks.where('taskId').equals(exTask.id).toArray()).filter((x) => x.plannedStart != null).length : 0;
        let moveSubs = false;
        if (timedSubs) {
          const c = await choose({ title: 'サブタスクの日時', message: `日時を設定したサブタスクが${timedSubs}件あります。`, actions: [{ label: '同じだけ一緒に移動', value: 'move' }, { label: 'サブタスクの日時はそのまま', value: 'keep' }, { label: 'キャンセル', value: 'cancel', style: 'cancel' }] });
          if (c == null || c === 'cancel') return;
          moveSubs = c === 'move';
        }
        const fresh = (await db.tasks.get(exTask.id)) ?? exTask;
        await repo.saveTask({ ...fresh, ...fields }, false);
        if (moveSubs) await repo.shiftSubtaskTimes(exTask.id, delta);
        showToast('保存しました');
      }
      await finish();
    } catch (e) { setError(e instanceof Error ? e.message : '保存できませんでした（入力は残っています）'); }
  };

  const finish = async () => {
    await repo.clearDraft(draftKey);
    await remember();
    closeSheet();
  };
  // 「キャンセル」でも未保存の変更があれば確認する（下へ引いて閉じるときと同じ）
  const close = async () => {
    if (dirty && !(await confirm({ title: '変更を破棄しますか？', message: '保存していない変更があります。', confirmLabel: '変更を破棄', cancelLabel: '編集を続ける', destructive: true }))) return;
    await discardAndClose();
  };
  // シート側（下へ引く・Esc）は確認済みで呼ばれる
  const discardAndClose = async () => { await repo.clearDraft(draftKey); closeSheet(); };

  // 種類の切替（予定⇔タスク）：共通の値はそのまま。専用の値も保持し、戻せば復元（Q63・Q77）
  const switchMode = (m: 'event' | 'task') => {
    if (m === v.mode) return;
    if (!isNew) return showToast('保存済みの予定とタスクは種類を変えられません');
    setV((o) => ({ ...o, mode: m, studioTypeId: m === 'event' ? calendarById.get(o.calendarId)?.studioTypeId ?? null : null }));
  };

  // 添付（Q80）：Google ドライブへ保存。ログインしていなければ案内
  const fileRef = useRef<HTMLInputElement>(null);
  const [uploading, setUploading] = useState(false);
  const addFiles = async (files: FileList | null) => {
    if (!files?.length) return;
    if (!sync.me) return showToast('添付するには Google でログインしてください');
    setUploading(true);
    try {
      for (const f of [...files].slice(0, 10)) {
        if (!/^(image\/|application\/pdf$)/.test(f.type)) { showToast('画像またはPDFだけを添付できます'); continue; }
        if (f.size > 10 * 1024 * 1024) { showToast(`${f.name} は10MBを超えています`); continue; }
        const buf = await f.arrayBuffer();
        const hash = [...new Uint8Array(await crypto.subtle.digest('SHA-256', buf))].map((b) => b.toString(16).padStart(2, '0')).join('');
        const driveFileId = await api.uploadAttachment(f, f.name);
        setV((o) => ({ ...o, attachments: [...o.attachments, { id: newId(), name: f.name.slice(0, 255), mime: f.type, size: f.size, driveFileId, sha256: hash, createdAt: Date.now() }].slice(0, 30) }));
      }
    } catch (e) { showToast(e instanceof Error ? e.message : '添付できませんでした'); } finally { setUploading(false); if (fileRef.current) fileRef.current.value = ''; }
  };
  const removeAttachment = async (a: Attachment) => {
    // 外すのはこの予定・タスクからの参照だけ。ドライブのファイル本体は消さない（C24）
    if (!(await confirm({ title: '添付を外しますか？', message: `「${a.name}」をこの${v.mode === 'event' ? '予定' : 'タスク'}から外します。Googleドライブのファイルは残ります。`, confirmLabel: '外す' }))) return;
    set('attachments', v.attachments.filter((x) => x.id !== a.id));
  };

  const remove = async () => {
    if (exEvent) {
      if (occ && exEvent.recurrence) {
        const scope = await askScope('削除');
        if (!scope) return;
        await repo.deleteOccurrence(exEvent.id, occ.originalStart, scope);
      } else {
        if (!(await confirm({ title: '予定を削除しますか？', message: `「${exEvent.title}」を削除します。`, confirmLabel: '削除', destructive: true }))) return;
        await repo.deleteEvent(exEvent.id);
      }
    } else if (exTask) {
      if (!(await confirm({ title: 'タスクを削除しますか？', message: `「${exTask.title}」とサブタスク、実績が削除されます。`, confirmLabel: '削除', destructive: true }))) return;
      await repo.deleteTask(exTask.id);
    }
    await repo.clearDraft(draftKey);
    closeSheet();
    showToast('削除しました');
  };

  const tabs: { id: Page; label: string }[] = [{ id: 'basic', label: '基本' }, { id: 'option', label: 'オプション' }, ...(hasSpecial ? [{ id: 'special' as Page, label: typeLabel }] : [])];
  const swipe = useRef<{ x: number; y: number } | null>(null);

  return (
    <Sheet
      onClose={() => void discardAndClose()}
      depth={depth}
      dirty={dirty}
      testId="editor-sheet"
      title={isNew ? '新規作成' : v.mode === 'event' ? '予定を編集' : 'タスクを編集'}
      left={<button type="button" className="bar-btn" onClick={() => void close()}>キャンセル</button>}
      right={<button type="button" className="gbtn-primary glass-i" onClick={() => void save()} aria-busy={saving} disabled={saving} data-testid="editor-save">{saving ? '保存中…' : isNew ? '追加' : '保存'}</button>}
      footer={
        <div className="ed-tabs glass" role="tablist" aria-label="編集の項目">
          {tabs.map((t) => <button key={t.id} type="button" role="tab" aria-selected={page === t.id} onClick={() => switchPage(t.id)} className="glass-i" data-testid={`editor-tab-${t.id}`}>{t.label}</button>)}
        </div>
      }
    >
      <div
        onPointerDown={(e) => { if (!(e.target as Element).closest('input, textarea, .hstrip, .wheel')) swipe.current = { x: e.clientX, y: e.clientY }; }}
        onPointerUp={(e) => {
          const s = swipe.current; swipe.current = null;
          if (!s || Math.abs(e.clientX - s.x) < 70 || Math.abs(e.clientY - s.y) > 40) return;
          const i = tabs.findIndex((t) => t.id === page) + (e.clientX < s.x ? 1 : -1);
          if (tabs[i]) switchPage(tabs[i]!.id);
        }}
      >
        {isNew && (
          <div className="ed-top">
            <div className="ed-seg glass" role="group" aria-label="作成する種類">
              <button type="button" aria-pressed={v.mode === 'event'} onClick={() => switchMode('event')} data-testid="editor-mode-event">予定</button>
              <button type="button" aria-pressed={v.mode === 'task'} onClick={() => switchMode('task')} data-testid="editor-mode-task">タスク</button>
            </div>
          </div>
        )}
        {restorable && (
          <div className="banner-inline" role="status">
            <span>前回の入力が残っています</span>
            <button type="button" className="link-btn" onClick={() => { setV(restorable); setRestorable(null); }} data-testid="restore-draft">復元</button>
            <button type="button" className="link-btn muted" onClick={() => { setRestorable(null); void repo.clearDraft(draftKey); }}>破棄</button>
          </div>
        )}
        <div className="ed-preview">
          {v.mode === 'task' ? <TaskBadge icon={v.icon} kind={v.taskKind} size={48} /> : <EventBadge icon={v.icon} color={previewColor} size={48} />}
          <input className="ed-title" value={v.title} onChange={(e) => set('title', e.target.value)} placeholder={v.mode === 'event' ? '予定のタイトル' : 'タスクのタイトル'} aria-label="タイトル" autoFocus={isNew} data-testid="editor-title" />
        </div>

        {/* ---------------- 基本 ---------------- */}
        <div className="ed-page" hidden={page !== 'basic'} data-testid="editor-page-basic">
          <div className="group"><div className="group-body">
            <Row icon="stack" color="#8E8E93" label="種類" onClick={() => setPick('type')} testId="editor-type">{typeLabel}</Row>
            {v.mode === 'task' && (
              <div className="row ed-kind-row">
                <KindButtons
                  label="タスクの種類"
                  value={v.taskKind}
                  onChange={(k) => set('taskKind', k)}
                  options={[{ value: 'do', label: '実行', tone: 'do', icon: 'play', testId: 'editor-kind-do' }, { value: 'check', label: '確認', tone: 'check', icon: 'check', testId: 'editor-kind-check' }]}
                />
              </div>
            )}
          </div></div>

          <div className="group"><div className="group-body">
            {v.mode === 'event' && (
              <Row icon="today" color="#FF9500" label="終日"><Toggle label="終日" checked={v.allDay} onChange={(b) => set('allDay', b)} /></Row>
            )}
            {v.mode === 'task' && v.taskKind === 'do' && (
              <Row icon="clock" color="#FF9500" label="日時を指定"><Toggle label="日時を指定" checked={v.timed} onChange={(b) => set('timed', b)} /></Row>
            )}
            {(v.mode === 'event' || (v.taskKind === 'do' && v.timed)) && (
              <>
                <DateTimeRow icon="play" label="開始" date={fmtDate(v.start)} time={!(v.mode === 'event' && v.allDay) ? fmtTime(v.start) : null} onDate={() => setPick('sDate')} onTime={() => setPick('sTime')} testIds={['editor-start-date', 'editor-start-time']} />
                <DateTimeRow icon="flag" label="終了" date={fmtDate(v.end)} time={!(v.mode === 'event' && v.allDay) ? fmtTime(v.end) : null} onDate={() => setPick('eDate')} onTime={() => setPick('eTime')} danger={v.end <= v.start} testIds={['editor-end-date', 'editor-end-time']} />
              </>
            )}
            {conflicts.length > 0 && (
              <div className="conflict" role="status" data-testid="conflict-warning">
                <Icon name="info" size={18} />
                <div>
                  <div>「{conflicts[0]!.title}」{conflicts.length > 1 ? `など${conflicts.length}件` : ''}と時間が重なっています。保存前に確認します。</div>
                  {suggestion && <button type="button" className="link-btn" onClick={() => setV((o) => ({ ...o, start: suggestion.start, end: suggestion.end }))}>{formatHm(suggestion.start)}〜{formatHm(suggestion.end)} に変更する</button>}
                  <div className="conflict-note">既存の予定は自動で移動しません。</div>
                </div>
              </div>
            )}
            {v.mode === 'task' && v.taskKind === 'check' && (
              <DateTimeRow icon="check" label="確認日時" date={v.checkAt != null ? fmtDate(v.checkAt) : '未設定'} time={v.checkAt != null ? fmtTime(v.checkAt) : null} onDate={() => setPick('cDate')} onTime={() => setPick('cTime')} testIds={['editor-check-date', 'editor-check-time']} />
            )}
            <Row icon="undo" color="#5E5CE6" label="繰り返し" onClick={() => setPick('rule')} testId="editor-repeat">{describeRule(v.rule)}</Row>
            {v.mode === 'task' && (
              <Row icon="clock" color="#30B0C7" label="見積時間">
                <span className="dur-inputs"><label><input type="number" inputMode="numeric" min={1} max={10000} value={v.estimate ?? ''} placeholder="" onChange={(e) => set('estimate', e.target.value === '' ? null : Number(e.target.value))} aria-label="見積時間（分）" data-testid="editor-estimate" />分</label></span>
              </Row>
            )}
          </div>
          {v.end <= v.start && (v.mode === 'event' || v.timed) && <div className="ed-section-note form-error">終了は開始より後にしてください</div>}
          </div>

          {/* 場所と移動・通知は基本タブ（C14・C23）。オプションには重複して置かない */}
          <div className="group"><div className="group-body">
            <Row icon="pin" color="#FF3B30" label="場所と移動" onClick={() => setPick('place')} testId="editor-place">{placeSummary(v.place, v.travelMinutes)}</Row>
            <Row icon="bell" color="#FF2D55" label="通知" onClick={() => setPick('notify')} testId="editor-notify">{notifySummary(v.notifies)}</Row>
          </div>
          {v.mode === 'task' && ((v.taskKind === 'do' && !v.timed) || (v.taskKind === 'check' && v.checkAt == null)) && <div className="group-footer">日時を設定すると、通知を受け取れます。</div>}
          </div>

          <div className="group-header">アイコン</div>
          <div className="group"><div className="group-body"><IconStrip value={v.icon} onChange={(id) => set('icon', id)} recent={settings.recentIcons} target={v.mode} /></div></div>
          <div className="group-header">色</div>
          <div className="group"><div className="group-body"><ColorStrip value={v.color} onChange={(c) => set('color', c)} recent={settings.recentColors} /></div></div>
          {error && <p className="form-error" role="alert">{error}</p>}
        </div>

        {/* ---------------- オプション ---------------- */}
        <div className="ed-page" hidden={page !== 'option'} data-testid="editor-page-option">
          <div className="group"><div className="group-body">
            <Row icon="link" color="#5E5CE6" label="会議URL">
              <input className="row-input right" type="url" inputMode="url" value={v.meetingUrl} onChange={(e) => set('meetingUrl', e.target.value)} placeholder="" aria-label="オンライン会議のURL" />
            </Row>
          </div>
          {v.meetingUrl && !/^https?:\/\//.test(v.meetingUrl.trim()) && <div className="ed-section-note form-error">https:// から始まるURLを入力してください</div>}
          </div>

          {v.mode === 'task' && (
            <>
              <div className="group-header">整理</div>
              <div className="group"><div className="group-body">
                <Row icon="tray" color="#A2845E" label="カテゴリー" onClick={() => setPick('category')} testId="editor-category">{v.category || 'なし'}</Row>
                <Row icon="calendar" color="#0A84FF" label="カレンダー" onClick={() => setPick('calendar')} testId="editor-task-calendar">{calendars.find((c) => c.id === v.taskCalendarId)?.name ?? 'なし'}</Row>
                <div className="ed-row ed-row-stack">
                  <span className="ed-row-head"><span className="ed-row-icon" style={{ background: PRIO_TONE(v.priority) === 'var(--label-2)' ? '#8E8E93' : PRIO_TONE(v.priority) }} aria-hidden><Icon name="exclamation" size={17} strokeWidth={2.1} /></span><span className="ed-row-label">優先度</span></span>
                  <PriorityButtons value={v.priority} onChange={(p) => set('priority', p)} />
                </div>
                <Row icon="flag" color="#FF9500" label="フラグ"><Toggle label="フラグ" checked={v.flagged} onChange={(b) => set('flagged', b)} /></Row>
              </div></div>
              <div className="group-header">タグ</div>
              <div className="group"><div className="group-body">
                <TagInput value={v.tags} onChange={(t) => set('tags', t)} />
              </div></div>
            </>
          )}

          <div className="group-header">メモ</div>
          <div className="group"><div className="group-body">
            <textarea className="row-input notes-input" value={v.notes} onChange={(e) => set('notes', e.target.value)} placeholder="メモ" aria-label="メモ" rows={4} data-testid="editor-notes" />
          </div></div>

          {/* リンクと添付（C24）：左アイコン・中央の名前とURL・右の削除の3列。長いURLでも画面幅を広げない */}
          <div className="group-header">リンク</div>
          <div className="group"><div className="group-body">
            {v.urls.map((u, i) => {
              const bad = !!u.url.trim() && !/^https?:\/\//i.test(u.url.trim());
              return (
                <div className="link-card" key={u.id} data-testid="link-card">
                  <span className="link-ico" aria-hidden><Icon name="link" size={17} /></span>
                  <span className="link-fields">
                    <label className="sr-only" htmlFor={`ln-${u.id}`}>リンクの名前</label>
                    <input id={`ln-${u.id}`} className="link-name" value={u.title} onChange={(e) => set('urls', v.urls.map((x, j) => (j === i ? { ...x, title: e.target.value } : x)))} placeholder="名前（任意）" />
                    <label className="sr-only" htmlFor={`lu-${u.id}`}>URL</label>
                    <input id={`lu-${u.id}`} className={`link-url ${bad ? 'bad' : ''}`} type="url" inputMode="url" value={u.url} onChange={(e) => set('urls', v.urls.map((x, j) => (j === i ? { ...x, url: e.target.value } : x)))} placeholder="https://" aria-invalid={bad} />
                    {bad && <span className="form-error small">http:// または https:// から始めてください</span>}
                  </span>
                  <button type="button" className="link-del" aria-label={`リンク「${u.title || u.url || '無題'}」を外す`} onClick={() => set('urls', v.urls.filter((_, j) => j !== i))}><Icon name="close" size={14} strokeWidth={2.6} /></button>
                </div>
              );
            })}
            <button type="button" className="row row-button tint-row" onClick={() => set('urls', [...v.urls, { id: newId(), title: '', url: '' }])} data-testid="editor-add-url"><Icon name="plus" size={18} /><span className="row-label">リンクを追加</span></button>
          </div></div>

          <div className="group-header">添付ファイル（画像・PDF）</div>
          <div className="group"><div className="group-body">
            {v.attachments.map((a) => <AttachmentRow key={a.id} a={a} onRemove={() => void removeAttachment(a)} />)}
            {uploading && <div className="att-row" aria-busy="true"><span className="att-ico skel" /><span className="att-text"><strong>Googleドライブへ保存中…</strong></span></div>}
            {sync.me ? (
              <button type="button" className="row row-button tint-row" disabled={uploading} onClick={() => fileRef.current?.click()} data-testid="editor-add-file"><Icon name="plus" size={18} /><span className="row-label">ファイルを追加</span></button>
            ) : (
              <div className="att-login" data-testid="attach-login"><Icon name="cloud" size={18} /><span>添付はGoogleドライブに保存します。使うには Google でログインしてください。</span><a className="link-btn" href={api.loginUrl()}>ログイン</a></div>
            )}
            <input ref={fileRef} hidden type="file" accept="image/*,application/pdf" multiple aria-label="添付ファイル" onChange={(e) => void addFiles(e.target.files)} />
          </div>
          {sync.me && <div className="group-footer">Googleドライブの「My Time Attachments」に保存します（10MBまで）。外すと、この予定・タスクからの参照だけを外し、ドライブのファイルは残します。</div>}</div>

          {v.mode === 'event' && crossesDate({ start: v.start, end: v.end }) && !v.rule && (
            <div className="group"><div className="group-body">
              <Row icon="today" color="#8E8E93" label="終了したらすぐ隠す"><Toggle label="終了したらすぐ隠す" checked={v.hideAfterEnd} onChange={(b) => set('hideAfterEnd', b)} /></Row>
            </div><div className="group-footer">日付をまたぐ予定を、終了直後にカレンダーから隠します（バックアップ確認後に削除。「期間指定の復元」で見返せます）。</div></div>
          )}
          {!isNew && (
            <div className="group"><div className="group-body">
              {exEvent && <button type="button" className="row row-button center" onClick={() => openSheet({ kind: 'copyEvent', eventId: id! })}>別の日にコピー</button>}
              <button type="button" className="row row-button destructive center" onClick={() => void remove()} data-testid="editor-delete">{v.mode === 'event' ? '予定を削除' : 'タスクを削除'}</button>
            </div></div>
          )}
        </div>

        {/* ---------------- 専用 ---------------- */}
        <div className="ed-page" hidden={page !== 'special'} data-testid="editor-page-special">
          {v.mode === 'event' && evKind === 'class' && (
            <>
              <div className="group-header">授業</div>
              <div className="group"><div className="group-body">
                <Row icon="graduation" color="#5E5CE6" label="科目">
                  <input className="row-input right" list="ed-subjects" value={v.subjectName} placeholder={v.title || '科目名'} onChange={(e) => setV((o) => ({ ...o, subjectName: e.target.value, subjectId: subjects.find((s) => s.name === e.target.value)?.id ?? null }))} aria-label="科目" />
                  <datalist id="ed-subjects">{subjects.map((s) => <option key={s.id} value={s.name} />)}</datalist>
                </Row>
                <Row icon="house" color="#8E8E93" label="教室"><input className="row-input right" value={v.room} onChange={(e) => set('room', e.target.value)} placeholder="未入力" aria-label="教室" /></Row>
              </div></div>
              <div className="group-header">課題</div>
              <div className="group"><div className="group-body">
                {v.assignments.map((a, i) => (
                  <div className="sub-form" key={a.key} data-testid="assignment-row">
                    <input className="row-input" value={a.title} onChange={(e) => set('assignments', v.assignments.map((x, j) => (j === i ? { ...x, title: e.target.value } : x)))} placeholder="課題名" aria-label="課題名" />
                    <input className="row-input small" value={a.content} onChange={(e) => set('assignments', v.assignments.map((x, j) => (j === i ? { ...x, content: e.target.value } : x)))} placeholder="内容" aria-label="課題の内容" />
                    <button type="button" className="row row-button destructive" onClick={() => set('assignments', v.assignments.filter((_, j) => j !== i))}>この課題を外す</button>
                  </div>
                ))}
                <button type="button" className="row row-button tint-row" onClick={() => set('assignments', [...v.assignments, { key: newId(), title: `${v.subjectName || v.title || '授業'}の課題`, content: '', submitMethod: '', submitTo: '', deadline: null }])} data-testid="add-assignment"><Icon name="plus" size={18} /><span className="row-label">課題を追加</span></button>
              </div></div>
              <div className="group-header">小テスト</div>
              <div className="group"><div className="group-body">
                {v.quizzes.map((q, i) => (
                  <div className="sub-form" key={q.key} data-testid="quiz-row">
                    <input className="row-input" value={q.title} onChange={(e) => set('quizzes', v.quizzes.map((x, j) => (j === i ? { ...x, title: e.target.value } : x)))} placeholder="小テスト名" aria-label="小テスト名" />
                    <button type="button" className="row row-button destructive" onClick={() => set('quizzes', v.quizzes.filter((_, j) => j !== i))}>この小テストを外す</button>
                  </div>
                ))}
                <button type="button" className="row row-button tint-row" onClick={() => set('quizzes', [...v.quizzes, { key: newId(), title: '', at: null }])} data-testid="add-quiz"><Icon name="plus" size={18} /><span className="row-label">小テストを追加</span></button>
              </div><div className="group-footer">課題・小テストは保存時に確認してから、タスクとして追加します（同じものを二重には作りません）。</div></div>
            </>
          )}
          {v.mode === 'event' && evKind === 'job' && (
            <>
              <div className="group-header">勤務</div>
              <div className="group"><div className="group-body">
                <Row icon="briefcase" color="#FF9500" label="勤務先">
                  {employers.length ? (
                    <select className="select-input" value={v.employerId ?? ''} onChange={(e) => set('employerId', e.target.value || null)} aria-label="勤務先" data-testid="event-employer">
                      {employers.map((e) => <option key={e.id} value={e.id}>{e.name}</option>)}
                    </select>
                  ) : <span className="muted">「その他」で登録</span>}
                </Row>
              </div>{v.employerId && <div className="group-footer">勤務開始の{employers.find((e) => e.id === v.employerId)?.reminderHours ?? 2}時間前に通知します（通知を許可している場合）。</div>}</div>
            </>
          )}
          {v.mode === 'task' && v.special === 'assignment' && (
            <>
              <div className="group-header">課題</div>
              <div className="group" data-testid="special-assignment"><div className="group-body">
                <textarea className="row-input notes-input" value={v.asgContent} onChange={(e) => set('asgContent', e.target.value)} placeholder="課題の内容" aria-label="課題の内容" rows={3} />
                <Row icon="chat" color="#5E5CE6" label="提出方法"><input className="row-input right" value={v.asgMethod} onChange={(e) => set('asgMethod', e.target.value)} placeholder="未入力" aria-label="提出方法" /></Row>
                <Row icon="tray" color="#5E5CE6" label="提出先"><input className="row-input right" value={v.asgTo} onChange={(e) => set('asgTo', e.target.value)} placeholder="未入力" aria-label="提出先" /></Row>
                <Row icon="flag" color="#FF3B30" label="提出期限"><button type="button" className="ed-chipbtn" onClick={() => setPick('asgDate')}>{v.asgDeadline != null ? `${fmtDate(v.asgDeadline)} ${fmtTime(v.asgDeadline)}` : '未設定'}</button></Row>
              </div></div>
            </>
          )}
          {v.mode === 'task' && v.special === 'testPrep' && (
            <>
              <div className="group-header">テスト対策</div>
              <div className="group" data-testid="special-testPrep"><div className="group-body">
                <Row icon="graduation" color="#5E5CE6" label="授業">
                  <input className="row-input right" list="ed-subjects2" value={v.prepSubject} onChange={(e) => set('prepSubject', e.target.value)} placeholder="授業を選ぶか入力" aria-label="授業" />
                  <datalist id="ed-subjects2">{subjects.map((s) => <option key={s.id} value={s.name} />)}</datalist>
                </Row>
                <Row icon="today" color="#FF3B30" label="試験日"><button type="button" className="ed-chipbtn" onClick={() => setPick('examDate')}>{v.examAt != null ? fmtDate(v.examAt) : '未設定'}</button></Row>
              </div></div>
            </>
          )}
          {studioType && <StudioFieldsForm type={studioType} values={v.studioValues} onChange={(vals) => set('studioValues', vals)} />}
        </div>
      </div>

      {/* ---------------- ピッカー ---------------- */}
      <DatePickerPopup open={pick === 'sDate'} value={v.start} title="開始日" onClose={() => setPick(null)} onPick={(d) => { setPick(null); moveStart(setDay(v.start, d)); }} />
      <TimeWheelPopup open={pick === 'sTime'} value={v.start} title="開始時刻" onClose={() => setPick(null)} onPick={(t) => { setPick(null); moveStart(setTime(v.start, t)); }} />
      <DatePickerPopup open={pick === 'eDate'} value={v.end} min={v.start} title="終了日" onClose={() => setPick(null)} onPick={(d) => { setPick(null); set('end', setDay(v.end, d)); }} />
      <TimeWheelPopup open={pick === 'eTime'} value={v.end} title="終了時刻" onClose={() => setPick(null)} onPick={(t) => { setPick(null); set('end', setTime(v.end, t)); }} />
      <DatePickerPopup open={pick === 'cDate'} value={v.checkAt ?? v.start} title="確認日" onClose={() => setPick(null)} onPick={(d) => { setPick(null); set('checkAt', setDay(v.checkAt ?? v.start, d)); }} />
      <TimeWheelPopup open={pick === 'cTime'} value={v.checkAt ?? v.start} title="確認時刻" onClose={() => setPick(null)} onPick={(t) => { setPick(null); set('checkAt', setTime(v.checkAt ?? v.start, t)); }} />
      <DatePickerPopup open={pick === 'asgDate'} value={v.asgDeadline ?? addDays(startOfDay(v.start), 7) + 23 * HOUR} title="提出期限" onClose={() => setPick(null)} onPick={(d) => { setPick(null); set('asgDeadline', setDay(v.asgDeadline ?? d + 23 * HOUR + 59 * 60_000, d)); }} />
      <DatePickerPopup open={pick === 'examDate'} value={v.examAt ?? addDays(startOfDay(v.start), 7) + 9 * HOUR} title="試験日" onClose={() => setPick(null)} onPick={(d) => { setPick(null); set('examAt', setDay(v.examAt ?? d + 9 * HOUR, d)); }} />
      <RecurrencePopup open={pick === 'rule'} value={v.rule} start={v.start} onClose={() => setPick(null)} onPick={(r) => { setPick(null); set('rule', v.mode === 'task' && r ? { ...r, byWeekday: null, until: null } : r); }} />
      <NotifyPopup open={pick === 'notify'} value={v.notifies} permission={permission} hint={v.mode === 'event' ? '予定の開始時刻を基準に通知します。' : v.taskKind === 'check' ? '確認日時を基準に通知します。' : '予定開始の時刻を基準に通知します。'} onClose={() => setPick(null)} onPick={(n) => { setPick(null); set('notifies', n); }} />
      <PlaceTravelPopup open={pick === 'place'} place={v.place} travel={v.travelMinutes} start={(v.mode === 'event' && !v.allDay) || (v.mode === 'task' && v.taskKind === 'do' && v.timed) ? v.start : null} history={settings.placeHistory} onClose={() => setPick(null)} onPick={(p, t) => { setPick(null); setV((o) => ({ ...o, place: p, travelMinutes: t })); }} />
      <ChoicePopup open={pick === 'category'} title="カテゴリー" value={v.category} onClose={() => setPick(null)} onPick={(c) => { setPick(null); set('category', c); }} testId="category-popup"
        items={[...new Set([...categories.map((c) => c.name), ...tasks.map((t) => t.category).filter((c): c is string => !!c), v.category].filter(Boolean))].map((name) => { const c = categories.find((x) => x.name === name); return { value: name, label: name, badge: c ? <EventBadge icon={c.icon} color={c.color} size={28} /> : undefined }; })} />
      <ChoicePopup open={pick === 'calendar'} title="カレンダー" value={v.taskCalendarId} onClose={() => setPick(null)} onPick={(c) => { setPick(null); set('taskCalendarId', c); }} testId="calendar-popup"
        items={calendars.map((c) => ({ value: c.id, label: c.name, badge: <EventBadge icon={c.icon} color={c.color} size={28} fallback={defaultCalendarIcon(c.kind)} /> }))} />
      <Popup open={pick === 'type'} title="種類" onClose={() => setPick(null)} testId="type-popup" tall>
        {v.mode === 'event' ? (
          <>
            {calendars.map((c) => {
              const st = c.studioTypeId ? studioTypes.find((t) => t.id === c.studioTypeId) : undefined;
              const desc = st ? `Create Studio：${st.fields.filter((f) => !f.hidden).length}項目` : c.kind === 'class' ? '科目・教室・課題・小テスト' : c.kind === 'job' ? '勤務先と勤務前の通知' : '一般の予定';
              return (
                <button key={c.id} type="button" className="type-card" aria-pressed={v.calendarId === c.id} onClick={() => { setV((o) => ({ ...o, calendarId: c.id, studioTypeId: c.studioTypeId ?? null, icon: o.icon === resolveItemIcon(calendarById.get(o.calendarId)?.icon).id ? resolveItemIcon(c.icon, defaultCalendarIcon(c.kind)).id : o.icon })); setPick(null); }} data-testid={`type-cal-${c.id}`}>
                  <EventBadge icon={st ? st.icon : c.icon} color={st ? st.color : c.color} size={40} fallback={defaultCalendarIcon(c.kind)} />
                  <span className="ed-row-label">{c.name}<span className="sub-label">{desc}</span></span>
                </button>
              );
            })}
          </>
        ) : (
          <>
            {([['normal', '一般', '予定時間を決めて取り組む作業や、日時にチェックする用事に使えます。進捗・見積・サブタスクを設定できます。', 'checklist'], ['assignment', '課題', '提出方法・提出先・提出期限を記録し、期限に向けて作業します。', 'note'], ['testPrep', 'テスト対策', '科目と試験日を記録し、試験までの勉強を進めます。', 'graduation']] as const).map(([k, l, d, ic]) => (
              <button key={k} type="button" className="type-card" aria-pressed={!v.studioTypeId && v.special === k} onClick={() => { setV((o) => ({ ...o, special: k, studioTypeId: null })); setPick(null); }} data-testid={`type-task-${k}`}>
                <TaskBadge icon={ic} kind={v.taskKind} size={40} />
                <span className="ed-row-label">{l}<span className="sub-label wrap">{d}{k === 'normal' ? (v.taskKind === 'do' ? '「実行」は開始・停止して作業時間を記録します。' : '「確認」は日時にチェックするだけの用事です。') : ''}</span></span>
                {!v.studioTypeId && v.special === k && <span className="sel-mark on" aria-hidden><Icon name="check" size={14} strokeWidth={3} /></span>}
              </button>
            ))}
            {studioTypes.filter((t) => t.target === 'task' && t.status === 'active').map((t) => (
              <button key={t.id} type="button" className="type-card" aria-pressed={v.studioTypeId === t.id} onClick={() => { setV((o) => ({ ...o, special: 'normal', studioTypeId: t.id, icon: resolveItemIcon(t.icon).id })); setPick(null); }} data-testid={`type-studio-${t.id}`}>
                <TaskBadge icon={t.icon} kind={v.taskKind} size={40} />
                <span className="ed-row-label">{t.name}<span className="sub-label">Create Studio：{t.fields.filter((f) => !f.hidden).length}項目</span></span>
                {v.studioTypeId === t.id && <span className="sel-mark on" aria-hidden><Icon name="check" size={14} strokeWidth={3} /></span>}
              </button>
            ))}
          </>
        )}
        <p className="muted small">自分専用の種類は「その他」の「Create Studio」で作れます。</p>
      </Popup>
    </Sheet>
  );
}

function AttachmentRow({ a, onRemove }: { a: Attachment; onRemove: () => void }) {
  const [url, setUrl] = useState<string | null>(null);
  useEffect(() => {
    let u: string | null = null;
    if (a.driveFileId && a.mime.startsWith('image/')) void api.attachmentBlob(a.driveFileId).then((b) => { u = URL.createObjectURL(b); setUrl(u); }).catch(() => undefined);
    return () => { if (u) URL.revokeObjectURL(u); };
  }, [a.driveFileId, a.mime]);
  const pdf = a.mime === 'application/pdf';
  const kb = a.size != null ? (a.size >= 1_048_576 ? `${(a.size / 1_048_576).toFixed(1)}MB` : `${Math.max(1, Math.round(a.size / 1024))}KB`) : '';
  return (
    <div className="att-row" data-testid="attachment">
      <span className={`att-ico ${pdf ? 'pdf' : 'img'}`} aria-hidden>{url ? <img src={url} alt="" /> : <Icon name={pdf ? 'note' : 'paint'} size={18} />}</span>
      <span className="att-text"><strong>{a.name}</strong><span className="muted small">{pdf ? 'PDF' : '画像'}{kb ? ` · ${kb}` : ''}</span></span>
      <button type="button" className="link-del" aria-label={`${a.name}を外す（ドライブのファイルは残ります）`} onClick={onRemove}><Icon name="close" size={14} strokeWidth={2.6} /></button>
    </div>
  );
}

export { formatHm };
