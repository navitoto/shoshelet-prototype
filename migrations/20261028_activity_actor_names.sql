-- Activity log actor names: show who performed each log action (approved by Tut 2026-10-28, mock + wording approved).
-- Returns names only for caller-supplied actor ids that appear in this family's activity_log
-- and resolve to a verified identity claim of the same family. Does not broaden identity_claims RLS.
begin;
create function public.family_actor_names(p_family_id uuid, p_actor_ids uuid[])
returns table(actor_id uuid, full_name text)
language sql stable security definer set search_path = ''
as $fn$
  select distinct l.actor_id, p.full_name
  from public.activity_log l
  join public.identity_claims c
    on c.user_id = l.actor_id and c.family_id = p_family_id and c.status = 'verified'
  join public.people p
    on p.id = c.person_id and p.family_id = p_family_id
  where l.family_id = p_family_id
    and l.actor_id = any(p_actor_ids)
    and auth.uid() is not null
    and public.is_family_member(p_family_id);
$fn$;
revoke all on function public.family_actor_names(uuid, uuid[]) from public, anon, authenticated;
grant execute on function public.family_actor_names(uuid, uuid[]) to authenticated;
commit;
