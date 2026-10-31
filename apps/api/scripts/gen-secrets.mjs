// 本番用の秘密値を手元で生成して表示する（ファイルには保存しない・GitHub にコミットしない）。
// 使い方：node apps/api/scripts/gen-secrets.mjs
import { webcrypto as c } from 'node:crypto';

const b64 = (u8) => Buffer.from(u8).toString('base64');
const b64url = (u8) => Buffer.from(u8).toString('base64url');

const kp = await c.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
const pub = new Uint8Array(await c.subtle.exportKey('raw', kp.publicKey));
const jwk = await c.subtle.exportKey('jwk', kp.privateKey);

console.log('# 以下を wrangler secret put で1つずつ登録してください（画面を閉じたら控えは残りません）');
console.log(`SESSION_SECRET=${b64url(c.getRandomValues(new Uint8Array(32)))}`);
console.log(`TOKEN_ENC_KEY=${b64(c.getRandomValues(new Uint8Array(32)))}`);
console.log(`VAPID_PUBLIC_KEY=${b64url(pub)}`);
console.log(`VAPID_PRIVATE_JWK=${JSON.stringify({ kty: jwk.kty, crv: jwk.crv, x: jwk.x, y: jwk.y, d: jwk.d })}`);
