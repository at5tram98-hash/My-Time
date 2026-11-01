import type { CalEvent, EpochMs, Task } from './types';
import { makeTask } from './factories';

/** 授業の課題・小テストから作るタスクの安定キー */
export const assignmentKey = (eventId: string, key: string) => `class:${eventId}:assignment:${key}`;
export const quizKey = (eventId: string, key: string) => `class:${eventId}:quiz:${key}`;

export interface ClassTaskPlan {
  /** 新しく作るタスク（ユーザーの確認後に保存） */
  create: Task[];
  /** 元の授業側の内容が変わったため更新するタスク（ユーザーが編集した項目は保持） */
  update: Task[];
}

/**
 * 授業予定の課題・小テストに対応する独立タスクを計画する。
 * - 予定に「内包」させず、sourceEventId / sourceKey で関連付ける（サブタスクと矛盾しない）。
 * - 同じキーのタスクがあれば新規作成しない（編集・再保存・同期の再試行で重複しない）。
 * - 授業から課題を消しても、作成済みのタスクは自動では削除しない。
 */
export function planClassTasks(ev: CalEvent, existing: readonly Task[], now: EpochMs): ClassTaskPlan {
  const info = ev.classInfo;
  if (!info) return { create: [], update: [] };
  const byKey = new Map(existing.filter((t) => t.sourceKey).map((t) => [t.sourceKey!, t]));
  const create: Task[] = [];
  const update: Task[] = [];
  const subject = info.subjectName;
  for (const a of info.assignments) {
    const key = assignmentKey(ev.id, a.key);
    const title = a.title || `${subject}の課題`;
    const found = byKey.get(key);
    if (!found) {
      create.push(
        makeTask(
          {
            title,
            icon: 'note',
            special: 'assignment',
            assignment: { content: a.content, submitMethod: a.submitMethod, submitTo: a.submitTo, deadline: a.deadline },
            sourceEventId: ev.id,
            sourceKey: key,
            category: '課題',
            calendarId: ev.calendarId,
          },
          now,
        ),
      );
    } else if (found.assignment && (found.assignment.deadline !== a.deadline || found.assignment.content !== a.content || found.assignment.submitTo !== a.submitTo || found.assignment.submitMethod !== a.submitMethod)) {
      update.push({ ...found, assignment: { content: a.content, submitMethod: a.submitMethod, submitTo: a.submitTo, deadline: a.deadline }, updatedAt: now });
    }
  }
  for (const q of info.quizzes) {
    const key = quizKey(ev.id, q.key);
    const found = byKey.get(key);
    if (!found) {
      create.push(
        makeTask(
          {
            title: q.title || `${subject} テスト対策`,
            icon: 'target',
            special: 'testPrep',
            testPrep: { examAt: q.at, subjectId: info.subjectId, subjectName: subject },
            sourceEventId: ev.id,
            sourceKey: key,
            category: 'テスト対策',
            calendarId: ev.calendarId,
          },
          now,
        ),
      );
    } else if (found.testPrep && found.testPrep.examAt !== q.at) {
      update.push({ ...found, testPrep: { ...found.testPrep, examAt: q.at }, updatedAt: now });
    }
  }
  return { create, update };
}

/** サブタスク一覧の見出し（テスト対策は「詳細なテスト対策」） */
export function subtaskLabel(task: Pick<Task, 'special'>): string {
  return task.special === 'testPrep' ? '詳細なテスト対策' : 'サブタスク';
}

/** 「未設定」：日時が未入力、または課題・テスト対策で作業時間が未入力 */
export function needsSetup(task: Task): boolean {
  if (task.kind === 'check') return task.checkAt == null;
  if (task.plannedStart == null) return true;
  return (task.special === 'assignment' || task.special === 'testPrep') && task.estimateMinutes == null && task.plannedEnd == null;
}
