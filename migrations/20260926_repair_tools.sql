-- כלי תיקון טעויות: רישום פעולות, תמונת שחזור פרטית ומחיקה אטומית.
-- יש להריץ בשלמותה בטרנזקציה אחת לאחר גיבוי ובדיקת הסכמה החיה.
begin;
create table public.activity_log (
 id uuid primary key default gen_random_uuid(), family_id uuid not null references public.families(id) on delete cascade,
 actor_id uuid references auth.users(id), created_at timestamptz not null default now(),
 action text not null, entity_type text, entity_id uuid, person_ids uuid[] not null default '{}',
 summary text not null, undoable boolean not null default false,
 undone_at timestamptz, undone_by uuid references auth.users(id), undo_of uuid references public.activity_log(id),
 before_state jsonb, after_state jsonb,
 constraint activity_undo_state check ((undone_at is null) = (undone_by is null))
);
create index activity_family_date on public.activity_log(family_id,created_at desc);
create index activity_people on public.activity_log using gin(person_ids);
alter table public.activity_log enable row level security;
revoke all on public.activity_log from public,anon,authenticated;
create policy activity_member_read on public.activity_log for select to authenticated using (public.is_family_member(family_id));
grant select(id,family_id,actor_id,created_at,action,entity_type,entity_id,person_ids,summary,undoable,undone_at,undo_of) on public.activity_log to authenticated;

create table public.repair_snapshots (
 activity_id uuid primary key references public.activity_log(id) on delete cascade,
 family_id uuid not null references public.families(id) on delete cascade,
 payload jsonb not null, post_hash text not null, created_at timestamptz not null default now()
);
alter table public.repair_snapshots enable row level security;
revoke all on public.repair_snapshots from public,anon,authenticated;

-- נעילה סדרתית בין פעולות תיקון; טריגרי audit הקיימים נשמרים ללא שינוי.
create or replace function public.repair_family_hash(fid uuid) returns text language sql stable security definer set search_path=public,pg_temp as $fn$
 select md5(coalesce((select jsonb_agg(to_jsonb(x) order by x.id::text)::text from people x where x.family_id=fid),'[]')||
 coalesce((select jsonb_agg(to_jsonb(x) order by x.id::text)::text from parent_child x where x.family_id=fid),'[]')||
 coalesce((select jsonb_agg(to_jsonb(x) order by x.id::text)::text from unions x where x.family_id=fid),'[]')||
 coalesce((select jsonb_agg(to_jsonb(x) order by x.person_a::text,x.person_b::text)::text from sibling_declarations x where x.family_id=fid),'[]')||
 coalesce((select jsonb_agg(to_jsonb(x) order by x.person_id::text)::text from contact_privacy x join people p on p.id=x.person_id where p.family_id=fid),'[]')||
 coalesce((select jsonb_agg(to_jsonb(x) order by x.id::text)::text from contact_requests x where x.family_id=fid),'[]')||
 coalesce((select jsonb_agg(to_jsonb(x) order by x.id::text)::text from identity_claims x where x.family_id=fid),'[]')||
 coalesce((select jsonb_agg(to_jsonb(x) order by x.id::text)::text from invitations x where x.family_id=fid),'[]'));
$fn$;
revoke all on function public.repair_family_hash(uuid) from public,anon,authenticated;

-- כל שינוי רלוונטי נועל תחילה את רשומת המשפחה, כך ש-preview ו-commit לא ידרסו שינוי מתחרה.
create or replace function public.repair_lock_family() returns trigger language plpgsql security definer set search_path=public,pg_temp as $fn$
declare fid uuid; pid uuid;
begin
 if tg_table_name='contact_privacy' then
  pid:=case when tg_op='DELETE' then old.person_id else new.person_id end;
  select family_id into fid from people where id=pid;
 else
  fid:=case when tg_op='DELETE' then old.family_id else new.family_id end;
 end if;
 if fid is null and tg_table_name='contact_privacy' and tg_op='DELETE' and current_setting('shoshelet.repair_operation',true)='group_delete' then return old; end if;
 if fid is null then raise exception 'REPAIR_FAMILY_UNKNOWN'; end if;
 perform 1 from families where id=fid for update;
 if not found then raise exception 'REPAIR_FAMILY_UNKNOWN'; end if;
 return case when tg_op='DELETE' then old else new end;
