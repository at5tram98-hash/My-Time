import { SPEC_BY_ID, type SpecTypeId } from '@my-time/domain';
import { Icon, type IconName } from '../../components/Icon';

/** 専門の種類のしるし（予定＝角丸四角、タスク＝円。色は種類ごと） */
export function SpecBadge({ type, size = 28, entity }: { type: SpecTypeId | null; size?: number; entity?: 'event' | 'task' }) {
  const def = type ? SPEC_BY_ID[type] : null;
  const shape = (entity ?? def?.entity ?? 'task') === 'event' ? 'sq' : 'ci';
  return (
    <span className={`spec-badge ${shape}`} style={{ width: size, height: size, ['--c' as string]: def?.color ?? '#8E8E93' }} aria-hidden>
      <Icon name={(def?.icon ?? 'circle') as IconName} size={Math.round(size * 0.58)} strokeWidth={2.1} />
    </span>
  );
}
