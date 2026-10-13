/* «Вдвоём» — фоновый помощник: показывает уведомление «напарник зовёт» и по нажатию открывает приложение */
self.addEventListener('install',()=>self.skipWaiting());
self.addEventListener('activate',e=>e.waitUntil(self.clients.claim()));
self.addEventListener('push',e=>{let d={};try{d=e.data.json()}catch(_){d={body:e.data&&e.data.text()}}
  e.waitUntil(self.registration.showNotification(d.title||'Смотрим вдвоём',{body:d.body||'Напарник зовёт смотреть вместе',
    tag:'ring-'+(d.code||''),renotify:true,icon:'icon.png',badge:'icon.png',data:{code:d.code||'',t:Date.now()}}))});
self.addEventListener('notificationclick',e=>{e.notification.close();const dd=e.notification.data||{},code=dd.code||'',t=dd.t||0;
  e.waitUntil(self.clients.matchAll({type:'window',includeUncontrolled:true}).then(cs=>{
    for(const c of cs){c.postMessage({ring:code,t});return c.focus()}
    return self.clients.openWindow('./#ring='+code+'&t='+t)}))});