end $fn$;
-- טריגר נעילה אינו משנה הרשאות משתמש או תוכן.
create trigger repair_lock_people before insert or update or delete on public.people for each row execute function public.repair_lock_family();
create trigger repair_lock_parent_child before insert or update or delete on public.parent_child for each row execute function public.repair_lock_family();
create trigger repair_lock_unions before insert or update or delete on public.unions for each row execute function public.repair_lock_family();
create trigger repair_lock_siblings before insert or update or delete on public.sibling_declarations for each row execute function public.repair_lock_family();
create trigger repair_lock_privacy before insert or update or delete on public.contact_privacy for each row execute function public.repair_lock_family();
create trigger repair_lock_requests before insert or update or delete on public.contact_requests for each row execute function public.repair_lock_family();
create trigger repair_lock_claims before insert or update or delete on public.identity_claims for each row execute function public.repair_lock_family();
create trigger repair_lock_invitations before insert or update or delete on public.invitations for each row execute function public.repair_lock_family();
revoke all on function public.repair_lock_family() from public,anon,authenticated;

-- חישוב רכיב שהתנתק משורש הכרטיס המאומת, בלי לבלוע מסלול חלופי.
create or replace function public.repair_detached(fid uuid, target_id uuid, root_id uuid) returns uuid[] language sql stable security definer set search_path=public,pg_temp as $fn$
 with recursive edges(a,b) as (
  select parent_id,child_id from parent_child where family_id=fid and status='confirmed'
  union all select child_id,parent_id from parent_child where family_id=fid and status='confirmed'
  union all select person_a,person_b from unions where family_id=fid
  union all select person_b,person_a from unions where family_id=fid
 ), old_graph(id) as (
  select root_id union select e.b from edges e join old_graph g on e.a=g.id
 ), new_graph(id) as (
  select root_id union select e.b from edges e join new_graph g on e.a=g.id where e.a<>target_id and e.b<>target_id
 ) select coalesce(array_agg(o.id order by o.id),'{}'::uuid[]) from old_graph o
 where o.id<>target_id and not exists(select 1 from new_graph n where n.id=o.id);
$fn$;
revoke all on function public.repair_detached(uuid,uuid,uuid) from public,anon,authenticated;

create or replace function public.repair_target(fid uuid, target_id uuid) returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $fn$
declare p people%rowtype; root_id uuid; detached uuid[]; blocked text; names jsonb;
begin
 if not is_family_member(fid) then raise exception 'NOT_FAMILY_MEMBER'; end if;
 select * into p from people where id=target_id and family_id=fid;
 if not found then raise exception 'PERSON_NOT_FOUND'; end if;
 select person_id into root_id from identity_claims where family_id=fid and user_id=auth.uid() and status='verified' order by created_at desc limit 1;
 if root_id is null then raise exception 'VERIFIED_CARD_REQUIRED'; end if;
 detached:=repair_detached(fid,target_id,root_id);
 
 if root_id=target_id then blocked:='לא ניתן למחוק את הכרטיס המאומת שלכם.'; end if;
 if exists(select 1 from identity_claims where person_id=target_id and family_id=fid) then blocked:='לא ניתן למחוק אדם עם שיוך חשבון.'; end if;
 if exists(select 1 from invitations where person_id=target_id and family_id=fid) then blocked:='לא ניתן למחוק אדם עם הזמנה קיימת.'; end if;
 
 select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'full_name',q.full_name) order by q.full_name),'[]'::jsonb) into names from people q where q.id=any(detached) and q.family_id=fid;
 return jsonb_build_object('person',p.full_name,'detached_people',names,'detached_ids',to_jsonb(detached),'blocked',blocked,'branch_blocked',case when exists(select 1 from identity_claims where person_id=any(detached) and family_id=fid) or exists(select 1 from invitations where person_id=any(detached) and family_id=fid) then 'בענף יש אדם עם שיוך חשבון או הזמנה; מחיקת הענף חסומה.' else null end,'root',root_id);
end $fn$;
revoke all on function public.repair_target(uuid,uuid) from public,anon,authenticated;

