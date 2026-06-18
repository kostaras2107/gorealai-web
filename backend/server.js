require('dotenv').config();
const express = require('express');
const cors = require('cors');
const admin = require('firebase-admin');
const stripe = require('stripe')(process.env.STRIPE_SECRET_KEY || '');
const sgMail = require('@sendgrid/mail');
const nodemailer = require('nodemailer');

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
  // Support both env var names
  const rawKey = process.env.FIREBASE_SERVICE_ACCOUNT || process.env.FIREBASE_KEY;
  const serviceAccount = rawKey ? JSON.parse(rawKey) : null;

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

// ── SendGrid Init (fallback) ─────────────────────────────────────
if (process.env.SENDGRID_API_KEY) {
  sgMail.setApiKey(process.env.SENDGRID_API_KEY);
  console.log('✅ SendGrid initialized');
}

// ── Nodemailer / Zoho SMTP Init ──────────────────────────────────
let zohoTransporter = null;
if (process.env.ZOHO_USER && process.env.ZOHO_PASS) {
  zohoTransporter = nodemailer.createTransport({
    host: 'smtp.zoho.eu',
    port: 465,
    secure: true,
    auth: { user: process.env.ZOHO_USER, pass: process.env.ZOHO_PASS },
  });
  console.log('✅ Zoho SMTP initialized');
} else {
  console.warn('⚠️  ZOHO_USER/ZOHO_PASS not set');
}

