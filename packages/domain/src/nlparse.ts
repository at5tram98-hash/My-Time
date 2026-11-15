/**
 * 文章からの入力（端末内の規則で解釈する。外部のAIには送らない）。
 *
 * - P01：「明日は課題2つと買い物」のような文章から、予定・タスクの候補を複数作る。保存前に一画面で確認する。
 * - P02：「夕方」「授業後」のような曖昧な時刻は候補とし、推定の根拠を必ず付ける（timeCertain=false）。
 * - P03：「来週のバイト」は検索、「〜を1時間遅らせて」は変更、「今日の課題を移して」は再計画として扱う。
 * 解釈できない部分は捨てずにタイトルに残す（勝手に情報を消さない）。
 */
import type { CalEvent, Employer, EpochMs, Subtask, Task } from './types';
import type { Occurrence } from './recurrence';
import { addDays, formatHm, HOUR, MINUTE, startOfDay, weekday } from './time';
import { busyItems, DEFAULT_PLAN, findSlots, prepBefore, type BusyItem, type PlanOptions } from './planner';
import { deadlineOf, specOf, SPEC_BY_ID, type SpecTypeId } from './spec';

type Ev = CalEvent | Occurrence;

export interface ParseContext {
  now: EpochMs;
  events: readonly Ev[];
  tasks: readonly Task[];
  subtasks?: readonly Subtask[];
  employers?: readonly Employer[];
  opts?: PlanOptions;
}

export interface CandidateChild { title: string; start: EpochMs; end: EpochMs }

export interface Candidate {
  key: string;
  entity: 'event' | 'task';
  spec: SpecTypeId | null;
  title: string;
  start: EpochMs | null;
  end: EpochMs | null;
  /** 締切（「金曜までに」など） */
  due: EpochMs | null;
  estimateMinutes: number | null;
  /** 文章に時刻がはっきり書かれていたか。false は「候補」 */
  timeCertain: boolean;
  /** どう読んだか（画面に出す根拠） */
  reasons: string[];
  details: Record<string, unknown>;
  /** 予定の前に置く準備（右のレーン）の候補 */
  prep: CandidateChild[];
  /** 締切までの作業枠の候補 */
  sessions: CandidateChild[];
  /** 勤務先（S01）。既存の勤務先と一致すれば employerId */
  workplace: string | null;
  employerId: string | null;
}

export interface SearchQuery { from: EpochMs | null; to: EpochMs | null; words: string[]; spec: SpecTypeId | null; label: string; before?: string | null }

export type ParseResult =
  | { intent: 'create'; candidates: Candidate[]; notes: string[] }
  | { intent: 'search'; query: SearchQuery; notes: string[] }
  | { intent: 'shift'; target: SearchQuery; deltaMin: number; notes: string[] }
  | { intent: 'move'; target: SearchQuery; toDay: EpochMs; notes: string[] }
  | { intent: 'replan'; day: EpochMs; spec: SpecTypeId | null; notes: string[] };

// ---------------- 文字の正規化 ----------------
export function normalizeText(s: string): string {
  return s
    .replace(/[０-９]/g, (c) => String.fromCharCode(c.charCodeAt(0) - 0xfee0))
    .replace(/[Ａ-Ｚａ-ｚ]/g, (c) => String.fromCharCode(c.charCodeAt(0) - 0xfee0))
    .replace(/[：]/g, ':')
    .replace(/[／]/g, '/')
    .replace(/(\d)\s*[~～〜－ー−-]\s*(?=\d|午)/g, '$1〜')
    .replace(/\u3000/g, ' ')
    .replace(/[？]/g, '?')
    .trim();
}

const KANJI_NUM: Record<string, number> = { 一: 1, 二: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9, 十: 10 };
const WD = '日月火水木金土';

/** 種類の判定順（具体的なものを先に） */
const SPEC_ORDER: SpecTypeId[] = ['shiftRequest', 'payday', 'shift', 'groupWork', 'report', 'exam', 'assignment', 'presentation', 'language', 'certification', 'class', 'shopping', 'appointment', 'trip', 'transit', 'routine', 'outing', 'chores', 'cooking', 'workout', 'project', 'paperwork', 'payment', 'reading', 'leisure'];

