-- v2.88: "מקושרים" - daily pairs game. ADDITIVE ONLY: new tables and functions with the pairs_ prefix.
-- No trivia table, trivia function, pot, medal or ranking is changed. Rollback file drops everything created here.
-- Game rules (approved): 8 people on a board, 4 different relation types, 1 point per correct pair, max 4,
-- a wrong pair closes the board and keeps what was solved, 60 seconds for the whole board counted on the server,
-- the clock keeps running when the player leaves, one board per family per Jerusalem day, prepared in advance.
begin;

create table if not exists public.pairs_boards (
  family_id uuid not null references public.families(id) on delete cascade,
  day date not null,
  cards jsonb not null default '[]'::jsonb,   -- 8 person ids in display order
  pairs jsonb not null default '[]'::jsonb,   -- [{a,b,t,s}] a<b, t=relation type, s=senior person for directional types
  void boolean not null default false,        -- set when a started board can no longer be shown safely
  built_at timestamptz not null default now(),
  primary key (family_id, day)
);
create table if not exists public.pairs_attempts (
  family_id uuid not null,
  day date not null,
  user_id uuid not null,
  started_at timestamptz not null,
  deadline timestamptz not null,
  solved jsonb not null default '[]'::jsonb,   -- indexes into pairs_boards.pairs
  finished_at timestamptz,
  end_reason text check (end_reason in ('complete','timeout','mistake')),
  primary key (family_id, day, user_id),
  foreign key (family_id, day) references public.pairs_boards(family_id, day) on delete cascade
);
create table if not exists public.pairs_awards (
  user_id uuid not null,
  family_id uuid not null references public.families(id) on delete cascade,
  medal text not null,
  run_start date,
  run_end date,
  created_at timestamptz not null default now(),
  primary key (user_id, family_id, medal)
);
create table if not exists public.pairs_build_log (
  id bigserial primary key,
  family_id uuid,
  day date,
  status text not null,
  message text,
  at timestamptz not null default now()
);
alter table public.pairs_boards enable row level security;
alter table public.pairs_attempts enable row level security;
alter table public.pairs_awards enable row level security;
alter table public.pairs_build_log enable row level security;
revoke all on public.pairs_boards, public.pairs_attempts, public.pairs_awards, public.pairs_build_log from public, anon, authenticated;

create or replace function public.pairs_config() returns jsonb
language sql immutable set search_path=public,pg_temp as
$$ select jsonb_build_object('seconds',60,'grace_seconds',2,'pairs',4,'streak_days',7,'streak_start','2026-11-07','tz','Asia/Jerusalem') $$;

