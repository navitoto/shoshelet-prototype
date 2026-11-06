-- Pairs rule v2: the player picks the relationship type together with the pair; wrong type = mistake. Own totals read for the end summary.
-- Non-destructive: adds a column and functions only. Rollback (20261108_pairs_rule_v2_rollback.sql) keeps every attempt and award.
begin;
alter table public.pairs_attempts add column if not exists rule_version int not null default 1;

-- Legacy (type-less) start/pick stay available until pairs_settings 'legacy_cutoff' (a timestamptz) passes; no row = no cutoff yet.
create or replace function public.pairs_legacy_allowed(p_at timestamptz) returns boolean
language sql stable security definer set search_path=public,pg_temp as $$
select coalesce((select v::timestamptz>p_at from public.pairs_settings where k='legacy_cutoff'),true) $$;

create or replace function public.pairs_start_internal(p_family uuid, p_day date, p_at timestamptz, p_uid uuid, p_rule int) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare cfg jsonb:=public.pairs_config(); b public.pairs_boards;
begin
  perform public.pairs_ensure_board(p_family,p_day);
  select * into b from public.pairs_boards where family_id=p_family and day=p_day;
  if jsonb_array_length(b.pairs)=4 and not exists (select 1 from public.pairs_attempts a where a.family_id=p_family and a.day=p_day and a.user_id=p_uid) then
    if not public.pairs_check(p_family,b.cards,b.pairs) then
      if not exists (select 1 from public.pairs_attempts a where a.family_id=p_family and a.day=p_day) then
        delete from public.pairs_boards where family_id=p_family and day=p_day;
        perform public.pairs_ensure_board(p_family,p_day);
        select * into b from public.pairs_boards where family_id=p_family and day=p_day;
      else
        update public.pairs_boards set void=true where family_id=p_family and day=p_day; b.void:=true;
      end if;
    end if;
    if jsonb_array_length(b.pairs)=4 and not b.void then
      insert into public.pairs_attempts(family_id,day,user_id,started_at,deadline,rule_version) values (p_family,p_day,p_uid,p_at,p_at+make_interval(secs=>(cfg->>'seconds')::int),p_rule) on conflict do nothing;
    end if;
  end if;
  return public.pairs_state_internal(p_family,p_day,p_at,p_uid);
end $$;

create or replace function public.pairs_start_internal(p_family uuid, p_day date, p_at timestamptz, p_uid uuid) returns jsonb
language sql security definer set search_path=public,pg_temp as $$ select public.pairs_start_internal(p_family,p_day,p_at,p_uid,1) $$;

create or replace function public.pairs_pick_internal(p_family uuid, p_day date, p_at timestamptz, p_uid uuid, p_a uuid, p_b uuid, p_type int) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare cfg jsonb:=public.pairs_config(); b public.pairs_boards; a public.pairs_attempts; grace interval; lo uuid; hi uuid; idx int; st jsonb; ns jsonb;
begin
  grace:=make_interval(secs=>(cfg->>'grace_seconds')::int);
  select * into b from public.pairs_boards where family_id=p_family and day=p_day;
  if not found or jsonb_array_length(b.pairs)<>4 then raise exception 'no board' using errcode='P0001'; end if;
  select * into a from public.pairs_attempts where family_id=p_family and day=p_day and user_id=p_uid for update;
  if not found then raise exception 'not started' using errcode='P0001'; end if;
  if a.finished_at is not null then return public.pairs_state_internal(p_family,p_day,p_at,p_uid); end if;
  if p_at>a.deadline+grace then
    update public.pairs_attempts set finished_at=deadline,end_reason='timeout' where family_id=p_family and day=p_day and user_id=p_uid;
    return public.pairs_state_internal(p_family,p_day,p_at,p_uid);
  end if;
  if b.void or not public.pairs_check(p_family,b.cards,b.pairs) then
    update public.pairs_boards set void=true where family_id=p_family and day=p_day;
    return jsonb_build_object('day',p_day,'phase','unavailable');
  end if;
  if p_a is null or p_b is null or p_a=p_b or not (b.cards ? p_a::text) or not (b.cards ? p_b::text) then raise exception 'bad pair' using errcode='P0001'; end if;
  lo:=least(p_a,p_b); hi:=greatest(p_a,p_b);
  select (ord-1)::int into idx from jsonb_array_elements(b.pairs) with ordinality t(e,ord) where (e->>'a')::uuid=lo and (e->>'b')::uuid=hi;
  if idx is null or (p_type is not null and p_type<>idx) then
    update public.pairs_attempts set finished_at=p_at,end_reason='mistake' where family_id=p_family and day=p_day and user_id=p_uid;
    return public.pairs_state_internal(p_family,p_day,p_at,p_uid);
  end if;
  if a.solved @> to_jsonb(idx) then return public.pairs_state_internal(p_family,p_day,p_at,p_uid); end if;
  update public.pairs_attempts set solved=solved||to_jsonb(idx) where family_id=p_family and day=p_day and user_id=p_uid returning * into a;
  if jsonb_array_length(a.solved)=4 then
    update public.pairs_attempts set finished_at=p_at,end_reason='complete' where family_id=p_family and day=p_day and user_id=p_uid;
    begin perform public.pairs_grant(p_family,p_uid); exception when others then null; end;
  end if;
  st:=public.pairs_state_internal(p_family,p_day,p_at,p_uid);
  return st||jsonb_build_object('last',(select s from jsonb_array_elements(public.pairs_solved_json(p_family,b,a)) s where (s->>'idx')::int=idx));
