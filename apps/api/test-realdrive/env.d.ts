declare module 'cloudflare:test' {
  interface ProvidedEnv {
    DB: D1Database;
    RECOVERY_DB: D1Database;
    TEST_MIGRATIONS: D1Migration[];
    REAL_SNAPSHOT_TEXT: string;
    REAL_SNAPSHOT_SHA256: string;
  }
}
