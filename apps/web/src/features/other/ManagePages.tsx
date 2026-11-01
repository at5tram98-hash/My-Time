import { useState } from 'react';
import { type Calendar, CALENDAR_ICON_CHOICES, type CalendarKind, defaultCalendarIcon, makeEmployer, makeSubject, newId } from '@my-time/domain';
import { useData } from '../../app/data';
import { useUIActions } from '../../app/ui';
import { Group, Toggle } from '../../components/Controls';
import { Icon } from '../../components/Icon';
import { repo } from '../../data/repo';
import { IconPicker, ItemIcon } from '../../components/ItemIcon';

const COLORS = ['#0A84FF', '#5E5CE6', '#BF5AF2', '#FF375F', '#FF453A', '#FF9F0A', '#FFD60A', '#30D158', '#64D2FF', '#8E8E93'];
const KIND_LABEL: Record<CalendarKind, string> = { general: '一般', class: '授業', job: 'アルバイト' };

function useErrorToast() {
  const { showToast } = useUIActions();
  return (e: unknown) => showToast(e instanceof Error ? e.message : '保存できませんでした');
}

/** カレンダーの追加・名前/色/アイコン・表示ON/OFF・並び順・テンプレート（一般/授業/アルバイト） */
export function CalendarsPage() {
  const { calendars } = useData();
  const { confirm, showToast } = useUIActions();
  const fail = useErrorToast();
  const [editing, setEditing] = useState<Calendar | null>(null);
  const [isNew, setIsNew] = useState(false);

  const move = (i: number, d: -1 | 1) => {
    const ids = calendars.map((c) => c.id);
    const j = i + d;
    if (j < 0 || j >= ids.length) return;
    [ids[i], ids[j]] = [ids[j]!, ids[i]!];
    void repo.reorderCalendars(ids);
  };

  const startNew = () => {
    const now = Date.now();
    setIsNew(true);
    setEditing({ id: newId(), name: '', color: COLORS[calendars.length % COLORS.length]!, icon: 'calendar', kind: 'general', visible: true, order: calendars.length, createdAt: now, updatedAt: now });
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

  if (editing) {
    return (
      <div data-testid="calendar-editor">
        <Group>
          <input className="row-input big" value={editing.name} onChange={(e) => setEditing({ ...editing, name: e.target.value })} placeholder="カレンダー名" aria-label="カレンダー名" autoFocus data-testid="calendar-name" />
        </Group>
        <Group header="種類（テンプレート）" footer="授業：科目・教室・課題・小テストを入力できます。アルバイト：勤務先を選び、勤務前に通知します。どちらも達成率・進捗の計算には含めません。">
          {(Object.keys(KIND_LABEL) as CalendarKind[]).map((k) => (
            <button key={k} type="button" className="row row-button" role="radio" aria-checked={editing.kind === k} onClick={() => setEditing({ ...editing, kind: k })}>
              <span className="row-label">{KIND_LABEL[k]}</span>
              {editing.kind === k && <Icon name="check" size={18} className="tint" strokeWidth={2.4} />}
            </button>
          ))}
        </Group>
        <Group header="色">
          <div className="color-grid" role="radiogroup" aria-label="色">
            {COLORS.map((c) => (
              <button key={c} type="button" role="radio" aria-checked={editing.color === c} aria-label={c} className={`color-dot ${editing.color === c ? 'on' : ''}`} style={{ background: c }} onClick={() => setEditing({ ...editing, color: c })} />
            ))}
          </div>
        </Group>
        <Group header="アイコン">
          <IconPicker choices={CALENDAR_ICON_CHOICES} value={editing.icon} onChange={(id) => setEditing({ ...editing, icon: id })} />
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

  return (
    <>
      <Group footer="スイッチで表示・非表示、矢印で並び順を変えられます。">
        {calendars.map((c, i) => (
          <div className="row" key={c.id} data-testid={`calendar-row-${c.id}`}>
            <span className="cal-chip" style={{ background: c.color }} aria-hidden><ItemIcon value={c.icon} size={16} fallback={defaultCalendarIcon(c.kind)} /></span>
            <button type="button" className="row-label link-like" onClick={() => { setIsNew(false); setEditing(c); }}>
              {c.name}
              <span className="sub-label">{KIND_LABEL[c.kind]}</span>
            </button>
            <button type="button" className="icon-btn" aria-label={`${c.name}を上へ`} disabled={i === 0} onClick={() => move(i, -1)}><Icon name="chevronLeft" size={16} style={{ transform: 'rotate(90deg)' }} /></button>
            <button type="button" className="icon-btn" aria-label={`${c.name}を下へ`} disabled={i === calendars.length - 1} onClick={() => move(i, 1)}><Icon name="chevronDown" size={16} /></button>
            <Toggle label={`${c.name}を表示`} checked={c.visible} onChange={(v) => void repo.saveCalendar({ ...c, visible: v }, false)} />
          </div>
        ))}
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
