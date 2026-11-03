-- v2.84: full emoji catalog for profile icons (Emoji 15.0, picker sequences up to 8 code points today;
-- widen the check so future catalog refreshes with longer ZWJ/tag sequences are not blocked).
-- Additive change to one check constraint. No data touched.
alter table public.person_icons drop constraint if exists person_icons_emoji_check;
alter table public.person_icons add constraint person_icons_emoji_check check (char_length(emoji) between 1 and 40);
