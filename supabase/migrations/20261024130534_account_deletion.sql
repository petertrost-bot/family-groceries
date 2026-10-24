-- Account deletion (App Store 5.1.1(v), Google Play account deletion) and the data export.

-- Deleting a user sets items.added_by and items.bought_by to null through their foreign keys.
-- That set-null is an UPDATE, which items_before_write used to answer by restoring added_by,
-- so the foreign key failed and no user who had ever added an item could be deleted, by any
-- path. The trigger now lets a reference to a deleted user go, without touching updated_at.
-- Security definer: it reads auth.users, which clients cannot.
create or replace function public.items_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE'
     and (to_jsonb(new) - '{added_by,bought_by}'::text[]) = (to_jsonb(old) - '{added_by,bought_by}'::text[])
     and (new.added_by, new.bought_by) is distinct from (old.added_by, old.bought_by)
     and (new.added_by is not distinct from old.added_by
          or (new.added_by is null and not exists (select from auth.users u where u.id = old.added_by)))
     and (new.bought_by is not distinct from old.bought_by
          or (new.bought_by is null and not exists (select from auth.users u where u.id = old.bought_by)))
  then
    return new;
  end if;
  new.name := btrim(new.name);
  new.quantity := nullif(btrim(new.quantity), '');
  new.normalized_name := public.normalize_item_name(new.name);
  if new.category_id is null then
    new.category_id := public.classify_item(new.household_id, new.name);
  end if;
  if tg_op = 'INSERT' and new.store_id is null then
    new.store_id := public.suggest_store(new.household_id, new.name);
  end if;
  if tg_op = 'UPDATE' then
    new.created_at := old.created_at;
    new.added_by := old.added_by;
    new.updated_at := now();
  end if;
  if new.status = 'bought' and (tg_op = 'INSERT' or old.status is distinct from 'bought') then
    new.bought_at := now();
    new.bought_by := auth.uid();
  elsif new.status = 'active' then
    new.bought_at := null;
    new.bought_by := null;
  end if;
  return new;
end $$;

