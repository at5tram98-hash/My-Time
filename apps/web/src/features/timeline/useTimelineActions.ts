import { useCallback } from 'react';
import { findConflicts, formatHm, makeEvent } from '@my-time/domain';
import { useData } from '../../app/data';
import { useUI } from '../../app/ui';
import { repo } from '../../data/repo';

/** 時間軸の共通操作（タップ・長押しメニュー・ドラッグ移動） */
export function useTimelineActions() {
  const { events, tasks } = useData();
  const { openSheet, choose, confirm, showToast } = useUI();

  const onMove = useCallback(
    async (kind: 'event' | 'task', id: string, newStart: number) => {
      try {
        if (kind === 'event') {
          const moved = await repo.moveEvent(id, newStart);
          const c = findConflicts({ id: moved.id, start: moved.start, end: moved.end }, events);
          showToast(c.length ? `${formatHm(newStart)}に移動（「${c[0]!.title}」と重なっています）` : `${formatHm(newStart)}に移動しました`);
        } else {
          await repo.moveTask(id, newStart);
          showToast(`${formatHm(newStart)}に移動しました`);
        }
      } catch (e) {
        showToast(e instanceof Error ? e.message : '移動できませんでした');
      }
    },
    [events, showToast],
  );

  const onItemMenu = useCallback(
    async (kind: 'event' | 'task', id: string) => {
      if (kind === 'event') {
        const ev = events.find((e) => e.id === id);
        if (!ev) return;
        const r = await choose({
          title: ev.title,
          message: `${formatHm(ev.start)}〜${formatHm(ev.end)}`,
          actions: [
            { label: '編集', value: 'edit' },
            { label: '複製', value: 'dup' },
            { label: '削除', value: 'delete', style: 'destructive' },
          ],
        });
        if (r === 'edit') openSheet({ kind: 'editEvent', eventId: id });
        if (r === 'dup') {
          await repo.saveEvent(makeEvent({ title: ev.title, calendarId: ev.calendarId, start: ev.start, end: ev.end, notes: ev.notes }, Date.now()), true);
          showToast('複製しました');
        }
        if (r === 'delete' && (await confirm({ title: '予定を削除しますか？', message: `「${ev.title}」を削除します。`, confirmLabel: '削除', destructive: true }))) {
          await repo.deleteEvent(id);
          showToast('削除しました');
        }
      } else {
        const t = tasks.find((x) => x.id === id);
        if (!t) return;
        const r = await choose({ title: t.title, actions: [{ label: '詳細を表示', value: 'open' }, { label: '編集', value: 'edit' }] });
        if (r === 'open') openSheet({ kind: 'task', id });
        if (r === 'edit') openSheet({ kind: 'editTask', taskId: id });
      }
    },
    [events, tasks, choose, confirm, openSheet, showToast],
  );

  return {
    onMove: (k: 'event' | 'task', id: string, s: number) => void onMove(k, id, s),
    onItemMenu: (k: 'event' | 'task', id: string) => void onItemMenu(k, id),
    onOpenEvent: (id: string) => openSheet({ kind: 'editEvent', eventId: id }),
    onOpenTask: (id: string) => openSheet({ kind: 'task', id }),
  };
}
