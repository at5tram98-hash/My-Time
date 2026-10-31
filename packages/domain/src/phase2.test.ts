import { describe, expect, it } from 'vitest';
import {
  addDays, applyAutoReservation, applyTaskAction, buildSnapshot, cancelThisOccurrence, classifyImport, copyToDays, dayStats, DAY, dueOccurrences,
  editThisOccurrence, eventRetention, expandEvent, hiddenAfterEnd, HOUR, isDue, makeEmployer, makeEvent, makeTask, MINUTE, needsSetup, normalizeTask,
  NOT_STARTED_BODY, parseICS, parseOccurrenceId, parseText, planClassTasks, planNotices, retryDelay, ruleStarts, splitFromOccurrence, startOfDay,
  subtaskLabel, taskRetention, verifySnapshot, weekStats, type CalEvent,
} from './index';

const day = startOfDay(new Date(2026, 9, 12, 12).getTime()); // 2026-10-12 月
const at = (h: number, m = 0, d = 0) => addDays(day, d) + h * HOUR + m * MINUTE;

describe('繰り返し予定', () => {
  const weekly = makeEvent({ id: 'w', title: 'ゼミ', calendarId: 'c', start: at(13), end: at(14, 30), recurrence: { freq: 'weekly', interval: 1, byWeekday: [1, 3], until: null } }, 0);

  it('毎週 月・水 を展開し、IDは回ごとに安定', () => {
    const occ = expandEvent(weekly, day, addDays(day, 14));
    expect(occ.map((o) => new Date(o.start).getDay())).toEqual([1, 3, 1, 3]);
    expect(occ[1]!.id).toBe(`w@${at(13, 0, 2)}`);
    expect(parseOccurrenceId(occ[1]!.id)).toEqual({ masterId: 'w', originalStart: at(13, 0, 2) });
  });
  it('「この回のみ」変更・削除はその回だけに反映', () => {
    let m = editThisOccurrence(weekly, at(13, 0, 2), { start: at(15, 0, 2), end: at(16, 0, 2), title: '補講' }, 1);
    m = cancelThisOccurrence(m, at(13, 0, 7), 2);
    const occ = expandEvent(m, day, addDays(day, 14));
    expect(occ.map((o) => o.title)).toEqual(['ゼミ', '補講', 'ゼミ']);
    expect(occ[1]!.start).toBe(at(15, 0, 2));
    expect(weekly.exceptions).toEqual([]); // 元のマスターは不変
  });
  it('「以降すべて」は過去の回を保護して新しいマスターに分割', () => {
    const { before, after } = splitFromOccurrence(weekly, at(13, 0, 7), { start: at(14, 0, 7), end: at(15, 0, 7), title: '新ゼミ' }, 'w2', 5);
    expect(before!.recurrence!.until).toBe(at(13, 0, 7) - 1);
    expect(expandEvent(before!, day, addDays(day, 21)).map((o) => o.title)).toEqual(['ゼミ', 'ゼミ']);
    expect(expandEvent(after, day, addDays(day, 14)).map((o) => [o.title, o.start])).toEqual([['新ゼミ', at(14, 0, 7)], ['新ゼミ', at(14, 0, 9)]]);
  });
  it('月末の毎月は短い月で月末日に丸める', () => {
    const m = makeEvent({ title: '月末', calendarId: 'c', start: new Date(2026, 0, 31, 9).getTime(), end: new Date(2026, 0, 31, 10).getTime(), recurrence: { freq: 'monthly', interval: 1, byWeekday: null, until: null } }, 0);
    const s = ruleStarts(m, new Date(2026, 0, 1).getTime(), new Date(2026, 3, 1).getTime());
    expect(s.map((t) => new Date(t).getDate())).toEqual([31, 28, 31]);
  });
  it('複数日へコピーは同じ時刻・長さで別の予定を作る（元は変えない）', () => {
    const e = makeEvent({ title: 'A', calendarId: 'c', start: at(9, 30), end: at(11) }, 0);
    let n = 0;
    const copies = copyToDays(e, [addDays(day, 2), addDays(day, 5)], () => `n${n++}`, 9);
    expect(copies.map((c) => [c.id, c.start, c.end])).toEqual([['n0', at(9, 30, 2), at(11, 0, 2)], ['n1', at(9, 30, 5), at(11, 0, 5)]]);
  });
});

