import type { Calendar, CalEvent, EpochMs, Subtask, Task } from './types';

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
    icon: '📘',
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
  return { id: newId(), timeZone: deviceTimeZone(), notes: '', createdAt: now, updatedAt: now, ...fields };
}

export function makeSubtask(taskId: string, title: string, order: number, now: EpochMs): Subtask {
  return { id: newId(), taskId, title, done: false, completedAt: null, order, createdAt: now, updatedAt: now };
}

/** 初回起動時に作る既定カレンダー（ユーザーデータではなく器のみ。既存があれば作らない）。 */
export function defaultCalendars(now: EpochMs): Calendar[] {
  return [
    { id: 'cal-general', name: '一般', color: '#0A84FF', kind: 'general', visible: true, order: 0, createdAt: now, updatedAt: now },
    { id: 'cal-class', name: '授業', color: '#5E5CE6', kind: 'class', visible: true, order: 1, createdAt: now, updatedAt: now },
    { id: 'cal-job', name: 'アルバイト', color: '#FF9F0A', kind: 'job', visible: true, order: 2, createdAt: now, updatedAt: now },
  ];
}
