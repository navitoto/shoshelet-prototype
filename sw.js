const CACHE='shoshelet-v26';
const ASSETS=['./phase3.html','./privacy.html','./manifest.webmanifest','./assets/shoshelet-mark.svg','./assets/shoshelet-app-icon-192.png','./assets/shoshelet-app-icon-512.png','./assets/apple-touch-icon.png','./assets/favicon-32.png'];
self.addEventListener('install',e=>e.waitUntil(caches.open(CACHE).then(c=>c.addAll(ASSETS))));
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==CACHE).map(k=>caches.delete(k))))));
self.addEventListener('fetch',e=>{
 if(e.request.method!=='GET')return;
 const url=new URL(e.request.url);
 // Tokens and OAuth codes in URLs are not stored in Cache Storage.
 if(url.origin!==self.location.origin||url.search)return;
 e.respondWith(fetch(e.request).then(r=>{
  if(r.ok){let x=r.clone();caches.open(CACHE).then(c=>c.put(e.request,x))}
  return r
 }).catch(()=>caches.match(e.request)));
});
