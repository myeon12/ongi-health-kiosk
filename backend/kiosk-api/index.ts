const symptoms=['상처가 났어요','삐거나 부딪혔어요','배가 아파요','머리가 아파요','팔·다리가 아파요','목이 아프거나 기침·콧물이 나요','열이 나는 것 같아요','어지러워요','토할 것 같아요','눈이 가렵거나 따가워요','코피가 나요','그 밖의 이유예요'];
const cors={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'content-type,x-kiosk-session','Access-Control-Allow-Methods':'POST,OPTIONS','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'};
const url=Deno.env.get('SUPABASE_URL')!;
const key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || Object.values(JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS')||'{}'))[0] as string;
Deno.serve(async req=>{
 const send=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,'Content-Type':'application/json; charset=utf-8'}});
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers:cors});
 if(req.method!=='POST')return send({error:'POST 요청만 지원합니다.'},405);
 try{
  const raw=await req.text();if(raw.length>8192)return send({error:'요청이 너무 큽니다.'},413);
  const body=JSON.parse(raw),op=body.op,payload=body.payload||{};
  if(!['session','public','login','logout','checkin','visits','status','settings','reason','delete_visit'].includes(op))return send({error:'지원하지 않는 요청입니다.'},400);
  if(op==='checkin'){
   if(!Number.isInteger(payload.grade)||payload.grade<1||payload.grade>6||!Number.isInteger(payload.room)||payload.room<1||payload.room>9||!Number.isInteger(payload.num)||payload.num<1||payload.num>60||!Array.isArray(payload.symptoms)||!payload.symptoms.length||payload.symptoms.length>12||payload.symptoms.some((x:unknown)=>!symptoms.includes(x as string))||! /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(payload.id||''))return send({error:'선택한 내용을 확인해 주세요.'},400);
  }
  if(op==='login'&&(typeof payload.password!=='string'||payload.password.length>200))return send({error:'계정 정보를 확인해 주세요.'},400);
  if(op==='status'&&(!Number.isInteger(payload.version)||!['waiting','treating','done','cancelled'].includes(payload.status)))return send({error:'변경 요청을 확인해 주세요.'},400);
  if(op==='reason'&&(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(payload.id||'')||!Number.isInteger(payload.version)||!Array.isArray(payload.symptoms)||payload.symptoms.length<1||payload.symptoms.length>12||payload.symptoms.some((x:unknown)=>typeof x!=='string'||!x.trim()||x.trim().length>200)))return send({error:'사유는 1~12개, 각 200자 이내로 입력해 주세요.'},400);
  if(op==='delete_visit'&&(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(payload.id||'')||!Number.isInteger(payload.version)||payload.confirm!=='delete'))return send({error:'삭제 요청을 확인해 주세요.'},400);
  if(op==='visits'&&((payload.mode!==undefined&&!['active','history','settings'].includes(payload.mode))||(payload.query!==undefined&&(typeof payload.query!=='string'||payload.query.length>200))||(payload.page!==undefined&&(!Number.isInteger(payload.page)||payload.page<0||payload.page>100000))||(payload.limit!==undefined&&(!Number.isInteger(payload.limit)||payload.limit<1||payload.limit>200))||(payload.date!==undefined&&(typeof payload.date!=='string'||(payload.date!==''&&(!/^\\d{4}-\\d{2}-\\d{2}$/.test(payload.date)||Number.isNaN(Date.parse(payload.date))||new Date(payload.date).toISOString().slice(0,10)!==payload.date))))||(payload.status!==undefined&&!['','waiting','treating','done','cancelled'].includes(payload.status))||(payload.beforeSeq!==undefined&&!/^\\d{1,18}$/.test(String(payload.beforeSeq)))))return send({error:'조회 조건을 확인해 주세요.'},400);
  const token=req.headers.get('x-kiosk-session')||'';
  if(op!=='session'&&!/^[a-f0-9]{64}$/.test(token))return send({error:'접속 시간이 만료됐어요. 화면을 다시 열어 주세요.'},401);
  const res=await fetch(url+'/rest/v1/rpc/kiosk_api',{method:'POST',headers:{apikey:key,Authorization:'Bearer '+key,'Content-Type':'application/json'},body:JSON.stringify({op,payload,session_token:token})});
  if(!res.ok){await res.text();return send({error:'요청을 처리하지 못했어요. 같은 화면에서 다시 시도해 주세요.'},500)}
  const out=await res.json();if(out.error)return send(out,out.code||400);
  if(op==='public')out.symptoms=symptoms;
  return send(out);
 }catch{return send({error:'요청을 처리하지 못했어요.'},400)}
});
