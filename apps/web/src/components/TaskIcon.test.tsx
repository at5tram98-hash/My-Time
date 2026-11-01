import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import { HOUR, makeTask, startOfDay } from '@my-time/domain';
import { TaskIcon } from './TaskIcon';
import { ItemIcon } from './ItemIcon';

const day = startOfDay(new Date(2026, 9, 12).getTime());
const EMOJI = /\p{Extended_Pictographic}/u;

describe('TaskIcon', () => {
  it('予定終了を過ぎた未完了タスクはアイコンを注意の記号（SVG）に置き換える', () => {
    const t = makeTask({ title: 'x', icon: '📘', plannedStart: day + 9 * HOUR, plannedEnd: day + 10 * HOUR }, day);
    const { container } = render(<TaskIcon task={t} now={day + 11 * HOUR} />);
    expect(screen.getByLabelText('遅延').querySelector('svg')).not.toBeNull();
    expect(container.textContent).toBe('');
  });
  it('理想進捗をリングの値として持ち、旧形式の絵文字値は SVG で表示する', () => {
    const t = makeTask({ title: 'x', icon: '📘', plannedStart: day + 9 * HOUR, plannedEnd: day + 11 * HOUR }, day);
    const { container } = render(<TaskIcon task={t} now={day + 10 * HOUR} />);
    expect(container.querySelector('.task-icon')).toHaveAttribute('data-ideal', '50');
    expect(container.querySelector('[data-icon]')).toHaveAttribute('data-icon', 'book');
    expect(container.querySelector('[data-icon]')).toHaveAttribute('data-icon-source', 'legacy');
    expect(EMOJI.test(container.textContent ?? '')).toBe(false);
  });
});

describe('ItemIcon', () => {
  it('新しい ID・旧絵文字（異体字セレクタ付き含む）・未知値をすべて SVG で表示し、文字は出さない', () => {
    for (const [value, id, source] of [
      ['star', 'star', 'id'],
      ['⭐️', 'star', 'legacy'],
      ['✏', 'pencil', 'legacy'],
      ['🦄', 'circle', 'fallback'],
      ['', 'circle', 'fallback'],
    ] as const) {
      const { container, unmount } = render(<ItemIcon value={value} />);
      const el = container.querySelector('[data-icon]')!;
      expect(el.getAttribute('data-icon')).toBe(id);
      expect(el.getAttribute('data-icon-source')).toBe(source);
      expect(el.querySelector('svg path')).not.toBeNull();
      expect(container.textContent).toBe('');
      unmount();
    }
  });
});
