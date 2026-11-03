import { render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { applyTaskAction, HOUR, makeTask, startOfDay } from '@my-time/domain';
import { UIProvider } from '../../app/ui';
import { FloatingCards } from './FloatingCards';

vi.mock('../../app/data', () => ({ useData: () => ({ studioTypes: [] }) }));

const day = startOfDay(new Date(2026, 9, 12).getTime());

describe('FloatingCards（コンパクト表示の円・C01）', () => {
  it('実行中・次のタスクがなくても空状態のカプセルを描く', () => {
    const { container } = render(<UIProvider><FloatingCards tasks={[]} subtasksByTask={new Map()} now={day + 10 * HOUR} /></UIProvider>);
    expect(container.querySelector('[data-testid="floating-cards"]')?.textContent).toContain('次のタスクはありません');
  });
  it('円の読み上げ名に状態と、実績未入力なら理想、入力後は実績を含める', () => {
    const t = applyTaskAction(makeTask({ title: '実行中', plannedStart: day + 10 * HOUR, plannedEnd: day + 12 * HOUR }, day), 'start', day + 10 * HOUR).task;
    const { rerender } = render(<UIProvider><FloatingCards tasks={[t]} subtasksByTask={new Map()} now={day + 11 * HOUR} /></UIProvider>);
    const label = () => screen.getByTestId('fcard-running').getAttribute('aria-label') ?? '';
    expect(label()).toContain('実行中');
    expect(label()).toContain('理想50%');
    const withActual = { ...t, manualProgress: { value: 0.8, at: day + 11 * HOUR, workedMsAtSample: HOUR } };
    rerender(<UIProvider><FloatingCards tasks={[withActual]} subtasksByTask={new Map()} now={day + 11 * HOUR} /></UIProvider>);
    expect(label()).toContain('実績80%');
  });
});
