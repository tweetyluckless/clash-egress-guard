'use strict';
const YAML=require('yaml');
const MARKER='egressGuardOriginalMain';
// Kept self-contained because the same function is injected into Clash's script runtime.
function enforcePolicy(config,s){
  const proxies=new Map((config.proxies||[]).map(p=>[p.name,p]));
  const groups=new Map((config['proxy-groups']||[]).map(g=>[g.name,g]));
  function inspect(name,seen){
    if(['DIRECT','REJECT','PASS','COMPATIBLE','GLOBAL'].includes(name))throw new Error('Direct/fallback built-in outbound is not allowed.');
    if(seen.has(name))throw new Error('Cyclic outbound group.');
    if(proxies.has(name))return;
    const group=groups.get(name);
    if(!group||!Array.isArray(group.proxies)||!group.proxies.length)throw new Error('The configured outbound must resolve to explicit existing proxy nodes.');
    const next=new Set(seen);next.add(name);
    for(const member of group.proxies)inspect(member,next);
  }
  inspect(s.outbound,new Set());
  config.mode='rule';config.ipv6=false;config['allow-lan']=false;
  config.tun={...(config.tun||{}),enable:true,device:s.device,stack:'gvisor','auto-route':true,'auto-detect-interface':true,'strict-route':true,'dns-hijack':['any:53','tcp://any:53']};
  config.dns={enable:true,listen:'127.0.0.1:1053',ipv6:false,'enhanced-mode':'fake-ip','fake-ip-range':'198.18.0.1/16','default-nameserver':s.bootstrapDns,'proxy-server-nameserver':s.bootstrapDns,nameserver:['https://1.1.1.1/dns-query#'+encodeURIComponent(s.outbound)]};
  config.rules=['NETWORK,udp,REJECT','MATCH,'+s.outbound,'MATCH,REJECT'];
  return config;
}
function parse(text){const d=YAML.parseDocument(text,{uniqueKeys:true,maxAliasCount:50});if(d.errors.length)throw new Error('Invalid local YAML; repair it before continuing.');return d;}
function update(text,changes){const d=parse(text);for(const [keys,value] of changes)d.setIn(keys,value);return d.toString({lineWidth:0});}
function wrapper(s){const policy={outbound:s.outbound,device:s.device,bootstrapDns:s.bootstrapDns};return '\n// Clash Egress Guard: generated locally; contains no proxy credentials.\nconst '+MARKER+' = main;\nmain = function(config, ...args) {\n  return ('+enforcePolicy.toString()+')('+MARKER+'(config, ...args), '+JSON.stringify(policy)+');\n};\n';}
function checkPolicy(config,s){
  const t=config.tun||{},d=config.dns||{};
  const expected=['NETWORK,udp,REJECT','MATCH,'+s.outbound,'MATCH,REJECT'];
  if(config.mode!=='rule'||config.ipv6!==false||!t.enable||!t['strict-route']||!t['auto-route']||t.device!==s.device||!t['dns-hijack']?.includes('tcp://any:53')||!d.enable||d.ipv6!==false||!d.nameserver?.includes('https://1.1.1.1/dns-query#'+encodeURIComponent(s.outbound))||JSON.stringify(config.rules)!==JSON.stringify(expected))throw new Error('Active configuration does not match the complete egress policy. Apply the prepared configuration and check Clash settings.');
  return {policy:true,device:s.device,mixedPort:config['mixed-port'],ipv6:false,strictRoute:true};
}
function modeChanges(mode){if(!['Live','Protect'].includes(mode))throw new Error('Invalid mode');const enabled=mode==='Protect';return {enabled,changes:enabled?[[['tun','enable'],true],[['tun','strict-route'],true],[['tun','auto-route'],true],[['mode'],'rule'],[['ipv6'],false]]:[[['tun','enable'],false]]};}
module.exports={MARKER,enforcePolicy,parse,update,wrapper,checkPolicy,modeChanges};
