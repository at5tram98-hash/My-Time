import { useState } from 'react';
import { motion, useReducedMotion } from 'motion/react';
import { useUI } from '../../app/ui';
import { useSync } from '../../app/data';
import { summaryText } from '../../data/accounts';
import { syncEngine } from '../../sync/engine';

/**
 * ログインしていない間にこの端末で作ったデータがある状態でログインしたときの確認。
 * 移行先のアカウントと件数を見せ、本人が選ぶまで何も送らない。
 */
export function AccountChoice() {
  const sync = useSync();
  const { showToast } = useUI();
  const reduce = useReducedMotion();
  const [busy, setBusy] = useState(false);
  const p = sync.pendingMigration;
  if (sync.phase !== 'chooseAccount' || !p) return null;
  const choose = async (migrate: boolean) => {
    setBusy(true);
    try {
      await syncEngine.resolveMigration(migrate);
    } catch (e) {
      showToast(e instanceof Error ? e.message : '移行できませんでした。元データはこの端末に残っています');
    } finally {
      setBusy(false);
    }
  };
  const s = p.summary;
  const rows: [string, number][] = [
    ['タスク', s.tasks],
    ['予定', s.events],
    ['サブタスク', s.subtasks],
    ['カレンダー', s.calendars],
    ['科目', s.subjects],
    ['勤務先', s.employers],
  ];
  return (
    <div className="alert-backdrop" data-testid="account-choice">
      <motion.div
        className="account-choice"
        role="alertdialog"
        aria-modal="true"
        aria-labelledby="ac-title"
        aria-describedby="ac-body"
        initial={reduce ? { opacity: 0 } : { opacity: 0, scale: 1.08 }}
        animate={{ opacity: 1, scale: 1 }}
        transition={reduce ? { duration: 0.1 } : { type: 'spring', stiffness: 520, damping: 36 }}
      >
        <h2 id="ac-title" className="ac-title">この端末のデータをアカウントに移しますか？</h2>
        <p id="ac-body" className="ac-body">ログインしていない間に、この端末だけに保存したデータがあります。</p>
        <dl className="ac-counts" data-testid="ac-counts">
          {rows.filter(([, n]) => n > 0).map(([label, n]) => (
            <div key={label} className="ac-count"><dt>{label}</dt><dd>{n}件</dd></div>
          ))}
        </dl>
        <div className="ac-target">
          <span className="ac-target-label">移行先</span>
          <span className="ac-target-value" data-testid="ac-target">{p.me.user.email}</span>
        </div>
        <p className="ac-note">移行後も元のデータはこの端末に残り、ログアウトすると表示されます。コピーしたデータは選んだアカウントで同期・バックアップされます。</p>
        <div className="ac-actions">
          <button type="button" className="ac-btn primary" disabled={busy} onClick={() => void choose(true)} data-testid="ac-migrate">
            {summaryText(s)}を移して同期
          </button>
          <button type="button" className="ac-btn" disabled={busy} onClick={() => void choose(false)} data-testid="ac-keep">
            移さない（この端末に残す）
          </button>
        </div>
      </motion.div>
    </div>
  );
}
