import { describe, expect, it } from 'vitest';
import {
  addDays, busyItems, deadlineCrowd, detectIssues, dayReview, estimateLearning, findSlots, focusHours, freeTime, HOUR, lifeAllocation, loadHeatmap, makeEvent, makeTask,
  MINUTE, nextAction, parseInput, payForecast, payPeriod, postponeOptions, prepBefore, readingPlan, remainingLoad, remainingWork, replanDay, routineForecast, searchItems,
  sessionsProposal, shiftPay, shiftProposal, SPEC_DEFS, specInsights, specOf, startOfDay, unionMinutes, unitsPerWeek, languageToday, leisureSuggestion,
  type CalEvent, type Task,
} from './index';

// 2026-11-15（日）10:00
const day = startOfDay(new Date(2026, 10, 15, 12).getTime());
const at = (h: number, m = 0, d = 0) => addDays(day, d) + h * HOUR + m * MINUTE;
const NOW = at(10);
const ctx = (events: CalEvent[] = [], tasks: Task[] = []) => ({ now: NOW, events, tasks, subtasks: [], employers: [] });

describe('専門の種類（S01〜S25）', () => {
  it('25種類が重複なく定義され、コードが S01〜S25', () => {
    expect(SPEC_DEFS).toHaveLength(25);
    expect(new Set(SPEC_DEFS.map((d) => d.id)).size).toBe(25);
    expect(SPEC_DEFS.map((d) => d.code)).toEqual(Array.from({ length: 25 }, (_, i) => `S${String(i + 1).padStart(2, '0')}`));
  });
  it('S01：18:30〜22:00・時給1,300円・休憩0分は 4,550円（交通費別・税引前）', () => {
    expect(shiftPay(at(18, 30), at(22), 1300, 0)).toEqual({ pay: 4550, workMinutes: 210 });
    const ev = makeEvent({ title: 'GU 勤務', calendarId: 'c', start: at(18, 30), end: at(22), extra: { spec: { type: 'shift', details: { hourlyWage: 1300, breakMinutes: 0, workplace: 'GU' } } } }, NOW);
    const ins = specInsights(ev, specOf(ev)!, ctx([ev]));
    expect(ins.find((i) => i.label === '給与見込み')).toMatchObject({ value: '4,550円', tone: 'estimate' });
    expect(ins.find((i) => i.label === '給与見込み')!.note).toContain('交通費別');
  });
  it('S01：時給が未入力なら給与を作らない', () => {
    expect(shiftPay(at(9), at(12), null)).toBeNull();
  });
  it('S05：見積120分・60分実施で残り60分。実績がなければ暫定', () => {
    const t = makeTask({ title: '課題', estimateMinutes: 120, intervals: [{ start: at(8), end: at(9) }] }, NOW);
    expect(remainingWork(t, NOW)).toEqual({ remaining: 60, worked: 60, provisional: false });
    expect(remainingWork({ ...t, intervals: [] }, NOW)).toMatchObject({ remaining: 120, provisional: true });
  });
  it('S12：今のページが未入力なら推測しない／入力があれば1日あたり', () => {
    expect(readingPlan(300, null, null, NOW)).toBeNull();
    expect(readingPlan(300, 180, at(0, 0, 5), NOW)).toEqual({ remaining: 120, perDay: 20, days: 6 });
  });
  it('S08：残り単元を週数で割る', () => { expect(unitsPerWeek(6, at(0, 0, 21), NOW)).toBe(2); });
  it('S07：分野を日ごとに回す', () => { expect(languageToday(['A', 'B'], at(0))).not.toBe(languageToday(['A', 'B'], at(0, 0, 1))); });
  it('S18：工程の残りから終わる見込み', () => {
    const f = routineForecast([{ title: '洗顔', minutes: 10 }, { title: '朝食', minutes: 20 }], [{ id: 's', taskId: 't', title: '洗顔', done: true, completedAt: NOW, order: 0, createdAt: 0, updatedAt: 0 }], NOW);
    expect(f).toEqual({ total: 30, remaining: 20, endAt: NOW + 20 * MINUTE });
  });
  it('S03：締め日の期間と、予測額と入金を区別', () => {
    const p = payPeriod(new Date(2026, 11, 25).getTime(), 15);
    expect(new Date(p.from).getDate()).toBe(16);
    expect(new Date(p.to - 1).getDate()).toBe(15);
    const shift = makeEvent({ title: 'GU', calendarId: 'c', start: new Date(2026, 10, 20, 18).getTime(), end: new Date(2026, 10, 20, 22).getTime(), extra: { spec: { type: 'shift', details: { hourlyWage: 1000, workplace: 'GU' } } } }, NOW);
    const payday = makeEvent({ title: '給料日', calendarId: 'c', start: new Date(2026, 11, 25).getTime(), end: new Date(2026, 11, 25, 1).getTime(), extra: { spec: { type: 'payday', details: { workplace: 'GU', closingDay: 15 } } } }, NOW);
    const ins = specInsights(payday, specOf(payday)!, ctx([shift, payday]));
    expect(ins.find((i) => i.label === '見込み額')!.value).toBe('4,000円');
    expect(ins.find((i) => i.label === '入金')!.value).toBe('未確認');
  });
  it('S13：営業時間が不明なら「未確認」', () => {
    const t = makeTask({ title: '買い物', extra: { spec: { type: 'shopping', details: {} } } }, NOW);
    expect(specInsights(t, specOf(t)!, ctx()).find((i) => i.label === '営業時間')!.value).toBe('未確認');
  });
  it('S17：移動時間が未入力でも0分として扱わない', () => {
    const e = makeEvent({ title: '移動', calendarId: 'c', start: at(12), end: at(12, 30), extra: { spec: { type: 'transit', details: {} } } }, NOW);
    expect(specInsights(e, specOf(e)!, ctx()).find((i) => i.label === '所要時間')).toMatchObject({ value: '未入力', tone: 'warn' });
  });
  it('S22：テスト結果は記録されるまで「未記録」', () => {
    const t = makeTask({ title: '開発', extra: { spec: { type: 'project', details: {} } } }, NOW);
    expect(specInsights(t, specOf(t)!, ctx()).find((i) => i.label === 'テスト結果')!.value).toBe('未記録');
  });
  it('S24：支払い済みは自分で記録するまで確定しない', () => {
    const t = makeTask({ title: '家賃', kind: 'check', checkAt: at(0, 0, 3), extra: { spec: { type: 'payment', details: { amount: 50000 } } } }, NOW);
    expect(specInsights(t, specOf(t)!, ctx()).find((i) => i.label === '状態')!.value).toBe('未確認');
  });
  it('旧データの種類（授業・勤務先・課題・テスト対策）を読み替えるが保存値は変えない', () => {
    const t = makeTask({ title: '課題', special: 'assignment' }, NOW);
    expect(specOf(t)?.type).toBe('assignment');
    expect(t.extra).toBeUndefined();
    const e = makeEvent({ title: '勤務', calendarId: 'c', start: at(9), end: at(10), employerId: 'emp' }, NOW);
    expect(specOf(e)?.type).toBe('shift');
  });
});

