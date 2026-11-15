import { AnimatePresence } from 'motion/react';
import { useUI } from './ui';
import { TaskDetailSheet } from '../features/tasks/TaskDetailSheet';
import { TaskEditorSheet } from '../features/tasks/TaskEditorSheet';
import { EventEditorSheet } from '../features/calendar/EventEditorSheet';
import { SearchSheet } from '../features/search/SearchSheet';
import { CopyEventSheet } from '../features/calendar/CopyEventSheet';
import { AutoReserveSheet } from '../features/tasks/AutoReserveSheet';
import { ImportSheet } from '../features/other/ImportSheet';
import { EditorSheet } from '../features/editor/EditorSheet';
import { AnalysisDetailSheet } from '../features/analysis/AnalysisDetailSheet';
import { CalendarFilterSheet, EventInfoSheet, SyncStatusSheet } from '../features/editor/InfoSheets';
import { DayTasksSheet, InboxSheet, IssuesSheet, RescheduleSheet, ReviewSheet } from '../features/plan/PlanSheets';
import { QuickAddSheet } from '../features/quickadd/QuickAddSheet';

export function SheetHost() {
  const { sheets } = useUI();
  return (
    <AnimatePresence>
      {sheets.map((s, i) => {
        // 同じ位置・同じ種類でも開くたびに別の key（閉じかけの前のシートの入力状態を引き継がない）
        const key = `${s.kind}-${s.uid}`;
        switch (s.kind) {
          case 'task':
            return <TaskDetailSheet key={key} id={s.id} depth={i} />;
          case 'editTask':
            return <TaskEditorSheet key={key} depth={i} {...(s.taskId ? { taskId: s.taskId } : {})} {...(s.defaults ? { defaults: s.defaults } : {})} />;
          case 'editEvent':
            return <EventEditorSheet key={key} depth={i} {...(s.eventId ? { eventId: s.eventId } : {})} {...(s.defaults ? { defaults: s.defaults } : {})} />;
          case 'search':
            return <SearchSheet key={key} depth={i} />;
          case 'copyEvent':
            return <CopyEventSheet key={key} depth={i} eventId={s.eventId} />;
          case 'autoReserve':
            return <AutoReserveSheet key={key} depth={i} taskId={s.taskId} />;
          case 'import':
            return <ImportSheet key={key} depth={i} />;
          case 'info':
            return s.entity === 'event' ? <EventInfoSheet key={key} id={s.id} depth={i} /> : <TaskDetailSheet key={key} id={s.id} depth={i} />;
          case 'run':
            return <TaskDetailSheet key={key} id={s.id} depth={i} openProgress={s.progress} />;
          case 'edit':
            return <EditorSheet key={key} depth={i} mode={s.mode} {...(s.id ? { id: s.id } : {})} {...(s.defaults ? { defaults: s.defaults } : {})} />;
          case 'calendarFilter':
            return <CalendarFilterSheet key={key} depth={i} />;
          case 'syncStatus':
            return <SyncStatusSheet key={key} depth={i} />;
          case 'analysisDetail':
            return <AnalysisDetailSheet key={key} depth={i} metric={s.metric} period={s.period} from={s.from} />;
          case 'quickAdd':
            return <QuickAddSheet key={key} depth={i} {...(s.text ? { text: s.text } : {})} {...(s.at ? { at: s.at } : {})} />;
          case 'issues':
            return <IssuesSheet key={key} depth={i} day={s.day} />;
          case 'inbox':
            return <InboxSheet key={key} depth={i} />;
          case 'dayTasks':
            return <DayTasksSheet key={key} depth={i} day={s.day} />;
          case 'review':
            return <ReviewSheet key={key} depth={i} day={s.day} />;
          case 'reschedule':
            return <RescheduleSheet key={key} depth={i} taskId={s.taskId} mode={s.mode} />;
        }
      })}
    </AnimatePresence>
  );
}