export function detectSpec(s: string): SpecTypeId | null {
  for (const id of SPEC_ORDER) if (SPEC_BY_ID[id].keywords.test(s)) return id;
  return null;
}

// ---------------- 日付 ----------------
interface DateHit { day: EpochMs; label: string; deadline: boolean; rest: string }

export function takeDate(s: string, now: EpochMs): DateHit | null {
  const today = startOfDay(now);
  const tries: [RegExp, (m: RegExpMatchArray) => { day: EpochMs; label: string } | null][] = [
    [/(\d{1,2})月(\d{1,2})日/, (m) => { const d = new Date(today); let t = new Date(d.getFullYear(), Number(m[1]) - 1, Number(m[2])).getTime(); if (t < addDays(today, -60)) t = new Date(d.getFullYear() + 1, Number(m[1]) - 1, Number(m[2])).getTime(); return { day: startOfDay(t), label: m[0] }; }],
    [/(?<![\d:])(\d{1,2})\/(\d{1,2})(?![\d:])/, (m) => { const d = new Date(today); let t = new Date(d.getFullYear(), Number(m[1]) - 1, Number(m[2])).getTime(); if (t < addDays(today, -60)) t = new Date(d.getFullYear() + 1, Number(m[1]) - 1, Number(m[2])).getTime(); return { day: startOfDay(t), label: m[0] }; }],
    [/(明後日|あさって)/, (m) => ({ day: addDays(today, 2), label: m[0] })],
    [/(明日|あした|あす)/, (m) => ({ day: addDays(today, 1), label: m[0] })],
    [/(今日|きょう|本日|今夜|今晩)/, (m) => ({ day: today, label: m[0] })],
    [/(再来週|来週|今週)?の?([日月火水木金土])曜日?/, (m) => {
      const wd = WD.indexOf(m[2]!);
      const ws = addDays(today, -weekday(today));
      if (m[1] === '今週') return { day: addDays(ws, wd), label: m[0] };
      if (m[1] === '来週') return { day: addDays(ws, 7 + wd), label: m[0] };
      if (m[1] === '再来週') return { day: addDays(ws, 14 + wd), label: m[0] };
      const diff = (wd - weekday(today) + 7) % 7;
      return { day: addDays(today, diff), label: m[0] };
    }],
    [/週末/, (m) => ({ day: addDays(today, (6 - weekday(today) + 7) % 7), label: m[0] })],
    [/(?<![\d月/])(\d{1,2})日(?=に|まで|は|の|\s|$|、)/, (m) => { const d = new Date(today); let t = new Date(d.getFullYear(), d.getMonth(), Number(m[1])).getTime(); if (t < today) t = new Date(d.getFullYear(), d.getMonth() + 1, Number(m[1])).getTime(); return { day: startOfDay(t), label: m[0] }; }],
  ];
  for (const [re, f] of tries) {
    const m = s.match(re);
    if (!m) continue;
    const r = f(m);
    if (!r) continue;
    const after = s.slice((m.index ?? 0) + m[0].length);
    const deadline = /^\s*(まで|迄|締切|締め切り|〆切|期限)/.test(after);
    const rest = (s.slice(0, m.index) + after.replace(/^\s*(までに|まで|迄に|迄|締切|締め切り|〆切|期限)/, '')).replace(/^\s*(は|に|の|、)/, '');
    return { ...r, deadline, rest };
  }
  return null;
}

// ---------------- 時刻 ----------------
interface TimeHit { startMin: number; endMin: number | null; certain: boolean; reason: string | null; rest: string }

