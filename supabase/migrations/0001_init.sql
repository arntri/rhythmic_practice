-- ============================================================================
-- Rhythmic Practice — cloud schema (Step 2b)
--
-- HOW TO RUN: Supabase Dashboard -> SQL Editor -> New query -> paste all of
-- this -> Run. It is safe to run more than once (uses "if not exists" / "or
-- replace" / "drop ... if exists").
--
-- PRIVACY: This is a METRICS-ONLY mirror. There is deliberately NO column for
-- audio anywhere here. Raw voice recordings never leave the device.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Tables
-- ----------------------------------------------------------------------------

-- A "practice profile" = the person being practiced with. It is owned by the
-- caregiver account (an auth.users row) that created it.
create table if not exists public.practice_profiles (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  display_name text,                 -- a friendly nickname, NOT a full/clinical name
  created_at   timestamptz not null default now()
);

-- Who can see a profile, and in what role.
--   owner  = the caregiver           (read + write)
--   viewer = an invited family member (read only)
create table if not exists public.profile_members (
  profile_id uuid not null references public.practice_profiles (id) on delete cascade,
  user_id    uuid not null references auth.users (id) on delete cascade,
  role       text not null check (role in ('owner', 'viewer')),
  added_at   timestamptz not null default now(),
  primary key (profile_id, user_id)
);

-- Sessions mirror the local practice_sessions table.
create table if not exists public.practice_sessions (
  id         uuid primary key,       -- same id as the local SQLite row
  profile_id uuid not null references public.practice_profiles (id) on delete cascade,
  started_at timestamptz not null default now()
);

-- Attempts mirror the local exercise_attempts table — metrics only.
create table if not exists public.exercise_attempts (
  id                            uuid primary key,  -- same id as the local row
  session_id                    uuid not null references public.practice_sessions (id) on delete cascade,
  phrase_id                     integer,
  phrase_text                   text,    -- denormalised so the progress view needs no phrase table
  complexity_level              integer,
  latency_ms                    integer,
  duration_ms                   integer,
  tapping_synchronization_score real,
  evaluation_label              integer check (evaluation_label in (0, 1, 2)),
  attempted_at                  timestamptz not null default now()
  -- NOTE: intentionally NO audio column. Raw audio stays on the device.
);

-- ----------------------------------------------------------------------------
-- Helper functions
--
-- These run as SECURITY DEFINER, meaning they read membership while bypassing
-- row-level security. That avoids the "policy on table A reads table B whose
-- policy reads table A" infinite-recursion trap that RLS is prone to.
-- ----------------------------------------------------------------------------

create or replace function public.is_profile_member(p_profile uuid)
returns boolean language sql security definer set search_path = public as $$
  select exists (
    select 1 from public.profile_members m
    where m.profile_id = p_profile and m.user_id = auth.uid()
  );
$$;

create or replace function public.is_profile_owner(p_profile uuid)
returns boolean language sql security definer set search_path = public as $$
  select exists (
    select 1 from public.profile_members m
    where m.profile_id = p_profile and m.user_id = auth.uid() and m.role = 'owner'
  );
$$;

-- Look up which profile a session belongs to (used by the attempts policies).
create or replace function public.session_profile(p_session uuid)
returns uuid language sql security definer set search_path = public as $$
  select s.profile_id from public.practice_sessions s where s.id = p_session;
$$;

-- When a profile is created, automatically record its creator as the 'owner'
-- member. (Runs as definer so it works before any membership row exists.)
create or replace function public.add_owner_membership()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profile_members (profile_id, user_id, role)
  values (new.id, new.owner_id, 'owner')
  on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists trg_add_owner_membership on public.practice_profiles;
create trigger trg_add_owner_membership
  after insert on public.practice_profiles
  for each row execute function public.add_owner_membership();

-- ----------------------------------------------------------------------------
-- Row-level security
--
-- Turn RLS on for every table. With RLS on and no matching policy, access is
-- DENIED by default — so nothing is reachable unless a policy below allows it.
-- ----------------------------------------------------------------------------

alter table public.practice_profiles enable row level security;
alter table public.profile_members   enable row level security;
alter table public.practice_sessions enable row level security;
alter table public.exercise_attempts enable row level security;

-- practice_profiles: members read; only the owner creates/edits/deletes.
drop policy if exists "profiles read"   on public.practice_profiles;
drop policy if exists "profiles insert" on public.practice_profiles;
drop policy if exists "profiles update" on public.practice_profiles;
drop policy if exists "profiles delete" on public.practice_profiles;
create policy "profiles read"   on public.practice_profiles for select using (public.is_profile_member(id));
create policy "profiles insert" on public.practice_profiles for insert with check (owner_id = auth.uid());
create policy "profiles update" on public.practice_profiles for update using (public.is_profile_owner(id));
create policy "profiles delete" on public.practice_profiles for delete using (public.is_profile_owner(id));

-- profile_members: fellow members can see the list; only the owner adds/removes.
drop policy if exists "members read"   on public.profile_members;
drop policy if exists "members insert" on public.profile_members;
drop policy if exists "members delete" on public.profile_members;
create policy "members read"   on public.profile_members for select using (public.is_profile_member(profile_id));
create policy "members insert" on public.profile_members for insert with check (public.is_profile_owner(profile_id));
create policy "members delete" on public.profile_members for delete using (public.is_profile_owner(profile_id));

-- practice_sessions: members read; only the owner writes.
drop policy if exists "sessions read"   on public.practice_sessions;
drop policy if exists "sessions insert" on public.practice_sessions;
drop policy if exists "sessions update" on public.practice_sessions;
create policy "sessions read"   on public.practice_sessions for select using (public.is_profile_member(profile_id));
create policy "sessions insert" on public.practice_sessions for insert with check (public.is_profile_owner(profile_id));
create policy "sessions update" on public.practice_sessions for update using (public.is_profile_owner(profile_id));

-- exercise_attempts: members read; only the owner writes.
drop policy if exists "attempts read"   on public.exercise_attempts;
drop policy if exists "attempts insert" on public.exercise_attempts;
drop policy if exists "attempts update" on public.exercise_attempts;
create policy "attempts read"   on public.exercise_attempts for select using (public.is_profile_member(public.session_profile(session_id)));
create policy "attempts insert" on public.exercise_attempts for insert with check (public.is_profile_owner(public.session_profile(session_id)));
create policy "attempts update" on public.exercise_attempts for update using (public.is_profile_owner(public.session_profile(session_id)));
