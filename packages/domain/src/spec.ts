/**
 * 専門の種類（S01〜S25）。
 *
 * 予定とタスクは別アプリのように分けず、共通の記録（CalEvent / Task）に「種類」と「詳細」を足して扱う。
 * - 保存は `extra.spec = { type, details }`。旧データ（授業カレンダー・勤務先・課題・テスト対策）は表示時だけ読み替え、書き換えない。
 * - 種類を選んだときだけ追加の項目を開く（普段の入力は タイトル・日時・種類 の3つ以内）。
 * - 推定値（給与・残り時間・終了見込みなど）は必ず「見込み」と分かる形で返す。根拠がなければ値を作らない。
 */
import type { CalEvent, Employer, EpochMs, Subtask, Task } from './types';
import { addDays, formatHm, MINUTE, startOfDay } from './time';
import { workedMs } from './progress';

export type SpecTypeId =
  | 'shift' | 'shiftRequest' | 'payday' | 'class' | 'assignment' | 'exam' | 'language' | 'certification' | 'report' | 'presentation'
  | 'groupWork' | 'reading' | 'shopping' | 'appointment' | 'outing' | 'trip' | 'transit' | 'routine' | 'chores' | 'cooking'
  | 'workout' | 'project' | 'paperwork' | 'payment' | 'leisure';

export type SpecGroup = 'work' | 'school' | 'life' | 'outing' | 'money' | 'self';
export const SPEC_GROUPS: { id: SpecGroup; label: string }[] = [
  { id: 'work', label: '仕事' },
  { id: 'school', label: '学校・勉強' },
  { id: 'outing', label: '外出・移動' },
  { id: 'life', label: '生活' },
  { id: 'money', label: 'お金・手続き' },
  { id: 'self', label: '自分の時間' },
];

export type SpecFieldType = 'text' | 'multiline' | 'number' | 'money' | 'minutes' | 'datetime' | 'date' | 'list' | 'checklist' | 'url' | 'toggle' | 'select' | 'members' | 'steps' | 'slots';

export interface SpecField {
  key: string;
  label: string;
  type: SpecFieldType;
  unit?: string;
  options?: string[];
  placeholder?: string;
  hint?: string;
}

export interface SpecStep { title: string; minutes: number }

export interface SpecDef {
  id: SpecTypeId;
  code: string;
  name: string;
  group: SpecGroup;
  icon: string;
  color: string;
  /** 主に予定として持つか、タスクとして持つか */
  entity: 'event' | 'task';
  taskKind: 'do' | 'check';
  /** 1日の画面のどちらのレーンか（左＝時間が決まった大きな予定、右＝細かな行動） */
  lane: 'main' | 'detail';
  /** 種類を選ぶ画面の説明（1行） */
  blurb: string;
  fields: SpecField[];
  /** 「工程を作る」で作るサブタスク（タスクの種類のみ） */
  steps?: SpecStep[];
  /** 予定の前に置く準備（予定の種類のみ）。before＝開始の直前に並べる / inbox＝未割当に置く */
  prep?: { title: string; minutes: number; place: 'before' | 'inbox' }[];
  /** 文章から種類を見分ける語（nlparse） */
  keywords: RegExp;
}

const CHECK = (name: string) => ({ id: name, name, done: false });