describe('空き時間と提案', () => {
  const lunch = makeEvent({ title: '昼', calendarId: 'c', start: at(12), end: at(13) }, NOW);
  it('重なりを二重に数えない', () => {
    expect(unionMinutes([{ start: at(9), end: at(11) }, { start: at(10), end: at(12) }], at(0), at(24))).toBe(180);
  });
  it('空き枠は予定を避けて、今より後から探す', () => {
    const s = findSlots(90, busyItems([lunch], []), NOW, at(23), 2);
    expect(s[0]).toEqual({ start: at(10), end: at(11, 30) });
    expect(s.every((x) => x.end <= at(12) || x.start >= at(13))).toBe(true);
  });
  it('P30：延期は期限を動かさず、期限を過ぎる候補には注意を付ける', () => {
    const t = makeTask({ title: '課題', plannedStart: at(8), plannedEnd: at(9), special: 'assignment', assignment: { content: '', submitMethod: '', submitTo: '', deadline: at(20) } }, NOW);
    const opts = postponeOptions(t, busyItems([lunch], [t]), NOW);
    expect(opts.map((o) => o.id.split(':').at(-1))).toEqual(['later', 'tomorrow', 'inbox']);
    expect(opts[1]!.warnings[0]).toContain('期限');
    expect(opts[2]!.changes[0]!.after).toEqual({ start: null, end: null });
  });
  it('P29：作業枠に分けて期限までの空きに置く', () => {
    const t = makeTask({ title: 'レポート', estimateMinutes: 120 }, NOW);
    const p = sessionsProposal(t, 120, 60, busyItems([lunch], []), NOW, at(23))!;
    expect(p.sessions!.map((s) => s.title)).toEqual(['着手', '見直し']);
    expect(p.sessions!.every((s) => s.end - s.start === 60 * MINUTE)).toBe(true);
  });
  it('P05：再計画は予定を固定し、過ぎた未着手のタスクだけを今より後へ', () => {
    const late = makeTask({ title: '過ぎた課題', plannedStart: at(8), plannedEnd: at(9) }, NOW);
    const ok = makeTask({ title: '午後の作業', plannedStart: at(15), plannedEnd: at(16) }, NOW);
    const p = replanDay(day, [lunch], [late, ok], [], NOW);
    expect(p.changes.map((c) => c.id)).toEqual([late.id]);
    expect(p.changes[0]!.after.start).toBeGreaterThanOrEqual(NOW);
    expect(p.alternatives?.[0]?.title).toBe('明日に回す');
  });
  it('P04：ずらす差分につながった準備タスクも含め、重なりを注意する', () => {
    const ev = makeEvent({ id: 'ev', title: '勤務', calendarId: 'c', start: at(14), end: at(18) }, NOW);
    const prep = makeTask({ title: '準備', sourceEventId: 'ev', plannedStart: at(13, 40), plannedEnd: at(14) }, NOW);
    const other = makeEvent({ title: '夕食', calendarId: 'c', start: at(18, 30), end: at(19, 30) }, NOW);
    const p = shiftProposal('event', ev, 60, [prep], busyItems([ev, other], [prep]));
    expect(p.changes).toHaveLength(2);
    expect(p.warnings[0]).toContain('夕食');
  });
  it('準備は開始（移動を引いた時刻）から逆に並べる', () => {
    expect(prepBefore(at(17), 20, [{ title: 'A', minutes: 30 }, { title: 'B', minutes: 5 }])).toEqual([{ title: 'A', start: at(16, 5), end: at(16, 35) }, { title: 'B', start: at(16, 35), end: at(16, 40) }]);
  });
});

