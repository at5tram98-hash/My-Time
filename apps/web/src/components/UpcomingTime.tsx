import { useEffect, useState } from 'react';
import { AnimatePresence, motion, useReducedMotion } from 'motion/react';

/** Keep a stable accessible time while the visual label alternates gently. */
export function UpcomingTime({ at, now, text }: { at: number; now: number; text: string }) {
  const minutes = Math.ceil((at - now) / 60_000);
  const eligible = minutes > 0 && minutes <= 60;
  const reduce = useReducedMotion();
  const [relative, setRelative] = useState(false);
  useEffect(() => {
    setRelative(false);
    if (!eligible || reduce) return;
    const id = window.setInterval(() => setRelative((v) => !v), 4000);
    return () => window.clearInterval(id);
  }, [eligible, at, reduce]);
  const value = eligible && relative ? `あと${minutes}分` : text;
  return <span className="upcoming-time" aria-label={eligible ? `${text}開始、あと${minutes}分` : text} data-testid="upcoming-time">
    <span className="upcoming-time-visual" aria-hidden><AnimatePresence mode="wait" initial={false}>
      <motion.span key={value} initial={reduce ? false : { y: 7, opacity: 0, filter: 'blur(2px)' }} animate={{ y: 0, opacity: 1, filter: 'blur(0px)' }} exit={reduce ? undefined : { y: -7, opacity: 0 }} transition={{ duration: 0.24, ease: [0.22, 1, 0.36, 1] }}>{value}</motion.span>
    </AnimatePresence></span>
  </span>;
}
