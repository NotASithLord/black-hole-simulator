import http from 'node:http';
import {createReadStream} from 'node:fs';
import {stat, writeFile, mkdir} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {randomUUID} from 'node:crypto';
import {reportIdentity} from './report-utils.mjs';

const repo=fileURLToPath(new URL('../..',import.meta.url));
const root=path.join(repo,'outputs/BlackHoleBrowser');
const port=Number(process.env.PORT||8765);
const mime={'.html':'text/html; charset=utf-8','.js':'text/javascript; charset=utf-8','.css':'text/css; charset=utf-8','.wasm':'application/wasm','.wgsl':'text/plain; charset=utf-8','.json':'application/json','.md':'text/plain; charset=utf-8'};
http.createServer(async(req,res)=>{
  res.setHeader('Cache-Control','no-store');
  res.setHeader('X-Content-Type-Options','nosniff');
  try {
    const url=new URL(req.url,'http://localhost');
    if(req.method==='POST'&&url.pathname==='/__report') {
      // Local-only, bounded verification receipt. No arbitrary file paths.
      let body=''; for await (const chunk of req) { body+=chunk; if(body.length>2_000_000) throw Error('Report too large'); }
      const value=JSON.parse(body);
      await mkdir(path.join(repo,'outputs'),{recursive:true});
      const encoded=JSON.stringify(value,null,2)+'\n';
      const identity=reportIdentity(value,new Date().toISOString().replace(/[:.]/g,'-'),randomUUID());
      const archive=path.join(repo,'outputs/browser-reports',identity.engine);
      await mkdir(archive,{recursive:true});
      await writeFile(path.join(archive,identity.filename),encoded,{flag:'wx'});
      await writeFile(path.join(repo,'outputs/browser-verification.json'),encoded);
      console.log(`Browser verification: ${value.status||value.phase||'update'} ${value.error||''}`);
      res.writeHead(200,{'Content-Type':'application/json'});res.end('{"ok":true}');return;
    }
    if(req.method!=='GET'&&req.method!=='HEAD') {res.writeHead(405);res.end();return;}
    const pathname=decodeURIComponent(url.pathname);
    const target=path.resolve(root,'.'+(pathname==='/'?'/index.html':pathname));
    if(!target.startsWith(root+path.sep)) {res.writeHead(403);res.end();return;}
    const info=await stat(target); if(!info.isFile()) throw Error('Not a file');
    res.writeHead(200,{'Content-Type':mime[path.extname(target)]||'application/octet-stream','Content-Length':info.size});
    if(req.method==='HEAD') res.end(); else createReadStream(target).pipe(res);
  } catch(error) {res.writeHead(404,{'Content-Type':'text/plain'});res.end('Not found');}
}).listen(port,'127.0.0.1',()=>console.log(`Black Hole WebGPU: http://127.0.0.1:${port} (local only)`));
