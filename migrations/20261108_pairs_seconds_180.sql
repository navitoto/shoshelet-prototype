-- Pairs: 3 minutes per board from Jerusalem day 2026-11-08. Rule change decided by the owner on 2026-11-07.
-- Day-based on purpose: attempts whose board day is before 2026-11-08 keep 60 seconds; nothing about
-- today's attempts, results, scores or medals changes. The deadline is stored on each attempt at start,
-- so in-flight attempts are untouched either way. Boards (cards/pairs) do not depend on the duration.
-- Non-destructive: one settings row + replacing pairs_config() only. Rollback restores 60s and drops the row.
begin;
insert into public.pairs_settings(k,v) values ('seconds180_start','2026-11-08') on conflict (k) do nothing;
create or replace function public.pairs_config() returns jsonb
language sql stable set search_path=public,pg_temp as
$$ select jsonb_build_object(
  'seconds', case when (now() at time zone 'Asia/Jerusalem')::date >= coalesce((select v::date from public.pairs_settings where k='seconds180_start'), date '9999-12-31') then 180 else 60 end,
  'grace_seconds',0,'pairs',4,'streak_days',7,
  'streak_start',(select v from public.pairs_settings where k='streak_start'),
  'tz','Asia/Jerusalem') $$;
commit;
