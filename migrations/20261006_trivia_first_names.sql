CREATE OR REPLACE FUNCTION public.trivia_build_set(p_family uuid, p_day date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  STR jsonb := public.trivia_strings();
  want int := (public.trivia_config()->>'questions')::int;
  res jsonb;
begin
  drop table if exists pg_temp.t_p; drop table if exists pg_temp.t_pc; drop table if exists pg_temp.t_u; drop table if exists pg_temp.t_c; drop table if exists pg_temp.t_sel;
  -- people with labels (same-name rule: add a distinguishing detail or the person is not used)
  create temp table t_p on commit drop as
  with base as (
    select p.id, p.full_name, p.gender::text g, p.nickname, p.city, p.birth_day, p.birth_month, p.former_surname,
           (p.death_date is not null) dead,
           (regexp_match(btrim(p.full_name),'^\S+'))[1] fname,
           (select min(pp.full_name) from public.parent_child pc join public.people pp on pp.id=pc.parent_id
              where pc.child_id=p.id and pc.family_id=p_family and pc.status='confirmed') first_parent,
           (select cp.birth_year from public.contact_privacy cp where cp.person_id=p.id and cp.show_birth_year) byear
    from public.people p where p.family_id=p_family
  ), dup as (
    select b.*, coalesce((regexp_match(btrim(b.first_parent),'^\S+'))[1],'') pfname, count(*) over (partition by full_name) n_same,
           count(*) over (partition by full_name, coalesce(former_surname,'')) n_same_fs
    from base b
  ), lab as (
    select d.*,
      case
        when n_same=1 then full_name
        when former_surname is not null and n_same_fs=1 then full_name || replace(STR->>'q_former','{x}',former_surname)
        when first_parent is not null and g='female' then full_name || replace(STR->>'q_daughter','{x}',first_parent)
        when first_parent is not null and g='male' then full_name || replace(STR->>'q_son','{x}',first_parent)
        else null end label
    from dup d
  )
  select l.*, (label is not null and count(*) over (partition by label)=1) ok from lab l;
  create temp table t_pc on commit drop as
    select parent_id parent, child_id child from public.parent_child where family_id=p_family and status='confirmed' group by 1,2;
  create temp table t_u on commit drop as
    select person_a a, person_b b, status::text st from public.unions where family_id=p_family
    union all select person_b, person_a, status::text from public.unions where family_id=p_family;

  create temp table t_c(qkey text, qtype text, kind text, subject uuid, qtext text, correct text, ans_ids uuid[], excl uuid[], ans_g text, extra jsonb, people uuid[]) on commit drop;

  -- mother / father
  insert into t_c select md5('mother|'||c.id), 'parents','person', c.id, replace(STR->>'mother','{x}',c.label), m.label, array[m.id], array[c.id,m.id], 'female', jsonb_build_object('adult',true), array[c.id,m.id]
  from t_p c join t_pc r on r.child=c.id join t_p m on m.id=r.parent and m.g='female' and m.ok
  where c.ok and (select count(*) from t_pc r2 join t_p m2 on m2.id=r2.parent and m2.g='female' where r2.child=c.id)=1;
  insert into t_c select md5('father|'||c.id), 'parents','person', c.id, replace(STR->>'father','{x}',c.label), m.label, array[m.id], array[c.id,m.id], 'male', jsonb_build_object('adult',true), array[c.id,m.id]
  from t_p c join t_pc r on r.child=c.id join t_p m on m.id=r.parent and m.g='male' and m.ok
  where c.ok and (select count(*) from t_pc r2 join t_p m2 on m2.id=r2.parent and m2.g='male' where r2.child=c.id)=1;
  -- both parents (exactly two parents, one female one male)
  insert into t_c select md5('parents|'||c.id), 'parents','pair', c.id,
     replace(case when f.dead and m.dead then STR->>'parents_past' else STR->>'parents' end,'{x}',c.label),
     f.label||(STR->>'pair_join')||m.label, array[f.id,m.id], array[c.id,f.id,m.id], null, jsonb_build_object('a',f.label,'b',m.label,'ida',f.id,'idb',m.id), array[c.id,f.id,m.id]
  from t_p c join t_pc r1 on r1.child=c.id join t_p f on f.id=r1.parent and f.g='female' and f.ok
     join t_pc r2 on r2.child=c.id join t_p m on m.id=r2.parent and m.g='male' and m.ok
  where c.ok and (select count(*) from t_pc r where r.child=c.id)=2;

  -- sibling (exactly one sister / brother through any shared parent)
  insert into t_c select md5('sister|'||c.id), 'siblings','person', c.id, replace(STR->>'sister','{x}',c.label), s.label, array[s.id], array[c.id,s.id], 'female', null, array[c.id,s.id]
  from t_p c join lateral (select distinct s2.id from t_pc a join t_pc b on b.parent=a.parent and b.child<>a.child join t_p s2 on s2.id=b.child and s2.g='female' where a.child=c.id) sx on true
  join t_p s on s.id=sx.id and s.ok
  where c.ok and (select count(distinct b.child) from t_pc a join t_pc b on b.parent=a.parent and b.child<>a.child join t_p s2 on s2.id=b.child and s2.g='female' where a.child=c.id)=1;
  insert into t_c select md5('brother|'||c.id), 'siblings','person', c.id, replace(STR->>'brother','{x}',c.label), s.label, array[s.id], array[c.id,s.id], 'male', null, array[c.id,s.id]
  from t_p c join lateral (select distinct s2.id from t_pc a join t_pc b on b.parent=a.parent and b.child<>a.child join t_p s2 on s2.id=b.child and s2.g='male' where a.child=c.id) sx on true
  join t_p s on s.id=sx.id and s.ok
  where c.ok and (select count(distinct b.child) from t_pc a join t_pc b on b.parent=a.parent and b.child<>a.child join t_p s2 on s2.id=b.child and s2.g='male' where a.child=c.id)=1;

  -- spouse (exactly one union in total, active or widowed)
  insert into t_c select md5('spouse|'||c.id), 'spouse','person', c.id,
     replace(case when s.g='male' then STR->>'spouse_m' else STR->>'spouse_f' end,'{x}',c.label), s.label, array[s.id], array[c.id,s.id], s.g, jsonb_build_object('adult',true), array[c.id,s.id]
  from t_p c join t_u u on u.a=c.id and u.st in ('active','widowed') join t_p s on s.id=u.b and s.ok and s.g in ('male','female')
  where c.ok and (select count(*) from t_u u2 where u2.a=c.id)=1;

  -- grandparents by side (needs exactly one mother and one father, and exactly one grandparent of that gender on that side)
  insert into t_c
  select md5('gp|'||c.id||'|'||side||'|'||gg), 'grandparents','person', c.id,
     replace(STR->>('gm_'||case when side='mother' then 'mat' else 'pat' end||'_'||case when gg='female' then 'f' else 'm' end),'{x}',c.label),
     g.label, array[g.id], array[c.id,par.id,g.id], gg, jsonb_build_object('adult',true), array[c.id,par.id,g.id]
  from t_p c
  cross join (values ('mother','female'),('father','male')) sd(side,pg)
  cross join (values ('female'),('male')) gx(gg)
  join t_pc r on r.child=c.id join t_p par on par.id=r.parent and par.g=sd.pg
  join t_pc r2 on r2.child=par.id join t_p g on g.id=r2.parent and g.g=gx.gg and g.ok
  where c.ok and (select count(*) from t_pc x join t_p y on y.id=x.parent where x.child=c.id and y.g=sd.pg)=1
    and (select count(*) from t_pc x join t_p y on y.id=x.parent where x.child=par.id and y.g=gx.gg)=1;

  -- counts
  insert into t_c select md5('children|'||c.id), 'counts','num', c.id, replace(STR->>'children','{x}',c.label), n::text, null, array[c.id], null, jsonb_build_object('n',n), array[c.id]
  from t_p c join lateral (select count(distinct child)::int n from t_pc where parent=c.id) k on true where c.ok and n>=2;
  insert into t_c select md5('grandchildren|'||c.id), 'counts','num', c.id, replace(STR->>'grandchildren','{x}',c.label), n::text, null, array[c.id], null, jsonb_build_object('n',n), array[c.id]
  from t_p c join lateral (select count(distinct b.child)::int n from t_pc a join t_pc b on b.parent=a.child where a.parent=c.id) k on true where c.ok and n>=2;

  -- nickname, both directions
  insert into t_c select md5('nick|'||c.id), 'nicknames','text', c.id, replace(STR->>'nick','{x}',c.label), c.nickname, null, array[c.id], null, jsonb_build_object('pool','nick'), array[c.id]
  from t_p c where c.ok and c.nickname is not null and length(trim(c.nickname))>0;
  insert into t_c select md5('nickrev|'||c.id), 'nicknames','person', c.id, replace(STR->>'nick_rev','{x}',c.nickname), c.label, array[c.id], array[c.id], case when c.g in ('male','female') then c.g end, null, array[c.id]
  from t_p c where c.ok and c.nickname is not null and length(trim(c.nickname))>0
    and (select count(*) from t_p o where o.nickname=c.nickname)=1;

  -- city (living people, city field visible on the card)
  insert into t_c select md5('city|'||c.id), 'cities','text', c.id, replace(STR->>'city','{x}',c.label), c.city, null, array[c.id], null, jsonb_build_object('pool','city'), array[c.id]
  from t_p c where c.ok and not c.dead and c.city is not null and length(trim(c.city))>0;

  -- birth month (day and month both visible on the card, living)
  insert into t_c select md5('month|'||c.id), 'birthdays','text', c.id, replace(STR->>'month','{x}',c.label), (STR->'months')->>(c.birth_month-1), null, array[c.id], null, jsonb_build_object('pool','month'), array[c.id]
  from t_p c where c.ok and not c.dead and c.birth_day is not null and c.birth_month is not null;

  -- birth year: ONLY for people who chose to share it
  insert into t_c select md5('year|'||c.id), 'birthdays','num', c.id,
     replace(case when c.g='female' then STR->>'year_f' else STR->>'year_m' end,'{x}',c.label), c.byear::text, null, array[c.id], null, jsonb_build_object('n',c.byear,'year',true), array[c.id]
  from t_p c where c.ok and c.byear is not null and c.g in ('male','female');

  -- selection: drop questions with an open report from an earlier day, prefer least recently used, vary types
  create temp table t_sel on commit drop as
  with used as (
    select q->>'key' k, max(s.day) last_day
    from public.trivia_sets s, jsonb_array_elements(s.questions) q
    where s.family_id=p_family and s.day<p_day group by 1
  ), blocked as (
    select distinct r->>'key' k from public.trivia_sets s, jsonb_array_elements(s.reports) r
    where s.family_id=p_family and s.day<p_day and coalesce(r->>'status','open')='open'
  ), cand as (
    select c.*, u.last_day, md5(p_day::text||c.qkey) h
    from t_c c left join used u on u.k=c.qkey
    where c.qkey not in (select k from blocked)
  ), ranked as (
    select cand.*, row_number() over (partition by qtype order by last_day nulls first, h) rn_type from cand
  )
  select * from ranked;
  -- build options per candidate in order of preference; skip candidates without 3 distinct distractors
  declare
    r record; opts text[]; oids uuid[]; cdisp text; cnt int := 0; qs jsonb := '[]'::jsonb; nn int;
  begin
    for r in select * from t_sel order by (case when rn_type<=2 then 0 else 1 end), (case when rn_type<=2 then rn_type else 0 end), last_day nulls first, h
    loop
      exit when cnt>=want;
      opts := null; oids := null; cdisp := null;
      if r.kind='person' then
        select array_agg(id) into oids from (select id from t_p
          where ok and not (id = any(r.excl)) and (r.ans_g is null or g=r.ans_g) and label<>r.correct
            and (r.extra->>'adult' is null or exists (select 1 from t_pc x where x.parent=t_p.id) or exists (select 1 from t_u x where x.a=t_p.id))
          order by md5(r.qkey||id::text) limit 3) d;
        if oids is null or array_length(oids,1)<3 then continue; end if;
        oids := oids || r.ans_ids[1];
        -- answer choices show the first name only; options that share a first name get a short qualifier (parent) on those options only
        select array_agg(dd.disp order by dd.pos), (array_agg(dd.disp) filter (where dd.id=r.ans_ids[1]))[1] into opts, cdisp from (
          select x.id, x.pos, case when count(*) over (partition by x.disp1)>1 then null else x.disp1 end disp from (
            select t.id, o.pos, t.label,
              case when count(*) over (partition by t.fname)=1 then t.fname
                   else (case when t.g='female' and t.pfname<>'' then t.fname||replace(STR->>'q_daughter','{x}',t.pfname)
                                      when t.g='male' and t.pfname<>'' then t.fname||replace(STR->>'q_son','{x}',t.pfname)
                                      when t.former_surname is not null then t.fname||replace(STR->>'q_former','{x}',t.former_surname) end) end disp1
            from unnest(oids) with ordinality o(id,pos) join t_p t on t.id=o.id) x) dd;
        -- a collision that cannot be told apart by a parent or former surname: skip this question rather than reveal a surname
        if exists (select 1 from unnest(opts) z where z is null) then continue; end if;
      elsif r.kind='pair' then
        select fa.fname||(STR->>'pair_join')||fb.fname into cdisp from t_p fa, t_p fb where fa.id=(r.extra->>'ida')::uuid and fb.id=(r.extra->>'idb')::uuid;
        select array_agg(l) into opts from (
          select l from (select distinct (f.fname||(STR->>'pair_join')||m.fname) l from t_p c2
            join t_pc r1 on r1.child=c2.id join t_p f on f.id=r1.parent and f.g='female' and f.ok
            join t_pc r2 on r2.child=c2.id join t_p m on m.id=r2.parent and m.g='male' and m.ok
            where (select count(*) from t_pc x where x.child=c2.id)=2
              and not (f.id=any(r.ans_ids)) and not (m.id=any(r.ans_ids))) u
          where l<>cdisp
          order by md5(r.qkey||l) limit 3) d;
      elsif r.kind='num' then
        nn := (r.extra->>'n')::int;
        select array_agg(v::text) into opts from (
          select v from unnest(case when (r.extra->>'year') is not null then array[nn-1,nn+1,nn-2,nn+2,nn-3,nn+3,nn-5,nn+5,nn-7,nn+7] else array[nn-2,nn-1,nn+1,nn+2] end) v
          where v>0 order by md5(r.qkey||v::text) limit 3) d;
      elsif r.extra->>'pool'='nick' then
        select array_agg(l) into opts from (select l from (select distinct nickname l from t_p
          where nickname is not null and length(trim(nickname))>0 and nickname<>r.correct) q0 order by md5(r.qkey||l) limit 3) d;
      elsif r.extra->>'pool'='city' then
        select array_agg(l) into opts from (select city l from (select distinct city from t_p
          where city is not null and length(trim(city))>0 and city<>r.correct) cc order by md5(r.qkey||city) limit 3) d;
      elsif r.extra->>'pool'='month' then
        select array_agg(l) into opts from (select m l from jsonb_array_elements_text(STR->'months') m where m<>r.correct order by md5(r.qkey||m) limit 3) d;
      end if;
      if opts is null or array_length(opts,1)<3 then continue; end if;
      if cdisp is null then cdisp := r.correct; opts := opts || r.correct; elsif r.kind='pair' then opts := opts || cdisp; end if;
      if (select count(distinct x) from unnest(opts) x)<>4 then continue; end if;
      select array_agg(x order by md5(p_day::text||r.qkey||x)) into opts from unnest(opts) x;
      cnt := cnt+1;
      qs := qs || jsonb_build_array(jsonb_build_object('key',r.qkey,'type',r.qtype,'text',r.qtext,'options',to_jsonb(opts),
          'correct',array_position(opts,cdisp)-1,'subject',r.subject,'nearest',r.subject,'people',to_jsonb(r.people)));
    end loop;
    return qs;
  end;
end $function$
;

-- today's already generated set was converted with a one-off UPDATE (see report); future sets use the function above
