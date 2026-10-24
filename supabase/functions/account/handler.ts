// POST /functions/v1/account/delete {"apple_authorization_code"?: string}
// Deletes the signed-in user's account for good, with the app's own session token only.
// 200 {"deleted": true, "household": "kept" | "deleted" | "none",
//      "apple": "revoked" | "not_linked" | "manual"}
// Errors are {"error", "message"}.
import { AuthError } from '../_shared/auth.ts';
import type { HouseholdFate } from '../_shared/db.ts';
import { json, preflight } from '../_shared/http.ts';
import type { AppleRevocation } from './apple.ts';

export type AppleFate = AppleRevocation | 'not_linked';

export type Deleted = { deleted: true; household: HouseholdFate; apple: AppleFate };

export interface Deps {
  /** The session's user; throws an AuthError when it can't. */
  authenticate(req: Request): Promise<{ userId: string }>;
  /** The Apple user id when the account has a Sign in with Apple identity. */
  appleSubject(userId: string): Promise<string | null>;
  revokeApple(grant: { code: string | null; subject: string }): Promise<AppleRevocation>;
  deleteAccount(userId: string): Promise<HouseholdFate>;
}

const failures = {
  not_found: [404, 'Unbekannte Adresse.'],
  method: [405, 'Bitte per POST.'],
  bad_request: [400, 'Der Inhalt ist kein gültiges JSON {"apple_authorization_code"?: string}.'],
  server: [500, 'Das Konto konnte nicht gelöscht werden. Bitte versuch es gleich noch einmal.'],
} as const satisfies Record<string, readonly [number, string]>;

const fail = (error: keyof typeof failures | AuthError) => {
  if (error instanceof AuthError) {
    return json({ error: error.reason, message: error.message }, {
      status: error.status,
      headers: error.status === 401 ? { 'www-authenticate': 'Bearer' } : {},
    });
  }
  const [status, message] = failures[error];
  return json({ error, message }, { status });
};

/** The optional Apple code, or null for a body that is not the documented shape. */
async function readBody(req: Request): Promise<{ appleCode: string | null } | null> {
  const raw = await req.text();
  if (!raw.trim()) return { appleCode: null };
  try {
    const body: unknown = JSON.parse(raw);
    if (typeof body !== 'object' || body === null || Array.isArray(body)) return null;
    const code: unknown = (body as Record<string, unknown>).apple_authorization_code;
    if (code === undefined || code === null) return { appleCode: null };
    return typeof code === 'string' ? { appleCode: code || null } : null;
  } catch {
    return null;
  }
}

export function createHandler(deps: Deps) {
  return async (req: Request): Promise<Response> => {
    const early = preflight(req);
    if (early) return early;
    if (!new URL(req.url).pathname.endsWith('/account/delete')) return fail('not_found');
    if (req.method !== 'POST') {
      const res = fail('method');
      res.headers.set('allow', 'POST, OPTIONS');
      return res;
    }

    let userId: string;
    try {
      ({ userId } = await deps.authenticate(req));
    } catch (e) {
      // The first call deleted the account but its answer never arrived.
      if (e instanceof AuthError && e.reason === 'user_deleted') {
        return json({ deleted: true, household: 'none', apple: 'not_linked' } satisfies Deleted);
      }
      if (e instanceof AuthError) return fail(e);
      console.error('account: authenticate failed', e);
      return fail('server');
    }

    const body = await readBody(req);
    if (!body) return fail('bad_request');

    try {
      // Revoke first: once the identity row is gone there is no Apple user id to check against.
      const subject = await deps.appleSubject(userId);
      const apple: AppleFate = subject
        ? await deps.revokeApple({ code: body.appleCode, subject })
        : 'not_linked';
      const household = await deps.deleteAccount(userId);
      return json({ deleted: true, household, apple } satisfies Deleted);
    } catch (e) {
      console.error('account: deletion failed', e);
      return fail('server');
    }
  };
}
