import { createContext, useCallback, useContext, useMemo, useRef, useState, type ReactNode } from 'react';
import { startOfDay, type CalEvent, type Task } from '@my-time/domain';

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
  | { kind: 'import' };

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
}

const Ctx = createContext<UIContextValue | null>(null);

export function UIProvider({ children }: { children: ReactNode }) {
  const [tab, setTab] = useState<TabId>('home');
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
    () => ({ tab, setTab, homeDate, setHomeDate, calDate, setCalDate, sheets, openSheet, closeSheet, alert, confirm, choose, ask, toast, showToast }),
    [tab, homeDate, setHomeDate, calDate, setCalDate, sheets, openSheet, closeSheet, alert, confirm, choose, ask, toast, showToast],
  );
  // 画面の大半は「操作（安定した関数）」と「日付」だけを使う。タブ・シート・トーストの変化で
  // 隠れているタブの画面やタスク行まで再描画しないよう、文脈を分ける。
  const actions = useMemo<UIActions>(
    () => ({ setTab, setHomeDate, setCalDate, openSheet, closeSheet, confirm, choose, ask, showToast }),
    [setHomeDate, setCalDate, openSheet, closeSheet, confirm, choose, ask, showToast],
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

type UIActions = Pick<UIContextValue, 'setTab' | 'setHomeDate' | 'setCalDate' | 'openSheet' | 'closeSheet' | 'confirm' | 'choose' | 'ask' | 'showToast'>;
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
