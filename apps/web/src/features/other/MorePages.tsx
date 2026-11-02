import { useRef, useState } from 'react';
import { newId, resolveItemIcon, TASK_ICON_CHOICES, type TaskCategory } from '@my-time/domain';
import { useData } from '../../app/data';
import { useUIActions } from '../../app/ui';
import { Group, Toggle } from '../../components/Controls';
import { Icon } from '../../components/Icon';
import { MenuButton } from '../../components/Menu';
import { DEFAULT_SETTINGS } from '../../data/db';
import { repo } from '../../data/repo';
import { Popup } from '../../ui/Popup';
import { openContextMenu } from '../../ui/ContextMenu';
import { useLongPress } from '../../ui/gestures';
import { ColorStrip, COLORS, IconStrip } from '../editor/pickers';

/** タスクのカテゴリー（Q55）：名前・アイコン・色。並び替えは専用ハンドルのドラッグ（矢印は使わない） */
export function CategoriesPage() {
  const { categories, tasks, settings, studioTypes } = useData();
  const { confirm, showToast } = useUIActions();
  const [editing, setEditing] = useState<TaskCategory | null>(null);
  const [isNew, setIsNew] = useState(false);
  const listRef = useRef<HTMLDivElement>(null);
  const used = (name: string) => tasks.filter((t) => t.category === name).length;
  const legacy = [...new Set(tasks.map((t) => t.category).filter((c): c is string => !!c && !categories.some((x) => x.name === c)))];

  const startNew = (name = '') => {
    const now = Date.now();
    setIsNew(true);
    setEditing({ id: newId(), name, icon: TASK_ICON_CHOICES[categories.length % TASK_ICON_CHOICES.length]!, color: COLORS[categories.length % COLORS.length]!, order: categories.length, createdAt: now, updatedAt: now });
  };
  const save = async () => {
    if (!editing || !editing.name.trim()) return;
    const prev = categories.find((c) => c.id === editing.id);
    await repo.saveCategory({ ...editing, name: editing.name.trim() }, isNew);
    // 名前を変えたら、そのカテゴリーのタスクの表示名も合わせる（確認のうえ）
    if (prev && prev.name !== editing.name.trim() && used(prev.name) > 0 && (await confirm({ title: 'タスクのカテゴリー名も変えますか？', message: `「${prev.name}」のタスク${used(prev.name)}件を「${editing.name.trim()}」にします。`, confirmLabel: '変える', cancelLabel: 'そのまま' }))) {
      for (const t of tasks.filter((x) => x.category === prev.name)) await repo.saveTask({ ...t, category: editing.name.trim() }, false);
    }
    setEditing(null);
  };
  const remove = async (c: TaskCategory) => {
    if (!(await confirm({ title: `「${c.name}」を削除しますか？`, message: used(c.name) ? `${used(c.name)}件のタスクのカテゴリー名はそのまま残ります。` : '', confirmLabel: '削除', destructive: true }))) return;
    await repo.deleteCategory(c.id);
    showToast('削除しました');
  };
  const startDrag = (e: React.PointerEvent, id: string) => {
    e.preventDefault();
    const items = [...(listRef.current?.querySelectorAll<HTMLElement>('[data-cat-id]') ?? [])];
    const ids = items.map((x) => x.dataset.catId!);
    const rects = items.map((x) => x.getBoundingClientRect());
    const el = items[ids.indexOf(id)]!;
    const y0 = e.clientY;
    const from = ids.indexOf(id);
    let to = from;
    el.classList.add('dragging');
    const move = (ev: PointerEvent) => { const dy = ev.clientY - y0; el.style.transform = `translateY(${dy}px)`; const cy = rects[from]!.top + rects[from]!.height / 2 + dy; const i = rects.findIndex((r) => cy < r.bottom); to = i === -1 ? ids.length - 1 : i; };
    const up = () => {
      window.removeEventListener('pointermove', move); window.removeEventListener('pointerup', up); window.removeEventListener('pointercancel', up);
      el.classList.remove('dragging'); el.style.transform = '';
      if (to === from) return;
      const next = [...ids]; next.splice(to, 0, next.splice(from, 1)[0]!);
      void repo.reorderCategories(next);
    };
    window.addEventListener('pointermove', move); window.addEventListener('pointerup', up); window.addEventListener('pointercancel', up);
  };

  return (
    <>
      <Group header="カテゴリー" footer="右端のつまみをドラッグして並び替えます。長押しで編集・削除。">
        <div ref={listRef}>
          {categories.map((c) => <CategoryRow key={c.id} c={c} count={used(c.name)} onEdit={() => { setIsNew(false); setEditing(c); }} onDelete={() => void remove(c)} onDrag={(e) => startDrag(e, c.id)} />)}
        </div>
        <button type="button" className="row row-button tint-row" onClick={() => startNew()} data-testid="add-category"><Icon name="plus" size={18} /><span className="row-label">カテゴリーを追加</span></button>
      </Group>
      {legacy.length > 0 && (
        <Group header="タスクに入っている名前" footer="タップするとアイコンと色を付けて登録できます。">
          {legacy.map((n) => <button key={n} type="button" className="row row-button" onClick={() => startNew(n)}><span className="row-label">{n}</span><span className="row-value muted">{used(n)}件</span></button>)}
        </Group>
      )}
      <Group header="専用の種類" footer="課題・テスト対策のほか、自分で作った種類は「Create Studio」で編集できます。">
        <div className="row"><Icon name="note" size={18} className="muted" /><span className="row-label">課題</span><span className="row-value muted">提出方法・期限</span></div>
        <div className="row"><Icon name="graduation" size={18} className="muted" /><span className="row-label">テスト対策</span><span className="row-value muted">授業・試験日</span></div>
        {studioTypes.filter((t) => t.target === 'task').map((t) => <div key={t.id} className="row"><Icon name={resolveItemIcon(t.icon).id} size={18} style={{ color: t.color }} /><span className="row-label">{t.name}</span><span className="row-value muted">{t.status === 'draft' ? '下書き' : `${t.fields.filter((f) => !f.hidden).length}項目`}</span></div>)}
      </Group>
      <Popup open={!!editing} title={isNew ? '新しいカテゴリー' : 'カテゴリーを編集'} onClose={() => setEditing(null)} onDone={() => void save()} doneLabel="保存" testId="category-editor" tall>
        {editing && (
          <>
            <div className="group"><div className="group-body"><input className="row-input big" value={editing.name} onChange={(e) => setEditing({ ...editing, name: e.target.value })} placeholder="カテゴリー名" aria-label="カテゴリー名" maxLength={40} data-testid="category-name" /></div></div>
            <div className="group-header">アイコン</div>
            <div className="group"><div className="group-body"><IconStrip value={editing.icon} onChange={(id) => setEditing({ ...editing, icon: id })} recent={settings.recentIcons} target="task" /></div></div>
            <div className="group-header">色</div>
            <div className="group"><div className="group-body"><ColorStrip value={editing.color} onChange={(col) => setEditing({ ...editing, color: col ?? '#0A84FF' })} recent={settings.recentColors} /></div></div>
          </>
        )}
      </Popup>
    </>
  );
}

