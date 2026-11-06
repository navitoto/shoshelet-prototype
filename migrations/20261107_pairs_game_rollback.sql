-- Rollback for 20261107_pairs_game.sql: removes only objects created by that migration.
begin;
do $c$ begin if exists (select 1 from pg_extension where extname='pg_cron') then perform cron.unschedule('shoshelet-pairs-pregen'); end if; exception when others then null; end $c$;
drop function if exists public.pairs_active_day(uuid,uuid,timestamptz), public.pairs_state(uuid), public.pairs_start(uuid), public.pairs_pick(uuid,uuid,uuid), public.pairs_rankings(uuid), public.pairs_medals(uuid), public.pairs_member_check(uuid);
drop function if exists public.pairs_state_internal(uuid,date,timestamptz,uuid), public.pairs_start_internal(uuid,date,timestamptz,uuid), public.pairs_pick_internal(uuid,date,timestamptz,uuid,uuid,uuid), public.pairs_rankings_internal(uuid,timestamptz), public.pairs_medals_internal(uuid,uuid,timestamptz);
drop function if exists public.pairs_grant(uuid,uuid), public.pairs_done_json(uuid,public.pairs_boards,public.pairs_attempts), public.pairs_types_json(public.pairs_boards), public.pairs_solved_json(uuid,public.pairs_boards,public.pairs_attempts), public.pairs_names(uuid,jsonb);
drop function if exists public.pairs_explain(uuid,text,uuid,uuid,uuid,boolean), public.pairs_label(text,uuid,uuid,uuid), public.pairs_word(text,boolean,text), public.pairs_health(date), public.pairs_prepare_next(), public.pairs_ensure_board(uuid,date), public.pairs_dfs(text[],int,uuid[],jsonb), public.pairs_build_board(uuid,date), public.pairs_check(uuid,jsonb,jsonb), public.pairs_relations(uuid), public.pairs_config();
drop table if exists public.pairs_build_log, public.pairs_awards, public.pairs_attempts, public.pairs_boards;
commit;
