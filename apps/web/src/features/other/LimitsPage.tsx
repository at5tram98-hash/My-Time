import { useSync } from '../../app/data';
import { Group } from '../../components/Controls';

/** 使える範囲と、保証できないこと（隠さずに示す） */
export function LimitsPage() {
  const sync = useSync();
  const mode = sync.config?.retentionMode ?? 'off';
  return (
    <>
      <Group header="オフライン">
        <p className="limits-text">一度開いたあとは、通信がなくても表示・追加・編集できます。変更は端末に保存し、つながったときに送ります。ログイン、Googleドライブへの保存、ほかの端末への反映には通信が必要です。</p>
      </Group>
      <Group header="通知">
        <p className="limits-text">iPhoneでは、ホーム画面に追加したアプリで通知を許可したときだけ届きます。通信状態や省電力の設定で遅れたり届かなかったりすることがあり、時刻ちょうどの到着は保証できません。</p>
      </Group>
      <Group header="バックアップ">
        <p className="limits-text">ログインしてGoogleドライブに接続している間、毎日22時ごろに保存し、読み戻して確認します。実行時刻は前後することがあります。Googleの設定によっては、約7日ごとにログインし直しが必要です。</p>
      </Group>
      <Group header="30日後の期限削除">
        <p className="limits-text" data-testid="limits-retention">
          {mode === 'on'
            ? '終了から30日を過ぎた予定・タスクは、Googleドライブへの保存を確認できた日だけ、通常の画面から削除します。削除したものは「期間指定の復元」で見返せます。'
            : mode === 'dry-run'
              ? '試運転中です。削除の対象数をお知らせするだけで、何も削除しません。'
              : '現在は停止中です。終了から30日を過ぎても自動では削除しません。'}
        </p>
      </Group>
    </>
  );
}
