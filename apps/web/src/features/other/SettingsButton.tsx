import { useAttention } from '../../app/data';
import { useUIActions } from '../../app/ui';
import { Icon } from '../../components/Icon';

/**
 * 設定を開く歯車（各画面の右上。IOS-016）。
 * 同期・バックアップの失敗など確認が必要なお知らせがあるときだけ、小さな「!」を重ねる（以前の「その他」タブの印と同じ）。
 */
export function SettingsButton() {
  const { setTab } = useUIActions();
  const attention = useAttention();
  return (
    <button type="button" className="gbtn glass glass-i settings-btn" aria-label={attention > 0 ? '設定（確認が必要なお知らせがあります）' : '設定'} onClick={() => setTab('other')} data-testid="open-settings">
      <Icon name="gear" size={20} />
      {attention > 0 && <span className="tab-alert" role="img" aria-label="確認が必要なお知らせがあります" data-testid="other-alert"><Icon name="exclamation" size={11} strokeWidth={3.4} /></span>}
    </button>
  );
}
