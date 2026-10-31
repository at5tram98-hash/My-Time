declare module 'cloudflare:test' {
  interface ProvidedEnv {
    DB: D1Database;
    TEST_MIGRATIONS: D1Migration[];
  }
}

declare module '*?raw' {
  const text: string;
  export default text;
}