describe('問題の検知（P06〜P08・P39）', () => {
  it('二重登録・重なり・移動不足・期限不足を、理由つきで検出し、予定は動かす提案をしない', () => {
    const a = makeEvent({ title: '授業', calendarId: 'c', start: at(13), end: at(14, 30) }, NOW);
    const b = makeEvent({ title: '授業', calendarId: 'c', start: at(13), end: at(14, 30) }, NOW);
    const c = makeEvent({ title: '会議', calendarId: 'c', start: at(14), end: at(15) }, NOW);
    const d = makeEvent({ title: '勤務', calendarId: 'c', start: at(15, 10), end: at(18), extra: { travelMinutes: 30 } }, NOW);
    const t = makeTask({ title: 'レポート', estimateMinutes: 900, special: 'assignment', assignment: { content: '', submitMethod: '', submitTo: '', deadline: at(23) } }, NOW);
    const issues = detectIssues({ events: [a, b, c, d], tasks: [t], subtasks: [], now: NOW, from: day, to: addDays(day, 1) });
    const kinds = issues.map((i) => i.kind);
    expect(kinds).toContain('duplicate');
    expect(kinds).toContain('overlap');
    expect(kinds).toContain('travel');
    expect(kinds).toContain('deadline');
    expect(issues.filter((i) => i.kind === 'overlap' && i.refs.every((r) => r.entity === 'event')).every((i) => i.proposals.length === 0)).toBe(true);
    expect(issues.find((i) => i.kind === 'deadline')!.reason).toContain('見込み');
  });
  it('移動時間が未入力なら確信度を下げる', () => {
    const a = makeEvent({ title: '授業', calendarId: 'c', start: at(13), end: at(14), extra: { place: { name: '大学', address: '', lat: null, lng: null } } }, NOW);
    const b = makeEvent({ title: '勤務', calendarId: 'c', start: at(14, 20), end: at(18), extra: { place: { name: '駅前店', address: '', lat: null, lng: null } } }, NOW);
    const i = detectIssues({ events: [a, b], tasks: [], subtasks: [], now: NOW, from: day, to: addDays(day, 1) }).find((x) => x.kind === 'travel')!;
    expect(i.confidence).toBe('low');
  });
  it('タスクと予定の重なりは、タスクだけを空きへ動かす提案', () => {
    const a = makeEvent({ title: '授業', calendarId: 'c', start: at(13), end: at(15) }, NOW);
    const t = makeTask({ title: '読書', plannedStart: at(14), plannedEnd: at(15) }, NOW);
    const i = detectIssues({ events: [a], tasks: [t], subtasks: [], now: NOW, from: day, to: addDays(day, 1) }).find((x) => x.id === `tovl:${t.id}`)!;
    expect(i.proposals[0]!.changes[0]!.entity).toBe('task');
  });
});