export const SPEC_DEFS: SpecDef[] = [
  { id: 'shift', code: 'S01', name: '勤務シフト', group: 'work', icon: 'briefcase', color: '#FF9F0A', entity: 'event', taskKind: 'do', lane: 'main', blurb: '勤務時間と時給から給与見込みを出します', keywords: /(アルバイト|バイト|パート|出勤|勤務|シフト(?!希望|提出))/,
    fields: [
      { key: 'workplace', label: '勤務先', type: 'text', placeholder: '例：GU' },
      { key: 'hourlyWage', label: '時給', type: 'money', unit: '円' },
      { key: 'breakMinutes', label: '休憩', type: 'minutes', unit: '分' },
      { key: 'transportFee', label: '交通費', type: 'money', unit: '円', hint: '給与とは別に扱います' },
    ],
    prep: [{ title: '出勤の準備', minutes: 20, place: 'before' }] },
  { id: 'shiftRequest', code: 'S02', name: 'シフト希望・提出', group: 'work', icon: 'calendar', color: '#FF9F0A', entity: 'task', taskKind: 'check', lane: 'detail', blurb: '希望の勤務枠と出られない日をまとめ、提出までを管理します', keywords: /(シフト希望|希望シフト|シフト提出|シフトを提出)/,
    fields: [
      { key: 'workplace', label: '勤務先', type: 'text' },
      { key: 'wishes', label: '希望の勤務枠', type: 'slots' },
      { key: 'unavailable', label: '出られない日', type: 'list', placeholder: '例：11/22（ゼミ）' },
      { key: 'status', label: '状態', type: 'select', options: ['未提出', '提出済み'] },
    ] },
  { id: 'payday', code: 'S03', name: '給与日・締め日', group: 'money', icon: 'yen', color: '#34C759', entity: 'event', taskKind: 'check', lane: 'main', blurb: '締め日までの勤務から見込み額を出し、入金を確認します', keywords: /(給料日|給与日|締め日|給料|給与)/,
    fields: [
      { key: 'workplace', label: '勤務先', type: 'text' },
      { key: 'closingDay', label: '締め日', type: 'number', unit: '日', hint: '月末締めは 0' },
      { key: 'actualAmount', label: '実際の入金額', type: 'money', unit: '円' },
      { key: 'received', label: '入金を確認した', type: 'toggle' },
    ] },
  { id: 'class', code: 'S04', name: '大学の授業', group: 'school', icon: 'graduation', color: '#5E5CE6', entity: 'event', taskKind: 'do', lane: 'main', blurb: '曜日・時限・教室を繰り返しで登録します（休講は1回だけ変更）', keywords: /(授業|講義|ゼミ|[1-7１-７]限)/,
    fields: [
      { key: 'period', label: '時限', type: 'text', placeholder: '例：2限' },
      { key: 'room', label: '教室', type: 'text' },
      { key: 'termEnd', label: '開講の終わり', type: 'date' },
      { key: 'bring', label: '持ち物', type: 'list' },
    ] },
  { id: 'assignment', code: 'S05', name: '大学の課題', group: 'school', icon: 'note', color: '#FF375F', entity: 'task', taskKind: 'do', lane: 'detail', blurb: '締切・見積時間・進み具合をまとめ、作業する時間を提案します', keywords: /(課題|宿題|提出物|レポート(?!.*論文))/,
    fields: [
      { key: 'course', label: '授業', type: 'text' },
      { key: 'dueAt', label: '提出期限', type: 'datetime' },
      { key: 'submitUrl', label: '提出URL', type: 'url' },
    ],
    steps: [{ title: '着手', minutes: 30 }, { title: '作成', minutes: 60 }, { title: '見直し', minutes: 20 }, { title: '提出', minutes: 10 }] },
  { id: 'exam', code: 'S06', name: '定期試験・小テスト', group: 'school', icon: 'target', color: '#FF453A', entity: 'task', taskKind: 'do', lane: 'detail', blurb: '試験日から逆算して復習の時間を提案します', keywords: /(試験|テスト|中間|期末|小テスト)/,
    fields: [
      { key: 'examAt', label: '試験日時', type: 'datetime' },
      { key: 'course', label: '科目', type: 'text' },
      { key: 'scope', label: '範囲', type: 'multiline' },
      { key: 'goal', label: '目標', type: 'text' },
      { key: 'reviewCount', label: '復習の回数', type: 'number', unit: '回' },
    ],
    steps: [{ title: '範囲を確認', minutes: 15 }, { title: '復習1', minutes: 60 }, { title: '復習2', minutes: 60 }, { title: '前日の確認', minutes: 30 }] },
  { id: 'language', code: 'S07', name: 'TOEIC・語学学習', group: 'school', icon: 'chat', color: '#64D2FF', entity: 'task', taskKind: 'do', lane: 'detail', blurb: '分野を順番に回し、今日の学習を1つだけ示します', keywords: /(TOEIC|TOEFL|英検|英語|英単語|語彙|リスニング|語学)/i,
    fields: [
      { key: 'targetScore', label: '目標点', type: 'number', unit: '点' },
      { key: 'mockDate', label: '模試・本番の日', type: 'date' },
      { key: 'areas', label: '学習する分野', type: 'list' },
      { key: 'dailyMinutes', label: '1日の目安', type: 'minutes', unit: '分' },
    ] },
  { id: 'certification', code: 'S08', name: '資格試験・検定', group: 'school', icon: 'star', color: '#BF5AF2', entity: 'task', taskKind: 'do', lane: 'detail', blurb: '受験日と残りの単元から、週に必要な量を出します', keywords: /(資格|検定|簿記|基本情報|宅建)/,
    fields: [
      { key: 'examDate', label: '受験日', type: 'date' },
      { key: 'material', label: '教材', type: 'text' },
      { key: 'units', label: '単元', type: 'checklist' },
    ] },
  { id: 'report', code: 'S09', name: 'レポート・論文制作', group: 'school', icon: 'books', color: '#AC8E68', entity: 'task', taskKind: 'do', lane: 'detail', blurb: '調査から提出までを段階に分けて進めます', keywords: /(論文|卒論|修論|長いレポート)/,
    fields: [
      { key: 'dueAt', label: '締切', type: 'datetime' },
      { key: 'format', label: '提出形式', type: 'text', placeholder: '例：Word 4000字' },
      { key: 'sources', label: '資料', type: 'list' },
    ],
    steps: [{ title: '調査', minutes: 90 }, { title: 'アウトライン', minutes: 45 }, { title: '初稿', minutes: 120 }, { title: '推敲', minutes: 60 }, { title: '提出', minutes: 10 }] },
  { id: 'presentation', code: 'S10', name: 'プレゼン・発表', group: 'school', icon: 'bulb', color: '#FF9F0A', entity: 'event', taskKind: 'do', lane: 'main', blurb: '本番の予定と、資料・原稿・リハーサルの準備をつなげます', keywords: /(プレゼン|発表|スライド)/,
    fields: [
      { key: 'talkMinutes', label: '持ち時間', type: 'minutes', unit: '分' },
      { key: 'materialDue', label: '資料の期限', type: 'datetime' },
    ],
    prep: [{ title: 'スライド準備', minutes: 90, place: 'inbox' }, { title: '原稿', minutes: 60, place: 'inbox' }, { title: 'リハーサル', minutes: 30, place: 'inbox' }, { title: '資料提出', minutes: 10, place: 'inbox' }] },
  { id: 'groupWork', code: 'S11', name: 'グループ課題', group: 'school', icon: 'people', color: '#30B0C7', entity: 'task', taskKind: 'do', lane: 'detail', blurb: '自分の担当と、ほかの人を待っている工程を分けます', keywords: /(グループ|班|共同|チーム課題)/,
    fields: [
      { key: 'members', label: '分担', type: 'members' },
      { key: 'shareUrl', label: '共有リンク', type: 'url', hint: 'My Time から共有先へは書き込みません' },
    ] },
  { id: 'reading', code: 'S12', name: '読書・教材消化', group: 'school', icon: 'book', color: '#A2845E', entity: 'task', taskKind: 'do', lane: 'detail', blurb: '残りのページを目標日まで割り振ります', keywords: /(読書|読む|読み|ページ|章|教材)/,
    fields: [
      { key: 'totalPages', label: '全体', type: 'number', unit: 'ページ' },
      { key: 'currentPage', label: '今のページ', type: 'number', unit: 'ページ' },
      { key: 'targetDate', label: '読み終える目標日', type: 'date' },
    ] },
  { id: 'shopping', code: 'S13', name: '買い物・日用品補充', group: 'life', icon: 'cart', color: '#34C759', entity: 'task', taskKind: 'do', lane: 'detail', blurb: '買う物の一覧と、行く店をまとめます', keywords: /(買い物|買う|購入|補充|スーパー|ドラッグストア)/,
    fields: [
      { key: 'items', label: '買う物', type: 'checklist' },
      { key: 'store', label: 'お店', type: 'text' },
      { key: 'storeHours', label: '営業時間', type: 'text', placeholder: '分からなければ空欄', hint: '空欄のときは「未確認」と表示します' },
    ] },
  { id: 'appointment', code: 'S14', name: '通院・予約', group: 'life', icon: 'heart', color: '#FF2D55', entity: 'event', taskKind: 'do', lane: 'main', blurb: '受付の余裕と移動時間から、出発の目安を出します', keywords: /(病院|歯医者|通院|診察|予約|美容院|クリニック)/,
    fields: [
      { key: 'bring', label: '持ち物', type: 'list' },
      { key: 'prep', label: '事前にすること', type: 'multiline' },
      { key: 'arriveEarly', label: '早めに着く', type: 'minutes', unit: '分' },
    ],
    prep: [{ title: '持ち物の準備', minutes: 10, place: 'before' }] },
  { id: 'outing', code: 'S15', name: 'デート・同行外出', group: 'outing', icon: 'person', color: '#FF375F', entity: 'event', taskKind: 'do', lane: 'main', blurb: '集合時刻から逆算して、身支度と移動を並べます', keywords: /(出かけ|お出かけ|外出|デート|待ち合わせ|遊びに|会う|ご飯に行)/,
    fields: [
      { key: 'companions', label: '一緒に行く人', type: 'text' },
      { key: 'meetPlace', label: '集合場所', type: 'text' },
      { key: 'purpose', label: '目的', type: 'text' },
      { key: 'prepMinutes', label: '身支度', type: 'minutes', unit: '分' },
    ],
    prep: [{ title: '髪・身支度', minutes: 30, place: 'before' }, { title: '持ち物の確認', minutes: 5, place: 'before' }] },
  { id: 'trip', code: 'S16', name: '旅行・出張', group: 'outing', icon: 'plane', color: '#0A84FF', entity: 'event', taskKind: 'do', lane: 'main', blurb: '日別の行程と持ち物・事前手続きをつなげます（時差も保存）', keywords: /(旅行|出張|帰省|泊|旅)/,
    fields: [
      { key: 'transport', label: '交通', type: 'text' },
      { key: 'lodging', label: '宿泊', type: 'text' },
      { key: 'meetTime', label: '集合時刻', type: 'datetime' },
      { key: 'destTimeZone', label: '現地のタイムゾーン', type: 'select', options: ['Asia/Tokyo', 'Asia/Seoul', 'Asia/Shanghai', 'Asia/Taipei', 'Asia/Singapore', 'Asia/Bangkok', 'Europe/London', 'Europe/Paris', 'America/New_York', 'America/Los_Angeles', 'Pacific/Honolulu', 'Australia/Sydney'] },
      { key: 'packing', label: '持ち物', type: 'checklist' },
    ],
    prep: [{ title: '荷造り', minutes: 45, place: 'inbox' }, { title: '事前の手続き', minutes: 15, place: 'inbox' }] },
  { id: 'transit', code: 'S17', name: '移動・乗換', group: 'outing', icon: 'train', color: '#8E8E93', entity: 'event', taskKind: 'do', lane: 'main', blurb: '予定と予定の間に移動の時間を確保します', keywords: /(移動|電車|乗り換え|乗換|バスで|車で)/,
    fields: [
      { key: 'from', label: '出発', type: 'text' },
      { key: 'to', label: '到着', type: 'text' },
      { key: 'mode', label: '手段', type: 'select', options: ['徒歩', '電車', 'バス', '車', '自転車', '飛行機'] },
      { key: 'minutes', label: '所要時間', type: 'minutes', unit: '分', hint: '未入力のまま0分として予定を詰めません' },
    ] },
  { id: 'routine', code: 'S18', name: '朝・帰宅・就寝ルーティン', group: 'life', icon: 'sun', color: '#FFD60A', entity: 'task', taskKind: 'do', lane: 'detail', blurb: '工程と標準の時間から、始める時刻と終わる見込みを出します', keywords: /(ルーティン|朝の準備|身支度|寝る準備|就寝|帰宅後)/,
    fields: [
      { key: 'steps', label: '工程', type: 'steps' },
    ],
    steps: [{ title: '起床・洗顔', minutes: 10 }, { title: '朝食', minutes: 15 }, { title: '着替え', minutes: 10 }, { title: '持ち物の確認', minutes: 5 }] },
  { id: 'chores', code: 'S19', name: '掃除・家事', group: 'life', icon: 'sparkles', color: '#30D158', entity: 'task', taskKind: 'do', lane: 'detail', blurb: '頻度と目安の時間で、次の回を置きます', keywords: /(掃除|洗濯|片付け|家事|ゴミ|皿洗い)/,
    fields: [
      { key: 'area', label: '場所・内容', type: 'text' },
    ] },
  { id: 'cooking', code: 'S20', name: '料理・食事準備', group: 'life', icon: 'pan', color: '#FF9F0A', entity: 'task', taskKind: 'do', lane: 'detail', blurb: '材料の有無を確かめ、足りない物だけ買い物に回します', keywords: /(料理|自炊|作り置き|ご飯を作|夕飯を作|お弁当)/,
    fields: [
      { key: 'dish', label: '料理', type: 'text' },
      { key: 'ingredients', label: '材料（持っている物にチェック）', type: 'checklist' },
    ] },
  { id: 'workout', code: 'S21', name: '運動・トレーニング', group: 'self', icon: 'run', color: '#32ADE6', entity: 'task', taskKind: 'do', lane: 'detail', blurb: '週の回数と前回の日を示し、休む日も残します', keywords: /(運動|筋トレ|ジム|ランニング|ジョギング|ヨガ|ストレッチ)/,
    fields: [
      { key: 'activity', label: '種目', type: 'text' },
      { key: 'perWeek', label: '週の回数', type: 'number', unit: '回' },
      { key: 'restDays', label: '休む日', type: 'text' },
    ] },
  { id: 'project', code: 'S22', name: '個人開発・制作', group: 'self', icon: 'laptop', color: '#5E5CE6', entity: 'task', taskKind: 'do', lane: 'detail', blurb: '調査・実装・テスト・公開を分けて、残りを次回へつなげます', keywords: /(開発|実装|プログラミング|コーディング|制作|アプリ作)/,
    fields: [
      { key: 'deliverable', label: '成果物', type: 'text' },
      { key: 'issueUrl', label: 'Issue / PR の URL', type: 'url' },
      { key: 'testResult', label: 'テスト結果', type: 'select', options: ['未記録', '成功', '失敗'], hint: '実行した結果だけを記録します' },
    ],
    steps: [{ title: '調査', minutes: 30 }, { title: '実装', minutes: 90 }, { title: 'テスト', minutes: 30 }, { title: '公開', minutes: 15 }] },
  { id: 'paperwork', code: 'S23', name: '申請・提出・行政手続', group: 'money', icon: 'note', color: '#8E8E93', entity: 'task', taskKind: 'do', lane: 'detail', blurb: '必要な書類をそろえ、期限と窓口の受付時間を分けて示します', keywords: /(申請|手続き|手続|役所|書類|届け出|届出|窓口)/,
    fields: [
      { key: 'office', label: '提出先', type: 'text' },
      { key: 'dueAt', label: '提出期限', type: 'datetime' },
      { key: 'windowHours', label: '窓口の受付時間', type: 'text', placeholder: '例：平日 8:30〜17:15' },
      { key: 'docs', label: '必要な書類', type: 'checklist' },
    ] },
  { id: 'payment', code: 'S24', name: '支払い・口座確認', group: 'money', icon: 'yen', color: '#34C759', entity: 'task', taskKind: 'check', lane: 'detail', blurb: '期日の前に知らせ、支払ったことは自分で記録します', keywords: /(支払い|支払う|払う|振込|振り込み|引き落とし|料金)/,
    fields: [
      { key: 'payee', label: '支払先', type: 'text' },
      { key: 'amount', label: '金額', type: 'money', unit: '円' },
      { key: 'paid', label: '支払った（自分で確認）', type: 'toggle' },
    ] },
  { id: 'leisure', code: 'S25', name: '自由時間・趣味・休息', group: 'self', icon: 'music', color: '#BF5AF2', entity: 'task', taskKind: 'do', lane: 'detail', blurb: '空いた時間に候補を出すだけで、勝手に予定へ入れません', keywords: /(趣味|自由時間|休憩|休む|ゲーム|映画|のんびり|昼寝|散歩)/,
    fields: [
      { key: 'wish', label: 'やりたいこと', type: 'text' },
    ] },
];

