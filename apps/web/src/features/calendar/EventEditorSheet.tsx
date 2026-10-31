import { useId, useMemo, useState } from 'react';
import {
  checkPlacement, crossesDate, expandAll, expandEvent, formatHm, HOUR, makeEvent, newId, parseOccurrenceId, placementItems, weekday,
  type CalEvent, type ClassAssignment, type ClassQuiz, type RecurrenceFreq, type RecurrenceRule,
} from '@my-time/domain';
import { Sheet } from '../../components/Sheet';
import { Icon } from '../../components/Icon';
import { Toggle } from '../../components/Controls';
import { useData } from '../../app/data';
import { usePlacementGuard } from '../../app/usePlacementGuard';
import { useUI } from '../../app/ui';
import { fromLocalInput, toLocalInput } from '../../app/format';
import { repo } from '../../data/repo';
import { defaultStartFor } from '../tasks/TaskEditorSheet';
import { useAskScope } from '../timeline/useTimelineActions';

const WD = ['日', '月', '火', '水', '木', '金', '土'];
const FREQ_LABEL: Record<RecurrenceFreq | 'none', string> = { none: 'しない', daily: '毎日', weekly: '毎週', monthly: '毎月' };

export function describeRule(r: RecurrenceRule | null): string {
  if (!r) return 'しない';
  const every = r.interval > 1 ? `${r.interval}${r.freq === 'daily' ? '日' : r.freq === 'weekly' ? '週' : 'か月'}ごと` : FREQ_LABEL[r.freq];
  const days = r.freq === 'weekly' && r.byWeekday?.length ? `（${r.byWeekday.map((d) => WD[d]).join('・')}）` : '';
  return `${every}${days}`;
}