describe('次の行動・振り返り', () => {
  it('P24：実行中 > まもなく始まるタスク > 出発 > 予定', () => {
    const run = makeTask({ title: '実行中', status: 'running', intervals: [{ start: at(9), end: null }] }, NOW);
    const soon = makeTask({ title: 'すぐ', plannedStart: at(10, 15), plannedEnd: at(11) }, NOW);
    expect(nextAction([], [run, soon], NOW).kind).toBe('continue');
    expect(nextAction([], [soon], NOW)).toMatchObject({ kind: 'start', title: 'すぐ' });
    const ev = makeEvent({ title: '病院', calendarId: 'c', start: at(10, 40), end: at(11, 30), extra: { travelMinutes: 30 } }, NOW);
    expect(nextAction([ev], [], NOW)).toMatchObject({ kind: 'leave' });
    expect(nextAction([], [], NOW).kind).toBe('free');
  });
  it('P32：余白率は重なりを二重に数えない', () => {
    const a = makeEvent({ title: 'A', calendarId: 'c', start: at(9), end: at(11) }, NOW);
    const b = makeEvent({ title: 'B', calendarId: 'c', start: at(10), end: at(12) }, NOW);
    expect(freeTime(day, busyItems([a, b], [])).busyMinutes).toBe(180);
  });
  it('P33・P36・P37：期限の集中・残り負荷・確定と見込みを分けた拘束時間', () => {
    const t1 = makeTask({ title: '課題1', estimateMinutes: 60, extra: { spec: { type: 'assignment', details: { dueAt: at(20, 0, 2) } } } }, NOW);
    const t2 = makeTask({ title: '課題2', estimateMinutes: 60, extra: { spec: { type: 'assignment', details: { dueAt: at(21, 0, 2) } } } }, NOW);
    expect(deadlineCrowd([t1, t2], NOW)[2]!.tasks).toHaveLength(2);
    expect(remainingLoad([t1], [], NOW)[0]).toMatchObject({ remaining: 60 });
    const ev = makeEvent({ title: '授業', calendarId: 'c', start: at(13), end: at(14) }, NOW);
    const tk = makeTask({ title: 'T', plannedStart: at(15), plannedEnd: at(15, 30) }, NOW);
    expect(loadHeatmap([ev], [tk], [], day, 1)[0]).toMatchObject({ fixedMinutes: 60, taskMinutes: 30 });
  });
  it('P35：給与見込みは勤務先別・二重登録は1回だけ', () => {
    const s = (id: string) => makeEvent({ id, title: 'GU', calendarId: 'c', start: at(18, 30), end: at(22), extra: { spec: { type: 'shift', details: { hourlyWage: 1300, workplace: 'GU', transportFee: 300 } } } }, NOW);
    expect(payForecast([s('a'), s('b')], [], day, addDays(day, 1))).toEqual([{ workplace: 'GU', shifts: 1, minutes: 210, pay: 4550, transport: 300, missingWage: 0 }]);
  });
  it('P26・P38：記録が少ないときは学習・傾向を出さない', () => {
    const done = (i: number) => makeTask({ title: `t${i}`, status: 'done', estimateMinutes: 60, intervals: [{ start: at(9), end: at(10, 30) }], actualEnd: at(10, 30) }, NOW);
    expect(estimateLearning([done(1), done(2)], makeTask({ title: 'x' }, NOW), NOW)).toBeNull();
    expect(estimateLearning([done(1), done(2), done(3)], makeTask({ title: 'x' }, NOW), NOW)).toEqual({ ratio: 1.5, samples: 3 });
    expect(focusHours([done(1)], day, addDays(day, 1))).toBeNull();
    expect(focusHours([1, 2, 3, 4, 5].map(done), day, addDays(day, 1))!.best).toBe(9);
  });
  it('P34：分類は種類から決まる', () => {
    const ev = makeEvent({ title: '勤務', calendarId: 'c', start: at(9), end: at(12), extra: { spec: { type: 'shift', details: {} } } }, NOW);
    expect(lifeAllocation([ev], [], day, addDays(day, 1), NOW)).toEqual([{ group: 'work', minutes: 180 }]);
  });
  it('P40：未完了を明日の空きへ置く提案', () => {
    const t = makeTask({ title: '残り', plannedStart: at(8), plannedEnd: at(9) }, NOW);
    const r = dayReview(day, [], [t], [], at(22));
    expect(r.unfinished).toHaveLength(1);
    expect(r.proposal!.changes[0]!.after.start).toBeGreaterThanOrEqual(addDays(day, 1));
  });
  it('S25：自由時間の候補は空きを埋め尽くさない', () => {
    const busy = busyItems([makeEvent({ title: '長い', calendarId: 'c', start: at(7), end: at(21) }, NOW)], []);
    expect(leisureSuggestion(day, busy, 90, NOW)).toBeNull();
    expect(leisureSuggestion(day, [], 60, NOW)).not.toBeNull();
  });
});

