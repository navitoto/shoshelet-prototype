-- Family contributor medal "family_member": 50 distinct city/birthday details a user completed on relatives' cards
-- through the existing completion flow (trivia_family_fill_log). Counting starts at cutoff (no history). Own card excluded.
-- Does not touch trivia_family_fill_detail, card saves or family medals.
begin;
do $chk$ begin
  if md5(pg_get_functiondef('public.trivia_personal_grant'::regproc)) <> '033aab7e53b3e1695106cc834591cfba' then raise exception 'grant changed'; end if;
  if md5(pg_get_functiondef('public.trivia_family_state'::regproc)) <> '118908492288156a230fd197b43ac28a' then raise exception 'state changed'; end if;
end $chk$;

create table public.trivia_family_member_rule (id boolean primary key default true check (id), cutoff timestamptz not null default now(), enabled boolean not null default true);
insert into public.trivia_family_member_rule default values;
alter table public.trivia_family_member_rule enable row level security;
revoke all on public.trivia_family_member_rule from public, anon, authenticated;

create table public.trivia_personal_diag (id uuid primary key default gen_random_uuid(), user_id uuid, family_id uuid, medal text not null, sqlstate text not null, created_at timestamptz not null default now());
alter table public.trivia_personal_diag enable row level security;
revoke all on public.trivia_personal_diag from public, anon, authenticated;

alter table public.trivia_personal_awards drop constraint trivia_personal_awards_medal_check;
alter table public.trivia_personal_awards drop constraint trivia_personal_awards_check;
alter table public.trivia_personal_awards add constraint trivia_personal_awards_medal_check check (medal = any (array['profile_photo','perfect_week','family_member']));
alter table public.trivia_personal_awards add constraint trivia_personal_awards_check check (
  (medal in ('profile_photo','family_member') and run_start is null and run_end is null)
  or (medal = 'perfect_week' and run_end = run_start + 6 and run_start is not null));

create or replace function public.trivia_family_member_count(p_family uuid, p_user uuid) returns integer
language sql stable security definer set search_path = public, pg_temp as $f$
  select count(*)::int from public.trivia_family_fill_log l, public.trivia_family_member_rule r
  where l.family_id = p_family and l.user_id = p_user and p_user is not null
    and l.created_at >= r.cutoff and l.field in ('city','birthday')
    and not exists (select 1 from public.identity_claims c where c.family_id = p_family and c.user_id = p_user and c.status = 'verified' and c.person_id = l.person_id);
$f$;
revoke all on function public.trivia_family_member_count(uuid, uuid) from public, anon, authenticated;

do $d$
declare def text; n int; blk text;
begin
  blk := $b$ BEGIN IF (SELECT enabled FROM public.trivia_family_member_rule) AND NOT EXISTS(SELECT 1 FROM public.trivia_personal_awards WHERE user_id=p_user AND family_id=p_family AND medal='family_member') AND public.trivia_family_member_count(p_family,p_user) >= 50 THEN INSERT INTO public.trivia_personal_awards(user_id,family_id,medal,rule_version) VALUES(p_user,p_family,'family_member',cfg.version) ON CONFLICT DO NOTHING; END IF; EXCEPTION WHEN OTHERS THEN BEGIN INSERT INTO public.trivia_personal_diag(user_id,family_id,medal,sqlstate) VALUES(p_user,p_family,'family_member',SQLSTATE); EXCEPTION WHEN OTHERS THEN NULL; END; END; $b$;
  def := pg_get_functiondef('public.trivia_personal_grant'::regproc);
  select count(*) into n from regexp_matches(def, 'SELECT\s+c\.person_id\s+INTO\s+pid', 'g');
  if n <> 1 then raise exception 'grant anchor count %', n; end if;
  def := regexp_replace(def, '(SELECT\s+c\.person_id\s+INTO\s+pid)', replace(blk, '\', '\\') || ' \1');
  execute def;

  def := pg_get_functiondef('public.trivia_family_state'::regproc);
  select count(*) into n from regexp_matches(def, $p$medal='perfect_week'\)\)$p$, 'g');
  if n <> 1 then raise exception 'state anchor count %', n; end if;
  def := regexp_replace(def, $p$(medal='perfect_week'\))\)$p$, $r$\1, 'family_member', EXISTS(SELECT 1 FROM public.trivia_personal_awards WHERE user_id=me AND family_id=p_family_id AND medal='family_member'), 'family_member_progress', public.trivia_family_member_count(p_family_id, me))$r$);
  execute def;
end $d$;
select 'ok';
commit;