-- רישום שינויים רגילים שאינם מבטיחים ביטול; snapshot פרטי מוחזק מחוץ ללוג.
create or replace function public.repair_audit_row() returns trigger language plpgsql security definer set search_path=public,pg_temp as $fn$
declare oldrow jsonb; newrow jsonb; ids uuid[]; fid uuid; label text; eid uuid; act text;
begin
 if current_setting('shoshelet.repair_operation',true)='group_delete' then return case when tg_op='DELETE' then old else new end; end if;
 oldrow:=case when tg_op='INSERT' then null else to_jsonb(old) end;
 newrow:=case when tg_op='DELETE' then null else to_jsonb(new) end;
 fid:=coalesce((newrow->>'family_id')::uuid,(oldrow->>'family_id')::uuid);
 eid:=coalesce((newrow->>'id')::uuid,(oldrow->>'id')::uuid);
 if tg_table_name='people' then ids:=array[eid];
 elsif tg_table_name='parent_child' then ids:=array[coalesce((newrow->>'parent_id')::uuid,(oldrow->>'parent_id')::uuid),coalesce((newrow->>'child_id')::uuid,(oldrow->>'child_id')::uuid)];
 elsif tg_table_name='unions' then ids:=array[coalesce((newrow->>'person_a')::uuid,(oldrow->>'person_a')::uuid),coalesce((newrow->>'person_b')::uuid,(oldrow->>'person_b')::uuid)];
 else ids:=array[coalesce((newrow->>'person_a')::uuid,(oldrow->>'person_a')::uuid),coalesce((newrow->>'person_b')::uuid,(oldrow->>'person_b')::uuid)]; eid:=ids[1]; end if;
 act:=lower(tg_op);
 label:=case when tg_table_name='people' then case tg_op when 'INSERT' then 'נוסף אדם' when 'UPDATE' then 'עודכן אדם' else 'נמחק אדם' end
 when tg_table_name='parent_child' then case tg_op when 'INSERT' then 'נוסף קשר הורות' when 'UPDATE' then 'עודכן קשר הורות' else 'נמחק קשר הורות' end
 when tg_table_name='unions' then case tg_op when 'INSERT' then 'נוסף קשר זוגיות' when 'UPDATE' then 'עודכן קשר זוגיות' else 'נמחק קשר זוגיות' end
 else 'עודכנה הצהרת אחאות' end;
 insert into activity_log(family_id,actor_id,action,entity_type,entity_id,person_ids,summary,undoable,before_state,after_state)
 values(fid,auth.uid(),act,tg_table_name,eid,ids,label,false,oldrow,newrow);
 return case when tg_op='DELETE' then old else new end;
end $fn$;
create trigger repair_people after insert or update or delete on public.people for each row execute function public.repair_audit_row();
create trigger repair_parent_child after insert or update or delete on public.parent_child for each row execute function public.repair_audit_row();
create trigger repair_unions after insert or update or delete on public.unions for each row execute function public.repair_audit_row();
create trigger repair_siblings after insert or update or delete on public.sibling_declarations for each row execute function public.repair_audit_row();
revoke all on function public.repair_audit_row() from public,anon,authenticated;
-- תמונת מצב מלאה של הרשומות שיימחקו ישירות או דרך cascade.
create or replace function public.repair_capture(fid uuid, ids uuid[]) returns jsonb language sql stable security definer set search_path=public,pg_temp as $fn$
 select jsonb_build_object(
 'people',coalesce((select jsonb_agg(to_jsonb(x) order by x.id) from people x where x.family_id=fid and x.id=any(ids)),'[]'::jsonb),
 'parent_child',coalesce((select jsonb_agg(to_jsonb(x) order by x.id) from parent_child x where x.family_id=fid and (x.parent_id=any(ids) or x.child_id=any(ids))),'[]'::jsonb),
 'unions',coalesce((select jsonb_agg(to_jsonb(x) order by x.id) from unions x where x.family_id=fid and (x.person_a=any(ids) or x.person_b=any(ids))),'[]'::jsonb),
 'sibling_declarations',coalesce((select jsonb_agg(to_jsonb(x) order by x.person_a,x.person_b) from sibling_declarations x where x.family_id=fid and (x.person_a=any(ids) or x.person_b=any(ids))),'[]'::jsonb),
 'contact_privacy',coalesce((select jsonb_agg(to_jsonb(x) order by x.person_id) from contact_privacy x where x.person_id=any(ids)),'[]'::jsonb),
 'contact_requests',coalesce((select jsonb_agg(to_jsonb(x) order by x.id) from contact_requests x where x.family_id=fid and x.person_id=any(ids)),'[]'::jsonb));
