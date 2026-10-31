import type { CalEvent, EpochMs, Task } from './types';
import { addDays, startOfDay } from './time';
import { findConflicts, suggestFreeSlot, type TimedItem } from './layout';

export interface PlacementItem extends TimedItem {
  title: string;
  kind: 'event' | 'task';
}

/** 重複判定の対象：予定と、時刻指定された未完了の実施タスク */
export function placementItems(events: readonly CalEvent[], tasks: readonly Task[]): PlacementItem[] {
  return [
    ...events.map((e) => ({ id: `event:${e.id}`, start: e.start, end: e.end, title: e.title, kind: 'event' as const })),
    ...tasks
      .filter((t) => t.kind === 'do' && t.status !== 'done' && t.plannedStart != null && t.plannedEnd != null)
      .map((t) => ({ id: `task:${t.id}`, start: t.plannedStart!, end: t.plannedEnd!, title: t.title, kind: 'task' as const })),
  ];
}

export interface PlacementCheck {
  conflicts: PlacementItem[];
  /** 既存の予定を動かさずに置ける最初の空き時間（同じ長さ）。見つからなければ null */
  suggestion: { start: EpochMs; end: EpochMs } | null;
}

/**
 * 移動・新規・編集の保存前に呼ぶ重複チェック。
 * 自分自身（id 一致）は除外する。既存の予定は決して動かさず、候補を「提案」するだけ。
 */
export function checkPlacement(target: TimedItem, others: readonly PlacementItem[]): PlacementCheck {
  const conflicts = findConflicts(target, others);
  if (conflicts.length === 0) return { conflicts, suggestion: null };
  const day = startOfDay(target.start);
  const suggestion = suggestFreeSlot(target, others, day) ?? suggestFreeSlot({ ...target, start: addDays(day, 1) + 8 * 3_600_000, end: addDays(day, 1) + 8 * 3_600_000 + (target.end - target.start) }, others, addDays(day, 1));
  return { conflicts, suggestion };
}
