-- Rollback for 20261027_family_member_medal.sql. Refuses to run if any family_member award exists
-- (earned medals are never removed). To only stop new awards use: update public.trivia_family_member_rule set enabled=false;
begin;
do $r$
declare def text;
begin
  if exists (select 1 from public.trivia_personal_awards where medal='family_member') then raise exception 'family_member awards exist; disable the rule instead'; end if;
  def := pg_get_functiondef('public.trivia_personal_grant'::regproc);
  def := regexp_replace(def, 'BEGIN\s+IF\s+\(SELECT enabled FROM public\.trivia_family_member_rule\).*?EXCEPTION WHEN OTHERS THEN BEGIN INSERT INTO public\.trivia_personal_diag.*?END;\s*END;\s*', '');
  if def like '%trivia_family_member_rule%' or def like '%trivia_personal_diag%' then raise exception 'grant block not removed'; end if;
  execute def;
  def := pg_get_functiondef('public.trivia_family_state'::regproc);
  def := regexp_replace(def, $p$,\s*'family_member', EXISTS\(.*?medal='family_member'\),\s*'family_member_progress', public\.trivia_family_member_count\(p_family_id, me\)$p$, '');
  if def like '%family_member_progress%' or def like '%medal=''family_member''%' then raise exception 'state keys not removed'; end if;
  execute def;
end $r$;
drop function public.trivia_family_member_count(uuid, uuid);
alter table public.trivia_personal_awards drop constraint trivia_personal_awards_medal_check;
alter table public.trivia_personal_awards drop constraint trivia_personal_awards_check;
alter table public.trivia_personal_awards add constraint trivia_personal_awards_medal_check check (medal = any (array['profile_photo','perfect_week']));
alter table public.trivia_personal_awards add constraint trivia_personal_awards_check check (
  (medal = 'profile_photo' and run_start is null and run_end is null)
  or (medal = 'perfect_week' and run_end = run_start + 6 and run_start is not null));
drop table public.trivia_personal_diag;
drop table public.trivia_family_member_rule;
commit;
