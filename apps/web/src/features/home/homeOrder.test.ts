import { expect, it } from 'vitest';
import { makeTask } from '@my-time/domain';
import { orderHomeTasks } from './homeOrder';

it('次のタスクを過去と完了より上にし、実行中を優先する。元の配列は変更しない', () => {
  const next = makeTask({ title: '次', plannedStart: 200 }, 0);
  const done = { ...makeTask({ title: '完了', plannedStart: 10 }, 0), status: 'done' as const };
  const late = makeTask({ title: '未着手', plannedStart: 20 }, 0);
  const running = { ...makeTask({ title: '実行中', plannedStart: 30 }, 0), status: 'running' as const };
  const list = [done, next, late, running];
  expect(orderHomeTasks(list, 100).map(t => t.title)).toEqual(['実行中', '次', '未着手', '完了']);
  expect(list[0]).toBe(done);
});
