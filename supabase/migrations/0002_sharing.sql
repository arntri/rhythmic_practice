-- ============================================================================
-- Rhythmic Practice — family sharing via share codes (Step 2e)
--
-- HOW TO RUN: Supabase Dashboard -> SQL Editor -> New query -> paste -> Run.
-- Safe to run more than once.
--
-- Model: each practice profile gets a short, unique share_code. A caregiver
-- gives that code to a family member; the family member (signed in) calls
-- join_profile_with_code(code) to gain read-only ("viewer") access.
-- ============================================================================

-- 1. A short, unique share code on every profile.
alter table public.practice_profiles
  add column if not exists share_code text unique;

-- Backfill any existing rows.
update public.practice_profiles
  set share_code = upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))
  where share_code is null;

-- New rows get one automatically.
alter table public.practice_profiles
  alter column share_code
  set default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));

-- 2. Redeem a code: adds the caller as a viewer of the matching profile.
--    SECURITY DEFINER so it can look up the profile (which the caller can't yet
--    see) and add the membership, bypassing RLS for just this controlled action.
create or replace function public.join_profile_with_code(p_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  target uuid;
begin
  select id into target
  from public.practice_profiles
  where share_code = upper(trim(p_code));

  if target is null then
    raise exception 'invalid share code';
  end if;

  insert into public.profile_members (profile_id, user_id, role)
  values (target, auth.uid(), 'viewer')
  on conflict do nothing;

  return target;
end;
$$;

-- Only signed-in users may redeem a code.
revoke all on function public.join_profile_with_code(text) from public, anon;
grant execute on function public.join_profile_with_code(text) to authenticated;