function CategoryRow({ c, count, onEdit, onDelete, onDrag }: { c: TaskCategory; count: number; onEdit: () => void; onDelete: () => void; onDrag: (e: React.PointerEvent) => void }) {
  const ref = useRef<HTMLDivElement>(null);
  const lp = useLongPress({ onLongPress: () => ref.current && openContextMenu({ anchor: ref.current, label: c.name, preview: <div className="ctx-card"><strong>{c.name}</strong><span>{count}件</span></div>, items: [{ label: '編集', icon: 'pencil', onSelect: onEdit }, 'separator', { label: '削除', icon: 'trash', destructive: true, onSelect: onDelete }] }) });
  return (
    <div className="row" ref={ref} data-cat-id={c.id} {...lp} data-testid={`category-${c.name}`}>
      <span className="cal-chip small" style={{ background: c.color }} aria-hidden><Icon name={resolveItemIcon(c.icon).id} size={14} /></span>
      <button type="button" className="row-label link-like" onClick={() => { if (!lp.consumedClick()) onEdit(); }}>{c.name}<span className="sub-label">{count}件</span></button>
      <span className="drag-handle" role="button" tabIndex={0} aria-label={`${c.name}の並び替え`} onPointerDown={onDrag}><Icon name="arrowUpDown" size={18} /></span>
    </div>
  );
}

/** TimeTree：読み込み専用の設定（Q52）。TimeTree への書き込みはしない */
export function TimeTreePage() {
  const { settings, calendars } = useData();
  const { openSheet } = useUIActions();
  return (
    <>
      <Group header="読み込み" footer="TimeTree の公式APIは提供が終了しているため、TimeTree から書き出したカレンダーファイル（.ics）またはテキストを読み込みます。My Time から TimeTree へは書き込みません。">
        <button type="button" className="row row-button" onClick={() => openSheet({ kind: 'import' })} data-testid="timetree-import"><Icon name="link" size={18} className="tint" /><span className="row-label tint">ファイル・テキストから読み込む</span></button>
      </Group>
      <Group header="読み込みの設定">
        <div className="row">
          <span className="row-label">同じ予定は飛ばす</span>
          <Toggle label="同じ予定は飛ばす" checked={settings.timetreeAutoSkipDuplicates} onChange={(b) => void repo.updateSettings({ timetreeAutoSkipDuplicates: b })} />
        </div>
        <div className="row">
          <span className="row-label">入れるカレンダー</span>
          <MenuButton label="入れるカレンダー" className="row-menu-btn" items={[{ label: '毎回選ぶ', checked: settings.timetreeDefaultCalendarId == null, onSelect: () => void repo.updateSettings({ timetreeDefaultCalendarId: null }) }, ...calendars.map((c) => ({ label: c.name, checked: settings.timetreeDefaultCalendarId === c.id, onSelect: () => void repo.updateSettings({ timetreeDefaultCalendarId: c.id }) }))]}>
            {calendars.find((c) => c.id === settings.timetreeDefaultCalendarId)?.name ?? '毎回選ぶ'}
            <Icon name="arrowUpDown" size={14} />
          </MenuButton>
        </div>
      </Group>
    </>
  );
}

