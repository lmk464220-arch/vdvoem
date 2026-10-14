#!/bin/bash
# «Вдвоём» — добавляет на ваш сервер уведомления «напарник зовёт».
# Запуск на сервере от root:   curl -fsSL https://lmk464220-arch.github.io/vdvoem/push-setup.sh | bash
set -e
export DEBIAN_FRONTEND=noninteractive
echo "=== Вдвоём: включаю уведомления ==="
IP=$(curl -4 -fsS https://api.ipify.org || curl -4 -fsS https://ifconfig.me || hostname -I | awk '{print $1}')
HOST="${IP//./-}.sslip.io"
command -v node >/dev/null || { apt-get update -y; apt-get install -y nodejs; }
mkdir -p /opt/vdvoem-push
cat > /opt/vdvoem-push/server.js <<'EOF_SERVER'
// «Вдвоём» — уведомления «напарник зовёт» (Web Push). Без сторонних библиотек: только Node.js.
// Слушает 127.0.0.1:9002; снаружи — через Caddy: https://<сервер>/push/…
const http=require('http'),https=require('https'),fs=require('fs'),crypto=require('crypto');
const DIR=__dirname,KF=DIR+'/vapid.json',DB=DIR+'/subs.json',PORT=+process.env.PORT||9002;
const SUBJ='https://lmk464220-arch.github.io/vdvoem/';
const b64u=b=>Buffer.from(b).toString('base64').replace(/=+$/,'').replace(/\+/g,'-').replace(/\//g,'_');
const ub64=s=>Buffer.from(s.replace(/-/g,'+').replace(/_/g,'/'),'base64');
/* ключи VAPID */
let K;try{K=JSON.parse(fs.readFileSync(KF))}catch(_){const e=crypto.createECDH('prime256v1');e.generateKeys();K={pub:b64u(e.getPublicKey()),priv:b64u(e.getPrivateKey())};fs.writeFileSync(KF,JSON.stringify(K),{mode:0o600})}
const PUB=ub64(K.pub);
const signKey=crypto.createPrivateKey({key:{kty:'EC',crv:'P-256',x:b64u(PUB.subarray(1,33)),y:b64u(PUB.subarray(33,65)),d:K.priv},format:'jwk'});
function vapid(endpoint){const aud=new URL(endpoint).origin;
  const h=b64u(JSON.stringify({typ:'JWT',alg:'ES256'})),c=b64u(JSON.stringify({aud,exp:Math.floor(Date.now()/1000)+12*3600,sub:SUBJ}));
  const sig=crypto.sign('sha256',Buffer.from(h+'.'+c),{key:signKey,dsaEncoding:'ieee-p1363'});
  return 'vapid t='+h+'.'+c+'.'+b64u(sig)+', k='+K.pub}
/* шифрование содержимого (RFC 8291, aes128gcm) */
function encrypt(sub,text){const uaPub=ub64(sub.keys.p256dh),auth=ub64(sub.keys.auth);
  const e=crypto.createECDH('prime256v1');e.generateKeys();const asPub=e.getPublicKey(),secret=e.computeSecret(uaPub);
  const ikm=Buffer.from(crypto.hkdfSync('sha256',secret,auth,Buffer.concat([Buffer.from('WebPush: info\0'),uaPub,asPub]),32));
  const salt=crypto.randomBytes(16);
  const cek=Buffer.from(crypto.hkdfSync('sha256',ikm,salt,Buffer.from('Content-Encoding: aes128gcm\0'),16));
  const nonce=Buffer.from(crypto.hkdfSync('sha256',ikm,salt,Buffer.from('Content-Encoding: nonce\0'),12));
  const ci=crypto.createCipheriv('aes-128-gcm',cek,nonce);const ct=Buffer.concat([ci.update(Buffer.concat([Buffer.from(text),Buffer.from([2])])),ci.final(),ci.getAuthTag()]);
  const hdr=Buffer.alloc(21);salt.copy(hdr,0);hdr.writeUInt32BE(4096,16);hdr[20]=65;
  return Buffer.concat([hdr,asPub,ct])}
function sendPush(sub,text){return new Promise((res,rej)=>{const body=encrypt(sub,text),u=new URL(sub.endpoint);
  const mod=u.protocol==='http:'?http:https;
  const r=mod.request(u,{method:'POST',headers:{'Content-Encoding':'aes128gcm','Content-Type':'application/octet-stream','Content-Length':body.length,TTL:'900',Urgency:'high',Authorization:vapid(sub.endpoint)},timeout:10000},
    x=>{let d='';x.on('data',c=>d+=c);x.on('end',()=>x.statusCode<300?res(x.statusCode):rej({statusCode:x.statusCode,body:d.slice(0,200)}))});
  r.on('error',e=>rej({message:e.message}));r.on('timeout',()=>r.destroy(new Error('timeout')));r.end(body)})}
/* подписки: { код комнаты: { устройство: {sub,t} } } */
let db={};try{db=JSON.parse(fs.readFileSync(DB))}catch(_){}
let saveT=null;function save(){clearTimeout(saveT);saveT=setTimeout(()=>fs.writeFile(DB,JSON.stringify(db),()=>{}),500)}
const okCode=c=>typeof c==='string'&&/^[a-z0-9]{6}$/.test(c),okDid=d=>typeof d==='string'&&/^[a-z0-9]{6,24}$/.test(d);
const okSub=s=>s&&typeof s.endpoint==='string'&&(/^https:\/\//.test(s.endpoint)||!!process.env.PUSH_TEST)&&s.keys&&typeof s.keys.p256dh==='string'&&typeof s.keys.auth==='string';
const lastRing={};
function reply(res,code,obj){res.writeHead(code,{'Content-Type':'application/json','Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'Content-Type','Access-Control-Allow-Methods':'GET,POST,OPTIONS'});res.end(JSON.stringify(obj))}
const srv=http.createServer((req,res)=>{
  const path=req.url.split('?')[0].replace(/^\/push/,'')||'/';
  if(req.method==='OPTIONS')return reply(res,204,{});
  if(req.method==='GET'&&path==='/key')return reply(res,200,{key:K.pub});
  if(req.method==='GET'&&path==='/')return reply(res,200,{ok:true,rooms:Object.keys(db).length});
  if(req.method!=='POST')return reply(res,404,{});
  let body='';req.on('data',d=>{body+=d;if(body.length>8000)req.destroy()});
  req.on('end',async()=>{let m;try{m=JSON.parse(body)}catch(_){return reply(res,400,{})}
    if(path==='/sub'){                      // {did, codes:[…], sub}
      if(!okDid(m.did)||!okSub(m.sub)||!Array.isArray(m.codes))return reply(res,400,{});
      const codes=m.codes.filter(okCode).slice(0,100);
      for(const c of Object.keys(db))if(db[c][m.did]&&!codes.includes(c)){delete db[c][m.did];if(!Object.keys(db[c]).length)delete db[c]}
      const sub={endpoint:m.sub.endpoint,keys:{p256dh:m.sub.keys.p256dh,auth:m.sub.keys.auth}};
      codes.forEach(c=>{(db[c]=db[c]||{})[m.did]={sub,t:Date.now()}});save();return reply(res,200,{ok:true,n:codes.length})}
    if(path==='/ring'){                     // {code, did, name}
      if(!okCode(m.code)||!okDid(m.did))return reply(res,400,{});
      const r=await doRing(m,'https');return reply(res,r.busy?429:200,r)}
    reply(res,404,{})})});

/* позвать напарника: и по https, и через запасной канал (MQTT) — что дойдёт первым */
async function doRing(m,via){const now=Date.now();if(now-(lastRing[m.code]||0)<8000)return {busy:true};lastRing[m.code]=now;
  const name=String(m.name||'').slice(0,20).trim()||'Напарник';
  const text=JSON.stringify({title:'Смотрим вдвоём',body:name+' зовёт смотреть вместе',code:m.code});
  const targets=Object.entries(db[m.code]||{}).filter(([d])=>d!==m.did);let sent=0;
  await Promise.all(targets.map(([d,x])=>sendPush(x.sub,text).then(()=>sent++).catch(e=>{console.log('push error',e.statusCode||e.message,e.body||'');
    if(e.statusCode===404||e.statusCode===410){delete db[m.code][d];save()}})));
  console.log('ring',m.code,'('+via+') →',sent+'/'+targets.length);return {sent,targets:targets.length}}
/* запасной канал: слушаем приглашения на общедоступных MQTT-посредниках — до них телефон часто достаёт, даже когда до нашего сервера нет */
const tls=require('tls'),net=require('net');
const MQ=(process.env.MQ_HOSTS||'broker.hivemq.com:8883').split(',');
function vlen(n){const b=[];do{let x=n%128;n=Math.floor(n/128);if(n>0)x|=128;b.push(x)}while(n>0);return Buffer.from(b)}
function pkt(type,body){return Buffer.concat([Buffer.from([type]),vlen(body.length),body])}
function str(s){const b=Buffer.from(s);const l=Buffer.alloc(2);l.writeUInt16BE(b.length);return Buffer.concat([l,b])}
function mqttListen(hp){const [host,port]=hp.split(':');let sock,buf=Buffer.alloc(0),ping=null,alive=false;
  const id='vdvoem-srv-'+crypto.randomBytes(4).toString('hex');
  const go=()=>{buf=Buffer.alloc(0);const opts={host,port:+port||8883,servername:host};
    sock=(process.env.MQ_PLAIN?net.connect(opts.port,host):tls.connect(opts));
    sock.on(process.env.MQ_PLAIN?'connect':'secureConnect',()=>{sock.write(pkt(0x10,Buffer.concat([str('MQTT'),Buffer.from([4,2,0,60]),str(id)])))});
    sock.on('data',d=>{buf=Buffer.concat([buf,d]);for(;;){if(buf.length<2)return;let mul=1,len=0,i=1,b;
      do{if(i>=buf.length)return;b=buf[i++];len+=(b&127)*mul;mul*=128}while(b&128);if(buf.length<i+len)return;
      const t=buf[0]>>4,q=(buf[0]>>1)&3,body=buf.subarray(i,i+len);buf=buf.subarray(i+len);
      if(t===2){alive=true;console.log('mqtt',host,'подключён');sock.write(pkt(0x82,Buffer.concat([Buffer.from([0,1]),str('toxanton/pushring/+'),Buffer.from([0])])));
        clearInterval(ping);ping=setInterval(()=>{try{sock.write(Buffer.from([0xC0,0]))}catch(_){}},30000)}
      else if(t===3){const tl=body.readUInt16BE(0),off=2+tl+(q?2:0);let m;try{m=JSON.parse(body.subarray(off).toString())}catch(_){continue}
        if(m&&okCode(m.code)&&okDid(m.did)&&Math.abs(Date.now()-(+m.ts||0))<120000)doRing(m,'mqtt '+host).catch(()=>{})}}});
    const again=()=>{clearInterval(ping);if(alive)console.log('mqtt',host,'отключён');alive=false;setTimeout(go,5000)};
    sock.on('error',()=>{});sock.on('close',again)};
  go()}
if(require.main===module)MQ.filter(Boolean).forEach(mqttListen);
if(require.main===module)srv.listen(PORT,'127.0.0.1',()=>console.log('vdvoem push on',PORT));
module.exports={encrypt,vapid,K,srv,mqttListen,db};
EOF_SERVER
cat > /etc/systemd/system/vdvoem-push.service <<EOF_UNIT
[Unit]
Description=Vdvoem push
After=network.target
[Service]
ExecStart=$(command -v node) /opt/vdvoem-push/server.js
WorkingDirectory=/opt/vdvoem-push
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF_UNIT
systemctl daemon-reload
systemctl enable vdvoem-push >/dev/null 2>&1 || true
systemctl restart vdvoem-push
cat > /etc/caddy/Caddyfile <<EOF_CADDY
{
	servers {
		protocols h1
	}
}
$HOST {
	handle /mqtt* {
		reverse_proxy 127.0.0.1:9001
	}
	handle /push* {
		reverse_proxy 127.0.0.1:9002
	}
	handle {
		respond "Vdvoem server OK" 200
	}
}
EOF_CADDY
systemctl reload caddy || systemctl restart caddy
sleep 3
echo
echo "=== Проверка ==="
for s in mosquitto caddy coturn vdvoem-push; do printf "%-12s %s\n" "$s" "$(systemctl is-active $s)"; done
echo
if curl -fsS "https://$HOST/push/key" >/dev/null; then echo "  ГОТОВО: уведомления работают ✅"; else echo "  Что-то не так — пришлите Claude весь текст выше"; fi