-- Every relation between two people that the game can ask about. Endpoints must have a unique full name in the family.
-- Paths may go through people who are not eligible. "intended" = may be the answer of a board; the rest only blocks ambiguity.
-- a<b always; senior = the parent / grandparent / uncle for directional types.
create or replace function public.pairs_relations(p_family uuid)
returns table(a uuid, b uuid, rtype text, intended boolean, senior uuid)
language sql stable security definer set search_path=public,pg_temp as $$
with ppl as materialized (
  select p.id, btrim(p.full_name) nm, nullif(lower(btrim(p.city)),'') city, p.birth_month bm, p.birth_day bd,
         coalesce(p.is_deceased, p.death_date is not null) dead
  from public.people p where p.family_id=p_family and p.full_name is not null and btrim(p.full_name)<>''
), uniq as materialized (
  select id,nm,city,bm,bd,dead from (select ppl.*, count(*) over (partition by nm) n from ppl) z where n=1
), pca as materialized (
  select r.parent_id p, r.child_id c, bool_or(r.status='confirmed') conf
  from public.parent_child r where r.family_id=p_family and r.parent_id<>r.child_id group by 1,2
), sib0 as materialized (
  select x.c a, y.c b, bool_or(x.conf and y.conf) conf from pca x join pca y on y.p=x.p and x.c<y.c group by 1,2
  union all
  select least(d.person_a,d.person_b), greatest(d.person_a,d.person_b), true from public.sibling_declarations d where d.family_id=p_family
), sib as materialized (
  select a,b,bool_or(conf) conf from sib0 group by 1,2
), sibd as materialized (
  select a,b,conf from sib union all select b,a,conf from sib
), mates as materialized (
  select u.person_a a, u.person_b b, (u.status in ('active','widowed')) cur from public.unions u where u.family_id=p_family
), mates2 as materialized (
  select a,b,cur from mates union all select b,a,cur from mates
), gp as materialized (
  select x.p g, y.c c, bool_or(x.conf and y.conf) conf from pca x join pca y on y.p=x.c where x.p<>y.c group by 1,2
), ub as materialized (
  select s.a u, pc.c n, bool_or(s.conf and pc.conf) conf from sibd s join pca pc on pc.p=s.b where s.a<>pc.c group by 1,2
), rel as materialized (
  select p x, c y, 'parent_child'::text t, conf intended, p senior from pca
  union all select a,b,'spouse',cur,null::uuid from mates
  union all select a,b,'sibling',conf,null::uuid from sib
  union all select g,c,'grandparent',conf,g from gp
  union all select u,n,'uncle_nephew',conf,u from ub
  union all select m.a,u.n,'uncle_nephew',false,m.a from mates2 m join ub u on u.u=m.b where m.a<>u.n
  union all select c1.c,c2.c,'cousin',(s.conf and c1.conf and c2.conf),null::uuid
    from sibd s join pca c1 on c1.p=s.a join pca c2 on c2.p=s.b where c1.c<>c2.c and c1.c<>s.b and c2.c<>s.a
  union all select x.id,y.id,'same_month',true,null::uuid from uniq x join uniq y on x.id<y.id
    where not x.dead and not y.dead and x.bm between 1 and 12 and x.bd between 1 and 31 and y.bd between 1 and 31 and y.bm=x.bm
  union all select x.id,y.id,'same_city',true,null::uuid from uniq x join uniq y on x.id<y.id
    where not x.dead and not y.dead and x.city is not null and y.city=x.city
  union all select x.id,y.id,'same_day',true,null::uuid from uniq x join uniq y on x.id<y.id
    where not x.dead and not y.dead and x.bm between 1 and 12 and x.bd between 1 and 31 and y.bm between 1 and 12 and y.bd=x.bd
)
select least(r.x,r.y), greatest(r.x,r.y), r.t, bool_or(r.intended), (array_agg(r.senior))[1]
from rel r join uniq ux on ux.id=r.x join uniq uy on uy.id=r.y
group by 1,2,3
$$;

-- Does a stored board still hold against the live tree? Used before every show / pick / reveal.
create or replace function public.pairs_check(p_family uuid, p_cards jsonb, p_pairs jsonb) returns boolean
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare ids uuid[]; types text[]; n int; bad int; per int;
begin
  select array_agg(x::uuid) into ids from jsonb_array_elements_text(p_cards) x;
  if ids is null or cardinality(ids)<>8 or (select count(distinct i) from unnest(ids) i)<>8 then return false; end if;
  if jsonb_array_length(p_pairs)<>4 then return false; end if;
  select array_agg(distinct e->>'t') into types from jsonb_array_elements(p_pairs) e;
  if cardinality(types)<>4 then return false; end if;
  if (select count(*) from public.people where family_id=p_family and id=any(ids))<>8 then return false; end if;
  -- no card name may be shared with anyone else in the family
  if exists (select 1 from public.people c where c.family_id=p_family and c.id=any(ids)
             and (select count(*) from public.people o where o.family_id=p_family and btrim(o.full_name)=btrim(c.full_name))<>1) then return false; end if;
  with r as (select * from public.pairs_relations(p_family) x where x.a=any(ids) and x.b=any(ids) and x.rtype=any(types))
  select count(*), count(*) filter (where not exists (
      select 1 from jsonb_array_elements(p_pairs) e where (e->>'a')::uuid=r.a and (e->>'b')::uuid=r.b and e->>'t'=r.rtype and r.intended))
  into n, bad from r;
  return n=4 and bad=0;
end $$;

