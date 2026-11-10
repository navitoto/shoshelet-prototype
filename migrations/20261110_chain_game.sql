-- v2.107: "מדור לדור" - daily chain game. ADDITIVE ONLY: new tables and functions with the chain_ prefix.
-- No people/relation/trivia/pairs table or function is changed. Rollback file drops everything created here.
-- Game rules (spec 114-118, approved): two endpoints from the family tree, a chain of 6 people (4 empty slots),
-- a bank of 8 names (4 chain + 4 gender-matched decoys), any valid bank chain wins, adjacent members must be
-- direct relatives (parent-child, siblings or spouses), 3 attempts, up to 2 hints (pair-type labels),
-- 3 minutes counted on the server and running while away, one board per family per Jerusalem day, prepared
-- in advance, no medal. Privacy = the pairs rules: unique full names only, deceased allowed.
-- Correctly placed names stay locked after a failed attempt (a name locks when some valid bank chain has it in that slot).
begin;

create table if not exists public.chain_boards (
  family_id uuid not null references public.families(id) on delete cascade,
  day date not null,
  start_id uuid,   -- null on empty/deferred markers
  end_id uuid,
  chain jsonb not null default '[]'::jsonb,  -- the 4 middle person ids, in chain order
  bank jsonb not null default '[]'::jsonb,   -- 8 ids in display order: 4 middles + 4 decoys
  void boolean not null default false,
  built_at timestamptz not null default now(),
  status text not null default 'built',      -- built | proven_none | deferred
  retry_after timestamptz,
  primary key (family_id, day)
);
create table if not exists public.chain_attempts (
  family_id uuid not null,
  day date not null,
  user_id uuid not null,
  started_at timestamptz not null,
  deadline timestamptz not null,
  locked jsonb not null default '[null,null,null,null]'::jsonb, -- per slot: locked person id or null
  hints jsonb not null default '[]'::jsonb,                     -- [{seg,label}]
  tries_left int not null default 3,
  submissions int not null default 0,                           -- failed submissions so far
  finished_at timestamptz,
  end_reason text check (end_reason in ('complete','out_of_tries','timeout')),
  score int,
  primary key (family_id, day, user_id),
  foreign key (family_id, day) references public.chain_boards(family_id, day) on delete cascade
);
create table if not exists public.chain_build_log (
  family_id uuid not null,
  day date not null,
  status text not null,
  message text,
  at timestamptz not null default now()
);
alter table public.chain_boards enable row level security;
alter table public.chain_attempts enable row level security;
alter table public.chain_build_log enable row level security;
-- no policies: direct table access stays denied; everything flows through the security-definer functions below

create or replace function public.chain_config() returns jsonb
language sql stable set search_path=public,pg_temp as
$$ select jsonb_build_object('seconds',180,'tries',3,'hints',2,'slots',4,'tz','Asia/Jerusalem') $$;

-- People the game may display: unique full name inside the family (privacy rule of "מקושרים"; deceased allowed).
create or replace function public.chain_people(p_family uuid)
returns table(id uuid, nm text, g text)
language sql stable security definer set search_path=public,pg_temp as $$
  select id, nm, g from (
    select p.id, btrim(p.full_name) nm, p.gender::text g,
           count(*) over (partition by btrim(p.full_name)) n
    from public.people p
    where p.family_id=p_family and p.full_name is not null and btrim(p.full_name)<>''
  ) z where n=1
$$;

-- Every direct relation the chain may use, between displayable people only: confirmed parent-child,
-- confirmed or declared siblings, active or widowed unions. a<b; label is the approved pair-type tag.
create or replace function public.chain_direct(p_family uuid)
returns table(a uuid, b uuid, label text)
language sql stable security definer set search_path=public,pg_temp as $$
with ppl as materialized (select * from public.chain_people(p_family)),
pc as materialized (
  select r.parent_id x, r.child_id y from public.parent_child r
  where r.family_id=p_family and r.status='confirmed' and r.parent_id<>r.child_id
), sib as materialized (
  select x.y a, y.y b from pc x join pc y on y.x=x.x and x.y<y.y
  union
  select least(d.person_a,d.person_b), greatest(d.person_a,d.person_b) from public.sibling_declarations d where d.family_id=p_family
), mates as materialized (
  select least(u.person_a,u.person_b) a, greatest(u.person_a,u.person_b) b from public.unions u
  where u.family_id=p_family and u.status in ('active','widowed')
), rel as materialized (
  select x a, y b, 'הורה וילד'::text label from pc
  union all select y, x, 'הורה וילד' from pc
  union all select a, b, 'אחים' from sib
  union all select b, a, 'אחים' from sib
  union all select a, b, 'בני זוג' from mates
  union all select b, a, 'בני זוג' from mates
)
select least(r.a,r.b), greatest(r.a,r.b), r.label
from rel r join ppl pa on pa.id=r.a join ppl pb on pb.id=r.b
group by 1,2,3
$$;

