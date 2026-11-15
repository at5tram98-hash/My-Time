import { createContext, useCallback, useContext, useMemo, useRef, useState, type ReactNode } from 'react';
import { startOfDay, type AnalysisPeriod, type CalEvent, type Task } from '@my-time/domain';

export type TabId = 'home' | 'calendar' | 'tasks' | 'analysis' | 'other';

export type SheetState =
  | { kind: 'task'; id: string }
  | { kind: 'editTask'; taskId?: string; defaults?: Partial<Task> }
  | { kind: 'editEvent'; eventId?: string; defaults?: Partial<CalEvent> }
  | { kind: 'search' }
  /** 予定を複数の日へコピー（既存の予定が見える縮小カレンダーで日付を選ぶ） */
  | { kind: 'copyEvent'; eventId: string }
  /** AR：自動開始・自動終了の予約 */
  | { kind: 'autoReserve'; taskId: string }
  /** 取り込み（TimeTree・ICS・テキスト） */
  | { kind: 'import' }
  /** 情報確認（Q62）：予定・タスクのタップ後。約半分の高さ、上スワイプで拡大 */
  | { kind: 'info'; entity: 'event' | 'task'; id: string }
  /** 共通の作成・編集（Q38・Q63）。mode が初期の種類、id があれば編集 */
  | { kind: 'edit'; mode: 'event' | 'task'; id?: string; defaults?: Record<string, unknown> }
  /** 実行パネル（Q35・Q92） */
  | { kind: 'run'; id: string; progress?: boolean }
  /** 表示するカレンダーの切替（Q31） */
  | { kind: 'calendarFilter' }
  /** 同期の詳細（Q57） */
  | { kind: 'syncStatus' }
  /** 分析の詳細（Q49） */
  | { kind: 'analysisDetail'; metric: AnalysisMetric; period: AnalysisPeriod; from: number }
  /** 文章から追加（P01〜P05）。text は最初に入れる文章、defaults は時間軸から開いたときの初期値 */
  | { kind: 'quickAdd'; text?: string; at?: { start: number; end: number; entity: 'event' | 'task' } }
  /** 気づいたこと（問題の検知と修正案：P06〜P09） */
  | { kind: 'issues'; day: number }
  /** 未割当（日時が決まっていないタスク：P22） */
  | { kind: 'inbox' }
  /** その日のタスク一覧（長押しで進捗入力） */
  | { kind: 'dayTasks'; day: number }
  /** 1日の振り返りと翌日の提案（P40） */
  | { kind: 'review'; day: number }
  /** 延期・分割（P29・P30） */
  | { kind: 'reschedule'; taskId: string; mode: 'postpone' | 'split' };

export type AnalysisMetric = 'completion' | 'delay' | 'work' | 'planDiff' | 'interruptions';

export interface AlertButton<T> {
  label: string;
  value: T;
  style?: 'default' | 'cancel' | 'destructive';
}

export interface AlertState {
  id: number;
  title: string;
  message?: string;
  buttons: AlertButton<unknown>[];
  /** 'alert' = 中央のアラート / 'sheet' = 下からのアクションシート */
  variant: 'alert' | 'sheet';
  resolve: (v: unknown) => void;
}

interface UIContextValue {
  tab: TabId;
  setTab: (t: TabId) => void;
  homeDate: number;
  setHomeDate: (d: number) => void;
  calDate: number;
  setCalDate: (d: number) => void;
  /** 開いているシート。uid は開くたびに新しく振る（閉じるアニメーション中の古い画面の状態を使い回さない） */
  sheets: (SheetState & { uid: number })[];
  openSheet: (s: SheetState) => void;
  closeSheet: () => void;
  alert: AlertState | null;
  confirm: (o: { title: string; message?: string; confirmLabel?: string; cancelLabel?: string; destructive?: boolean }) => Promise<boolean>;
  choose: <T>(o: { title: string; message?: string; actions: AlertButton<T>[] }) => Promise<T | null>;
  /** 中央のiOS風アラートで複数の選択肢を出す（3つ以上は縦並び） */
  ask: <T>(o: { title: string; message?: string; buttons: AlertButton<T>[] }) => Promise<T | null>;
  toast: string | null;
  showToast: (msg: string) => void;
  /** 設定の下にある画面（設定を開く前のタブ） */
  baseTab: TabId;
  closeSettings: () => void;
}

const Ctx = createContext<UIContextValue | null>(null);