-- Builds one board or an empty marker when no unambiguous board exists. Nothing is stored here.
create or replace function public.pairs_build_board(p_family uuid, p_day date) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare avail text[]; types text[]; persons uuid[]; picks jsonb; i int; cnt int; cards jsonb; tries int:=2000;
begin
  drop table if exists pg_temp.t_prel; drop table if exists pg_temp.t_prec;
  create temp table t_prel on commit drop as select * from public.pairs_relations(p_family);
  analyze pg_temp.t_prel;
  create temp table t_prec on commit drop as
    select (e->>'a')::uuid a,(e->>'b')::uuid b,e->>'t' t from public.pairs_boards bd, jsonb_array_elements(bd.pairs) e
    where bd.family_id=p_family and bd.day<p_day and bd.day>=p_day-21;
  select array_agg(distinct rtype) into avail from t_prel where intended;
  if avail is null or cardinality(avail)<4 then return jsonb_build_object('cards','[]'::jsonb,'pairs','[]'::jsonb); end if;
  for i in 1..tries loop
    select array_agg(t) into types from (select t from unnest(avail) t order by random() limit 4) z;
    select jsonb_agg(jsonb_build_object('a',a,'b',b,'t',rtype,'s',senior)) into picks from (
      select distinct on (r.rtype) r.a,r.b,r.rtype,r.senior from t_prel r
      where r.intended and r.rtype=any(types)
        and (i>250 or not exists (select 1 from t_prec c where c.a=r.a and c.b=r.b and c.t=r.rtype))
      order by r.rtype, random()) z;
    continue when picks is null or jsonb_array_length(picks)<>4;
    select array_agg(x) into persons from (select (e->>'a')::uuid x from jsonb_array_elements(picks) e union all select (e->>'b')::uuid from jsonb_array_elements(picks) e) z;
    continue when (select count(distinct x) from unnest(persons) x)<>8;
    select count(*) into cnt from t_prel r where r.a=any(persons) and r.b=any(persons) and r.rtype=any(types);
    continue when cnt<>4;
    select jsonb_agg(x order by random()) into cards from unnest(persons) x;
    return jsonb_build_object('cards',cards,'pairs',picks);
  end loop;
  return jsonb_build_object('cards','[]'::jsonb,'pairs','[]'::jsonb);
end $$;

create or replace function public.pairs_ensure_board(p_family uuid, p_day date) returns void
language plpgsql security definer set search_path=public,pg_temp as $$
declare b jsonb; ex public.pairs_boards;
begin
  select * into ex from public.pairs_boards where family_id=p_family and day=p_day;
  if found and not (jsonb_array_length(ex.pairs)=0 and ex.built_at<now()-interval '60 minutes'
                    and not exists (select 1 from public.pairs_attempts a where a.family_id=p_family and a.day=p_day)) then return; end if;
  perform pg_advisory_xact_lock(hashtextextended('pairs'||p_family::text||p_day::text,0));
  select * into ex from public.pairs_boards where family_id=p_family and day=p_day;
  if found and not (jsonb_array_length(ex.pairs)=0 and ex.built_at<now()-interval '60 minutes'
                    and not exists (select 1 from public.pairs_attempts a where a.family_id=p_family and a.day=p_day)) then return; end if;
  b:=public.pairs_build_board(p_family,p_day);
  insert into public.pairs_boards(family_id,day,cards,pairs) values (p_family,p_day,b->'cards',b->'pairs')
  on conflict (family_id,day) do update set cards=excluded.cards,pairs=excluded.pairs,built_at=now(),void=false
  where jsonb_array_length(public.pairs_boards.pairs)=0 and not exists (select 1 from public.pairs_attempts a where a.family_id=public.pairs_boards.family_id and a.day=public.pairs_boards.day);
  insert into public.pairs_build_log(family_id,day,status,message) values (p_family,p_day,case when jsonb_array_length(b->'pairs')=4 then 'built' else 'empty' end,null);
end $$;