describe('授業の課題・小テスト → 独立タスク', () => {
  const ev = makeEvent({ id: 'cls', title: '財政学', calendarId: 'cal-class', start: at(10, 45), end: at(12, 15), classInfo: { subjectId: 's1', subjectName: '財政学', room: '1-201', assignments: [{ key: 'a1', title: 'レポート1', content: '2000字', submitMethod: 'Moodle', submitTo: '担当教員', deadline: at(23, 59, 7) }], quizzes: [{ key: 'q1', title: '', at: at(10, 45, 14) }] } }, 0);
  it('課題は課題タスク、小テストはテスト対策タスクとして source で関連付けて作る', () => {
    const plan = planClassTasks(ev, [], 1);
    expect(plan.create.map((t) => [t.special, t.sourceEventId, t.eventId, t.sourceKey])).toEqual([
      ['assignment', 'cls', null, 'class:cls:assignment:a1'],
      ['testPrep', 'cls', null, 'class:cls:quiz:q1'],
    ]);
    expect(plan.create[1]!.title).toBe('財政学 テスト対策');
    expect(subtaskLabel(plan.create[1]!)).toBe('詳細なテスト対策');
  });
  it('同じキーがあれば二重に作らず、期限の変更だけを反映', () => {
    const first = planClassTasks(ev, [], 1).create;
    const changed: CalEvent = { ...ev, classInfo: { ...ev.classInfo!, assignments: [{ ...ev.classInfo!.assignments[0]!, deadline: at(23, 59, 8) }] } };
    const plan = planClassTasks(changed, first, 2);
    expect(plan.create).toEqual([]);
    expect(plan.update.map((t) => t.assignment?.deadline)).toEqual([at(23, 59, 8)]);
  });
  it('作業時間・日時が未入力の課題は「未設定」', () => {
    const t = planClassTasks(ev, [], 1).create[0]!;
    expect(needsSetup(t)).toBe(true);
    expect(needsSetup({ ...t, plannedStart: at(19), plannedEnd: at(20) })).toBe(false);
  });
});

describe('30日削除の判定（推測で広げない）', () => {
  it('通常の予定は終了日から30日、特則の日またぎ予定は終了直後（非表示も終了直後）', () => {
    const e = makeEvent({ title: 'x', calendarId: 'c', start: at(10), end: at(11) }, 0);
    expect(eventRetention(e, at(12))).toMatchObject({ state: 'due', dueAt: at(11) + 30 * DAY });
    const night = makeEvent({ title: '夜勤', calendarId: 'c', start: at(22), end: at(6, 0, 1), hideAfterEnd: true }, 0);
    expect(eventRetention(night, at(7, 0, 1))).toMatchObject({ state: 'due', dueAt: at(6, 0, 1) });
    expect(hiddenAfterEnd(night, at(5, 59, 1))).toBe(false);
    expect(hiddenAfterEnd(night, at(6, 0, 1))).toBe(true);
    // フラグなしの日またぎ予定は特則の対象外
    expect(hiddenAfterEnd({ ...night, hideAfterEnd: false }, at(7, 0, 1))).toBe(false);
  });
  it('継続中の繰り返しマスターは残し、過去の各回だけを個別に期限処理', () => {
    const m = makeEvent({ title: '授業', calendarId: 'c', start: at(10), end: at(11), recurrence: { freq: 'weekly', interval: 1, byWeekday: null, until: null } }, 0);
    expect(eventRetention(m, at(0, 0, 100)).state).toBe('keep');
    const due = dueOccurrences(m, at(12, 0, 45));
    expect(due).toEqual([at(10), at(10, 0, 7), at(10, 0, 14)]); // 45日後：終了から30日を過ぎた3回だけ
  });
  it('タスク：時間あり＝終了から30日、試験日あり＝試験日から30日、日時なし＝作成から30日、提出期限のみの課題は保留', () => {
    const timed = makeTask({ title: 't', plannedStart: at(9), plannedEnd: at(10) }, at(0));
    expect(taskRetention(timed)).toMatchObject({ state: 'due', dueAt: at(10) + 30 * DAY });
    const prep = makeTask({ title: 'p', special: 'testPrep', testPrep: { examAt: at(10, 0, 20), subjectId: null, subjectName: 'x' } }, at(0));
    expect(taskRetention(prep)).toMatchObject({ dueAt: at(10, 0, 20) + 30 * DAY });
    const bare = makeTask({ title: 'b' }, at(0));
    expect(taskRetention(bare)).toMatchObject({ dueAt: at(0) + 30 * DAY });
    const asg = makeTask({ title: 'a', special: 'assignment', assignment: { content: '', submitMethod: '', submitTo: '', deadline: at(23, 0, 3) } }, at(0));
    expect(taskRetention(asg).state).toBe('hold');
    expect(isDue(taskRetention(asg), at(0, 0, 400))).toBe(false);
  });
});

