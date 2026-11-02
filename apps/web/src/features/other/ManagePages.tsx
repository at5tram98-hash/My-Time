import { useState } from 'react';
import type { StudioType } from '@my-time/domain';
import { EventBadge } from '../../components/Identity';
import { ColorStrip, IconStrip } from '../editor/pickers';
import { blankStudioType, StudioDesigner } from '../studio/StudioPage';
import { useDragReorder } from '../../ui/reorder';
import { type Calendar, CALENDAR_ICON_CHOICES, type CalendarKind, defaultCalendarIcon, makeEmployer, makeSubject, newId } from '@my-time/domain';
import { useData } from '../../app/data';
import { useUIActions } from '../../app/ui';
import { Group, Toggle } from '../../components/Controls';
import { Icon } from '../../components/Icon';
import { repo } from '../../data/repo';

const COLORS = ['#0A84FF', '#5E5CE6', '#BF5AF2', '#FF375F', '#FF453A', '#FF9F0A', '#FFD60A', '#30D158', '#64D2FF', '#8E8E93'];
const KIND_LABEL: Record<CalendarKind, string> = { general: '一般', class: '授業', job: 'アルバイト' };

function useErrorToast() {
  const { showToast } = useUIActions();
  return (e: unknown) => showToast(e instanceof Error ? e.message : '保存できませんでした');
}

/**
 * カレンダーの管理（C32・C33）。並び順は右端のハンドルをドラッグ（矢印ボタンは使わない）。
 * 追加・編集では名前・アイコン・色・種類を設定。種類は一般／授業／アルバイトと、保存済みの「カレンダー用」Studio 種類。
 * 専用の種類がなければ、その場で Create Studio を開き、保存後は作成途中のカレンダーへ戻って選択済みにする。
 */