// Helper: send email via Zoho (primary) or SendGrid (fallback)
async function sendEmail({ to, subject, html }) {
  if (zohoTransporter) {
    await zohoTransporter.sendMail({
      from: `GorealAI <${process.env.ZOHO_USER || 'info@gorealai.gr'}>`,
      to, subject, html,
    });
    return;
  }
  if (process.env.SENDGRID_API_KEY) {
    await sgMail.send({
      to,
      from: { email: process.env.FROM_EMAIL || 'info@gorealai.gr', name: 'GorealAI' },
      subject, html,
    });
    return;
  }
  throw new Error('No email provider configured');
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

  // ── Send email ──
  if (userEmail) {
    try {
      await sendEmail({
        to: userEmail,
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

  if (userEmail) {
    try {
      await sendEmail({
        to: userEmail,
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

// ── Welcome email on registration ────────────────────────────────────
// POST /welcome-email
// Body: { email, name, role }
app.post('/welcome-email', rateLimit(5, 60_000), async (req, res) => {
  const { email, name, role } = req.body;
  if (!email || !name) return res.status(400).json({ error: 'email and name required' });
  if (!process.env.SENDGRID_API_KEY) return res.json({ success: false, reason: 'sendgrid not configured' });

  const isPro = role === 'professional';
  const subject = isPro
    ? `🎉 Καλώς ήρθες στο GorealAI, ${name.split(' ')[0]}!`
    : `🎉 Καλώς ήρθες στο GorealAI, ${name.split(' ')[0]}!`;

  const html = isPro ? `
    <div style="font-family:Arial,sans-serif;max-width:520px;margin:0 auto;background:#0A0800;color:#fff;border-radius:20px;padding:36px;border:1px solid rgba(201,168,76,0.3)">
      <div style="text-align:center;margin-bottom:28px">
        <h1 style="color:#FFD47A;font-size:28px;margin:0;font-style:italic">${name.split(' ')[0]},</h1>
        <p style="color:#C9A84C;font-size:16px;margin:8px 0 0">καλώς ήρθες στο GorealAI!</p>
      </div>
      <p style="color:rgba(255,255,255,0.75);line-height:1.7;font-size:14px">Ο λογαριασμός σου ως <strong style="color:#FFD47A">Επαγγελματία</strong> είναι έτοιμος. Από τώρα μπορείς να λαμβάνεις αιτήματα από πελάτες κοντά σου και να στέλνεις τις προσφορές σου.</p>
      <div style="background:rgba(201,168,76,0.08);border:1px solid rgba(201,168,76,0.2);border-radius:14px;padding:20px;margin:24px 0">
        <p style="color:#FFD47A;font-size:13px;font-weight:700;margin:0 0 12px">Τι μπορείς να κάνεις:</p>
        <p style="color:rgba(255,255,255,0.65);font-size:13px;line-height:1.8;margin:0">
          📋 Λαμβάνεις αιτήματα που ταιριάζουν με την ειδικότητά σου<br>
          💼 Στέλνεις προσφορές με τιμή & διαθεσιμότητα<br>
          💬 Επικοινωνείς απευθείας με τους πελάτες<br>
          📅 Διαχειρίζεσαι τα bookings σου
        </p>
      </div>
      <div style="text-align:center;margin-top:28px">
        <a href="https://gorealai.web.app/app" style="display:inline-block;padding:14px 32px;background:linear-gradient(135deg,#FFD47A,#C9A84C);color:#000;border-radius:12px;text-decoration:none;font-weight:800;font-size:15px">Άνοιξε την εφαρμογή →</a>
      </div>
      <p style="color:rgba(255,255,255,0.25);font-size:11px;margin-top:28px;text-align:center">GorealAI · gorealai.web.app · info@gorealai.gr</p>
    </div>
  ` : `
    <div style="font-family:Arial,sans-serif;max-width:520px;margin:0 auto;background:#0A0800;color:#fff;border-radius:20px;padding:36px;border:1px solid rgba(201,168,76,0.3)">
      <div style="text-align:center;margin-bottom:28px">
        <h1 style="color:#FFD47A;font-size:28px;margin:0;font-style:italic">${name.split(' ')[0]},</h1>
        <p style="color:#C9A84C;font-size:16px;margin:8px 0 0">καλώς ήρθες στο GorealAI!</p>
      </div>
      <p style="color:rgba(255,255,255,0.75);line-height:1.7;font-size:14px">Ο λογαριασμός σου είναι έτοιμος. Μπορείς τώρα να βρεις τον κατάλληλο επαγγελματία για οποιαδήποτε δουλειά, γρήγορα και εύκολα.</p>
      <div style="background:rgba(201,168,76,0.08);border:1px solid rgba(201,168,76,0.2);border-radius:14px;padding:20px;margin:24px 0">
        <p style="color:#FFD47A;font-size:13px;font-weight:700;margin:0 0 12px">Πώς λειτουργεί:</p>
        <p style="color:rgba(255,255,255,0.65);font-size:13px;line-height:1.8;margin:0">
          1️⃣ Στέλνεις το αίτημά σου (υδραυλικός, ηλεκτρολόγος κ.λπ.)<br>
          2️⃣ Λαμβάνεις προσφορές από επαγγελματίες κοντά σου<br>
          3️⃣ Επιλέγεις την καλύτερη προσφορά<br>
          4️⃣ Επικοινωνείς απευθείας μέσω της εφαρμογής
        </p>
      </div>
      <div style="text-align:center;margin-top:28px">
        <a href="https://gorealai.web.app/app" style="display:inline-block;padding:14px 32px;background:linear-gradient(135deg,#FFD47A,#C9A84C);color:#000;border-radius:12px;text-decoration:none;font-weight:800;font-size:15px">Κάνε το πρώτο σου αίτημα →</a>
      </div>
      <p style="color:rgba(255,255,255,0.25);font-size:11px;margin-top:28px;text-align:center">GorealAI · gorealai.web.app · info@gorealai.gr</p>
    </div>
  `;

  try {
    await sendEmail({ to: email, subject, html });
    console.log(`📧 Welcome email sent to ${email} (${role})`);
    res.json({ success: true });
  } catch (e) {
    console.error('Welcome email error:', e.message);
    res.status(500).json({ error: e.message });
  }
});

// ── Email all matching pros for a new request ────────────────────────
// POST /email-pros-new-request
// Body: { profession, location, description, requestId }
app.post('/email-pros-new-request', rateLimit(30, 60_000), async (req, res) => {
  const { profession, location, description, requestId } = req.body;
  if (!firebaseReady) return res.json({ success: false, reason: 'firebase not ready' });
  if (!zohoTransporter && !process.env.SENDGRID_API_KEY) return res.json({ success: false, reason: 'no email provider configured' });

  try {
    // Fetch all professionals (email is stored in 'professionals' collection)
    const snapshot = await admin.firestore().collection('professionals').get();

    const profLower = (profession || '').toLowerCase();
    const locLower = (location || '').toLowerCase();

    const matching = [];
    snapshot.forEach(doc => {
      const d = doc.data();
      if (!d.email) return;

      // Match specialty
      if (profLower) {
        const specialty = (d.specialty || '').toLowerCase();
        if (specialty && !specialty.includes(profLower) && !profLower.includes(specialty)) return;
      }

      // Match area
      if (locLower && locLower !== 'κοντά μου') {
        const areas = Array.isArray(d.areas) ? d.areas.map(a => a.toLowerCase()) : [];
        if (areas.length > 0 && !areas.some(a => a.includes(locLower) || locLower.includes(a))) return;
      }

      matching.push({ email: d.email, name: d.displayName || d.name || 'Επαγγελματία' });
    });

    if (matching.length === 0) {
      return res.json({ success: true, sent: 0 });
    }

    const subject = `🔔 Νέο αίτημα${profession ? ` για ${profession}` : ''}${location ? ` — ${location}` : ''}`;
    const html = `
      <div style="font-family:Arial,sans-serif;max-width:480px;margin:0 auto;background:#0A0800;color:#fff;border-radius:16px;padding:32px;border:1px solid rgba(201,168,76,0.3)">
        <h1 style="color:#FFD47A;font-size:22px;margin-bottom:4px;">🔔 Νέο Αίτημα!</h1>
        ${profession ? `<p style="color:#C9A84C;font-size:15px;margin:4px 0;font-weight:700;">${profession}</p>` : ''}
        ${location ? `<p style="color:rgba(255,255,255,0.5);font-size:13px;margin:4px 0;">📍 ${location}</p>` : ''}
        ${description ? `<p style="color:rgba(255,255,255,0.7);font-size:14px;margin:16px 0;line-height:1.6;border-left:3px solid rgba(201,168,76,0.4);padding-left:12px;">${description.substring(0, 200)}</p>` : ''}
        <a href="https://gorealai.web.app/app" style="display:inline-block;margin-top:20px;padding:13px 28px;background:linear-gradient(135deg,#FFD47A,#C9A84C);color:#000;border-radius:12px;text-decoration:none;font-weight:800;font-size:14px;">Δες το αίτημα →</a>
        <p style="color:rgba(255,255,255,0.2);font-size:11px;margin-top:24px;">GorealAI · gorealai.web.app · info@gorealai.gr</p>
      </div>
    `;

    // Send individually to avoid one bad email blocking others
    let sent = 0;
    for (const p of matching) {
      try {
        await sendEmail({ to: p.email, subject, html });
        sent++;
      } catch (e) {
        console.error(`Email error for ${p.email}:`, e.message);
      }
    }

    console.log(`📧 New-request emails: ${sent}/${matching.length} sent (${profession} / ${location})`);
    res.json({ success: true, sent, total: matching.length });
  } catch (e) {
    console.error('email-pros-new-request error:', e.message);
    res.status(500).json({ error: e.message });
  }
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

// ── Google Places: search business ──────────────────────────────
// GET /places-search?query=...&location=...
app.get('/places-search', rateLimit(30, 60_000), async (req, res) => {
  const { query, location } = req.query;
  const apiKey = process.env.GOOGLE_PLACES_KEY;
  if (!apiKey) return res.status(503).json({ error: 'Google Places not configured' });
  if (!query) return res.status(400).json({ error: 'query required' });
  try {
    const q = encodeURIComponent(location ? `${query} ${location}` : query);
    const url = `https://maps.googleapis.com/maps/api/place/textsearch/json?query=${q}&language=el&key=${apiKey}`;
    const resp = await fetch(url);
    const data = await resp.json();
    console.log('places-search status:', data.status, data.error_message || '');
    if (data.status && data.status !== 'OK' && data.status !== 'ZERO_RESULTS') {
      return res.status(503).json({ error: `Google Places: ${data.status} — ${data.error_message || ''}` });
    }
    const results = (data.results || []).slice(0, 5).map(p => ({
      placeId: p.place_id,
      name: p.name,
      address: p.formatted_address,
      rating: p.rating || null,
      userRatingsTotal: p.user_ratings_total || 0,
    }));
    res.json({ results });
  } catch (e) {
    console.error('places-search error:', e.message);
    res.status(500).json({ error: e.message });
  }
});

// ── Google Places: get rating for saved placeId ──────────────────
// GET /places-rating?placeId=...
app.get('/places-rating', rateLimit(60, 60_000), async (req, res) => {
  const { placeId } = req.query;
  const apiKey = process.env.GOOGLE_PLACES_KEY;
  if (!apiKey) return res.status(503).json({ error: 'Google Places not configured' });
  if (!placeId) return res.status(400).json({ error: 'placeId required' });
  try {
    const url = `https://maps.googleapis.com/maps/api/place/details/json?place_id=${placeId}&fields=name,rating,user_ratings_total,url&language=el&key=${apiKey}`;
    const resp = await fetch(url);
    const data = await resp.json();
    const r = data.result || {};
    res.json({
      name: r.name || '',
      rating: r.rating || null,
      userRatingsTotal: r.user_ratings_total || 0,
      mapsUrl: r.url || '',
    });
  } catch (e) {
    console.error('places-rating error:', e.message);
    res.status(500).json({ error: e.message });
  }
});

// ── Auth user count (admin only) ─────────────────────────────────
// GET /auth-user-count
app.get('/auth-user-count', async (req, res) => {
  if (!firebaseReady) return res.status(503).json({ error: 'Firebase not ready' });
  try {
    let count = 0;
    let pageToken;
    do {
      const result = await admin.auth().listUsers(1000, pageToken);
      count += result.users.length;
      pageToken = result.pageToken;
    } while (pageToken);
    res.json({ count });
  } catch (e) {
    console.error('auth-user-count error:', e.message);
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
