begin;
select plan(36);

create function pg_temp.login(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
end $$;

create function pg_temp.as_postgres() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end $$;

create function pg_temp.hash(token text) returns text language sql as $$
  select encode(extensions.digest(token, 'sha256'), 'hex');
$$;

-- Rows per household-owned table; every table that carries household_id is listed.
create function pg_temp.household_rows(p_household uuid) returns table (tbl text, n int)
language sql as $$
  select 'households', count(*)::int from public.households where id = p_household
  union all select 'household_members', count(*)::int from public.household_members where household_id = p_household
  union all select 'invites', count(*)::int from public.invites where household_id = p_household
  union all select 'categories', count(*)::int from public.categories where household_id = p_household
  union all select 'stores', count(*)::int from public.stores where household_id = p_household
  union all select 'store_category_order', count(*)::int from public.store_category_order where household_id = p_household
  union all select 'items', count(*)::int from public.items where household_id = p_household
  union all select 'item_events', count(*)::int from public.item_events where household_id = p_household
  union all select 'category_memory', count(*)::int from public.category_memory where household_id = p_household
  union all select 'item_store_memory', count(*)::int from public.item_store_memory where household_id = p_household
  union all select 'personal_access_tokens', count(*)::int from public.personal_access_tokens where household_id = p_household;
$$;

select is(
  (select array_agg(c.relname::text order by c.relname)
   from pg_attribute a join pg_class c on c.oid = a.attrelid join pg_namespace s on s.oid = c.relnamespace
   where s.nspname = 'public' and c.relkind = 'r' and a.attname = 'household_id' and not a.attisdropped),
  (select array_agg(tbl order by tbl) from pg_temp.household_rows(null) where tbl <> 'households'),
  'household_rows covers every household-owned table'
);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'alice@example.com'),
  ('00000000-0000-0000-0000-0000000000b1', 'bob@example.com'),
  ('00000000-0000-0000-0000-0000000000c1', 'carl@example.com'),
  ('00000000-0000-0000-0000-0000000000d1', 'dora@example.com'),
  ('00000000-0000-0000-0000-0000000000e1', 'emil@example.com'),
  ('00000000-0000-0000-0000-0000000000f1', 'frida@example.com');

-- Alice owns the household; Carl joined before Bob.
select pg_temp.login('00000000-0000-0000-0000-0000000000a1');
create temp table h as select id from public.create_household('WG');
create temp table inv as select code from public.create_invite((select id from h));
create temp table pat_a as select token from public.create_personal_access_token('Siri');
grant select on h, inv, pat_a to authenticated;
insert into public.items (household_id, name) select id, 'Milch' from h;
insert into public.items (household_id, name) select id, 'Kaffee' from h;
update public.items set status = 'bought' where name = 'Kaffee';
select pg_temp.login('00000000-0000-0000-0000-0000000000c1');
select public.join_household((select code from inv));
select pg_temp.login('00000000-0000-0000-0000-0000000000b1');
select public.join_household((select code from inv));
insert into public.items (household_id, name) select id, 'Brot' from h;
update public.items set status = 'bought' where name = 'Milch';
update public.items set added_by = null where name = 'Milch';
select is((select added_by from public.items where name = 'Milch'),
  '00000000-0000-0000-0000-0000000000a1'::uuid, 'a client cannot clear who added an item');

select pg_temp.as_postgres();
update public.household_members set joined_at = now() - interval '2 days'
where user_id = '00000000-0000-0000-0000-0000000000c1';
update public.household_members set joined_at = now() - interval '1 day'
where user_id = '00000000-0000-0000-0000-0000000000b1';
-- Backdate without triggers so a bump of updated_at is visible inside this transaction.
set local session_replication_role = replica;
update public.items set updated_at = updated_at - interval '1 hour';
set local session_replication_role = origin;
create temp table items_before as select id, updated_at from public.items;
create temp table events_before as select count(*)::int as n from public.item_events;
grant select on items_before, events_before to authenticated;

select pg_temp.login('00000000-0000-0000-0000-0000000000b1');
select throws_ok(
  $$ select public.delete_account('00000000-0000-0000-0000-0000000000a1') $$,
  '42501', null, 'a signed-in user cannot delete an account, not even someone else''s'
);
select pg_temp.login('00000000-0000-0000-0000-0000000000a1');
select throws_ok(
  $$ select public.delete_account(auth.uid()) $$,
  '42501', null, 'nor their own through the API; only the edge function can'
);