-- Nightly preparation for tomorrow. Same families as the trivia job, plus families that already played this game.
create or replace function public.pairs_prepare_next() returns int
language plpgsql security definer set search_path=public,pg_temp as $$
declare f record; d date; n int:=0;
begin
  d:=(now() at time zone 'Asia/Jerusalem')::date+1;
  for f in select family_id from (
      select family_id from public.trivia_sets where day>=d-8
      union select family_id from public.trivia_attempts where day>=d-8
      union select family_id from public.pairs_boards where day>=d-8) x loop
    begin
      perform public.pairs_ensure_board(f.family_id,d); n:=n+1;
    exception when others then
      insert into public.pairs_build_log(family_id,day,status,message) values (f.family_id,d,'error',left(sqlerrm,300));
    end;
  end loop;
  return n;
end $$;

-- Health for the existing monitoring: families that should have a board for the given day but do not, and recent build errors.
create or replace function public.pairs_health(p_day date default null) returns jsonb
language sql stable security definer set search_path=public,pg_temp as $$
with d as (select coalesce(p_day,(now() at time zone 'Asia/Jerusalem')::date) as day),
fam as (select distinct family_id from public.trivia_sets s,d where s.day>=d.day-8 union select family_id from public.pairs_boards b,d where b.day>=d.day-8)
select jsonb_build_object('day',(select day from d),
 'families_without_board',(select count(*) from fam f,d where not exists (select 1 from public.pairs_boards b where b.family_id=f.family_id and b.day=d.day)),
 'empty_boards',(select count(*) from public.pairs_boards b,d where b.day=d.day and jsonb_array_length(b.pairs)=0),
 'errors_last_day',(select count(*) from public.pairs_build_log l where l.status='error' and l.at>now()-interval '1 day'))
$$;

create or replace function public.pairs_word(p_kind text, p_senior boolean, p_g text) returns text
language sql immutable set search_path=public,pg_temp as $$
select case p_kind
 when 'parent_child' then case when p_senior then case p_g when 'male' then 'אב' when 'female' then 'אם' else 'הורה' end
                                               else case p_g when 'male' then 'בן' when 'female' then 'בת' else 'ילד/ה' end end
 when 'grandparent' then case when p_senior then case p_g when 'male' then 'סבא' when 'female' then 'סבתא' else 'סבא/סבתא' end
                                               else case p_g when 'male' then 'נכד' when 'female' then 'נכדה' else 'נכד/ה' end end
 when 'uncle_nephew' then case when p_senior then case p_g when 'male' then 'דוד' when 'female' then 'דודה' else 'דוד/ה' end
                                               else case p_g when 'male' then 'אחיין' when 'female' then 'אחיינית' else 'אחיין/ית' end end
 end $$;

-- Chip text for a relation type of one board pair, from the live genders (draft wording).
create or replace function public.pairs_label(p_type text, p_a uuid, p_b uuid, p_senior uuid) returns text
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare ga text; gb text; s uuid; j uuid;
begin
  if p_type in ('parent_child','grandparent','uncle_nephew') then
    s:=coalesce(p_senior,p_a); j:=case when s=p_a then p_b else p_a end;
    select gender::text into ga from public.people where id=s; select gender::text into gb from public.people where id=j;
    return public.pairs_word(p_type,true,ga)||' ו'||public.pairs_word(p_type,false,gb);
  end if;
  return case p_type when 'spouse' then 'בני זוג' when 'sibling' then 'אחים' when 'cousin' then 'בני דודים'
    when 'same_month' then 'אותו חודש לידה' when 'same_city' then 'אותה עיר' when 'same_day' then 'אותו יום בחודש' else p_type end;
end $$;

-- One-line explanation for the end screen (draft wording). Built from live data and only when the relation still holds.
create or replace function public.pairs_explain(p_family uuid, p_type text, p_a uuid, p_b uuid, p_senior uuid, p_holds boolean) returns text
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare pa public.people; pb public.people; sp public.people; jn public.people; m text[]:=array['בינואר','בפברואר','במרץ','באפריל','במאי','ביוני','ביולי','באוגוסט','בספטמבר','באוקטובר','בנובמבר','בדצמבר'];
 fa text; fb text; fs text; fj text;