-- Does a stored board still hold against the live tree? Checked before every show / submit / hint.
create or replace function public.chain_check_board(p_family uuid, p_start uuid, p_end uuid, p_chain jsonb, p_bank jsonb) returns boolean
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare mids uuid[]; bk uuid[]; i int;
begin
  if p_start is null or p_end is null or p_start=p_end then return false; end if;
  select array_agg(x::uuid) into mids from jsonb_array_elements_text(p_chain) x;
  select array_agg(x::uuid) into bk from jsonb_array_elements_text(p_bank) x;
  if mids is null or cardinality(mids)<>4 or bk is null or cardinality(bk)<>8 then return false; end if;
  if (select count(distinct u) from unnest(mids||p_start||p_end) u)<>6 then return false; end if;
  if (select count(distinct u) from unnest(bk) u)<>8 then return false; end if;
  if not (bk @> mids) then return false; end if;
  if bk && array[p_start,p_end] then return false; end if;  -- endpoints are never in the bank
  -- every displayed person must still be in the family with a unique full name
  if (select count(*) from public.chain_people(p_family) q where q.id=any(bk||p_start||p_end))<>10 then return false; end if;
  -- each consecutive pair of the intended chain must still be direct relatives
  for i in 0..4 loop
    if not exists (select 1 from public.chain_direct(p_family) r
      where r.a=least((array[p_start]||mids||p_end)[i+1], (array[p_start]||mids||p_end)[i+2])
        and r.b=greatest((array[p_start]||mids||p_end)[i+1], (array[p_start]||mids||p_end)[i+2])) then return false; end if;
  end loop;
  return true;
end $$;

-- All valid winning chains from the bank under the live tree: 6 distinct people, start..end, adjacent direct.
create or replace function public.chain_paths(p_family uuid, p_start uuid, p_end uuid, p_bank jsonb)
returns table(path uuid[])
language sql stable security definer set search_path=public,pg_temp as $$
with bk as (select array_agg(x::uuid) ids from jsonb_array_elements_text(p_bank) x),
adj as (select r.a x, r.b y from public.chain_direct(p_family) r, bk where r.a=any(bk.ids) or r.a in (p_start,p_end)
        union all select r.b, r.a from public.chain_direct(p_family) r, bk where r.b=any(bk.ids) or r.b in (p_start,p_end)),
walk as (
  with recursive w(path, last) as (
    select array[p_start]::uuid[], p_start
    union all
    select w.path||c.y, c.y
    from w join adj c on c.x=w.last, bk
    where not c.y=any(w.path)
      and ((c.y=any(bk.ids) and cardinality(w.path)<5) or (c.y=p_end and cardinality(w.path)=5))
  )
  select path from w where last=p_end
)
select path from walk
$$;

-- Builds one board (nothing stored). Start at a random person, BFS the direct-relation graph, choose an
-- endpoint exactly 5 steps away, then walk back down the BFS layers for a shortest path (always exists).
-- Decoys match the genders of the 4 middles.
create or replace function public.chain_build_board(p_family uuid, p_day date) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare path uuid[]:='{}'; s uuid; e uuid; nx uuid; i int; k int; tries int:=40; mg text; dcy uuid; decoys uuid[]:='{}';
  mids uuid[]; bank jsonb; frontier uuid[]; dist int; nnodes int;
