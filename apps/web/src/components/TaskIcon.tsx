import { delayInfo, idealProgress, type Task } from '@my-time/domain';
import { Icon } from './Icon';
import { ItemIcon } from './ItemIcon';

/** ユーザー定義アイコン＋外周の理想進捗リング。遅延時は注意の記号に置換、完了時はチェック。 */
export function TaskIcon({ task, now, size = 40 }: { task: Task; now: number; size?: number }) {
  const stroke = 3;
  const r = (size - stroke) / 2;
  const c = 2 * Math.PI * r;
  const ideal = task.kind === 'do' && task.status !== 'done' ? idealProgress(task, now) ?? 0 : 0;
  const delayed = delayInfo(task, now).delayed;
  const done = task.status === 'done';
  let inner;
  if (done) inner = <span className="ti-done"><Icon name="check" size={size * 0.5} strokeWidth={3} /></span>;
  else if (delayed) inner = <span className="ti-warn" role="img" aria-label="遅延"><Icon name="exclamation" size={size * 0.5} strokeWidth={3} /></span>;
  else inner = <ItemIcon value={task.icon} size={Math.round(size * 0.5)} className="ti-glyph" />;
  return (
    <span className={`task-icon ${task.status === 'running' ? 'running' : ''}`} style={{ width: size, height: size }} data-ideal={Math.round(ideal * 100)}>
      <svg width={size} height={size} className="ti-ring" aria-hidden>
        <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke="var(--ring-track)" strokeWidth={stroke} />
        {ideal > 0 && !done && (
          <circle
            cx={size / 2}
            cy={size / 2}
            r={r}
            fill="none"
            stroke={delayed ? 'var(--orange)' : 'var(--ring-ideal)'}
            strokeWidth={stroke}
            strokeLinecap="round"
            strokeDasharray={`${c * ideal} ${c}`}
            transform={`rotate(-90 ${size / 2} ${size / 2})`}
          />
        )}
      </svg>
      {inner}
    </span>
  );
}
