import { defineWorkersConfig, readD1Migrations } from '@cloudflare/vitest-pool-workers/config';
import { readFileSync } from 'node:fs';
import path from 'node:path';

/**
 * 実 Drive の日次バックアップファイルを、隔離した空の D1（miniflare のローカル DB。本番 D1 ではない）へ書き戻す検証。
 * 使い方：MYTIME_REAL_SNAPSHOT=/path/to/MyTime-daily-....json [MYTIME_REAL_SHA256=<manifest の sha256>] pnpm --filter @my-time/api test:realdrive
 * ファイルはリポジトリに入れない。結果は件数と一致・不一致だけを出力する（本文は出さない）。
 */
export default defineWorkersConfig(async () => {
  const migrations = await readD1Migrations(path.join(__dirname, 'migrations'));
  const file = process.env.MYTIME_REAL_SNAPSHOT;
  if (!file) throw new Error('MYTIME_REAL_SNAPSHOT（実 Drive からダウンロードした日次ファイルのパス）を指定してください');
  return {
    test: {
      name: 'api-realdrive',
      include: ['test-realdrive/**/*.test.ts'],
      setupFiles: ['./test/apply-migrations.ts'],
      poolOptions: {
        workers: {
          singleWorker: true,
          isolatedStorage: true,
          wrangler: { configPath: './wrangler.toml' },
          miniflare: {
            d1Databases: ['RECOVERY_DB'],
            bindings: {
              TEST_MIGRATIONS: migrations,
              REAL_SNAPSHOT_TEXT: readFileSync(file, 'utf8'),
              REAL_SNAPSHOT_SHA256: process.env.MYTIME_REAL_SHA256 ?? '',
              SESSION_SECRET: 'test-secret-0123456789abcdef0123456789abcdef',
              TOKEN_ENC_KEY: 'MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=',
              GOOGLE_CLIENT_ID: 'test-client',
              GOOGLE_CLIENT_SECRET: 'test-secret',
              ALLOW_TEST_CLOCK: '1',
              RETENTION_MODE: 'off',
            },
          },
        },
      },
    },
  };
});