const HM = '(午前|午後|朝|夜|夕方)?\\s*(\\d{1,2})(?::(\\d{2})|時(?:(\\d{1,2})分|(半))?)(?!間)';
function toMin(ampm: string | undefined, h: string, m1?: string, m2?: string, half?: string): { min: number; guessed: boolean } {
  let hour = Number(h);
  let guessed = false;
  if ((ampm === '午後' || ampm === '夜' || ampm === '夕方') && hour < 12) hour += 12;
  else if (!ampm && hour >= 1 && hour <= 6) { hour += 12; guessed = true; }
  const minute = m1 ? Number(m1) : m2 ? Number(m2) : half ? 30 : 0;
  return { min: Math.min(24 * 60, hour * 60 + minute), guessed };
}

export function takeTimes(s: string): TimeHit | null {
  const range = new RegExp(`${HM}\\s*(?:〜|から|より)\\s*${HM}(?:まで)?`);
  let m = s.match(range);
  if (m) {
    const a = toMin(m[1], m[2]!, m[3], m[4], m[5]);
    const b = toMin(m[6] ?? (a.min >= 12 * 60 && Number(m[7]) < 12 ? '午後' : undefined), m[7]!, m[8], m[9], m[10]);
    let end = b.min;
    if (end <= a.min) end += 24 * 60; // 日付をまたぐ
    return { startMin: a.min, endMin: end, certain: !a.guessed, reason: a.guessed ? `「${m[2]}時」を${Math.floor(a.min / 60)}:00と読みました` : null, rest: s.replace(m[0], ' ') };
  }
  m = s.match(new RegExp(`${HM}\\s*(に|から|〜|頃|ごろ|開始|集合)?`));
  if (m) {
    const a = toMin(m[1], m[2]!, m[3], m[4], m[5]);
    return { startMin: a.min, endMin: null, certain: !a.guessed && !/頃|ごろ/.test(m[6] ?? ''), reason: a.guessed ? `「${m[2]}時」を${Math.floor(a.min / 60)}:00と読みました` : /頃|ごろ/.test(m[6] ?? '') ? '「頃」とあるため目安の時刻です' : null, rest: s.replace(m[0], ' ') };
  }
  return null;
}

/** 曖昧な時間帯（P02） */
const VAGUE: [RegExp, number, number, string][] = [
  [/午前中/, 9, 12, '午前中'],
  [/(お昼|昼休み|昼)/, 12, 13.5, 'お昼'],
  [/朝(?!食)/, 7, 9, '朝'],
  [/午後/, 13, 17, '午後'],
  [/夕方/, 17, 19, '夕方'],
  [/(寝る前|就寝前)/, 22, 23.5, '寝る前'],
  [/(今夜|今晩|夜)/, 19, 22, '夜'],
];

interface VagueHit { from: EpochMs; to: EpochMs; label: string; rest: string }
function takeVague(s: string, day: EpochMs, ctx: ParseContext): VagueHit | null {
  const after = s.match(/(授業|講義|バイト|勤務|仕事)(の)?(後|あと|終わり)|放課後/);
  if (after) {
    const spec: SpecTypeId = /授業|講義|放課後/.test(after[0]) ? 'class' : 'shift';
    const ref = ctx.events.filter((e) => e.start >= day && e.start < addDays(day, 1) && specOf(e)?.type === spec).sort((a, b) => b.end - a.end)[0];
    if (ref) return { from: ref.end + (ref.extra?.travelMinutes ?? 0) * MINUTE, to: Math.min(ref.end + 4 * HOUR, day + 23 * HOUR), label: `「${after[0]}」を「${ref.title}」の終わり（${formatHm(ref.end)}）以降`, rest: s.replace(after[0], ' ') };
    return { from: day + 17 * HOUR, to: day + 21 * HOUR, label: `「${after[0]}」に当たる予定が見つからないため17:00以降`, rest: s.replace(after[0], ' ') };
  }
  for (const [re, a, b, label] of VAGUE) {
    const m = s.match(re);
    if (m) return { from: day + a * HOUR, to: day + b * HOUR, label: `「${label}」を${formatHm(day + a * HOUR)}〜${formatHm(day + b * HOUR)}`, rest: s.replace(m[0], ' ') };
  }
  return null;
}

