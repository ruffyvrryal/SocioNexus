-- Run this migration once in the SocioNexus Supabase SQL Editor.
-- Replace REPLACE_WITH_OWNER_EMAIL with the email of the first vault owner.

begin;

create table if not exists public.vaults (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'My Vault',
  created_by uuid not null references auth.users(id) on delete cascade,
  legacy_import_allowed boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.vaults
  add column if not exists legacy_import_allowed boolean not null default false;

create table if not exists public.vault_members (
  vault_id uuid not null references public.vaults(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('owner', 'editor', 'viewer')),
  created_at timestamptz not null default now(),
  primary key (vault_id, user_id)
);

create table if not exists public.vault_invites (
  id uuid primary key default gen_random_uuid(),
  vault_id uuid not null references public.vaults(id) on delete cascade,
  email text not null,
  role text not null check (role in ('editor', 'viewer')),
  invited_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (vault_id, email)
);

create table if not exists public.vault_niches (
  vault_id uuid not null references public.vaults(id) on delete cascade,
  niche text not null,
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (vault_id, niche)
);

create table if not exists public.viewer_locations (
  id text primary key,
  account_id text not null,
  country text not null,
  percentage numeric(5,2) not null check (percentage >= 0 and percentage <= 100)
);

alter table public.content_posts
  add column if not exists content_type text not null default 'feed';
alter table public.content_posts
  add column if not exists niche text not null default '';
alter table public.accounts
  add column if not exists vault_id uuid references public.vaults(id) on delete cascade;
alter table public.content_posts
  add column if not exists vault_id uuid references public.vaults(id) on delete cascade;
alter table public.viewer_locations
  add column if not exists vault_id uuid references public.vaults(id) on delete cascade;

do $$
declare
  bootstrap_email text := lower('ruffyprasetya@gmail.com');
  owner_id uuid;
  owner_vault_id uuid;
begin
  if bootstrap_email = 'replace_with_owner_email' then
    raise exception 'Edit this migration and replace REPLACE_WITH_OWNER_EMAIL with the first owner email before running it.';
  end if;

  select id into owner_id
  from auth.users
  where lower(email) = bootstrap_email
  order by created_at
  limit 1;

  if owner_id is null then
    raise exception 'No Supabase Auth user exists for %. Sign up that email in SocioNexus first, then run this migration.', bootstrap_email;
  end if;

  select id into owner_vault_id
  from public.vaults
  where created_by = owner_id
  order by created_at
  limit 1;

  if owner_vault_id is null then
    insert into public.vaults (name, created_by)
    values ('My Vault', owner_id)
    returning id into owner_vault_id;
  end if;

  insert into public.vault_members (vault_id, user_id, role)
  values (owner_vault_id, owner_id, 'owner')
  on conflict (vault_id, user_id) do update set role = 'owner';
  update public.vaults set legacy_import_allowed = true where id = owner_vault_id;

  -- Existing shared pre-auth data has no recorded owner. Assign it only to
  -- the explicitly configured first owner instead of exposing it to all users.
  update public.accounts set vault_id = owner_vault_id where vault_id is null;
  update public.content_posts p
  set vault_id = a.vault_id
  from public.accounts a
  where p.account_id = a.id and p.vault_id is null;
  update public.viewer_locations l
  set vault_id = a.vault_id
  from public.accounts a
  where l.account_id = a.id and l.vault_id is null;
end $$;

alter table public.accounts alter column vault_id set not null;
create index if not exists accounts_vault_id_idx on public.accounts(vault_id);
create index if not exists content_posts_vault_id_idx on public.content_posts(vault_id);
create index if not exists viewer_locations_vault_id_idx on public.viewer_locations(vault_id);
create index if not exists vault_members_user_id_idx on public.vault_members(user_id);
create index if not exists vault_invites_email_idx on public.vault_invites(lower(email));

create or replace function public.current_vault_role(target_vault_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select role
  from public.vault_members
  where vault_id = target_vault_id and user_id = auth.uid()
  limit 1
$$;

create or replace function public.has_vault_role(target_vault_id uuid, allowed_roles text[])
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.current_vault_role(target_vault_id) = any(allowed_roles), false)
$$;

create or replace function public.assign_record_vault()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  account_vault_id uuid;
begin
  select vault_id into account_vault_id
  from public.accounts
  where id = new.account_id;

  if account_vault_id is null then
    raise exception 'The account does not belong to an available vault.';
  end if;

  if new.vault_id is not null and new.vault_id <> account_vault_id then
    raise exception 'The record vault must match its account vault.';
  end if;

  new.vault_id := account_vault_id;
  return new;
end
$$;

drop trigger if exists content_posts_assign_vault on public.content_posts;
create trigger content_posts_assign_vault
before insert or update of account_id, vault_id on public.content_posts
for each row execute function public.assign_record_vault();

drop trigger if exists viewer_locations_assign_vault on public.viewer_locations;
create trigger viewer_locations_assign_vault
before insert or update of account_id, vault_id on public.viewer_locations
for each row execute function public.assign_record_vault();

create or replace function public.create_personal_vault_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  new_vault_id uuid;
begin
  insert into public.vaults (name, created_by)
  values ('My Vault', new.id)
  returning id into new_vault_id;

  insert into public.vault_members (vault_id, user_id, role)
  values (new_vault_id, new.id, 'owner');
  return new;
end
$$;

drop trigger if exists socio_create_personal_vault on auth.users;
create trigger socio_create_personal_vault
after insert on auth.users
for each row execute function public.create_personal_vault_for_new_user();

drop function if exists public.get_my_vaults();
create function public.get_my_vaults()
returns table (vault_id uuid, vault_name text, role text, legacy_import_allowed boolean)
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  current_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  if current_email <> '' then
    insert into public.vault_members as existing_member (vault_id, user_id, role)
    select i.vault_id, auth.uid(), i.role
    from public.vault_invites i
    where lower(i.email) = current_email
      and exists (
        select 1 from auth.users u
        where u.id = auth.uid() and u.email_confirmed_at is not null
      )
    on conflict (vault_id, user_id) do update
    set role = case when existing_member.role = 'owner'
      then 'owner' else excluded.role end;

    delete from public.vault_invites
    where lower(email) = current_email
      and exists (
        select 1 from auth.users u
        where u.id = auth.uid() and u.email_confirmed_at is not null
      );
  end if;

  return query
  select v.id, v.name, m.role, v.legacy_import_allowed
  from public.vault_members m
  join public.vaults v on v.id = m.vault_id
  where m.user_id = auth.uid()
  order by v.created_at, v.name;
end
$$;

create or replace function public.list_vault_members(target_vault_id uuid)
returns table (user_id uuid, email text, role text)
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if not public.has_vault_role(target_vault_id, array['owner']) then
    raise exception 'Only the vault owner can view member details.';
  end if;

  return query
  select m.user_id, u.email::text, m.role
  from public.vault_members m
  join auth.users u on u.id = m.user_id
  where m.vault_id = target_vault_id
  order by case m.role when 'owner' then 0 when 'editor' then 1 else 2 end, lower(u.email);
end
$$;

create or replace function public.list_vault_invites(target_vault_id uuid)
returns table (invite_id uuid, email text, role text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.has_vault_role(target_vault_id, array['owner']) then
    raise exception 'Only the vault owner can manage invitations.';
  end if;

  return query
  select i.id, i.email, i.role, i.created_at
  from public.vault_invites i
  where i.vault_id = target_vault_id
  order by i.created_at desc;
end
$$;

create or replace function public.invite_to_vault(target_vault_id uuid, invite_email text, invite_role text)
returns text
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  normalized_email text := lower(trim(invite_email));
  invited_user_id uuid;
begin
  if not public.has_vault_role(target_vault_id, array['owner']) then
    raise exception 'Only the vault owner can invite members.';
  end if;
  if invite_role not in ('viewer', 'editor') then
    raise exception 'Choose viewer or editor role.';
  end if;
  if normalized_email = '' or position('@' in normalized_email) < 2 then
    raise exception 'Enter a valid email address.';
  end if;
  if normalized_email = lower(coalesce(auth.jwt() ->> 'email', '')) then
    raise exception 'You already own this vault.';
  end if;

  select id into invited_user_id
  from auth.users
  where lower(email) = normalized_email and email_confirmed_at is not null
  limit 1;
  if invited_user_id is not null then
    insert into public.vault_members as existing_member (vault_id, user_id, role)
    values (target_vault_id, invited_user_id, invite_role)
    on conflict (vault_id, user_id) do update
    set role = case when existing_member.role = 'owner'
      then 'owner' else excluded.role end;
    delete from public.vault_invites where vault_id = target_vault_id and lower(email) = normalized_email;
    return 'member';
  end if;

  insert into public.vault_invites (vault_id, email, role, invited_by)
  values (target_vault_id, normalized_email, invite_role, auth.uid())
  on conflict (vault_id, email) do update set role = excluded.role, invited_by = excluded.invited_by, created_at = now();
  return 'pending';
end
$$;

create or replace function public.set_vault_member_role(target_vault_id uuid, target_user_id uuid, new_role text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.has_vault_role(target_vault_id, array['owner']) then
    raise exception 'Only the vault owner can change member roles.';
  end if;
  if new_role not in ('viewer', 'editor') then
    raise exception 'Choose viewer or editor role.';
  end if;
  update public.vault_members set role = new_role
  where vault_id = target_vault_id and user_id = target_user_id and role <> 'owner';
  if not found then raise exception 'Member was not found or the owner role cannot be changed.'; end if;
end
$$;

create or replace function public.remove_vault_member(target_vault_id uuid, target_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.has_vault_role(target_vault_id, array['owner']) then
    raise exception 'Only the vault owner can remove members.';
  end if;
  delete from public.vault_members
  where vault_id = target_vault_id and user_id = target_user_id and role <> 'owner';
  if not found then raise exception 'Member was not found or the owner cannot be removed.'; end if;
end
$$;

create or replace function public.cancel_vault_invite(target_vault_id uuid, target_invite_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.has_vault_role(target_vault_id, array['owner']) then
    raise exception 'Only the vault owner can cancel invitations.';
  end if;
  delete from public.vault_invites where id = target_invite_id and vault_id = target_vault_id;
  if not found then raise exception 'Invitation was not found.'; end if;
end
$$;

alter table public.vaults enable row level security;
alter table public.vault_members enable row level security;
alter table public.vault_invites enable row level security;
alter table public.vault_niches enable row level security;
alter table public.accounts enable row level security;
alter table public.content_posts enable row level security;
alter table public.viewer_locations enable row level security;

do $$
declare
  policy_row record;
begin
  for policy_row in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename = any(array[
        'vaults', 'vault_members', 'vault_invites', 'vault_niches',
        'accounts', 'content_posts', 'viewer_locations'
      ])
  loop
    execute format('drop policy %I on %I.%I', policy_row.policyname, policy_row.schemaname, policy_row.tablename);
  end loop;
end $$;

drop policy if exists vaults_member_select on public.vaults;
create policy vaults_member_select on public.vaults
for select to authenticated using (public.has_vault_role(id, array['owner', 'editor', 'viewer']));
drop policy if exists vaults_owner_update on public.vaults;
create policy vaults_owner_update on public.vaults
for update to authenticated using (public.has_vault_role(id, array['owner']))
with check (public.has_vault_role(id, array['owner']));

drop policy if exists vault_members_same_vault_select on public.vault_members;
create policy vault_members_same_vault_select on public.vault_members
for select to authenticated using (public.has_vault_role(vault_id, array['owner', 'editor', 'viewer']));
drop policy if exists vault_invites_owner_select on public.vault_invites;
create policy vault_invites_owner_select on public.vault_invites
for select to authenticated using (public.has_vault_role(vault_id, array['owner']));

drop policy if exists vault_niches_member_select on public.vault_niches;
create policy vault_niches_member_select on public.vault_niches
for select to authenticated using (public.has_vault_role(vault_id, array['owner', 'editor', 'viewer']));
drop policy if exists vault_niches_editor_insert on public.vault_niches;
create policy vault_niches_editor_insert on public.vault_niches
for insert to authenticated with check (
  created_by = auth.uid() and public.has_vault_role(vault_id, array['owner', 'editor'])
);
drop policy if exists vault_niches_editor_delete on public.vault_niches;
create policy vault_niches_editor_delete on public.vault_niches
for delete to authenticated using (public.has_vault_role(vault_id, array['owner', 'editor']));

drop policy if exists accounts_vault_select on public.accounts;
create policy accounts_vault_select on public.accounts
for select to authenticated using (public.has_vault_role(vault_id, array['owner', 'editor', 'viewer']));
drop policy if exists accounts_vault_insert on public.accounts;
create policy accounts_vault_insert on public.accounts
for insert to authenticated with check (public.has_vault_role(vault_id, array['owner', 'editor']));
drop policy if exists accounts_vault_update on public.accounts;
create policy accounts_vault_update on public.accounts
for update to authenticated using (public.has_vault_role(vault_id, array['owner', 'editor']))
with check (public.has_vault_role(vault_id, array['owner', 'editor']));
drop policy if exists accounts_vault_delete on public.accounts;
create policy accounts_vault_delete on public.accounts
for delete to authenticated using (public.has_vault_role(vault_id, array['owner', 'editor']));

drop policy if exists content_posts_vault_select on public.content_posts;
create policy content_posts_vault_select on public.content_posts
for select to authenticated using (public.has_vault_role(vault_id, array['owner', 'editor', 'viewer']));
drop policy if exists content_posts_vault_insert on public.content_posts;
create policy content_posts_vault_insert on public.content_posts
for insert to authenticated with check (public.has_vault_role(vault_id, array['owner', 'editor']));
drop policy if exists content_posts_vault_update on public.content_posts;
create policy content_posts_vault_update on public.content_posts
for update to authenticated using (public.has_vault_role(vault_id, array['owner', 'editor']))
with check (public.has_vault_role(vault_id, array['owner', 'editor']));
drop policy if exists content_posts_vault_delete on public.content_posts;
create policy content_posts_vault_delete on public.content_posts
for delete to authenticated using (public.has_vault_role(vault_id, array['owner', 'editor']));

drop policy if exists viewer_locations_vault_select on public.viewer_locations;
create policy viewer_locations_vault_select on public.viewer_locations
for select to authenticated using (public.has_vault_role(vault_id, array['owner', 'editor', 'viewer']));
drop policy if exists viewer_locations_vault_insert on public.viewer_locations;
create policy viewer_locations_vault_insert on public.viewer_locations
for insert to authenticated with check (public.has_vault_role(vault_id, array['owner', 'editor']));
drop policy if exists viewer_locations_vault_update on public.viewer_locations;
create policy viewer_locations_vault_update on public.viewer_locations
for update to authenticated using (public.has_vault_role(vault_id, array['owner', 'editor']))
with check (public.has_vault_role(vault_id, array['owner', 'editor']));
drop policy if exists viewer_locations_vault_delete on public.viewer_locations;
create policy viewer_locations_vault_delete on public.viewer_locations
for delete to authenticated using (public.has_vault_role(vault_id, array['owner', 'editor']));

grant select, insert, update, delete on public.vaults, public.vault_members, public.vault_invites,
  public.vault_niches, public.accounts, public.content_posts, public.viewer_locations to authenticated;
grant execute on function public.current_vault_role(uuid) to authenticated;
grant execute on function public.has_vault_role(uuid, text[]) to authenticated;
grant execute on function public.get_my_vaults() to authenticated;
grant execute on function public.list_vault_members(uuid) to authenticated;
grant execute on function public.list_vault_invites(uuid) to authenticated;
grant execute on function public.invite_to_vault(uuid, text, text) to authenticated;
grant execute on function public.set_vault_member_role(uuid, uuid, text) to authenticated;
grant execute on function public.remove_vault_member(uuid, uuid) to authenticated;
grant execute on function public.cancel_vault_invite(uuid, uuid) to authenticated;

revoke all on function public.assign_record_vault() from public, anon, authenticated;
revoke all on function public.create_personal_vault_for_new_user() from public, anon, authenticated;
revoke all on function public.current_vault_role(uuid) from public, anon;
revoke all on function public.has_vault_role(uuid, text[]) from public, anon;
revoke all on function public.get_my_vaults() from public, anon;
revoke all on function public.list_vault_members(uuid) from public, anon;
revoke all on function public.list_vault_invites(uuid) from public, anon;
revoke all on function public.invite_to_vault(uuid, text, text) from public, anon;
revoke all on function public.set_vault_member_role(uuid, uuid, text) from public, anon;
revoke all on function public.remove_vault_member(uuid, uuid) from public, anon;
revoke all on function public.cancel_vault_invite(uuid, uuid) from public, anon;

commit;
