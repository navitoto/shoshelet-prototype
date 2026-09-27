-- Family members can learn only the verified yes/no state of each already visible person.
-- This does not broaden SELECT on identity_claims.
begin;
create function public.family_verified_status(p_family_id uuid)
returns table(person_id uuid, verified boolean)
language sql stable security definer set search_path = ''
as $fn$
  select p.id, exists (
    select 1 from public.identity_claims c
    where c.family_id = p_family_id and c.person_id = p.id and c.status = 'verified'
  )
  from public.people p
  where p.family_id = p_family_id
    and auth.uid() is not null
    and public.is_family_member(p_family_id);
$fn$;
revoke all on function public.family_verified_status(uuid) from public, anon, authenticated;
grant execute on function public.family_verified_status(uuid) to authenticated;
commit;