export function CalendarsPage() {
  const { calendars, studioTypes, events, settings } = useData();
  const { confirm, showToast } = useUIActions();
  const fail = useErrorToast();
  const [editing, setEditing] = useState<Calendar | null>(null);
  const [isNew, setIsNew] = useState(false);
  const [designing, setDesigning] = useState<StudioType | null>(null);
  const ids = calendars.map((c) => c.id);
  const dr = useDragReorder(ids, (next) => void repo.reorderCalendars(next));
  const calTypes = studioTypes.filter((t) => t.target === 'calendar' && t.status === 'active');

  const startNew = () => {
    const now = Date.now();
    setIsNew(true);
    setEditing({ id: newId(), name: '', color: COLORS[calendars.length % COLORS.length]!, icon: 'calendar', kind: 'general', studioTypeId: null, visible: true, order: calendars.length, createdAt: now, updatedAt: now });
  };

  const save = async () => {
    if (!editing) return;
    if (!editing.name.trim()) return showToast('名前を入力してください');
    try {
      await repo.saveCalendar({ ...editing, name: editing.name.trim() }, isNew);
      setEditing(null);
    } catch (e) {
      fail(e);
    }
  };

  const remove = async (c: Calendar) => {
    if (!(await confirm({ title: `「${c.name}」を削除しますか？`, message: '予定・タスクが入っているカレンダーは削除できません。', confirmLabel: '削除', destructive: true }))) return;
    try {
      await repo.deleteCalendar(c.id);
      setEditing(null);
    } catch (e) {
      fail(e);
    }
  };

  // 専用の種類を作る（作成途中のカレンダーは保持し、保存後に戻って選択済みにする）
  if (designing && editing) {
    return (
      <StudioDesigner
        initial={designing}
        isNew
        usage={0}
        linkCalendar={false}
        onSaved={(t) => { if (t.status === 'active') setEditing((e) => (e ? { ...e, kind: 'general', studioTypeId: t.id, icon: e.name ? e.icon : t.icon, color: e.name ? e.color : t.color, name: e.name || t.name } : e)); }}
        onDone={() => setDesigning(null)}
      />
    );
  }

  if (editing) {
    const typeKey = editing.studioTypeId ? `studio:${editing.studioTypeId}` : editing.kind;
    const used = !isNew && editing.studioTypeId ? events.filter((e) => e.calendarId === editing.id).length : 0;
    return (
      <div data-testid="calendar-editor">
        <div className="cal-ed-head">
          <EventBadge icon={editing.icon} color={editing.color} size={52} fallback={defaultCalendarIcon(editing.kind)} />
          <input className="row-input big" value={editing.name} onChange={(e) => setEditing({ ...editing, name: e.target.value })} placeholder="カレンダー名" aria-label="カレンダー名" autoFocus data-testid="calendar-name" />
        </div>
        <Group header="アイコン"><IconStrip value={editing.icon} onChange={(id) => setEditing({ ...editing, icon: id })} recent={settings.recentIcons} target="event" /></Group>
        <Group header="色"><ColorStrip value={editing.color} onChange={(c) => setEditing({ ...editing, color: c ?? editing.color })} recent={settings.recentColors} /></Group>
        <Group header="種類" footer={`授業：科目・教室・課題・小テストを入力できます。アルバイト：勤務先を選び、勤務前に通知します。専用：Create Studio で作った項目を入力できます。${used ? `このカレンダーの予定${used}件の入力値は、種類を変えても消えません。` : ''}`}>
          {(Object.keys(KIND_LABEL) as CalendarKind[]).map((k) => (
            <button key={k} type="button" className="row row-button" role="radio" aria-checked={typeKey === k} onClick={() => setEditing({ ...editing, kind: k, studioTypeId: null })} data-testid={`cal-kind-${k}`}>
              <EventBadge icon={defaultCalendarIcon(k)} color="var(--gray)" size={28} />
              <span className="row-label">{KIND_LABEL[k]}</span>
              {typeKey === k && <Icon name="check" size={18} className="tint" strokeWidth={2.4} />}
            </button>
          ))}
          {calTypes.map((t) => (
            <button key={t.id} type="button" className="row row-button" role="radio" aria-checked={typeKey === `studio:${t.id}`} onClick={() => setEditing({ ...editing, kind: 'general', studioTypeId: t.id })} data-testid={`cal-kind-studio-${t.id}`}>
              <EventBadge icon={t.icon} color={t.color} size={28} />
              <span className="row-label">{t.name}<span className="sub-label">専用（{t.fields.filter((f) => !f.hidden).length}項目）</span></span>
              {typeKey === `studio:${t.id}` && <Icon name="check" size={18} className="tint" strokeWidth={2.4} />}
            </button>
          ))}
          <button type="button" className="row row-button tint-row" onClick={() => setDesigning(blankStudioType('calendar'))} data-testid="cal-new-studio">
            <Icon name="sparkles" size={18} />
            <span className="row-label">専用の種類を作る</span>
          </button>
        </Group>
        <Group>
          <button type="button" className="row row-button center bold tint" onClick={() => void save()} data-testid="save-calendar">{isNew ? '追加' : '保存'}</button>
          <button type="button" className="row row-button center" onClick={() => setEditing(null)}>キャンセル</button>
          {!isNew && (
            <button type="button" className="row row-button center destructive" onClick={() => void remove(editing)}>カレンダーを削除</button>
          )}
        </Group>
      </div>
    );
  }

  const byId = new Map(calendars.map((c) => [c.id, c]));
  return (
    <>
      <Group footer="名前をタップで編集、スイッチで表示・非表示、右端のハンドルをドラッグして並べ替えます。">
        <div data-reorder-list>
          {dr.order.map((id) => {
            const c = byId.get(id)!;
            const st = c.studioTypeId ? studioTypes.find((t) => t.id === c.studioTypeId) : undefined;
            return (
              <div className={`row cal-row ${dr.active === id ? 'reordering' : ''}`} key={c.id} data-reorder-id={c.id} data-testid={`calendar-row-${c.id}`}>
                <EventBadge icon={c.icon} color={c.color} size={30} fallback={defaultCalendarIcon(c.kind)} />
                <button type="button" className="row-label link-like" onClick={() => { setIsNew(false); setEditing(c); }}>
                  {c.name}
                  <span className="sub-label">{st ? `専用：${st.name}` : KIND_LABEL[c.kind]}</span>
                </button>
                <Toggle label={`${c.name}を表示`} checked={c.visible} onChange={(v) => void repo.saveCalendar({ ...c, visible: v }, false)} />
                <span
                  className="drag-handle"
                  role="button"
                  tabIndex={0}
                  aria-label={`${c.name}の並び替え。Space で開始、上下キーで移動、Space で確定`}
                  aria-pressed={dr.active === id}
                  onPointerDown={(e) => dr.startPointer(e, c.id)}
                  onKeyDown={(e) => dr.onKey(e, c.id)}
                  data-testid={`calendar-handle-${c.id}`}
                >
                  <Icon name="reorder" size={20} />
                </span>
              </div>
            );
          })}
        </div>
        <button type="button" className="row row-button tint-row" onClick={startNew} data-testid="add-calendar">
          <Icon name="plus" size={18} />
          <span className="row-label">カレンダーを追加</span>
        </button>
      </Group>
    </>
  );
}