begin
  if not p_holds then return null; end if;
  select * into pa from public.people where id=p_a and family_id=p_family; select * into pb from public.people where id=p_b and family_id=p_family;
  if pa.id is null or pb.id is null then return null; end if;
  if p_senior is not null then sp:=case when p_senior=p_a then pa else pb end; jn:=case when p_senior=p_a then pb else pa end; fs:=split_part(btrim(sp.full_name),' ',1); fj:=split_part(btrim(jn.full_name),' ',1); end if;
  fa:=split_part(btrim(pa.full_name),' ',1); fb:=split_part(btrim(pb.full_name),' ',1);
  return case p_type
   when 'parent_child' then fs||case sp.gender::text when 'female' then ' היא האמא של ' when 'male' then ' הוא האבא של ' else ' הוא/היא ההורה של ' end||fj
   when 'grandparent' then fs||case sp.gender::text when 'female' then ' היא הסבתא של ' when 'male' then ' הוא הסבא של ' else ' הוא/היא הסבא/סבתא של ' end||fj
   when 'uncle_nephew' then fs||case sp.gender::text when 'female' then ' היא הדודה של ' when 'male' then ' הוא הדוד של ' else ' הוא/היא הדוד/ה של ' end||fj
   when 'spouse' then fa||' ו'||fb||' רשומים כבני זוג'
   when 'sibling' then case when exists (select 1 from public.parent_child x join public.parent_child y on y.parent_id=x.parent_id where x.family_id=p_family and y.family_id=p_family and x.child_id=p_a and y.child_id=p_b) then 'יש להם הורה משותף' else 'רשומים כאחים' end
   when 'cousin' then 'ההורים שלהם הם אחים'
   when 'same_month' then case when pa.birth_month between 1 and 12 and pa.birth_month=pb.birth_month then 'שניהם נולדו '||m[pa.birth_month] end
   when 'same_city' then case when nullif(lower(btrim(pa.city)),'') is not null and lower(btrim(pa.city))=lower(btrim(pb.city)) then 'אותה עיר: '||btrim(pa.city) end
   when 'same_day' then case when pa.birth_day is not null and pa.birth_day=pb.birth_day then 'שניהם נולדו ב-'||pa.birth_day||' בחודש' end
  end;
end $$;

-- ---- play ----
create or replace function public.pairs_names(p_family uuid, p_ids jsonb) returns jsonb
language sql stable security definer set search_path=public,pg_temp as $$
select coalesce(jsonb_agg(jsonb_build_object('id',x,'name',(select btrim(p.full_name) from public.people p where p.id=x::uuid and p.family_id=p_family)) order by ord),'[]'::jsonb)
from jsonb_array_elements_text(p_ids) with ordinality t(x,ord) $$;

create or replace function public.pairs_solved_json(p_family uuid, p_b public.pairs_boards, p_a public.pairs_attempts) returns jsonb
language sql stable security definer set search_path=public,pg_temp as $$
select coalesce(jsonb_agg(jsonb_build_object('idx',i::int,'t',e->>'t','label',public.pairs_label(e->>'t',(e->>'a')::uuid,(e->>'b')::uuid,nullif(e->>'s','')::uuid),
  'a',jsonb_build_object('id',e->>'a','nick',(select nullif(btrim(p.nickname),'') from public.people p where p.id=(e->>'a')::uuid)),
  'b',jsonb_build_object('id',e->>'b','nick',(select nullif(btrim(p.nickname),'') from public.people p where p.id=(e->>'b')::uuid))) order by i),'[]'::jsonb)
from jsonb_array_elements(p_a.solved) s(i), lateral (select p_b.pairs->(s.i::text::int) e) q $$;

create or replace function public.pairs_types_json(p_b public.pairs_boards) returns jsonb
language sql stable security definer set search_path=public,pg_temp as $$
select coalesce(jsonb_agg(jsonb_build_object('idx',(ord-1)::int,'t',e->>'t','label',public.pairs_label(e->>'t',(e->>'a')::uuid,(e->>'b')::uuid,nullif(e->>'s','')::uuid)) order by ord),'[]'::jsonb)
from jsonb_array_elements(p_b.pairs) with ordinality t(e,ord) $$;