describe('分析', () => {
  const base = (f: Parameters<typeof makeTask>[0]) => makeTask(f, at(0));
  it('完了率・遅延率・実行時間。一時停止経験とARは初期設定で除外し、切替で含められる', () => {
    let a = applyTaskAction(base({ title: 'a', plannedStart: at(9), plannedEnd: at(10) }), 'start', at(9)).task;
    a = applyTaskAction(a, 'finish', at(10, 30)).task; // 遅延して完了
    let b = applyTaskAction(base({ title: 'b', plannedStart: at(11), plannedEnd: at(12) }), 'start', at(11)).task;
    b = applyTaskAction(b, 'finish', at(11, 30)).task;
    let p = applyTaskAction(base({ title: 'p', plannedStart: at(13), plannedEnd: at(14) }), 'start', at(13)).task;
    p = applyTaskAction(p, 'pause', at(13, 10)).task;
    const auto = { ...base({ title: 'ar', plannedStart: at(15), plannedEnd: at(16) }), autoReserved: true };
    const s = dayStats([a, b, p, auto], day, at(20));
    expect(s).toMatchObject({ total: 2, done: 2, completionRate: 1, delayed: 1, delayBase: 2, delayRate: 0.5, excluded: 2 });
    expect(s.workedMs).toBe(120 * MINUTE);
    const all = dayStats([a, b, p, auto], day, at(20), { includePaused: true, includeAuto: true });
    expect(all.total).toBe(4);
    expect(weekStats([a, b], addDays(day, -1), at(20)).total.done).toBe(2);
  });
});

describe('TimeTree・テキスト取込', () => {
  it('ICS を読み、UID と内容の指紋を持つ', () => {
    const ics = ['BEGIN:VCALENDAR', 'X-WR-CALNAME:ふたりの予定', 'BEGIN:VEVENT', 'UID:abc-1', 'SUMMARY:映画', 'DTSTART:20261012T100000Z', 'DTEND:20261012T120000Z', 'END:VEVENT', 'BEGIN:VEVENT', 'UID:abc-2', 'SUMMARY:旅', ' 行', 'DTSTART;VALUE=DATE:20261020', 'DTEND;VALUE=DATE:20261022', 'END:VEVENT', 'END:VCALENDAR'].join('\r\n');
    const r = parseICS(ics, 'partner');
    expect(r.map((c) => [c.externalId, c.title, c.owner, c.calendarName])).toEqual([['abc-1', '映画', 'partner', 'ふたりの予定'], ['abc-2', '旅行', 'partner', 'ふたりの予定']]);
    expect(r[0]!.start).toBe(Date.UTC(2026, 9, 12, 10));
  });
  it('テキストは1行1件、相手の予定・日付またぎ・読めない行を区別', () => {
    const { items, errors } = parseText('10/13 18:00-20:00 ご飯 @相手\n2026/10/14 22:00〜6:00 夜勤\nあいうえお', day);
    expect(items.map((i) => [i.title, i.owner, i.end - i.start])).toEqual([['ご飯', 'partner', 2 * HOUR], ['夜勤', 'me', 8 * HOUR]]);
    expect(errors).toEqual([{ line: 3, text: 'あいうえお' }]);
  });
  it('同じ予定・時間の重なり・新規を区別（無関係な予定を上書きしない）', () => {
    const { items } = parseText('10/13 18:00-20:00 ご飯\n10/13 19:00-21:00 映画\n10/14 9:00-10:00 散歩', day);
    const imported = makeEvent({ title: 'ご飯', calendarId: 'c', start: items[0]!.start, end: items[0]!.end, source: { type: 'text', externalId: null, fingerprint: items[0]!.fingerprint, owner: 'me', calendarName: null } }, 0);
    expect(classifyImport(items[0]!, [imported]).kind).toBe('same');
    const ov = classifyImport(items[1]!, [imported]);
    expect(ov.kind).toBe('overlap');
    expect(classifyImport(items[2]!, [imported]).kind).toBe('new');
  });
});

