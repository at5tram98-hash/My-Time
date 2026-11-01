import type { Calendar, CalEvent, Employer, EpochMs, Subject, Subtask, Task } from './types';
import { DEFAULT_TASK_ICON, defaultCalendarIcon } from './icons';

export function newId(): string {
  const c = (globalThis as { crypto?: { randomUUID?: () => string } }).crypto;
  if (c?.randomUUID) return c.randomUUID();
  return `id-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

export function deviceTimeZone(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || 'Asia/Tokyo';
  } catch {
    return 'Asia/Tokyo';
  }
}

export function makeTask(fields: Partial<Task> & Pick<Task, 'title'>, now: EpochMs): Task {
  return {
    id: newId(),
    kind: 'do',
    special: 'normal',
    assignment: null,
    testPrep: null,
    sourceEventId: null,
    sourceKey: null,
    estimateMinutes: null,
    priority: 0,
    tags: [],
    flagged: false,
    notifyMinutesBefore: null,
    location: null,
    repeat: null,
    autoStartAt: null,
    autoEndAt: null,
    icon: DEFAULT_TASK_ICON,
    calendarId: null,
    category: null,
    eventId: null,
    plannedStart: null,
    plannedEnd: null,
    timeZone: deviceTimeZone(),
    status: 'notStarted',
    intervals: [],
    actualStart: null,
    actualEnd: null,
    manualProgress: null,
    pausedEver: false,
    autoReserved: false,
    checkAt: null,
    checked: false,
    checkedAt: null,
    notes: '',
    createdAt: now,
    updatedAt: now,
    ...fields,
  };
}

export function makeEvent(fields: Partial<CalEvent> & Pick<CalEvent, 'title' | 'calendarId' | 'start' | 'end'>, now: EpochMs): CalEvent {
  return {
    id: newId(),
    timeZone: deviceTimeZone(),
    notes: '',
    recurrence: null,
    exceptions: [],
    classInfo: null,
    employerId: null,
    hideAfterEnd: false,
    source: null,
    createdAt: now,
    updatedAt: now,
    ...fields,
  };
}

export function makeSubject(name: string, now: EpochMs): Subject {
  return { id: newId(), name, createdAt: now, updatedAt: now };
}

export function makeEmployer(name: string, now: EpochMs, reminderHours = 2): Employer {
  return { id: newId(), name, reminderHours, createdAt: now, updatedAt: now };
}

/** 旧スキーマ（Phase 1）のレコードに新しい項目の既定値を補う。既存の値は上書きしない。 */
export function normalizeTask(raw: Partial<Task> & Pick<Task, 'id' | 'title' | 'createdAt'>): Task {
  return makeTask({ ...raw }, raw.createdAt);
}
export function normalizeEvent(raw: Partial<CalEvent> & Pick<CalEvent, 'id' | 'title' | 'calendarId' | 'start' | 'end' | 'createdAt'>): CalEvent {
  return makeEvent({ ...raw }, raw.createdAt);
}
export function normalizeCalendar(raw: Partial<Calendar> & Pick<Calendar, 'id' | 'name' | 'kind' | 'createdAt'>): Calendar {
  const icon = defaultCalendarIcon(raw.kind);
  return { color: '#0A84FF', visible: true, order: 0, updatedAt: raw.createdAt, icon, ...raw } as Calendar;
}

export function makeSubtask(taskId: string, title: string, order: number, now: EpochMs): Subtask {
  return { id: newId(), taskId, title, done: false, completedAt: null, order, createdAt: now, updatedAt: now };
}

/** 初回起動時に作る既定カレンダー（ユーザーデータではなく器のみ。既存があれば作らない）。 */
export function defaultCalendars(now: EpochMs): Calendar[] {
  return [
    { id: 'cal-general', name: '一般', color: '#0A84FF', icon: 'calendar', kind: 'general', visible: true, order: 0, createdAt: now, updatedAt: now },
    { id: 'cal-class', name: '授業', color: '#5E5CE6', icon: 'graduation', kind: 'class', visible: true, order: 1, createdAt: now, updatedAt: now },
    { id: 'cal-job', name: 'アルバイト', color: '#FF9F0A', icon: 'briefcase', kind: 'job', visible: true, order: 2, createdAt: now, updatedAt: now },
  ];
}
