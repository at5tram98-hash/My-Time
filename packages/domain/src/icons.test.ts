import { describe, expect, it } from 'vitest';
import { CALENDAR_ICON_CHOICES, defaultCalendars, ITEM_ICONS, LEGACY_EMOJI_ICONS, makeTask, normalizeCalendar, resolveItemIcon, TASK_ICON_CHOICES } from './index';

describe('アイコン ID と旧形式（絵文字）の互換', () => {
  it('旧バージョンのピッカーにあった絵文字はすべて意味の合う ID へ読み替える', () => {
    const oldTask = ['📘', '✏️', '💻', '📝', '📚', '🧪', '🎯', '💼', '🏃', '🧹', '🛒', '🍳', '🎧', '💬', '💡', '⭐️'];
    const oldCalendar = ['📅', '🎓', '💼', '🏠', '❤️', '🏃', '🎵', '✈️', '🍽️', '📚', '💡', '⭐️'];
    expect(oldTask.map((e) => resolveItemIcon(e).id)).toEqual([...TASK_ICON_CHOICES]);
    expect(oldCalendar.map((e) => resolveItemIcon(e).id)).toEqual([...CALENDAR_ICON_CHOICES]);
    for (const e of [...oldTask, ...oldCalendar]) expect(resolveItemIcon(e).legacy).toBe(true);
  });
  it('未知の値・空・null は既定のアイコンで表示する（値は呼び出し側に残る）', () => {
    expect(resolveItemIcon('🦄')).toEqual({ id: 'circle', current: false, legacy: false });
    expect(resolveItemIcon('')).toMatchObject({ id: 'circle' });
    expect(resolveItemIcon(null, 'calendar')).toMatchObject({ id: 'calendar' });
    expect(resolveItemIcon('toString')).toMatchObject({ id: 'circle' }); // プロトタイプの名前を ID とみなさない
  });
  it('対応表の行き先はすべて定義済みの ID、ID は保存欄の上限（16文字）以内', () => {
    for (const id of Object.values(LEGACY_EMOJI_ICONS)) expect(ITEM_ICONS[id]).toBeTruthy();
    for (const id of Object.keys(ITEM_ICONS)) expect(id.length).toBeLessThanOrEqual(16);
  });
  it('新規作成の既定値は ID。既存の値（旧絵文字）は正規化しても書き換えない', () => {
    expect(makeTask({ title: 'x' }, 0).icon).toBe('book');
    expect(defaultCalendars(0).map((c) => c.icon)).toEqual(['calendar', 'graduation', 'briefcase']);
    expect(normalizeCalendar({ id: 'c', name: '授業', kind: 'class', createdAt: 0 }).icon).toBe('graduation');
    expect(normalizeCalendar({ id: 'c', name: '旧', kind: 'general', createdAt: 0, icon: '🎵' }).icon).toBe('🎵');
    expect(makeTask({ title: 'x', icon: '🧪' }, 0).icon).toBe('🧪');
  });
});