describe('同期の再試行・AR・通知', () => {
  it('指数バックオフ＋ジッター（上限あり）', () => {
    expect(retryDelay(0, 0)).toBe(1000);
    expect(retryDelay(0, 1)).toBe(2000);
    expect(retryDelay(3, 0.5)).toBe(12000);
    expect(retryDelay(20, 1)).toBe(600000);
  });
  it('AR：予約時刻に開始・終了した記録として反映（アプリを閉じていても時刻は正確）', () => {
    const t = makeTask({ title: 'ar', plannedStart: at(9), plannedEnd: at(10), autoStartAt: at(9), autoEndAt: at(10) }, 0);
    const trs = applyAutoReservation(t, at(12));
    const last = trs.at(-1)!.task;
    expect(trs.map((x) => x.log.action)).toEqual(['start', 'finish']);
    expect(last).toMatchObject({ status: 'done', actualStart: at(9), actualEnd: at(10), autoReserved: true, autoStartAt: null, autoEndAt: null });
    expect(applyAutoReservation(t, at(8, 59))).toEqual([]);
  });
  it('未開始通知・リマインダー・アルバイト2時間前・未設定は1日1回。予定には未開始通知を送らない', () => {
    const t = makeTask({ id: 't', title: '課題', plannedStart: at(10), plannedEnd: at(11), notifyMinutesBefore: 10 }, 0);
    const emp = makeEmployer('GU', 0);
    const job = makeEvent({ id: 'j', title: 'バイト', calendarId: 'cal-job', start: at(18), end: at(22), employerId: emp.id }, 0);
    const cls = makeEvent({ title: '授業', calendarId: 'cal-class', start: at(10), end: at(11) }, 0);
    const setupT = makeTask({ title: '課題2', special: 'assignment', assignment: { content: '', submitMethod: '', submitTo: '', deadline: null } }, 0);
    const n1 = planNotices([t], [cls], [], at(9, 52), 5 * MINUTE);
    expect(n1.map((n) => n.key)).toEqual([`remind:t:${at(10)}:10`]);
    const n2 = planNotices([t], [cls], [], at(10, 6), 5 * MINUTE);
    expect(n2).toEqual([expect.objectContaining({ body: NOT_STARTED_BODY })]);
    const n3 = planNotices([], [job], [emp], at(16, 2), 5 * MINUTE);
    expect(n3.map((n) => n.title)).toEqual(['【GU】2時間前']);
    expect(planNotices([setupT], [], [], at(20, 1), 5 * MINUTE)).toHaveLength(1);
    expect(planNotices([setupT], [], [], at(20, 10), 5 * MINUTE)).toHaveLength(0);
  });
});

describe('スナップショット検証', () => {
  it('件数・ハッシュ・スキーマ版が一致して初めて検証成功。改ざん・欠落は失敗', async () => {
    const { text, manifest } = await buildSnapshot({ schemaVersion: 2, kind: 'daily', userId: 'u', createdAt: 1, range: { from: 0, to: 1 }, tables: { tasks: [{ id: 'a', b: 1 }], events: [] } });
    expect((await verifySnapshot(text, manifest)).ok).toBe(true);
    expect((await verifySnapshot(text.replace('"b":1', '"b":2'), manifest)).ok).toBe(false);
    expect((await verifySnapshot(text, { ...manifest, counts: { tasks: 2, events: 0 } })).reason).toMatch(/ハッシュ|件数/);
  });
  it('旧スキーマのタスクは既定値を補って読み込む', () => {
    const old = { id: 'x', title: '古い', createdAt: 5, status: 'done' as const };
    const n = normalizeTask(old);
    expect(n).toMatchObject({ id: 'x', status: 'done', special: 'normal', tags: [], priority: 0 });
  });
});

describe('タイムゾーン（UTCで動くサーバーでも利用者の暦で判定）', () => {
  it('Asia/Tokyo を設定すると日付・曜日・時刻を日本時間で扱う', async () => {
    const { setDomainTimeZone, startOfDay: sod, weekday, formatHm: fhm, addMonths, crossesDate } = await import('./index');
    setDomainTimeZone('Asia/Tokyo');
    try {
      const t = Date.parse('2026-10-12T00:30:00+09:00'); // UTC では 11日
      expect(sod(t)).toBe(Date.parse('2026-10-12T00:00:00+09:00'));
      expect(weekday(t)).toBe(1);
      expect(fhm(t)).toBe('0:30');
      expect(addMonths(Date.parse('2026-01-31T08:00:00+09:00'), 1)).toBe(Date.parse('2026-02-28T08:00:00+09:00'));
      // 22:00〜翌6:00（日本時間）は日付をまたぐ。UTC では同じ日付だが正しく判定する
      expect(crossesDate({ start: Date.parse('2026-11-29T22:00:00+09:00'), end: Date.parse('2026-11-30T06:00:00+09:00') })).toBe(true);
    } finally {
      setDomainTimeZone(null);
    }
  });
});
