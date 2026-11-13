-- Joint boards: shared boards, members and email invites. Already applied to the live project.
-- Members are never deleted. Leaving sets left_at, so a person can be invited back later.

create table public.shared_boards (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'Household' check (char_length(name) between 1 and 40),
  owner uuid not null references auth.users(id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create table public.board_members (
  board_id uuid not null references public.shared_boards(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('owner','member')),
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  primary key (board_id, user_id)
);
create index board_members_user_idx on public.board_members(user_id);
create table public.board_invites (
  id uuid primary key default gen_random_uuid(),
  board_id uuid not null references public.shared_boards(id) on delete cascade,
  email text not null,
  invited_by uuid not null references auth.users(id) on delete cascade,
  inviter_email text,
  status text not null default 'pending' check (status in ('pending','accepted','declined','cancelled')),
  created_at timestamptz not null default now()
);
create index board_invites_email_idx on public.board_invites(lower(email)) where status='pending';
create index board_invites_board_idx on public.board_invites(board_id);
alter table public.shared_boards enable row level security;
alter table public.board_members enable row level security;
alter table public.board_invites enable row level security;

create or replace function public.is_board_member(b uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.board_members m where m.board_id = b and m.user_id = (select auth.uid()) and m.left_at is null);
$$;

create policy "Members read board" on public.shared_boards for select to authenticated using (public.is_board_member(id));
create policy "Members update board" on public.shared_boards for update to authenticated using (public.is_board_member(id)) with check (public.is_board_member(id));
create policy "Members see members" on public.board_members for select to authenticated using (public.is_board_member(board_id));
create policy "Members see invites" on public.board_invites for select to authenticated using (public.is_board_member(board_id));
grant select, update on public.shared_boards to authenticated;
grant select on public.board_members, public.board_invites to authenticated;

create or replace function public.my_email() returns text
language sql stable security definer set search_path = '' as $$
  select lower(email) from auth.users where id = (select auth.uid());
$$;

create or replace function public.create_shared_board(p_name text, p_data jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v uuid; me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in first'; end if;
  if (select count(*) from public.board_members where user_id = me and left_at is null) >= 10 then raise exception 'You are already on 10 joint boards'; end if;
  insert into public.shared_boards(name, owner, data) values (coalesce(nullif(trim(p_name),''),'Household'), me, coalesce(p_data,'{}'::jsonb)) returning id into v;
  insert into public.board_members(board_id, user_id, role) values (v, me, 'owner');
  return v;
end $$;

create or replace function public.my_boards() returns table(id uuid, name text, role text, members int, updated_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select b.id, b.name, m.role, (select count(*)::int from public.board_members x where x.board_id = b.id and x.left_at is null), b.updated_at
  from public.board_members m join public.shared_boards b on b.id = m.board_id
  where m.user_id = (select auth.uid()) and m.left_at is null order by b.created_at;
$$;

create or replace function public.board_people(p_board uuid) returns table(user_id uuid, email text, role text, me boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_board_member(p_board) then raise exception 'Not a member of this board'; end if;
  return query select m.user_id, u.email::text, m.role, m.user_id = auth.uid()
    from public.board_members m join auth.users u on u.id = m.user_id where m.board_id = p_board and m.left_at is null order by m.joined_at;
end $$;

create or replace function public.invite_to_board(p_board uuid, p_email text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v uuid; em text := lower(trim(p_email));
begin
  if not public.is_board_member(p_board) then raise exception 'Not a member of this board'; end if;
  if em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That email does not look right'; end if;
  if em = public.my_email() then raise exception 'You are already on this board'; end if;
  if exists(select 1 from public.board_members m join auth.users u on u.id = m.user_id where m.board_id = p_board and m.left_at is null and lower(u.email) = em) then raise exception 'They are already on this board'; end if;
  if exists(select 1 from public.board_invites where board_id = p_board and lower(email) = em and status = 'pending') then raise exception 'They already have an invite waiting'; end if;
  if (select count(*) from public.board_invites where invited_by = auth.uid() and created_at > now() - interval '1 day') >= 20 then raise exception 'Too many invites today. Try again tomorrow'; end if;
  insert into public.board_invites(board_id, email, invited_by, inviter_email) values (p_board, em, auth.uid(), public.my_email()) returning id into v;
  return v;
end $$;

create or replace function public.my_invites() returns table(id uuid, board_id uuid, board_name text, inviter_email text, created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select i.id, i.board_id, b.name, i.inviter_email, i.created_at
  from public.board_invites i join public.shared_boards b on b.id = i.board_id
  where i.status = 'pending' and lower(i.email) = public.my_email() and not public.is_board_member(i.board_id)
  order by i.created_at desc;
$$;

create or replace function public.answer_invite(p_invite uuid, p_accept boolean) returns uuid
language plpgsql security definer set search_path = '' as $$
declare inv public.board_invites;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into inv from public.board_invites where id = p_invite and status = 'pending' and lower(email) = public.my_email() for update;
  if not found then raise exception 'That invite is no longer available'; end if;
  if not exists(select 1 from auth.users where id = auth.uid() and email_confirmed_at is not null) then raise exception 'Confirm your email first'; end if;
  if p_accept then
    if not exists(select 1 from public.board_members where board_id = inv.board_id and left_at is null) then raise exception 'That board no longer exists'; end if;
    insert into public.board_members(board_id, user_id, role) values (inv.board_id, auth.uid(), 'member')
      on conflict (board_id, user_id) do update set left_at = null, role = 'member', joined_at = now();
    update public.board_invites set status = 'accepted' where id = inv.id;
    update public.board_invites set status = 'cancelled' where board_id = inv.board_id and lower(email) = lower(inv.email) and status = 'pending';
    return inv.board_id;
  end if;
  update public.board_invites set status = 'declined' where id = inv.id;
  return null;
end $$;

create or replace function public.cancel_invite(p_invite uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.board_invites i set status = 'cancelled' where i.id = p_invite and i.status = 'pending' and public.is_board_member(i.board_id);
end $$;

create or replace function public.rename_board(p_board uuid, p_name text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_board_member(p_board) then raise exception 'Not a member of this board'; end if;
  update public.shared_boards set name = left(coalesce(nullif(trim(p_name),''),'Household'),40) where id = p_board;
end $$;

create or replace function public.leave_board(p_board uuid, p_user uuid default null) returns void
language plpgsql security definer set search_path = '' as $$
declare target uuid := coalesce(p_user, auth.uid()); r text; nxt uuid;
begin
  select role into r from public.board_members where board_id = p_board and user_id = auth.uid() and left_at is null;
  if r is null then raise exception 'Not a member of this board'; end if;
  if target <> auth.uid() and r <> 'owner' then raise exception 'Only the owner can remove people'; end if;
  update public.board_members set left_at = now(), role = 'member' where board_id = p_board and user_id = target and left_at is null;
  if not exists(select 1 from public.board_members where board_id = p_board and left_at is null) then
    update public.shared_boards set data = '{}'::jsonb, updated_at = now() where id = p_board;
    update public.board_invites set status = 'cancelled' where board_id = p_board and status = 'pending';
    return;
  end if;
  if not exists(select 1 from public.board_members where board_id = p_board and role = 'owner' and left_at is null) then
    select user_id into nxt from public.board_members where board_id = p_board and left_at is null order by joined_at limit 1;
    update public.board_members set role = 'owner' where board_id = p_board and user_id = nxt;
    update public.shared_boards set owner = nxt where id = p_board;
  end if;
end $$;

revoke execute on function public.is_board_member(uuid), public.my_email(), public.create_shared_board(text,jsonb), public.my_boards(), public.board_people(uuid), public.invite_to_board(uuid,text), public.my_invites(), public.answer_invite(uuid,boolean), public.cancel_invite(uuid), public.rename_board(uuid,text), public.leave_board(uuid,uuid) from public, anon;
grant execute on function public.is_board_member(uuid), public.my_email(), public.create_shared_board(text,jsonb), public.my_boards(), public.board_people(uuid), public.invite_to_board(uuid,text), public.my_invites(), public.answer_invite(uuid,boolean), public.cancel_invite(uuid), public.rename_board(uuid,text), public.leave_board(uuid,uuid) to authenticated, service_role;