begin
  drop table if exists pg_temp.t_nodes; drop table if exists pg_temp.t_adj; drop table if exists pg_temp.t_dist; drop table if exists pg_temp.t_recent;
  create temp table t_nodes on commit drop as select * from public.chain_people(p_family);
  select count(*) into nnodes from t_nodes;
  if nnodes<10 then return jsonb_build_object('status','proven_none'); end if;
  create temp table t_adj on commit drop as
    select r.a x, r.b y from public.chain_direct(p_family) r
    union all select r.b, r.a from public.chain_direct(p_family) r;
  create index on t_adj(x);
  create temp table t_dist(id uuid primary key, d int) on commit drop;
  create temp table t_recent on commit drop as
    select least(b.start_id,b.end_id) a, greatest(b.start_id,b.end_id) b
    from public.chain_boards b where b.family_id=p_family and b.day<p_day and b.day>=p_day-21;
  for i in 1..tries loop
    truncate t_dist;
    select n.id into s from t_nodes n where exists (select 1 from t_adj c where c.x=n.id) order by random() limit 1;
    -- BFS from s
    insert into t_dist values (s,0);
    frontier:=array[s]; dist:=0;
    while dist<5 loop
      insert into t_dist select c.y, dist+1 from t_adj c where c.x=any(frontier) on conflict do nothing;
      select array_agg(t.id) into frontier from t_dist t where t.d=dist+1;
      exit when frontier is null;
      dist:=dist+1;
    end loop;
    -- endpoint at distance exactly 5, not recently used with this start
    select t.id into e from t_dist t where t.d=5
      and (i>25 or not exists (select 1 from t_recent r where r.a=least(s,t.id) and r.b=greatest(s,t.id)))
      order by random() limit 1;
    continue when e is null;
    -- walk down the layers: e is at 5, pick a random neighbor at 4, then 3, ... down to s
    path:=array[e];
    for k in reverse 5..1 loop
      select c.x into nx from t_adj c join t_dist t on t.id=c.x and t.d=k-1 where c.y=path[1] order by random() limit 1;
      exit when nx is null;
      path:=nx||path;
    end loop;
    continue when cardinality(path)<6;
    -- decoys: match each middle's gender where possible
    mids:=path[2:5]; decoys:='{}';
    for k in 1..4 loop
      select n.g into mg from t_nodes n where n.id=mids[k];
      select n.id into dcy from t_nodes n
        where n.g=mg and not n.id=any(path) and not n.id=any(decoys)
        order by random() limit 1;
      if dcy is null then
        select n.id into dcy from t_nodes n where not n.id=any(path) and not n.id=any(decoys) order by random() limit 1;
      end if;
      exit when dcy is null;
      decoys:=decoys||dcy; dcy:=null;
    end loop;
    continue when cardinality(decoys)<4;
    select jsonb_agg(x order by random()) into bank from unnest(mids||decoys) x;
    return jsonb_build_object('status','built','start',path[1],'end',path[6],'chain',to_jsonb(mids),'bank',bank);
  end loop;
  return jsonb_build_object('status','proven_none');
end $$;

create or replace function public.chain_ensure_board(p_family uuid, p_day date) returns void
language plpgsql security definer set search_path=public,pg_temp as $$
declare b jsonb; ex public.chain_boards; st text;
begin
  select * into ex from public.chain_boards where family_id=p_family and day=p_day;
  if found and not (ex.status='deferred' and ex.retry_after<=now()) then return; end if;
  if not pg_try_advisory_xact_lock(hashtextextended('chain'||p_family::text||p_day::text,0)) then return; end if;
  select * into ex from public.chain_boards where family_id=p_family and day=p_day;
  if found and not (ex.status='deferred' and ex.retry_after<=now()) then return; end if;
  b:=public.chain_build_board(p_family,p_day); st:=b->>'status';
  if st='built' then
    insert into public.chain_boards(family_id,day,start_id,end_id,chain,bank,status)
    values (p_family,p_day,(b->>'start')::uuid,(b->>'end')::uuid,b->'chain',b->'bank','built')
    on conflict (family_id,day) do update set start_id=excluded.start_id,end_id=excluded.end_id,chain=excluded.chain,bank=excluded.bank,status='built',retry_after=null,built_at=now();
  elsif st='proven_none' then
    insert into public.chain_boards(family_id,day,chain,bank,status)
    values (p_family,p_day,'[]','[]','proven_none')
    on conflict (family_id,day) do update set status='proven_none',chain='[]',bank='[]',retry_after=null,built_at=now();
  else
    insert into public.chain_boards(family_id,day,chain,bank,status,retry_after)
    values (p_family,p_day,'[]','[]','deferred',now()+interval '2 minutes')
    on conflict (family_id,day) do update set retry_after=excluded.retry_after;
  end if;
  insert into public.chain_build_log(family_id,day,status,message) values (p_family,p_day,st,null);
end $$;