-- A member deletes the account: the owner, who added items and bought one.
select pg_temp.as_postgres();
select is(public.delete_account('00000000-0000-0000-0000-0000000000a1'), 'kept',
  'the household stays while others remain');
select is(
  (select user_id from public.household_members where household_id = (select id from h) and role = 'owner'),
  '00000000-0000-0000-0000-0000000000c1'::uuid,
  'ownership passes to the longest-standing member'
);
select is((select count(*)::int from public.household_members where household_id = (select id from h)), 2,
  'the other members stay');
select is((select count(*)::int from auth.users where id = '00000000-0000-0000-0000-0000000000a1'), 0,
  'the user is gone');
select is((select count(*)::int from public.profiles where id = '00000000-0000-0000-0000-0000000000a1'), 0,
  'and so is their profile');
select results_eq(
  $$ select name, added_by from public.items order by name $$,
  $$ values ('Brot', '00000000-0000-0000-0000-0000000000b1'::uuid), ('Kaffee', null), ('Milch', null) $$,
  'their items stay for the household, without an author'
);
select is((select bought_by from public.items where name = 'Kaffee'), null, 'and without a buyer');
select is(
  (select count(*)::int from public.items i join items_before b using (id) where i.updated_at <> b.updated_at),
  0, 'losing the author does not touch updated_at'
);
select is((select count(*)::int from public.item_events), (select n from events_before),
  'and writes no history');
select is(
  (select count(*)::int from public.item_events where actor = '00000000-0000-0000-0000-0000000000a1'),
  0, 'the history keeps their events without the author'
);
select isnt_empty(
  $$ select from public.item_events where actor is null and item_name = 'Kaffee' and action = 'bought' $$,
  'the history itself stays'
);
select is_empty(
  $$ select * from public.authenticate_personal_access_token(pg_temp.hash((select token from pat_a))) $$,
  'their tokens stop working'
);
select is(public.delete_account('00000000-0000-0000-0000-0000000000a1'), 'none',
  'deleting again changes nothing');

select pg_temp.login('00000000-0000-0000-0000-0000000000b1');
select results_eq(
  $$ select name from public.items order by name $$,
  $$ values ('Brot'), ('Kaffee'), ('Milch') $$,
  'the remaining members still see the list'
);
update public.items set quantity = '2' where name = 'Kaffee';
insert into public.items (household_id, name) select id, 'Eier' from h;
select is((select count(*)::int from public.items where quantity = '2' or name = 'Eier'), 2,
  'and still change it');
select is(
  (select added_by from public.items where name = 'Kaffee'), null,
  'an edit does not claim an orphaned item'
);
update public.items set added_by = auth.uid() where name = 'Milch';
select is((select added_by from public.items where name = 'Milch'), null,
  'clients still cannot change who added an item');
select is(
  (select action from public.item_events where item_name = 'Kaffee' order by id desc limit 1), 'edited',
  'real edits are still history'
);

-- The dashboard and the admin API delete straight from auth.users.
select pg_temp.as_postgres();
select lives_ok(
  $$ delete from auth.users where id = '00000000-0000-0000-0000-0000000000b1' $$,
  'a user who added and bought items can be deleted directly'
);
select results_eq(
  $$ select count(*)::int from public.items where added_by is not null or bought_by is not null $$,
  $$ values (0) $$,
  'which leaves their items without author and buyer'
);

-- The last member: Carl, now the owner, with learned memories and a token.
select pg_temp.login('00000000-0000-0000-0000-0000000000c1');
create temp table pat_c as select token from public.create_personal_access_token('MCP');
grant select on pat_c to authenticated;
update public.items
set category_id = (select id from public.categories where household_id = (select id from h) and seed_key = 'drinks'),
    store_id = (select id from public.stores where household_id = (select id from h) and seed_key = 'lidl')
where name = 'Brot';
select pg_temp.as_postgres();
select is(
  (select array_agg(tbl order by tbl) from pg_temp.household_rows((select id from h)) where n = 0),
  null, 'before: every household table has rows'
);
select is(public.delete_account('00000000-0000-0000-0000-0000000000c1'), 'deleted',
  'the last member takes the household with them');
select is(
  (select array_agg(tbl order by tbl) from pg_temp.household_rows((select id from h)) where n > 0),
  null, 'after: no household table has a row left'
);
select is_empty(
  $$ select * from public.authenticate_personal_access_token(pg_temp.hash((select token from pat_c))) $$,
  'the last member''s tokens stop working'
);

