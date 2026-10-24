import { assert, assertEquals } from '@std/assert';
import { exportPKCS8, generateKeyPair, jwtVerify, SignJWT } from 'jose';
import { type AppleConfig, appleConfig, revokeAppleGrant } from './apple.ts';

const { publicKey, privateKey } = await generateKeyPair('ES256', { extractable: true });
const pem = await exportPKCS8(privateKey);

const config: AppleConfig = {
  clientId: 'com.petertrost.familygroceries',
  teamId: 'TEAM123456',
  keyId: 'KEY1234567',
  privateKey: pem,
  baseUrl: 'https://apple.test',
};

const idToken = (sub: string) =>
  new SignJWT({}).setProtectedHeader({ alg: 'ES256' }).setSubject(sub).sign(privateKey);

type Seen = { url: string; form: Record<string, string> };

/** Apple's two endpoints; `answers` overrides a path's response. */
function fakeApple(answers: Record<string, () => Response | Promise<Response>> = {}) {
  const seen: Seen[] = [];
  const fetchFn = async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    seen.push({ url, form: Object.fromEntries(new URLSearchParams(String(init?.body))) });
    const path = new URL(url).pathname;
    if (answers[path]) return await answers[path]();
    if (path === '/auth/token') {
      return Response.json({
        access_token: 'at',
        refresh_token: 'rt-secret',
        id_token: await idToken('apple-sub'),
      });
    }
    return new Response(null, { status: 200 });
  };
  return { fetchFn: fetchFn as typeof fetch, seen };
}

Deno.test('exchanges the code, then revokes the refresh token', async () => {
  const { fetchFn, seen } = fakeApple();
  const fate = await revokeAppleGrant({ code: 'c0de', subject: 'apple-sub' }, config, fetchFn);
  assertEquals(fate, 'revoked');
  assertEquals(seen.map((s) => s.url), [
    'https://apple.test/auth/token',
    'https://apple.test/auth/revoke',
  ]);
  const [token, revoke] = seen;
  assertEquals({ ...token.form, client_secret: '-' }, {
    client_id: 'com.petertrost.familygroceries',
    client_secret: '-',
    grant_type: 'authorization_code',
    code: 'c0de',
  });
  assertEquals({ ...revoke.form, client_secret: '-' }, {
    client_id: 'com.petertrost.familygroceries',
    client_secret: '-',
    token: 'rt-secret',
    token_type_hint: 'refresh_token',
  });

  const { payload, protectedHeader } = await jwtVerify(token.form.client_secret, publicKey, {
    issuer: 'TEAM123456',
    audience: 'https://appleid.apple.com',
    subject: 'com.petertrost.familygroceries',
    algorithms: ['ES256'],
  });
  assertEquals(protectedHeader.kid, 'KEY1234567');
  assert(payload.exp! - payload.iat! <= 300, 'the client secret is short-lived');
  assertEquals(revoke.form.client_secret, token.form.client_secret);
});

Deno.test('every Apple failure falls back to manual removal, without logging secrets', async (t) => {
  const down = (() => Promise.reject(new TypeError('connection refused'))) as typeof fetch;
  const cases: {
    name: string;
    code?: string | null;
    config?: AppleConfig | null;
    answers?: Parameters<typeof fakeApple>[0];
    fetchFn?: typeof fetch;
    calls: number;
  }[] = [
    { name: 'no code', code: null, calls: 0 },
    { name: 'no configuration', config: null, calls: 0 },
    {
      name: 'invalid_grant',
      answers: { '/auth/token': () => Response.json({ error: 'invalid_grant' }, { status: 400 }) },
      calls: 1,
    },
    {
      name: 'a code of another Apple ID',
      answers: {
        '/auth/token': async () =>
          Response.json({ refresh_token: 'rt-secret', id_token: await idToken('someone-else') }),
      },
      calls: 1,
    },
    {
      name: 'revoke refused',
      answers: {
        '/auth/revoke': () => Response.json({ error: 'invalid_client' }, { status: 400 }),
      },
      calls: 2,
    },
    { name: 'network down', fetchFn: down, calls: 0 },
  ];
  const warn = console.warn;
  const logged: string[] = [];
  console.warn = (...args: unknown[]) => logged.push(args.join(' '));
  try {
    for (const c of cases) {
      await t.step(c.name, async () => {
        const apple = fakeApple(c.answers);
        const fate = await revokeAppleGrant(
          { code: c.code === undefined ? 'c0de-secret' : c.code, subject: 'apple-sub' },
          c.config === undefined ? config : c.config,
          c.fetchFn ?? apple.fetchFn,
        );
        assertEquals([fate, apple.seen.length], ['manual', c.calls]);
      });
    }
  } finally {
    console.warn = warn;
  }
  assertEquals(logged.length, cases.length);
  for (const line of logged) {
    assert(!/rt-secret|PRIVATE KEY|c0de-secret|eyJ/.test(line), `no secret in: ${line}`);
  }
});

Deno.test('the configuration comes from the environment, with the bundle id default', () => {
  // Split so secret scanners don't take the placeholder for a key.
  const [begin, end] = ['BEGIN', 'END'].map((word) => `-----${word} PRIVATE KEY-----`);
  const env: Record<string, string> = {
    APPLE_TEAM_ID: 'T',
    APPLE_KEY_ID: 'K',
    APPLE_PRIVATE_KEY: `${begin}\\nabc\\n${end}`,
  };
  assertEquals(appleConfig((name) => env[name]), {
    clientId: 'com.petertrost.familygroceries',
    teamId: 'T',
    keyId: 'K',
    privateKey: `${begin}\nabc\n${end}`,
    baseUrl: 'https://appleid.apple.com',
  });
  assertEquals(appleConfig((name) => ({ ...env, APPLE_KEY_ID: '' })[name]), null);
});
