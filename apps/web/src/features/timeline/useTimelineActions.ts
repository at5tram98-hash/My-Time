import { useCallback } from 'react';
import { expandEvent, formatHm, makeEvent, parseOccurrenceId } from '@my-time/domain';
import { useData } from '../../app/data';
import { useUI } from '../../app/ui';
import { usePlacementGuard } from '../../app/usePlacementGuard';
import { repo } from '../../data/repo';

export type RecurrenceScope = 'this' | 'future';

/** 繰り返し予定を変更・削除するときの範囲（iOS カレンダーと同じ選び方） */
export function useAskScope() {
  const { choose } = useUI();
  return useCallback(
    (verb: '変更' | '削除' | '移動') =>
      choose<RecurrenceScope>({
        title: `繰り返しの予定を${verb}します`,
        actions: [
          { label: 'この予定のみ', value: 'this' },
          { label: 'これ以降のすべての予定', value: 'future', style: verb === '削除' ? 'destructive' : 'default' },
        ],
      }),
    [choose],
  );
}

/** 時間軸の共通操作（タップ・予定の長押しメニュー・ドラッグ移動） */
export function useTimelineActions() {
  const { events, tasks } = useData();
  const { openSheet, choose, confirm, showToast } = useUI();
  const guard = usePlacementGuard();
  const askScope = useAskScope();

  /** 予定ID（繰り返しの回は 'マスター@開始'）から、表示中の開始・終了を求める */
  const resolveEvent = useCallback(
    (id: string) => {
      const occ = parseOccurrenceId(id);
      const master = events.find((e) => e.id === (occ?.masterId ?? id));
      if (!master) return null;
      if (!occ) return { master, start: master.start, end: master.end, originalStart: null as number | null };
      const inst = expandEvent(master, occ.originalStart - 86_400_000 * 8, occ.originalStart + 86_400_000 * 8).find((o) => o.id === id);
      return inst ? { master, start: inst.start, end: inst.end, originalStart: occ.originalStart } : null;
    },
    [events],
  );

  /** ドラッグ移動：重複を確認し、承認されたときだけ保存する（キャンセル時はデータも操作ログも変更しない） */
  const onMove = useCallback(
    async (kind: 'event' | 'task', id: string, newStart: number) => {
      try {
        if (kind === 'event') {
          const r = resolveEvent(id);
          if (!r) return;
          const decision = await guard({ id: `event:${id}`, start: newStart, end: newStart + (r.end - r.start) }, '移動');
          if (!decision) return;
          if (r.originalStart != null) {
            const scope = await askScope('移動');
            if (!scope) return;
            await repo.editOccurrence(r.master.id, r.originalStart, { start: decision.start, end: decision.end }, scope);
          } else await repo.moveEvent(id, decision.start);
          showToast(`${formatHm(decision.start)}に移動しました`);
        } else {
          const t = tasks.find((x) => x.id === id);
          if (!t || t.plannedStart == null || t.plannedEnd == null) return;
          const decision = await guard({ id: `task:${id}`, start: newStart, end: newStart + (t.plannedEnd - t.plannedStart) }, '移動');
          if (!decision) return;
          await repo.moveTask(id, decision.start);
          showToast(`${formatHm(decision.start)}に移動しました`);
        }
      } catch (e) {
        showToast(e instanceof Error ? e.message : '移動できませんでした');
      }
    },
    [resolveEvent, tasks, guard, askScope, showToast],
  );

  const onEventMenu = useCallback(
    async (id: string) => {
      const r = resolveEvent(id);
      if (!r) return;
      const ev = r.master;
      const act = await choose({
        title: ev.title,
        message: `${formatHm(r.start)}〜${formatHm(r.end)}`,
        actions: [
          { label: '編集', value: 'edit' },
          { label: '複製', value: 'dup' },
          { label: '別の日にコピー', value: 'copy' },
          { label: '削除', value: 'delete', style: 'destructive' },
        ],
      });
      if (act === 'edit') openSheet({ kind: 'editEvent', eventId: id });
      if (act === 'copy') openSheet({ kind: 'copyEvent', eventId: id });
      if (act === 'dup') {
        await repo.saveEvent(makeEvent({ title: ev.title, calendarId: ev.calendarId, start: r.start, end: r.end, notes: ev.notes, classInfo: null, employerId: ev.employerId }, Date.now()), true);
        showToast('複製しました');
      }
      if (act === 'delete') {
        if (r.originalStart != null) {
          const scope = await askScope('削除');
          if (!scope) return;
          await repo.deleteOccurrence(ev.id, r.originalStart, scope);
        } else {
          if (!(await confirm({ title: '予定を削除しますか？', message: `「${ev.title}」を削除します。`, confirmLabel: '削除', destructive: true }))) return;
          await repo.deleteEvent(ev.id);
        }
        showToast('削除しました');
      }
    },
    [resolveEvent, choose, confirm, askScope, openSheet, showToast],
  );

  return {
    onMove,
    onEventMenu: (id: string) => void onEventMenu(id),
    onOpenEvent: (id: string) => openSheet({ kind: 'editEvent', eventId: id }),
    onOpenTask: (id: string) => openSheet({ kind: 'task', id }),
  };
}