create or replace function public.pairs_done_json(p_family uuid, p_b public.pairs_boards, p_a public.pairs_attempts) returns jsonb
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare ids uuid[]; rows jsonb;
begin
  select array_agg(x::uuid) into ids from jsonb_array_elements_text(p_b.cards) x;
  select coalesce(jsonb_agg(jsonb_build_object('idx',(ord-1)::int,'t',e->>'t','label',public.pairs_label(e->>'t',(e->>'a')::uuid,(e->>'b')::uuid,nullif(e->>'s','')::uuid),
     'solved',(p_a.solved @> to_jsonb((ord-1)::int)),
     'a',(select jsonb_build_object('id',p.id,'name',btrim(p.full_name)) from public.people p where p.id=(e->>'a')::uuid and p.family_id=p_family),
     'b',(select jsonb_build_object('id',p.id,'name',btrim(p.full_name)) from public.people p where p.id=(e->>'b')::uuid and p.family_id=p_family),
     'explain',public.pairs_explain(p_family,e->>'t',(e->>'a')::uuid,(e->>'b')::uuid,nullif(e->>'s','')::uuid,
        exists (select 1 from public.pairs_relations(p_family) r where r.a=(e->>'a')::uuid and r.b=(e->>'b')::uuid and r.rtype=e->>'t' and r.intended))
     ) order by ord),'[]'::jsonb) into rows
  from jsonb_array_elements(p_b.pairs) with ordinality t(e,ord);
  return jsonb_build_object('day',p_a.day,'phase','done','score',jsonb_array_length(p_a.solved),'total',4,'reason',p_a.end_reason,'solution',rows);
end $$;

