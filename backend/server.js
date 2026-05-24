require('dotenv').config();
const express = require('express');
const cors = require('cors');
const admin = require('firebase-admin');
const stripe = require('stripe')(process.env.STRIPE_SECRET_KEY || '');
const sgMail = require('@sendgrid/mail');

const app = express();

// ── Security headers ─────────────────────────────────────────────
app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('X-XSS-Protection', '1; mode=block');
  res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
  next();
});

// ── Simple in-memory rate limiter ────────────────────────────────
const rateLimitMap = new Map();
function rateLimit(maxRequests, windowMs) {
  return (req, res, next) => {
    const ip = req.headers['x-forwarded-for']?.split(',')[0] || req.ip || 'unknown';
    const now = Date.now();
    const key = `${ip}:${req.path}`;
    const entry = rateLimitMap.get(key) || { count: 0, resetAt: now + windowMs };
    if (now > entry.resetAt) {
      entry.count = 0;
      entry.resetAt = now + windowMs;
    }
    entry.count++;
    rateLimitMap.set(key, entry);
    if (entry.count > maxRequests) {
      return res.status(429).json({ error: 'Too many requests. Try again later.' });
    }
    next();
  };
}
// Clean up old entries every 10 minutes
setInterval(() => {
  const now = Date.now();
  for (const [key, val] of rateLimitMap.entries()) {
    if (now > val.resetAt) rateLimitMap.delete(key);
  }
}, 10 * 60 * 1000);

app.use(cors());
app.use(express.json());

// ── Firebase Admin Init ──────────────────────────────────────────
let firebaseReady = false;
try {
  const serviceAccount = process.env.FIREBASE_SERVICE_ACCOUNT
    ? JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT)
    : null;

  if (serviceAccount) {
    admin.initializeApp({
      credential: admin.credential.cert(serviceAccount),
    });
    firebaseReady = true;
    console.log('✅ Firebase Admin initialized');
  } else {
    console.warn('⚠️  FIREBASE_SERVICE_ACCOUNT not set — push notifications disabled');
  }
} catch (e) {
  console.error('Firebase Admin init error:', e.message);
}

// ── SendGrid Init ────────────────────────────────────────────────
if (process.env.SENDGRID_API_KEY) {
  sgMail.setApiKey(process.env.SENDGRID_API_KEY);
  console.log('✅ SendGrid initialized');
} else {
  console.warn('⚠️  SENDGRID_API_KEY not set — emails disabled');
}

// ── Health check ────────────────────────────────────────────────
app.get('/', (req, res) => {
  res.json({
    status: 'ok',
    service: 'GorealAI Backend',
    firebase: firebaseReady,
    stripe: !!process.env.STRIPE_SECRET_KEY,
    sendgrid: !!process.env.SENDGRID_API_KEY,
  });
});

app.get('/health', (req, res) => res.json({ status: 'ok' }));

// ── FCM Push Notification ────────────────────────────────────────
// POST /send-push
// Body: { token, title, body, data? }
app.post('/send-push', rateLimit(30, 60_000), async (req, res) => {
  const { token, title, body, data } = req.body;

  if (!token || !title) {
    return res.status(400).json({ error: 'token and title required' });
  }

  if (!firebaseReady) {
    return res.status(503).json({ error: 'Firebase not configured' });
  }

  try {
    const message = {
      token,
      notification: { title, body: body || '' },
      data: data || {},
      // Android native config
      android: {
        priority: 'high',
        notification: {
          channelId: 'gorealai_channel',
          priority: 'high',
          sound: 'default',
          icon: 'ic_launcher',
          title,
          body: body || '',
        },
      },
      // Web push config (for browser)
      webpush: {
        notification: {
          title,
          body: body || '',
          icon: 'https://gorealai.web.app/icons/Icon-192.png',
          badge: 'https://gorealai.web.app/icons/Icon-192.png',
        },
        headers: { Urgency: 'high' },
      },
      // iOS config
      apns: {
        payload: {
          aps: { alert: { title, body: body || '' }, sound: 'default', badge: 1 },
        },
      },
    };

    const result = await admin.messaging().send(message);
    console.log(`📬 Push sent: ${result}`);
    res.json({ success: true, messageId: result });
  } catch (e) {
    console.error('Push error:', e.message);
    res.status(500).json({ error: e.message });
  }
});