export const SPEC_BY_ID: Record<SpecTypeId, SpecDef> = Object.fromEntries(SPEC_DEFS.map((d) => [d.id, d])) as Record<SpecTypeId, SpecDef>;

export function isSpecType(v: unknown): v is SpecTypeId {
  return typeof v === 'string' && v in SPEC_BY_ID;
}

export interface SpecValue { type: SpecTypeId; details: Record<string, unknown> }

/**
 * 記録の種類。extra.spec を優先し、なければ旧データの種類から読み替える（保存値は変えない）。
 * calendarKind は予定のカレンダーの種類（授業・アルバイト）。
 */
export function specOf(item: Task | CalEvent, calendarKind?: 'general' | 'class' | 'job'): SpecValue | null {
  const s = item.extra?.spec as { type?: unknown; details?: unknown } | null | undefined;
  if (s && isSpecType(s.type)) return { type: s.type, details: (s.details && typeof s.details === 'object' ? s.details : {}) as Record<string, unknown> };
  if ('kind' in item && 'special' in item) {
    if (item.special === 'assignment') return { type: 'assignment', details: {} };
    if (item.special === 'testPrep') return { type: 'exam', details: {} };
    return null;
  }
  const ev = item as CalEvent;
  if (ev.classInfo || calendarKind === 'class') return { type: 'class', details: {} };
  if (ev.employerId || calendarKind === 'job') return { type: 'shift', details: {} };
  return null;
}