// ---------------- 時間の長さ・お金 ----------------
function takeDuration(s: string): { minutes: number; rest: string } | null {
  let m = s.match(/(\d+(?:\.\d+)?)\s*時間(半)?\s*(ぐらい|くらい|程度|ほど|位)?/);
  if (m) return { minutes: Math.round(Number(m[1]) * 60 + (m[2] ? 30 : 0)), rest: s.replace(m[0], ' ') };
  m = s.match(/([一二三四五六七八九十])\s*時間(半)?/);
  if (m) return { minutes: (KANJI_NUM[m[1]!] ?? 1) * 60 + (m[2] ? 30 : 0), rest: s.replace(m[0], ' ') };
  m = s.match(/(?<!休憩\s*)(\d+)\s*分\s*(ぐらい|くらい|程度|ほど|間)?(?!から)/);
  if (m) return { minutes: Number(m[1]), rest: s.replace(m[0], ' ') };
  m = s.match(/半日/);
  if (m) return { minutes: 240, rest: s.replace(m[0], ' ') };
  return null;
}

interface Money { wage?: number; transport?: number; breakMin?: number; amount?: number }
function takeMoney(s: string): { money: Money; rest: string } {
  const money: Money = {};
  let rest = s;
  const yenNum = (x: string) => Number(x.replace(/,/g, ''));
  let m = rest.match(/時給\s*([\d,]+)\s*円?/);
  if (m) { money.wage = yenNum(m[1]!); rest = rest.replace(m[0], ' '); }
  m = rest.match(/交通費\s*([\d,]+)\s*円?/);
  if (m) { money.transport = yenNum(m[1]!); rest = rest.replace(m[0], ' '); }
  m = rest.match(/休憩\s*(\d+)\s*分/);
  if (m) { money.breakMin = Number(m[1]); rest = rest.replace(m[0], ' '); }
  m = rest.match(/休憩\s*(なし|無し|0)/);
  if (m) { money.breakMin = 0; rest = rest.replace(m[0], ' '); }
  m = rest.match(/([\d,]{2,})\s*円/);
  if (m) { money.amount = yenNum(m[1]!); rest = rest.replace(m[0], ' '); }
  return { money, rest };
}

// ---------------- タイトルの整形 ----------------
const TRAIL = /(を?したい|を?やりたい|したく|をやる|をする|やる|する|します|しなきゃ|しないと|に行く|へ行く|に行きたい|行く|行きたい|予定|ぐらい|くらい|程度|頃|ごろ|かかる|かかりそう|を?入れて|を?追加して|を?追加|がある|ある|です|。|、|\s)+$/;
export function cleanTitle(s: string): string {
  let t = s.replace(/\s+/g, ' ').trim();
  for (let i = 0; i < 4; i++) {
    t = t.replace(/^[はをにでのもと、・\s]+/, '').replace(TRAIL, '').replace(/[はをにでのがもと]$/, '').trim();
  }
  return t;
}

function defaultTitle(spec: SpecTypeId | null, workplace: string | null): string {
  if (spec === 'shift') return workplace ? `${workplace} 勤務` : '勤務';
  if (spec === 'outing') return '外出';
  if (spec === 'shopping') return '買い物';
  if (spec === 'assignment') return '課題';
  if (spec === 'chores') return '家事';
  if (spec) return SPEC_BY_ID[spec].name;
  return '新しい予定';
}

// ---------------- 分割 ----------------
export function splitItems(text: string): string[] {
  const parts = text.split(/(?<!\d),(?!\d)|[\n。、，;；]+/).map((x) => x.trim()).filter(Boolean);
  const out: string[] = [];
  for (const p of parts) {
    const pieces = p.split('と');
    if (pieces.length > 1 && pieces.every((x) => x.trim() && (detectSpec(x) || /\d+\s*(つ|個|件)/.test(x)))) out.push(...pieces.map((x) => x.trim()));
    else out.push(p);
  }
  return out;
}

