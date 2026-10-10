/* Shoshelet visual tree view - standalone layout/compute module (stage 1-2, test page only).
   Data shape matches the app tables: people, parents(parent_id,child_id), unions(person_a,person_b,status),
   siblingDeclarations(person_a,person_b,declared_half). No DOM access in compute functions. */
(function(root){
'use strict';
const C={NODE_W:86,NODE_H:98,GAP:12,COUPLE_GAP:22,ROW_GAP:78,COLLAPSE_ABOVE:5,UP:2,DOWN:2,PAD:16};

function makeModel(d){
  const people=d.people||[],parents=d.parents||[],unions=d.unions||[],decl=d.siblingDeclarations||[];
  const byId=new Map(people.map(p=>[p.id,p]));
  const uniq=a=>[...new Set(a)];
  const parentsOf=id=>uniq(parents.filter(e=>e.child_id===id).map(e=>e.parent_id)).filter(x=>byId.has(x));
  const childrenOf=id=>uniq(parents.filter(e=>e.parent_id===id).map(e=>e.child_id)).filter(x=>byId.has(x));
  const unionsOf=id=>unions.filter(u=>u.person_a===id||u.person_b===id);
  // active spouses only: ended and pending unions are hidden from the tree
  const activeSpouses=id=>uniq(unionsOf(id).filter(u=>u.status==='active').map(u=>u.person_a===id?u.person_b:u.person_a)).filter(x=>byId.has(x)&&x!==id);
  const anyUnion=(a,b)=>unions.find(u=>(u.person_a===a&&u.person_b===b)||(u.person_a===b&&u.person_b===a));
  const sharedParents=(a,b)=>{const s=new Set(parentsOf(a));return parentsOf(b).filter(x=>s.has(x)).length};
  // same rule as phase3.html isHalfSibling
  const isHalf=(a,b)=>{if(!sharedParents(a,b))return false;const [pa,pb]=[a,b].sort();const dc=decl.find(x=>x.person_a===pa&&x.person_b===pb);
    return dc?dc.declared_half:(sharedParents(a,b)===1&&parentsOf(a).length>=2&&parentsOf(b).length>=2)};
  const siblings=id=>{const ps=new Set(parentsOf(id));const ids=uniq(parents.filter(e=>ps.has(e.parent_id)&&e.child_id!==id).map(e=>e.child_id)).filter(x=>byId.has(x));
    return{full:ids.filter(x=>!isHalf(id,x)),half:ids.filter(x=>isHalf(id,x))}};
  return{byId,parentsOf,childrenOf,activeSpouses,anyUnion,sharedParents,isHalf,siblings};
}

const unitW=n=>n*C.NODE_W+(n-1)*C.COUPLE_GAP;

/* ---------- layout ---------- */
function layout(model,rootId,opts){
  opts=opts||{};const expanded=opts.expanded||new Set();const UPMAX=C.UP+Math.max(0,opts.extraUp|0),DOWNMAX=C.DOWN+Math.max(0,opts.extraDown|0);let truncUp=false,truncDown=false;
  const M=model,nodes=[],lines=[],hearts=[],groups=[];
  const root=M.byId.get(rootId);if(!root)return null;
  const seen=new Set();
  // --- down subtrees ---
  function downSub(pid,depth,ctxSeen){
    const sp=M.activeSpouses(pid).filter(s=>!ctxSeen.has(s));
    const persons=[pid,...sp];persons.forEach(x=>ctxSeen.add(x));
    const kids=[];const ks=new Set();
    for(const x of persons)for(const k of M.childrenOf(x))if(!ks.has(k)&&!ctxSeen.has(k)){ks.add(k);kids.push(k)}
    const sub={persons,depth,kids:[],collapsed:null,w:unitW(persons.length)};
    if(depth>=DOWNMAX&&kids.length)truncDown=true;
    if(depth<DOWNMAX&&kids.length){
      const key='g'+pid+'@'+depth;
      if(kids.length>C.COLLAPSE_ABOVE&&!expanded.has(key)){
        sub.collapsed={key,count:kids.length,label:kids.length+(depth===0?' ילדים':depth===1?' נכדים':' צאצאים')};
        sub.kidsW=C.NODE_W;
      }else{
        kids.forEach(k=>ctxSeen.add(k));
        sub.kids=kids.map(k=>downSub(k,depth+1,ctxSeen));
        sub.kidsW=sub.kids.reduce((s,k)=>s+k.w,0)+C.GAP*(sub.kids.length-1);
        if(kids.length>C.COLLAPSE_ABOVE)sub.expandedKey=key;
      }
      sub.w=Math.max(sub.w,sub.kidsW);
    }
    return sub;
  }
  const ctxSeen=new Set([rootId]);
  const rootSub=downSub(rootId,0,ctxSeen);
  // --- siblings ---
  const sib=M.siblings(rootId);
  sib.full.forEach(x=>ctxSeen.add(x));sib.half.forEach(x=>ctxSeen.add(x));
  const sibSlots=[...sib.full.map(id=>({id,half:false})),...sib.half.map(id=>({id,half:true}))];
  // gen0 row slots left-to-right: root region, then siblings
  const g0=[...sibSlots.filter(s=>s.half),{type:'root',w:unitW(rootSub.persons.length)},...sibSlots.filter(s=>!s.half)].map(s=>s.type==='root'?s:{type:'sib',id:s.id,half:s.half,sp:M.activeSpouses(s.id).filter(z=>!ctxSeen.has(z)&&!sibSlots.some(q=>q.id===z)),w:0});
  g0.forEach(s=>{if(s.type==='sib'){s.sp.forEach(z=>ctxSeen.add(z));s.w=unitW(1+s.sp.length)}});
  const g0W=g0.reduce((s,x)=>s+x.w,0)+C.GAP*(g0.length-1);
  let x=0;g0.forEach(s=>{s.x=x;x+=s.w+C.GAP});
  const g0Center=g0W/2;
  // --- ancestors (generic depth: up to UPMAX generations above the root) ---
  const ancSeen=new Set([rootId,...ctxSeen]);
  function ancSlot(pid,lvl){ // lvl = generation above root of pid (1 = parent)
    let ps=M.parentsOf(pid).filter(x=>!ancSeen.has(x)).slice(0,4);
    if(!ps.length)return{pid,lvl,ps:[],slotW:C.NODE_W};
    if(lvl>=UPMAX){truncUp=true;return{pid,lvl,ps:[],slotW:C.NODE_W}}
    ps.forEach(x=>ancSeen.add(x));
    const subs=ps.map(x=>ancSlot(x,lvl+1));
    const w=subs.reduce((t,q)=>t+q.slotW,0)+C.COUPLE_GAP*(subs.length-1);
    return{pid,lvl,ps:subs,slotW:Math.max(C.NODE_W,w),unitW:w};
  }
  const pids0=M.parentsOf(rootId).filter(x=>!ancSeen.has(x)).slice(0,UPMAX===0?0:4);
  pids0.forEach(x=>ancSeen.add(x));
  const par=pids0.map(pid=>ancSlot(pid,1));
  const parW=par.reduce((s,p)=>s+p.slotW,0)+C.GAP*Math.max(0,par.length-1);
  let px=g0Center-parW/2;par.forEach(p=>{p.x=px;p.cx=px+p.slotW/2;px+=p.slotW+C.GAP});
  const pids=pids0;
  let maxLvl=par.length?1:0;(function walk(q){q.forEach(x=>{maxLvl=Math.max(maxLvl,x.lvl);walk(x.ps)})})(par);
  const minGen=-maxLvl;
  const rowY=g=>C.PAD+(g-minGen)*(C.NODE_H+C.ROW_GAP);
  const addNode=(id,cx,gen,extra)=>{const n=Object.assign({id,x:cx-C.NODE_W/2,y:rowY(gen),w:C.NODE_W,h:C.NODE_H,gen},extra||{});nodes.push(n);return n};
  const curve=(sx,sy,tx,ty)=>lines.push({curve:true,pts:[[sx,sy],[tx,ty]]});const bot=n=>[n.x+n.w/2,n.y+n.h];
  const couple=(ns,ended)=>{for(let i=0;i<ns.length-1;i++){const a=ns[i],b=ns[i+1],y=a.y+a.h/2;lines.push({pts:[[a.x+a.w,y],[b.x,y]],dashed:!!ended});if(!ended)hearts.push({x:(a.x+a.w+b.x)/2,y})}};
  const unitCenterOf=ns=>(ns[0].x+ns[ns.length-1].x+ns[ns.length-1].w)/2;
  // place ancestors
  const parentNodes=new Map();const ancTags=[];
  function placeAnc(q,cx){
    const n=addNode(q.pid,cx,-q.lvl,{ancestor:true});parentNodes.set(q.pid,n);
    if(q.ps.length){let gx=cx-q.unitW/2;const gn=q.ps.map(sub=>{const c=gx+sub.slotW/2;gx+=sub.slotW+C.COUPLE_GAP;return placeAnc(sub,c)});
      couple(gn,gn.length===2&&!M.activeSpouses(gn[0].id).includes(gn[1].id));
      gn.forEach(g2=>{const b=bot(g2);curve(b[0],b[1],cx,n.y)});ancTags.push({pid:q.pid,node:n})}
    return n;
  }
  par.forEach(p=>placeAnc(p,p.cx));
  // couple lines between adjacent parents that have a union (ended -> dashed, no heart)
  for(let i=0;i<par.length-1;i++){const u=M.anyUnion(par[i].pid,par[i+1].pid);if(u){const a=parentNodes.get(par[i].pid),b=parentNodes.get(par[i+1].pid);couple([a,b],u.status!=='active')}}
  // parent source point for a child with given parent set
  const srcFor=(parentSet)=>parentSet.map(id=>parentNodes.get(id)).filter(Boolean).map(bot);
  const midG0=rowY(0)-C.ROW_GAP/2;
  // --- gen0 placement ---
  const rootSlot=g0.find(s=>s.type==='root');
  const rootCx=rootSlot.x+rootSlot.w/2;
  function placeDown(sub,left,gen,srcPts){
    // centered unit over region [left,left+sub.w]
    const cx=left+sub.w/2;const ns=sub.persons.map((id,i)=>addNode(id,cx-unitW(sub.persons.length)/2+C.NODE_W/2+i*(C.NODE_W+C.COUPLE_GAP),gen,{isRoot:id===rootId&&gen===0,spouse:i>0}));
    couple(ns,false);
    const uc=unitCenterOf(ns);
    if(srcPts)srcPts.forEach(p=>curve(p[0],p[1],ns[0].x+ns[0].w/2,ns[0].y));
    if(sub.collapsed){const cy=rowY(gen+1);const g={key:sub.collapsed.key,x:cx-C.NODE_W/2,y:cy,w:C.NODE_W,h:C.NODE_H,label:sub.collapsed.label,gen:gen+1};groups.push(g);
      ns.forEach(pn=>{const b=bot(pn);curve(b[0],b[1],cx,cy)})}
    else if(sub.kids.length){let kx=left+(sub.w-sub.kidsW)/2;
      for(const k of sub.kids){placeDown(k,kx,gen+1,ns.filter(pn=>M.parentsOf(k.persons[0]).includes(pn.id)).map(bot));kx+=k.w+C.GAP}}
    return ns;
  }
  // root
  placeDown(rootSub,rootCx-rootSub.w/2,0,null);
  if(rootSub.expandedKey)groups.push({key:rootSub.expandedKey,collapse:true,x:rootCx-C.NODE_W/2,y:rowY(1)-C.NODE_H*0.0,w:0,h:0,hidden:true});
  // root to parents link
  const rootParentSrc=srcFor(pids);
  const rootNode=nodes.find(n=>n.id===rootId&&n.gen===0);
  rootParentSrc.forEach(p=>curve(p[0],p[1],rootNode.x+rootNode.w/2,rootNode.y));
  // siblings
  g0.filter(s=>s.type==='sib').forEach(s=>{const n=addNode(s.id,s.x+C.NODE_W/2,0,{sibling:true,half:s.half});
    const spn=s.sp.map((z,i)=>addNode(z,s.x+C.NODE_W/2+(i+1)*(C.NODE_W+C.COUPLE_GAP),0,{sibSpouse:true,spouse:true}));couple([n,...spn],false);
    const shared=M.parentsOf(s.id).filter(pp=>pids.includes(pp));
    srcFor(s.half?shared:pids).forEach(p=>curve(p[0],p[1],n.x+n.w/2,n.y));
    if(s.half){const g=M.byId.get(s.id).gender;n.label=g==='female'?'אחות למחצה':g==='male'?'אח למחצה':'אח/ות למחצה'}});
  // "ההורים של X" tags on the connector gap above each parent unit
  const tags=[];const nm=id=>M.byId.get(id).full_name;
  if(par.length){const f=parentNodes.get(par[0].pid),l=parentNodes.get(par[par.length-1].pid);tags.push({x:(f.x+l.x+l.w)/2,y:f.y+f.h+C.ROW_GAP*0.5,text:'ההורים של '+nm(rootId)})}
  ancTags.forEach(t=>{const n=t.node;tags.push({x:n.x+n.w/2,y:n.y-C.ROW_GAP*0.5,text:'ההורים של '+nm(t.pid)})});
  // bounds
  let minX=Infinity,maxX=-Infinity,maxY=0;
  nodes.concat(groups.filter(g=>!g.hidden)).forEach(n=>{minX=Math.min(minX,n.x);maxX=Math.max(maxX,n.x+n.w);maxY=Math.max(maxY,n.y+n.h)});
  const shift=C.PAD-minX,W=maxX-minX+2*C.PAD,H=maxY+C.PAD;
  nodes.forEach(n=>n.x+=shift);tags.forEach(t=>t.x+=shift);groups.forEach(n=>n.x+=shift);hearts.forEach(h=>h.x+=shift);lines.forEach(l=>l.pts.forEach(p=>p[0]+=shift));
  // validity metrics
  const issues=[];
  const rows={};nodes.forEach(n=>(rows[n.gen]=rows[n.gen]||[]).push(n));
  for(const g in rows){const r=rows[g].slice().sort((a,b)=>a.x-b.x);for(let i=1;i<r.length;i++)if(r[i].x<r[i-1].x+r[i-1].w-0.5)issues.push('overlap gen '+g+': '+r[i-1].id+' / '+r[i].id)}
  const ids=nodes.map(n=>n.id);if(new Set(ids).size!==ids.length)issues.push('duplicate person node');
  return{W,H,nodes,tags,lines,hearts,groups:groups.filter(g=>!g.hidden),rootId,issues,moreUp:truncUp,moreDown:truncDown,collapsibleKeys:rootSub.expandedKey?[rootSub.expandedKey]:[]};
}

/* ---------- render (DOM) ---------- */
function esc(v){return String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
function nameColor(n){let h=0;for(const c of n||'')h=(Math.imul(h,31)+c.charCodeAt(0))>>>0;return['#D6E6DC','#EADFD0','#DDE3EA','#E8DCE6'][h%4]}
function initials(n){const a=String(n||'').trim().split(/\s+/);return(a[0]?.[0]||'ש')+(a.length>1?a.at(-1)[0]:'')}

function rounded(q,r){
  if(q.length<3)return 'M'+q.map(p=>p[0]+','+p[1]).join(' L');
  let d='M'+q[0][0]+','+q[0][1];
  for(let i=1;i<q.length-1;i++){const a=q[i-1],b=q[i],c=q[i+1];
    const l1=Math.hypot(b[0]-a[0],b[1]-a[1]),l2=Math.hypot(c[0]-b[0],c[1]-b[1]);
    if(!l1||!l2){continue}
    if(Math.abs(b[0]-a[0])<0.5&&Math.abs(c[0]-b[0])<0.5||Math.abs(b[1]-a[1])<0.5&&Math.abs(c[1]-b[1])<0.5){d+=' L'+b[0]+','+b[1];continue}
    const k=Math.min(r,l1/2,l2/2);
    const p1=[b[0]+(a[0]-b[0])/l1*k,b[1]+(a[1]-b[1])/l1*k],p2=[b[0]+(c[0]-b[0])/l2*k,b[1]+(c[1]-b[1])/l2*k];
    d+=' L'+p1[0]+','+p1[1]+' Q'+b[0]+','+b[1]+' '+p2[0]+','+p2[1]}
  const e=q[q.length-1];return d+' L'+e[0]+','+e[1]}
function html(model,L){
  // mirror x for RTL: canvas is LTR, mirrored so the first generation sits at the right edge
  const mx=(x,w)=>L.W-x-(w||0);
  const svg=L.lines.map(l=>{const q=l.pts.map(p=>[mx(p[0]),p[1]]);const d=l.curve?`M${q[0][0]},${q[0][1]} C${q[0][0]},${q[0][1]+(q[1][1]-q[0][1])*0.3} ${q[1][0]},${q[1][1]-(q[1][1]-q[0][1])*0.7} ${q[1][0]},${q[1][1]}`:rounded(q,16);return`<path class="tv-line${l.dashed?' dashed':''}" d="${d}"/>`}).join('')
    +L.hearts.map(h=>`<text class="tv-heart" x="${mx(h.x)}" y="${h.y+4}" text-anchor="middle">♥</text>`).join('');
  const nd=L.nodes.map(n=>{const p=model.byId.get(n.id);return`<button type="button" class="tv-node${n.isRoot?' root':''}${n.spouse?' sp':''}${n.ancestor?' anc':''}" data-tv-person="${esc(n.id)}" style="left:${mx(n.x,n.w)}px;top:${n.y}px;width:${n.w}px;height:${n.h}px"><span class="tv-av" style="background:${nameColor(p.full_name)}">${esc(initials(p.full_name))}</span><span class="tv-name"><b>${esc(p.full_name)}</b>${n.label?`<small>${esc(n.label)}</small>`:''}</span></button>`}).join('');
  const gr=L.groups.map(g=>`<button type="button" class="tv-node tv-group" data-tv-group="${esc(g.key)}" style="left:${mx(g.x,g.w)}px;top:${g.y}px;width:${g.w}px;height:${g.h}px"><b>${esc(g.label)}</b><small>הקישו לפתיחה</small></button>`).join('');
  const tg=(L.tags||[]).map(t=>`<div class="tv-tag" style="left:${mx(t.x)}px;top:${t.y}px">${esc(t.text)}</div>`).join('');
  return`<div class="tv-canvas" style="width:${L.W}px;height:${L.H}px"><svg width="${L.W}" height="${L.H}" aria-hidden="true">${svg}</svg>${tg}${nd}${gr}</div>`;
}

const CSS=`.tv-tag{position:absolute;transform:translate(-50%,-50%);white-space:nowrap;background:#F7F4EB;color:#6b7d73;font-size:10px;font-weight:700;padding:1px 7px;border-radius:9px;z-index:1;direction:rtl}
.tv-wrap{position:relative;direction:rtl;font-family:Arial,"Noto Sans Hebrew",sans-serif;color:#0C3B2E}
.tv-scroll{direction:rtl;overflow-x:auto;overflow-y:hidden;-webkit-overflow-scrolling:touch;background:#F7F4EB;border:1px solid #e1ddcf;border-radius:14px;padding:6px 0}
.tv-canvas{position:relative;direction:ltr}.tv-canvas svg{position:absolute;left:0;top:0}
.tv-line{fill:none;stroke:#C9A227;stroke-width:1.7;opacity:.95;stroke-linecap:round;stroke-linejoin:round}.tv-line.dashed{stroke-dasharray:4 4;opacity:.7}.tv-heart{fill:#C9A227;font-size:12px}
.tv-node{box-sizing:border-box;position:absolute;display:flex;flex-direction:column;align-items:center;justify-content:flex-start;gap:5px;direction:rtl;background:#fffdfa;border:1px solid #e3dfd0;border-radius:14px;padding:10px 5px 6px;font:inherit;text-align:center;cursor:pointer;color:#0C3B2E;box-shadow:0 2px 6px #0c3b2e14}
.tv-node.sp{border-style:dashed;background:#f6f3e8;box-shadow:none;transform:scale(.88)}
.tv-node.root{border:1px solid #0C5A44;background:#0C5A44;color:#F7F4EB}.tv-node.root .tv-name small{color:#cfe3d8}
.tv-av{flex:none;width:36px;height:36px;border-radius:50%;color:#0C5A44;display:flex;align-items:center;justify-content:center;font-size:15px;font-weight:800}
.tv-node.root .tv-av{background:#ffffff2e!important;color:#F7F4EB}
.tv-name{display:flex;flex-direction:column;min-width:0;width:100%;line-height:1.15;align-items:center}.tv-name b{font-size:11.5px;display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden;word-break:break-word}.tv-name small{font-size:10px;color:#78867f;margin-top:2px}
.tv-group{justify-content:center;gap:2px;background:#f1ecdc;border-style:dashed}.tv-group b{font-size:13px}.tv-group small{font-size:10px;color:#78867f}
.tv-gen{display:flex;justify-content:center;margin:8px 0}.tv-gen button{min-height:38px;padding:0 18px;border:1px solid #085E45;background:#fffdfa;color:#085E45;border-radius:12px;font:inherit;font-weight:800;font-size:14px}.tv-gen button[hidden]{display:none}
.tv-btns{display:flex;justify-content:space-between;gap:10px;margin:10px 0}.tv-btns button{flex:1;min-height:40px;border:1px solid #085E45;background:#fffdfa;color:#085E45;border-radius:12px;font:inherit;font-weight:800;font-size:14px}.tv-btns button:disabled{opacity:.35}`;

function mount(el,model,rootId,opts){
  opts=opts||{};const expanded=new Set();let last;const ex={up:Math.max(0,Math.min(8,+(opts.extra&&opts.extra.up)|0)),down:Math.max(0,Math.min(8,+(opts.extra&&opts.extra.down)|0))};
  if(!document.getElementById('tv-css')){const s=document.createElement('style');s.id='tv-css';s.textContent=CSS;document.head.appendChild(s)}
  el.innerHTML='<div class="tv-wrap"><div class="tv-gen"><button type="button" data-tv-gen="up">עוד דור ↑</button></div><div class="tv-scroll"></div><div class="tv-gen"><button type="button" data-tv-gen="down">עוד דור ↓</button></div><div class="tv-btns"><button type="button" data-tv-dir="back">חזרה</button><button type="button" data-tv-dir="more">המשך העץ</button></div></div>';
  const sc=el.querySelector('.tv-scroll');
  function paint(keepScroll){
    const prev=sc.scrollLeft;last=layout(model,rootId,{expanded,extraUp:ex.up,extraDown:ex.down});sc.innerHTML=html(model,last);
    sc.querySelectorAll('[data-tv-group]').forEach(b=>b.onclick=()=>{expanded.add(b.dataset.tvGroup);paint(true)});
    sc.querySelectorAll('[data-tv-person]').forEach(b=>b.onclick=()=>opts.onPerson&&opts.onPerson(b.dataset.tvPerson));
    if(keepScroll)sc.scrollLeft=prev;else{const r=sc.querySelector('.root');if(r){const max=sc.scrollWidth-sc.clientWidth,c=r.offsetLeft+r.offsetWidth/2;sc.scrollLeft=Math.min(0,Math.max(-max,Math.min(max,Math.max(0,c-sc.clientWidth/2))-max))}}
    el.querySelector('[data-tv-gen=up]').hidden=!last.moreUp;el.querySelector('[data-tv-gen=down]').hidden=!last.moreDown;
    upd();
  }
  function grow(dir){
    const r0=sc.querySelector('.root'),b0=r0&&r0.getBoundingClientRect();
    if(dir==='up')ex.up++;else ex.down++;
    paint(true);
    const r1=sc.querySelector('.root');
    if(b0&&r1){const b1=r1.getBoundingClientRect();try{window.scrollBy(0,b1.top-b0.top);sc.scrollLeft+=b1.left-b0.left}catch(e){}}
    upd();if(opts.onExtra)try{opts.onExtra({up:ex.up,down:ex.down})}catch(e){}
  }
  el.querySelectorAll('[data-tv-gen]').forEach(b=>b.onclick=()=>grow(b.dataset.tvGen));
  const upd=()=>{const max=sc.scrollWidth-sc.clientWidth,pos=Math.abs(sc.scrollLeft);el.querySelector('[data-tv-dir=more]').disabled=max<=2||pos>=max-2;el.querySelector('[data-tv-dir=back]').disabled=max<=2||pos<=2};
  sc.addEventListener('scroll',upd);
  el.querySelector('[data-tv-dir=more]').onclick=()=>sc.scrollBy({left:-sc.clientWidth*0.7,behavior:'smooth'});
  el.querySelector('[data-tv-dir=back]').onclick=()=>sc.scrollBy({left:sc.clientWidth*0.7,behavior:'smooth'});
  paint(false);return{get layout(){return last},repaint:paint,expanded,extra:ex};
}

const api={C,makeModel,layout,html,mount};
if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.ShosheletTreeView=api;
})(typeof window!=='undefined'?window:globalThis);
