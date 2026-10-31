import { useMemo, useState } from 'react';
import { needsSetup, taskAnchor, type Task, type TaskKind } from '@my-time/domain';
import { useData } from '../../app/data';
import { useUI } from '../../app/ui';
import { useNow } from '../../app/useNow';
import { Segmented } from '../../components/Controls';
import { Icon } from '../../components/Icon';
import { MenuButton } from '../../components/Menu';
import { TaskRow } from './TaskRow';

export function TasksScreen() {
  const { tasks, subtasksByTask } = useData();
  const { openSheet } = useUI();
  const now = useNow();
  const [kind, setKind] = useState<TaskKind>('do');
  const [q, setQ] = useState('');
  const [showDone, setShowDone] = useState(false);

  const sections = useMemo(() => {
    const k = q.trim().toLowerCase();
    const list = tasks
      .filter((t) => t.kind === kind)
      .filter((t) => showDone || t.status !== 'done')
      .filter((t) => !k || t.title.toLowerCase().includes(k) || (t.category ?? '').toLowerCase().includes(k) || t.notes.toLowerCase().includes(k));
    const unscheduled = list.filter(needsSetup).sort((a, b) => b.createdAt - a.createdAt);
    const groups = new Map<string, Task[]>();
    for (const t of list.filter((x) => !needsSetup(x))) {
      const key = t.category ?? 'カテゴリなし';
      groups.set(key, [...(groups.get(key) ?? []), t]);
    }
    const sorted = [...groups.entries()]
      .sort(([a], [b]) => (a === 'カテゴリなし' ? 1 : b === 'カテゴリなし' ? -1 : a.localeCompare(b, 'ja')))
      .map(([name, ts]) => ({ name, tasks: ts.sort((a, b) => (taskAnchor(a) ?? 0) - (taskAnchor(b) ?? 0)) }));
    return { unscheduled, groups: sorted, total: list.length };
  }, [tasks, kind, q, showDone]);

  return (
    <div className="screen tasks" data-testid="tasks-screen">
      <header className="nav large">
        <div className="nav-row">
          <h1 className="large-title">タスク</h1>
          <div className="nav-actions">
            <MenuButton label="その他の操作" items={[
              { label: '新規タスク', icon: 'plus', onSelect: () => openSheet({ kind: 'editTask', defaults: { kind } }) },
              { label: '日時未設定で追加', icon: 'tray', onSelect: () => openSheet({ kind: 'editTask', defaults: { kind, plannedStart: null } }) },
              'separator',
              { label: '完了済みを表示', checked: showDone, onSelect: () => setShowDone((v) => !v) },
            ]}>
              <Icon name="more" strokeWidth={3} />
            </MenuButton>
          </div>
        </div>
        <div className="search-field">
          <Icon name="search" size={17} />
          <input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="検索" aria-label="タスクを検索" />
        </div>
        <Segmented label="タスクの種類" value={kind} onChange={setKind} options={[{ value: 'do', label: '実施' }, { value: 'check', label: '確認' }]} />
      </header>
      <div className="scroll-body">
        {sections.unscheduled.length > 0 && (
          <section className="task-section" data-testid="section-unscheduled">
            <h2 className="section-title">未設定</h2>
            <div className="rows card">
              {sections.unscheduled.map((t) => <TaskRow key={t.id} task={t} subtasks={subtasksByTask.get(t.id) ?? []} now={now} />)}
            </div>
          </section>
        )}
        {sections.groups.map((g) => (
          <section className="task-section" key={g.name}>
            <h2 className="section-title">{g.name}</h2>
            <div className="rows card">
              {g.tasks.map((t) => <TaskRow key={t.id} task={t} subtasks={subtasksByTask.get(t.id) ?? []} now={now} showDate />)}
            </div>
          </section>
        ))}
        {sections.total === 0 && (
          <div className="empty-list tall">
            <p>{q ? '一致するタスクはありません' : kind === 'do' ? '実施タスクはありません' : '確認タスクはありません'}</p>
            <button type="button" className="link-btn" onClick={() => openSheet({ kind: 'editTask', defaults: { kind } })}>新規タスク</button>
          </div>
        )}
      </div>
    </div>
  );
}