describe('文章からの入力（P01〜P05・例A〜C）', () => {
  it('例A：土曜日はGU 18:30〜22:00、時給1,300円 → 勤務の予定・給与の根拠つき', () => {
    const r = parseInput('土曜日はGU 18:30〜22:00、時給1,300円', ctx());
    expect(r.intent).toBe('create');
    if (r.intent !== 'create') return;
    expect(r.candidates).toHaveLength(1);
    const c = r.candidates[0]!;
    expect(c).toMatchObject({ entity: 'event', spec: 'shift', workplace: 'GU', timeCertain: true });
    expect(new Date(c.start!).getDay()).toBe(6);
    expect(c.end! - c.start!).toBe(210 * MINUTE);
    expect(c.details).toMatchObject({ hourlyWage: 1300, breakMinutes: 0 });
    expect(shiftPay(c.start!, c.end!, 1300, 0)!.pay).toBe(4550);
    expect(c.prep[0]!.title).toBe('出勤の準備');
  });
  it('例B：金曜までに経済学のレポート、2時間ぐらい → 締切は保持し、作業枠を候補に', () => {
    const r = parseInput('金曜までに経済学のレポート、2時間ぐらい', ctx());
    if (r.intent !== 'create') throw new Error(r.intent);
    const c = r.candidates[0]!;
    expect(r.candidates).toHaveLength(1);
    expect(c).toMatchObject({ entity: 'task', spec: 'assignment', title: '経済学のレポート', estimateMinutes: 120, start: null });
    expect(new Date(c.due!).getDay()).toBe(5);
    expect(c.sessions.map((s) => s.title)).toEqual(['着手', '見直し']);
    expect(c.sessions.every((s) => s.end <= c.due!)).toBe(true);
  });
  it('例C：17時に出かける → 左に外出、右に身支度の候補', () => {
    const r = parseInput('17時に出かける', ctx());
    if (r.intent !== 'create') throw new Error(r.intent);
    const c = r.candidates[0]!;
    expect(c).toMatchObject({ entity: 'event', spec: 'outing', title: '外出', start: at(17) });
    expect(c.prep.map((p) => p.title)).toEqual(['髪・身支度', '持ち物の確認']);
    expect(c.prep.at(-1)!.end).toBe(at(17));
    expect(c.reasons.join()).toContain('移動時間は分からない');
  });
  it('P01：明日は課題2つと買い物 → 3件、明日の空きを候補', () => {
    const r = parseInput('明日は課題2つと買い物', ctx());
    if (r.intent !== 'create') throw new Error(r.intent);
    expect(r.candidates.map((c) => c.title)).toEqual(['課題1', '課題2', '買い物']);
    expect(r.candidates.every((c) => c.start != null && startOfDay(c.start) === addDays(day, 1) && !c.timeCertain)).toBe(true);
    const starts = r.candidates.map((c) => c.start!);
    expect(new Set(starts).size).toBe(3);
  });
  it('P02：夕方・授業後は根拠つきの候補で、確定扱いにしない', () => {
    const cls = makeEvent({ title: '経済学', calendarId: 'c', start: at(13), end: at(14, 30), extra: { spec: { type: 'class', details: {} } } }, NOW);
    let r = parseInput('夕方に買い物', ctx([cls]));
    if (r.intent !== 'create') throw new Error(r.intent);
    expect(r.candidates[0]).toMatchObject({ timeCertain: false, start: at(17) });
    expect(r.candidates[0]!.reasons.join()).toContain('夕方');
    r = parseInput('授業後に図書館で勉強 1時間', ctx([cls]));
    if (r.intent !== 'create') throw new Error(r.intent);
    expect(r.candidates[0]!.start).toBe(at(14, 30));
    expect(r.candidates[0]!.reasons.join()).toContain('経済学');
  });
  it('P03：「来週のバイト」は検索。複数一致は一覧で返す', () => {
    const r = parseInput('来週のバイト', ctx());
    expect(r.intent).toBe('search');
    if (r.intent !== 'search') return;
    expect(r.query.spec).toBe('shift');
    const s1 = makeEvent({ title: 'GU', calendarId: 'c', start: at(18, 0, 7), end: at(22, 0, 7), extra: { spec: { type: 'shift', details: {} } } }, NOW);
    const s2 = makeEvent({ title: 'GU', calendarId: 'c', start: at(18, 0, 9), end: at(22, 0, 9), extra: { spec: { type: 'shift', details: {} } } }, NOW);
    const s3 = makeEvent({ title: 'GU', calendarId: 'c', start: at(18, 0, 1), end: at(22, 0, 1), extra: { spec: { type: 'shift', details: {} } } }, NOW);
    expect(searchItems(r.query, [s1, s2, s3], []).map((h) => h.at)).toEqual([s1.start, s2.start]);
  });
  it('P04：「明日のバイト前の勉強を1時間遅らせて」は変更（対象を特定してから差分）', () => {
    const r = parseInput('明日のバイト前の勉強を1時間遅らせて', ctx());
    expect(r).toMatchObject({ intent: 'shift', deltaMin: 60 });
    if (r.intent !== 'shift') return;
    expect(r.target.words).toEqual(['勉強']);
    expect(r.target.before).toBe('バイト');
    const job = makeEvent({ title: 'GU', calendarId: 'c', start: at(18, 0, 1), end: at(22, 0, 1), extra: { spec: { type: 'shift', details: {} } } }, NOW);
    const before = makeTask({ title: '英語の勉強', plannedStart: at(15, 0, 1), plannedEnd: at(16, 0, 1) }, NOW);
    const after = makeTask({ title: '勉強', plannedStart: at(22, 30, 1), plannedEnd: at(23, 0, 1) }, NOW);
    expect(searchItems(r.target, [job], [before, after]).map((h) => h.id)).toEqual([before.id]);
  });
  it('P05：「急用ができたので今日の課題を移して」は再計画', () => {
    expect(parseInput('急用ができたので今日の課題を移して', ctx())).toMatchObject({ intent: 'replan', day, spec: 'assignment' });
  });
  it('解釈できない文章は候補を作らず、書き方を案内する', () => {
    const r = parseInput('   ', ctx());
    if (r.intent !== 'create') throw new Error(r.intent);
    expect(r.candidates).toHaveLength(0);
    expect(r.notes[0]).toContain('書いてください');
  });
});

describe('ICS の書き出し（P15）', () => {
  it('書き出したものを読み戻すと、タイトル・時刻が一致し、繰り返し・取り消しの回を含む', async () => {
    const { toICS, parseICS } = await import('./index');
    const e = makeEvent({ id: 'e1', title: '会議, 定例; A', calendarId: 'c', start: at(13), end: at(14), recurrence: { freq: 'weekly', interval: 1, byWeekday: [1, 3], until: null }, exceptions: [{ originalStart: at(13, 0, 1), kind: 'cancelled' }] }, NOW);
    const ics = toICS([e]);
    expect(ics).toContain('RRULE:FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,WE');
    expect(ics).toContain('EXDATE:');
    const back = parseICS(ics);
    expect(back[0]).toMatchObject({ title: '会議, 定例; A', start: at(13), end: at(14), externalId: 'e1@mytime' });
  });
});