// ---------------- 意図 ----------------
function querySpecAndWords(s: string): { spec: SpecTypeId | null; words: string[]; before: string | null } {
  const beforeM = s.match(/([^\sのを]+?)(の)?前の/);
  const before = beforeM ? beforeM[1]! : null;
  const stripped = (beforeM ? s.replace(beforeM[0], '') : s).replace(/^(の|は)/, '');
  const parts = stripped.split('の').map((x) => cleanTitle(x)).filter(Boolean);
  const head = parts.at(-1) ?? '';
  const spec = detectSpec(head);
  return { spec, words: spec ? [] : head ? [head] : [], before };
}

function rangeFor(s: string, now: EpochMs): { from: EpochMs | null; to: EpochMs | null; label: string; rest: string } {
  const today = startOfDay(now);
  const ws = addDays(today, -weekday(today));
  if (/来週/.test(s) && !/来週の?[日月火水木金土]曜/.test(s)) return { from: addDays(ws, 7), to: addDays(ws, 14), label: '来週', rest: s.replace('来週', '') };
  if (/今週/.test(s) && !/今週の?[日月火水木金土]曜/.test(s)) return { from: today, to: addDays(ws, 7), label: '今週', rest: s.replace('今週', '') };
  if (/今月/.test(s)) { const d = new Date(today); return { from: today, to: new Date(d.getFullYear(), d.getMonth() + 1, 1).getTime(), label: '今月', rest: s.replace('今月', '') }; }
  const d = takeDate(s, now);
  if (d) return { from: d.day, to: addDays(d.day, 1), label: d.label, rest: d.rest };
  return { from: null, to: null, label: '', rest: s };
}

export function parseInput(raw: string, ctx: ParseContext): ParseResult {
  const text = normalizeText(raw);
  const now = ctx.now;
  // 変更：〜を1時間遅らせて / 30分早めて（P04）
  let m = text.match(/^(.+?)を\s*(\d+(?:\.\d+)?|[一二三四五])\s*(時間|分)(半)?\s*(遅ら|後ろ|後に|ずら|早め|前に|繰り上)/);
  if (m) {
    const n = /\d/.test(m[2]!) ? Number(m[2]) : KANJI_NUM[m[2]!] ?? 1;
    const minutes = (m[3] === '時間' ? n * 60 : n) + (m[4] ? 30 : 0);
    const sign = /早め|前に|繰り上/.test(m[5]!) ? -1 : 1;
    const r = rangeFor(m[1]!, now);
    const q = querySpecAndWords(r.rest);
    return { intent: 'shift', target: { from: r.from, to: r.to, ...q, label: m[1]! }, deltaMin: sign * minutes, notes: [] };
  }
  // 移動：〜を明日に移して（日付つき）
  m = text.match(/^(.+?)を\s*(.+?)に\s*(移|変更|回|ずら|動か)/);
  if (m) {
    const to = takeDate(m[2]!, now);
    if (to) {
      const r = rangeFor(m[1]!, now);
      const q = querySpecAndWords(r.rest);
      return { intent: 'move', target: { from: r.from, to: r.to, ...q, label: m[1]! }, toDay: to.day, notes: [] };
    }
  }
  // 再計画：急用ができたので今日の課題を移して（P05）
  if (/(急用|予定が変わ|組み直|やり直|再計画|立て直|移して|ずらして|回して|組み替え)/.test(text)) {
    const r = rangeFor(text, now);
    const spec = detectSpec(text.replace(/(急用|予定が変わ\S*)/, ''));
    return { intent: 'replan', day: r.from ?? startOfDay(now), spec, notes: [] };
  }
  // 検索（P03）：「来週のバイト」「金曜の提出物」「〜はいつ？」
  const isQuestion = /(\?|いつ|探して|見せて|教えて|ある\?|は\?$)/.test(text);
  const shortRef = /^(今日|明日|明後日|今週|来週|今月|[日月火水木金土]曜日?|\d{1,2}月\d{1,2}日|\d{1,2}\/\d{1,2})の[^\d:時分]+$/.test(text) && !/(したい|やる|する|行く|入れ|追加|まで)/.test(text);
  if (isQuestion || shortRef) {
    const r = rangeFor(text.replace(/(\?|はいつ|いつ|を?探して|を?見せて|を?教えて|ある|は$)/g, ''), now);
    const q = querySpecAndWords(r.rest);
    return { intent: 'search', query: { from: r.from, to: r.to, ...q, label: text }, notes: [] };
  }
  return { intent: 'create', ...createCandidates(text, ctx) };
}

