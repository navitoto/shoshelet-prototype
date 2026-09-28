/* Print-only family tree export. All source records are provided by the signed-in app.
   This module neither fetches nor mutates family data. */
(function(){
const W=420,H=297,PAD=13,GAP=5,CELL=19,MAX_COLS=11,MAX_ROWS=12;
function safe(s){return String(s??'').replace(/[&<>"']/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]))}
function makeModel(data){let people=(data.people||[]).filter(x=>x&&x.id).map(p=>({id:String(p.id),name:String(p.full_name||'ללא שם')}));let byId=new Map(people.map(p=>[p.id,p]));let edges=new Map();for(let e of data.parents||[]){if(!byId.has(String(e.parent_id))||!byId.has(String(e.child_id))||String(e.parent_id)===String(e.child_id))continue;edges.set(e.parent_id+'|'+e.child_id,{from:String(e.parent_id),to:String(e.child_id)})}let couples=new Map();for(let u of data.unions||[]){let a=String(u.person_a),b=String(u.person_b);if(!byId.has(a)||!byId.has(b)||a===b)continue;let k=[a,b].sort().join('|');couples.set(k,{a,b,status:u.status==='ended'?'ended':'active'})}return {people,byId,edges:[...edges.values()],couples:[...couples.values()]}}
function components(model){let adjacency=new Map(model.people.map(x=>[x.id,new Set()]));for(let e of model.edges){adjacency.get(e.from).add(e.to);adjacency.get(e.to).add(e.from)}for(let c of model.couples){adjacency.get(c.a).add(c.b);adjacency.get(c.b).add(c.a)}let seen=new Set(),out=[];for(let p of model.people){if(seen.has(p.id))continue;let q=[p.id],ids=[];seen.add(p.id);while(q.length){let id=q.shift();ids.push(id);for(let next of adjacency.get(id))if(!seen.has(next)){seen.add(next);q.push(next)}}out.push(ids)}return out.sort((a,b)=>b.length-a.length)}
function layout(model){
  const pages=[];
  for(const [branch,ids] of components(model).entries()){
    const set=new Set(ids),families=new Map();
    for(const child of ids){const ps=model.edges.filter(e=>e.to===child&&set.has(e.from)).map(e=>e.from).sort();if(!ps.length)continue;
      const key=ps.join('|'),f=families.get(key)||{parents:ps,children:[]};f.children.push(child);families.set(key,f)}
    const units=[];
    for(const f of families.values())units.push({...f,couples:model.couples.filter(c=>f.parents.includes(c.a)&&f.parents.includes(c.b))});
    for(const c of model.couples.filter(c=>set.has(c.a)&&set.has(c.b)))if(!units.some(u=>u.couples.includes(c)))units.push({parents:[c.a,c.b],children:[],couples:[c]});
    for(const id of ids)if(!units.some(u=>[...u.parents,...u.children].includes(id)))units.push({parents:[id],children:[],couples:[]});
    units.sort((a,b)=>a.parents.map(x=>model.byId.get(x).name).join(' ').localeCompare(b.parents.map(x=>model.byId.get(x).name).join(' '),'he'));
    const expanded=[];for(const u of units){if(u.children.length<=7){expanded.push(u);continue}for(let k=0;k<u.children.length;k+=7)expanded.push({...u,children:u.children.slice(k,k+7),couples:k===0?u.couples:[]})}
    let page={branch:branch+1,part:1,nodes:[],edges:[],couples:[],panels:[]},y=41;
    const flush=()=>{if(page.panels.length)pages.push(page);page={branch:branch+1,part:page.part+1,nodes:[],edges:[],couples:[],panels:[]};y=41};
    for(const [i,u] of expanded.entries()){
      const rows=Math.max(1,Math.ceil(u.children.length/7)),h=49+(rows-1)*17;
      if(y+h>265 && page.panels.length)flush();
      const p={number:i+1,y,h,nodes:[],edges:[],couples:u.couples,parents:u.parents,children:u.children};
      let w=Math.min(53,(W-2*PAD-16)/u.parents.length),step=w+8,x0=(W-u.parents.length*step+8)/2;
      u.parents.forEach((id,j)=>p.nodes.push({id,x:x0+j*step,y:y+6,w,h:12}));
      for(let r=0;r<rows;r++){let group=u.children.slice(r*7,(r+1)*7),cw=Math.min(49,(W-2*PAD-20)/Math.max(1,group.length)),cs=cw+5,cx=(W-group.length*cs+5)/2;
        group.forEach((id,j)=>p.nodes.push({id,x:cx+j*cs,y:y+30+r*17,w:cw,h:12}))}
      const parentSet=new Set(u.parents),childSet=new Set(u.children);p.edges=model.edges.filter(e=>parentSet.has(e.from)&&childSet.has(e.to));
      page.panels.push(p);page.nodes.push(...p.nodes);page.edges.push(...p.edges);page.couples.push(...p.couples);y+=h+4;
    }
    flush();
  }
  return pages;
}
function svg(model,page,index,count){
 const tag=id=>String(model.people.findIndex(p=>p.id===id)+1).padStart(3,'0'),groups=[];
 for(const p of page.panels){
   let paths=[],loc=id=>p.nodes.find(n=>n.id===id);
   for(const c of p.couples){const a=loc(c.a),b=loc(c.b);if(!a||!b)continue;let left=a.x<b.x?a:b,right=left===a?b:a,yy=left.y+left.h/2;
     paths.push(`<path d="M${left.x+left.w} ${yy}H${right.x}" stroke="#b78a28" stroke-width=".8" ${c.status==='ended'?'stroke-dasharray="2 1.5"':''}/>`);
     if(c.status==='ended')paths.push(`<text x="${(left.x+left.w+right.x)/2}" y="${yy-2}" text-anchor="middle" font-size="2.7" fill="#85621b">לשעבר</text>`)}
   for(const e of p.edges){const a=loc(e.from),b=loc(e.to);if(!a||!b)continue;let x=a.x+a.w/2,xx=b.x+b.w/2,yy=a.y+a.h,by=b.y,mid=Math.min(by-2,yy+7);
      paths.push(`<path d="M${x} ${yy}V${mid}H${xx}V${by}" stroke="#438764" stroke-width=".48" fill="none"/>`)}
   let cards=p.nodes.map(n=>`<g><rect x="${n.x}" y="${n.y}" width="${n.w}" height="${n.h}" rx="2" fill="#fffdfa" stroke="#9dbda7" stroke-width=".45"/><foreignObject x="${n.x+1}" y="${n.y+1}" width="${n.w-2}" height="${n.h-2}"><div xmlns="http://www.w3.org/1999/xhtml" dir="rtl" style="height:100%;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;color:#163b2b;font:700 5px Arial,sans-serif;line-height:1.1;overflow:hidden;overflow-wrap:anywhere"><span>${safe(model.byId.get(n.id).name)}</span><span style="font:3px Arial,sans-serif;color:#778d7c">#${tag(n.id)}</span></div></foreignObject></g>`).join('');
   groups.push(`<g><rect x="17" y="${p.y}" width="386" height="${p.h}" rx="3" fill="#fbfcf8" stroke="#ceded0" stroke-width=".5"/><text x="397" y="${p.y+5}" text-anchor="end" font-family="Arial" font-size="3.5" fill="#527460">יחידה ${p.number}</text>${paths.join('')}${cards}</g>`)
 }
 let header=`ענף ${page.branch}, חלק ${page.part} · עמוד ${index+1} מתוך ${count} · ${model.people.length} אנשים`;
 return `<svg xmlns="http://www.w3.org/2000/svg" width="420mm" height="297mm" viewBox="0 0 420 297"><rect width="420" height="297" fill="#f8f6ef"/><text x="407" y="19" text-anchor="end" font-family="Arial" font-size="8" font-weight="700" fill="#0c3b2e">שושלת · עץ המשפחה המלא</text><path d="M13 25H407" stroke="#c9a227" stroke-width=".6"/><text x="407" y="34" text-anchor="end" font-family="Arial" font-size="4" fill="#527460">${header}</text>${groups.join('')}<path d="M13 271H407" stroke="#c9a227" stroke-width=".4"/><text x="407" y="279" text-anchor="end" font-family="Arial" font-size="3.8" fill="#496953">ירוק: הורה-ילד · זהב: זוגיות · זהב מקווקו: לשעבר</text><text x="407" y="286" text-anchor="end" font-family="Arial" font-size="3.4" fill="#567063">כל מסגרת היא יחידה משפחתית · מספר # זהה מציין אותו אדם גם בדפי המשך.</text></svg>`;
}
async function build(data){let model=makeModel(data),pages=layout(model);if(!pages.length)throw Error('אין אנשים להדפסה');let {jsPDF}=window.jspdf||{};if(!jsPDF)throw Error('מנוע PDF לא זמין');let pdf=new jsPDF({orientation:'landscape',unit:'mm',format:'a3',compress:true});let preview=[];for(let i=0;i<pages.length;i++){if(i)pdf.addPage('a3','landscape');let xml=svg(model,pages[i],i,pages.length),url='data:image/svg+xml;charset=utf-8,'+encodeURIComponent(xml),img=new Image();img.src=url;await img.decode();let canvas=document.createElement('canvas');canvas.width=3508;canvas.height=2480;let ctx=canvas.getContext('2d');ctx.fillStyle='#f8f6ef';ctx.fillRect(0,0,canvas.width,canvas.height);ctx.drawImage(img,0,0,canvas.width,canvas.height);let png=canvas.toDataURL('image/png');pdf.addImage(png,'PNG',0,0,W,H);preview.push({branch:pages[i].branch,part:pages[i].part,people:pages[i].nodes.map(n=>n.id),parentEdges:pages[i].edges.length,couples:pages[i].couples.length})}return {pdf,preview,model}}
window.ShTreeExport={build,makeModel,layout};
})();
