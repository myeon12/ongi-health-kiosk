CREATE OR REPLACE FUNCTION public.kiosk_api(op text, payload jsonb DEFAULT '{}'::jsonb, session_token text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare s kiosk_private.sessions%rowtype;a kiosk_private.accounts%rowtype;v kiosk_private.visits%rowtype;tok text;target text;result jsonb;days int;mx int;cnt int;
begin
 select retention_days,max_number into days,mx from kiosk_private.settings where id;
 if days>0 then delete from kiosk_private.visits where status in ('done','cancelled') and created<now()-make_interval(days=>days);end if;
 delete from kiosk_private.sessions where expires<now();
 if op='session' then
  tok=encode(extensions.gen_random_bytes(32),'hex');
  insert into kiosk_private.sessions(token_hash,role,username,expires) values(encode(extensions.digest(tok,'sha256'),'hex'),'student','kiosk',now()+interval '12 hours');
  return jsonb_build_object('token',tok,'role','student','unlocked',false,'csrf','unused');
 end if;
 select * into s from kiosk_private.sessions where token_hash=encode(extensions.digest(session_token,'sha256'),'hex') and expires>now();
 if s.token_hash is null then return jsonb_build_object('error','접속 시간이 만료됐어요. 화면을 다시 열어 주세요.','code',401);end if;
 if op='public' then return jsonb_build_object('waiting',(select count(*) from kiosk_private.visits where status='waiting'),'maxNumber',mx);end if;
 if op='login' then
  select * into a from kiosk_private.accounts where username='teacher' and role='teacher' for update;
  if a.username is null then return jsonb_build_object('error','계정 정보를 확인해 주세요.','code',403);end if;
  if a.locked_until>now() then return jsonb_build_object('error','5분 후 다시 시도해 주세요.','code',429);end if;
  if extensions.crypt(coalesce(payload->>'password',''),a.password_hash)<>a.password_hash then
   update kiosk_private.accounts set failures=case when failures>=4 then 0 else failures+1 end,locked_until=case when failures>=4 then now()+interval '5 minutes' else null end where username=a.username;
   return jsonb_build_object('error','계정 또는 비밀번호를 확인해 주세요.','code',403);
  end if;
  update kiosk_private.accounts set failures=0,locked_until=null where username=a.username;
  tok=encode(extensions.gen_random_bytes(32),'hex');delete from kiosk_private.sessions where token_hash=s.token_hash;
  insert into kiosk_private.sessions(token_hash,role,username,expires) values(encode(extensions.digest(tok,'sha256'),'hex'),'teacher',a.username,now()+interval '15 minutes');
  return jsonb_build_object('ok',true,'token',tok,'role','teacher','unlocked',true);
 end if;
 if op='logout' then delete from kiosk_private.sessions where token_hash=s.token_hash;return jsonb_build_object('ok',true);end if;
 if op='checkin' then
  perform pg_advisory_xact_lock(774019);
  select * into v from kiosk_private.visits where id=(payload->>'id')::uuid;
  if v.id is not null then
   if v.grade<>(payload->>'grade')::int or v.room<>(payload->>'room')::int or v.num<>(payload->>'num')::int then return jsonb_build_object('error','접수 요청이 일치하지 않아요.','code',409);end if;
  else
   if (payload->>'num')::int>mx or jsonb_array_length(payload->'symptoms') not between 1 and 12 then return jsonb_build_object('error','선택한 내용을 확인해 주세요.','code',400);end if;
   if exists(select 1 from kiosk_private.visits where grade=(payload->>'grade')::int and room=(payload->>'room')::int and num=(payload->>'num')::int and status in ('waiting','treating')) then return jsonb_build_object('error','이미 접수되어 있어요. 선생님께 말해 주세요.','code',409);end if;
   if s.last_action>now()-interval '2 seconds' and exists(select 1 from kiosk_private.events where actor=s.token_hash) then return jsonb_build_object('error','잠시 후 다시 시도해 주세요.','code',429);end if;
   insert into kiosk_private.visits(id,grade,room,num,symptoms) values((payload->>'id')::uuid,(payload->>'grade')::int,(payload->>'room')::int,(payload->>'num')::int,payload->'symptoms') returning * into v;
   insert into kiosk_private.events(visit_id,actor,previous,next) values(v.id,s.token_hash,'new','waiting');
  end if;
  update kiosk_private.sessions set last_action=now() where token_hash=s.token_hash;
  return jsonb_build_object('ok',true,'position',(select count(*) from kiosk_private.visits where status='waiting' and seq<=v.seq));
 end if;
 if s.role<>'teacher' then return jsonb_build_object('error','선생님 계정만 사용할 수 있어요.','code',403);end if;
 if op='visits' then
  select coalesce(jsonb_agg(to_jsonb(q) order by q.seq),'[]') into result from (select *,case when status='waiting' then sum(case when status='waiting' then 1 else 0 end) over(order by seq) else null end as position from kiosk_private.visits) q;
  return jsonb_build_object('visits',result,'settings',jsonb_build_object('max_number',mx::text,'retention_days',days::text));
 end if;
 update kiosk_private.sessions set expires=now()+interval '15 minutes' where token_hash=s.token_hash;


 if op='delete_visit' then
  if payload->>'confirm' is distinct from 'delete' or jsonb_typeof(payload->'version') is distinct from 'number' then return jsonb_build_object('error','삭제 요청을 확인해 주세요.','code',400);end if;
  perform pg_advisory_xact_lock(774019);
  select * into v from kiosk_private.visits where id=(payload->>'id')::uuid for update;
  if v.id is null then return jsonb_build_object('error','이미 삭제됐거나 접수를 찾을 수 없어요.','code',404);end if;
  if v.version is distinct from (payload->>'version')::int then return jsonb_build_object('error','다른 창에서 변경됐어요. 새로고침 후 다시 확인해 주세요.','code',409);end if;
  delete from kiosk_private.visits where id=v.id;
  return jsonb_build_object('ok',true);
 end if;
 if op='reason' then
  if jsonb_typeof(payload->'symptoms') is distinct from 'array' then return jsonb_build_object('error','방문 사유를 확인해 주세요.','code',400);end if;
  if jsonb_array_length(payload->'symptoms') not between 1 and 12 or exists(select 1 from jsonb_array_elements(payload->'symptoms') x where jsonb_typeof(x)<>'string' or char_length(btrim(x#>>'{}')) not between 1 and 200) or jsonb_typeof(payload->'version') is distinct from 'number' then return jsonb_build_object('error','사유는 1~12개, 각 200자 이내로 입력해 주세요.','code',400);end if;
  perform pg_advisory_xact_lock(774019);
  select * into v from kiosk_private.visits where id=(payload->>'id')::uuid for update;
  if v.id is null then return jsonb_build_object('error','접수를 찾을 수 없어요.','code',404);end if;
  if v.version is distinct from (payload->>'version')::int then return jsonb_build_object('error','다른 창에서 변경됐어요. 수정 내용을 복사한 뒤 취소하고 다시 열어 주세요.','code',409);end if;
  select jsonb_agg(btrim(value) order by ord) into result from jsonb_array_elements_text(payload->'symptoms') with ordinality as t(value,ord);
  update kiosk_private.visits set symptoms=result,version=version+1 where id=v.id;
  insert into kiosk_private.events(visit_id,actor,previous,next) values(v.id,s.username,jsonb_build_object('symptoms',v.symptoms)::text,jsonb_build_object('symptoms',result)::text);
  return jsonb_build_object('ok',true,'version',v.version+1);
 end if;
 if op='status' then
  perform pg_advisory_xact_lock(774019);
  select * into v from kiosk_private.visits where id=(payload->>'id')::uuid for update;target=payload->>'status';
  if v.id is null then return jsonb_build_object('error','접수를 찾을 수 없어요.','code',404);end if;
  if v.version<>(payload->>'version')::int then return jsonb_build_object('error','다른 창에서 변경됐어요. 새로 확인해 주세요.','code',409);end if;
  if not ((v.status='waiting' and target in ('treating','cancelled')) or (v.status='treating' and target in ('done','waiting')) or (v.status='done' and target in ('waiting','treating')) or (v.status='cancelled' and target='waiting')) then return jsonb_build_object('error','허용되지 않는 변경이에요.','code',400);end if;
  if target in ('waiting','treating') and exists(select 1 from kiosk_private.visits where grade=v.grade and room=v.room and num=v.num and id<>v.id and status in ('waiting','treating')) then return jsonb_build_object('error','이 학생의 다른 접수가 진행 중이에요.','code',409);end if;
  update kiosk_private.visits set status=target,started=case when target='treating' then now() else started end,finished=case when target in ('done','cancelled') then now() else null end,version=version+1 where id=v.id;
  insert into kiosk_private.events(visit_id,actor,previous,next) values(v.id,s.username,v.status,target);
  return jsonb_build_object('ok',true);
 end if;
 if op='settings' then
  if (payload->>'maxNumber')::int not between 1 and 60 or (payload->>'retentionDays')::int not between 0 and 3650 then return jsonb_build_object('error','설정값을 확인해 주세요.','code',400);end if;
  update kiosk_private.settings set max_number=(payload->>'maxNumber')::int,retention_days=(payload->>'retentionDays')::int where id;
  return jsonb_build_object('ok',true);
 end if;
 return jsonb_build_object('error','지원하지 않는 요청이에요.','code',400);
end $function$;