-- Nightly preparation for tomorrow, same family selection and fair order as the pairs job.
create or replace function public.chain_prepare_next() returns int
language plpgsql security definer set search_path=public,pg_temp as $$
declare f record; d date; n int:=0; t0 timestamptz:=clock_timestamp();
begin
  d:=(now() at time zone 'Asia/Jerusalem')::date+1;
  for f in select family_id from (
      select family_id from public.trivia_sets where day>=d-8
      union select family_id from public.trivia_attempts where day>=d-8
      union select family_id from public.pairs_boards where day>=d-8
      union select family_id from public.chain_boards where day>=d-8) x
    where not exists (select 1 from public.chain_boards b where b.family_id=x.family_id and b.day=d and b.status in ('built','proven_none'))
    order by coalesce((select max(l.at) from public.chain_build_log l where l.family_id=x.family_id and l.day=d),'-infinity'::timestamptz) loop
    exit when clock_timestamp()>t0+interval '90 seconds';
    begin
      perform public.chain_ensure_board(f.family_id,d); n:=n+1;
    exception when others then
      insert into public.chain_build_log(family_id,day,status,message) values (f.family_id,d,'error',left(sqlerrm,300));
    end;
  end loop;
  return n;
end $$;

create or replace function public.chain_health(p_day date default null) returns jsonb
language sql stable security definer set search_path=public,pg_temp as $$
with d as (select coalesce(p_day,(now() at time zone 'Asia/Jerusalem')::date) as day),
fam as (select distinct family_id from public.trivia_sets s,d where s.day>=d.day-8
        union select family_id from public.pairs_boards b,d where b.day>=d.day-8
        union select family_id from public.chain_boards b,d where b.day>=d.day-8)
select jsonb_build_object('day',(select day from d),
 'families_without_board',(select count(*) from fam f,d where not exists (select 1 from public.chain_boards b where b.family_id=f.family_id and b.day=d.day)),
 'empty_boards',(select count(*) from public.chain_boards b,d where b.day=d.day and b.status='proven_none'),
 'deferred_boards',(select count(*) from public.chain_boards b,d where b.day=d.day and b.status='deferred'),
 'errors_last_day',(select count(*) from public.chain_build_log l where l.status='error' and l.at>now()-interval '1 day'))
$$;

-- names for display
create or replace function public.chain_names(p_family uuid, p_ids jsonb) returns jsonb
language sql stable security definer set search_path=public,pg_temp as $$
select coalesce(jsonb_agg(jsonb_build_object('id',x,'name',(select btrim(p.full_name) from public.people p where p.id=x::uuid and p.family_id=p_family)) order by ord),'[]'::jsonb)
from jsonb_array_elements_text(p_ids) with ordinality t(x,ord) $$;

-- end-of-game payload: score, outcome, and the intended chain with its relation tags
create or replace function public.chain_done_json(p_family uuid, p_b public.chain_boards, p_a public.chain_attempts) returns jsonb
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare seq uuid[]; labels text[]; i int; lb text;
begin
  seq:=array[p_b.start_id]||(select array_agg(x::uuid) from jsonb_array_elements_text(p_b.chain) x)||p_b.end_id;
  for i in 1..5 loop
    select min(r.label) into lb from public.chain_direct(p_family) r where r.a=least(seq[i],seq[i+1]) and r.b=greatest(seq[i],seq[i+1]);
    labels:=labels||lb;
  end loop;
  return jsonb_build_object('day',p_a.day,'phase','done','score',coalesce(p_a.score,0),'won',p_a.end_reason='complete','reason',p_a.end_reason,
    'solution',public.chain_names(p_family,to_jsonb(seq)),'solution_labels',to_jsonb(labels),
    'hints',p_a.hints,'tries_left',p_a.tries_left);
end $$;

