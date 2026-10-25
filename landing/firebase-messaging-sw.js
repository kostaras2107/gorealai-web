importScripts('https://www.gstatic.com/firebasejs/10.7.1/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.7.1/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: "AIzaSyDjRV1CA5FD144UTyIAc_U5oYbSpzw2aFM",
  authDomain: "shoppilot-app-e4104.firebaseapp.com",
  projectId: "shoppilot-app-e4104",
  storageBucket: "shoppilot-app-e4104.firebasestorage.app",
  messagingSenderId: "451660365555",
  appId: "1:451660365555:web:c340e9650c38bb37888186",
});

const messaging = firebase.messaging();

messaging.onBackgroundMessage(function(payload) {
  const title = payload.notification?.title || 'GorealAI';
  const body = payload.notification?.body || '';
  self.registration.showNotification(title, {
    body,
    icon: '/app/icons/Icon-192.png',
    badge: '/app/icons/Icon-192.png',
    data: payload.data,
  });
});
