// Sign in with Apple token revocation on account deletion (Apple TN3194): exchange the
// authorization code the app just got from Apple for a refresh token, then revoke it, which
// removes the app from the user's "Sign in with Apple" list. Codes, tokens and the key are
// never logged.
import { decodeJwt, importPKCS8, SignJWT } from 'jose';

export type AppleConfig = {
  /** The bundle id for native iOS codes. */
  clientId: string;
  teamId: string;
  keyId: string;
  /** PKCS#8 PEM of the Sign in with Apple key. */
  privateKey: string;
  baseUrl: string;
};

/** 'manual': the user removes the app under Settings, Apple ID, Sign in with Apple. */
export type AppleRevocation = 'revoked' | 'manual';

type Env = (name: string) => string | undefined;

/** The configuration from the environment, or null when the key is not set up. */
export function appleConfig(env: Env = (name) => Deno.env.get(name)): AppleConfig | null {
  const teamId = env('APPLE_TEAM_ID');
  const keyId = env('APPLE_KEY_ID');
  const privateKey = env('APPLE_PRIVATE_KEY');
  if (!teamId || !keyId || !privateKey) return null;
  return {
    clientId: env('APPLE_BUNDLE_ID') || 'com.petertrost.familygroceries',
    teamId,
    keyId,
    // Secrets set from a one-line value carry the PEM's newlines as "\n".
    privateKey: privateKey.replaceAll('\\n', '\n'),
    baseUrl: (env('APPLE_AUTH_URL') || 'https://appleid.apple.com').replace(/\/+$/, ''),
  };
}

/** The ES256 client secret Apple's token endpoints take; valid for five minutes. */
export async function clientSecret(config: AppleConfig, now = new Date()): Promise<string> {
  const iat = Math.floor(now.getTime() / 1000);
  return await new SignJWT({})
    .setProtectedHeader({ alg: 'ES256', kid: config.keyId })
    .setIssuer(config.teamId)
    .setSubject(config.clientId)
    .setAudience('https://appleid.apple.com')
    .setIssuedAt(iat)
    .setExpirationTime(iat + 300)
    .sign(await importPKCS8(config.privateKey, 'ES256'));
}

class AppleFailure extends Error {}

/**
 * Revokes the user's Apple grant. `subject` is the Apple user id of the account being deleted;
 * a code issued to a different Apple ID is refused. Never throws.
 */
export async function revokeAppleGrant(
  { code, subject }: { code: string | null; subject: string },
  config: AppleConfig | null,
  fetchFn: typeof fetch = fetch,
): Promise<AppleRevocation> {
  try {
    if (!config) throw new AppleFailure('APPLE_TEAM_ID, APPLE_KEY_ID or APPLE_PRIVATE_KEY not set');
    if (!code) throw new AppleFailure('no authorization code sent');
    const secret = await clientSecret(config);
    const post = async (path: string, form: Record<string, string>) => {
      const res = await fetchFn(`${config.baseUrl}${path}`, {
        method: 'POST',
        headers: { 'content-type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ client_id: config.clientId, client_secret: secret, ...form }),
      });
      if (!res.ok) {
        const reason = await res.json().then((b) => b?.error, () => undefined);
        throw new AppleFailure(`${path} answered ${res.status} ${reason ?? ''}`.trim());
      }
      return res;
    };

    const tokens = await (await post('/auth/token', {
      grant_type: 'authorization_code',
      code,
    })).json() as { refresh_token?: unknown; id_token?: unknown };
    if (typeof tokens.refresh_token !== 'string' || typeof tokens.id_token !== 'string') {
      throw new AppleFailure('/auth/token answered without refresh_token or id_token');
    }
    // The id_token came straight from Apple over TLS; its subject is all we need from it.
    if (decodeJwt(tokens.id_token).sub !== subject) {
      throw new AppleFailure('the code belongs to a different Apple ID');
    }
    await post('/auth/revoke', { token: tokens.refresh_token, token_type_hint: 'refresh_token' });
    return 'revoked';
  } catch (e) {
    const reason = e instanceof AppleFailure
      ? e.message
      : `${(e as Error).name}: ${(e as Error).message}`;
    console.warn(`account: Apple revocation skipped, user must remove the app by hand: ${reason}`);
    return 'manual';
  }
}
