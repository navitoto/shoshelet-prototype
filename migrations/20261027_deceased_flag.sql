-- Deceased status independent of death date (approved by Tut 2026-10-27).
-- Adds people.is_deceased; a date always implies deceased via normalization trigger;
-- trivia deceased handling derives from the effective flag.
-- Applied via Supabase SQL editor on 2026-10-27.

ALTER TABLE public.people ADD COLUMN IF NOT EXISTS is_deceased boolean;

CREATE OR REPLACE FUNCTION public.normalize_deceased_flag() RETURNS trigger
LANGUAGE plpgsql SET search_path TO 'public', 'pg_temp' AS $f$
begin
  if new.death_date is not null then new.is_deceased := true; end if;
  return new;
end $f$;

DROP TRIGGER IF EXISTS a_normalize_deceased ON public.people;
CREATE TRIGGER a_normalize_deceased BEFORE INSERT OR UPDATE ON public.people
  FOR EACH ROW EXECUTE FUNCTION public.normalize_deceased_flag();

UPDATE public.people SET is_deceased = (death_date IS NOT NULL);

-- trivia: effective deceased = flag, falling back to stored date (only line changed)
DO $d$
declare def text; n int;
begin
  def := pg_get_functiondef('public.trivia_build_set_phase1_legacy(uuid,date)'::regprocedure);
  n := (length(def) - length(replace(def, '(p.death_date is not null) dead', ''))) / length('(p.death_date is not null) dead');
  if n <> 1 then raise exception 'unexpected match count %', n; end if;
  def := replace(def, '(p.death_date is not null) dead', '(coalesce(p.is_deceased, p.death_date is not null)) dead');
  execute def;
end $d$;
