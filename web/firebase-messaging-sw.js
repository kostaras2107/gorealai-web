importScripts("https://www.gstatic.com/firebasejs/10.8.0/firebase-app-compat.js");
importScripts("https://www.gstatic.com/firebasejs/10.8.0/firebase-messaging-compat.js");

firebase.initializeApp({
  apiKey: "AIzaSyDjRV1CA5FD144UTyIAc_U5oYbSpzw2aFM",
  authDomain: "shoppilot-app-e4104.firebaseapp.com",
  projectId: "shoppilot-app-e4104",
  storageBucket: "shoppilot-app-e4104.firebasestorage.app",
  messagingSenderId: "451660365555",
  appId: "1:451660365555:web:c340e9650c38bb37888186"
});

const messaging = firebase.messaging();

// 🔥 Background notifications (όταν το site είναι κλειστό ή στο background)
messaging.onBackgroundMessage((payload) => {
  console.log("Background message received:", payload);

  const { title, body } = payload.notification || {};

  self.registration.showNotification(title || "GorealAI", {
    body: body || "",
    icon: "/icons/Icon-192.png",
    badge: "/icons/Icon-192.png",
    tag: "gorealai-notification",
    data: payload.data || {},
  });
});