import { at, event, task } from './helpers';

/** 画面キャプチャ用のデモデータ（テスト用に投入するもの） */
export const demo = {
  tasks: [
    task({ id: 't1', title: '財政学レポート', icon: '📝', category: '課題', calendarId: 'cal-class', plannedStart: at(9), plannedEnd: at(10, 30), status: 'running', intervals: [{ start: at(9, 5), end: null }], actualStart: at(9, 5), manualProgress: { value: 0.6, at: at(10, 20), workedMsAtSample: 75 * 60_000 } }),
    task({ id: 't2', title: 'ミクロ経済 小テスト対策', icon: '📚', category: 'テスト対策', plannedStart: at(10), plannedEnd: at(12) }),
    task({ id: 't3', title: '英語の単語', icon: '✏️', category: '語学', plannedStart: at(8), plannedEnd: at(8, 40), status: 'done', intervals: [{ start: at(8), end: at(8, 35) }], actualStart: at(8), actualEnd: at(8, 35) }),
    task({ id: 't4', title: '持ち物チェック', kind: 'check', icon: '🎒', checkAt: at(12, 30) }),
    task({ id: 't5', title: 'アプリ開発', icon: '💻', category: '個人', plannedStart: at(15), plannedEnd: at(17) }),
    task({ id: 't6', title: 'ゼミ資料の下書き', icon: '💼', category: '課題', plannedStart: at(10, 0, 1), plannedEnd: at(11, 30, 1) }),
    task({ id: 't7', title: '期末試験の範囲確認', icon: '🎯', category: 'テスト対策' }),
  ],
  events: [
    event({ id: 'e1', title: 'マクロ経済学', calendarId: 'cal-class', start: at(10, 45), end: at(12, 15) }),
    event({ id: 'e2', title: 'GU アルバイト', calendarId: 'cal-job', start: at(18), end: at(22) }),
    event({ id: 'e3', title: '昼ごはん', start: at(12, 30), end: at(13, 15) }),
    event({ id: 'e4', title: '歴史学の世界', calendarId: 'cal-class', start: at(13, 15), end: at(14, 45), }),
    event({ id: 'e5', title: '無印良品 夜勤', calendarId: 'cal-job', start: at(22, 0, 1), end: at(6, 0, 2) }),
    event({ id: 'e6', title: 'ゼミ合宿', start: at(9, 0, 4), end: at(17, 0, 8) }),
  ],
};
