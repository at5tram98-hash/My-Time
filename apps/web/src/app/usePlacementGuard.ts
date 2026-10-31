import { useCallback } from 'react';
import { checkPlacement, formatHm, isSameDay, placementItems } from '@my-time/domain';
import { formatDayLabel } from '@my-time/domain';
import { useData } from './data';
import { useUI } from './ui';

export interface PlacementRequest {
  /** 'event:<id>' / 'task:<id>'。新規は自分と重ならない仮のID */
  id: string;
  start: number;
  end: number;
}

export type PlacementDecision = { start: number; end: number } | null;

/**
 * 保存前の重複確認（ドラッグ移動・新規・編集で共通）。
 * 重なりがなければそのまま返す。重なれば iOS 風アラートで「候補へ移動／重ねて保存／キャンセル」を選ばせ、
 * キャンセルなら null（呼び出し側は何も保存しない＝データも操作ログも変わらない）。
 */
export function usePlacementGuard() {
  const { events, tasks } = useData();
  const { ask } = useUI();

  return useCallback(
    async (req: PlacementRequest, verb: '移動' | '保存'): Promise<PlacementDecision> => {
      const { conflicts, suggestion } = checkPlacement(req, placementItems(events, tasks));
      if (conflicts.length === 0) return { start: req.start, end: req.end };
      const names = conflicts.slice(0, 2).map((c) => `「${c.title}」`).join('');
      const more = conflicts.length > 2 ? `ほか${conflicts.length - 2}件` : '';
      const slot = suggestion
        ? `${isSameDay(suggestion.start, req.start) ? '' : `${formatDayLabel(suggestion.start)} `}${formatHm(suggestion.start)}〜${formatHm(suggestion.end)}`
        : null;
      const choice = await ask<'suggest' | 'keep' | 'cancel'>({
        title: '時間が重なっています',
        message: `${names}${more}と重なります。${slot ? `空いている ${slot} に${verb}できます。` : ''}既存の予定は動かしません。`,
        buttons: [
          ...(slot ? [{ label: `${slot} に${verb}`, value: 'suggest' as const, style: 'default' as const }] : []),
          { label: `重ねて${verb}`, value: 'keep' as const },
          { label: 'キャンセル', value: 'cancel' as const, style: 'cancel' as const },
        ],
      });
      if (choice === 'suggest' && suggestion) return suggestion;
      if (choice === 'keep') return { start: req.start, end: req.end };
      return null;
    },
    [events, tasks, ask],
  );
}
