import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import { applyTaskAction, HOUR, makeTask, startOfDay } from '@my-time/domain';
import { UIProvider } from '../../app/ui';
import { FloatingCards } from './FloatingCards';

const day = startOfDay(new Date(2026, 9, 12).getTime());

describe('FloatingCards（拡張時の浮遊カード）', () => {
  it('実行中・次のタスクがなければカードを1枚も出さない', () => {
    const { container } = render(<UIProvider><FloatingCards tasks={[]} subtasksByTask={new Map()} now={day + 10 * HOUR} /></UIProvider>);
    expect(container.querySelectorAll('.fcard')).toHaveLength(0);
  });
  it('実行中は理想進捗、実績入力があれば実績で充填する', () => {
    const t = applyTaskAction(makeTask({ title: '実行中', plannedStart: day + 10 * HOUR, plannedEnd: day + 12 * HOUR }, day), 'start', day + 10 * HOUR).task;
    const { rerender } = render(<UIProvider><FloatingCards tasks={[t]} subtasksByTask={new Map()} now={day + 11 * HOUR} /></UIProvider>);
    expect(screen.getByTestId('fcard-running')).toHaveTextContent('50%');
    const withActual = { ...t, manualProgress: { value: 0.8, at: day + 11 * HOUR, workedMsAtSample: HOUR } };
    rerender(<UIProvider><FloatingCards tasks={[withActual]} subtasksByTask={new Map()} now={day + 11 * HOUR} /></UIProvider>);
    expect(screen.getByTestId('fcard-running')).toHaveTextContent('80%');
  });
});
