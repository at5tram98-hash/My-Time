import { useCallback } from 'react';
import { formatHm, makeEvent } from '@my-time/domain';
import { useData } from '../../app/data';
import { useUI } from '../../app/ui';
import { usePlacementGuard } from '../../app/usePlacementGuard';
import { repo } from '../../data/repo';

/** 時間軸の共通操作（タップ・予定の長押しメニュー・ドラッグ移動） */
export function useTimelineActions() {
  const { events, tasks } = useData();
  const { openSheet, choose, confirm, showToast } = useUI();
  const guard = usePlacementGuard();

  /** ドラッグ移動：重複を確認し、承認されたときだけ保存する（キャンセル時はデータも操作ログも変えない） */
  const onMove = useCallback(
    async (kind: 'event' | 'task', id: string, newStart: number) => {
      const src = kind === 'event' ? events.find((e) => e.id === id) : tasks.find((t) => t.id === id);
      if (!src) return;
      const dur = kind === 'event' ? (src as (typeof events)[number]).end - (src as (typeof events)[number]).start : ((src as (typeof tasks)[number]).plannedEnd ?? 0) - ((src as (typeof tasks)[number]).plannedStart ?? 0);
      const decision = await guard({ id: `${kind}:${id}`, start: newStart, end: newStart + dur }, '移動');
      if (!decision) return;
      try {
        if (kind === 'event') await repo.moveEvent(id, decision.start);
        else await repo.moveTask(id, decision.start);
        showToast(`${formatHm(decision.start)}に移動しました`);
      } catch (e) {
        showToast(e instanceof Error ? e.message : '移動できませんでした');
      }
    },
    [events, tasks, guard, showToast],
  );

  const onEventMenu = useCallback(
    async (id: string) => {
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
    },
    [events, choose, confirm, openSheet, showToast],
  );

  return {
    onMove,
    onEventMenu: (id: string) => void onEventMenu(id),
    onOpenEvent: (id: string) => openSheet({ kind: 'editEvent', eventId: id }),
    onOpenTask: (id: string) => openSheet({ kind: 'task', id }),
  };
}