end $$;

create or replace function public.pairs_pick_internal(p_family uuid, p_day date, p_at timestamptz, p_uid uuid, p_a uuid, p_b uuid) returns jsonb
language sql security definer set search_path=public,pg_temp as $$ select public.pairs_pick_internal(p_family,p_day,p_at,p_uid,p_a,p_b,null::int) $$;

-- v1 (legacy) start: refused for a new attempt after the cutoff; an attempt already started keeps its state.
create or replace function public.pairs_start(p_family_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare d date;
begin perform public.pairs_member_check(p_family_id); d:=public.pairs_active_day(p_family_id,auth.uid(),now());
  if not public.pairs_legacy_allowed(now()) and not exists (select 1 from public.pairs_attempts a where a.family_id=p_family_id and a.day=d and a.user_id=auth.uid()) then
    return jsonb_build_object('day',d,'phase','unavailable');
  end if;
  return public.pairs_start_internal(p_family_id,d,now(),auth.uid(),1); end $$;
-- v2 start: records rule version 2 on the attempt.
create or replace function public.pairs_start(p_family_id uuid, p_rule int) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare d date;
begin perform public.pairs_member_check(p_family_id); if p_rule is distinct from 2 then raise exception 'bad rule' using errcode='P0001'; end if;
  d:=public.pairs_active_day(p_family_id,auth.uid(),now()); return public.pairs_start_internal(p_family_id,d,now(),auth.uid(),2); end $$;
-- v1 pick: only for an attempt started under v1 (a v2 attempt can never be finished without the type).
create or replace function public.pairs_pick(p_family_id uuid, p_a uuid, p_b uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare d date;
begin perform public.pairs_member_check(p_family_id); d:=public.pairs_active_day(p_family_id,auth.uid(),now());
  if exists (select 1 from public.pairs_attempts a where a.family_id=p_family_id and a.day=d and a.user_id=auth.uid() and a.rule_version<>1) then raise exception 'update required' using errcode='P0001'; end if;
  return public.pairs_pick_internal(p_family_id,d,now(),auth.uid(),p_a,p_b,null::int); end $$;
-- v2 pick: pair and type (the type is the index of the relationship chip, 0..3).
create or replace function public.pairs_pick(p_family_id uuid, p_a uuid, p_b uuid, p_type int) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare d date;
begin perform public.pairs_member_check(p_family_id); if p_type is null or p_type<0 or p_type>3 then raise exception 'bad type' using errcode='P0001'; end if;
  d:=public.pairs_active_day(p_family_id,auth.uid(),now()); return public.pairs_pick_internal(p_family_id,d,now(),auth.uid(),p_a,p_b,p_type); end $$;

-- Own totals for the end summary, bound to the caller's own finished attempt on p_day (the credited board day).
-- Week = Sunday..Saturday and year = calendar year of that credited day; a period that is not the current one is returned as null.
create or replace function public.pairs_totals_internal(p_family uuid, p_uid uuid, p_day date, p_at timestamptz) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare a public.pairs_attempts; d date:=(p_at at time zone 'Asia/Jerusalem')::date; w date; cw date; ws bigint; ys bigint; med jsonb;
begin
  select * into a from public.pairs_attempts x where x.family_id=p_family and x.day=p_day and x.user_id=p_uid and x.finished_at is not null;
  if not found then raise exception 'no finished attempt' using errcode='P0001'; end if;
  w:=p_day-extract(dow from p_day)::int; cw:=d-extract(dow from d)::int;
  select coalesce(sum(jsonb_array_length(x.solved)),0) into ws from public.pairs_attempts x where x.family_id=p_family and x.user_id=p_uid and x.finished_at is not null and x.day>=w and x.day<=w+6;
  select coalesce(sum(jsonb_array_length(x.solved)),0) into ys from public.pairs_attempts x where x.family_id=p_family and x.user_id=p_uid and x.finished_at is not null and extract(year from x.day)=extract(year from p_day);
  med:=public.pairs_medals_internal(p_family,p_uid,p_at);
  return jsonb_build_object('day',p_day,'score',jsonb_array_length(a.solved),'is_today',p_day=d,
    'week',case when w=cw then ws end,'year',case when extract(year from p_day)=extract(year from d) then ys end,
    'streak',med->'streak','target',med->'target','awarded',med->'awarded');
end $$;
create or replace function public.pairs_totals(p_family_id uuid, p_day date) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
begin perform public.pairs_member_check(p_family_id); return public.pairs_totals_internal(p_family_id,auth.uid(),p_day,now()); end $$;

do $g$
declare f text;
begin
  for f in select p.oid::regprocedure::text from pg_proc p where p.pronamespace='public'::regnamespace and p.proname like 'pairs\_%' loop
    execute 'revoke all on function '||f||' from public, anon, authenticated';
  end loop;
end $g$;
grant execute on function public.pairs_state(uuid), public.pairs_start(uuid), public.pairs_start(uuid,int), public.pairs_pick(uuid,uuid,uuid), public.pairs_pick(uuid,uuid,uuid,int), public.pairs_rankings(uuid), public.pairs_medals(uuid), public.pairs_totals(uuid,date) to authenticated;
commit;