create or replace function public.chain_state_internal(p_family uuid, p_day date, p_at timestamptz, p_uid uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare cfg jsonb:=public.chain_config(); b public.chain_boards; a public.chain_attempts;
begin
  select * into b from public.chain_boards where family_id=p_family and day=p_day;
  if not found or b.status='deferred' then return jsonb_build_object('day',p_day,'phase','preparing'); end if;
  if b.status='proven_none' or jsonb_array_length(b.bank)=0 then return jsonb_build_object('day',p_day,'phase','empty'); end if;
  select * into a from public.chain_attempts where family_id=p_family and day=p_day and user_id=p_uid for update;
  if not found then
    if b.void then return jsonb_build_object('day',p_day,'phase','unavailable'); end if;
    return jsonb_build_object('day',p_day,'phase','ready','seconds',(cfg->>'seconds')::int);
  end if;
  if a.finished_at is null and p_at>a.deadline then
    update public.chain_attempts set finished_at=deadline,end_reason='timeout',score=0
     where family_id=p_family and day=p_day and user_id=p_uid returning * into a;
  end if;
  if a.finished_at is not null then return public.chain_done_json(p_family,b,a); end if;
  if b.void or not public.chain_check_board(p_family,b.start_id,b.end_id,b.chain,b.bank) then
    update public.chain_boards set void=true where family_id=p_family and day=p_day;
    return jsonb_build_object('day',p_day,'phase','unavailable');
  end if;
  return jsonb_build_object('day',p_day,'phase','playing','seconds',(cfg->>'seconds')::int,
    'remaining_ms',greatest(0,(extract(epoch from (a.deadline-p_at))*1000)::int),
    'start',(select jsonb_build_object('id',p.id,'name',btrim(p.full_name)) from public.people p where p.id=b.start_id),
    'end',(select jsonb_build_object('id',p.id,'name',btrim(p.full_name)) from public.people p where p.id=b.end_id),
    'bank',public.chain_names(p_family,b.bank),
    'locked',a.locked,'hints',a.hints,'tries_left',a.tries_left,'hints_left',(cfg->>'hints')::int-jsonb_array_length(a.hints));
end $$;

create or replace function public.chain_start_internal(p_family uuid, p_day date, p_at timestamptz, p_uid uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare cfg jsonb:=public.chain_config(); b public.chain_boards;
begin
  perform public.chain_ensure_board(p_family,p_day);
  select * into b from public.chain_boards where family_id=p_family and day=p_day;
  if b.start_id is not null and jsonb_array_length(b.bank)=8
     and not exists (select 1 from public.chain_attempts a where a.family_id=p_family and a.day=p_day and a.user_id=p_uid) then
    if not public.chain_check_board(p_family,b.start_id,b.end_id,b.chain,b.bank) then
      if not exists (select 1 from public.chain_attempts a where a.family_id=p_family and a.day=p_day) then
        delete from public.chain_boards where family_id=p_family and day=p_day;
        perform public.chain_ensure_board(p_family,p_day);
        select * into b from public.chain_boards where family_id=p_family and day=p_day;
      else
        update public.chain_boards set void=true where family_id=p_family and day=p_day; b.void:=true;
      end if;
    end if;
    if b.start_id is not null and jsonb_array_length(b.bank)=8 and not b.void then
      insert into public.chain_attempts(family_id,day,user_id,started_at,deadline)
      values (p_family,p_day,p_uid,p_at,p_at+make_interval(secs=>(cfg->>'seconds')::int)) on conflict do nothing;
    end if;
  end if;
  return public.chain_state_internal(p_family,p_day,p_at,p_uid);
end $$;

create or replace function public.chain_hint_internal(p_family uuid, p_day date, p_at timestamptz, p_uid uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare cfg jsonb:=public.chain_config(); b public.chain_boards; a public.chain_attempts;
  ref uuid[]; pth uuid[]; seg int; lb text; hint jsonb; locked_ids uuid[];
begin
  select * into b from public.chain_boards where family_id=p_family and day=p_day;
  if not found or jsonb_array_length(b.bank)<>8 then raise exception 'no board' using errcode='P0001'; end if;
  select * into a from public.chain_attempts where family_id=p_family and day=p_day and user_id=p_uid for update;
  if not found then raise exception 'not started' using errcode='P0001'; end if;
  if a.finished_at is not null then return public.chain_state_internal(p_family,p_day,p_at,p_uid); end if;
  if p_at>a.deadline then
    update public.chain_attempts set finished_at=deadline,end_reason='timeout',score=0 where family_id=p_family and day=p_day and user_id=p_uid;
    return public.chain_state_internal(p_family,p_day,p_at,p_uid);
  end if;
  if b.void or not public.chain_check_board(p_family,b.start_id,b.end_id,b.chain,b.bank) then
    update public.chain_boards set void=true where family_id=p_family and day=p_day;
    return jsonb_build_object('day',p_day,'phase','unavailable');
  end if;
  if jsonb_array_length(a.hints)>=(cfg->>'hints')::int then return public.chain_state_internal(p_family,p_day,p_at,p_uid); end if;
  -- reference chain: the intended one if it fits the locked slots, else any valid bank chain that fits them
  ref:=array[b.start_id]||(select array_agg(x::uuid) from jsonb_array_elements_text(b.chain) x)||b.end_id;
  select array_agg(x::uuid order by ord) into locked_ids from jsonb_array_elements_text(a.locked) with ordinality t(x,ord);
  if not (select coalesce(bool_and(locked_ids[i] is null or locked_ids[i]=ref[i+1]),true) from generate_subscripts(locked_ids,1) i) then
    select p.path into pth from public.chain_paths(p_family,b.start_id,b.end_id,b.bank) p
      where (select coalesce(bool_and(locked_ids[i] is null or locked_ids[i]=p.path[i+2]),true) from generate_subscripts(locked_ids,1) i)
      limit 1;
    if pth is not null then ref:=pth; end if;
  end if;
  -- first unhinted segment whose two links are not both fixed (endpoints or locked)
  seg:=0; lb:=null;
  while seg<=4 loop
    if not exists (select 1 from jsonb_array_elements(a.hints) h where (h->>'seg')::int=seg)
       and not ((seg=0 or locked_ids[seg] is not null and locked_ids[seg]=ref[seg+1])
            and (seg=4 or locked_ids[seg+1] is not null and locked_ids[seg+1]=ref[seg+2])) then
      select min(r.label) into lb from public.chain_direct(p_family) r where r.a=least(ref[seg+1],ref[seg+2]) and r.b=greatest(ref[seg+1],ref[seg+2]);
      exit when lb is not null;
    end if;
    seg:=seg+1;
  end loop;
  if seg>4 or lb is null then return public.chain_state_internal(p_family,p_day,p_at,p_uid); end if; -- everything already revealed: do not consume
  hint:=jsonb_build_object('seg',seg,'label',lb);
  update public.chain_attempts set hints=hints||hint where family_id=p_family and day=p_day and user_id=p_uid;
  return public.chain_state_internal(p_family,p_day,p_at,p_uid)||jsonb_build_object('last_hint',hint);
end $$;

create or replace function public.chain_check_internal(p_family uuid, p_day date, p_at timestamptz, p_uid uuid, p_slots jsonb) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare cfg jsonb:=public.chain_config(); b public.chain_boards; a public.chain_attempts;
  slots uuid[]; seq uuid[]; i int; ok boolean; sc int; locked_ids uuid[]; new_locked jsonb;
begin
  select * into b from public.chain_boards where family_id=p_family and day=p_day;
  if not found or jsonb_array_length(b.bank)<>8 then raise exception 'no board' using errcode='P0001'; end if;
  select * into a from public.chain_attempts where family_id=p_family and day=p_day and user_id=p_uid for update;
  if not found then raise exception 'not started' using errcode='P0001'; end if;
  if a.finished_at is not null then return public.chain_state_internal(p_family,p_day,p_at,p_uid); end if;
  if p_at>a.deadline then
    update public.chain_attempts set finished_at=deadline,end_reason='timeout',score=0 where family_id=p_family and day=p_day and user_id=p_uid;
    return public.chain_state_internal(p_family,p_day,p_at,p_uid);
  end if;
  if b.void or not public.chain_check_board(p_family,b.start_id,b.end_id,b.chain,b.bank) then
    update public.chain_boards set void=true where family_id=p_family and day=p_day;
    return jsonb_build_object('day',p_day,'phase','unavailable');
  end if;
  if p_slots is null or jsonb_typeof(p_slots)<>'array' or jsonb_array_length(p_slots)<>4 then raise exception 'bad slots' using errcode='P0001'; end if;
  select array_agg(x::uuid) into slots from jsonb_array_elements_text(p_slots) x;
  if (select count(distinct u) from unnest(slots) u)<>4
     or exists (select 1 from unnest(slots) u where not b.bank ? u::text) then raise exception 'bad slots' using errcode='P0001'; end if;
  seq:=array[b.start_id]||slots||b.end_id;
  ok:=true;
  for i in 1..5 loop
    if not exists (select 1 from public.chain_direct(p_family) r where r.a=least(seq[i],seq[i+1]) and r.b=greatest(seq[i],seq[i+1])) then ok:=false; exit; end if;
  end loop;
  if ok then
    sc:=greatest(1,5-a.submissions-jsonb_array_length(a.hints)); -- מתחילים מ-5, פחות נקודה על כל ניסיון כושל וכל רמז
    update public.chain_attempts set finished_at=p_at,end_reason='complete',score=sc where family_id=p_family and day=p_day and user_id=p_uid;
    return public.chain_state_internal(p_family,p_day,p_at,p_uid)||jsonb_build_object('last_result','won');
  end if;
  -- failed submission: lock every placed name that sits in its slot in some valid bank chain; the rest return to the bank
  select array_agg(x::uuid order by ord) into locked_ids from jsonb_array_elements_text(a.locked) with ordinality t(x,ord);
  new_locked:='[]'::jsonb;
  for i in 0..3 loop
    if locked_ids[i+1] is not null then
      new_locked:=new_locked||to_jsonb(locked_ids[i+1]);
    elsif exists (select 1 from public.chain_paths(p_family,b.start_id,b.end_id,b.bank) p where p.path[i+2]=slots[i+1]) then
      new_locked:=new_locked||to_jsonb(slots[i+1]);
    else
      new_locked:=new_locked||'null'::jsonb;
    end if;
  end loop;
  update public.chain_attempts set submissions=submissions+1, tries_left=tries_left-1, locked=new_locked
   where family_id=p_family and day=p_day and user_id=p_uid returning * into a;
  if a.tries_left<=0 then
    update public.chain_attempts set finished_at=p_at,end_reason='out_of_tries',score=0 where family_id=p_family and day=p_day and user_id=p_uid;
    return public.chain_state_internal(p_family,p_day,p_at,p_uid)||jsonb_build_object('last_result','lost');
  end if;
  return public.chain_state_internal(p_family,p_day,p_at,p_uid)||jsonb_build_object('last_result','wrong');
end $$;

-- ---- personal scoreboard: day / week (Sunday-Saturday) / calendar year, same rules as the other games ----
create or replace function public.chain_rankings_internal(p_family uuid, p_at timestamptz) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare d date:=(p_at at time zone 'Asia/Jerusalem')::date; w date; y date; daily jsonb; weekly jsonb; annual jsonb; first_day date;
begin
  w:=d-extract(dow from d)::int; y:=make_date(extract(year from d)::int,1,1);
  update public.chain_attempts set finished_at=deadline,end_reason='timeout',score=0
   where family_id=p_family and finished_at is null and p_at>deadline;
  select coalesce(jsonb_agg(jsonb_build_object('name',nm,'score',sc,'is_me',user_id=auth.uid()) order by sc desc,finished_at,nm,user_id),'[]'::jsonb) into daily
  from (select a.user_id,a.finished_at,coalesce(a.score,0) sc,
        coalesce((select p.full_name from public.identity_claims c join public.people p on p.id=c.person_id and p.family_id=p_family where c.user_id=a.user_id and c.family_id=p_family and c.status='verified' order by c.created_at desc limit 1),'חבר משפחה') nm
        from public.chain_attempts a where a.family_id=p_family and a.day=d and a.finished_at is not null) z;
  with registered as (
    select m.user_id,card.full_name from public.family_members m join lateral (
      select p.full_name from public.identity_claims c join public.people p on p.id=c.person_id and p.family_id=p_family
      where c.user_id=m.user_id and c.family_id=p_family and c.status='verified' order by c.created_at desc,c.person_id limit 1) card on true
    where m.family_id=p_family and m.status='active'
  ), sc as (
    select a.user_id,
      sum(a.score) filter (where a.day>=y)::bigint year_score,
      coalesce(sum(a.score) filter (where a.day>=w),0)::bigint week_score,
      max(a.finished_at) last_finish, max(a.finished_at) filter (where a.day>=w) week_finish
    from public.chain_attempts a where a.family_id=p_family and a.day>=least(w,y) and a.day<=d and a.finished_at is not null group by a.user_id
  )
  select coalesce(jsonb_agg(jsonb_build_object('name',r.full_name,'score',s.week_score,'is_me',s.user_id=auth.uid()) order by s.week_score desc,s.week_finish,r.full_name,s.user_id) filter (where s.week_score>0),'[]'::jsonb),
         coalesce(jsonb_agg(jsonb_build_object('name',r.full_name,'score',s.year_score,'is_me',s.user_id=auth.uid()) order by s.year_score desc,s.last_finish,r.full_name,s.user_id) filter (where coalesce(s.year_score,0)>0),'[]'::jsonb)
  into weekly,annual from sc s join registered r on r.user_id=s.user_id;
  select min(a.day) into first_day from public.chain_attempts a where a.family_id=p_family and a.day>=y and a.day<=d and a.finished_at is not null;
  return jsonb_build_object('day',d,'week_start',w,'week_end',w+6,'year',extract(year from d)::int,'counted_since',first_day,'daily',daily,'weekly',weekly,'annual',annual);
end $$;

create or replace function public.chain_totals_internal(p_family uuid, p_uid uuid, p_day date, p_at timestamptz) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare a public.chain_attempts; d date:=(p_at at time zone 'Asia/Jerusalem')::date; w date; cw date; ws bigint; ys bigint;
begin
  select * into a from public.chain_attempts x where x.family_id=p_family and x.day=p_day and x.user_id=p_uid and x.finished_at is not null;
  if not found then raise exception 'no finished attempt' using errcode='P0001'; end if;
  w:=p_day-extract(dow from p_day)::int; cw:=d-extract(dow from d)::int;
  select coalesce(sum(x.score),0) into ws from public.chain_attempts x where x.family_id=p_family and x.user_id=p_uid and x.finished_at is not null and x.day>=w and x.day<=w+6;
  select coalesce(sum(x.score),0) into ys from public.chain_attempts x where x.family_id=p_family and x.user_id=p_uid and x.finished_at is not null and extract(year from x.day)=extract(year from p_day);
  return jsonb_build_object('day',p_day,'score',coalesce(a.score,0),'is_today',p_day=d,
    'week',case when w=cw then ws end,'year',case when extract(year from p_day)=extract(year from d) then ys end);
end $$;

-- ---- RPCs for signed-in family members ----
create or replace function public.chain_member_check(p_family uuid) returns void
language plpgsql security definer set search_path=public,pg_temp as $$
begin if auth.uid() is null or not public.is_family_member(p_family) then raise exception 'not a family member' using errcode='42501'; end if; end $$;

create or replace function public.chain_active_day(p_family uuid, p_uid uuid, p_at timestamptz) returns date
language sql stable security definer set search_path=public,pg_temp as $$
select coalesce((select a.day from public.chain_attempts a where a.family_id=p_family and a.user_id=p_uid and a.finished_at is null and a.deadline>=p_at order by a.day desc limit 1),(p_at at time zone 'Asia/Jerusalem')::date) $$;

create or replace function public.chain_state(p_family_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare d date;
begin perform public.chain_member_check(p_family_id); d:=public.chain_active_day(p_family_id,auth.uid(),now()); perform public.chain_ensure_board(p_family_id,d); return public.chain_state_internal(p_family_id,d,now(),auth.uid()); end $$;
create or replace function public.chain_start(p_family_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare d date;
begin perform public.chain_member_check(p_family_id); d:=public.chain_active_day(p_family_id,auth.uid(),now()); return public.chain_start_internal(p_family_id,d,now(),auth.uid()); end $$;
create or replace function public.chain_hint(p_family_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare d date;
begin perform public.chain_member_check(p_family_id); d:=public.chain_active_day(p_family_id,auth.uid(),now()); return public.chain_hint_internal(p_family_id,d,now(),auth.uid()); end $$;
create or replace function public.chain_check(p_family_id uuid, p_slots jsonb) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare d date;
begin perform public.chain_member_check(p_family_id); d:=public.chain_active_day(p_family_id,auth.uid(),now()); return public.chain_check_internal(p_family_id,d,now(),auth.uid(),p_slots); end $$;
create or replace function public.chain_rankings(p_family_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
begin perform public.chain_member_check(p_family_id); return public.chain_rankings_internal(p_family_id,now()); end $$;
create or replace function public.chain_totals(p_family_id uuid, p_day date) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
begin perform public.chain_member_check(p_family_id); return public.chain_totals_internal(p_family_id,auth.uid(),p_day,now()); end $$;

do $g$
declare f text;
begin
  for f in select p.oid::regprocedure::text from pg_proc p where p.pronamespace='public'::regnamespace and p.proname like 'chain\_%' loop
    execute 'revoke all on function '||f||' from public, anon, authenticated';
  end loop;
end $g$;
grant execute on function public.chain_state(uuid), public.chain_start(uuid), public.chain_hint(uuid), public.chain_check(uuid,jsonb), public.chain_rankings(uuid), public.chain_totals(uuid,date) to authenticated;

-- CHAIN_CRON_BEGIN
do $c$ begin
  if exists (select 1 from pg_extension where extname='pg_cron')
     and not exists (select 1 from cron.job where jobname='shoshelet-chain-pregen') then
    perform cron.schedule('shoshelet-chain-pregen','30,45 20,21 * * *',
      $job$ do $x$ begin if (now() at time zone 'Asia/Jerusalem')::time between time '23:30' and time '23:59' then perform public.chain_prepare_next(); end if; end $x$; $job$);
  end if;
end $c$;
-- CHAIN_CRON_END
commit;