export function UIProvider({ children }: { children: ReactNode }) {
  const [tab, setTabRaw] = useState<TabId>('home');
  // 設定（'other'）は下部タブではなく、今いる画面の上に重ねて開く。閉じると元の画面へ戻る
  const prevTab = useRef<TabId>('home');
  const setTab = useCallback((t: TabId) => setTabRaw((cur) => { if (t === 'other' && cur !== 'other') prevTab.current = cur; return t; }), []);
  const closeSettings = useCallback(() => setTabRaw(prevTab.current), []);
  const [homeDate, setHomeDateRaw] = useState(() => startOfDay(Date.now()));
  const [calDate, setCalDateRaw] = useState(() => startOfDay(Date.now()));
  const [sheets, setSheets] = useState<(SheetState & { uid: number })[]>([]);
  const sheetSeq = useRef(0);
  const [alert, setAlert] = useState<AlertState | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  const toastTimer = useRef<number | undefined>(undefined);
  const alertSeq = useRef(0);

  const setHomeDate = useCallback((d: number) => setHomeDateRaw(startOfDay(d)), []);
  const setCalDate = useCallback((d: number) => setCalDateRaw(startOfDay(d)), []);
  const openSheet = useCallback((s: SheetState) => {
    sheetSeq.current += 1;
    const uid = sheetSeq.current;
    setSheets((st) => [...st, { ...s, uid }]);
  }, []);
  const closeSheet = useCallback(() => setSheets((st) => st.slice(0, -1)), []);

  const present = useCallback(<T,>(variant: AlertState['variant'], title: string, message: string | undefined, buttons: AlertButton<T>[]) => {
    return new Promise<T | null>((resolve) => {
      alertSeq.current += 1;
      setAlert({
        id: alertSeq.current,
        title,
        ...(message ? { message } : {}),
        buttons: buttons as AlertButton<unknown>[],
        variant,
        resolve: (v) => {
          setAlert(null);
          resolve(v as T | null);
        },
      });
    });
  }, []);

  const confirm = useCallback<UIContextValue['confirm']>(
    async (o) => {
      const r = await present<boolean>('alert', o.title, o.message, [
        { label: o.cancelLabel ?? 'キャンセル', value: false, style: 'cancel' },
        { label: o.confirmLabel ?? 'OK', value: true, style: o.destructive ? 'destructive' : 'default' },
      ]);
      return r === true;
    },
    [present],
  );

  const choose = useCallback(<T,>(o: { title: string; message?: string; actions: AlertButton<T>[] }) => present<T>('sheet', o.title, o.message, o.actions), [present]);

  const ask = useCallback(<T,>(o: { title: string; message?: string; buttons: AlertButton<T>[] }) => present<T>('alert', o.title, o.message, o.buttons), [present]);

  const showToast = useCallback((msg: string) => {
    window.clearTimeout(toastTimer.current);
    setToast(msg);
    toastTimer.current = window.setTimeout(() => setToast(null), 2200);
  }, []);

  const value = useMemo(
    () => ({ tab, setTab, homeDate, setHomeDate, calDate, setCalDate, sheets, openSheet, closeSheet, alert, confirm, choose, ask, toast, showToast, baseTab: tab === 'other' ? prevTab.current : tab, closeSettings }),
    [tab, setTab, homeDate, setHomeDate, calDate, setCalDate, sheets, openSheet, closeSheet, alert, confirm, choose, ask, toast, showToast, closeSettings],
  );
  // 画面の大半は「操作（安定した関数）」と「日付」だけを使う。タブ・シート・トーストの変化で
  // 隠れているタブの画面やタスク行まで再描画しないよう、文脈を分ける。
  const actions = useMemo<UIActions>(
    () => ({ setTab, setHomeDate, setCalDate, openSheet, closeSheet, confirm, choose, ask, showToast, closeSettings }),
    [setTab, setHomeDate, setCalDate, openSheet, closeSheet, confirm, choose, ask, showToast, closeSettings],
  );
  const dates = useMemo(() => ({ homeDate, calDate }), [homeDate, calDate]);
  return (
    <ActionsCtx.Provider value={actions}>
      <DatesCtx.Provider value={dates}>
        <Ctx.Provider value={value}>{children}</Ctx.Provider>
      </DatesCtx.Provider>
    </ActionsCtx.Provider>
  );
}

type UIActions = Pick<UIContextValue, 'setTab' | 'setHomeDate' | 'setCalDate' | 'openSheet' | 'closeSheet' | 'confirm' | 'choose' | 'ask' | 'showToast' | 'closeSettings'>;
const ActionsCtx = createContext<UIActions | null>(null);
const DatesCtx = createContext<{ homeDate: number; calDate: number } | null>(null);

/** 操作だけを使う（タブ・シート・トーストの変化で再描画されない） */
export function useUIActions(): UIActions {
  const v = useContext(ActionsCtx);
  if (!v) throw new Error('UIProvider がありません');
  return v;
}
/** ホーム・カレンダーの表示日 */
export function useUIDates(): { homeDate: number; calDate: number } {
  const v = useContext(DatesCtx);
  if (!v) throw new Error('UIProvider がありません');
  return v;
}

export function useUI(): UIContextValue {
  const v = useContext(Ctx);
  if (!v) throw new Error('UIProvider がありません');
  return v;
}