// ── Booking Response (accept/reject) + email + push ──────────────
// POST /booking-response
// Body: { bookingId, action, proName, userEmail, userName, userFcmToken? }
app.post('/booking-response', rateLimit(20, 60_000), async (req, res) => {
  const { bookingId, action, proName, userEmail, userName, userFcmToken } = req.body;

  if (!bookingId || !action) {
    return res.status(400).json({ error: 'bookingId and action required' });
  }

  const isAccepted = action === 'accept';
  const results = { email: null, push: null };

  // ── Send email via SendGrid ──
  if (userEmail && process.env.SENDGRID_API_KEY) {
    try {
      await sgMail.send({
        to: userEmail,
        from: {
          email: process.env.FROM_EMAIL || 'noreply@gorealai.app',
          name: 'GorealAI',
        },
        subject: isAccepted
          ? `✅ Ο ${proName} αποδέχτηκε το αίτημά σου!`
          : `❌ Ο ${proName} δεν είναι διαθέσιμος`,
        html: isAccepted
          ? `
            <div style="font-family:Arial,sans-serif;max-width:480px;margin:0 auto;background:#0A0800;color:#fff;border-radius:16px;padding:32px;border:1px solid rgba(201,168,76,0.3)">
              <h1 style="color:#C9A84C;font-size:24px;margin-bottom:8px;">✅ Αποδοχή Αιτήματος!</h1>
              <p style="color:rgba(255,255,255,0.7);line-height:1.6;">Γεια σου <strong>${userName}</strong>,</p>
              <p style="color:rgba(255,255,255,0.7);line-height:1.6;">Ο <strong style="color:#C9A84C">${proName}</strong> αποδέχτηκε το αίτημά σου! Μπορείς να επικοινωνήσεις μαζί του μέσα από την εφαρμογή.</p>
              <a href="https://gorealai.web.app/app" style="display:inline-block;margin-top:20px;padding:12px 24px;background:linear-gradient(135deg,#FFD47A,#C9A84C);color:#000;border-radius:10px;text-decoration:none;font-weight:700;">Άνοιξε την εφαρμογή →</a>
              <p style="color:rgba(255,255,255,0.3);font-size:11px;margin-top:24px;">GorealAI — gorealai.web.app</p>
            </div>
          `
          : `
            <div style="font-family:Arial,sans-serif;max-width:480px;margin:0 auto;background:#0A0800;color:#fff;border-radius:16px;padding:32px;border:1px solid rgba(255,80,80,0.2)">
              <h1 style="color:rgba(255,255,255,0.8);font-size:22px;">Ο ${proName} δεν είναι διαθέσιμος</h1>
              <p style="color:rgba(255,255,255,0.6);line-height:1.6;">Μην ανησυχείς! Υπάρχουν άλλοι επαγγελματίες που μπορούν να σε εξυπηρετήσουν.</p>
              <a href="https://gorealai.web.app/app" style="display:inline-block;margin-top:20px;padding:12px 24px;background:linear-gradient(135deg,#FFD47A,#C9A84C);color:#000;border-radius:10px;text-decoration:none;font-weight:700;">Βρες άλλον επαγγελματία →</a>
            </div>
          `,
      });
      results.email = 'sent';
      console.log(`📧 Email sent to ${userEmail}`);
    } catch (e) {
      console.error('Email error:', e.message);
      results.email = `error: ${e.message}`;
    }
  }

  // ── Send FCM push ──
  if (userFcmToken && firebaseReady) {
    const pushTitle = isAccepted ? '✅ Αποδέχτηκαν το αίτημά σου!' : '❌ Δεν ήταν διαθέσιμος';
    const pushBody = isAccepted
      ? `Ο ${proName} αποδέχτηκε την κράτησή σου!`
      : `Ο ${proName} δεν είναι διαθέσιμος αυτή τη στιγμή.`;
    try {
      await admin.messaging().send({
        token: userFcmToken,
        notification: { title: pushTitle, body: pushBody },
        android: {
          priority: 'high',
          notification: {
            channelId: 'gorealai_channel',
            priority: 'high',
            sound: 'default',
            icon: 'ic_launcher',
            title: pushTitle,
            body: pushBody,
          },
        },
        apns: {
          payload: { aps: { alert: { title: pushTitle, body: pushBody }, sound: 'default', badge: 1 } },
        },
      });
      results.push = 'sent';
    } catch (e) {
      console.error('Push error:', e.message);
      results.push = `error: ${e.message}`;
    }
  }

  res.json({ success: true, bookingId, action, results });
});

