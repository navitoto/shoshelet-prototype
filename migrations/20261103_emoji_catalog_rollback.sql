-- Rollback for 20261103_emoji_catalog: restore the original 1-8 check. No data touched.
alter table public.person_icons drop constraint if exists person_icons_emoji_check;
alter table public.person_icons add constraint person_icons_emoji_check check (char_length(emoji) between 1 and 8);
