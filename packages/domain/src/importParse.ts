import type { CalEvent as CalEventT } from './types';
import type { CalEvent, EpochMs } from './types';
import { overlaps } from './layout';
import { fromWall, wall } from './time';

/** 取り込み候補（TimeTree などから。名前・日時・自分/相手・カレンダー分類のみ） */
export interface ImportCandidate {
  externalId: string | null;
  title: string;
  start: EpochMs;
  end: EpochMs;
  owner: 'me' | 'partner';
  calendarName: string | null;
  fingerprint: string;
}

export function fingerprint(title: string, start: EpochMs, end: EpochMs): string {
  return `${title.normalize('NFKC').replace(/\s+/g, '').toLowerCase()}|${start}|${end}`;
}

function unfold(text: string): string[] {
  return text.replace(/\r\n/g, '\n').replace(/\n[ \t]/g, '').split('\n');
}

function parseIcsDate(value: string, params: string): EpochMs | null {
  const m = /^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})?(Z)?)?$/.exec(value.trim());
  if (!m) return null;
  const [, y, mo, d, h, mi, s, z] = m;
  if (h == null) return fromWall(+y!, +mo! - 1, +d!); // 終日：利用者の時刻の0:00
  if (z) return Date.UTC(+y!, +mo! - 1, +d!, +h, +mi!, +(s ?? 0));
  // TZID 付きは Asia/Tokyo のみ厳密対応（それ以外は端末ローカルとして扱う）
  if (/TZID=Asia\/Tokyo/i.test(params)) return Date.UTC(+y!, +mo! - 1, +d!, +h - 9, +mi!, +(s ?? 0));
  return fromWall(+y!, +mo! - 1, +d!, +h, +mi!, +(s ?? 0));
}

const unescapeIcs = (s: string) => s.replace(/\\n/gi, '\n').replace(/\\([,;\\])/g, '$1');

/** iCalendar（.ics）の VEVENT を読み取る。繰り返し規則は取り込まない（各回は別途） */
export function parseICS(text: string, owner: 'me' | 'partner' = 'me'): ImportCandidate[] {
  const lines = unfold(text);
  const calName = lines.find((l) => l.startsWith('X-WR-CALNAME:'))?.slice(13).trim() ?? null;
  const out: ImportCandidate[] = [];
  let cur: Record<string, { v: string; p: string }> | null = null;
  for (const line of lines) {
    if (line === 'BEGIN:VEVENT') cur = {};
    else if (line === 'END:VEVENT' && cur) {
      const start = cur.DTSTART ? parseIcsDate(cur.DTSTART.v, cur.DTSTART.p) : null;
      let end = cur.DTEND ? parseIcsDate(cur.DTEND.v, cur.DTEND.p) : null;
      if (start != null) {
        if (end == null || end <= start) end = start + 3_600_000;
        const title = unescapeIcs(cur.SUMMARY?.v ?? '(無題)').trim() || '(無題)';
        out.push({ externalId: cur.UID?.v ?? null, title, start, end, owner, calendarName: calName, fingerprint: fingerprint(title, start, end) });
      }
      cur = null;
    } else if (cur) {
      const idx = line.indexOf(':');
      if (idx < 0) continue;
      const head = line.slice(0, idx);
      const [name, ...params] = head.split(';');
      cur[name!.toUpperCase()] = { v: line.slice(idx + 1), p: params.join(';') };
    }
  }
  return out;
}

/**
 * テキスト貼り付けの取り込み。1行1件：
 *   2026/10/12 13:00-14:00 打ち合わせ
 *   10/12 13:00〜14:30 ゼミ @相手
 * 「@相手」「(相手)」「［相手］」で相手の予定として扱う。年がなければ基準日の年。
 */
export function parseText(text: string, ref: EpochMs, calendarName: string | null = null): { items: ImportCandidate[]; errors: { line: number; text: string }[] } {
  const items: ImportCandidate[] = [];
  const errors: { line: number; text: string }[] = [];
  const year0 = wall(ref).y;
  text.split(/\r?\n/).forEach((raw, i) => {
    const line = raw.normalize('NFKC').trim();
    if (!line) return;
    const m = /^(?:(\d{4})[/-])?(\d{1,2})[/-](\d{1,2})(?:\([^)]*\))?\s+(\d{1,2}):(\d{2})\s*[-~〜～]\s*(\d{1,2}):(\d{2})\s+(.+)$/.exec(line);
    if (!m) {
      errors.push({ line: i + 1, text: raw });
      return;
    }
    const [, y, mo, d, h1, m1, h2, m2, rest] = m;
    const year = y ? +y : year0;
    const start = fromWall(year, +mo! - 1, +d!, +h1!, +m1!);
    let end = fromWall(year, +mo! - 1, +d!, +h2!, +m2!);
    if (end <= start) end += 86_400_000; // 日付またぎ（例 22:00-6:00）
    const partner = /(@相手|\(相手\)|\[相手\]|【相手】)/.test(rest!);
    const title = rest!.replace(/(@相手|\(相手\)|\[相手\]|【相手】|@自分|\(自分\))/g, '').trim();
    if (!title) {
      errors.push({ line: i + 1, text: raw });
      return;
    }
    items.push({ externalId: null, title, start, end, owner: partner ? 'partner' : 'me', calendarName, fingerprint: fingerprint(title, start, end) });
  });
  return { items, errors };
}

