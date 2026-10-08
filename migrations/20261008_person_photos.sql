-- Profile photo on the person card (phase 1: only the card owner writes).
-- Additive: creates one new table. Nothing existing is altered.
create table if not exists public.person_photos (
  person_id  uuid primary key references public.people(id) on delete cascade,
  family_id  uuid not null references public.families(id) on delete cascade,
  mime       text not null default 'image/jpeg' check (mime = 'image/jpeg'),
  data       text not null check (length(data) between 100 and 200000),
  updated_by uuid,
  updated_at timestamptz not null default now()
);
alter table public.person_photos enable row level security;
revoke all on public.person_photos from anon, public;
grant select, insert, update, delete on public.person_photos to authenticated;

create policy person_photos_read on public.person_photos
  for select to authenticated using (is_family_member(family_id));
create policy person_photos_owner_insert on public.person_photos
  for insert to authenticated
  with check (owns_person(person_id) and family_id = (select p.family_id from public.people p where p.id = person_id));
create policy person_photos_owner_update on public.person_photos
  for update to authenticated
  using (owns_person(person_id))
  with check (owns_person(person_id) and family_id = (select p.family_id from public.people p where p.id = person_id));
create policy person_photos_owner_delete on public.person_photos
  for delete to authenticated using (owns_person(person_id));
