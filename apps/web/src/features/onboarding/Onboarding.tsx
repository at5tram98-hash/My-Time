import { useRef, useState } from 'react';
import { motion, AnimatePresence, useReducedMotion } from 'motion/react';
import { defaultCalendarIcon, makeEmployer, makeSubject } from '@my-time/domain';
import { useData, useSync } from '../../app/data';
import { repo } from '../../data/repo';
import { api } from '../../sync/api';
import { db, type ThemePref } from '../../data/db';
import { ItemIcon } from '../../components/ItemIcon';
import { Icon } from '../../components/Icon';

type Step = 'welcome' | 'account' | 'calendars' | 'places' | 'notify' | 'appearance' | 'guide';
const STEPS: Step[] = ['welcome', 'account', 'calendars', 'places', 'notify', 'appearance', 'guide'];

/**
 * 初回セットアップ（カード式）。どのカードも「あとで」で進め、権限は必要なカードでだけ求める。
 * 歓迎 → Google ログインと Drive → カレンダー → 授業・勤務先 → 通知 → 外観 → 操作のガイド
 */
export function Onboarding() {
  const { calendars, settings } = useData();
  const sync = useSync();
  const reduce = useReducedMotion();
  const [i, setI] = useState(0);
  const [subjects, setSubjects] = useState('');
  const [employers, setEmployers] = useState('');
  const step = STEPS[i]!;
  // 切り替え直後（約0.4秒）のタップは無視する：連打で次のカードのボタンまで押され、手順が飛ぶのを防ぐ
  const changedAt = useRef(0);
  const next = () => {
    const t = performance.now();
    if (t - changedAt.current < 400) return;
    changedAt.current = t;
    if (i < STEPS.length - 1) setI(i + 1);
    else void repo.updateSettings({ onboarded: true });
  };

  // 二度押し・戻って再入力しても同じ名前を重複登録しない
  const saving = useRef(false);
  const savePlaces = async () => {
    if (saving.current) return;
    saving.current = true;
    try {
      const now = Date.now();
      const split = (v: string) => [...new Set(v.split(/[\n,、]/).map((x) => x.trim()).filter(Boolean))];
      const haveS = new Set((await db.subjects.toArray()).map((x) => x.name));
      for (const n of split(subjects)) if (!haveS.has(n)) await repo.saveSubject(makeSubject(n, now), true);
      const haveE = new Set((await db.employers.toArray()).map((x) => x.name));
      for (const n of split(employers)) if (!haveE.has(n)) await repo.saveEmployer(makeEmployer(n, now, settings.defaultJobReminderHours), true);
      next();
    } finally {
      saving.current = false;
    }
  };

  const card = (title: string, body: React.ReactNode, actions: React.ReactNode) => (
    <motion.div
      key={step}
      className="ob-card"
      initial={reduce ? { opacity: 0 } : { opacity: 0, x: 60 }}
      animate={{ opacity: 1, x: 0 }}
      exit={reduce ? { opacity: 0 } : { opacity: 0, x: -60 }}
      transition={reduce ? { duration: 0.1 } : { type: 'spring', stiffness: 380, damping: 38 }}
    >
      <h2 className="ob-title">{title}</h2>
      <div className="ob-body">{body}</div>
      <div className="ob-actions">{actions}</div>
    </motion.div>
  );

  return (
    <motion.div className="onboarding" role="dialog" aria-modal="true" aria-label="はじめの設定" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} data-testid="onboarding">
      <div className="ob-progress" aria-hidden>
        {STEPS.map((s, k) => (
          <span key={s} className={k <= i ? 'on' : ''} />
        ))}
      </div>
      <AnimatePresence mode="wait">
        {step === 'welcome' &&
          card(
            'My Time へようこそ',
            <>
              <div className="ob-hero" aria-hidden><Icon name="stopwatch" size={44} strokeWidth={1.7} /></div>
              <p>予定とタスクをひとつの画面で。やることの進み具合を、長押しのひと動作で記録できます。</p>
            </>,
            <button type="button" className="ob-primary" onClick={next} data-testid="ob-next">はじめる</button>,
          )}
        {step === 'account' &&
          card(
            'Googleでログイン',
            <>
              <p>ログインすると、データをクラウドに保存し、毎晩Googleドライブの「My Time Backup」フォルダーへバックアップします。権限はこのアプリが作るファイルだけに限ります。</p>
              {sync.me ? <p className="ob-ok"><Icon name="check" size={18} strokeWidth={2.6} /> {sync.me.user.email} でログイン済み</p> : null}
              {(sync.phase === 'notConfigured' || sync.phase === 'unavailable') && <p className="ob-note">この配信先ではまだサーバーが設定されていません。データはこの端末に保存されます。</p>}
            </>,
            <>
              {!sync.me && sync.config?.googleConfigured && (
                <a className="ob-primary" href={api.loginUrl()} onClick={() => void repo.updateSettings({ onboarded: false })}>Googleでログイン</a>
              )}
              <button type="button" className="ob-secondary" onClick={next} data-testid="ob-next">{sync.me ? '次へ' : 'あとで'}</button>
            </>,
          )}
        {step === 'calendars' &&
          card(
            'カレンダー',
            <>
              <p>用途ごとにカレンダーを分けられます。あとから「その他」の「カレンダー」で追加・変更できます。</p>
              <ul className="ob-list">
                {calendars.map((c) => (
                  <li key={c.id}>
                    <span className="cal-chip" style={{ background: c.color }} aria-hidden><ItemIcon value={c.icon} size={16} fallback={defaultCalendarIcon(c.kind)} /></span>
                    {c.name}
                    <span className="sub-label">{c.kind === 'class' ? '授業：科目・課題・小テスト' : c.kind === 'job' ? 'アルバイト：勤務先と勤務前の通知' : '一般'}</span>
                  </li>
                ))}
              </ul>
            </>,
            <button type="button" className="ob-primary" onClick={next} data-testid="ob-next">次へ</button>,
          )}
        {step === 'places' &&
          card(
            '授業と勤務先',
            <>
              <label className="ob-field">
                受講している科目（改行または「、」区切り）
                <textarea value={subjects} onChange={(e) => setSubjects(e.target.value)} placeholder={'財政学、マクロ経済学'} rows={2} data-testid="ob-subjects" />
              </label>
              <label className="ob-field">
                勤務先
                <textarea value={employers} onChange={(e) => setEmployers(e.target.value)} placeholder={'GU、無印良品'} rows={2} data-testid="ob-employers" />
              </label>
            </>,
            <>
              <button type="button" className="ob-primary" onClick={() => void savePlaces()} data-testid="ob-next">次へ</button>
              <button type="button" className="ob-secondary" onClick={next}>あとで</button>
            </>,
          )}
        {step === 'notify' &&
          card(
            '通知',
            <p>タスクの開始忘れや勤務前のお知らせを受け取れます。iPhoneではホーム画面に追加したアプリで使えます。許可はあとから「その他」の「通知」でもできます。</p>,
            <>
              {'Notification' in window && Notification.permission === 'default' && (
                <button type="button" className="ob-primary" onClick={() => void Notification.requestPermission().finally(next)}>通知を許可</button>
              )}
              <button type="button" className="ob-secondary" onClick={next} data-testid="ob-next">あとで</button>
            </>,
          )}
        {step === 'appearance' &&
          card(
            '外観',
            <div className="ob-choices" role="radiogroup" aria-label="外観">
              {(['system', 'light', 'dark'] as ThemePref[]).map((t) => (
                <button key={t} type="button" role="radio" aria-checked={settings.theme === t} className={`ob-choice ${settings.theme === t ? 'on' : ''}`} onClick={() => void repo.updateSettings({ theme: t })}>
                  {{ system: '自動', light: 'ライト', dark: 'ダーク' }[t]}
                </button>
              ))}
            </div>,
            <button type="button" className="ob-primary" onClick={next} data-testid="ob-next">次へ</button>,
          )}
        {step === 'guide' &&
          card(
            '使い方',
            <ul className="ob-guide">
              <li><b>タップ</b> でタスクの詳細</li>
              <li><b>長押しして左右にスライド</b> で進み具合を記録（100%で終了を確認）</li>
              <li><b>境界のつまみを上へドラッグ</b> でカレンダーを広げる</li>
              <li><b>左右にスワイプ</b> で日付を移動</li>
              <li><b>予定を長押ししてドラッグ</b> で15分刻みに移動</li>
            </ul>,
            <button type="button" className="ob-primary" onClick={next} data-testid="ob-finish">使いはじめる</button>,
          )}
      </AnimatePresence>
    </motion.div>
  );
}
