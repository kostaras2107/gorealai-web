importScripts('https://www.gstatic.com/firebasejs/10.7.1/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.7.1/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: "AIzaSyDjRV1CA5FD144UTyIAc_U5oYbSpzw2aFM",
  authDomain: "shoppilot-app-e4104.firebaseapp.com",
  projectId: "shoppilot-app-e4104",
  storageBucket: "shoppilot-app-e4104.firebasestorage.app",
  messagingSenderId: "451660365555",
  appId: "1:451660365555:web:c340e9650c38bb37888186"
});

const messaging = firebase.messaging();

// Background messages — εμφανίζεται notification ακόμα και αν η εφαρμογή είναι κλειστή
messaging.onBackgroundMessage((payload) => {
  const title = payload.notification?.title || 'GorealAI';
  const options = {
    body: payload.notification?.body || 'Νέα ειδοποίηση',
    icon: '/app/icons/gorealai.svg',
    badge: '/app/icons/gorealai.svg',
    tag: payload.data?.requestId || 'gorealai',
    data: payload.data || {},
    vibrate: [200, 100, 200],
  };
  return self.registration.showNotification(title, options);
});

// Πάτημα notification → άνοιγμα app
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
      for (const c of list) {
        if (c.url.includes('/app/') && 'focus' in c) return c.focus();
      }
      if (clients.openWindow) return clients.openWindow('/app/');
    })
  );
});
