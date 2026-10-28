-- v2.80: read-only daily/weekly/calendar-year boards. No score or tree writes.
begin;
create or replace function public.trivia_rankings(p_family_id uuid) returns jsonb
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare d date:=public.trivia_day_key(now()); w date; y date; daily jsonb; weekly jsonb; annual jsonb; first_day date;
begin
 perform public.trivia_check_member(p_family_id);
 w:=d-extract(dow from d)::int; y:=make_date(extract(year from d)::int,1,1);
 -- Daily keeps the existing all-completed-participants rule, including zero.
 select coalesce(jsonb_agg(jsonb_build_object('name',nm,'score',sc,'is_me',user_id=auth.uid()) order by sc desc,finished_at,nm,user_id),'[]'::jsonb) into daily
 from (select a.user_id,a.finished_at,public.trivia_effective_score(s.questions,s.reports,a.answers) sc,
 coalesce((select p.full_name from public.identity_claims c join public.people p on p.id=c.person_id and p.family_id=p_family_id where c.user_id=a.user_id and c.family_id=p_family_id and c.status='verified' order by c.created_at desc limit 1),'חבר משפחה') nm
 from public.trivia_attempts a join public.trivia_sets s using(family_id,day) where a.family_id=p_family_id and a.day=d and a.finished_at is not null) z;
 -- Weekly/yearly use the exact weekly member and effective-score rules.
 with registered as (
 select m.user_id,card.full_name from public.family_members m join lateral (
 select p.full_name from public.identity_claims c join public.people p on p.id=c.person_id and p.family_id=p_family_id
 where c.user_id=m.user_id and c.family_id=p_family_id and c.status='verified' order by c.created_at desc,c.person_id limit 1
 ) card on true where m.family_id=p_family_id and m.status='active'
 ), scores as (
 select a.user_id,sum(public.trivia_effective_score(s.questions,s.reports,a.answers))::bigint score,
 coalesce(sum(public.trivia_effective_score(s.questions,s.reports,a.answers)) filter(where a.day>=w),0)::bigint week_score,
 max(a.finished_at) last_finish,max(a.finished_at) filter(where a.day>=w) week_finish
 from public.trivia_attempts a join public.trivia_sets s using(family_id,day)
 where a.family_id=p_family_id and a.day>=y and a.day<=d and a.finished_at is not null group by a.user_id
 ) select
 coalesce(jsonb_agg(jsonb_build_object('name',r.full_name,'score',s.week_score,'is_me',s.user_id=auth.uid()) order by s.week_score desc,s.week_finish,r.full_name,s.user_id) filter(where s.week_score>0),'[]'::jsonb),
 coalesce(jsonb_agg(jsonb_build_object('name',r.full_name,'score',s.score,'is_me',s.user_id=auth.uid()) order by s.score desc,s.last_finish,r.full_name,s.user_id) filter(where s.score>0),'[]'::jsonb)
 into weekly,annual from scores s join registered r on r.user_id=s.user_id;
 -- Week may overlap the previous calendar year. Calculate independently then.
 if w<y then
 -- Attach identity without matching display names by recomputing the overlap week.
 with registered as (select m.user_id,card.full_name from public.family_members m join lateral(select p.full_name from public.identity_claims c join public.people p on p.id=c.person_id and p.family_id=p_family_id where c.user_id=m.user_id and c.family_id=p_family_id and c.status='verified' order by c.created_at desc,c.person_id limit 1)card on true where m.family_id=p_family_id and m.status='active'),scores as(select a.user_id,sum(public.trivia_effective_score(s.questions,s.reports,a.answers))::bigint score,max(a.finished_at) last_finish from public.trivia_attempts a join public.trivia_sets s using(family_id,day) where a.family_id=p_family_id and a.day>=w and a.day<=d and a.finished_at is not null group by a.user_id)
 select coalesce(jsonb_agg(jsonb_build_object('name',r.full_name,'score',s.score,'is_me',s.user_id=auth.uid()) order by s.score desc,s.last_finish,r.full_name,s.user_id),'[]'::jsonb) into weekly from scores s join registered r on r.user_id=s.user_id where s.score>0;
 end if;
 select min(a.day) into first_day from public.trivia_attempts a where a.family_id=p_family_id and a.day>=y and a.day<=d and a.finished_at is not null;
 return jsonb_build_object('day',d,'week_start',w,'week_end',w+6,'year',extract(year from d)::int,'counted_since',first_day,'daily',daily,'weekly',weekly,'annual',annual);
end $$;
revoke all on function public.trivia_rankings(uuid) from public,anon;
grant execute on function public.trivia_rankings(uuid) to authenticated;
commit;
