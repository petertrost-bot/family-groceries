import { authenticateSession } from '../_shared/auth.ts';
import { appleSubject, deleteAccount } from '../_shared/db.ts';
import { appleConfig, revokeAppleGrant } from './apple.ts';
import { createHandler } from './handler.ts';

Deno.serve(createHandler({
  authenticate: (req) => authenticateSession(req),
  appleSubject,
  revokeApple: (grant) => revokeAppleGrant(grant, appleConfig()),
  deleteAccount,
}));