// ---------------- 作成の候補 ----------------
function createCandidates(text: string, ctx: ParseContext): { candidates: Candidate[]; notes: string[] } {
  const now = ctx.now;
  const opts = ctx.opts ?? DEFAULT_PLAN;
  const notes: string[] = [];
  const out: Candidate[] = [];
  let sharedDay: { day: EpochMs; label: string } | null = null;
  const busy: BusyItem[] = busyItems(ctx.events, ctx.tasks, ctx.subtasks ?? []);

  interface Raw { text: string; day: EpochMs | null; dayLabel: string | null; ownDate: boolean; deadline: boolean; time: TimeHit | null; vague: VagueHit | null; duration: number | null; money: Money; spec: SpecTypeId | null; title: string; count: number }
  const raws: Raw[] = [];
  for (const seg of splitItems(text)) {
    let rest = seg;
    const d = takeDate(rest, now);
    if (d) { rest = d.rest; if (!sharedDay) sharedDay = { day: d.day, label: d.label }; }
    const money = takeMoney(rest); rest = money.rest;
    const time = takeTimes(rest); if (time) rest = time.rest;
    const dur = takeDuration(rest); if (dur) rest = dur.rest;
    const day = d?.day ?? sharedDay?.day ?? null;
    const vague = !time && day != null ? takeVague(rest, day, ctx) : !time ? takeVague(rest, startOfDay(now), ctx) : null;
    if (vague) rest = vague.rest;
    let spec = detectSpec(seg);
    let count = 1;
    const qm = rest.match(/(\d+|[一二三四五六七八九])\s*(つ|個|件|コ)/);
    if (qm) { count = Math.min(9, /\d/.test(qm[1]!) ? Number(qm[1]) : KANJI_NUM[qm[1]!] ?? 1); rest = rest.replace(qm[0], ' '); }
    if (money.money.wage != null) spec = 'shift';
    const title = cleanTitle(rest);
    raws.push({ text: seg, day, dayLabel: d?.label ?? (sharedDay && !d ? sharedDay.label : null), ownDate: !!d, deadline: !!d?.deadline, time, vague, duration: dur?.minutes ?? null, money: money.money, spec, title, count });
  }
  // 属性だけの断片（「時給1,300円」「2時間ぐらい」）は直前の項目に足す
  const merged: Raw[] = [];
  for (const r of raws) {
    const prev = merged.at(-1);
    const onlyAttr = !r.title && !r.spec && !r.ownDate && (r.duration != null || Object.keys(r.money).length > 0 || (r.time && !r.title));
    if (prev && (onlyAttr || (!r.title && r.money.wage != null && !r.time && !r.ownDate))) {
      prev.duration ??= r.duration;
      prev.money = { ...prev.money, ...r.money };
      prev.time ??= r.time;
      if (r.money.wage != null) prev.spec = 'shift';
      continue;
    }
    merged.push(r);
  }

  for (const r of merged) {
    let spec = r.spec;
    // 長い作業のレポートは「レポート・論文制作」
    if (spec === 'assignment' && /レポート/.test(r.text) && (r.duration ?? 0) >= 240) spec = 'report';
    const def = spec ? SPEC_BY_ID[spec] : null;
    const hasTime = !!r.time || !!r.vague;
    let entity: 'event' | 'task' = def ? def.entity : hasTime && !/(したい|やる|する|作業|勉強)/.test(r.text) ? 'event' : 'task';
    if (def?.entity === 'event' && !hasTime && r.day == null) entity = 'task';
    // 勤務先（S01）
    let workplace: string | null = null;
    let employerId: string | null = null;
    let title = r.title;
    if (spec === 'shift') {
      const wp = cleanTitle(title.replace(SPEC_BY_ID.shift.keywords, ' '));
      if (wp) {
        workplace = wp;
        const hit = (ctx.employers ?? []).find((e) => e.name.toLowerCase() === wp.toLowerCase());
        employerId = hit?.id ?? null;
        if (hit) workplace = hit.name;
      }
      title = defaultTitle('shift', workplace);
    }
    // タイトルが種類の語だけ（「出かける」「買い物」）なら、種類の名前を使う
    if (spec && spec !== 'shift' && cleanTitle(title.replace(SPEC_BY_ID[spec].keywords, ' ')).length <= 1) title = '';
    for (let i = 0; i < r.count; i++) {
      const reasons: string[] = [];
      const base = title || defaultTitle(spec, workplace);
      const t = r.count > 1 ? `${base}${i + 1}` : base;
      const details: Record<string, unknown> = {};
      if (spec === 'shift') {
        if (workplace) details.workplace = workplace;
        if (r.money.wage != null) details.hourlyWage = r.money.wage;
        details.breakMinutes = r.money.breakMin ?? 0;
        if (r.money.transport != null) details.transportFee = r.money.transport;
      }
      if (spec === 'payment' && r.money.amount != null) details.amount = r.money.amount;
      let start: EpochMs | null = null;
      let end: EpochMs | null = null;
      let due: EpochMs | null = null;
      let certain = false;
      const day = r.day ?? (hasTime ? startOfDay(now) : null);
      if (r.deadline && r.day != null) { due = r.day + 23 * HOUR + 59 * MINUTE; reasons.push(`締切を${r.dayLabel}の23:59としました`); }
      const length = r.duration ?? (entity === 'event' ? 60 : 30);
      if (r.time && day != null) {
        start = day + r.time.startMin * MINUTE;
        end = r.time.endMin != null ? day + r.time.endMin * MINUTE : start + length * MINUTE;
        certain = r.time.certain;
        if (r.time.reason) reasons.push(r.time.reason);
        if (r.time.endMin == null) reasons.push(r.duration != null ? `長さ${r.duration}分` : `終わりの時刻がないため、仮に${length}分としました`);
      } else if (r.vague) {
        const slot = findSlots(length, busy, Math.max(now, r.vague.from), r.vague.to, 1, opts)[0];
        start = slot?.start ?? Math.max(r.vague.from, now);
        end = start + length * MINUTE;
        reasons.push(`${r.vague.label}として、${slot ? `空いている${formatHm(start)}を仮に選びました` : `${formatHm(start)}を仮に選びました（空きがありません）`}`);
      } else if (entity === 'task' && r.day != null && !r.deadline) {
        // 日付だけ：その日の空き時間を候補にする
        const slot = findSlots(length, busy, Math.max(now, r.day), addDays(r.day, 1), 1, opts)[0];
        if (slot) { start = slot.start; end = slot.end; reasons.push(`時刻が書かれていないため、${r.dayLabel ?? 'その日'}の空き時間${formatHm(slot.start)}〜を候補にしました`); }
        else { due = r.day + 23 * HOUR + 59 * MINUTE; reasons.push(`${r.dayLabel ?? 'その日'}に空きがないため、時刻を決めずに置きます`); }
      } else if (entity === 'event' && r.day != null) {
        start = r.day; end = addDays(r.day, 1);
        reasons.push('時刻がないため、終日の予定にします');
        details.__allDay = true;
      }
      if (spec && !def) reasons.push('');
      if (def && spec !== null) reasons.unshift(`種類：${def.name}（${def.code}）`);
      const cand: Candidate = { key: `c${out.length}`, entity, spec, title: t, start, end, due, estimateMinutes: r.duration, timeCertain: certain, reasons: reasons.filter(Boolean), details, prep: [], sessions: [], workplace, employerId };
      // 予定の前の準備（S01・S14・S15）
      if (entity === 'event' && def?.prep && start != null && end != null && !details.__allDay) {
        const before = def.prep.filter((p) => p.place === 'before');
        if (before.length) {
          cand.prep = prepBefore(start, null, before.map((p) => ({ title: p.title, minutes: spec === 'outing' && p.title === '髪・身支度' ? 30 : p.minutes })));
          cand.reasons.push(`準備の時間は目安です。移動時間は分からないため含めていません`);
        }
      }
      // 締切つきで時間のかかるタスク（S05）：締切までの空きに作業枠を置く
      if (entity === 'task' && due != null && r.duration != null && start == null) {
        const per = Math.min(60, r.duration);
        const n = Math.max(1, Math.ceil(r.duration / per));
        const slots = findSlots(Math.ceil(r.duration / n / 15) * 15, busy, now, due, n, opts);
        const names = n === 1 ? ['作業'] : Array.from({ length: n }, (_, k) => (k === 0 ? '着手' : k === n - 1 ? '見直し' : `続き${k}`));
        cand.sessions = slots.map((s, k) => ({ title: names[k] ?? `作業${k + 1}`, start: s.start, end: s.end }));
        if (slots.length) { cand.reasons.push(`締切までの空きに${slots.length}回の作業枠を候補にしました（締切は動かしません）`); slots.forEach((s) => busy.push({ id: `tmp:${s.start}`, refId: '', title: '', kind: 'task', fixed: false, ...s })); }
        else cand.reasons.push('締切までに空きが見つかりません');
      }
      if (start != null && end != null && !details.__allDay) busy.push({ id: `tmp:${out.length}`, refId: '', title: t, kind: entity === 'event' ? 'event' : 'task', fixed: entity === 'event', start, end });
      out.push(cand);
    }
  }
  if (!out.length) notes.push('予定やタスクとして読み取れませんでした。「明日18時から勤務」「金曜までに課題 2時間」のように書いてください');
  return { candidates: out, notes };
}

