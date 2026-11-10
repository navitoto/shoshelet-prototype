-- Rollback of 20261110_chain_game.sql: drops everything the migration created. Attempt rows are lost with the tables.
begin;
do $c$ begin
  if exists (select 1 from pg_extension where extname='pg_cron') then
    perform cron.unschedule('shoshelet-chain-pregen');
  end if;
exception when others then null;
end $c$;
do $g$
declare f text;
begin
  for f in select p.oid::regprocedure::text from pg_proc p where p.pronamespace='public'::regnamespace and p.proname like 'chain\_%' loop
    execute 'drop function '||f||' cascade';
  end loop;
end $g$;
drop table if exists public.chain_attempts;
drop table if exists public.chain_build_log;
drop table if exists public.chain_boards;
commit;