create or replace function public.pairs_state_internal(p_family uuid, p_day date, p_at timestamptz, p_uid uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare cfg jsonb:=public.pairs_config(); b public.pairs_boards; a public.pairs_attempts; grace interval;
begin
  grace:=make_interval(secs=>(cfg->>'grace_seconds')::int);
  select * into b from public.pairs_boards where family_id=p_family and day=p_day;
  if not found or jsonb_array_length(b.pairs)=0 then return jsonb_build_object('day',p_day,'phase','empty'); end if;
  select * into a from public.pairs_attempts where family_id=p_family and day=p_day and user_id=p_uid for update;
  if not found then
    if b.void then return jsonb_build_object('day',p_day,'phase','unavailable'); end if;
    return jsonb_build_object('day',p_day,'phase','ready','seconds',(cfg->>'seconds')::int);
  end if;
  if a.finished_at is null and p_at>a.deadline+grace then
    update public.pairs_attempts set finished_at=deadline,end_reason='timeout' where family_id=p_family and day=p_day and user_id=p_uid returning * into a;
  end if;
  if a.finished_at is not null then return public.pairs_done_json(p_family,b,a); end if;
  if b.void or not public.pairs_check(p_family,b.cards,b.pairs) then
    update public.pairs_boards set void=true where family_id=p_family and day=p_day;
    return jsonb_build_object('day',p_day,'phase','unavailable');
  end if;
  return jsonb_build_object('day',p_day,'phase','playing','seconds',(cfg->>'seconds')::int,
    'remaining_ms',greatest(0,(extract(epoch from (a.deadline-p_at))*1000)::int),
    'cards',public.pairs_names(p_family,b.cards),'types',public.pairs_types_json(b),'solved',public.pairs_solved_json(p_family,b,a),'score',jsonb_array_length(a.solved));
end $$;

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

create or replace function public.pairs_grant(p_family uuid, p_user uuid) returns void
language plpgsql security definer set search_path=public,pg_temp as $$
declare cfg jsonb:=public.pairs_config(); ending date;
begin
  if exists (select 1 from public.pairs_awards where user_id=p_user and family_id=p_family and medal='perfect_pairs_week') then return; end if;
  with perfect as (
    select a.day from public.pairs_attempts a where a.family_id=p_family and a.user_id=p_user and a.finished_at is not null
      and a.end_reason='complete' and jsonb_array_length(a.solved)=4 and a.day>=(cfg->>'streak_start')::date
  ), runs as (select day, day-(row_number() over (order by day))::int grp from perfect)
  select min(first_day+((cfg->>'streak_days')::int-1)) into ending from (select min(day) first_day from runs group by grp having count(*)>=(cfg->>'streak_days')::int) z;
  if ending is not null then
    insert into public.pairs_awards(user_id,family_id,medal,run_start,run_end) values (p_user,p_family,'perfect_pairs_week',ending-((cfg->>'streak_days')::int-1),ending) on conflict do nothing;
  end if;
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

-- ---- personal scoreboard: day / week (Sunday-Saturday) / calendar year, same rules as the trivia boards ----
create or replace function public.pairs_rankings_internal(p_family uuid, p_at timestamptz) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare cfg jsonb:=public.pairs_config(); d date:=(p_at at time zone 'Asia/Jerusalem')::date; w date; y date; daily jsonb; weekly jsonb; annual jsonb; first_day date;
begin
  w:=d-extract(dow from d)::int; y:=make_date(extract(year from d)::int,1,1);
  update public.pairs_attempts set finished_at=deadline,end_reason='timeout'
   where family_id=p_family and finished_at is null and p_at>deadline+make_interval(secs=>(cfg->>'grace_seconds')::int);
  select coalesce(jsonb_agg(jsonb_build_object('name',nm,'score',sc,'is_me',user_id=auth.uid()) order by sc desc,finished_at,nm,user_id),'[]'::jsonb) into daily
  from (select a.user_id,a.finished_at,jsonb_array_length(a.solved) sc,
        coalesce((select p.full_name from public.identity_claims c join public.people p on p.id=c.person_id and p.family_id=p_family where c.user_id=a.user_id and c.family_id=p_family and c.status='verified' order by c.created_at desc limit 1),'חבר משפחה') nm
        from public.pairs_attempts a where a.family_id=p_family and a.day=d and a.finished_at is not null) z;
  with registered as (
    select m.user_id,card.full_name from public.family_members m join lateral (
      select p.full_name from public.identity_claims c join public.people p on p.id=c.person_id and p.family_id=p_family
      where c.user_id=m.user_id and c.family_id=p_family and c.status='verified' order by c.created_at desc,c.person_id limit 1) card on true
    where m.family_id=p_family and m.status='active'
  ), sc as (
    select a.user_id,
      sum(jsonb_array_length(a.solved)) filter (where a.day>=y)::bigint year_score,
      coalesce(sum(jsonb_array_length(a.solved)) filter (where a.day>=w),0)::bigint week_score,
      max(a.finished_at) last_finish, max(a.finished_at) filter (where a.day>=w) week_finish
    from public.pairs_attempts a where a.family_id=p_family and a.day>=least(w,y) and a.day<=d and a.finished_at is not null group by a.user_id
  )
  select coalesce(jsonb_agg(jsonb_build_object('name',r.full_name,'score',s.week_score,'is_me',s.user_id=auth.uid()) order by s.week_score desc,s.week_finish,r.full_name,s.user_id) filter (where s.week_score>0),'[]'::jsonb),
         coalesce(jsonb_agg(jsonb_build_object('name',r.full_name,'score',s.year_score,'is_me',s.user_id=auth.uid()) order by s.year_score desc,s.last_finish,r.full_name,s.user_id) filter (where coalesce(s.year_score,0)>0),'[]'::jsonb)
  into weekly,annual from sc s join registered r on r.user_id=s.user_id;
  select min(a.day) into first_day from public.pairs_attempts a where a.family_id=p_family and a.day>=y and a.day<=d and a.finished_at is not null;
  return jsonb_build_object('day',d,'week_start',w,'week_end',w+6,'year',extract(year from d)::int,'counted_since',first_day,'daily',daily,'weekly',weekly,'annual',annual);
end $$;

create or replace function public.pairs_medals_internal(p_family uuid, p_uid uuid, p_at timestamptz) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare cfg jsonb:=public.pairs_config(); d date:=(p_at at time zone 'Asia/Jerusalem')::date; aw public.pairs_awards; streak int:=0; lastd date;
begin
  update public.pairs_attempts set finished_at=deadline,end_reason='timeout'
   where family_id=p_family and user_id=p_uid and finished_at is null and p_at>deadline+make_interval(secs=>(cfg->>'grace_seconds')::int);
  perform public.pairs_grant(p_family,p_uid);
  select * into aw from public.pairs_awards where user_id=p_uid and family_id=p_family and medal='perfect_pairs_week';
  with perfect as (select a.day from public.pairs_attempts a where a.family_id=p_family and a.user_id=p_uid and a.finished_at is not null and a.end_reason='complete' and jsonb_array_length(a.solved)=4 and a.day>=(cfg->>'streak_start')::date and a.day<=d),
  runs as (select day, day-(row_number() over (order by day))::int grp from perfect),
  lastrun as (select count(*) n, max(day) last_day from runs group by grp order by max(day) desc limit 1)
  select n, last_day into streak, lastd from lastrun;
  if lastd is null or lastd<d-1 then streak:=0; end if;
  return jsonb_build_object('awarded',aw.user_id is not null,'run_start',aw.run_start,'run_end',aw.run_end,'streak',least(coalesce(streak,0),(cfg->>'streak_days')::int),'target',(cfg->>'streak_days')::int);
end $$;

-- ---- RPCs for signed-in family members ----
create or replace function public.pairs_member_check(p_family uuid) returns void
language plpgsql security definer set search_path=public,pg_temp as $$
begin if auth.uid() is null or not public.is_family_member(p_family) then raise exception 'not a family member' using errcode='42501'; end if; end $$;

create or replace function public.pairs_state(p_family_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare d date:=(now() at time zone 'Asia/Jerusalem')::date;
begin perform public.pairs_member_check(p_family_id); perform public.pairs_ensure_board(p_family_id,d); return public.pairs_state_internal(p_family_id,d,now(),auth.uid()); end $$;
create or replace function public.pairs_start(p_family_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare d date:=(now() at time zone 'Asia/Jerusalem')::date;
begin perform public.pairs_member_check(p_family_id); return public.pairs_start_internal(p_family_id,d,now(),auth.uid()); end $$;
create or replace function public.pairs_pick(p_family_id uuid, p_a uuid, p_b uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare d date:=(now() at time zone 'Asia/Jerusalem')::date;
begin perform public.pairs_member_check(p_family_id); return public.pairs_pick_internal(p_family_id,d,now(),auth.uid(),p_a,p_b); end $$;
create or replace function public.pairs_rankings(p_family_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
begin perform public.pairs_member_check(p_family_id); return public.pairs_rankings_internal(p_family_id,now()); end $$;
create or replace function public.pairs_medals(p_family_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
begin perform public.pairs_member_check(p_family_id); return public.pairs_medals_internal(p_family_id,auth.uid(),now()); end $$;

do $g$
declare f text;
begin
  for f in select p.oid::regprocedure::text from pg_proc p where p.pronamespace='public'::regnamespace and p.proname like 'pairs\_%' loop
    execute 'revoke all on function '||f||' from public, anon, authenticated';
  end loop;
end $g$;
grant execute on function public.pairs_state(uuid), public.pairs_start(uuid), public.pairs_pick(uuid,uuid,uuid), public.pairs_rankings(uuid), public.pairs_medals(uuid) to authenticated;

-- PAIRS_CRON_BEGIN
do $c$ begin
  if exists (select 1 from pg_extension where extname='pg_cron') then
    perform cron.schedule('shoshelet-pairs-pregen','30,45 20,21 * * *',
      $job$ do $x$ begin if (now() at time zone 'Asia/Jerusalem')::time between time '23:30' and time '23:59' then perform public.pairs_prepare_next(); end if; end $x$; $job$);
  end if;
end $c$;
-- PAIRS_CRON_END
commit;