// ---------------- 検索（P03・P46） ----------------
export interface SearchHit { entity: 'event' | 'task'; id: string; title: string; at: EpochMs | null; spec: SpecTypeId | null }

export function searchItems(q: SearchQuery, events: readonly Ev[], tasks: readonly Task[]): SearchHit[] {
  const inRange = (t: EpochMs | null) => t != null && (q.from == null || t >= q.from) && (q.to == null || t < q.to);
  const words = q.words.map((w) => w.toLowerCase());
  const okWords = (title: string) => !words.length || words.some((w) => title.toLowerCase().includes(w));
  const hits: SearchHit[] = [];
  for (const e of events) {
    const s = specOf(e);
    if (q.spec && s?.type !== q.spec) continue;
    if (!okWords(e.title)) continue;
    if ((q.from != null || q.to != null) && !(e.start < (q.to ?? Infinity) && e.end > (q.from ?? -Infinity))) continue;
    hits.push({ entity: 'event', id: e.id, title: e.title, at: e.start, spec: s?.type ?? null });
  }
  for (const t of tasks) {
    const s = specOf(t);
    if (q.spec && s?.type !== q.spec) continue;
    if (!okWords(t.title)) continue;
    const at = t.plannedStart ?? t.checkAt ?? deadlineOf(t, s);
    if ((q.from != null || q.to != null) && !inRange(at)) continue;
    hits.push({ entity: 'task', id: t.id, title: t.title, at, spec: s?.type ?? null });
  }
  let out = hits.sort((a, b) => (a.at ?? Infinity) - (b.at ?? Infinity));
  // 「バイト前の勉強」：基準の予定より前に終わるものに絞る
  if (q.before) {
    const ref = events.find((e) => (detectSpec(q.before!) ? specOf(e)?.type === detectSpec(q.before!) : e.title.includes(q.before!)) && (q.from == null || e.start >= q.from) && (q.to == null || e.start < q.to));
    if (ref) out = out.filter((h) => h.id !== ref.id && h.at != null && h.at < ref.start);
  }
  return out;
}
