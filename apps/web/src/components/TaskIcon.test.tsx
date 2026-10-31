import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import { HOUR, makeTask, startOfDay } from '@my-time/domain';
import { TaskIcon } from './TaskIcon';

const day = startOfDay(new Date(2026, 9, 12).getTime());

describe('TaskIcon', () => {
  it('予定終了を過ぎた未完了タスクはアイコンを「!」に置き換える', () => {
    const t = makeTask({ title: 'x', icon: '📘', plannedStart: day + 9 * HOUR, plannedEnd: day + 10 * HOUR }, day);
    render(<TaskIcon task={t} now={day + 11 * HOUR} />);
    expect(screen.getByLabelText('遅延')).toHaveTextContent('!');
    expect(screen.queryByText('📘')).toBeNull();
  });
  it('理想進捗をリングの値として持つ', () => {
    const t = makeTask({ title: 'x', icon: '📘', plannedStart: day + 9 * HOUR, plannedEnd: day + 11 * HOUR }, day);
    const { container } = render(<TaskIcon task={t} now={day + 10 * HOUR} />);
    expect(container.querySelector('.task-icon')).toHaveAttribute('data-ideal', '50');
    expect(screen.getByText('📘')).toBeInTheDocument();
  });
});
