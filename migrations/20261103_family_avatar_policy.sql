-- v2.83: internal family-specific avatar requirement. No row means photo_or_icon.
create table public.family_avatar_policies (
 family_id uuid primary key references public.families(id) on delete cascade,
 photo_required boolean not null default false
);
alter table public.family_avatar_policies enable row level security;
revoke all on public.family_avatar_policies from public, anon, authenticated;
grant select on public.family_avatar_policies to authenticated;
create policy family_avatar_policy_read on public.family_avatar_policies for select to authenticated using (public.is_family_member(family_id));
create function public.family_avatar_policy(p_family_id uuid) returns boolean
language plpgsql stable security definer set search_path=public as $$
begin
 if not public.is_family_member(p_family_id) then raise exception 'family access denied' using errcode='42501'; end if;
 return coalesce((select photo_required from public.family_avatar_policies where family_id=p_family_id),false);
end $$;
revoke all on function public.family_avatar_policy(uuid) from public,anon;
grant execute on function public.family_avatar_policy(uuid) to authenticated;
-- Restrictive policies combine with, never replace, the existing owner checks.
create policy person_icons_family_insert on public.person_icons as restrictive for insert to authenticated with check (not public.family_avatar_policy(family_id));
create policy person_icons_family_update on public.person_icons as restrictive for update to authenticated using (not public.family_avatar_policy(family_id)) with check (not public.family_avatar_policy(family_id));
-- A trigger also protects updates that attempt to move the last photo to another card.
-- Parent deletion removes the people row first; its ordinary FK cascade stays supported.
create function public.guard_required_family_photo() returns trigger
language plpgsql security definer set search_path=public as $$
begin
 if exists(select 1 from public.people p join public.family_avatar_policies f on f.family_id=p.family_id where p.id=old.person_id and f.photo_required) then
  if TG_OP='DELETE' then raise exception 'photo replacement required' using errcode='23514'; end if;
  if new.person_id is distinct from old.person_id or new.family_id is distinct from old.family_id then raise exception 'photo replacement required' using errcode='23514'; end if;
 end if;
 if TG_OP='DELETE' then return old; end if;
 return new;
end $$;
revoke all on function public.guard_required_family_photo() from public,anon,authenticated;
create trigger protect_required_family_photo before delete or update on public.person_photos for each row execute function public.guard_required_family_photo();