// ── New Offer notification ────────────────────────────────────────
// POST /new-offer
// Body: { userEmail, userName, userFcmToken, proName, price, requestDesc }
app.post('/new-offer', rateLimit(20, 60_000), async (req, res) => {
  const { userEmail, userName, userFcmToken, proName, price, requestDesc } = req.body;
  const results = {};

  if (userEmail && process.env.SENDGRID_API_KEY) {
    try {
      await sgMail.send({
        to: userEmail,
        from: { email: process.env.FROM_EMAIL || 'noreply@gorealai.app', name: 'GorealAI' },
        subject: `🎯 Νέα προσφορά από ${proName} — ${price}€`,
        html: `
          <div style="font-family:Arial,sans-serif;max-width:480px;margin:0 auto;background:#0A0800;color:#fff;border-radius:16px;padding:32px;border:1px solid rgba(201,168,76,0.3)">
            <h1 style="color:#C9A84C">🎯 Νέα Προσφορά!</h1>
            <p style="color:rgba(255,255,255,0.7)">Γεια σου <strong>${userName}</strong>,</p>
            <p style="color:rgba(255,255,255,0.7)">Ο <strong style="color:#C9A84C">${proName}</strong> έστειλε προσφορά <strong style="color:#FFD47A">${price}€</strong> για το αίτημά σου.</p>
            <a href="https://gorealai.web.app/app" style="display:inline-block;margin-top:20px;padding:12px 24px;background:linear-gradient(135deg,#FFD47A,#C9A84C);color:#000;border-radius:10px;text-decoration:none;font-weight:700;">Δες την προσφορά →</a>
          </div>
        `,
      });
      results.email = 'sent';
    } catch (e) { results.email = `error: ${e.message}`; }
  }

  if (userFcmToken && firebaseReady) {
    const offerTitle = `🎯 Νέα προσφορά — ${price}€`;
    const offerBody = `Ο ${proName} έστειλε προσφορά!`;
    try {
      await admin.messaging().send({
        token: userFcmToken,
        notification: { title: offerTitle, body: offerBody },
        android: {
          priority: 'high',
          notification: {
            channelId: 'gorealai_channel',
            priority: 'high',
            sound: 'default',
            icon: 'ic_launcher',
            title: offerTitle,
            body: offerBody,
          },
        },
        apns: {
          payload: { aps: { alert: { title: offerTitle, body: offerBody }, sound: 'default', badge: 1 } },
        },
      });
      results.push = 'sent';
    } catch (e) { results.push = `error: ${e.message}`; }
  }

  res.json({ success: true, results });
});

// ── Notify pros of new request ───────────────────────────────────────
// POST /notify-new-request
// Body: { fcmToken, proName, userName, description, profession }
app.post('/notify-new-request', rateLimit(60, 60_000), async (req, res) => {
  const { fcmToken, proName, userName, description, profession } = req.body;
  if (!fcmToken || !firebaseReady) {
    return res.json({ success: false, reason: !fcmToken ? 'no token' : 'firebase not ready' });
  }
  const title = `🔔 Νέο αίτημα${profession ? ` για ${profession}` : ''}!`;
  const body = `${userName}: ${description ? description.substring(0, 80) : ''}`;
  try {
    await admin.messaging().send({
      token: fcmToken,
      notification: { title, body },
      android: {
        priority: 'high',
        notification: { channelId: 'gorealai_channel', priority: 'high', sound: 'default', icon: 'ic_launcher', title, body },
      },
      apns: { payload: { aps: { alert: { title, body }, sound: 'default', badge: 1 } } },
    });
    console.log(`📬 New-request push → ${proName}`);
    res.json({ success: true });
  } catch (e) {
    console.error('notify-new-request error:', e.message);
    res.status(500).json({ error: e.message });
  }
});

