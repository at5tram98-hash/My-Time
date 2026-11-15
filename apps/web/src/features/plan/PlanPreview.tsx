import { useState } from 'react';
import { motion, useReducedMotion } from 'motion/react';
import { formatHm, type Proposal } from '@my-time/domain';
import { Icon } from '../../components/Icon';
import { useUIActions } from '../../app/ui';
import { repo } from '../../data/repo';
import { offerUndo } from '../../ui/undo';
import { SPRING } from '../../ui/motion';

const md = (t: number | null) => { if (t == null) return '未割当'; const d = new Date(t); return `${d.getMonth() + 1}/${d.getDate()}（${'日月火水木金土'[d.getDay()]}）${formatHm(t)}`; };
const range = (s: number | null, e: number | null) => (s == null ? '未割当' : `${md(s)}〜${e != null ? formatHm(e) : ''}`);

/** 提案を適用し、数秒間「取り消す」を出す（P10）。適用できなければ理由を知らせる */
export function useApplyPlan() {
  const { showToast } = useUIActions();
  return async (p: Proposal): Promise<boolean> => {
    try {
      const u = await repo.applyPlan(p);
      offerUndo(`plan:${p.id}`, `${p.title}を適用しました`, async () => {
        const r = await repo.revertPlan(u);
        showToast(r.skipped ? `元に戻しました（その後に変更された${r.skipped}件はそのまま）` : '元に戻しました');
      });
      return true;
    } catch (e) {
      showToast(e instanceof Error ? e.message : '適用できませんでした');
      return false;
    }
  };
}

/**
 * 変更の差分（P04）：変更前 → 変更後、作る作業枠、注意。別の案（P09）は横に切り替える。
 * 「適用」を押すまで何も保存しない。
 */
export function PlanPreview({ proposal, onApplied, compact, testId = 'plan-preview' }: { proposal: Proposal; onApplied?: () => void; compact?: boolean; testId?: string }) {
  const options = [proposal, ...(proposal.alternatives ?? [])];
  const [idx, setIdx] = useState(0);
  const p = options[idx]!;
  const apply = useApplyPlan();
  const reduce = useReducedMotion();
  const [busy, setBusy] = useState(false);
  const empty = !p.changes.length && !(p.sessions?.length);
  return (
    <div className={`plan-preview ${compact ? 'compact' : ''}`} data-testid={testId}>
      {options.length > 1 && (
        <div className="plan-options" role="tablist" aria-label="案">
          {options.map((o, i) => <button key={o.id} type="button" role="tab" aria-selected={i === idx} className={i === idx ? 'on' : ''} onClick={() => setIdx(i)} data-testid={`plan-option-${i}`}>{i === 0 ? 'おすすめ' : o.title}</button>)}
        </div>
      )}
      {/* 前の案は即座に外し、新しい案だけを横から入れる（切替の途中で古い案の「変更」を押せないように） */}
        <motion.div key={p.id} initial={reduce ? { opacity: 0 } : { opacity: 0, x: 16 }} animate={{ opacity: 1, x: 0 }} transition={reduce ? { duration: 0.1 } : SPRING.pop}>
          <div className="plan-title">{p.title}</div>
          <p className="plan-reason"><Icon name="info" size={14} />{p.reason}</p>
          {p.changes.length > 0 && (
            <ul className="diff-list" aria-label="変更の内容">
              {p.changes.map((c) => (
                <li key={`${c.entity}:${c.id}`} className="diff-row" data-testid="diff-row">
                  <span className="diff-title" data-user-text>{c.title}</span>
                  <span className="diff-before">{range(c.before.start, c.before.end)}</span>
                  <Icon name="forward" size={14} strokeWidth={2.4} className="diff-arrow" />
                  <span className="diff-after">{range(c.after.start, c.after.end)}</span>
                </li>
              ))}
            </ul>
          )}
          {p.sessions?.length ? (
            <ul className="diff-list" aria-label="作る作業枠">
              {p.sessions.map((s) => <li key={`${s.start}`} className="diff-row new" data-testid="diff-session"><span className="diff-title">{s.title}</span><span className="diff-after">{range(s.start, s.end)}</span></li>)}
            </ul>
          ) : null}
          {p.warnings.map((w) => <p key={w} className="plan-warn" role="note"><Icon name="warning" size={14} />{w}</p>)}
          {!empty && (
            <button type="button" className="gbtn-primary glass-i plan-apply" disabled={busy} onClick={async () => { setBusy(true); const ok = await apply(p); setBusy(false); if (ok) onApplied?.(); }} data-testid="plan-apply">
              <Icon name="check" size={16} strokeWidth={2.6} />この内容で変更
            </button>
          )}
          {empty && <p className="muted small">変える必要のある項目はありません。</p>}
        </motion.div>
    </div>
  );
}