-- History records what happened to an item; an update that changes none of what the list
-- shows (a retried edit, a deleted author's set-null) is not an edit.
create or replace function public.items_log_event() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_row public.items := case when tg_op = 'DELETE' then old else new end;
  v_action text;
begin
  -- A household delete cascades to its items; its history goes with it.
  if tg_op = 'DELETE' and not exists (select 1 from public.households where id = old.household_id) then
    return null;
  end if;
  if tg_op = 'UPDATE'
     and (new.name, new.quantity, new.category_id, new.store_id, new.status)
         is not distinct from (old.name, old.quantity, old.category_id, old.store_id, old.status) then
    return null;
  end if;
  v_action := case
    when tg_op = 'INSERT' then 'added'
    when tg_op = 'DELETE' then 'deleted'
    when new.status = 'bought' and old.status = 'active' then 'bought'
    when new.status = 'active' and old.status = 'bought' then 'restored'
    else 'edited'
  end;
  insert into public.item_events (household_id, item_id, action, item_name, category_id)
  values (v_row.household_id, v_row.id, v_action, v_row.name, v_row.category_id);
  return null;
end $$;

-- Deletes a user for good. Returns what became of their household:
--   'kept'    other members remain; ownership passes to the longest-standing one;
--   'deleted' they were the last member; the household and all its data are gone;
--   'none'    they had no household, or the user does not exist (a repeated call).
-- The household's history stays for the others, without the author. Everything else the
-- user owns (profile, membership, tokens, sessions, identities, OAuth grants) cascades from
-- auth.users. Called by the account edge function with the service connection.
create function public.delete_account(p_user uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_household uuid;
  v_role text;
  v_fate text := 'none';
begin
  -- The household row lock serializes with join_household (its membership insert takes a key
  -- share lock on the household) and with another member deleting their account at once.
  select h.id into v_household
  from public.households h
  join public.household_members m on m.household_id = h.id
  where m.user_id = p_user
  for update of h;

  if v_household is not null then
    select m.role into v_role
    from public.household_members m
    where m.user_id = p_user and m.household_id = v_household;

    if exists (
      select from public.household_members m
      where m.household_id = v_household and m.user_id <> p_user
    ) then
      v_fate := 'kept';
      if v_role = 'owner' then
        update public.household_members set role = 'owner'
        where household_id = v_household
          and user_id = (
            select m.user_id from public.household_members m
            where m.household_id = v_household and m.user_id <> p_user
            order by m.joined_at, m.user_id
            limit 1
          );
      end if;
    else
      v_fate := 'deleted';
      delete from public.households where id = v_household;
    end if;
  end if;

  update public.item_events set actor = null where actor = p_user;
  delete from auth.users where id = p_user;
  return v_fate;
end $$;

revoke execute on function public.delete_account(uuid) from public, anon, authenticated;
grant execute on function public.delete_account(uuid) to service_role;

-- Everything the app stores about the signed-in user, for "Meine Daten exportieren" (GDPR
-- Art. 15 and 20). Other members' personal data is left out. The shape is a stable contract:
-- {
--   "format": "family-groceries-export", "version": 1, "exported_at": timestamptz,
--   "account": {id, email, created_at, last_sign_in_at, providers: [text]},
--   "profile": {display_name, created_at},
--   "household": null | {id, name, role, joined_at},
--   "items_added": [{name, quantity, status, category, store, created_at, bought_at}],
--   "history": [{action, item_name, category, created_at}],
--   "access_tokens": [{name, token_hint, created_at, last_used_at, revoked_at}],
--   "connected_apps": [{client_name, scopes, granted_at, revoked_at}]
-- }
-- items_added: items in the current household the user added. history: item events the user
-- caused, in any household that still exists. Token hashes are never exported.
create function public.export_my_data() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  -- An app connected over OAuth (MCP) acts on the list, not on the account.
  if auth.jwt() ->> 'client_id' is not null then
    raise exception 'session_required' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'format', 'family-groceries-export',
    'version', 1,
    'exported_at', now(),
    'account', (
      select jsonb_build_object(
        'id', u.id,
        'email', u.email,
        'created_at', u.created_at,
        'last_sign_in_at', u.last_sign_in_at,
        'providers', coalesce(
          (select jsonb_agg(distinct i.provider) from auth.identities i where i.user_id = u.id),
          '[]'::jsonb
        )
      )
      from auth.users u where u.id = v_user
    ),
    'profile', (
      select jsonb_build_object('display_name', p.display_name, 'created_at', p.created_at)
      from public.profiles p where p.id = v_user
    ),
    'household', (
      select jsonb_build_object('id', h.id, 'name', h.name, 'role', m.role, 'joined_at', m.joined_at)
      from public.household_members m
      join public.households h on h.id = m.household_id
      where m.user_id = v_user
    ),
    'items_added', coalesce((
      select jsonb_agg(jsonb_build_object(
        'name', i.name,
        'quantity', i.quantity,
        'status', i.status,
        'category', c.name,
        'store', s.name,
        'created_at', i.created_at,
        'bought_at', i.bought_at
      ) order by i.created_at, i.id)
      from public.items i
      join public.household_members m on m.household_id = i.household_id and m.user_id = v_user
      left join public.categories c on c.id = i.category_id
      left join public.stores s on s.id = i.store_id
      where i.added_by = v_user
    ), '[]'::jsonb),
    'history', coalesce((
      select jsonb_agg(jsonb_build_object(
        'action', e.action,
        'item_name', e.item_name,
        'category', c.name,
        'created_at', e.created_at
      ) order by e.created_at, e.id)
      from public.item_events e
      left join public.categories c on c.id = e.category_id
      where e.actor = v_user
    ), '[]'::jsonb),
    'access_tokens', coalesce((
      select jsonb_agg(jsonb_build_object(
        'name', t.name,
        'token_hint', t.token_hint,
        'created_at', t.created_at,
        'last_used_at', t.last_used_at,
        'revoked_at', t.revoked_at
      ) order by t.created_at, t.id)
      from public.personal_access_tokens t
      where t.user_id = v_user
    ), '[]'::jsonb),
    'connected_apps', coalesce((
      select jsonb_agg(jsonb_build_object(
        'client_name', oc.client_name,
        'scopes', c.scopes,
        'granted_at', c.granted_at,
        'revoked_at', c.revoked_at
      ) order by c.granted_at, c.id)
      from auth.oauth_consents c
      join auth.oauth_clients oc on oc.id = c.client_id
      where c.user_id = v_user
    ), '[]'::jsonb)
  );
end $$;

revoke execute on function public.export_my_data() from public, anon, service_role;
grant execute on function public.export_my_data() to authenticated;