// ---------------- 値の取り出し（型の不一致・不正値は「未入力」として扱う） ----------------
export const num = (v: unknown): number | null => (typeof v === 'number' && Number.isFinite(v) ? v : null);
export const str = (v: unknown): string => (typeof v === 'string' ? v : '');
export const list = (v: unknown): string[] => (Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string' && x.trim() !== '') : []);
export interface CheckItem { id: string; name: string; done: boolean }
export const checks = (v: unknown): CheckItem[] => (Array.isArray(v) ? v.filter((x): x is CheckItem => !!x && typeof x === 'object' && typeof (x as CheckItem).name === 'string').map((x) => ({ id: String(x.id ?? x.name), name: x.name, done: !!x.done })) : []);
export interface Member { name: string; part: string; mine: boolean; status: 'todo' | 'waiting' | 'done' }
export const members = (v: unknown): Member[] => (Array.isArray(v) ? v.filter((x): x is Member => !!x && typeof x === 'object').map((x) => ({ name: str(x.name), part: str(x.part), mine: !!x.mine, status: (['todo', 'waiting', 'done'] as const).includes(x.status) ? x.status : 'todo' })) : []);
export const steps = (v: unknown): SpecStep[] => (Array.isArray(v) ? v.filter((x): x is SpecStep => !!x && typeof x === 'object' && typeof (x as SpecStep).title === 'string').map((x) => ({ title: x.title, minutes: num(x.minutes) ?? 0 })) : []);
export interface Slot { start: EpochMs; end: EpochMs }
export const slots = (v: unknown): Slot[] => (Array.isArray(v) ? v.filter((x): x is Slot => !!x && typeof x === 'object' && num((x as Slot).start) != null && num((x as Slot).end) != null && (x as Slot).end > (x as Slot).start) : []);

export const yen = (n: number) => `${Math.round(n).toLocaleString('ja-JP')}円`;

// ---------------- 計算（単体テストの対象） ----------------

/** S01：時給×実働（休憩を除く）。税引前・交通費は含めない。根拠がなければ null */
export function shiftPay(start: EpochMs, end: EpochMs, hourlyWage: number | null, breakMinutes: number | null = 0): { pay: number; workMinutes: number } | null {
  if (hourlyWage == null || hourlyWage < 0 || end <= start) return null;
  const workMinutes = Math.max(0, Math.round((end - start) / MINUTE) - Math.max(0, breakMinutes ?? 0));
  return { pay: Math.round((hourlyWage * workMinutes) / 60), workMinutes };
}

/** S05 など：見積と実績から残りの作業時間。実績がなければ見積そのもの（暫定） */
export function remainingWork(task: Pick<Task, 'estimateMinutes' | 'intervals'>, now: EpochMs): { remaining: number; worked: number; provisional: boolean } | null {
  if (task.estimateMinutes == null) return null;
  const worked = Math.round(workedMs(task, now) / MINUTE);
  return { remaining: Math.max(0, task.estimateMinutes - worked), worked, provisional: worked === 0 };
}

/** S12：残りページを目標日まで均等に。現在のページが未入力なら推測しない */
export function readingPlan(total: number | null, current: number | null, target: EpochMs | null, now: EpochMs): { remaining: number; perDay: number | null; days: number | null } | null {
  if (total == null || current == null) return null;
  const remaining = Math.max(0, total - current);
  if (target == null) return { remaining, perDay: null, days: null };
  const days = Math.max(1, Math.round((startOfDay(target) - startOfDay(now)) / 86_400_000) + 1);
  return { remaining, perDay: Math.ceil(remaining / days), days };
}

/** S08：残りの単元を受験日までの週数で割る */
export function unitsPerWeek(remainingUnits: number, examDate: EpochMs | null, now: EpochMs): number | null {
  if (examDate == null || examDate <= now) return null;
  const weeks = Math.max(1, Math.ceil((examDate - now) / (7 * 86_400_000)));
  return Math.ceil(remainingUnits / weeks);
}

/** S07：分野を日ごとに順番に回す（責める表現は使わない） */
export function languageToday(areas: string[], day: EpochMs): string | null {
  if (!areas.length) return null;
  const idx = Math.floor(startOfDay(day) / 86_400_000) % areas.length;
  return areas[(idx + areas.length) % areas.length]!;
}

/** S18：工程（サブタスク）の残りから終了の見込み。実績がある工程は終わったものとして除く */
export function routineForecast(def: SpecStep[], subtasks: readonly Subtask[], now: EpochMs): { total: number; remaining: number; endAt: EpochMs } {
  const total = def.reduce((s, x) => s + x.minutes, 0);
  const done = new Set(subtasks.filter((s) => s.done).map((s) => s.title));
  const remaining = def.filter((s) => !done.has(s.title)).reduce((s, x) => s + x.minutes, 0);
  return { total, remaining, endAt: now + remaining * MINUTE };
}

/** S03：締め日で区切った期間（前の締め日の翌日〜今回の締め日）。closingDay=0 は月末 */
export function payPeriod(payDate: EpochMs, closingDay: number): { from: EpochMs; to: EpochMs } {
  const d = new Date(payDate);
  const closing = (y: number, m: number) => {
    const last = new Date(y, m + 1, 0).getDate();
    const day = closingDay <= 0 || closingDay > last ? last : closingDay;
    return new Date(y, m, day).getTime();
  };
  // 支払日より前で最も近い締め日を「今回の締め」とする
  let to = closing(d.getFullYear(), d.getMonth());
  if (to >= startOfDay(payDate)) to = closing(d.getFullYear(), d.getMonth() - 1);
  const prev = new Date(to);
  const from = addDays(closing(prev.getFullYear(), prev.getMonth() - 1), 1);
  return { from, to: addDays(to, 1) };
}

/** タイムゾーンでの時刻表示（S16） */
export function timeIn(t: EpochMs, tz: string): string {
  try {
    return new Intl.DateTimeFormat('ja-JP', { timeZone: tz, hour: '2-digit', minute: '2-digit', hour12: false }).format(t);
  } catch {
    return formatHm(t);
  }
}

// ---------------- 情報カードの中身 ----------------

export interface SpecInsight {
  label: string;
  value: string;
  /** estimate＝見込み（推定値）、warn＝注意、ok＝済み、muted＝未入力・未確認 */
  tone?: 'estimate' | 'warn' | 'ok' | 'muted';
  note?: string;
}

export interface SpecContext {
  now: EpochMs;
  tasks: readonly Task[];
  events: readonly CalEvent[];
  subtasks: readonly Subtask[];
  employers: readonly Employer[];
}

const dayDiff = (a: EpochMs, b: EpochMs) => Math.round((startOfDay(a) - startOfDay(b)) / 86_400_000);
const untilText = (t: EpochMs, now: EpochMs) => {
  if (t <= now) return '過ぎています';
  const d = dayDiff(t, now);
  if (d === 0) { const m = Math.round((t - now) / MINUTE); return m >= 60 ? `あと${Math.floor(m / 60)}時間${m % 60 ? `${m % 60}分` : ''}` : `あと${m}分`; }
  return `あと${d}日`;
};
const md = (t: EpochMs) => { const d = new Date(t); return `${d.getMonth() + 1}/${d.getDate()}（${'日月火水木金土'[d.getDay()]}）${formatHm(t)}`; };

/** 締切（課題の提出期限・試験日・詳細の期限・予定終了の順） */
export function deadlineOf(task: Task, spec: SpecValue | null = specOf(task)): EpochMs | null {
  const d = spec?.details ?? {};
  return num(d.dueAt) ?? task.assignment?.deadline ?? num(d.examAt) ?? task.testPrep?.examAt ?? num(d.examDate) ?? num(d.targetDate) ?? (spec?.type === 'payment' ? task.checkAt : null) ?? null;
}

export function workplaceOf(ev: CalEvent, spec: SpecValue | null, employers: readonly Employer[]): string {
  return employers.find((e) => e.id === ev.employerId)?.name ?? str(spec?.details.workplace);
}

/** 種類ごとの要点（情報シートの専門カード）。根拠のない値は作らない */
export function specInsights(item: Task | CalEvent, spec: SpecValue, ctx: SpecContext): SpecInsight[] {
  const d = spec.details;
  const out: SpecInsight[] = [];
  const isTask = 'kind' in item && 'special' in item;
  const task = isTask ? (item as Task) : null;
  const ev = isTask ? null : (item as CalEvent);
  const subs = task ? ctx.subtasks.filter((s) => s.taskId === task.id) : [];
  const progressSubs = () => { if (subs.length) out.push({ label: '工程', value: `${subs.filter((s) => s.done).length}/${subs.length}` }); };
  const due = task ? deadlineOf(task, spec) : null;

  switch (spec.type) {
    case 'shift': {
      if (!ev) break;
      const wp = workplaceOf(ev, spec, ctx.employers);
      if (wp) out.push({ label: '勤務先', value: wp });
      const p = shiftPay(ev.start, ev.end, num(d.hourlyWage), num(d.breakMinutes));
      out.push(p ? { label: '給与見込み', value: yen(p.pay), tone: 'estimate', note: `実働${Math.floor(p.workMinutes / 60)}時間${p.workMinutes % 60 ? `${p.workMinutes % 60}分` : ''}・税引前${num(d.transportFee) ? `・交通費${yen(num(d.transportFee)!)}は別` : '・交通費別'}` } : { label: '給与見込み', value: '時給が未入力', tone: 'muted' });
      if (num(d.breakMinutes)) out.push({ label: '休憩', value: `${num(d.breakMinutes)}分` });
      break;
    }
    case 'shiftRequest': {
      const ws = slots(d.wishes);
      const conflicts = ws.filter((w) => ctx.events.some((e) => e.start < w.end && w.start < e.end));
      out.push({ label: '希望の枠', value: `${ws.length}件`, note: '確定したシフトとは別に保持します' });
      if (conflicts.length) out.push({ label: '重なり', value: `${conflicts.length}件が既存の予定と重なっています`, tone: 'warn' });
      if (list(d.unavailable).length) out.push({ label: '出られない日', value: list(d.unavailable).join('、') });
      out.push({ label: '状態', value: str(d.status) || '未提出', tone: str(d.status) === '提出済み' ? 'ok' : 'muted' });
      break;
    }
    case 'payday': {
      if (!ev) break;
      const wp = str(d.workplace);
      const period = payPeriod(ev.start, num(d.closingDay) ?? 0);
      const shifts = ctx.events.filter((e) => e.start >= period.from && e.start < period.to && specOf(e)?.type === 'shift' && (!wp || workplaceOf(e, specOf(e), ctx.employers) === wp));
      const pays = shifts.map((e) => { const s = specOf(e)!; return shiftPay(e.start, e.end, num(s.details.hourlyWage), num(s.details.breakMinutes)); });
      const known = pays.filter((x): x is NonNullable<typeof x> => x != null);
      out.push({ label: '対象の勤務', value: `${shifts.length}回`, note: `${new Date(period.from).getMonth() + 1}/${new Date(period.from).getDate()}〜${new Date(period.to - 1).getMonth() + 1}/${new Date(period.to - 1).getDate()}` });
      out.push(known.length ? { label: '見込み額', value: yen(known.reduce((s, x) => s + x.pay, 0)), tone: 'estimate', note: known.length < shifts.length ? `時給が未入力の勤務${shifts.length - known.length}回を除く・税引前` : '税引前・交通費別' } : { label: '見込み額', value: '時給の入った勤務がありません', tone: 'muted' });
      out.push(d.received === true ? { label: '入金', value: num(d.actualAmount) != null ? `確認済み ${yen(num(d.actualAmount)!)}` : '確認済み', tone: 'ok' } : { label: '入金', value: '未確認', tone: 'muted' });
      break;
    }
    case 'class': {
      if (!ev) break;
      const room = ev.classInfo?.room || str(d.room);
      if (str(d.period)) out.push({ label: '時限', value: str(d.period) });
      out.push(room ? { label: '教室', value: room } : { label: '教室', value: '未入力', tone: 'muted' });
      if (list(d.bring).length) out.push({ label: '持ち物', value: list(d.bring).join('、') });
      const related = ctx.tasks.filter((t) => t.sourceEventId === ev.id && t.status !== 'done');
      if (related.length) out.push({ label: '関連する課題', value: `${related.length}件` });
      break;
    }
    case 'assignment': case 'report': {
      if (!task) break;
      if (due != null) out.push({ label: '締切', value: `${md(due)}（${untilText(due, ctx.now)}）`, tone: due - ctx.now < 86_400_000 ? 'warn' : undefined });
      const r = remainingWork(task, ctx.now);
      out.push(r ? { label: '残りの作業', value: `${r.remaining}分`, tone: 'estimate', note: r.provisional ? '実績がまだないため、見積そのままの暫定値' : `見積${task.estimateMinutes}分・実施${r.worked}分` } : { label: '残りの作業', value: '見積時間が未入力', tone: 'muted' });
      progressSubs();
      if (str(d.submitUrl)) out.push({ label: '提出先', value: str(d.submitUrl) });
      break;
    }
    case 'exam': {
      if (!task) break;
      const at = num(d.examAt) ?? task.testPrep?.examAt ?? null;
      out.push(at != null ? { label: '試験まで', value: untilText(at, ctx.now), note: md(at) } : { label: '試験日', value: '未設定', tone: 'muted' });
      if (str(d.scope)) out.push({ label: '範囲', value: str(d.scope) });
      progressSubs();
      break;
    }
    case 'language': {
      const areas = list(d.areas).length ? list(d.areas) : ['語彙', '文法', 'リスニング', 'リーディング'];
      const today = languageToday(areas, ctx.now);
      out.push({ label: '今日の学習', value: `${today}${num(d.dailyMinutes) ? ` ${num(d.dailyMinutes)}分` : ''}` });
      if (num(d.targetScore)) out.push({ label: '目標', value: `${num(d.targetScore)}点` });
      if (num(d.mockDate)) out.push({ label: '本番・模試まで', value: untilText(num(d.mockDate)!, ctx.now) });
      break;
    }
    case 'certification': {
      const units = checks(d.units);
      const left = units.filter((u) => !u.done).length;
      out.push(units.length ? { label: '残りの単元', value: `${left}/${units.length}` } : { label: '単元', value: '未入力', tone: 'muted' });
      const per = unitsPerWeek(left, num(d.examDate), ctx.now);
      if (per != null && left) out.push({ label: '必要なペース', value: `週${per}単元`, tone: 'estimate' });
      if (num(d.examDate)) out.push({ label: '受験日まで', value: untilText(num(d.examDate)!, ctx.now) });
      break;
    }
    case 'presentation': {
      if (!ev) break;
      if (num(d.talkMinutes)) out.push({ label: '持ち時間', value: `${num(d.talkMinutes)}分` });
      if (num(d.materialDue)) out.push({ label: '資料の期限', value: `${md(num(d.materialDue)!)}（${untilText(num(d.materialDue)!, ctx.now)}）` });
      const prep = ctx.tasks.filter((t) => t.sourceEventId === ev.id);
      out.push(prep.length ? { label: '準備', value: `${prep.filter((t) => t.status === 'done' || t.checked).length}/${prep.length}` } : { label: '準備', value: 'まだありません', tone: 'muted' });
      break;
    }
    case 'groupWork': {
      const ms = members(d.members);
      const mine = ms.filter((m) => m.mine);
      out.push({ label: '自分の担当', value: mine.length ? `${mine.filter((m) => m.status === 'done').length}/${mine.length}` : '未設定', tone: mine.length ? undefined : 'muted' });
      const waiting = ms.filter((m) => !m.mine && m.status !== 'done');
      if (waiting.length) out.push({ label: 'ほかの人を待っている', value: waiting.map((m) => `${m.name || '担当者'}（${m.part || '担当'}）`).join('、'), tone: 'muted' });
      break;
    }
    case 'reading': {
      const p = readingPlan(num(d.totalPages), num(d.currentPage), num(d.targetDate), ctx.now);
      out.push(p ? { label: '残り', value: `${p.remaining}ページ` } : { label: '進み具合', value: '今のページが未入力', tone: 'muted', note: '入力がない限り読み終えたとは見なしません' });
      if (p?.perDay != null) out.push({ label: '1日あたり', value: `${p.perDay}ページ`, tone: 'estimate', note: `目標日まで${p.days}日` });
      break;
    }
    case 'shopping': {
      const items = checks(d.items);
      out.push(items.length ? { label: '買う物', value: `${items.filter((x) => x.done).length}/${items.length}` } : { label: '買う物', value: '未入力', tone: 'muted' });
      if (str(d.store)) out.push({ label: 'お店', value: str(d.store) });
      out.push(str(d.storeHours) ? { label: '営業時間', value: str(d.storeHours) } : { label: '営業時間', value: '未確認', tone: 'muted' });
      break;
    }
    case 'appointment': case 'outing': {
      if (!ev) break;
      const travel = ev.extra?.travelMinutes ?? null;
      const early = spec.type === 'appointment' ? num(d.arriveEarly) ?? 10 : 0;
      const prepMin = spec.type === 'outing' ? num(d.prepMinutes) ?? 30 : 0;
      if (spec.type === 'outing' && str(d.meetPlace)) out.push({ label: '集合', value: `${formatHm(ev.start)} ${str(d.meetPlace)}` });
      if (travel == null) out.push({ label: '出発の目安', value: '移動時間が未入力', tone: 'muted', note: '0分として詰めません。場所と移動から入力できます' });
      else out.push({ label: '出発の目安', value: formatHm(ev.start - (travel + early) * MINUTE), tone: 'estimate', note: `移動${travel}分${early ? `・受付の余裕${early}分` : ''}` });
      if (spec.type === 'outing' && travel != null) out.push({ label: '支度を始める', value: formatHm(ev.start - (travel + prepMin) * MINUTE), tone: 'estimate', note: '支度の予定は自分だけに表示します' });
      if (spec.type === 'appointment' && list(d.bring).length) out.push({ label: '持ち物', value: list(d.bring).join('、') });
      break;
    }
    case 'trip': {
      if (!ev) break;
      const nights = Math.max(0, dayDiff(ev.end - 1, ev.start));
      out.push({ label: '日程', value: nights ? `${nights}泊${nights + 1}日` : '日帰り' });
      if (num(d.meetTime)) out.push({ label: '集合', value: md(num(d.meetTime)!) });
      const tz = str(d.destTimeZone);
      if (tz && tz !== ev.timeZone) out.push({ label: '現地の時刻', value: `${timeIn(ev.start, tz)} 出発時（${tz}）`, note: `端末の時刻 ${formatHm(ev.start)}` });
      const pk = checks(d.packing);
      if (pk.length) out.push({ label: '持ち物', value: `${pk.filter((x) => x.done).length}/${pk.length}` });
      break;
    }
    case 'transit': {
      if (!ev) break;
      const m = num(d.minutes) ?? ev.extra?.travelMinutes ?? null;
      out.push(m != null ? { label: '所要時間', value: `${m}分`, note: str(d.mode) || undefined } : { label: '所要時間', value: '未入力', tone: 'warn', note: '0分として予定を詰めません' });
      if (str(d.from) || str(d.to)) out.push({ label: '区間', value: `${str(d.from) || '?'} → ${str(d.to) || '?'}` });
      break;
    }
    case 'routine': {
      if (!task) break;
      const st = steps(d.steps).length ? steps(d.steps) : SPEC_BY_ID.routine.steps!;
      const f = routineForecast(st, subs, ctx.now);
      out.push({ label: '合計', value: `${f.total}分` });
      if (task.status === 'running' || subs.some((s) => s.done)) out.push({ label: '終わる見込み', value: formatHm(f.endAt), tone: 'estimate', note: `残り${f.remaining}分` });
      else if (task.plannedEnd != null) out.push({ label: '始める目安', value: formatHm(task.plannedEnd - f.total * MINUTE), tone: 'estimate' });
      break;
    }
    case 'chores': case 'workout': {
      if (!task) break;
      const same = ctx.tasks.filter((t) => t.id !== task.id && t.title === task.title && t.status === 'done' && t.actualEnd != null).sort((a, b) => b.actualEnd! - a.actualEnd!);
      out.push(same[0] ? { label: '前回', value: md(same[0].actualEnd!) } : { label: '前回', value: '記録なし', tone: 'muted' });
      if (spec.type === 'workout') {
        const ws = addDays(startOfDay(ctx.now), -new Date(ctx.now).getDay());
        const n = same.filter((t) => t.actualEnd! >= ws).length;
        if (num(d.perWeek)) out.push({ label: '今週', value: `${n}/${num(d.perWeek)}回`, note: '休む日も大切にします' });
      }
      if (task.repeat) out.push({ label: '頻度', value: `${{ daily: '毎日', weekly: '毎週', monthly: '毎月' }[task.repeat.freq]}${task.repeat.interval > 1 ? `（${task.repeat.interval}回ごと）` : ''}` });
      break;
    }
    case 'cooking': {
      const ing = checks(d.ingredients);
      const missing = ing.filter((x) => !x.done);
      out.push(ing.length ? { label: '足りない材料', value: missing.length ? missing.map((x) => x.name).join('、') : 'なし', tone: missing.length ? 'warn' : 'ok' } : { label: '材料', value: '未入力', tone: 'muted' });
      break;
    }
    case 'project': {
      out.push({ label: 'テスト結果', value: str(d.testResult) || '未記録', tone: str(d.testResult) === '成功' ? 'ok' : str(d.testResult) === '失敗' ? 'warn' : 'muted', note: '実行した結果だけを自分で記録します' });
      progressSubs();
      if (str(d.deliverable)) out.push({ label: '成果物', value: str(d.deliverable) });
      break;
    }
    case 'paperwork': {
      if (due != null) out.push({ label: '提出期限', value: `${md(due)}（${untilText(due, ctx.now)}）` });
      out.push(str(d.windowHours) ? { label: '窓口の受付', value: str(d.windowHours), note: '期限とは別です' } : { label: '窓口の受付', value: '未確認', tone: 'muted' });
      const docs = checks(d.docs);
      if (docs.length) out.push({ label: '必要な書類', value: `${docs.filter((x) => x.done).length}/${docs.length}` });
      break;
    }
    case 'payment': {
      if (!task) break;
      if (task.checkAt != null) out.push({ label: '期日', value: `${md(task.checkAt)}（${untilText(task.checkAt, ctx.now)}）` });
      if (num(d.amount) != null) out.push({ label: '金額', value: yen(num(d.amount)!) });
      out.push(d.paid === true ? { label: '状態', value: '支払い済み（自分で記録）', tone: 'ok' } : { label: '状態', value: '未確認', tone: 'muted', note: '外部と照合しないため、自分で記録するまで支払い済みにしません' });
      break;
    }
    case 'leisure': {
      out.push({ label: '使い方', value: '空き時間に候補として出します', tone: 'muted', note: '確定した予定には勝手に入れません' });
      break;
    }
  }
  return out;
}

/** 種類を新しく選んだときの詳細の初期値 */
export function defaultDetails(type: SpecTypeId): Record<string, unknown> {
  switch (type) {
    case 'shift': return { breakMinutes: 0 };
    case 'language': return { areas: ['語彙', '文法', 'リスニング', 'リーディング'] };
    case 'routine': return { steps: SPEC_BY_ID.routine.steps };
    case 'project': return { testResult: '未記録' };
    case 'shiftRequest': return { status: '未提出', wishes: [] };
    case 'exam': return { reviewCount: 3 };
    case 'appointment': return { arriveEarly: 10 };
    case 'outing': return { prepMinutes: 30 };
    default: return {};
  }
}

export { CHECK as makeCheckItem };
