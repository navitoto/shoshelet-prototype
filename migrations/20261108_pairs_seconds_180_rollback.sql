-- Rollback of 20261108_pairs_seconds_180.sql: 60 seconds for every board again, as in 20261107_pairs_game.sql.
-- Attempts already started keep their stored deadline in both directions.
begin;
delete from public.pairs_settings where k='seconds180_start';
create or replace function public.pairs_config() returns jsonb
language sql stable set search_path=public,pg_temp as
$$ select jsonb_build_object('seconds',60,'grace_seconds',0,'pairs',4,'streak_days',7,'streak_start',(select v from public.pairs_settings where k='streak_start'),'tz','Asia/Jerusalem') $$;
commit;
