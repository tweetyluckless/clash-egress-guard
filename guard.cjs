'use strict';
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),https=require('node:https'),tls=require('node:tls'),net=require('node:net'),dns=require('node:dns').promises,crypto=require('node:crypto');
const {execFileSync}=require('node:child_process');
const P=require('./policy.cjs');
const {jsonForPowerShell,currentUser}=require('./settings.cjs');
const S=require('./settings.cjs').load();
const ROOT=S.root,STATE=S.state,EXPECTED=S.expectedIp||'',COUNTRY=S.expectedCountry;
const FILES=['profiles/Script.js','config.yaml','verge.yaml','clash-verge.yaml'];
const read=p=>fs.readFileSync(p,'utf8').replace(/^\uFEFF/,'');
const topValue=(s,key)=>P.parse(s).toJS({maxAliasCount:50})[key];
const atomic=(p,data)=>{const t=p+'.egress-new';fs.writeFileSync(t,data,'utf8');fs.renameSync(t,p);};
function current(){return P.parse(read(path.join(ROOT,'clash-verge.yaml'))).toJS({maxAliasCount:50});}
function policyCheck(){return P.checkPolicy(current(),S);}
function configureMode(mode){
  if(!read(path.join(ROOT,'profiles/Script.js')).includes(P.MARKER))throw new Error('Persistent guard policy is missing.');
  const m=P.modeChanges(mode);
  atomic(path.join(ROOT,'verge.yaml'),P.update(read(path.join(ROOT,'verge.yaml')),[[['enable_tun_mode'],m.enabled],[['enable_system_proxy'],m.enabled]]));
  for(const f of ['config.yaml','clash-verge.yaml'])atomic(path.join(ROOT,f),P.update(read(path.join(ROOT,f)),m.changes));
  return {configured:mode};
}
async function ipQuery(proxy = false, second = false, verifyEgress = true) {
  const url = new URL(second ? 'http://ip-api.com/json/?fields=status,query,countryCode,city' : 'https://ipinfo.io/json');
  let agent;
  let tunnel;
  if (proxy) {
    tunnel = await new Promise((resolve, reject) => {
      const port = Number(topValue(read(path.join(ROOT,'clash-verge.yaml')), 'mixed-port'));
      if (!Number.isInteger(port) || port < 1 || port > 65535) { reject(new Error('Invalid active Clash proxy port')); return; }
      const req = http.request({host:'127.0.0.1',port,method:'CONNECT',path:url.hostname + ':443'});
      req.on('error', reject);
      req.setTimeout(10000, () => req.destroy(new Error('Proxy timeout')));
      req.on('connect', (res, sock, head) => {
        if (res.statusCode !== 200) { sock.destroy(); reject(new Error('Proxy CONNECT failed')); return; }
        sock.setTimeout(0); if (head.length) sock.unshift(head); resolve(sock);
      });
      req.end();
    });
    agent = new https.Agent({keepAlive:false});
    agent.createConnection = () => tls.connect({socket:tunnel,servername:url.hostname});
  }
  try {
    const result = await new Promise((resolve, reject) => {
      const mod = url.protocol === 'https:' ? https : http;
      const req = mod.get(url, {agent:agent || false, headers:{Accept:'application/json'}}, res => {
        let body=''; res.setEncoding('utf8'); res.on('data',c=>body+=c); res.on('error',reject);
        res.on('end',()=>{try { if(res.statusCode!==200) throw new Error('IP service returned '+res.statusCode); resolve(JSON.parse(body)); } catch(e){reject(e);} });
      });
      req.on('error',reject);
      const timer=setTimeout(()=>req.destroy(new Error('IP query timeout')),15000);
      req.on('close',()=>clearTimeout(timer));
    });
    const resultIp = result.ip || result.query;
    const country = result.country || result.countryCode;
    if(verifyEgress && ((EXPECTED && resultIp!==EXPECTED) || country!==COUNTRY)) throw new Error('Unexpected egress: '+JSON.stringify({ip:resultIp,country}));
    return {ip:resultIp,country,city:result.city};
  } finally { agent?.destroy(); tunnel?.destroy(); }
}
async function tcpProbe(host) {
  return new Promise(resolve => {
    const s=net.createConnection({host,port:443});
    const done=ok=>{s.destroy();resolve(ok);};
    const timer=setTimeout(()=>done(false),5000);
    s.once('connect',()=>{clearTimeout(timer);done(true);});
    s.once('error',()=>{clearTimeout(timer);done(false);});
  });
}

