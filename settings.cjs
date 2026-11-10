'use strict';
const fs=require('node:fs');
const path=require('node:path');
const net=require('node:net');
const os=require('node:os');
const CONFIG=path.join(__dirname,'config.local.json');
function validate(raw,env=process.env){
  const c={...raw};
  for(const key of ['clashExe','coreExe','outbound','expectedCountry']) if(typeof c[key]!=='string'||!c[key].trim()||c[key].includes('REPLACE_'))throw new Error(`Configure ${key} in config.local.json first.`);
  if(!/^[A-Z]{2}$/.test(c.expectedCountry))throw new Error('expectedCountry must be an uppercase ISO country code.');
  if(/[,\r\n#]/.test(c.outbound)||['DIRECT','REJECT','GLOBAL','DNS','PASS','COMPATIBLE'].includes(c.outbound))throw new Error('Choose an existing non-direct outbound without rule delimiters.');
  if(!/^[A-Za-z0-9_-]{3,32}$/.test(c.tunDevice||''))throw new Error('tunDevice must contain 3-32 ASCII letters, digits, underscores or hyphens.');
  if(!/^[A-Za-z0-9_-]+$/.test(c.serviceName||''))throw new Error('Invalid Windows service name.');
  if(c.expectedIp&&!net.isIP(c.expectedIp))throw new Error('expectedIp must be an IP address or an empty string.');
  if(!c.upstream||typeof c.upstream.host!=='string'||!c.upstream.host||c.upstream.host.includes('REPLACE_')||/[\s/:\\]/.test(c.upstream.host)||!Number.isInteger(c.upstream.port)||c.upstream.port<1||c.upstream.port>65535)throw new Error('Configure the existing proxy transport first-hop hostname and TCP port.');
  if(!Array.isArray(c.bootstrapDns)||!c.bootstrapDns.length||c.bootstrapDns.some(x=>net.isIP(x)!==4))throw new Error('bootstrapDns must be a non-empty array of IPv4 resolver addresses.');
  if(c.appsToCloseBeforeLive===undefined)c.appsToCloseBeforeLive=[];
  if(!Array.isArray(c.appsToCloseBeforeLive)||c.appsToCloseBeforeLive.some(x=>typeof x!=='string'||!/^[A-Za-z0-9_.-]+$/.test(x)||/\.exe$/i.test(x)))throw new Error('appsToCloseBeforeLive must contain plain process names without .exe.');
  const appdata=env.APPDATA||path.join(os.homedir(),'.config');
  const local=env.LOCALAPPDATA||path.join(os.homedir(),'.local','share');
  c.root=path.resolve(c.clashDataDir||path.join(appdata,'io.github.clash-verge-rev.clash-verge-rev'));
  c.state=path.resolve(c.stateDir||path.join(local,'clash-egress-guard','state'));
  const relativeState=path.relative(__dirname,c.state);
  if(!relativeState||(!relativeState.startsWith('..'+path.sep)&&relativeState!=='..'&&!path.isAbsolute(relativeState)))throw new Error('stateDir must be outside the source tree so local backups cannot be published.');
  c.modeState=path.join(c.state,'modes');
  c.app=path.resolve(c.clashExe);c.core=path.resolve(c.coreExe);
  c.device=c.tunDevice;
  c.trustedServiceCoreRoot=path.resolve(path.join(env.ProgramData||'C:/ProgramData','clash-verge-service','cores'));
  return c;
}
function load(){if(!fs.existsSync(CONFIG))throw new Error('Copy config.example.json to config.local.json and edit it before use.');return validate(JSON.parse(fs.readFileSync(CONFIG,'utf8').replace(/^\uFEFF/,'')));}
// Windows PowerShell 5.1 decodes Node's output with the console code page (GBK on Chinese
// Windows) and can break JSON with non-ASCII names, so JSON for PowerShell is ASCII only.
function jsonForPowerShell(value,space){return JSON.stringify(value,null,space).replace(/[\u007f-\uFFFF]/g,c=>'\\u'+c.charCodeAt(0).toString(16).padStart(4,'0'));}
// Same form as WindowsIdentity.Name, which Install.ps1 and Modes.ps1 compare it with. whoami.exe
// prints in the console code page, and in Git Bash `whoami` is a different program.
function currentUser(env=process.env){if(!env.USERDOMAIN)throw new Error('USERDOMAIN is not set; run this from a normal Windows session.');return env.USERDOMAIN+'\\'+os.userInfo().username;}
module.exports={load,validate,CONFIG,jsonForPowerShell,currentUser};