$fn$;
revoke all on function public.repair_capture(uuid,uuid[]) from public,anon,authenticated;

create or replace function public.preview_repair(p_family_id uuid,p_kind text,p_target jsonb) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $fn$
declare context jsonb; target_id uuid; detached uuid[]; block_message text; scope text; event activity_log%rowtype; state_hash text; current_state jsonb;
begin
 if not is_family_member(p_family_id) then raise exception 'NOT_FAMILY_MEMBER'; end if;
 if p_kind='delete_person' then
  target_id:=(p_target->>'id')::uuid;
  context:=repair_target(p_family_id,target_id);
  detached:=array(select jsonb_array_elements_text(context->'detached_ids')::uuid);
  block_message:=context->>'blocked';
  if block_message is not null then return jsonb_build_object('allowed',false,'description',block_message,'detached_people',context->'detached_people'); end if;
  state_hash:=repair_family_hash(p_family_id);
  return jsonb_build_object('allowed',true,'description','האדם והקשרים שלו יוסרו. בחרו אם להשאיר את הענף מנותק או למחוק אותו יחד.',
  'detached_people',context->'detached_people','branch_allowed',(context->>'branch_blocked') is null,'branch_blocked',context->>'branch_blocked','effects',jsonb_build_array('הנתונים ייבדקו שוב לפני מחיקה','תמונת מצב מלאה תישמר לביטול אחד'),
  'token',md5(p_family_id::text||target_id::text||state_hash));
 elsif p_kind='undo' then
  select * into event from activity_log where id=(p_target->>'id')::uuid and family_id=p_family_id;
  if not found then raise exception 'ACTION_NOT_FOUND'; end if;
  if not event.undoable or event.undone_at is not null then return jsonb_build_object('allowed',false,'description','אין אפשרות לבטל פעולה זו.'); end if;
  if event.action='delete_person' then
   select payload into current_state from repair_snapshots where activity_id=event.id and family_id=p_family_id;
   if current_state is null then return jsonb_build_object('allowed',false,'description','תמונת שחזור אינה זמינה.'); end if;
   if (select post_hash from repair_snapshots where activity_id=event.id)<>repair_family_hash(p_family_id) then return jsonb_build_object('allowed',false,'description','המשפחה השתנתה מאז המחיקה; לא ניתן לשחזר אוטומטית.'); end if;
  else
   -- אין שחזור אוטומטי של פעולות רגילות לפני שנבדקו כל תלותיהן.
   return jsonb_build_object('allowed',false,'description','ביטול אוטומטי של פעולה זו עדיין אינו זמין.');
  end if;
  return jsonb_build_object('allowed',true,'description','שחזור האדם והענף שנמחקו','token',md5(event.id::text||repair_family_hash(p_family_id)));
 else raise exception 'UNKNOWN_REPAIR_KIND'; end if;
end $fn$;
revoke all on function public.preview_repair(uuid,text,jsonb) from public,anon;
grant execute on function public.preview_repair(uuid,text,jsonb) to authenticated;

