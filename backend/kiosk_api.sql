CREATE OR REPLACE FUNCTION kiosk_private.kiosk_api_impl(op text, payload jsonb DEFAULT '{}'::jsonb, session_token text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare s kiosk_private.sessions%rowtype;a kiosk_private.accounts%rowtype;v kiosk_private.visits%rowtype;tok text;target text;result jsonb;days int;mx int;cnt int;query_date date;query_text text;page_no int;page_size int;visit_mode text;where_start timestamptz;where_end timestamptz;clinic smallint;rev text;
begin
 delete from kiosk_private.sessions where expires<now();
 if op='session' then
  if coalesce(payload->>'clinic','') not in ('1','2') then return jsonb_build_object('error','보건실 전용 주소로 다시 접속해 주세요.','code',400);end if;
  clinic=(payload->>'clinic')::smallint;
  tok=encode(extensions.gen_random_bytes(32),'hex');
  insert into kiosk_private.sessions(token_hash,role,username,expires,clinic_id) values(encode(extensions.digest(tok,'sha256'),'hex'),'student','kiosk',now()+interval '12 hours',clinic);
  return jsonb_build_object('token',tok,'role','student','unlocked',false,'clinic',clinic);
 end if;
 select * into s from kiosk_private.sessions where token_hash=encode(extensions.digest(session_token,'sha256'),'hex') and expires>now();
 if s.token_hash is null then return jsonb_build_object('error','접속 시간이 만료됐어요. 화면을 다시 열어 주세요.','code',401);end if;
 select retention_days,max_number into days,mx from kiosk_private.clinic_settings where clinic_id=s.clinic_id;
 if op='public' then return jsonb_build_object('waiting',(select count(*) from kiosk_private.visits where clinic_id=s.clinic_id and status='waiting'),'maxNumber',mx);end if;
 if op='login' then
  select * into a from kiosk_private.accounts where username=payload->>'username' and role='teacher' for update;
  if a.username is null then return jsonb_build_object('error','계정 정보를 확인해 주세요.','code',403);end if;
  if a.locked_until>now() then return jsonb_build_object('error','5분 후 다시 시도해 주세요.','code',429);end if;
  if extensions.crypt(coalesce(payload->>'password',''),a.password_hash)<>a.password_hash then
   update kiosk_private.accounts set failures=case when failures>=4 then 0 else failures+1 end,locked_until=case when failures>=4 then now()+interval '5 minutes' else null end where username=a.username;
   return jsonb_build_object('error','계정 또는 비밀번호를 확인해 주세요.','code',403);
  end if;
  update kiosk_private.accounts set failures=0,locked_until=null where username=a.username;
  tok=encode(extensions.gen_random_bytes(32),'hex');delete from kiosk_private.sessions where token_hash=s.token_hash;
  insert into kiosk_private.sessions(token_hash,role,username,expires,clinic_id) values(encode(extensions.digest(tok,'sha256'),'hex'),'teacher',a.username,now()+interval '15 minutes',a.clinic_id);
  return jsonb_build_object('ok',true,'token',tok,'role','teacher','unlocked',true,'clinic',a.clinic_id);
 end if;
 if op='logout' then delete from kiosk_private.sessions where token_hash=s.token_hash;return jsonb_build_object('ok',true);end if;
 if op='checkin' then
  perform pg_advisory_xact_lock(774019);
  select * into v from kiosk_private.visits where clinic_id=s.clinic_id and id=(payload->>'id')::uuid;
  if v.id is not null then
   if v.clinic_id<>s.clinic_id or v.grade<>(payload->>'grade')::int or v.room<>(payload->>'room')::int or v.num<>(payload->>'num')::int then return jsonb_build_object('error','접수 요청이 일치하지 않아요.','code',409);end if;
  else
   if (payload->>'num')::int>mx or jsonb_array_length(payload->'symptoms') not between 1 and 12 then return jsonb_build_object('error','선택한 내용을 확인해 주세요.','code',400);end if;
   if exists(select 1 from kiosk_private.visits where clinic_id=s.clinic_id and grade=(payload->>'grade')::int and room=(payload->>'room')::int and num=(payload->>'num')::int and status in ('waiting','treating')) then return jsonb_build_object('error','이미 접수되어 있어요. 선생님께 말해 주세요.','code',409);end if;
   if s.last_action>now()-interval '2 seconds' and exists(select 1 from kiosk_private.events where actor=s.token_hash) then return jsonb_build_object('error','잠시 후 다시 시도해 주세요.','code',429);end if;
   insert into kiosk_private.visits(id,clinic_id,grade,room,num,symptoms) values((payload->>'id')::uuid,s.clinic_id,(payload->>'grade')::int,(payload->>'room')::int,(payload->>'num')::int,payload->'symptoms') returning * into v;
   insert into kiosk_private.events(visit_id,actor,previous,next) values(v.id,s.token_hash,'new','waiting');
  end if;
  update kiosk_private.sessions set last_action=now() where token_hash=s.token_hash;
  return jsonb_build_object('ok',true,'position',(select count(*) from kiosk_private.visits where clinic_id=s.clinic_id and status='waiting' and seq<=v.seq));
 end if;
 if s.role<>'teacher' then return jsonb_build_object('error','선생님 계정만 사용할 수 있어요.','code',403);end if;

 if op='visits' then
  visit_mode=coalesce(payload->>'mode','active');
  if visit_mode not in ('active','history','settings') then return jsonb_build_object('error','조회 조건을 확인해 주세요.','code',400);end if;
  if coalesce(payload->>'touch','false')='true' then update kiosk_private.sessions set expires=now()+interval '15 minutes' where token_hash=s.token_hash;end if;
  select jsonb_build_object('waiting',count(*) filter(where status='waiting'),'treating',count(*) filter(where status='treating')) into result from kiosk_private.visits where clinic_id=s.clinic_id;
  if visit_mode='settings' then return jsonb_build_object('visits','[]'::jsonb,'counts',result,'settings',jsonb_build_object('max_number',mx::text,'retention_days',days::text));end if;
  if visit_mode='active' then
   select md5(coalesce(string_agg(id::text||':'||version::text,',' order by seq),'')||':'||mx::text||':'||days::text) into rev from kiosk_private.visits where clinic_id=s.clinic_id and status in ('waiting','treating');
   if payload->>'knownRevision'=rev then return jsonb_build_object('unchanged',true,'revision',rev);end if;
   select coalesce(jsonb_agg(to_jsonb(q) order by q.seq),'[]') into result from (select *,case when status='waiting' then sum(case when status='waiting' then 1 else 0 end) over(order by seq) else null end as position from kiosk_private.visits where clinic_id=s.clinic_id and status in ('waiting','treating')) q;
   return jsonb_build_object('revision',rev,'visits',result,'counts',jsonb_build_object('waiting',(select count(*) from kiosk_private.visits where clinic_id=s.clinic_id and status='waiting'),'treating',(select count(*) from kiosk_private.visits where clinic_id=s.clinic_id and status='treating')),'settings',jsonb_build_object('max_number',mx::text,'retention_days',days::text));
  end if;
  query_date=nullif(payload->>'date','')::date;query_text=coalesce(payload->>'query','');page_no=coalesce((payload->>'page')::int,0);page_size=coalesce((payload->>'limit')::int,50);
  if page_no not between 0 and 100000 or page_size not between 1 and 200 or char_length(query_text)>200 or coalesce(payload->>'status','') not in ('','waiting','treating','done','cancelled') then return jsonb_build_object('error','조회 조건을 확인해 주세요.','code',400);end if;
  where_start=query_date::timestamp at time zone 'Asia/Seoul';where_end=(query_date+1)::timestamp at time zone 'Asia/Seoul';
  select count(*) into cnt from kiosk_private.visits x where x.clinic_id=s.clinic_id and (query_date is null or (x.created>=where_start and x.created<where_end))
 and (coalesce(payload->>'status','')='' or x.status=payload->>'status')
 and not exists(select 1 from regexp_split_to_table(lower(query_text),E'\\s+') as term where term<>'' and strpos(lower(x.grade::text||'학년 '||x.room::text||'반 '||x.num::text||'번 '||x.symptoms::text||' '||case x.status when 'waiting' then '대기' when 'treating' then '진료중' when 'done' then '완료' else '취소' end),term)=0);
  select coalesce(jsonb_agg(to_jsonb(q) order by q.seq desc),'[]') into result from (select x.* from kiosk_private.visits x where x.clinic_id=s.clinic_id and (query_date is null or (x.created>=where_start and x.created<where_end))
 and (coalesce(payload->>'status','')='' or x.status=payload->>'status')
 and not exists(select 1 from regexp_split_to_table(lower(query_text),E'\\s+') as term where term<>'' and strpos(lower(x.grade::text||'학년 '||x.room::text||'반 '||x.num::text||'번 '||x.symptoms::text||' '||case x.status when 'waiting' then '대기' when 'treating' then '진료중' when 'done' then '완료' else '취소' end),term)=0) and (payload->>'beforeSeq' is null or x.seq<(payload->>'beforeSeq')::bigint) order by x.seq desc limit page_size offset case when payload->>'beforeSeq' is null then page_no*page_size else 0 end) q;
  return jsonb_build_object('visits',result,'total',cnt,'page',page_no,'pageSize',page_size,'counts',jsonb_build_object('waiting',(select count(*) from kiosk_private.visits where clinic_id=s.clinic_id and status='waiting'),'treating',(select count(*) from kiosk_private.visits where clinic_id=s.clinic_id and status='treating')),'settings',jsonb_build_object('max_number',mx::text,'retention_days',days::text));
 end if;
 update kiosk_private.sessions set expires=now()+interval '15 minutes' where token_hash=s.token_hash;


 if op='delete_visit' then
  if payload->>'confirm' is distinct from 'delete' or jsonb_typeof(payload->'version') is distinct from 'number' then return jsonb_build_object('error','삭제 요청을 확인해 주세요.','code',400);end if;
  perform pg_advisory_xact_lock(774019);
  select * into v from kiosk_private.visits where clinic_id=s.clinic_id and id=(payload->>'id')::uuid for update;
  if v.id is null then return jsonb_build_object('error','이미 삭제됐거나 접수를 찾을 수 없어요.','code',404);end if;
  if v.version is distinct from (payload->>'version')::int then return jsonb_build_object('error','다른 창에서 변경됐어요. 새로고침 후 다시 확인해 주세요.','code',409);end if;
  delete from kiosk_private.visits where id=v.id;
  return jsonb_build_object('ok',true);
 end if;
 if op='reason' then
  if jsonb_typeof(payload->'symptoms') is distinct from 'array' then return jsonb_build_object('error','방문 사유를 확인해 주세요.','code',400);end if;
  if jsonb_array_length(payload->'symptoms') not between 1 and 12 or exists(select 1 from jsonb_array_elements(payload->'symptoms') x where jsonb_typeof(x)<>'string' or char_length(btrim(x#>>'{}')) not between 1 and 200) or jsonb_typeof(payload->'version') is distinct from 'number' then return jsonb_build_object('error','사유는 1~12개, 각 200자 이내로 입력해 주세요.','code',400);end if;
  perform pg_advisory_xact_lock(774019);
  select * into v from kiosk_private.visits where clinic_id=s.clinic_id and id=(payload->>'id')::uuid for update;
  if v.id is null then return jsonb_build_object('error','접수를 찾을 수 없어요.','code',404);end if;
  if v.version is distinct from (payload->>'version')::int then return jsonb_build_object('error','다른 창에서 변경됐어요. 수정 내용을 복사한 뒤 취소하고 다시 열어 주세요.','code',409);end if;
  select jsonb_agg(btrim(value) order by ord) into result from jsonb_array_elements_text(payload->'symptoms') with ordinality as t(value,ord);
  update kiosk_private.visits set symptoms=result,version=version+1 where id=v.id;
  insert into kiosk_private.events(visit_id,actor,previous,next) values(v.id,s.username,jsonb_build_object('symptoms',v.symptoms)::text,jsonb_build_object('symptoms',result)::text);
  return jsonb_build_object('ok',true,'version',v.version+1);
 end if;
 if op='status' then
  perform pg_advisory_xact_lock(774019);
  select * into v from kiosk_private.visits where clinic_id=s.clinic_id and id=(payload->>'id')::uuid for update;target=payload->>'status';
  if v.id is null then return jsonb_build_object('error','접수를 찾을 수 없어요.','code',404);end if;
  if v.version<>(payload->>'version')::int then return jsonb_build_object('error','다른 창에서 변경됐어요. 새로 확인해 주세요.','code',409);end if;
  if not ((v.status='waiting' and target in ('treating','cancelled')) or (v.status='treating' and target in ('done','waiting')) or (v.status='done' and target in ('waiting','treating')) or (v.status='cancelled' and target='waiting')) then return jsonb_build_object('error','허용되지 않는 변경이에요.','code',400);end if;
  if target in ('waiting','treating') and exists(select 1 from kiosk_private.visits where clinic_id=s.clinic_id and grade=v.grade and room=v.room and num=v.num and id<>v.id and status in ('waiting','treating')) then return jsonb_build_object('error','이 학생의 다른 접수가 진행 중이에요.','code',409);end if;
  update kiosk_private.visits set status=target,started=case when target='treating' then now() else started end,finished=case when target in ('done','cancelled') then now() else null end,version=version+1 where id=v.id;
  insert into kiosk_private.events(visit_id,actor,previous,next) values(v.id,s.username,v.status,target);
  return jsonb_build_object('ok',true);
 end if;
 if op='settings' then
  if (payload->>'maxNumber')::int not between 1 and 60 or (payload->>'retentionDays')::int not between 0 and 3650 then return jsonb_build_object('error','설정값을 확인해 주세요.','code',400);end if;
  update kiosk_private.clinic_settings set max_number=(payload->>'maxNumber')::int,retention_days=(payload->>'retentionDays')::int where clinic_id=s.clinic_id;
  return jsonb_build_object('ok',true);
 end if;
 return jsonb_build_object('error','지원하지 않는 요청이에요.','code',400);
end $function$
;

CREATE OR REPLACE FUNCTION public.kiosk_api(op text, payload jsonb DEFAULT '{}'::jsonb, session_token text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare u kiosk_private.usage_month%rowtype;period date:=date_trunc('month',now() at time zone 'UTC')::date;next_time timestamptz;out jsonb;n bigint;is_teacher boolean;soft boolean;
begin
 next_time=(period+interval '1 month') at time zone 'UTC';
 insert into kiosk_private.usage_month(month) values(period) on conflict do nothing;
 select * into u from kiosk_private.usage_month where month=period for update;
 if u.requests>=150000 or u.estimated_bytes+1048576>536870912 then
  update kiosk_private.usage_month set blocked=blocked+1 where month=period;
  return jsonb_build_object('error','이번 달 앱 자체 사용 상한에 도달했어요. 보건교사에게 직접 접수해 주세요.','code',429,'quotaBlocked',true,'pauseUntil',floor(extract(epoch from next_time)*1000));
 end if;
 update kiosk_private.usage_month set requests=requests+1 where month=period;
 soft=u.requests>=120000 or u.estimated_bytes>=429496729;
 if coalesce(payload->>'auto','false')='true' and (soft or extract(isodow from now() at time zone 'Asia/Seoul')>5 or extract(hour from now() at time zone 'Asia/Seoul')<7 or extract(hour from now() at time zone 'Asia/Seoul')>=18) then
  out=jsonb_build_object('error',case when soft then '사용량 절약 모드예요. 필요한 경우 수동 조회해 주세요.' else '자동 갱신은 평일 07:00~18:00에만 작동해요.' end,'code',429,'autoPaused',true,'budgetSoft',soft);
 else
  out=kiosk_private.kiosk_api_impl(op,payload,session_token);
 end if;
 select exists(select 1 from kiosk_private.sessions where token_hash=encode(extensions.digest(session_token,'sha256'),'hex') and role='teacher' and expires>now()) into is_teacher;
 if is_teacher then out=out||jsonb_build_object('usage',jsonb_build_object('requests',u.requests+1,'requestLimit',150000,'estimatedBytes',u.estimated_bytes,'byteLimit',536870912,'soft',soft,'period',period));end if;
 n=octet_length(out::text)+2048;
 if n>1048576 then out=jsonb_build_object('error','조회 결과가 너무 커요. 날짜·검색 조건을 좁혀 주세요.','code',413);n=octet_length(out::text)+2048;end if;
 update kiosk_private.usage_month set estimated_bytes=estimated_bytes+n where month=period;
 return out;
end $function$
;

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
revoke all on function kiosk_private.kiosk_api_impl(text,jsonb,text) from public,anon,authenticated;
grant execute on function kiosk_private.kiosk_api_impl(text,jsonb,text) to service_role;
revoke all on function public.kiosk_api(text,jsonb,text) from public,anon,authenticated;
grant execute on function public.kiosk_api(text,jsonb,text) to service_role;
revoke all on function kiosk_private.purge_expired_visits() from public,anon,authenticated,service_role;
