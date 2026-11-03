-- Profile icon on the person card (chosen by the card owner at signup or from the card; card-only display, like photos).
-- Additive: creates one new table. Nothing existing is altered.
create table if not exists public.person_icons (
  person_id  uuid primary key references public.people(id) on delete cascade,
  family_id  uuid not null references public.families(id) on delete cascade,
  emoji      text not null check (char_length(emoji) between 1 and 8),
  updated_by uuid,
  updated_at timestamptz not null default now()
);
alter table public.person_icons enable row level security;
revoke all on public.person_icons from anon, public;
grant select, insert, update, delete on public.person_icons to authenticated;

create policy person_icons_read on public.person_icons
  for select to authenticated using (is_family_member(family_id));
create policy person_icons_owner_insert on public.person_icons
  for insert to authenticated
  with check (owns_person(person_id) and family_id = (select p.family_id from public.people p where p.id = person_id));
create policy person_icons_owner_update on public.person_icons
  for update to authenticated
  using (owns_person(person_id))
  with check (owns_person(person_id) and family_id = (select p.family_id from public.people p where p.id = person_id));
create policy person_icons_owner_delete on public.person_icons
  for delete to authenticated using (owns_person(person_id));