create or replace function public.commit_repair(p_family_id uuid,p_kind text,p_target jsonb,p_preview_token text) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $fn$
declare target_id uuid; context jsonb; detached uuid[]; ids uuid[]; scope text; user_name text; snapshot jsonb; operation_id uuid; event activity_log%rowtype; rec jsonb; state_hash text; snapshot_record repair_snapshots%rowtype;
begin
 if not is_family_member(p_family_id) then raise exception 'NOT_FAMILY_MEMBER'; end if;
 -- נעילת המשפחה מונעת התנגשות בין שתי פעולות תיקון במקביל.
 perform 1 from families where id=p_family_id for update;
 if not found then raise exception 'FAMILY_NOT_FOUND'; end if;
 state_hash:=repair_family_hash(p_family_id);
 if p_kind='delete_person' then
  target_id:=(p_target->>'id')::uuid;scope:=p_target->>'scope';
  if scope not in ('person','branch') then raise exception 'INVALID_SCOPE'; end if;
  context:=repair_target(p_family_id,target_id);
  if context->>'blocked' is not null then raise exception 'DELETE_BLOCKED: %',context->>'blocked'; end if;
  if p_preview_token is distinct from md5(p_family_id::text||target_id::text||state_hash) then raise exception 'PREVIEW_STALE'; end if;
  user_name:=p_target->>'confirmed_name';
  if user_name is distinct from context->>'person' then raise exception 'NAME_CONFIRMATION_REQUIRED'; end if;
  detached:=array(select jsonb_array_elements_text(context->'detached_ids')::uuid);
  if scope='branch' and context->>'branch_blocked' is not null then raise exception 'DELETE_BRANCH_BLOCKED'; end if;
  ids:=case when scope='branch' then array_prepend(target_id,detached) else array[target_id] end;
  -- בדיקה חוזרת של כל תלות בעלת זהות/הזמנה: אין שחזור בטוח שלה.
  if exists(select 1 from identity_claims where family_id=p_family_id and person_id=any(ids))
    or exists(select 1 from invitations where family_id=p_family_id and person_id=any(ids)) then raise exception 'DEPENDENT_IDENTITY_OR_INVITE'; end if;
  snapshot:=repair_capture(p_family_id,ids);
  if jsonb_array_length(snapshot->'people')<>cardinality(ids) then raise exception 'INCOMPLETE_SNAPSHOT'; end if;
  perform set_config('shoshelet.repair_operation','group_delete',true);
  insert into activity_log(family_id,actor_id,action,entity_type,entity_id,person_ids,summary,undoable)
  values(p_family_id,auth.uid(),'delete_person','people',target_id,ids,case when scope='branch' then 'נמחק אדם וענף' else 'נמחק אדם' end,true) returning id into operation_id;
  insert into repair_snapshots(activity_id,family_id,payload,post_hash) values(operation_id,p_family_id,jsonb_build_object('rows',snapshot,'ids',to_jsonb(ids),'scope',scope),'pending');
  delete from people where family_id=p_family_id and id=any(ids);
  update repair_snapshots set post_hash=repair_family_hash(p_family_id) where activity_id=operation_id;
  perform set_config('shoshelet.repair_operation','',true);
  return jsonb_build_object('ok',true,'id',operation_id);
 elsif p_kind='undo' then
  select * into event from activity_log where id=(p_target->>'id')::uuid and family_id=p_family_id for update;
  if not found or not event.undoable or event.undone_at is not null or event.action<>'delete_person' then raise exception 'UNDO_UNAVAILABLE'; end if;
  select * into snapshot_record from repair_snapshots where activity_id=event.id and family_id=p_family_id;
  if not found or snapshot_record.post_hash<>state_hash then raise exception 'UNDO_CONFLICT'; end if;
  if p_preview_token is distinct from md5(event.id::text||state_hash) then raise exception 'PREVIEW_STALE'; end if;
  snapshot:=snapshot_record.payload->'rows';
  perform set_config('shoshelet.repair_operation','group_delete',true);
  for rec in select value from jsonb_array_elements(snapshot->'people') loop insert into people select * from jsonb_populate_record(null::people,rec); end loop;
  for rec in select value from jsonb_array_elements(snapshot->'parent_child') loop insert into parent_child select * from jsonb_populate_record(null::parent_child,rec); end loop;
  for rec in select value from jsonb_array_elements(snapshot->'unions') loop insert into unions select * from jsonb_populate_record(null::unions,rec); end loop;
  for rec in select value from jsonb_array_elements(snapshot->'sibling_declarations') loop insert into sibling_declarations select * from jsonb_populate_record(null::sibling_declarations,rec); end loop;
  for rec in select value from jsonb_array_elements(snapshot->'contact_privacy') loop insert into contact_privacy select * from jsonb_populate_record(null::contact_privacy,rec); end loop;
  for rec in select value from jsonb_array_elements(snapshot->'contact_requests') loop insert into contact_requests select * from jsonb_populate_record(null::contact_requests,rec); end loop;
  update activity_log set undone_at=now(),undone_by=auth.uid(),undoable=false where id=event.id;
  insert into activity_log(family_id,actor_id,action,entity_type,entity_id,person_ids,summary,undo_of)
  values(p_family_id,auth.uid(),'undo','people',event.entity_id,event.person_ids,'שוחזרה מחיקה',event.id) returning id into operation_id;
  perform set_config('shoshelet.repair_operation','',true);
  return jsonb_build_object('ok',true,'id',operation_id);
 else raise exception 'UNKNOWN_REPAIR_KIND'; end if;
end $fn$;
revoke all on function public.commit_repair(uuid,text,jsonb,text) from public,anon;
grant execute on function public.commit_repair(uuid,text,jsonb,text) to authenticated;
commit;
