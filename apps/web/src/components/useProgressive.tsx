import { useEffect, useRef, useState } from 'react';

/**
 * 長い一覧を少しずつ描画する（可視範囲＋先読み分だけ）。末尾の目印が画面に近づいたら件数を増やす。
 * key が変わったら（絞り込み・切替）先頭から数え直す。
 */
export function useProgressive(total: number, key: unknown, initial = 80, step = 120) {
  const [limit, setLimit] = useState(initial);
  const sentinel = useRef<HTMLDivElement | null>(null);
  useEffect(() => setLimit(initial), [key, initial]);
  useEffect(() => {
    const el = sentinel.current;
    if (!el || limit >= total || typeof IntersectionObserver === 'undefined') return;
    const io = new IntersectionObserver((entries) => {
      if (entries.some((e) => e.isIntersecting)) setLimit((l) => Math.min(total, l + step));
    }, { rootMargin: '800px 0px' });
    io.observe(el);
    return () => io.disconnect();
  }, [limit, total, step]);
  const more = limit < total ? <div ref={sentinel} className="progressive-sentinel" aria-hidden style={{ height: 1 }} /> : null;
  return { limit: typeof IntersectionObserver === 'undefined' ? total : limit, more };
}