export type ImportClass =
  /** 以前に取り込んだ同じ予定（外部ID or 内容一致）。取り込み元を優先して更新できる */
  | { kind: 'same'; existing: CalEvent; changed: boolean }
  /** 別の予定と時間が重なる（上書きしない。警告のみ） */
  | { kind: 'overlap'; with: CalEvent[] }
  | { kind: 'new' };

export function classifyImport(c: ImportCandidate, events: readonly CalEvent[]): ImportClass {
  const same = events.find((e) => e.source && ((c.externalId && e.source.externalId === c.externalId) || e.source.fingerprint === c.fingerprint));
  if (same) return { kind: 'same', existing: same, changed: same.title !== c.title || same.start !== c.start || same.end !== c.end };
  const ov = events.filter((e) => overlaps(e, c));
  return ov.length ? { kind: 'overlap', with: ov } : { kind: 'new' };
}

// ---------------- 書き出し（P15：ICS） ----------------
const icsEscape = (s: string) => s.replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\r?\n/g, '\\n');
const icsUtc = (t: number) => new Date(t).toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
const icsDay = (t: number) => { const d = new Date(t); return `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, '0')}${String(d.getDate()).padStart(2, '0')}`; };
/** 75 オクテットごとに折り返す（RFC 5545） */
function fold(line: string): string {
  const enc = new TextEncoder();
  const out: string[] = [];
  let cur = '';
  for (const ch of line) {
    if (enc.encode(cur + ch).length > 73) { out.push(cur); cur = ` ${ch}`; } else cur += ch;
  }
  out.push(cur);
  return out.join('\r\n');
}

/**
 * 予定を iCalendar（.ics）に書き出す。繰り返しは RRULE、取り消した回は EXDATE、その回だけの変更は RECURRENCE-ID 付きの別 VEVENT。
 * 時刻は UTC で出力し、元のタイムゾーンは X-MYTIME-TZ に残す。
 */
export function toICS(events: readonly CalEventT[], calName = 'My Time', stamp = Date.now()): string {
  const L: string[] = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//My Time//JA', 'CALSCALE:GREGORIAN', `X-WR-CALNAME:${icsEscape(calName)}`];
  const freq = { daily: 'DAILY', weekly: 'WEEKLY', monthly: 'MONTHLY' } as const;
  for (const e of events) {
    const allDay = !!e.extra?.allDay;
    const dt = (k: string, t: number) => (allDay ? `${k};VALUE=DATE:${icsDay(t)}` : `${k}:${icsUtc(t)}`);
    const base = [`UID:${e.id}@mytime`, `DTSTAMP:${icsUtc(stamp)}`, dt('DTSTART', e.start), dt('DTEND', e.end), `SUMMARY:${icsEscape(e.title)}`, ...(e.notes ? [`DESCRIPTION:${icsEscape(e.notes)}`] : []), ...(e.extra?.place?.name ? [`LOCATION:${icsEscape(e.extra.place.name)}`] : []), `X-MYTIME-TZ:${e.timeZone}`];
    L.push('BEGIN:VEVENT', ...base);
    if (e.recurrence) {
      const r = e.recurrence;
      const by = r.freq === 'weekly' && r.byWeekday?.length ? `;BYDAY=${r.byWeekday.map((d) => ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA'][d]).join(',')}` : '';
      L.push(`RRULE:FREQ=${freq[r.freq]};INTERVAL=${r.interval}${by}${r.until != null ? `;UNTIL=${icsUtc(r.until)}` : ''}`);
      for (const x of e.exceptions) if (x.kind === 'cancelled' || x.kind === 'archived') L.push(allDay ? `EXDATE;VALUE=DATE:${icsDay(x.originalStart)}` : `EXDATE:${icsUtc(x.originalStart)}`);
    }
    L.push('END:VEVENT');
    for (const x of e.exceptions) {
      if (x.kind !== 'override') continue;
      L.push('BEGIN:VEVENT', `UID:${e.id}@mytime`, `DTSTAMP:${icsUtc(stamp)}`, `RECURRENCE-ID:${icsUtc(x.originalStart)}`, dt('DTSTART', x.start ?? x.originalStart), dt('DTEND', x.end ?? x.originalStart + (e.end - e.start)), `SUMMARY:${icsEscape(x.title ?? e.title)}`, 'END:VEVENT');
    }
  }
  L.push('END:VCALENDAR');
  return L.map(fold).join('\r\n') + '\r\n';
}
