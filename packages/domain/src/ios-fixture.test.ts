import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import {
  addDays, applyTaskAction, canonicalJson, defaultCalendars, expandEvent, fromWall, idealProgress, layoutDay, makeEmployer, makeEvent, makeSubtask, makeTask,
  setDomainTimeZone, sha256Hex, shiftPay, startOfDay, tasksForDay, type Task,
} from './index';

/**
 * iOS 版（ios/Packages/MyTimeCore）との互換性の基準データ。
 * Web 版の実際のコードで「移行ファイル」と計算結果を作り、Swift のテストが同じ結果になるかを確かめる。
 * - 通常の `pnpm test` では、保存済みの基準データが今の Web 版の出力と一致するかを確かめる（片方だけ変えたら失敗する）。
 * - 作り直すとき：GEN_IOS_FIXTURE=1 pnpm exec vitest run packages/domain/src/ios-fixture.test.ts
 */
const FIXTURE = fileURLToPath(new URL('../../../ios/Packages/MyTimeCore/Tests/MyTimeCoreTests/Fixtures/web-compat.json', import.meta.url));

async function build() {
  setDomainTimeZone('Asia/Tokyo');
  try {
    const day = fromWall(2026, 10, 16); // 2026-11-16（月）0:00 JST
    const at = (h: number, m = 0, d = 0) => addDays(day, d) + h * 3_600_000 + m * 60_000;
    const now = at(10, 40);
    const cals = defaultCalendars(at(0));
    const task: Task = {
      ...makeTask({ id: 'task-1', title: '統計のレポート "引用" \\ 改行\n😀 é', plannedStart: at(10), plannedEnd: at(12), estimateMinutes: 120, tags: ['大学', 'ゼミ'], extra: { spec: { type: 'assignment', details: { dueAt: at(23, 59, 4), ratio: 0.4, tiny: 1e-7 } }, travelMinutes: 15 } }, at(0)),
      timeZone: 'Asia/Tokyo',
    };
    const check = { ...makeTask({ id: 'task-2', title: '書類を確認', kind: 'check', checkAt: at(12) }, at(0)), timeZone: 'Asia/Tokyo' };
    const sub = { ...makeSubtask('task-1', '構成を考える', 0, at(0)), id: 'sub-1' };
    const weekly = { ...makeEvent({ id: 'ev-1', title: 'ゼミ', calendarId: 'cal-class', start: at(13), end: at(14, 30), recurrence: { freq: 'weekly', interval: 1, byWeekday: [1, 3], until: null }, exceptions: [{ originalStart: at(13, 0, 2), kind: 'cancelled' }] }, at(0)), timeZone: 'Asia/Tokyo' };
    const shift = { ...makeEvent({ id: 'ev-2', title: 'GU 勤務', calendarId: 'cal-job', start: at(18, 30), end: at(22), employerId: 'emp-1', extra: { spec: { type: 'shift', details: { hourlyWage: 1300, breakMinutes: 0 } } } }, at(0)), timeZone: 'Asia/Tokyo' };
    const emp = { ...makeEmployer('GU', at(0)), id: 'emp-1' };
    const body = {
      format: 'my-time-device-transfer', version: 1, owner: null, origin: 'https://example.invalid', createdAt: now,
      tables: {
        calendars: cals, events: [weekly, shift], tasks: [task, check], subtasks: [sub], subjects: [], employers: [emp], categories: [], studioTypes: [],
        operationLog: [{ seq: 1, id: 'log-1', at: at(0), entity: 'task', entityId: 'task-1', action: 'create' }],
        outbox: [{ opId: 'op-1', at: at(0), entity: 'task', entityId: 'task-1', op: 'put', synced: 0 }],
        settings: [{ key: 'app', theme: 'dark', homeSplit: 0.4, laneFocus: 'main', onboarded: true }],
        meta: [], syncState: [], notices: [], drafts: [], recovery: [],
      },
    };
    const transfer = JSON.stringify({ body, sha256: await sha256Hex(canonicalJson(body)) });

    const started = applyTaskAction(task, 'start', at(10, 5)).task;
    const paused = applyTaskAction(started, 'pause', at(10, 35)).task;
    const lay = layoutDay([{ id: 'a', start: at(9), end: at(11) }, { id: 'b', start: at(10), end: at(12) }, { id: 'c', start: at(13), end: at(13, 5) }, { id: 'd', start: at(23), end: at(2, 0, 1) }], day);
    const samples = [{ s: 1, n: 0.4, e: 1e-7, big: 1e21, neg: -5, z: 0 }, 'tab\tquote"back\\slash ctrl\u0001 ✓', { b: 1, a: [true, false, null], ä: 'x', B: 2 }];
    return {
      timeZone: 'Asia/Tokyo',
      day, now,
      transfer,
      canonical: await Promise.all(samples.map(async (v) => ({ value: JSON.stringify(v), canonical: canonicalJson(v), sha256: await sha256Hex(canonicalJson(v)) }))),
      expect: {
        idealAtNow: idealProgress(task, now),
        layout: lay,
        weeklyIds: expandEvent(weekly, day, addDays(day, 14)).map((o) => o.id),
        tasksForDay: tasksForDay([task, check], day).map((t) => t.id),
        startOfDayPlus1: startOfDay(addDays(day, 1)),
        paused: { status: paused.status, intervals: paused.intervals, pausedEver: paused.pausedEver, actualStart: paused.actualStart },
        shiftPay: shiftPay(at(18, 30), at(22), 1300, 0),
      },
    };
  } finally {
    setDomainTimeZone(null);
  }
}

describe('iOS 版との互換性の基準データ', () => {
  it('保存済みの基準データが、今の Web 版の出力と一致する', async () => {
    const data = await build();
    if (process.env.GEN_IOS_FIXTURE === '1') writeFileSync(FIXTURE, `${JSON.stringify(data, null, 2)}\n`);
    const saved = JSON.parse(readFileSync(FIXTURE, 'utf8')) as unknown;
    expect(saved).toEqual(JSON.parse(JSON.stringify(data)));
  });
});
