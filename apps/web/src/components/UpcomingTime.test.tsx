import { act, render, screen, cleanup } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { UpcomingTime } from './UpcomingTime';

vi.mock('motion/react', () => ({ useReducedMotion: () => false, AnimatePresence: ({ children }: { children: React.ReactNode }) => children, motion: { span: ({ children }: { children: React.ReactNode }) => <span>{children}</span> } }));
afterEach(() => { cleanup(); vi.useRealTimers(); });
it('60分前から時刻と残り分数を繰り返し表示し、開始時刻を過ぎると停止する', () => {
  vi.useFakeTimers();
  const view = render(<UpcomingTime at={3600000} now={0} text="12:00" />);
  expect(screen.getByTestId('upcoming-time')).toHaveTextContent('12:00');
  act(() => vi.advanceTimersByTime(4000));
  expect(screen.getByTestId('upcoming-time')).toHaveTextContent('あと60分');
  act(() => vi.advanceTimersByTime(4000));
  expect(screen.getByTestId('upcoming-time')).toHaveTextContent('12:00');
  view.rerender(<UpcomingTime at={3600000} now={3600000} text="12:00" />);
  act(() => vi.advanceTimersByTime(4000));
  expect(screen.getByTestId('upcoming-time')).not.toHaveTextContent('あと');
});
