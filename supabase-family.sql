-- "Куда ушли деньги?" - семейный облачный режим
-- Выполните файл целиком в Supabase SQL Editor.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  display_name text,
  created_at timestamptz not null default now()
);

create table if not exists public.families (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  invite_code text unique not null,
  owner_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.family_members (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('owner', 'member')),
  display_name text,
  created_at timestamptz not null default now(),
  unique (family_id, user_id),
  unique (user_id)
);

create table if not exists public.transactions (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  type text not null check (type in ('income', 'expense')),
  amount numeric not null check (amount > 0),
  date date not null,
  category text not null,
  subcategory text,
  beneficiary text default 'Общее',
  comment text,
  payment_method text,
  account text,
  tags text[] not null default '{}',
  created_by_user_id uuid references auth.users(id) on delete set null,
  created_by_name text,
  created_by_email text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  sync_status text not null default 'synced'
);

alter table public.transactions add column if not exists receipt jsonb;
alter table public.transactions add column if not exists sync_status text not null default 'synced';

create table if not exists public.category_limits (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  category text not null,
  limit_amount numeric not null default 0 check (limit_amount >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (family_id, category)
);

create table if not exists public.beneficiary_limits (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  beneficiary text not null,
  limit_amount numeric not null default 0 check (limit_amount >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (family_id, beneficiary)
);

create table if not exists public.goals (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  name text not null,
  target_amount numeric not null check (target_amount > 0),
  saved_amount numeric not null default 0 check (saved_amount >= 0),
  comment text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.family_settings (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null unique references public.families(id) on delete cascade,
  beneficiaries jsonb not null default '["Я","Жена","Сын","Кошка","Семья","Дом","Общее","Прочее"]'::jsonb,
  currency text not null default 'RUB',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists transactions_family_date_idx on public.transactions (family_id, date desc) where deleted_at is null;
create index if not exists transactions_family_beneficiary_idx on public.transactions (family_id, beneficiary) where deleted_at is null;
create index if not exists transactions_family_creator_idx on public.transactions (family_id, created_by_user_id) where deleted_at is null;
create index if not exists family_members_family_idx on public.family_members (family_id);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists transactions_set_updated_at on public.transactions;
create trigger transactions_set_updated_at before update on public.transactions
for each row execute function public.set_updated_at();

drop trigger if exists category_limits_set_updated_at on public.category_limits;
create trigger category_limits_set_updated_at before update on public.category_limits
for each row execute function public.set_updated_at();

drop trigger if exists beneficiary_limits_set_updated_at on public.beneficiary_limits;
create trigger beneficiary_limits_set_updated_at before update on public.beneficiary_limits
for each row execute function public.set_updated_at();

drop trigger if exists goals_set_updated_at on public.goals;
create trigger goals_set_updated_at before update on public.goals
for each row execute function public.set_updated_at();

drop trigger if exists family_settings_set_updated_at on public.family_settings;
create trigger family_settings_set_updated_at before update on public.family_settings
for each row execute function public.set_updated_at();

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, display_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data ->> 'display_name', split_part(new.email, '@', 1)))
  on conflict (id) do update
    set email = excluded.email,
        display_name = coalesce(public.profiles.display_name, excluded.display_name);
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert or update of email on auth.users
for each row execute function public.handle_new_user();

create or replace function public.is_family_member(check_family_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.family_members
    where family_id = check_family_id
      and user_id = auth.uid()
  );
$$;

create or replace function public.is_family_owner(check_family_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.family_members
    where family_id = check_family_id
      and user_id = auth.uid()
      and role = 'owner'
  );
$$;

create or replace function public.create_family(p_name text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_family_id uuid;
  new_invite_code text;
  member_name text;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация';
  end if;
  if nullif(trim(p_name), '') is null then
    raise exception 'Укажите название семьи';
  end if;
  if exists (select 1 from public.family_members where user_id = auth.uid()) then
    raise exception 'Пользователь уже состоит в семейной группе';
  end if;

  loop
    new_invite_code := 'FAMILY-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
    exit when not exists (select 1 from public.families where invite_code = new_invite_code);
  end loop;

  select coalesce(display_name, split_part(email, '@', 1))
  into member_name
  from public.profiles
  where id = auth.uid();

  insert into public.families (name, invite_code, owner_id)
  values (trim(p_name), new_invite_code, auth.uid())
  returning id into new_family_id;

  insert into public.family_members (family_id, user_id, role, display_name)
  values (new_family_id, auth.uid(), 'owner', member_name);

  insert into public.family_settings (family_id)
  values (new_family_id);

  return new_family_id;
end;
$$;

create or replace function public.join_family_by_code(p_invite_code text, p_display_name text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  target_family_id uuid;
  member_name text;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация';
  end if;
  if exists (select 1 from public.family_members where user_id = auth.uid()) then
    raise exception 'Пользователь уже состоит в семейной группе';
  end if;

  select id into target_family_id
  from public.families
  where invite_code = upper(trim(p_invite_code));

  if target_family_id is null then
    raise exception 'Код приглашения не найден';
  end if;

  select coalesce(nullif(trim(p_display_name), ''), display_name, split_part(email, '@', 1))
  into member_name
  from public.profiles
  where id = auth.uid();

  insert into public.family_members (family_id, user_id, role, display_name)
  values (target_family_id, auth.uid(), 'member', member_name);

  return target_family_id;
end;
$$;

revoke all on function public.create_family(text) from public;
revoke all on function public.join_family_by_code(text, text) from public;
revoke all on function public.is_family_member(uuid) from public;
revoke all on function public.is_family_owner(uuid) from public;
grant execute on function public.create_family(text) to authenticated;
grant execute on function public.join_family_by_code(text, text) to authenticated;
grant execute on function public.is_family_member(uuid) to authenticated;
grant execute on function public.is_family_owner(uuid) to authenticated;

alter table public.profiles enable row level security;
alter table public.families enable row level security;
alter table public.family_members enable row level security;
alter table public.transactions enable row level security;
alter table public.category_limits enable row level security;
alter table public.beneficiary_limits enable row level security;
alter table public.goals enable row level security;
alter table public.family_settings enable row level security;

drop policy if exists profiles_select_self on public.profiles;
create policy profiles_select_self on public.profiles for select
to authenticated using (id = auth.uid());
drop policy if exists profiles_insert_self on public.profiles;
create policy profiles_insert_self on public.profiles for insert
to authenticated with check (id = auth.uid());
drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles for update
to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists families_select_member on public.families;
create policy families_select_member on public.families for select
to authenticated using (owner_id = auth.uid() or public.is_family_member(id));
drop policy if exists families_insert_owner on public.families;
create policy families_insert_owner on public.families for insert
to authenticated with check (owner_id = auth.uid());
drop policy if exists families_update_owner on public.families;
create policy families_update_owner on public.families for update
to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());
drop policy if exists families_delete_owner on public.families;
create policy families_delete_owner on public.families for delete
to authenticated using (owner_id = auth.uid());

drop policy if exists family_members_select_family on public.family_members;
create policy family_members_select_family on public.family_members for select
to authenticated using (public.is_family_member(family_id));
drop policy if exists family_members_insert_owner on public.family_members;
drop policy if exists family_members_update_owner_or_self on public.family_members;
drop policy if exists family_members_update_owner on public.family_members;
create policy family_members_update_owner on public.family_members for update
to authenticated using (public.is_family_owner(family_id))
with check (public.is_family_owner(family_id));
drop policy if exists family_members_update_self on public.family_members;
create policy family_members_update_self on public.family_members for update
to authenticated using (user_id = auth.uid() and role = 'member')
with check (user_id = auth.uid() and role = 'member' and public.is_family_member(family_id));
drop policy if exists family_members_delete_owner_or_self on public.family_members;
create policy family_members_delete_owner_or_self on public.family_members for delete
to authenticated using (public.is_family_owner(family_id) or user_id = auth.uid());

drop policy if exists transactions_select_family on public.transactions;
create policy transactions_select_family on public.transactions for select
to authenticated using (public.is_family_member(family_id));
drop policy if exists transactions_insert_family on public.transactions;
create policy transactions_insert_family on public.transactions for insert
to authenticated with check (public.is_family_member(family_id) and created_by_user_id = auth.uid());
drop policy if exists transactions_update_family on public.transactions;
create policy transactions_update_family on public.transactions for update
to authenticated using (public.is_family_member(family_id))
with check (public.is_family_member(family_id));
drop policy if exists transactions_delete_family on public.transactions;
create policy transactions_delete_family on public.transactions for delete
to authenticated using (public.is_family_member(family_id));

drop policy if exists category_limits_family_all on public.category_limits;
create policy category_limits_family_all on public.category_limits for all
to authenticated using (public.is_family_member(family_id))
with check (public.is_family_member(family_id));

drop policy if exists beneficiary_limits_family_all on public.beneficiary_limits;
create policy beneficiary_limits_family_all on public.beneficiary_limits for all
to authenticated using (public.is_family_member(family_id))
with check (public.is_family_member(family_id));

drop policy if exists goals_family_all on public.goals;
create policy goals_family_all on public.goals for all
to authenticated using (public.is_family_member(family_id))
with check (public.is_family_member(family_id));

drop policy if exists family_settings_family_all on public.family_settings;
create policy family_settings_family_all on public.family_settings for all
to authenticated using (public.is_family_member(family_id))
with check (public.is_family_member(family_id));

grant select, insert, update, delete on public.profiles to authenticated;
grant select, insert, update, delete on public.families to authenticated;
grant select, insert, update, delete on public.family_members to authenticated;
grant select, insert, update, delete on public.transactions to authenticated;
grant select, insert, update, delete on public.category_limits to authenticated;
grant select, insert, update, delete on public.beneficiary_limits to authenticated;
grant select, insert, update, delete on public.goals to authenticated;
grant select, insert, update, delete on public.family_settings to authenticated;

-- Realtime для автоматического обновления семейных данных на втором устройстве.
-- Replica identity full сохраняет идентификатор строки в событиях DELETE.
alter table public.transactions replica identity full;
alter table public.category_limits replica identity full;
alter table public.beneficiary_limits replica identity full;
alter table public.goals replica identity full;
alter table public.family_settings replica identity full;

do $$
declare
  realtime_table text;
begin
  foreach realtime_table in array array[
    'transactions',
    'category_limits',
    'beneficiary_limits',
    'goals',
    'family_settings'
  ]
  loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', realtime_table);
    exception
      when duplicate_object then null;
    end;
  end loop;
end;
$$;
