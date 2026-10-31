// Synthetic local HTTP fixture only; no provider credentials or real files.
import {createServer} from 'node:http';
import {createHash,randomUUID} from 'node:crypto';
if(process.env.CARRY_ASSET_DOWNLOAD_QA!=='synthetic-only')throw new Error('synthetic_qa_opt_in_required');
const fixtures=new Map(),uuid=/^[0-9a-f-]{36}$/i;
const raw=Buffer.alloc(128*1024,0x57),hash=createHash('sha256').update(raw).digest('hex');
const server=createServer(async(request,response)=>{
  const url=new URL(request.url,'http://127.0.0.1:8893');
  if(request.method==='POST'&&url.pathname==='/__fixture') {
    let bytes='';for await(const chunk of request){bytes+=chunk;if(bytes.length>4096){response.writeHead(413).end();return;}}
    let input;try{input=JSON.parse(bytes);}catch{response.writeHead(400).end();return;}
    if(!uuid.test(input.id)||!['normal','corrupt','overflow','truncated','redirect','expired','slow'].includes(input.mode)){response.writeHead(400).end();return;}
    const fixture={mode:input.mode,accountID:input.accountID??'00000000-0000-0000-0000-000000000001',entityID:input.entityID??randomUUID(),kind:input.kind??'attachment',slot:input.slot??'file',providerVersion:randomUUID()};
    if(!uuid.test(fixture.accountID)||!uuid.test(fixture.entityID)){response.writeHead(400).end();return;}
    fixtures.set(input.id.toLowerCase(),fixture);response.writeHead(201,{'Content-Type':'application/json'}).end(JSON.stringify({sha256:hash,byteCount:raw.length,...fixture}));return;
  }
  if(request.method==='DELETE'&&url.pathname.startsWith('/__fixture/')){fixtures.delete(url.pathname.split('/').pop());response.writeHead(204).end();return;}
  const match=/^\/functions\/v1\/carry-assets\/(download|manifest)\/([0-9a-f-]{36})$/.exec(url.pathname),fixture=match&&fixtures.get(match[2]);
  if(!fixture){response.writeHead(404).end();return;}
  const mode=fixture.mode;
  if(request.headers.authorization!=='Bearer synthetic-download-token'){response.writeHead(401).end();return;}
  if(mode==='redirect'){response.writeHead(302,{Location:'http://127.0.0.1:8893/__trap'}).end();return;}
  if(mode==='expired'){response.writeHead(401).end();return;}
  if(match[1]==='manifest') {
    response.writeHead(200,{'Content-Type':'application/json','Cache-Control':'private, no-store'}).end(JSON.stringify({accountID:fixture.accountID,
      assetID:match[2],entityID:fixture.entityID,kind:fixture.kind,slot:fixture.slot,sha256:hash,byteCount:raw.length,providerVersion:fixture.providerVersion}));return;
  }
  response.writeHead(200,{'Content-Type':'application/octet-stream','Content-Length':String(raw.length),
    'X-Carry-Asset-ID':match[2],'X-Carry-Asset-SHA256':hash,'X-Carry-Asset-Version':fixture.providerVersion});
  if(mode==='slow') {
    let offset=0;const timer=setInterval(()=>{if(offset===raw.length){clearInterval(timer);response.end();return;}
      response.write(raw.subarray(offset,offset+4096));offset+=4096;},20);
    response.on('close',()=>clearInterval(timer));return;
  }
  if(mode==='truncated'){response.write(raw.subarray(0,4096));response.destroy();return;}
  response.end(mode==='corrupt'?Buffer.alloc(raw.length):mode==='overflow'?Buffer.alloc(raw.length+1):raw);
});
server.listen(8893,'127.0.0.1',()=>console.log('synthetic asset download QA listening on 127.0.0.1:8893'));