export function SubjectsPage() {
  const { subjects } = useData();
  const { confirm } = useUIActions();
  const fail = useErrorToast();
  const [name, setName] = useState('');
  const add = async () => {
    if (!name.trim()) return;
    try {
      await repo.saveSubject(makeSubject(name.trim(), Date.now()), true);
      setName('');
    } catch (e) {
      fail(e);
    }
  };
  return (
    <Group footer="授業の予定・テスト対策タスクで科目を選べるようになります。">
      {subjects.map((s) => (
        <div className="row" key={s.id}>
          <input className="row-input" defaultValue={s.name} aria-label="科目名" onBlur={(e) => e.target.value.trim() && e.target.value.trim() !== s.name && void repo.saveSubject({ ...s, name: e.target.value.trim() }, false)} />
          <button type="button" className="icon-btn subtle" aria-label={`${s.name}を削除`} onClick={async () => (await confirm({ title: `「${s.name}」を削除しますか？`, message: '予定・タスクに入力済みの科目名は残ります。', confirmLabel: '削除', destructive: true })) && void repo.deleteSubject(s.id)}>
            <Icon name="trash" size={16} />
          </button>
        </div>
      ))}
      <form className="row" onSubmit={(e) => { e.preventDefault(); void add(); }}>
        <Icon name="plus" size={18} className="tint" />
        <input className="row-input" value={name} onChange={(e) => setName(e.target.value)} placeholder="科目を追加（例：財政学）" aria-label="追加する科目名" data-testid="subject-input" enterKeyHint="done" />
      </form>
    </Group>
  );
}

export function EmployersPage() {
  const { employers, settings } = useData();
  const { confirm } = useUIActions();
  const fail = useErrorToast();
  const [name, setName] = useState('');
  const add = async () => {
    if (!name.trim()) return;
    try {
      await repo.saveEmployer(makeEmployer(name.trim(), Date.now(), settings.defaultJobReminderHours), true);
      setName('');
    } catch (e) {
      fail(e);
    }
  };
  return (
    <Group footer="アルバイトの予定で勤務先を選ぶと、勤務開始の指定時間前に「【勤務先】◯時間前」と通知します。">
      {employers.map((e) => (
        <div className="row" key={e.id} data-testid="employer-row">
          <span className="row-label">{e.name}</span>
          <select className="select-input small" value={e.reminderHours} aria-label={`${e.name}の通知`} onChange={(ev) => void repo.saveEmployer({ ...e, reminderHours: Number(ev.target.value) }, false)}>
            {[0.5, 1, 1.5, 2, 3, 4, 6, 12, 24].map((h) => (
              <option key={h} value={h}>{h}時間前</option>
            ))}
          </select>
          <button type="button" className="icon-btn subtle" aria-label={`${e.name}を削除`} onClick={async () => (await confirm({ title: `「${e.name}」を削除しますか？`, message: '登録済みの予定は残ります（通知は止まります）。', confirmLabel: '削除', destructive: true })) && void repo.deleteEmployer(e.id)}>
            <Icon name="trash" size={16} />
          </button>
        </div>
      ))}
      <form className="row" onSubmit={(ev) => { ev.preventDefault(); void add(); }}>
        <Icon name="plus" size={18} className="tint" />
        <input className="row-input" value={name} onChange={(e) => setName(e.target.value)} placeholder="勤務先を追加（例：GU 四条河原町）" aria-label="追加する勤務先" data-testid="employer-input" enterKeyHint="done" />
      </form>
    </Group>
  );
}
