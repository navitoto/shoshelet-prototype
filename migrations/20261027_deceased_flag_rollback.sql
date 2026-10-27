-- Rollback for 20261027_deceased_flag.sql
-- NOTE: dateless deceased marks exist ONLY in is_deceased. Before dropping the
-- column, export the flagged-without-date list (or keep the column dormant).
-- This rollback preserves that data: it reverts code, not the column.

DO $d$
declare def text; n int;
begin
  def := pg_get_functiondef('public.trivia_build_set_phase1_legacy(uuid,date)'::regprocedure);
  n := (length(def) - length(replace(def, '(coalesce(p.is_deceased, p.death_date is not null)) dead', ''))) / length('(coalesce(p.is_deceased, p.death_date is not null)) dead');
  if n <> 1 then raise exception 'unexpected match count %', n; end if;
  def := replace(def, '(coalesce(p.is_deceased, p.death_date is not null)) dead', '(p.death_date is not null) dead');
  execute def;
end $d$;

DROP TRIGGER IF EXISTS a_normalize_deceased ON public.people;
DROP FUNCTION IF EXISTS public.normalize_deceased_flag();

-- Intentionally NOT dropped; run only after exporting dateless marks:
-- SELECT id FROM public.people WHERE is_deceased AND death_date IS NULL;
-- ALTER TABLE public.people DROP COLUMN IF EXISTS is_deceased;
