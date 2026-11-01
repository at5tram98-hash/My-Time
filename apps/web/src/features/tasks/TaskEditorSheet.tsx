import { useId, useMemo, useState } from 'react';
import { DEFAULT_TASK_ICON, HOUR, makeTask, previewConversion, type RecurrenceFreq, type SpecialKind, startOfDay, type Task, TASK_ICON_CHOICES, type TaskKind } from '@my-time/domain';
import { Sheet } from '../../components/Sheet';
import { Segmented, Toggle } from '../../components/Controls';
import { useData } from '../../app/data';
import { usePlacementGuard } from '../../app/usePlacementGuard';
import { useUIActions, useUIDates } from '../../app/ui';
import { fromLocalInput, toLocalInput } from '../../app/format';
import { db } from '../../data/db';
import { repo } from '../../data/repo';
import { IconPicker } from '../../components/ItemIcon';


/** 次のきりのよい時刻（その日の範囲内） */
export function defaultStartFor(day: number, now: number): number {
  const base = startOfDay(day) === startOfDay(now) ? now : startOfDay(day) + 9 * HOUR;
  const d = new Date(base);
  d.setMinutes(d.getMinutes() > 0 ? 60 : 0, 0, 0);
  return d.getTime();
}

export function TaskEditorSheet({ taskId, defaults, depth }: { taskId?: string; defaults?: Partial<Task>; depth: number }) {
  const { tasks, calendars, subjects, settings } = useData();
  const { homeDate } = useUIDates();
  const { closeSheet, confirm, showToast } = useUIActions();
  const existing = taskId ? tasks.find((t) => t.id === taskId) : undefined;
  const isNew = !existing;
  const init = existing ?? ({ ...defaults } as Partial<Task>);
  const fid = useId();
  const guard = usePlacementGuard();

  const startDefault = defaultStartFor(homeDate, Date.now());
  const [title, setTitle] = useState(init.title ?? '');
  const [kind, setKind] = useState<TaskKind>(init.kind ?? 'do');
  const [icon, setIcon] = useState<string>(init.icon ?? DEFAULT_TASK_ICON);
  const [calendarId, setCalendarId] = useState<string>(init.calendarId ?? '');
  const [category, setCategory] = useState(init.category ?? '');
  const [timed, setTimed] = useState(isNew ? (defaults?.plannedStart !== null) : init.plannedStart != null);
  const [start, setStart] = useState(toLocalInput(init.plannedStart ?? startDefault));
  const [end, setEnd] = useState(toLocalInput(init.plannedEnd ?? (init.plannedStart ?? startDefault) + HOUR));
  const [checkTimed, setCheckTimed] = useState(isNew ? true : init.checkAt != null);
  const [checkAt, setCheckAt] = useState(toLocalInput(init.checkAt ?? startDefault));
  const [notes, setNotes] = useState(init.notes ?? '');
  const [special, setSpecial] = useState<SpecialKind>(init.special ?? 'normal');
  const [asgContent, setAsgContent] = useState(init.assignment?.content ?? '');
  const [asgMethod, setAsgMethod] = useState(init.assignment?.submitMethod ?? '');
  const [asgTo, setAsgTo] = useState(init.assignment?.submitTo ?? '');
  const [asgDeadline, setAsgDeadline] = useState(init.assignment?.deadline != null ? toLocalInput(init.assignment.deadline) : '');
  const [examOn, setExamOn] = useState(init.testPrep?.examAt != null);
  const [examAt, setExamAt] = useState(toLocalInput(init.testPrep?.examAt ?? startDefault + 7 * 86_400_000));
  const [prepSubject, setPrepSubject] = useState(init.testPrep?.subjectName ?? '');
  const [estimate, setEstimate] = useState(init.estimateMinutes != null ? String(init.estimateMinutes) : '');
  const [priority, setPriority] = useState<0 | 1 | 2 | 3>(init.priority ?? 0);
  const [tagsText, setTagsText] = useState((init.tags ?? []).join(' '));
  const [flagged, setFlagged] = useState(init.flagged ?? false);
  const [notify, setNotify] = useState<string>(init.notifyMinutesBefore != null ? String(init.notifyMinutesBefore) : isNew && settings.defaultNotifyMinutes != null ? String(settings.defaultNotifyMinutes) : '');
  const [locOn, setLocOn] = useState(init.location != null);
  const [location, setLocation] = useState(init.location ?? '');
  const [repeat, setRepeat] = useState<RecurrenceFreq | 'none'>(init.repeat?.freq ?? 'none');
  const [error, setError] = useState<string | null>(null);

  const categories = useMemo(() => [...new Set(tasks.map((t) => t.category).filter((c): c is string => !!c))], [tasks]);

  const onStartChange = (v: string) => {
    // 開始を動かしたら長さを保って終了も動かす
    const os = fromLocalInput(start);
    const oe = fromLocalInput(end);
    const ns = fromLocalInput(v);
    setStart(v);
    if (os != null && oe != null && ns != null && oe > os) setEnd(toLocalInput(ns + (oe - os)));
  };

  const save = async () => {
    setError(null);
    if (!title.trim()) return setError('タイトルを入力してください');
    const ps = kind === 'do' && timed ? fromLocalInput(start) : null;
    const pe = kind === 'do' && timed ? fromLocalInput(end) : null;
    if (kind === 'do' && timed && (ps == null || pe == null || pe <= ps)) return setError('終了は開始より後にしてください');
    // 時刻を新しく決めた／変えたときは保存前に重複を確認（キャンセルなら何も保存しない）
    let [ps2, pe2] = [ps, pe];
    if (ps != null && pe != null && (isNew || existing.plannedStart !== ps || existing.plannedEnd !== pe)) {
      const decision = await guard({ id: `task:${existing?.id ?? '__new'}`, start: ps, end: pe }, '保存');
      if (!decision) return;
      [ps2, pe2] = [decision.start, decision.end];
    }
    const fields: Partial<Task> = {
      title: title.trim(),
      icon,
      calendarId: calendarId || null,
      category: category.trim() || null,
      notes,
      special,
      assignment: special === 'assignment' ? { content: asgContent.trim(), submitMethod: asgMethod.trim(), submitTo: asgTo.trim(), deadline: fromLocalInput(asgDeadline) } : null,
      testPrep: special === 'testPrep' ? { examAt: examOn ? fromLocalInput(examAt) : null, subjectId: subjects.find((x) => x.name === prepSubject.trim())?.id ?? null, subjectName: prepSubject.trim() } : null,
      estimateMinutes: estimate.trim() ? Math.max(1, Math.min(10_000, Math.round(Number(estimate)))) || null : null,
      priority,
      tags: [...new Set(tagsText.split(/[\s,、]+/).map((t) => t.replace(/^#/, '').trim()).filter(Boolean))].slice(0, 30),
      flagged,
      notifyMinutesBefore: notify === '' ? null : Number(notify),
      location: locOn && location.trim() ? location.trim() : null,
      repeat: repeat === 'none' ? null : { freq: repeat, interval: 1 },
      ...(kind === 'do' ? { plannedStart: ps2, plannedEnd: pe2 } : { checkAt: checkTimed ? fromLocalInput(checkAt) : null }),
    };
    try {
      if (isNew) {
        await repo.saveTask(makeTask({ ...defaults, ...fields, title: title.trim(), kind }, Date.now()), true);
        showToast('追加しました');
      } else {
        if (existing.kind !== kind) {
          const pv = previewConversion(existing, kind);
          const ok = await confirm({
            title: kind === 'check' ? '確認タスクに変更しますか？' : '実施タスクに変更しますか？',
            message: pv.warnings.join('\n') || '実績の記録は保持されます。',
            confirmLabel: '変更',
          });
          if (!ok) return;
          await repo.convertTask(existing.id, kind);
        }
        const fresh = (await db.tasks.get(existing.id)) ?? existing;
        await repo.saveTask({ ...fresh, ...fields }, false);
      }
      closeSheet();
    } catch (e) {
      setError(e instanceof Error ? e.message : '保存できませんでした');
    }
  };

  return (
    <Sheet
      onClose={closeSheet}
      depth={depth}
      title={isNew ? '新規タスク' : 'タスクを編集'}
      left={<button type="button" className="bar-btn" onClick={closeSheet}>キャンセル</button>}
      right={<button type="button" className="bar-btn bold" onClick={() => void save()} data-testid="save-task">{isNew ? '追加' : '完了'}</button>}
    >
      <form
        className="form"
        onSubmit={(e) => {
          e.preventDefault();
          void save();
        }}
      >
        <div className="group">
          <div className="group-body">
            <input className="row-input big" value={title} onChange={(e) => setTitle(e.target.value)} placeholder="タイトル" aria-label="タイトル" autoFocus={isNew} data-testid="task-title-input" />
            <textarea className="row-input notes-input" value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="メモ" aria-label="メモ" rows={2} />
          </div>
        </div>

        <div className="form-center">
          <Segmented label="タスクの種類" value={kind} onChange={setKind} options={[{ value: 'do', label: '実施' }, { value: 'check', label: '確認' }]} />
        </div>

        <div className="group">
          <div className="group-header">アイコン</div>
          <div className="group-body padded">
            <IconPicker choices={TASK_ICON_CHOICES} value={icon} onChange={setIcon} />
          </div>
        </div>

        <div className="group">
          <div className="group-body">
            {kind === 'do' ? (
              <>
                <div className="row">
                  <label className="row-label" htmlFor={`${fid}-timed`}>日時を指定</label>
                  <Toggle id={`${fid}-timed`} label="日時を指定" checked={timed} onChange={setTimed} />
                </div>
                {timed && (
                  <>
                    <div className="row">
                      <label className="row-label" htmlFor={`${fid}-s`}>開始</label>
                      <input id={`${fid}-s`} type="datetime-local" className="dt-input" value={start} onChange={(e) => onStartChange(e.target.value)} data-testid="task-start" />
                    </div>
                    <div className="row">
                      <label className="row-label" htmlFor={`${fid}-e`}>終了</label>
                      <input id={`${fid}-e`} type="datetime-local" className="dt-input" value={end} onChange={(e) => setEnd(e.target.value)} data-testid="task-end" />
                    </div>
                  </>
                )}
              </>
            ) : (
              <>
                <div className="row">
                  <label className="row-label" htmlFor={`${fid}-ct`}>確認日時</label>
                  <Toggle id={`${fid}-ct`} label="確認日時" checked={checkTimed} onChange={setCheckTimed} />
                </div>
                {checkTimed && (
                  <div className="row">
                    <label className="row-label" htmlFor={`${fid}-c`}>日時</label>
                    <input id={`${fid}-c`} type="datetime-local" className="dt-input" value={checkAt} onChange={(e) => setCheckAt(e.target.value)} />
                  </div>
                )}
              </>
            )}
          </div>
          {kind === 'do' && !timed && <div className="group-footer">日時を指定しないタスクは「未設定」に表示されます。</div>}
        </div>

        <div className="group">
          <div className="group-body">
            <div className="row">
              <label className="row-label" htmlFor={`${fid}-cal`}>カレンダー</label>
              <select id={`${fid}-cal`} className="select-input" value={calendarId} onChange={(e) => setCalendarId(e.target.value)}>
                <option value="">なし</option>
                {calendars.map((c) => (
                  <option key={c.id} value={c.id}>{c.name}</option>
                ))}
              </select>
            </div>
            <div className="row">
              <label className="row-label" htmlFor={`${fid}-cat`}>カテゴリ</label>
              <input id={`${fid}-cat`} className="row-input right" list={`${fid}-cats`} value={category} onChange={(e) => setCategory(e.target.value)} placeholder="なし" />
              <datalist id={`${fid}-cats`}>
                {categories.map((c) => (
                  <option key={c} value={c} />
                ))}
              </datalist>
            </div>
          </div>
        </div>
        {kind === 'do' && (
          <div className="group">
            <div className="group-header">種類</div>
            <div className="group-body padded">
              <Segmented label="特別なタスク" value={special} onChange={setSpecial} options={[{ value: 'normal', label: '通常' }, { value: 'assignment', label: '課題' }, { value: 'testPrep', label: 'テスト対策' }]} />
            </div>
            {special !== 'normal' && (
              <div className="group-body" data-testid={`special-${special}`}>
                {special === 'assignment' ? (
                  <>
                    <input className="row-input" value={asgContent} onChange={(e) => setAsgContent(e.target.value)} placeholder="課題の内容" aria-label="課題の内容" />
                    <div className="row">
                      <input className="row-input small half" value={asgMethod} onChange={(e) => setAsgMethod(e.target.value)} placeholder="提出方法" aria-label="提出方法" />
                      <input className="row-input small half" value={asgTo} onChange={(e) => setAsgTo(e.target.value)} placeholder="提出先" aria-label="提出先" />
                    </div>
                    <div className="row">
                      <label className="row-label" htmlFor={`${fid}-dl`}>提出期限</label>
                      <input id={`${fid}-dl`} type="datetime-local" className="dt-input" value={asgDeadline} onChange={(e) => setAsgDeadline(e.target.value)} />
                    </div>
                  </>
                ) : (
                  <>
                    <div className="row">
                      <label className="row-label" htmlFor={`${fid}-subj`}>科目</label>
                      <input id={`${fid}-subj`} className="row-input right" list={`${fid}-subjects`} value={prepSubject} onChange={(e) => setPrepSubject(e.target.value)} placeholder="授業を選ぶか入力" />
                      <datalist id={`${fid}-subjects`}>
                        {subjects.map((x) => (
                          <option key={x.id} value={x.name} />
                        ))}
                      </datalist>
                    </div>
                    <div className="row">
                      <label className="row-label" htmlFor={`${fid}-ex`}>試験日時</label>
                      <Toggle id={`${fid}-ex`} label="試験日時" checked={examOn} onChange={setExamOn} />
                    </div>
                    {examOn && (
                      <div className="row">
                        <label className="row-label" htmlFor={`${fid}-exat`}>日時</label>
                        <input id={`${fid}-exat`} type="datetime-local" className="dt-input" value={examAt} onChange={(e) => setExamAt(e.target.value)} />
                      </div>
                    )}
                  </>
                )}
                <div className="row">
                  <label className="row-label" htmlFor={`${fid}-est`}>作業時間</label>
                  <span className="row-value">
                    <input id={`${fid}-est`} type="number" inputMode="numeric" min={1} className="num-input" value={estimate} onChange={(e) => setEstimate(e.target.value)} placeholder="未入力" />分
                  </span>
                </div>
              </div>
            )}
            {special !== 'normal' && <div className="group-footer">日時と作業時間が未入力の間は「未設定」に表示し、1日1回だけ入力をお知らせします。</div>}
          </div>
        )}

        <div className="group">
          <div className="group-header">詳細</div>
          <div className="group-body">
            <div className="row">
              <label className="row-label" htmlFor={`${fid}-ntf`}>通知</label>
              <select id={`${fid}-ntf`} className="select-input" value={notify} onChange={(e) => setNotify(e.target.value)}>
                <option value="">なし</option>
                <option value="0">{kind === 'check' ? '確認日時' : '開始時刻'}</option>
                <option value="5">5分前</option>
                <option value="10">10分前</option>
                <option value="30">30分前</option>
                <option value="60">1時間前</option>
                <option value="1440">1日前</option>
              </select>
            </div>
            <div className="row">
              <label className="row-label" htmlFor={`${fid}-rep`}>繰り返し</label>
              <select id={`${fid}-rep`} className="select-input" value={repeat} onChange={(e) => setRepeat(e.target.value as RecurrenceFreq | 'none')}>
                <option value="none">しない</option>
                <option value="daily">毎日</option>
                <option value="weekly">毎週</option>
                <option value="monthly">毎月</option>
              </select>
            </div>
            <div className="row">
              <label className="row-label" htmlFor={`${fid}-pri`}>優先度</label>
              <select id={`${fid}-pri`} className="select-input" value={priority} onChange={(e) => setPriority(Number(e.target.value) as 0 | 1 | 2 | 3)}>
                <option value={0}>なし</option>
                <option value={1}>低</option>
                <option value={2}>中</option>
                <option value={3}>高</option>
              </select>
            </div>
            <div className="row">
              <label className="row-label" htmlFor={`${fid}-flag`}>フラグ</label>
              <Toggle id={`${fid}-flag`} label="フラグ" checked={flagged} onChange={setFlagged} />
            </div>
            <div className="row">
              <label className="row-label" htmlFor={`${fid}-tags`}>タグ</label>
              <input id={`${fid}-tags`} className="row-input right" value={tagsText} onChange={(e) => setTagsText(e.target.value)} placeholder="#ゼミ #レポート" />
            </div>
            <div className="row">
              <label className="row-label" htmlFor={`${fid}-loc`}>場所</label>
              <Toggle id={`${fid}-loc`} label="場所" checked={locOn} onChange={setLocOn} />
            </div>
            {locOn && <input className="row-input" value={location} onChange={(e) => setLocation(e.target.value)} placeholder="場所" aria-label="場所の名前" />}
          </div>
        </div>
        {error && <p className="form-error" role="alert">{error}</p>}
        <button type="submit" hidden />
      </form>
    </Sheet>
  );
}
