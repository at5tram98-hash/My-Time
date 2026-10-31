export interface Env {
  DB: D1Database;
  ASSETS?: Fetcher;
  /** アプリの公開オリジン（OAuth のリダイレクト先・Cookie 判定に使う） */
  APP_ORIGIN: string;
  /** 日付・曜日の判定に使う利用者のタイムゾーン（既定 Asia/Tokyo） */
  APP_TIME_ZONE?: string;
  GOOGLE_AUTH_BASE: string;
  GOOGLE_TOKEN_URL: string;
  GOOGLE_JWKS_URL: string;
  GOOGLE_API_BASE: string;
  /** 以下はシークレット（wrangler secret put / GitHub Secrets）。リポジトリには置かない */
  GOOGLE_CLIENT_ID?: string;
  GOOGLE_CLIENT_SECRET?: string;
  /** Cookie 署名などに使う32文字以上の乱数 */
  SESSION_SECRET?: string;
  /** リフレッシュトークン暗号化キー（base64 の 32 バイト） */
  TOKEN_ENC_KEY?: string;
  /** Web Push（VAPID）の鍵。公開鍵は base64url の非圧縮点、秘密鍵は JWK(JSON) */
  VAPID_PUBLIC_KEY?: string;
  VAPID_PRIVATE_JWK?: string;
  VAPID_SUBJECT?: string;
  /**
   * 期限削除（30日）の動作：off＝停止（未設定時の既定）／dry-run＝対象の件数だけ記録して何も消さない／on＝実行。
   * 本番は off で公開し、本物の Drive でバックアップと復元試験を確認してから on にする
   */
  RETENTION_MODE?: string;
  /** テスト専用（x-mytime-now ヘッダーで時刻を差し替え）。本番では設定しない */
  ALLOW_TEST_CLOCK?: string;
}

import { setDomainTimeZone } from '@my-time/domain';

/** 日付判定を利用者のタイムゾーンで行う（Workers は UTC で動くため、各処理の入口で呼ぶ） */
export function applyUserZone(env: Pick<Env, 'APP_TIME_ZONE'>): void {
  setDomainTimeZone(env.APP_TIME_ZONE || 'Asia/Tokyo');
}

export type RetentionMode = 'off' | 'dry-run' | 'on';

/** 不明な値・未設定は安全側の off として扱う */
export function retentionMode(env: Pick<Env, 'RETENTION_MODE'>): RetentionMode {
  const v = (env.RETENTION_MODE ?? '').trim().toLowerCase();
  return v === 'on' || v === 'dry-run' ? v : 'off';
}

export function googleConfigured(env: Env): boolean {
  return Boolean(env.GOOGLE_CLIENT_ID && env.GOOGLE_CLIENT_SECRET && env.SESSION_SECRET && env.TOKEN_ENC_KEY);
}

export function pushConfigured(env: Env): boolean {
  return Boolean(env.VAPID_PUBLIC_KEY && env.VAPID_PRIVATE_JWK);
}

export type AppBindings = { Bindings: Env; Variables: { userId: string; now: number } };
