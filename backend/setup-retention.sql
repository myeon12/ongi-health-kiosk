create extension if not exists pg_cron;
CREATE OR REPLACE FUNCTION kiosk_private.purge_expired_visits()
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare n integer;
begin
 perform pg_advisory_xact_lock(774019);
 delete from kiosk_private.visits v using kiosk_private.clinic_settings c where v.clinic_id=c.clinic_id and c.retention_days>0 and v.status in ('done','cancelled') and v.finished is not null and v.finished<now()-make_interval(days=>c.retention_days);
 get diagnostics n=row_count;return n;
end $function$
;
revoke all on function kiosk_private.purge_expired_visits() from public,anon,authenticated,service_role;
select cron.schedule('kiosk-daily-retention','0 17 * * *','select kiosk_private.purge_expired_visits();');
