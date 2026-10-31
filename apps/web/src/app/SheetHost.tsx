import { AnimatePresence } from 'motion/react';
import { useUI } from './ui';
import { TaskDetailSheet } from '../features/tasks/TaskDetailSheet';
import { TaskEditorSheet } from '../features/tasks/TaskEditorSheet';
import { EventEditorSheet } from '../features/calendar/EventEditorSheet';
import { SearchSheet } from '../features/search/SearchSheet';

export function SheetHost() {
  const { sheets } = useUI();
  return (
    <AnimatePresence>
      {sheets.map((s, i) => {
        const key = `${i}-${s.kind}`;
        switch (s.kind) {
          case 'task':
            return <TaskDetailSheet key={key} id={s.id} depth={i} />;
          case 'editTask':
            return <TaskEditorSheet key={key} depth={i} {...(s.taskId ? { taskId: s.taskId } : {})} {...(s.defaults ? { defaults: s.defaults } : {})} />;
          case 'editEvent':
            return <EventEditorSheet key={key} depth={i} {...(s.eventId ? { eventId: s.eventId } : {})} {...(s.defaults ? { defaults: s.defaults } : {})} />;
          case 'search':
            return <SearchSheet key={key} depth={i} />;
        }
      })}
    </AnimatePresence>
  );
}
