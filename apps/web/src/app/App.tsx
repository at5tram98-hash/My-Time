import { useEffect } from 'react';
import { DataProvider, useData } from './data';
import { UIProvider, useUI, type TabId } from './ui';
import { SheetHost } from './SheetHost';
import { AlertHost, ToastHost } from '../components/Overlays';
import { Icon, type IconName } from '../components/Icon';
import { HomeScreen } from '../features/home/HomeScreen';
import { CalendarScreen } from '../features/calendar/CalendarScreen';
import { TasksScreen } from '../features/tasks/TasksScreen';
import { AnalysisScreen } from '../features/analysis/AnalysisScreen';
import { OtherScreen } from '../features/other/OtherScreen';

const TABS: { id: TabId; label: string; icon: IconName }[] = [
  { id: 'home', label: 'ホーム', icon: 'house' },
  { id: 'calendar', label: 'カレンダー', icon: 'calendar' },
  { id: 'tasks', label: 'タスク', icon: 'checklist' },
  { id: 'analysis', label: '分析', icon: 'chart' },
  { id: 'other', label: 'その他', icon: 'more' },
];

const TEXT_SIZE_PX = { small: '15px', large: '19px', xlarge: '22px' } as const;

function AppearanceSync() {
  const { settings } = useData();
  useEffect(() => {
    const root = document.documentElement;
    if (settings.theme === 'system') root.removeAttribute('data-theme');
    else root.setAttribute('data-theme', settings.theme);
    if (settings.textSize === 'system') root.style.removeProperty('--base-size');
    else root.style.setProperty('--base-size', TEXT_SIZE_PX[settings.textSize]);
    root.dataset.textSize = settings.textSize;
  }, [settings.theme, settings.textSize]);

  // iOS のソフトウェアキーボード表示中は、その高さだけシートを持ち上げて入力欄・保存ボタンを隠さない
  useEffect(() => {
    const vv = window.visualViewport;
    if (!vv) return;
    const update = () => {
      const kb = Math.max(0, window.innerHeight - vv.height - vv.offsetTop);
      document.documentElement.style.setProperty('--kb', `${Math.round(kb)}px`);
    };
    update();
    vv.addEventListener('resize', update);
    vv.addEventListener('scroll', update);
    return () => {
      vv.removeEventListener('resize', update);
      vv.removeEventListener('scroll', update);
    };
  }, []);
  return null;
}

function Shell() {
  const { tab, setTab } = useUI();
  const { ready } = useData();
  return (
    <div className="app-shell">
      <AppearanceSync />
      <main className="app-main">
        {ready ? (
          <>
            <div className="tab-panel" hidden={tab !== 'home'}><HomeScreen /></div>
            <div className="tab-panel" hidden={tab !== 'calendar'}>{tab === 'calendar' && <CalendarScreen />}</div>
            <div className="tab-panel" hidden={tab !== 'tasks'}>{tab === 'tasks' && <TasksScreen />}</div>
            <div className="tab-panel" hidden={tab !== 'analysis'}>{tab === 'analysis' && <AnalysisScreen />}</div>
            <div className="tab-panel" hidden={tab !== 'other'}>{tab === 'other' && <OtherScreen />}</div>
          </>
        ) : (
          <div className="loading" aria-busy="true" />
        )}
      </main>
      <nav className="tabbar" aria-label="タブ">
        {TABS.map((t) => (
          <button key={t.id} type="button" className={`tab ${tab === t.id ? 'active' : ''}`} aria-current={tab === t.id ? 'page' : undefined} onClick={() => setTab(t.id)} data-testid={`tab-${t.id}`}>
            <span className="tab-icon">
              <Icon name={t.icon} size={25} strokeWidth={tab === t.id ? 2.2 : 1.8} />
            </span>
            <span className="tab-label">{t.label}</span>
          </button>
        ))}
      </nav>
      <SheetHost />
      <AlertHost />
      <ToastHost />
    </div>
  );
}

export function App() {
  return (
    <DataProvider>
      <UIProvider>
        <Shell />
      </UIProvider>
    </DataProvider>
  );
}
