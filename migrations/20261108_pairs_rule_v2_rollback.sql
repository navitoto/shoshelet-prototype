-- Non-destructive rollback of pairs rule v2: restores the previous functions, removes the new ones. Keeps pairs_attempts (including rule_version), pairs_awards and all settings.
begin;
create or replace function public.pairs_start_internal(p_family uuid, p_day date, p_at timestamptz, p_uid uuid) returns jsonb
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
      insert into public.pairs_attempts(family_id,day,user_id,started_at,deadline) values (p_family,p_day,p_uid,p_at,p_at+make_interval(secs=>(cfg->>'seconds')::int)) on conflict do nothing;
    end if;
  end if;
  return public.pairs_state_internal(p_family,p_day,p_at,p_uid);
end $$;
create or replace function public.pairs_pick_internal(p_family uuid, p_day date, p_at timestamptz, p_uid uuid, p_a uuid, p_b uuid) returns jsonb
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
  if idx is null then
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
create or replace function public.pairs_start(p_family_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare d date:=(now() at time zone 'Asia/Jerusalem')::date;
begin perform public.pairs_member_check(p_family_id); d:=public.pairs_active_day(p_family_id,auth.uid(),now()); return public.pairs_start_internal(p_family_id,d,now(),auth.uid()); end $$;
create or replace function public.pairs_pick(p_family_id uuid, p_a uuid, p_b uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare d date;
begin perform public.pairs_member_check(p_family_id); d:=public.pairs_active_day(p_family_id,auth.uid(),now()); return public.pairs_pick_internal(p_family_id,d,now(),auth.uid(),p_a,p_b); end $$;
drop function if exists public.pairs_pick(uuid,uuid,uuid,int);
drop function if exists public.pairs_start(uuid,int);
drop function if exists public.pairs_totals(uuid,date);
drop function if exists public.pairs_totals_internal(uuid,uuid,date,timestamptz);
drop function if exists public.pairs_pick_internal(uuid,date,timestamptz,uuid,uuid,uuid,int);
drop function if exists public.pairs_start_internal(uuid,date,timestamptz,uuid,int);
drop function if exists public.pairs_legacy_allowed(timestamptz);
do $g$
declare f text;
begin
  for f in select p.oid::regprocedure::text from pg_proc p where p.pronamespace='public'::regnamespace and p.proname like 'pairs\_%' loop
    execute 'revoke all on function '||f||' from public, anon, authenticated';
  end loop;
end $g$;
grant execute on function public.pairs_state(uuid), public.pairs_start(uuid), public.pairs_pick(uuid,uuid,uuid), public.pairs_rankings(uuid), public.pairs_medals(uuid) to authenticated;
commit;
