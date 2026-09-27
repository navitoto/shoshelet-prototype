-- Roll back the RPC only after the client has reverted to a compatible build.
begin;
revoke all on function public.family_verified_status(uuid) from authenticated;
drop function public.family_verified_status(uuid);
commit;