/** 詳細設定（Q61）：分析・入力の細かい設定、端末のデータ件数、危険な操作（奥に隔離・確認必須） */
export function AdvancedPage({ logCount }: { logCount: number }) {
  const { settings, tasks, events, outboxPending } = useData();
  const { confirm, showToast } = useUIActions();
  const resetSettings = async () => {
    if (!(await confirm({ title: '表示の設定を初期状態に戻しますか？', message: '外観・文字サイズ・並び順・ホームの比率などを初期状態に戻します。予定・タスク・アカウント・バックアップは変わりません。', confirmLabel: '初期状態に戻す', destructive: true }))) return;
    const keep = { onboarded: settings.onboarded, placeHistory: settings.placeHistory, recentIcons: settings.recentIcons, recentColors: settings.recentColors };
    const { key: _k, ...defaults } = DEFAULT_SETTINGS;
    await repo.updateSettings({ ...defaults, ...keep });
    showToast('設定を初期状態に戻しました');
  };
  return (
    <>
      <Group header="分析" footer="一時停止したタスク・自動開始/終了（AR）したタスクは、初期設定では分析の集計に含めません。授業・アルバイトの予定は常に対象外です。">
        <div className="row"><label className="row-label" htmlFor="opt-paused">一時停止したタスクを含める</label><Toggle id="opt-paused" label="一時停止したタスクを含める" checked={settings.analysisIncludePaused} onChange={(v) => void repo.updateSettings({ analysisIncludePaused: v })} /></div>
        <div className="row"><label className="row-label" htmlFor="opt-auto">自動開始・終了したタスクを含める</label><Toggle id="opt-auto" label="自動開始・終了したタスクを含める" checked={settings.analysisIncludeAuto} onChange={(v) => void repo.updateSettings({ analysisIncludeAuto: v })} /></div>
      </Group>
      <Group header="入力・操作" footer="予定やタスクの時間が重なったときに提案する空き時間の範囲です。既存の予定は自動では動かしません。">
        <div className="row">
          <span className="row-label">新しいタスクの通知</span>
          <MenuButton label="新しいタスクの通知" className="row-menu-btn" items={[null, 0, 5, 10, 30, 60].map((m) => ({ label: m == null ? 'なし' : m === 0 ? '開始時刻' : `${m}分前`, checked: settings.defaultNotifyMinutes === m, onSelect: () => void repo.updateSettings({ defaultNotifyMinutes: m }) }))}>
            {settings.defaultNotifyMinutes == null ? 'なし' : settings.defaultNotifyMinutes === 0 ? '開始時刻' : `${settings.defaultNotifyMinutes}分前`}<Icon name="arrowUpDown" size={14} />
          </MenuButton>
        </div>
        <div className="row">
          <span className="row-label">提案する時間帯</span>
          <MenuButton label="提案の開始時刻" className="row-menu-btn" items={[5, 6, 7, 8, 9, 10].map((h) => ({ label: `${h}時から`, checked: settings.suggestFromHour === h, onSelect: () => void repo.updateSettings({ suggestFromHour: h }) }))}>{settings.suggestFromHour}時</MenuButton>〜
          <MenuButton label="提案の終了時刻" className="row-menu-btn" items={[20, 21, 22, 23, 24].map((h) => ({ label: `${h}時まで`, checked: settings.suggestToHour === h, onSelect: () => void repo.updateSettings({ suggestToHour: h }) }))}>{settings.suggestToHour}時</MenuButton>
        </div>
        <div className="row">
          <span className="row-label">提案の刻み</span>
          <MenuButton label="提案の刻み" className="row-menu-btn" items={([15, 30, 60] as const).map((m) => ({ label: `${m}分`, checked: settings.suggestStepMin === m, onSelect: () => void repo.updateSettings({ suggestStepMin: m }) }))}>{settings.suggestStepMin}分<Icon name="arrowUpDown" size={14} /></MenuButton>
        </div>
      </Group>
      <Group header="この端末のデータ">
        <div className="row"><span className="row-label">タスク</span><span className="row-value" data-testid="count-tasks">{tasks.length}件</span></div>
        <div className="row"><span className="row-label">予定</span><span className="row-value">{events.length}件</span></div>
        <div className="row"><span className="row-label">操作ログ</span><span className="row-value">{logCount}件</span></div>
        <div className="row"><span className="row-label">未送信の変更</span><span className="row-value">{outboxPending}件</span></div>
      </Group>
      <Group header="危険な操作" footer="予定・タスク・バックアップを消す操作はここにはありません。">
        <button type="button" className="row row-button destructive" onClick={() => void resetSettings()} data-testid="reset-settings"><span className="row-label">表示の設定を初期状態に戻す</span></button>
      </Group>
    </>
  );
}