select is(public.delete_account('00000000-0000-0000-0000-0000000000d1'), 'none',
  'a user without a household is deleted too');
select is((select count(*)::int from auth.users where id = '00000000-0000-0000-0000-0000000000d1'), 0,
  'and is gone');
select is(public.delete_account('00000000-0000-0000-0000-00000000dead'), 'none',
  'an unknown user returns none');

-- Export: Emil and Frida share a household; Emil connected an app.
select pg_temp.login('00000000-0000-0000-0000-0000000000e1');
create temp table he as select id from public.create_household('Emil & Frida');
create temp table inv_e as select code from public.create_invite((select id from he));
grant select on he, inv_e to authenticated;
select public.create_personal_access_token('Kurzbefehl');
insert into public.items (household_id, name, quantity) select id, 'Äpfel', '1 kg' from he;
select pg_temp.login('00000000-0000-0000-0000-0000000000f1');
select public.join_household((select code from inv_e));
insert into public.items (household_id, name) select id, 'Fridas Geheimnis' from he;
select pg_temp.as_postgres();
insert into auth.oauth_clients (id, registration_type, redirect_uris, grant_types, client_name, client_type, token_endpoint_auth_method)
values ('00000000-0000-0000-0000-00000000c11e', 'dynamic', 'https://claude.ai/cb', 'authorization_code', 'Claude', 'public', 'none');
insert into auth.oauth_consents (id, user_id, client_id, scopes)
values (gen_random_uuid(), '00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-00000000c11e', 'openid email');

create temp table emil as select created_at from auth.users where email = 'emil@example.com';
grant select on emil to authenticated;
select pg_temp.login('00000000-0000-0000-0000-0000000000e1');
create temp table export as select public.export_my_data() as doc;
select is(
  (select array_agg(k order by k) from export, jsonb_object_keys(doc) k),
  array['access_tokens', 'account', 'connected_apps', 'exported_at', 'format', 'history', 'household',
        'items_added', 'profile', 'version'],
  'the export has the documented sections'
);
select is(
  (select doc - 'exported_at' from export),
  jsonb_build_object(
    'format', 'family-groceries-export',
    'version', 1,
    'account', jsonb_build_object('id', '00000000-0000-0000-0000-0000000000e1', 'email', 'emil@example.com',
      'created_at', (select created_at from emil),
      'last_sign_in_at', null, 'providers', '[]'::jsonb),
    'profile', jsonb_build_object('display_name', 'emil', 'created_at', now()),
    'household', jsonb_build_object('id', (select id from he), 'name', 'Emil & Frida', 'role', 'owner', 'joined_at', now()),
    'items_added', jsonb_build_array(jsonb_build_object('name', 'Äpfel', 'quantity', '1 kg', 'status', 'active',
      'category', 'Obst & Gemüse', 'store', null, 'created_at', now(), 'bought_at', null)),
    'history', jsonb_build_array(jsonb_build_object('action', 'added', 'item_name', 'Äpfel',
      'category', 'Obst & Gemüse', 'created_at', now())),
    'access_tokens', jsonb_build_array(jsonb_build_object('name', 'Kurzbefehl',
      'token_hint', (select token_hint from public.personal_access_tokens where name = 'Kurzbefehl'),
      'created_at', now(), 'last_used_at', null, 'revoked_at', null)),
    'connected_apps', jsonb_build_array(jsonb_build_object('client_name', 'Claude', 'scopes', 'openid email',
      'granted_at', now(), 'revoked_at', null))
  ),
  'the export holds the user''s own data and nothing of the other member''s'
);
select ok(
  (select doc::text !~ '[0-9a-f]{64}' and doc::text !~* 'hash' from export),
  'the export carries no token hashes'
);

select set_config('request.jwt.claims', json_build_object(
  'sub', '00000000-0000-0000-0000-0000000000e1', 'role', 'authenticated',
  'client_id', '00000000-0000-0000-0000-00000000c11e')::text, true);
select throws_ok(
  $$ select public.export_my_data() $$,
  '42501', 'session_required', 'an app connected over OAuth cannot export the account'
);
select set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
select throws_ok(
  $$ select public.export_my_data() $$,
  '28000', 'not_authenticated', 'export needs a user'
);

select * from finish();
rollback;
