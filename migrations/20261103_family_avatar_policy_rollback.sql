-- Does not delete photos, icons or people.
drop trigger if exists protect_required_family_photo on public.person_photos;
drop function if exists public.guard_required_family_photo();
drop policy if exists person_icons_family_insert on public.person_icons;
drop policy if exists person_icons_family_update on public.person_icons;
drop function if exists public.family_avatar_policy(uuid);
drop table if exists public.family_avatar_policies;
