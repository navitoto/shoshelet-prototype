/* Shoshelet: PDF of one person's tree, exactly as configured on screen (root, extra generations, chips, expanded groups).
   Pipeline matches the family poster: SVG -> canvas -> PNG -> jsPDF. The drawing comes from tree-view.js svg().
   Names only, like the family export: no photos, no phones, no emails, no dates. */
(function(root){
'use strict';
const HDR=64,MAX_AREA=12e6,MAX_R=4,PAGE_W=594,MIN_W=210,MAX_MM_PER_PX=0.423;
function esc(v){return String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
function compose(model,L,rootName){
  const T=root.ShosheletTreeView,FONT='font-family="Arial, \'Noto Sans Hebrew\', Helvetica, sans-serif"';
  const people=L.nodes.length,ns=String(people),nw=ns.length*8,hw=38,gap=8;
  /* Visual order left to right: שושלת, dot, אנשים, N (reads right to left as "N אנשים · שושלת"). Separate text
     elements anchored at their right edge, so no bidi reordering can mix the pieces. */
  const x0=24,eShosh=x0+hw,eDot=eShosh+gap+4,eWord=eDot+gap+hw,eN=eWord+gap+nw;
  const hd=(x,t)=>`<text x="${x}" y="38" text-anchor="end" ${FONT} font-size="14" fill="#0C5A44">${t}</text>`;
  const head=`<rect width="${L.W}" height="${HDR}" fill="#F7F2E8"/><rect y="${HDR-2}" width="${L.W}" height="2" fill="#BA9132"/>`
   +`<text x="${L.W-24}" y="40" text-anchor="end" ${FONT} font-size="26" font-weight="800" fill="#0C5A44">${esc('העץ של '+rootName)}</text>`
   +hd(eN,ns)+hd(eWord,'אנשים')+hd(eDot,'·')+hd(eShosh,'שושלת');
  const H=L.H+HDR;
  const svg=`<svg xmlns="http://www.w3.org/2000/svg" width="${L.W}" height="${H}" viewBox="0 0 ${L.W} ${H}"><rect width="100%" height="100%" fill="#fff"/>${head}<g transform="translate(0 ${HDR})">${T.svg(model,L)}</g></svg>`;
  return {svg,W:L.W,H,people};
}
function rasterize(svg,W,H,r){
  return new Promise((resolve,reject)=>{
    const img=new Image();
    img.onload=()=>{try{const c=document.createElement('canvas');c.width=Math.max(1,Math.round(W*r));c.height=Math.max(1,Math.round(H*r));const x=c.getContext('2d');if(!x)throw new Error('canvas');x.fillStyle='#fff';x.fillRect(0,0,c.width,c.height);x.drawImage(img,0,0,c.width,c.height);const url=c.toDataURL('image/png');if(!url||url.length<100)throw new Error('empty canvas');resolve({url,w:c.width,h:c.height})}catch(e){reject(e)}};
    img.onerror=()=>reject(new Error('svg image'));
    img.src='data:image/svg+xml;charset=utf-8,'+encodeURIComponent(svg);
  });
}
async function build(data){
  const T=root.ShosheletTreeView;
  if(!T||!T.svg)throw new Error('tree view unavailable');
  if(!root.jspdf?.jsPDF)throw new Error('pdf library unavailable');
  const model=T.makeModel({people:data.people,parents:data.parents,unions:data.unions,siblingDeclarations:data.siblingDeclarations||[]});
  const rootPerson=model.byId.get(data.rootId);
  if(!rootPerson)throw new Error('person missing');
  const o=data.options||{};
  const L=T.layout(model,data.rootId,{extraUp:o.extraUp|0,extraDown:o.extraDown|0,unclesOpen:o.unclesOpen===true,nephewsOpen:o.nephewsOpen===true,cousinsOpen:o.cousinsOpen===true,expanded:new Set(o.expanded||[])});
  const c=compose(model,L,rootPerson.full_name);
  let r=Math.min(MAX_R,Math.sqrt(MAX_AREA/(c.W*c.H))),img=null,lastErr=null;
  for(let attempt=0;attempt<3&&!img;attempt++){try{img=await rasterize(c.svg,c.W,c.H,r)}catch(e){lastErr=e;r=r*0.7}}
  if(!img)throw lastErr||new Error('raster failed');
  const s=Math.min(PAGE_W/c.W,MAX_MM_PER_PX),imgW=c.W*s,imgH=c.H*s,pageW=Math.max(MIN_W,imgW),pageH=Math.ceil(imgH);
  const pdf=new root.jspdf.jsPDF({orientation:pageW>=pageH?'landscape':'portrait',unit:'mm',format:[pageW,pageH]});
  pdf.addImage(img.url,'PNG',(pageW-imgW)/2,0,imgW,imgH,undefined,'FAST');
  return {pdf,meta:{people:c.people,cssWidth:c.W,cssHeight:c.H,canvasWidth:img.w,canvasHeight:img.h,pageMm:[pageW,pageH],ppi:Math.round(img.w/(imgW/25.4))}};
}
root.ShPersonTreeExport={build,compose};
})(typeof window!=='undefined'?window:globalThis);