export function EventEditorSheet({ eventId, defaults, depth }: { eventId?: string; defaults?: Partial<CalEvent>; depth: number }) {
  const { events, tasks, calendars, calendarById, subjects, employers } = useData();
  const guard = usePlacementGuard();
  const askScope = useAskScope();
  const { closeSheet, openSheet, calDate, tab, homeDate, confirm, showToast } = useUI();
  const occ = eventId ? parseOccurrenceId(eventId) : null;
  const existing = eventId ? events.find((e) => e.id === (occ?.masterId ?? eventId)) : undefined;
  const instance = useMemo(() => (existing && occ ? expandEvent(existing, occ.originalStart - 8 * 86_400_000, occ.originalStart + 8 * 86_400_000).find((o) => o.id === eventId) : undefined), [existing, occ?.originalStart, eventId]); // eslint-disable-line react-hooks/exhaustive-deps
  const isNew = !existing;
  const fid = useId();
  const baseDay = tab === 'calendar' ? calDate : homeDate;
  const s0 = instance?.start ?? existing?.start ?? defaults?.start ?? defaultStartFor(baseDay, Date.now());
  const e0 = instance?.end ?? existing?.end ?? defaults?.end ?? s0 + HOUR;
  const [title, setTitle] = useState(instance?.title ?? existing?.title ?? defaults?.title ?? '');
  const [calendarId, setCalendarId] = useState(existing?.calendarId ?? defaults?.calendarId ?? calendars[0]?.id ?? 'cal-general');
  const [start, setStart] = useState(toLocalInput(s0));
  const [end, setEnd] = useState(toLocalInput(e0));
  const [notes, setNotes] = useState(instance?.notes ?? existing?.notes ?? '');
  const [freq, setFreq] = useState<RecurrenceFreq | 'none'>(existing?.recurrence?.freq ?? 'none');
  const [interval, setInterval] = useState(existing?.recurrence?.interval ?? 1);
  const [byWeekday, setByWeekday] = useState<number[]>(existing?.recurrence?.byWeekday ?? [weekday(s0)]);
  const [untilOn, setUntilOn] = useState(existing?.recurrence?.until != null);
  const [until, setUntil] = useState(toLocalInput(existing?.recurrence?.until ?? s0 + 90 * 86_400_000).slice(0, 10));
  const [hideAfterEnd, setHideAfterEnd] = useState(existing?.hideAfterEnd ?? false);
  const [subjectName, setSubjectName] = useState(existing?.classInfo?.subjectName ?? '');
  const [subjectId, setSubjectId] = useState<string | null>(existing?.classInfo?.subjectId ?? null);
  const [room, setRoom] = useState(existing?.classInfo?.room ?? '');
  const [assignments, setAssignments] = useState<ClassAssignment[]>(existing?.classInfo?.assignments ?? []);
  const [quizzes, setQuizzes] = useState<ClassQuiz[]>(existing?.classInfo?.quizzes ?? []);
  const [employerId, setEmployerId] = useState<string | null>(existing?.employerId ?? employers[0]?.id ?? null);
  const [error, setError] = useState<string | null>(null);

  const kind = calendarById.get(calendarId)?.kind ?? 'general';
  const ps = fromLocalInput(start);
  const pe = fromLocalInput(end);
  const target = ps != null && pe != null && pe > ps ? { id: `event:${eventId ?? '__new'}`, start: ps, end: pe } : null;
  const crossing = target ? crossesDate(target) : false;
  // 入力中も重なりを表示（保存時には改めてアラートで確認する）
  const { conflicts, suggestion } = useMemo(() => {
    if (!target) return { conflicts: [], suggestion: null };
    const around = expandAll(events, target.start - 2 * 86_400_000, target.end + 3 * 86_400_000);
    return checkPlacement(target, placementItems(around, tasks));
  }, [target?.start, target?.end, events, tasks]); // eslint-disable-line react-hooks/exhaustive-deps

  const rule: RecurrenceRule | null =
    freq === 'none' ? null : { freq, interval: Math.max(1, Math.min(99, interval || 1)), byWeekday: freq === 'weekly' ? [...byWeekday].sort() : null, until: untilOn ? (fromLocalInput(`${until}T23:59`) ?? null) : null };
  const ruleChanged = JSON.stringify(rule) !== JSON.stringify(existing?.recurrence ?? null);

  const onStartChange = (v: string) => {
    const ns = fromLocalInput(v);
    setStart(v);
    if (ps != null && pe != null && ns != null && pe > ps) setEnd(toLocalInput(ns + (pe - ps)));
  };

  const classInfo = kind === 'class' ? { subjectId, subjectName: subjectName.trim() || title.trim(), room: room.trim(), assignments, quizzes } : null;

  const save = async () => {
    setError(null);
    if (!title.trim()) return setError('タイトルを入力してください');
    if (!target) return setError('終了は開始より後にしてください');
    if (freq === 'weekly' && byWeekday.length === 0) return setError('繰り返す曜日を選んでください');
    let { start: s1, end: e1 } = target;
    if (isNew || s0 !== s1 || e0 !== e1) {
      const decision = await guard(target, '保存');
      if (!decision) return; // キャンセル：何も保存しない（編集画面に戻る）
      ({ start: s1, end: e1 } = decision);
    }
    const fields = { title: title.trim(), calendarId, start: s1, end: e1, notes, recurrence: rule, classInfo, employerId: kind === 'job' ? employerId : null, hideAfterEnd: crossing && !rule ? hideAfterEnd : false };
    try {
      // 授業：まだタスクになっていない課題・小テストがあれば、確認してから作る
      let createTasks = false;
      if (classInfo) {
        const mid = existing?.id ?? '';
        const made = new Set(tasks.filter((t) => t.sourceEventId === mid).map((t) => t.sourceKey));
        const fresh = [...classInfo.assignments.map((a) => `class:${mid}:assignment:${a.key}`), ...classInfo.quizzes.map((q) => `class:${mid}:quiz:${q.key}`)].filter((k) => !made.has(k));
        if (fresh.length) {
          createTasks = await confirm({
            title: '課題・テスト対策のタスクを作成しますか？',
            message: `${classInfo.assignments.length ? `課題 ${classInfo.assignments.filter((a) => !made.has(`class:${mid}:assignment:${a.key}`)).length}件` : ''}${classInfo.quizzes.length ? ` 小テスト ${classInfo.quizzes.filter((q) => !made.has(`class:${mid}:quiz:${q.key}`)).length}件` : ''}をタスク一覧に追加します。作業時間が未入力のものは「未設定」に入ります。`,
            confirmLabel: '作成',
            cancelLabel: '作成しない',
          });
        }
      }
      if (isNew) {
        const ev = makeEvent(fields, Date.now());
        const r = await repo.saveEventWithClassTasks(ev, true, createTasks);
        showToast(r.created ? `予定とタスク${r.created}件を追加しました` : '予定を追加しました');
      } else if (occ && existing.recurrence) {
        // 繰り返しの1回：規則を変えたら「以降すべて」、それ以外は範囲を選ぶ
        const scope = ruleChanged ? 'future' : await askScope('変更');
        if (!scope) return;
        await repo.editOccurrence(existing.id, occ.originalStart, scope === 'this' ? { start: s1, end: e1, title: fields.title, notes } : fields, scope);
        showToast('保存しました');
      } else {
        const r = await repo.saveEventWithClassTasks({ ...existing, ...fields }, false, createTasks);
        showToast(r.created ? `保存し、タスク${r.created}件を追加しました` : '保存しました');
      }
      closeSheet();
    } catch (e) {
      setError(e instanceof Error ? e.message : '保存できませんでした');
    }
  };

  const remove = async () => {
    if (!existing) return;
    if (occ && existing.recurrence) {
      const scope = await askScope('削除');
      if (!scope) return;
      await repo.deleteOccurrence(existing.id, occ.originalStart, scope);
    } else {
      const ok = await confirm({ title: '予定を削除しますか？', message: `「${existing.title}」を削除します。${existing.classInfo ? '授業から作ったタスクは残ります。' : ''}`, confirmLabel: '削除', destructive: true });
      if (!ok) return;
      await repo.deleteEvent(existing.id);
    }
    closeSheet();
    showToast('削除しました');
  };

  const addAssignment = () => setAssignments((a) => [...a, { key: newId(), title: `${subjectName || title || '授業'}の課題`, content: '', submitMethod: '', submitTo: '', deadline: null }]);

  return (
    <Sheet
      onClose={closeSheet}
      depth={depth}
      title={isNew ? '新規予定' : '予定を編集'}
      left={<button type="button" className="bar-btn" onClick={closeSheet}>キャンセル</button>}
      right={<button type="button" className="bar-btn bold" onClick={() => void save()} data-testid="save-event">{isNew ? '追加' : '完了'}</button>}
    >
      <form className="form" onSubmit={(e) => { e.preventDefault(); void save(); }}>
        <div className="group">
          <div className="group-body">
            <input className="row-input big" value={title} onChange={(e) => setTitle(e.target.value)} placeholder="タイトル" aria-label="タイトル" autoFocus={isNew} data-testid="event-title-input" />
          </div>
        </div>
        <div className="group">
          <div className="group-body">
            <div className="row">
              <label className="row-label" htmlFor={`${fid}-cal`}>カレンダー</label>
              <select id={`${fid}-cal`} className="select-input" value={calendarId} onChange={(e) => setCalendarId(e.target.value)} data-testid="event-calendar">
                {calendars.map((c) => (
                  <option key={c.id} value={c.id}>{c.icon} {c.name}</option>
                ))}
              </select>
            </div>
          </div>
        </div>
        <div className="group">
          <div className="group-body">
            <div className="row">
              <label className="row-label" htmlFor={`${fid}-s`}>開始</label>
              <input id={`${fid}-s`} type="datetime-local" className="dt-input" value={start} onChange={(e) => onStartChange(e.target.value)} data-testid="event-start" />
            </div>
            <div className="row">
              <label className="row-label" htmlFor={`${fid}-e`}>終了</label>
              <input id={`${fid}-e`} type="datetime-local" className="dt-input" value={end} onChange={(e) => setEnd(e.target.value)} data-testid="event-end" />
            </div>
            <div className="row">
              <label className="row-label" htmlFor={`${fid}-rep`}>繰り返し</label>
              <select id={`${fid}-rep`} className="select-input" value={freq} onChange={(e) => setFreq(e.target.value as RecurrenceFreq | 'none')} data-testid="event-repeat">
                {(['none', 'daily', 'weekly', 'monthly'] as const).map((f) => (
                  <option key={f} value={f}>{FREQ_LABEL[f]}</option>
                ))}
              </select>
            </div>
            {freq !== 'none' && (
              <>
                <div className="row">
                  <label className="row-label" htmlFor={`${fid}-int`}>間隔</label>
                  <span className="row-value">
                    <input id={`${fid}-int`} type="number" inputMode="numeric" min={1} max={99} className="num-input" value={interval} onChange={(e) => setInterval(Number(e.target.value))} />
                    {freq === 'daily' ? '日ごと' : freq === 'weekly' ? '週ごと' : 'か月ごと'}
                  </span>
                </div>
                {freq === 'weekly' && (
                  <div className="row">
                    <span className="row-label">曜日</span>
                    <span className="wd-chips" role="group" aria-label="曜日">
                      {WD.map((w, i) => (
                        <button key={w} type="button" aria-pressed={byWeekday.includes(i)} className={`wd-chip ${byWeekday.includes(i) ? 'on' : ''}`} onClick={() => setByWeekday((d) => (d.includes(i) ? d.filter((x) => x !== i) : [...d, i]))}>
                          {w}
                        </button>
                      ))}
                    </span>
                  </div>
                )}
                <div className="row">
                  <label className="row-label" htmlFor={`${fid}-until-on`}>終了日</label>
                  <Toggle id={`${fid}-until-on`} label="繰り返しの終了日" checked={untilOn} onChange={setUntilOn} />
                </div>
                {untilOn && (
                  <div className="row">
                    <label className="row-label" htmlFor={`${fid}-until`}>この日まで</label>
                    <input id={`${fid}-until`} type="date" className="dt-input" value={until} onChange={(e) => setUntil(e.target.value)} />
                  </div>
                )}
              </>
            )}
            {crossing && !rule && (
              <div className="row">
                <label className="row-label" htmlFor={`${fid}-hide`}>終了したらすぐ隠す</label>
                <Toggle id={`${fid}-hide`} label="終了したらすぐ隠す" checked={hideAfterEnd} onChange={setHideAfterEnd} />
              </div>
            )}
          </div>
          {crossing && !rule && <div className="group-footer">夜勤など日付をまたぐ予定を、終了直後にカレンダーから隠します。Googleドライブへの保存を確認してから削除し、「期間指定の復元」でいつでも見返せます。</div>}
          {occ && existing?.recurrence && <div className="group-footer">繰り返しの1回です。保存時に「この予定のみ」か「これ以降すべて」を選べます（繰り返しの設定を変えた場合は以降すべて）。</div>}
          {conflicts.length > 0 && (
            <div className="conflict" role="status" data-testid="conflict-warning">
              <Icon name="info" size={18} />
              <div>
                <div>「{conflicts[0]!.title}」{conflicts.length > 1 ? `など${conflicts.length}件` : ''}と時間が重なっています。保存前に確認します。</div>
                {suggestion && (
                  <button type="button" className="link-btn" onClick={() => { setStart(toLocalInput(suggestion.start)); setEnd(toLocalInput(suggestion.end)); }}>
                    {formatHm(suggestion.start)}〜{formatHm(suggestion.end)} に変更する
                  </button>
                )}
                <div className="conflict-note">既存の予定は自動で移動しません。</div>
              </div>
            </div>
          )}
        </div>

        {kind === 'class' && (
          <div className="group" data-testid="class-fields">
            <div className="group-header">授業</div>
            <div className="group-body">
              <div className="row">
                <label className="row-label" htmlFor={`${fid}-subj`}>科目</label>
                <input
                  id={`${fid}-subj`}
                  className="row-input right"
                  list={`${fid}-subjects`}
                  value={subjectName}
                  placeholder={title || '科目名'}
                  onChange={(e) => {
                    setSubjectName(e.target.value);
                    setSubjectId(subjects.find((s) => s.name === e.target.value)?.id ?? null);
                  }}
                />
                <datalist id={`${fid}-subjects`}>
                  {subjects.map((s) => (
                    <option key={s.id} value={s.name} />
                  ))}
                </datalist>
              </div>
              <div className="row">
                <label className="row-label" htmlFor={`${fid}-room`}>教室</label>
                <input id={`${fid}-room`} className="row-input right" value={room} onChange={(e) => setRoom(e.target.value)} placeholder="未入力" />
              </div>
            </div>
            <div className="group-header sub">課題</div>
            <div className="group-body">
              {assignments.map((a, i) => (
                <div className="sub-form" key={a.key} data-testid="assignment-row">
                  <input className="row-input" value={a.title} onChange={(e) => setAssignments((l) => l.map((x, j) => (j === i ? { ...x, title: e.target.value } : x)))} placeholder="課題名" aria-label="課題名" />
                  <input className="row-input small" value={a.content} onChange={(e) => setAssignments((l) => l.map((x, j) => (j === i ? { ...x, content: e.target.value } : x)))} placeholder="内容" aria-label="課題の内容" />
                  <div className="row">
                    <input className="row-input small half" value={a.submitMethod} onChange={(e) => setAssignments((l) => l.map((x, j) => (j === i ? { ...x, submitMethod: e.target.value } : x)))} placeholder="提出方法" aria-label="提出方法" />
                    <input className="row-input small half" value={a.submitTo} onChange={(e) => setAssignments((l) => l.map((x, j) => (j === i ? { ...x, submitTo: e.target.value } : x)))} placeholder="提出先" aria-label="提出先" />
                  </div>
                  <div className="row">
                    <span className="row-label small">提出期限</span>
                    <input type="datetime-local" className="dt-input" value={a.deadline != null ? toLocalInput(a.deadline) : ''} onChange={(e) => setAssignments((l) => l.map((x, j) => (j === i ? { ...x, deadline: fromLocalInput(e.target.value) } : x)))} aria-label="提出期限" />
                    <button type="button" className="icon-btn subtle" aria-label="課題を外す" onClick={() => setAssignments((l) => l.filter((_, j) => j !== i))}>
                      <Icon name="close" size={16} />
                    </button>
                  </div>
                </div>
              ))}
              <button type="button" className="row row-button tint-row" onClick={addAssignment} data-testid="add-assignment">
                <Icon name="plus" size={18} />
                <span className="row-label">課題を追加</span>
              </button>
            </div>
            <div className="group-header sub">小テスト</div>
            <div className="group-body">
              {quizzes.map((q, i) => (
                <div className="sub-form" key={q.key} data-testid="quiz-row">
                  <input className="row-input" value={q.title} onChange={(e) => setQuizzes((l) => l.map((x, j) => (j === i ? { ...x, title: e.target.value } : x)))} placeholder="小テスト名" aria-label="小テスト名" />
                  <div className="row">
                    <span className="row-label small">日時</span>
                    <input type="datetime-local" className="dt-input" value={q.at != null ? toLocalInput(q.at) : ''} onChange={(e) => setQuizzes((l) => l.map((x, j) => (j === i ? { ...x, at: fromLocalInput(e.target.value) } : x)))} aria-label="小テストの日時" />
                  <button type="button" className="icon-btn subtle" aria-label="小テストを外す" onClick={() => setQuizzes((l) => l.filter((_, j) => j !== i))}>
                      <Icon name="close" size={16} />
                    </button>
                  </div>
                </div>
              ))}
              <button type="button" className="row row-button tint-row" onClick={() => setQuizzes((l) => [...l, { key: newId(), title: '', at: null }])} data-testid="add-quiz">
                <Icon name="plus" size={18} />
                <span className="row-label">小テストを追加</span>
              </button>
            </div>
            <div className="group-footer">課題・小テストは保存時に確認してから、課題タスク・テスト対策タスクとして追加します（同じものを二重には作りません）。</div>
          </div>
        )}

        {kind === 'job' && (
          <div className="group" data-testid="job-fields">
            <div className="group-header">アルバイト</div>
            <div className="group-body">
              <div className="row">
                <label className="row-label" htmlFor={`${fid}-emp`}>勤務先</label>
                {employers.length ? (
                  <select id={`${fid}-emp`} className="select-input" value={employerId ?? ''} onChange={(e) => setEmployerId(e.target.value || null)} data-testid="event-employer">
                    {employers.map((e) => (
                      <option key={e.id} value={e.id}>{e.name}</option>
                    ))}
                  </select>
                ) : (
                  <span className="row-value muted">「その他 › カレンダー」で登録</span>
                )}
              </div>
            </div>
            {employerId && <div className="group-footer">勤務開始の{employers.find((e) => e.id === employerId)?.reminderHours ?? 2}時間前に通知します（通知を許可している場合）。</div>}
          </div>
        )}

        <div className="group">
          <div className="group-body">
            <textarea className="row-input notes-input" value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="メモ" aria-label="メモ" rows={3} />
          </div>
        </div>
        {error && <p className="form-error" role="alert">{error}</p>}
        {!isNew && (
          <div className="group">
            <div className="group-body">
              <button type="button" className="row row-button center" onClick={() => openSheet({ kind: 'copyEvent', eventId: eventId! })} data-testid="copy-event">別の日にコピー</button>
              <button type="button" className="row row-button destructive center" onClick={() => void remove()} data-testid="delete-event">予定を削除</button>
            </div>
          </div>
        )}
        <button type="submit" hidden />
      </form>
    </Sheet>
  );
}
