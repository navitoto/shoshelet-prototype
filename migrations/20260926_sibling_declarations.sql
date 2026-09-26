-- Applied to the Shoshelet Supabase project on 2026-09-26.
-- Ordered, pair-scoped declaration: a selected single shared parent may be
-- explicitly declared half-sibling even when the other parent is unknown.
create table public.sibling_declarations (
  family_id uuid not null references public.families(id) on delete cascade,
  person_a uuid not null references public.people(id) on delete cascade,
  person_b uuid not null references public.people(id) on delete cascade,
  declared_half boolean not null default true check (declared_half),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  primary key (person_a, person_b),
  check (person_a < person_b)
);

alter table public.sibling_declarations enable row level security;

create policy sibling_member_all on public.sibling_declarations
  for all to authenticated
  using (public.is_family_member(family_id))
  with check (
    public.is_family_member(sibling_declarations.family_id)
    and created_by = auth.uid()
    and exists (
      select 1 from public.people a
      where a.id = sibling_declarations.person_a
        and a.family_id = sibling_declarations.family_id
    )
    and exists (
      select 1 from public.people b
      where b.id = sibling_declarations.person_b
        and b.family_id = sibling_declarations.family_id
    )
    and exists (
      select 1 from public.parent_child x
      join public.parent_child y
        on x.parent_id = y.parent_id and x.family_id = y.family_id
      where x.family_id = sibling_declarations.family_id
        and x.child_id = sibling_declarations.person_a
        and y.child_id = sibling_declarations.person_b
    )
  );

revoke all on public.sibling_declarations from public, anon;
grant select, insert, update, delete on public.sibling_declarations to authenticated;
