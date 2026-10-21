-- Apply once before kiosk_api.sql on an existing single-room deployment.
alter table kiosk_private.accounts add column if not exists clinic_id smallint not null default 1 check(clinic_id in (1,2));
alter table kiosk_private.sessions add column if not exists clinic_id smallint not null default 1 check(clinic_id in (1,2));
alter table kiosk_private.visits add column if not exists clinic_id smallint not null default 1 check(clinic_id in (1,2));
create table if not exists kiosk_private.clinic_settings(clinic_id smallint primary key check(clinic_id in(1,2)),max_number integer not null default 30,retention_days integer not null default 30);
insert into kiosk_private.clinic_settings select c,max_number,retention_days from kiosk_private.settings cross join generate_series(1,2) c on conflict do nothing;
alter table kiosk_private.clinic_settings enable row level security;
revoke all on kiosk_private.clinic_settings from public,anon,authenticated;
grant select,update on kiosk_private.clinic_settings to service_role;
insert into kiosk_private.accounts(username,role,password_hash,clinic_id) select 'mw'||c,'teacher',password_hash,c from kiosk_private.accounts cross join generate_series(1,2) c where username='teacher' on conflict do nothing;
update kiosk_private.accounts set role='student' where username='teacher';
create unique index if not exists kiosk_active_student_by_clinic on kiosk_private.visits(clinic_id,grade,room,num) where status in ('waiting','treating');
drop index if exists kiosk_private.kiosk_active_student;
create index if not exists visits_clinic_status_seq on kiosk_private.visits(clinic_id,status,seq);
create index if not exists visits_clinic_created on kiosk_private.visits(clinic_id,created desc);
create table if not exists kiosk_private.usage_month(month date primary key,requests bigint not null default 0,estimated_bytes bigint not null default 0,blocked bigint not null default 0);
alter table kiosk_private.usage_month enable row level security;
revoke all on kiosk_private.usage_month from public,anon,authenticated;
grant select,insert,update on kiosk_private.usage_month to service_role;
