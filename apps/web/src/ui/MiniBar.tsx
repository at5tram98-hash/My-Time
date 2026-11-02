import { useEffect, useState } from 'react';
import { AnimatePresence, motion } from 'motion/react';
import { workedMs } from '@my-time/domain';
import { useData } from '../app/data';
import { useUI } from '../app/ui';
import { Ring } from './Ring';
import { Icon } from '../components/Icon';
import { repo } from '../data/repo';
import { SPRING } from './motion';

const fmt = (ms: number) => { const s = Math.floor(ms / 1000); const h = Math.floor(s / 3600); const m = Math.floor((s % 3600) / 60); return h ? `${h}:${String(m).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}` : `${m}:${String(s % 60).padStart(2, '0')}`; };

/**
 * 全タブ共通の実行中ミニバー（Q93）。ホームでは島が実行状態を担うので出さない（二重表示しない）。
 * タップで実行パネル、右のボタンで停止。
 */
export function RunningMiniBar() {
  const { tasks } = useData();
  const { tab, openSheet, sheets } = useUI();
  const running = tasks.find((t) => t.kind === 'do' && t.status === 'running');
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    if (!running) return;
    const i = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(i);
  }, [running]);
  const show = !!running && tab !== 'home' && sheets.length === 0;
  useEffect(() => { document.documentElement.toggleAttribute('data-minibar', show); }, [show]);
  return (
    <AnimatePresence>
      {show && running && (
        <motion.div className="minibar glass" initial={{ y: 30, opacity: 0 }} animate={{ y: 0, opacity: 1 }} exit={{ y: 30, opacity: 0 }} transition={SPRING.capsule} data-testid="minibar">
          <button type="button" className="minibar-main" onClick={() => openSheet({ kind: 'run', id: running.id })} aria-label={`実行中 ${running.title}。経過 ${fmt(workedMs(running, now))}。タップで実行パネル`}>
            <Ring value={running.plannedStart != null && running.plannedEnd != null ? Math.min(1, (now - running.plannedStart) / Math.max(1, running.plannedEnd - running.plannedStart)) : 0} size={30} icon={running.icon} />
            <span className="minibar-title">{running.title}</span>
            <span className="minibar-time">{fmt(workedMs(running, now))}</span>
          </button>
          <button type="button" className="gbtn glass-i" aria-label="停止" onClick={() => void repo.taskAction(running.id, 'pause')} data-testid="minibar-pause"><Icon name="pause" size={18} /></button>
        </motion.div>
      )}
    </AnimatePresence>
  );
}
