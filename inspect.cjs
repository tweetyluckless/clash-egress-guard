'use strict';
// Lists the outbounds in the running Clash Verge Rev configuration without any secrets, and
// works out the upstream first hop for one outbound. Only names, types, servers and ports
// are printed: passwords, UUIDs, keys and subscription URLs never leave this process.
//
//   node inspect.cjs [--clash-dir DIR]                 list proxies and groups
//   node inspect.cjs [--clash-dir DIR] --outbound NAME  first hop and suggested config
//
// The current choice of each select group is read from the running core's controller. The
// controller secret is only sent to that local endpoint and is never printed.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),http=require('node:http');
const P=require('./policy.cjs');
const BUILT_IN=['DIRECT','REJECT','PASS','COMPATIBLE','GLOBAL'];
const UDP_TRANSPORTS=new Set(['hysteria','hysteria2','tuic','wireguard']);
const AUTO_GROUPS=new Set(['url-test','fallback','load-balance']);
const USAGE='Usage: node inspect.cjs [--clash-dir DIR] [--outbound NAME]';

function defaultClashDir(env=process.env){
  return path.join(env.APPDATA||path.join(os.homedir(),'.config'),'io.github.clash-verge-rev.clash-verge-rev');
}
// Service mode renames the controller pipe (for example "...-sidecar-release-<hash>" becomes
// "...-production-<hash>"), so after the configured pipe, try the verge-mihomo pipes that exist.
function controllerEndpoints(config){
  const endpoints=[],pipe=config['external-controller-pipe'],tcp=config['external-controller'];
  if(pipe)endpoints.push({socketPath:String(pipe)});
  if(process.platform==='win32'){
    try{
      const suffix=pipe?String(pipe).split('-').pop():'\0';
      const names=fs.readdirSync('\\\\.\\pipe\\').filter(n=>/^verge-mihomo-/.test(n));
      names.sort((a,b)=>Number(b.endsWith(suffix))-Number(a.endsWith(suffix)));
      for(const n of names){const p='\\\\.\\pipe\\'+n;if(p!==pipe)endpoints.push({socketPath:p});}
    }catch{}
  }
  const m=tcp?/^(?:\[?([^\]]*)\]?)?:(\d+)$/.exec(String(tcp)):null;
  if(m)endpoints.push({host:!m[1]||m[1]==='0.0.0.0'||m[1]==='::'?'127.0.0.1':m[1],port:Number(m[2])});
  return endpoints;
}
function controllerGet(endpoint,secret,urlPath){
  const headers={Accept:'application/json'};
  if(secret)headers.Authorization='Bearer '+secret;
  return new Promise((resolve,reject)=>{
    const req=http.get({...endpoint,path:urlPath,headers,timeout:5000},res=>{
      let body='';res.setEncoding('utf8');res.on('data',c=>body+=c);
      res.on('end',()=>{if(res.statusCode!==200)return reject(new Error('Controller returned '+res.statusCode+'.'));try{resolve(JSON.parse(body));}catch{reject(new Error('Controller returned invalid JSON.'));}});
    });
    req.on('timeout',()=>req.destroy(new Error('Controller timeout.')));
    req.on('error',reject);
  });
}
async function readSelections(config){
  const endpoints=controllerEndpoints(config);
  if(!endpoints.length)throw new Error('No external controller is configured.');
  let data,lastError;
  for(const endpoint of endpoints){
    try{data=await controllerGet(endpoint,config.secret,'/proxies');break;}catch(e){lastError=e;}
  }
  if(!data)throw new Error('The Clash core controller could not be reached ('+lastError.message.replace(/\\\\\.\\pipe\\\S+/,'<pipe>')+').');
  const selected={};
  for(const [name,value] of Object.entries(data.proxies||{}))if(value&&typeof value.now==='string'&&value.now)selected[name]=value.now;
  return selected;
}
function summarize(config,selected={}){
  return {
    mixedPort:config['mixed-port']??null,
    proxies:(config.proxies||[]).map(p=>({name:p.name,type:p.type,server:p.server,port:p.port,dialerProxy:p['dialer-proxy']||null})),
    groups:(config['proxy-groups']||[]).map(g=>({name:g.name,type:g.type,selected:selected[g.name]||null,members:Array.isArray(g.proxies)?g.proxies:[],usesProviders:Array.isArray(g.use)&&g.use.length>0}))
  };
}
function firstHops(config,outbound,selected={}){
  const proxies=new Map((config.proxies||[]).map(p=>[p.name,p]));
  const groups=new Map((config['proxy-groups']||[]).map(g=>[g.name,g]));
  const hops=new Map(),problems=new Set(),notes=new Set();
  function walk(name,seen){
    if(BUILT_IN.includes(name)){problems.add(`Built-in outbound ${name} is not allowed.`);return;}
    if(seen.has(name)){problems.add(`Cyclic reference at ${name}.`);return;}
    const next=new Set(seen);next.add(name);
    const proxy=proxies.get(name);
    if(proxy){
      if(proxy['dialer-proxy'])return walk(proxy['dialer-proxy'],next);
      if(UDP_TRANSPORTS.has(String(proxy.type).toLowerCase()))problems.add(`First hop ${name} (${proxy.type}) connects over UDP, but the firewall only allows TCP to the upstream.`);
      hops.set(`${proxy.server}:${proxy.port}`,{host:proxy.server,port:proxy.port,via:name,type:proxy.type});
      return;
    }
    const group=groups.get(name);
    if(!group){problems.add(`Unknown outbound ${name}.`);return;}
    if(Array.isArray(group.use)&&group.use.length)problems.add(`Group ${name} uses proxy providers, which the guard cannot resolve.`);
    const members=Array.isArray(group.proxies)?group.proxies:[];
    if(!members.length){problems.add(`Group ${name} has no explicit members.`);return;}
    if(group.type==='relay')return walk(members[0],next);
    if(group.type==='select'&&members.includes(selected[name])){
      notes.add(`Group ${name} currently selects ${selected[name]}. Changing that selection later breaks the guard until you prepare and install again.`);
      return walk(selected[name],next);
    }
    if(AUTO_GROUPS.has(group.type))problems.add(`Group ${name} (${group.type}) switches nodes automatically, so its first hop can change. Use a select group or a single node.`);
    for(const member of members)walk(member,next);
  }
  walk(outbound,new Set());
  const result={outbound,firstHops:[...hops.values()],problems:[...problems],notes:[...notes]};
  if(result.firstHops.length>1)result.problems.push('Several first hops: only the one set as upstream will be reachable. Choose a single node or a chain with one entry.');
  if(result.firstHops.length===1&&!result.problems.length)result.suggestedConfig={outbound,upstream:{host:result.firstHops[0].host,port:result.firstHops[0].port}};
  return result;
}
async function main(args){
  let dir=defaultClashDir(),outbound=null;
  for(let i=0;i<args.length;i++){
    if(args[i]==='--clash-dir'&&args[i+1])dir=args[++i];
    else if(args[i]==='--outbound'&&args[i+1])outbound=args[++i];
    else throw new Error(USAGE);
  }
  const file=path.join(dir,'clash-verge.yaml');
  if(!fs.existsSync(file))throw new Error(`clash-verge.yaml was not found in ${dir}. Start Clash Verge Rev once, or pass --clash-dir.`);
  const config=P.parse(fs.readFileSync(file,'utf8').replace(/^﻿/,'')).toJS({maxAliasCount:50});
  let selected={},controller='connected';
  try{selected=await readSelections(config);}catch(e){controller='unavailable: '+e.message+' Select groups are treated as all of their members.';}
  if(outbound===null)return {clashDir:dir,controller,...summarize(config,selected),next:'Choose an outbound, then run: npm run inspect -- --outbound "<name>"'};
  return {controller,...firstHops(config,outbound,selected)};
}
if(require.main===module){
  main(process.argv.slice(2)).then(r=>console.log(JSON.stringify(r,null,2))).catch(e=>{console.error(e.message);process.exitCode=1;});
}
module.exports={summarize,firstHops,defaultClashDir,main};