// ── Notify user/pro of new chat message ──────────────────────────────
// POST /notify-chat-message
// Body: { fcmToken, senderName, messagePreview }
app.post('/notify-chat-message', rateLimit(120, 60_000), async (req, res) => {
  const { fcmToken, senderName, messagePreview } = req.body;
  if (!fcmToken || !firebaseReady) {
    return res.json({ success: false, reason: !fcmToken ? 'no token' : 'firebase not ready' });
  }
  const title = `💬 ${senderName}`;
  const body = messagePreview || 'Νέο μήνυμα';
  try {
    await admin.messaging().send({
      token: fcmToken,
      notification: { title, body },
      android: {
        priority: 'high',
        notification: { channelId: 'gorealai_channel', priority: 'high', sound: 'default', icon: 'ic_launcher', title, body },
      },
      apns: { payload: { aps: { alert: { title, body }, sound: 'default', badge: 1 } } },
    });
    res.json({ success: true });
  } catch (e) {
    console.error('notify-chat-message error:', e.message);
    res.status(500).json({ error: e.message });
  }
});

// ── Stripe Checkout Session ──────────────────────────────────────
// POST /create-checkout-session
// Body: { userId, email }
app.post('/create-checkout-session', rateLimit(10, 60_000), async (req, res) => {
  const { userId, email } = req.body;

  if (!process.env.STRIPE_SECRET_KEY) {
    return res.status(503).json({ error: 'Stripe not configured' });
  }

  if (!process.env.STRIPE_PRICE_ID) {
    return res.status(503).json({ error: 'STRIPE_PRICE_ID not set' });
  }

  try {
    const session = await stripe.checkout.sessions.create({
      mode: 'subscription',
      payment_method_types: ['card'],
      customer_email: email,
      line_items: [{
        price: process.env.STRIPE_PRICE_ID,
        quantity: 1,
      }],
      success_url: `https://gorealai.web.app/app?payment=success&userId=${userId}`,
      cancel_url: `https://gorealai.web.app/app?payment=cancelled`,
      metadata: { userId },
      subscription_data: {
        metadata: { userId },
      },
    });

    console.log(`💳 Checkout session created for ${email}`);
    res.json({ url: session.url, sessionId: session.id });
  } catch (e) {
    console.error('Stripe error:', e.message);
    res.status(500).json({ error: e.message });
  }
});

// ── Stripe Webhook (payment success → update Firestore) ──────────
// POST /stripe-webhook
app.post('/stripe-webhook', express.raw({ type: 'application/json' }), async (req, res) => {
  const sig = req.headers['stripe-signature'];
  const webhookSecret = process.env.STRIPE_WEBHOOK_SECRET;

  if (!webhookSecret) return res.json({ received: true });

  let event;
  try {
    event = stripe.webhooks.constructEvent(req.body, sig, webhookSecret);
  } catch (e) {
    console.error('Webhook signature error:', e.message);
    return res.status(400).send(`Webhook Error: ${e.message}`);
  }

  if (event.type === 'checkout.session.completed') {
    const session = event.data.object;
    const userId = session.metadata?.userId;
    if (userId && firebaseReady) {
      try {
        await admin.firestore().collection('users').doc(userId).update({
          isPremium: true,
          stripeCustomerId: session.customer,
          stripeSubscriptionId: session.subscription,
          premiumSince: admin.firestore.FieldValue.serverTimestamp(),
        });
        console.log(`👑 User ${userId} upgraded to Premium`);
      } catch (e) {
        console.error('Firestore update error:', e.message);
      }
    }
  }

  if (event.type === 'customer.subscription.deleted') {
    const subscription = event.data.object;
    const userId = subscription.metadata?.userId;
    if (userId && firebaseReady) {
      try {
        // Don't revoke premium from owner accounts
        const userDoc = await admin.firestore().collection('users').doc(userId).get();
        if (userDoc.data()?.isOwner === true) {
          console.log(`👑 Owner ${userId} — skipping premium revocation`);
        } else {
          await admin.firestore().collection('users').doc(userId).update({
            isPremium: false,
            premiumCancelledAt: admin.firestore.FieldValue.serverTimestamp(),
          });
          console.log(`❌ User ${userId} subscription cancelled`);
        }
      } catch (e) {
        console.error('Firestore update error:', e.message);
      }
    }
  }

  res.json({ received: true });
});

// ── Start server ────────────────────────────────────────────────
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`🚀 GorealAI backend running on port ${PORT}`);
});
