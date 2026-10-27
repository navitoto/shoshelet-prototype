-- Rollback for 20261028_activity_actor_names.sql: removes the actor-name lookup only; no data touched.
begin;
drop function if exists public.family_actor_names(uuid, uuid[]);
commit;