async function prepare(){
  if(process.platform!=='win32')throw new Error('Preparation and system changes require Windows.');
  if(fs.existsSync(path.join(STATE,'manifest.json')))throw new Error('A preparation already exists. Inspect or restore it before preparing again.');
  const runtime=current();
  const protectedConfig=P.enforcePolicy(structuredClone(runtime),S);
  P.checkPolicy(protectedConfig,S);
  const script=read(path.join(ROOT,'profiles/Script.js'));
  if(script.includes(P.MARKER))throw new Error('The global script is already wrapped. Restore the old installation first.');
  const wrapped=script+P.wrapper(S);
  new (require('node:vm').Script)(wrapped);
  const version=execFileSync(S.core,['-v'],{encoding:'utf8',windowsHide:true}).trim();
  const addresses=[...new Set((await dns.lookup(S.upstream.host,{all:true,family:4})).map(a=>a.address))];
  if(!addresses.length)throw new Error('No first-hop IPv4 addresses could be resolved.');
  await ipQuery(true);
  const contents={};
  for(const file of FILES){
    const src=read(path.join(ROOT,file));
    if(file.endsWith('Script.js'))contents[file]=wrapped;
    else if(file==='verge.yaml')contents[file]=P.update(src,[[['enable_tun_mode'],true],[['enable_system_proxy'],true]]);
    else{
      const keys=['mode','ipv6','allow-lan','tun','dns'];
      if(file==='clash-verge.yaml')keys.push('rules');
      contents[file]=P.update(src,keys.map(k=>[[k],protectedConfig[k]]));
    }
  }
  const hashes={};
  for(const file of FILES){
    for(const dir of ['backup','staged'])fs.mkdirSync(path.dirname(path.join(STATE,dir,file)),{recursive:true});
    fs.copyFileSync(path.join(ROOT,file),path.join(STATE,'backup',file));
    hashes[file]=crypto.createHash('sha256').update(fs.readFileSync(path.join(ROOT,file))).digest('hex');
    fs.writeFileSync(path.join(STATE,'staged',file),contents[file],'utf8');
  }
  const manifest={root:ROOT,state:STATE,files:FILES,hashes,preparedBy:currentUser(),preparedAt:new Date().toISOString(),expectedIp:EXPECTED,expectedCountry:COUNTRY,device:S.device,upstreamHost:S.upstream.host,upstreamPort:S.upstream.port,upstreamAddresses:addresses,core:S.core,app:S.app,coreSha256:crypto.createHash('sha256').update(fs.readFileSync(S.core)).digest('hex').toUpperCase(),trustedServiceCoreRoot:S.trustedServiceCoreRoot,version};
  fs.writeFileSync(path.join(STATE,'manifest.json'),jsonForPowerShell(manifest,2));
  return {prepared:true,state:STATE,files:FILES.length};
}
async function run(){
  switch(process.argv[2]){
    case 'settings':return S;
    case 'prepare':return prepare();
    case 'policy-check':return policyCheck();
    case 'proxy-check':return ipQuery(true);
    case 'direct-check':return {first:await ipQuery(false),second:await ipQuery(false,true)};
    case 'egress-check':return ipQuery(false,false,false);
    case 'configure-mode':return configureMode(process.argv[3]);
    case 'mode-file-check':{const c=current(),v=P.parse(read(path.join(ROOT,'verge.yaml'))).toJS();return {tunConfigured:c.tun?.enable===true,vergeTun:String(v.enable_tun_mode),vergeProxy:String(v.enable_system_proxy)};}
    case 'blocked-check':{const [v4,v6]=await Promise.all([tcpProbe('1.1.1.1'),tcpProbe('2606:4700:4700::1111')]);if(v4||v6)throw new Error('A direct TCP connection succeeded with the TUN stopped.');return {blocked:true,ipv4Connected:v4,ipv6Connected:v6,note:'These are sample connection probes, not a complete leak audit or proof of IPv6 availability.'};}
    default:throw new Error('Unknown command.');
  }
}
run().then(r=>console.log(process.stdout.isTTY?JSON.stringify(r):jsonForPowerShell(r))).catch(e=>{console.error(e.message);process.exitCode=1;});
