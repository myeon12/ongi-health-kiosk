create extension if not exists pg_cron;
create or replace function kiosk_private.purge_expired_visits() returns integer language plpgsql security invoker set search_path='' as $$
declare days integer;n integer;
begin
 select retention_days into days from kiosk_private.settings where id;
 if days is null or days<=0 then return 0;end if;
 perform pg_advisory_xact_lock(774019);
 delete from kiosk_private.visits where status in ('done','cancelled') and finished is not null and finished < now()-make_interval(days=>days);
 get diagnostics n = row_count;
 return n;
end $$;
revoke all on function kiosk_private.purge_expired_visits() from public,anon,authenticated,service_role;
update kiosk_private.settings set retention_days=30 where id;
select cron.schedule('kiosk-daily-retention','0 17 * * *','select kiosk_private.purge_expired_visits();');
