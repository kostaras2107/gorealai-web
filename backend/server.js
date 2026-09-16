require('dotenv').config();
const express = require('express');
const cors = require('cors');
const admin = require('firebase-admin');
const stripe = require('stripe')(process.env.STRIPE_SECRET_KEY || '');
const sgMail = require('@sendgrid/mail');
const nodemailer = require('nodemailer');

const app = express();

// Τομείς Αττικής — ένας επαγγελματίας μπορεί να δηλώσει "Βόρεια Προάστια"
// αντί να επιλέξει έναν-έναν όλους τους δήμους. Όταν έρθει αίτημα από
// συγκεκριμένο δήμο (π.χ. Χαλάνδρι), το επεκτείνουμε στον τομέα του για το
// matching, ώστε να βρεθεί ο επαγγελματίας που κάλυψε τον τομέα, όχι μόνο
// όσους έχουν επιλέξει ρητά τον ίδιο δήμο.
const ATTICA_SECTORS = {
  'κεντρικά προάστια': ['αθήνα', 'βύρωνας', 'γαλάτσι', 'δάφνη-υμηττός', 'ζωγράφου', 'ηλιούπολη', 'καισαριανή', 'κυψέλη', 'φιλαδέλφεια-χαλκηδόνα'],
  'νότια προάστια': ['άλιμος', 'αργυρούπολη-ελληνικό', 'γλυφάδα', 'βούλα', 'βουλιαγμένη', 'καλλιθέα', 'μοσχάτο-ταύρος', 'νέα σμύρνη', 'παλαιό φάληρο'],
  'βόρεια προάστια': ['αγία παρασκευή', 'αμαρούσιο', 'βριλήσσια', 'ηράκλειο αττικής', 'κηφισιά', 'λυκόβρυση-πεύκη', 'μεταμόρφωση', 'νέα ιωνία', 'παπάγου-χολαργός', 'πεντέλη', 'φιλοθέη-ψυχικό', 'χαλάνδρι'],
  'δυτικά προάστια': ['αγία βαρβάρα', 'αγίων αναργύρων-καματερό', 'αιγάλεω', 'ίλιον', 'κορυδαλλός', 'περιστέρι', 'πετρούπολη', 'χαϊδάρι'],
  'πειραιάς & νησιά': ['πειραιάς', 'κερατσίνι-δραπετσώνα', 'νίκαια-αγ.ιω.ρέντης', 'πέραμα', 'σαλαμίνα'],
  'ανατολική αττική': ['ανθούσα', 'αχαρνές', 'γέρακας', 'διόνυσος', 'κρυονέρι', 'μαραθώνας', 'μαρκόπουλο', 'παιανία', 'παλλήνη', 'ραφήνα-πικέρμι', 'σπάτα-αρτέμιδα', 'ωρωπός'],
  'δυτική αττική': ['ασπρόπυργος', 'ελευσίνα', 'μάνδρα-ειδυλλία', 'μέγαρα', 'νέα πέραμος'],
  'νότια αττική': ['κορωπί', 'λαύριο', 'σαρωνικός'],
};
// Αντίστροφος χάρτης: δήμος (lowercase) → τομέας του, για γρήγορο lookup.
const AREA_TO_SECTOR = {};
for (const [sector, towns] of Object.entries(ATTICA_SECTORS)) {
  for (const t of towns) AREA_TO_SECTOR[t] = sector;
}

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

// ── SMS via InfiniReach ──────────────────────────────────────────
async function sendSms(phone, message) {
  const apiKey = process.env.INFINIREACH_API_KEY;
  const fromPhone = process.env.INFINIREACH_PHONE; // your Android number e.g. +306944048588
  if (!apiKey || !fromPhone || !phone) return;
  let p = phone.replace(/\s+/g, '');
  if (p.startsWith('00')) p = '+' + p.slice(2);
  else if (p.startsWith('0')) p = '+30' + p.slice(1);
  else if (/^[62]/.test(p)) p = '+30' + p;
  else if (!p.startsWith('+')) p = '+30' + p;
  try {
    const r = await fetch('https://api.infinireach.io/api/v1/messages', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-API-Key': apiKey },
      body: JSON.stringify({ to: p, from: fromPhone, message, channel: 'sms' }),
    });
    const j = await r.json();
    console.log(`📱 SMS to ${p}:`, j.success ? 'OK' : JSON.stringify(j));
  } catch (e) {
    console.error(`SMS error for ${p}:`, e.message);
  }
}

// Helper: send email via Zoho (primary) or SendGrid (fallback)
async function sendEmail({ to, subject, html }) {
  if (zohoTransporter) {
    await zohoTransporter.sendMail({
      from: `GorealPro <${process.env.ZOHO_USER || 'info@gorealai.gr'}>`,
      to, subject, html,
    });
    return;
  }
  if (process.env.SENDGRID_API_KEY) {
    await sgMail.send({
      to,
      from: { email: process.env.FROM_EMAIL || 'info@gorealai.gr', name: 'GorealPro' },
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
    service: 'GorealPro Backend',
    firebase: firebaseReady,
    stripe: !!process.env.STRIPE_SECRET_KEY,
    sendgrid: !!process.env.SENDGRID_API_KEY,
  });
});

app.get('/health', (req, res) => res.json({ status: 'ok' }));

// ── Δημοφιλείς υπηρεσίες (top ειδικότητες ανά αριθμό επαγγελματιών) ──────
// GET /popular-specialties?limit=8
// Υπολογίζεται live από τη βάση, με μικρό in-memory cache ώστε η λίστα να
// ανανεώνεται μόνη της καθώς μπαίνουν/φεύγουν επαγγελματίες, χωρίς να
// χτυπάει το Firestore σε κάθε άνοιγμα της αρχικής.
const SPECIALTY_EMOJI = {
  'Συνεργείο Ανακαίνισης': '🏗️', 'Ηλεκτρολόγος': '⚡', 'Ελαιοχρωματιστής': '🎨',
  'Υδραυλικός': '🔧', 'Μονώσεις - Διαχείριση & Αντιμετώπιση Υγρασίας': '💧',
  'Γυψοσανίδες': '🧱', 'Συνεργείο Κατασκευών': '🏢', 'Ξυλουργός': '🪵',
  'Πλακάς': '🔲', 'Συνεργείο Υδραυλικών': '🔧', 'Μετακομίσεις': '📦',
  'Νοσηλευτής κατ\' οίκον': '🩺', 'Υπηρεσία Αποξήλωσης': '🔨',
  'Μεταλλικές Κατασκευές': '⚙️', 'Συνεργείο Γυψοσανίδας & Οροφής': '🧱',
  'Καθαρίστρια': '🧹', 'Συνεργείο Πλακιδίων & Δαπέδων': '🔲',
  'Εκδηλώσεις Γάμου': '💍', 'Συντήρηση Κλιματιστικών': '❄️',
  'Συνεργείο Βαφής & Διακόσμησης': '🎨', 'Εγκατάσταση Ηλιακών': '☀️',
  'Φωτογράφος': '📷', 'Συνεργείο Ηλεκτρολόγων': '⚡',
  'Συνεργείο Ξυλουργικών Εργασιών': '🪵', 'Συνεργείο Κλιματισμού': '❄️',
  'Συνεργείο Αλουμινίου & Κουφωμάτων': '🪟', 'Εκδηλώσεις Βάφτισης': '👶',
  'Αλουμινάς': '🪟', 'DJ / Μουσική Εκδηλώσεων': '🎧', 'Ψυκτικός': '🧊',
  'Γυάλισμα Μαρμάρων': '✨', 'Συνεργείο Κήπου & Εξωτερικών Χώρων': '🌿',
  'Φωτογράφος Εκδηλώσεων': '📷', 'Makeup Artist': '💄', 'Κηπουρός': '🌿',
  'Αποφράξεις': '🚿', 'Τεχνίτρια Νυχιών': '💅', 'Baby Sitter': '🍼',
  'Γραφίστας': '🖌️', 'Διοργάνωση Πάρτυ': '🎉', 'Καθηγητής Αγγλικών': '📚',
  'Γκαραζόπορτες - Ρολά - Συρόμενα': '🚪', 'Τέντες - Σκίαστρα': '⛱️',
  'Catering': '🍽️', 'Βιολογικός Καθαρισμός': '🧼', 'Κτίστης': '🧱',
  'Smart Home - Συστήματα Ασφαλείας': '🏠', 'Web Developer': '💻',
};

let _popularSpecialtiesCache = null;
let _popularSpecialtiesCacheAt = 0;
const POPULAR_SPECIALTIES_TTL_MS = 30 * 60_000; // 30 λεπτά

app.get('/popular-specialties', async (req, res) => {
  const limit = Math.min(parseInt(req.query.limit, 10) || 8, 20);
  if (!firebaseReady) return res.json({ success: false, reason: 'firebase not ready', items: [] });

  try {
    const now = Date.now();
    if (!_popularSpecialtiesCache || (now - _popularSpecialtiesCacheAt) > POPULAR_SPECIALTIES_TTL_MS) {
      const snap = await admin.firestore().collection('users').where('role', '==', 'professional').get();
      const counts = {};
      snap.forEach(doc => {
        const d = doc.data();
        const specs = Array.isArray(d.specialties) && d.specialties.length > 0
          ? d.specialties
          : (d.specialty ? [d.specialty] : []);
        const unique = [...new Set(specs.filter(s => s && s.trim()))];
        unique.forEach(s => { counts[s] = (counts[s] || 0) + 1; });
      });
      _popularSpecialtiesCache = Object.entries(counts)
        .sort((a, b) => b[1] - a[1])
        .map(([profession, count]) => ({
          profession, count,
          emoji: SPECIALTY_EMOJI[profession] || '🛠️',
        }));
      _popularSpecialtiesCacheAt = now;
    }
    res.json({ success: true, items: _popularSpecialtiesCache.slice(0, limit) });
  } catch (e) {
    console.error('popular-specialties error:', e.message);
    res.status(500).json({ success: false, items: [] });
  }
});

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
  const { bookingId, action } = req.body;
  let { proName, userEmail, userName, userFcmToken } = req.body;

  if (!bookingId || !action) {
    return res.status(400).json({ error: 'bookingId and action required' });
  }

  const isAccepted = action === 'accept';
  const results = { email: null, push: null };

  // ── Look up booking + user contact info server-side (client doesn't reliably send it) ──
  let userId = null;
  if (firebaseReady) {
    try {
      const bookingDoc = await admin.firestore().collection('bookings').doc(bookingId).get();
      if (bookingDoc.exists) {
        const b = bookingDoc.data();
        userId = b.userId || null;
        proName = proName || b.professionalName || '';
        if (userId) {
          const userDoc = await admin.firestore().collection('users').doc(userId).get();
          if (userDoc.exists) {
            userEmail = userEmail || userDoc.data().email;
            userName = userName || userDoc.data().name;
            userFcmToken = userFcmToken || userDoc.data().fcmToken;
          }
        }
      }
    } catch (e) {
      console.error('booking-response lookup error:', e.message);
    }
  }

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
              <p style="color:rgba(255,255,255,0.3);font-size:11px;margin-top:24px;">GorealPro — gorealai.web.app</p>
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
            notificationCount: 1,
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

  // ── In-app notification + badge entry ──
  if (userId && firebaseReady) {
    const pushTitle = isAccepted ? '✅ Αποδέχτηκαν το αίτημά σου!' : '❌ Δεν ήταν διαθέσιμος';
    const pushBody = isAccepted
      ? `Ο ${proName} αποδέχτηκε την κράτησή σου!`
      : `Ο ${proName} δεν είναι διαθέσιμος αυτή τη στιγμή.`;
    admin.firestore().collection('users').doc(userId).collection('notifications').add({
      title: pushTitle, body: pushBody, isRead: false, type: 'booking_response', bookingId,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    }).catch(() => {});
  }

  res.json({ success: true, bookingId, action, results });
});

// ── Smart offer ranking ──────────────────────────────────────────
// GET /get-offers/:requestId
// Επιστρέφει τις 3 καλύτερες προσφορές, με κατάταξη που εξαρτάται από το
// κριτήριο που επέλεξε ο πελάτης όταν έστειλε το αίτημα (criteria:
// 'cheap' | 'value' | 'fast') — όχι απλά "ό,τι είναι φθηνότερο" πάντα.
// - cheap: κυρίως τιμή (φθηνότερα πρώτα), rating σαν tie-breaker
// - value: ισορροπία τιμής/rating/verified — καλύτερη σχέση ποιότητας-τιμής
// - fast: κυρίως διαθεσιμότητα (σήμερα > αύριο > αργότερα), rating δεύτερο
app.get('/get-offers/:requestId', rateLimit(60, 60_000), async (req, res) => {
  const { requestId } = req.params;
  if (!firebaseReady) return res.json({ offers: [] });
  try {
    const reqDoc = await admin.firestore().collection('requests').doc(requestId).get();
    const criteria = reqDoc.exists ? (reqDoc.data().criteria || 'cheap') : 'cheap';

    const offersSnap = await admin.firestore().collection('offers')
      .where('requestId', '==', requestId).limit(50).get();
    if (offersSnap.empty) return res.json({ offers: [], criteria });

    const offers = await Promise.all(offersSnap.docs.map(async doc => {
      const o = { id: doc.id, ...doc.data() };
      if (o.professionalId) {
        try {
          const proDoc = await admin.firestore().collection('professionals').doc(o.professionalId).get();
          if (proDoc.exists) {
            const p = proDoc.data();
            o.rating = (typeof p.averageRating === 'number') ? p.averageRating : (o.rating || 0);
            o.reviewCount = p.reviewCount || 0;
            o.verified = p.afmValid === true;
            if (p.profilePhotoUrl) o.profilePhotoUrl = p.profilePhotoUrl;
          }
        } catch (_) {}
      }
      return o;
    }));

    const availabilityRank = (avail) => {
      const a = (avail || '').toLowerCase();
      if (a.includes('σήμερα')) return 3;
      if (a.includes('αύριο')) return 2;
      return 1;
    };

    const scored = offers.map(o => {
      const hasPrice = !o.priceAfterVisit && typeof o.price === 'number' && o.price > 0;
      const price = hasPrice ? o.price : null;
      const rating = typeof o.rating === 'number' ? o.rating : 0;
      // Όταν πολλές προσφορές είναι όλες "τιμή μετά από αυτοψία" (χωρίς
      // σταθερό νούμερο), το rating μόνο του συχνά ισοπαλεί (πολλοί
      // καινούριοι επαγγελματίες με 0 reviews) — αυτό δίνει μια αλυσίδα
      // tie-breakers ώστε να μην καταλήγει σε τυχαία σειρά: rating →
      // αριθμός αξιολογήσεων (πόσο αξιόπιστο είναι το rating) → verified.
      const reviewCount = typeof o.reviewCount === 'number' ? o.reviewCount : 0;
      const tieBreak = Math.log10(reviewCount + 1) * 3 + (o.verified ? 1 : 0);
      let score;
      if (criteria === 'fast') {
        score = availabilityRank(o.availableFrom) * 1000 + rating * 10 - (price != null ? price * 0.05 : 0) + tieBreak;
      } else if (criteria === 'value') {
        const normPrice = price != null ? Math.max(price, 1) : 300; // ουδέτερη υπόθεση αν "τιμή μετά από αυτοψία"
        score = (rating * 200) - normPrice + (o.verified ? 50 : 0) + tieBreak;
      } else {
        // 'cheap' (default) — κυρίως τιμή, rating σαν tie-breaker.
        // "Τιμή μετά από αυτοψία" (χωρίς σταθερή τιμή) πάει τελευταία εδώ,
        // αφού ο πελάτης ζήτησε ρητά το φθηνότερο συγκεκριμένο νούμερο.
        score = (price != null ? -price : -999999) + rating * 5 + tieBreak;
      }
      const createdAtMs = o.createdAt && typeof o.createdAt.toMillis === 'function'
        ? o.createdAt.toMillis() : Infinity;
      return { ...o, _score: score, _createdAtMs: createdAtMs };
    });

    // Αν δύο προσφορές ισοπαλήσουν ακριβώς σε score (π.χ. όλοι καινούριοι,
    // χωρίς reviews, χωρίς verified, όλοι "τιμή μετά από αυτοψία"), κερδίζει
    // όποιος έστειλε προσφορά πρώτος — πάντα διαθέσιμο, δίκαιο σήμα ταχύτητας.
    scored.sort((a, b) => b._score - a._score || a._createdAtMs - b._createdAtMs);
    const top = scored.slice(0, 3).map(({ _score, _createdAtMs, ...rest }) => rest);

    res.json({ offers: top, criteria, totalOffers: offers.length });
  } catch (e) {
    console.error('get-offers error:', e.message);
    res.status(500).json({ offers: [] });
  }
});

// ── New Offer notification ────────────────────────────────────────
// POST /new-offer
// Body: { userEmail, userName, userFcmToken, proName, price, requestDesc }
app.post('/new-offer', rateLimit(20, 60_000), async (req, res) => {
  const { userId, userName, userFcmToken, proName, price, requestDesc } = req.body;
  let { userEmail } = req.body;
  const results = {};

  // Το email συχνά δεν υπάρχει στο Firestore users doc — πάρτο αξιόπιστα από το Auth
  if (!userEmail && userId && firebaseReady) {
    try {
      const authUser = await admin.auth().getUser(userId);
      userEmail = authUser.email || null;
    } catch (e) { /* δεν βρέθηκε λογαριασμός Auth */ }
  }

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
            notificationCount: 1,
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

// ── Offer accepted notification (customer selected this pro) ─────────
// POST /offer-accepted
// Body: { proId, userName, userPhone, requestDesc }
app.post('/offer-accepted', rateLimit(20, 60_000), async (req, res) => {
  const { proId, userName, userPhone, requestDesc } = req.body;
  if (!proId) return res.status(400).json({ error: 'proId required' });
  if (!firebaseReady) return res.json({ success: false, reason: 'firebase not ready' });

  try {
    // Αύξηση μετρητή "Δουλειές" στο δημόσιο προφίλ — γίνεται εδώ (Admin SDK)
    // γιατί ο πελάτης δεν επιτρέπεται από τους κανόνες ασφαλείας να γράψει
    // απευθείας στο professionals doc κάποιου άλλου.
    try {
      await admin.firestore().collection('professionals').doc(proId).set({
        completedJobs: admin.firestore.FieldValue.increment(1),
        jobs_count: admin.firestore.FieldValue.increment(1),
      }, { merge: true });
    } catch (e) { console.error('jobs-count increment error:', e.message); }

    let proEmail = null;
    try {
      const authUser = await admin.auth().getUser(proId);
      proEmail = authUser.email || null;
    } catch (e) { /* δεν βρέθηκε λογαριασμός Auth */ }

    if (!proEmail) return res.json({ success: false, reason: 'no email found for pro' });

    const html = `
      <div style="font-family:Arial,sans-serif;max-width:480px;margin:0 auto;background:#0A0800;color:#fff;border-radius:16px;padding:32px;border:1px solid rgba(201,168,76,0.3)">
        <h1 style="color:#FFD47A;font-size:22px;margin-bottom:4px;">🎉 Αποδέχτηκαν την προσφορά σου!</h1>
        <p style="color:rgba(255,255,255,0.75);font-size:14px;line-height:1.6;">Ο/Η <strong style="color:#FFD47A">${userName || 'πελάτης'}</strong> αποδέχτηκε την προσφορά σου${requestDesc ? ` για: "${String(requestDesc).substring(0, 120)}"` : ''}.</p>
        ${userPhone ? `<p style="color:rgba(255,255,255,0.6);font-size:14px;margin-top:12px;">📞 Τηλέφωνο επικοινωνίας: <strong style="color:#FFD47A">${userPhone}</strong></p>` : ''}
        <a href="https://gorealai.web.app/app" style="display:inline-block;margin-top:20px;padding:13px 28px;background:linear-gradient(135deg,#FFD47A,#C9A84C);color:#000;border-radius:12px;text-decoration:none;font-weight:800;font-size:14px;">Δες τα Bookings σου →</a>
        <p style="color:rgba(255,255,255,0.2);font-size:11px;margin-top:24px;">GorealPro · gorealai.web.app · info@gorealai.gr</p>
      </div>
    `;
    await sendEmail({ to: proEmail, subject: '🎉 Αποδέχτηκαν την προσφορά σου στο GorealPro', html });
    console.log(`📧 Offer-accepted email sent to ${proEmail}`);
    res.json({ success: true });
  } catch (e) {
    console.error('offer-accepted error:', e.message);
    res.status(500).json({ error: e.message });
  }
});

// ── Track professional referral (new pro signed up via referral) ─────
// POST /track-referral
// Body: { referrerUid, newProName }
// Ο νέος εγγεγραμμένος δεν επιτρέπεται από τους κανόνες ασφαλείας να γράψει
// στο users doc κάποιου άλλου (του referrer) — γίνεται εδώ με Admin SDK.
app.post('/track-referral', rateLimit(20, 60_000), async (req, res) => {
  const { referrerUid, newProName } = req.body;
  if (!referrerUid) return res.status(400).json({ error: 'referrerUid required' });
  if (!firebaseReady) return res.json({ success: false, reason: 'firebase not ready' });

  try {
    const ref = admin.firestore().collection('users').doc(referrerUid);
    const result = await admin.firestore().runTransaction(async (tx) => {
      const doc = await tx.get(ref);
      if (!doc.exists) return { count: 0, justUnlocked: false };
      const count = ((doc.data().referralCount) || 0) + 1;
      const updates = { referralCount: count };
      let justUnlocked = false;
      // Συνδέεται με τα ΠΡΑΓΜΑΤΙΚΑ πεδία που ελέγχει η εφαρμογή για premium
      // πρόσβαση (isPremium/premiumUntil), όχι το ανενεργό freeUntil.
      if (count >= 5 && doc.data().isPremium !== true) {
        updates.isPremium = true;
        updates.premiumUntil = admin.firestore.Timestamp.fromDate(
          new Date(Date.now() + 365 * 24 * 60 * 60 * 1000)
        );
        updates.premiumSince = admin.firestore.FieldValue.serverTimestamp();
        justUnlocked = true;
      }
      tx.update(ref, updates);
      return { count, justUnlocked };
    });
    console.log(`🤝 Referral tracked for ${referrerUid}: count=${result.count}${result.justUnlocked ? ' — PREMIUM UNLOCKED' : ''}`);
    res.json({ success: true, ...result });
  } catch (e) {
    console.error('track-referral error:', e.message);
    res.status(500).json({ error: e.message });
  }
});

// ── Welcome email on registration ────────────────────────────────────
// POST /welcome-email
// Body: { email, name, role }
app.post('/welcome-email', rateLimit(5, 60_000), async (req, res) => {
  const { email, name, role } = req.body;
  if (!email || !name) return res.status(400).json({ error: 'email and name required' });

  const isPro = role === 'professional';
  const subject = isPro
    ? `🎉 Καλώς ήρθες στο GorealPro, ${name.split(' ')[0]}!`
    : `🎉 Καλώς ήρθες στο GorealPro, ${name.split(' ')[0]}!`;

  const html = isPro ? `
    <div style="font-family:Arial,sans-serif;max-width:520px;margin:0 auto;background:#0A0800;color:#fff;border-radius:20px;padding:36px;border:1px solid rgba(201,168,76,0.3)">
      <div style="text-align:center;margin-bottom:28px">
        <h1 style="color:#FFD47A;font-size:28px;margin:0;font-style:italic">${name.split(' ')[0]},</h1>
        <p style="color:#C9A84C;font-size:16px;margin:8px 0 0">καλώς ήρθες στο GorealPro!</p>
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
      <div style="text-align:center;margin-top:16px">
        <p style="color:rgba(255,255,255,0.5);font-size:12px;margin:0 0 8px">📲 Έχεις Android; Κατέβασε την εφαρμογή από το Google Play για την καλύτερη εμπειρία</p>
        <a href="https://gorealai.web.app/get" style="color:#FFD47A;font-size:13px;text-decoration:underline">Κατέβασε από το Google Play</a>
      </div>
      <p style="color:rgba(255,255,255,0.25);font-size:11px;margin-top:28px;text-align:center">GorealPro · gorealai.web.app · info@gorealai.gr</p>
    </div>
  ` : `
    <div style="font-family:Arial,sans-serif;max-width:520px;margin:0 auto;background:#0A0800;color:#fff;border-radius:20px;padding:36px;border:1px solid rgba(201,168,76,0.3)">
      <div style="text-align:center;margin-bottom:28px">
        <h1 style="color:#FFD47A;font-size:28px;margin:0;font-style:italic">${name.split(' ')[0]},</h1>
        <p style="color:#C9A84C;font-size:16px;margin:8px 0 0">καλώς ήρθες στο GorealPro!</p>
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
      <div style="text-align:center;margin-top:16px">
        <p style="color:rgba(255,255,255,0.5);font-size:12px;margin:0 0 8px">📲 Έχεις Android; Κατέβασε την εφαρμογή από το Google Play για την καλύτερη εμπειρία</p>
        <a href="https://gorealai.web.app/get" style="color:#FFD47A;font-size:13px;text-decoration:underline">Κατέβασε από το Google Play</a>
      </div>
      <p style="color:rgba(255,255,255,0.25);font-size:11px;margin-top:28px;text-align:center">GorealPro · gorealai.web.app · info@gorealai.gr</p>
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

// ── Email verification link (via our own Zoho sender, better deliverability) ──
// POST /verify-email
// Body: { email }
// Ο client-side κλήση Firebase user.sendEmailVerification() αποτυγχάνει σιωπηλά
// σε κάποιες περιπτώσεις (π.χ. rate-limit) χωρίς να το μαθαίνει κανείς — το
// στέλνουμε πλέον από εδώ, ίδιο μοτίβο με το /forgot-password.
app.post('/verify-email', rateLimit(5, 60_000), async (req, res) => {
  const { email } = req.body;
  if (!email) return res.status(400).json({ error: 'email required' });
  if (!firebaseReady) return res.status(503).json({ error: 'Firebase not ready' });

  try {
    const link = await admin.auth().generateEmailVerificationLink(email);
    const html = `
      <div style="font-family:Arial,sans-serif;max-width:480px;margin:0 auto;background:#0A0800;color:#fff;border-radius:16px;padding:32px;border:1px solid rgba(201,168,76,0.3)">
        <h1 style="color:#FFD47A;font-size:20px;margin-bottom:8px;">Επιβεβαίωσε το email σου</h1>
        <p style="color:rgba(255,255,255,0.75);font-size:14px;line-height:1.6;">Καλώς ήρθες στο GorealPro! Πάτα το παρακάτω κουμπί για να επιβεβαιώσεις το email σου και να ενεργοποιήσεις τον λογαριασμό σου.</p>
        <a href="${link}" style="display:inline-block;margin-top:20px;padding:13px 28px;background:linear-gradient(135deg,#FFD47A,#C9A84C);color:#000;border-radius:12px;text-decoration:none;font-weight:800;font-size:14px;">Επιβεβαίωση Email →</a>
        <p style="color:rgba(255,255,255,0.4);font-size:12px;margin-top:20px;">Αν δεν δημιούργησες εσύ αυτόν τον λογαριασμό, αγνόησε αυτό το email.</p>
        <p style="color:rgba(255,255,255,0.2);font-size:11px;margin-top:24px;">GorealPro · gorealai.web.app · info@gorealai.gr</p>
      </div>
    `;
    await sendEmail({ to: email, subject: 'Επιβεβαίωσε το email σου στο GorealPro', html });
    console.log(`📧 Verification email sent to ${email}`);
    res.json({ success: true });
  } catch (e) {
    console.error('verify-email error:', e.code || e.message);
    if (e.code === 'auth/user-not-found') {
      return res.status(404).json({ error: 'Δεν βρέθηκε λογαριασμός με αυτό το email.' });
    }
    res.status(500).json({ error: e.message });
  }
});

// ── AFM verification via the EU VIES service ──────────────────────────
// POST /verify-afm
// Body: { afm }
// Καλεί το επίσημο REST API του VIES (ec.europa.eu) για να επιβεβαιώσει ότι
// το ΑΦΜ αντιστοιχεί σε πραγματική, ενεργή επιχείρηση — όχι απλά ότι
// γράφτηκε κάτι στο πεδίο.
app.post('/verify-afm', rateLimit(20, 60_000), async (req, res) => {
  const { afm } = req.body;
  if (!afm || !/^\d{9}$/.test(afm)) return res.status(400).json({ valid: false, reason: 'invalid format' });

  try {
    const viesRes = await fetch('https://ec.europa.eu/taxation_customs/vies/rest-api/check-vat-number', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ countryCode: 'EL', vatNumber: afm }),
      signal: AbortSignal.timeout(10_000),
    });
    if (!viesRes.ok) return res.json({ valid: false, reason: 'vies unavailable' });
    const data = await viesRes.json();
    res.json({ valid: data.valid === true, name: data.name || null });
  } catch (e) {
    console.error('verify-afm error:', e.message);
    res.json({ valid: false, reason: 'vies error' });
  }
});

// ── Resolve short TikTok share links (vm.tiktok.com / vt.tiktok.com) ─────
// Το κουμπί "Αντιγραφή Συνδέσμου" στο κινητό δίνει σύντομο redirect link,
// όχι το πλήρες https://www.tiktok.com/@user/video/123... — το ακολουθούμε
// server-side (χωρίς πρόβλημα CORS, σε αντίθεση με τον browser) για να
// βγάλουμε το πραγματικό video ID.
// POST /resolve-tiktok-link
// Body: { url }
app.post('/resolve-tiktok-link', rateLimit(30, 60_000), async (req, res) => {
  const { url } = req.body;
  if (!url) return res.status(400).json({ success: false, reason: 'url required' });
  try {
    const resp = await fetch(url, { redirect: 'follow', signal: AbortSignal.timeout(10_000) });
    const finalUrl = resp.url;
    const match = finalUrl.match(/\/(?:video|photo)\/(\d+)/);
    if (!match) return res.json({ success: false, reason: 'video id not found' });
    res.json({ success: true, videoId: match[1], canonicalUrl: finalUrl });
  } catch (e) {
    console.error('resolve-tiktok-link error:', e.message);
    res.json({ success: false, reason: e.message });
  }
});

// ── TikTok video thumbnail proxy ──────────────────────────────────────────
// Το thumbnail_url του TikTok oEmbed δεν έχει CORS headers, οπότε ο browser
// (Flutter Web/CanvasKit) δεν μπορεί να το φορτώσει απευθείας. Το φέρνουμε
// server-side και το περνάμε στον client με δικά μας CORS headers.
// GET /tiktok-thumbnail?url=<video url>
app.get('/tiktok-thumbnail', rateLimit(120, 60_000), async (req, res) => {
  const { url } = req.query;
  if (!url) return res.status(400).send('url required');
  try {
    const oembedResp = await fetch(`https://www.tiktok.com/oembed?url=${encodeURIComponent(url)}`, {
      signal: AbortSignal.timeout(10_000),
    });
    if (!oembedResp.ok) return res.status(404).send('oembed not found');
    const oembed = await oembedResp.json();
    if (!oembed.thumbnail_url) return res.status(404).send('no thumbnail');
    const imgResp = await fetch(oembed.thumbnail_url, { signal: AbortSignal.timeout(10_000) });
    if (!imgResp.ok) return res.status(404).send('thumbnail fetch failed');
    res.set('Content-Type', imgResp.headers.get('content-type') || 'image/jpeg');
    res.set('Cache-Control', 'public, max-age=3600');
    res.set('Access-Control-Allow-Origin', '*');
    const buf = Buffer.from(await imgResp.arrayBuffer());
    res.send(buf);
  } catch (e) {
    console.error('tiktok-thumbnail error:', e.message);
    res.status(500).send('error');
  }
});

// ── Password reset email (via our own Zoho sender, better deliverability) ──
// POST /forgot-password
// Body: { email }
app.post('/forgot-password', rateLimit(5, 60_000), async (req, res) => {
  const { email } = req.body;
  if (!email) return res.status(400).json({ error: 'email required' });
  if (!firebaseReady) return res.status(503).json({ error: 'Firebase not ready' });

  try {
    const link = await admin.auth().generatePasswordResetLink(email);
    const html = `
      <div style="font-family:Arial,sans-serif;max-width:480px;margin:0 auto;background:#0A0800;color:#fff;border-radius:16px;padding:32px;border:1px solid rgba(201,168,76,0.3)">
        <h1 style="color:#FFD47A;font-size:20px;margin-bottom:8px;">Επαναφορά κωδικού</h1>
        <p style="color:rgba(255,255,255,0.75);font-size:14px;line-height:1.6;">Ζήτησες επαναφορά κωδικού για τον λογαριασμό σου στο GorealPro. Πάτα το παρακάτω κουμπί για να ορίσεις νέο κωδικό.</p>
        <a href="${link}" style="display:inline-block;margin-top:20px;padding:13px 28px;background:linear-gradient(135deg,#FFD47A,#C9A84C);color:#000;border-radius:12px;text-decoration:none;font-weight:800;font-size:14px;">Επαναφορά Κωδικού →</a>
        <p style="color:rgba(255,255,255,0.4);font-size:12px;margin-top:20px;">Αν δεν το ζήτησες εσύ, αγνόησε αυτό το email.</p>
        <p style="color:rgba(255,255,255,0.2);font-size:11px;margin-top:24px;">GorealPro · gorealai.web.app · info@gorealai.gr</p>
      </div>
    `;
    await sendEmail({ to: email, subject: 'Επαναφορά κωδικού στο GorealPro', html });
    console.log(`📧 Password reset email sent to ${email}`);
    res.json({ success: true });
  } catch (e) {
    console.error('forgot-password error:', e.code || e.message);
    if (e.code === 'auth/user-not-found') {
      return res.status(404).json({ error: 'Δεν βρέθηκε λογαριασμός με αυτό το email.' });
    }
    res.status(500).json({ error: e.message });
  }
});

// ── Email all matching pros for a new request ────────────────────────
// POST /email-pros-new-request
// Body: { profession, location, description, requestId }
app.post('/email-pros-new-request', rateLimit(30, 60_000), async (req, res) => {
  const { profession, location, description, requestId, filterVerifiedOnly, exactSpecialty, requesterUserId, urgent, teachingMode } = req.body;
  if (!firebaseReady) return res.json({ success: false, reason: 'firebase not ready' });
  if (!zohoTransporter && !process.env.SENDGRID_API_KEY) return res.json({ success: false, reason: 'no email provider configured' });

  try {
    // Fetch all professionals (email is stored in 'professionals' collection)
    const snapshot = await admin.firestore().collection('professionals').get();

    const profLower = (profession || '').toLowerCase();
    const locLower = (location || '').toLowerCase();

    // Build a map: userId/docId → best data (merge auto-ID and UID-keyed docs)
    const proMap = new Map(); // key = userId (UID) → merged data
    snapshot.forEach(doc => {
      const d = doc.data();
      const uid = d.userId || doc.id; // auto-ID docs have userId field; UID-keyed docs use doc.id
      if (!proMap.has(uid)) {
        proMap.set(uid, { ...d, _docId: doc.id });
      } else {
        // Merge: prefer whichever has email, newer specialties from UID-keyed doc
        const existing = proMap.get(uid);
        proMap.set(uid, {
          ...existing,
          ...d,
          email: existing.email || d.email, // keep email from whichever has it
          specialties: (d.specialties && d.specialties.length > 0) ? d.specialties : existing.specialties,
          areas: (d.areas && d.areas.length > 0) ? d.areas : existing.areas,
        });
      }
    });

    // For pros still missing email, try users collection
    const missingEmailUids = [...proMap.entries()].filter(([, d]) => !d.email).map(([uid]) => uid);
    if (missingEmailUids.length > 0) {
      await Promise.all(missingEmailUids.map(async uid => {
        try {
          const userDoc = await admin.firestore().collection('users').doc(uid).get();
          if (userDoc.exists) {
            const email = userDoc.data().email;
            if (email) {
              const d = proMap.get(uid);
              proMap.set(uid, { ...d, email });
            }
          }
        } catch (_) {}
      }));
    }

    const matching = [];
    proMap.forEach((d, uid) => {
      if (!d.email) return;
      // Μην ειδοποιείς τον ίδιο τον αιτούντα — μπορεί να είναι επαγγελματίας
      // με ειδικότητα που ταιριάζει με το δικό του αίτημα (π.χ. ο ίδιος
      // στέλνει αίτημα για "Συντήρηση Κλιματιστικών" ενώ έχει αυτή την
      // ειδικότητα στο προφίλ του).
      if (requesterUserId && uid === requesterUserId) return;

      // Match specialty — check both singular and array
      if (profLower) {
        const specialty = (d.specialty || '').toLowerCase();
        const specialties = Array.isArray(d.specialties) ? d.specialties.map(s => s.toLowerCase()) : [];
        const allSpecs = specialties.length > 0 ? specialties : (specialty ? [specialty] : []);
        if (allSpecs.length > 0) {
          // exactSpecialty (π.χ. αιτήματα εκδηλώσεων): μόνο ακριβές match,
          // ώστε ένας γενικός "Φωτογράφος" να ΜΗΝ ταιριάζει με
          // "Φωτογράφος Εκδηλώσεων" — μόνο όσοι έχουν δηλώσει ρητά τη
          // συγκεκριμένη ειδικότητα εκδήλωσης ειδοποιούνται.
          const matches = exactSpecialty
            ? allSpecs.some(s => s.trim() === profLower.trim())
            : allSpecs.some(s => s.includes(profLower) || profLower.includes(s));
          if (!matches) return;
        }
      }

      // Μαθήματα (καθηγητές/ιδιαίτερα): online καλύπτει όλη την Ελλάδα,
      // ανεξαρτήτως περιοχής — δια ζώσης συνεχίζει να κοιτάει την περιοχή
      // όπως πάντα. "both" σημαίνει: ειδοποίησε ΚΑΙ όσους δηλώνουν online
      // (οπουδήποτε) ΚΑΙ όσους ταιριάζουν με την περιοχή του αιτήματος.
      const proTeachingMode = d.teachingMode || 'in_person';
      const proCanOnline = proTeachingMode === 'online' || proTeachingMode === 'both';
      if (teachingMode === 'online' && !proCanOnline) return;
      const skipAreaForOnline = teachingMode === 'online' ||
          (teachingMode === 'both' && proCanOnline);

      // Match area — συνδυάζει το array (areas) ΚΑΙ το single πεδίο (area),
      // γιατί μπορεί να διαφέρουν (π.χ. το areas να μην έχει ενημερωθεί ποτέ
      // ενώ το area να είναι σωστό) — αγνοώντας μόνο ένα από τα δύο έχανε
      // πραγματικά matches.
      if (!skipAreaForOnline && locLower && locLower !== 'κοντά μου') {
        const areasArr = Array.isArray(d.areas) ? d.areas.map(a => a.toLowerCase()) : [];
        const areaSingle = (d.area || '').toLowerCase();
        const areas = areaSingle ? [...areasArr, areaSingle] : areasArr;
        // Sector match — πιάνει ΚΑΙ όσους δήλωσαν ρητά τον τομέα (π.χ. "Βόρεια
        // Προάστια"), ΚΑΙ όσους απλά δήλωσαν έναν συγκεκριμένο δήμο του ίδιου
        // τομέα (π.χ. κάποιος με μόνο "Χαλάνδρι" ταιριάζει και με αίτημα από
        // Κηφισιά, αφού είναι στον ίδιο τομέα) — έτσι δουλεύει αυτόματα και
        // για ήδη υπάρχοντες επαγγελματίες, χωρίς να χρειαστεί να ξαναδηλώσουν.
        const sectorOfRequest = AREA_TO_SECTOR[locLower];
        const sectorMatch = sectorOfRequest && areas.some(a =>
            a === sectorOfRequest || AREA_TO_SECTOR[a] === sectorOfRequest);
        if (areas.length > 0 && !sectorMatch &&
            !areas.some(a => a.includes(locLower) || locLower.includes(a))) return;
      }

      // Verified-only filter — πρέπει να έχει επιβεβαιωθεί πραγματικά από το
      // VIES (afmValid), όχι απλά να έχει γραφτεί κάποιο κείμενο στο πεδίο.
      if (filterVerifiedOnly && d.afmValid !== true) return;

      matching.push({ uid, email: d.email, phone: d.phone || '', name: d.displayName || d.name || 'Επαγγελματία' });
    });

    // Fetch FCM tokens for push notifications (batched)
    await Promise.all(matching.map(async p => {
      try {
        const userDoc = await admin.firestore().collection('users').doc(p.uid).get();
        p.fcmToken = userDoc.exists ? (userDoc.data().fcmToken || null) : null;
      } catch (_) { p.fcmToken = null; }
    }));

    if (matching.length === 0) {
      if (requestId) {
        try {
          await admin.firestore().collection('requests').doc(requestId).update({
            prosNotified: 0, notifiedProNames: [],
          });
        } catch (_) {}
      }
      return res.json({ success: true, sent: 0 });
    }

    const subject = `${urgent ? '🚨 ΕΠΕΙΓΟΝ — ' : ''}🔔 Νέο αίτημα${profession ? ` για ${profession}` : ''}${location ? ` — ${location}` : ''}`;
    const html = `
      <div style="font-family:Arial,sans-serif;max-width:480px;margin:0 auto;background:#0A0800;color:#fff;border-radius:16px;padding:32px;border:1px solid rgba(201,168,76,0.3)">
        ${urgent ? `<p style="display:inline-block;background:#ff4d4d;color:#fff;font-size:12px;font-weight:800;padding:4px 12px;border-radius:20px;margin-bottom:10px;">🚨 ΕΠΕΙΓΟΝ — απαντά μέσα σε 15 λεπτά</p>` : ''}
        <h1 style="color:#FFD47A;font-size:22px;margin-bottom:4px;">🔔 Νέο Αίτημα!</h1>
        ${profession ? `<p style="color:#C9A84C;font-size:15px;margin:4px 0;font-weight:700;">${profession}</p>` : ''}
        ${location ? `<p style="color:rgba(255,255,255,0.5);font-size:13px;margin:4px 0;">📍 ${location}</p>` : ''}
        ${description ? `<p style="color:rgba(255,255,255,0.7);font-size:14px;margin:16px 0;line-height:1.6;border-left:3px solid rgba(201,168,76,0.4);padding-left:12px;">${description.substring(0, 200)}</p>` : ''}
        <a href="https://gorealai.web.app/app" style="display:inline-block;margin-top:20px;padding:13px 28px;background:linear-gradient(135deg,#FFD47A,#C9A84C);color:#000;border-radius:12px;text-decoration:none;font-weight:800;font-size:14px;">Δες το αίτημα →</a>
        <p style="color:rgba(255,255,255,0.2);font-size:11px;margin-top:24px;">GorealPro · gorealai.web.app · info@gorealai.gr</p>
      </div>
    `;

    // Send email + SMS individually
    let sent = 0;
    const sentPros = [];
    for (const p of matching) {
      try {
        await sendEmail({ to: p.email, subject, html });
        sent++;
        sentPros.push(p.name);
      } catch (e) {
        console.error(`Email error for ${p.email}:`, e.message);
      }
      // Send SMS regardless of email success
      if (p.phone) {
        const smsText = `🔔 Νέο αίτημα GorealPro${profession ? ` για ${profession}` : ''}!\n${description ? description.substring(0, 100) : ''}\nΔες το: gorealai.web.app/app`;
        sendSms(p.phone, smsText); // fire-and-forget
      }
      // Push notification + in-app badge entry (fire-and-forget, doesn't block the loop)
      if (p.fcmToken) {
        const pushTitle = `${urgent ? '🚨 ΕΠΕΙΓΟΝ — ' : ''}🔔 Νέο αίτημα${profession ? ` για ${profession}` : ''}!`;
        const pushBody = description ? description.substring(0, 100) : 'Δες το αίτημα στην εφαρμογή';
        admin.messaging().send({
          token: p.fcmToken,
          notification: { title: pushTitle, body: pushBody },
          android: {
            priority: 'high',
            notification: { channelId: 'gorealai_channel', priority: 'high', sound: 'default', icon: 'ic_launcher', title: pushTitle, body: pushBody },
          },
          apns: { payload: { aps: { alert: { title: pushTitle, body: pushBody }, sound: 'default', badge: 1 } } },
          data: { type: 'new_request', requestId: requestId || '' },
        }).catch(e => console.error('new-request push error:', e.message));
      }
      admin.firestore().collection('users').doc(p.uid).collection('notifications').add({
        title: `${urgent ? '🚨 ΕΠΕΙΓΟΝ — ' : ''}🔔 Νέο αίτημα${profession ? ` για ${profession}` : ''}!`,
        body: description ? description.substring(0, 100) : '',
        isRead: false,
        type: 'new_request',
        requestId: requestId || '',
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      }).catch(() => {});
    }

    // Update request doc with who was notified
    if (requestId && sent > 0) {
      try {
        await admin.firestore().collection('requests').doc(requestId).update({
          prosNotified: sent,
          notifiedProNames: sentPros,
        });
      } catch (_) {}
    }

    console.log(`📧 New-request emails: ${sent}/${matching.length} sent (${profession} / ${location})`);
    res.json({ success: true, sent, total: matching.length, notified: sentPros });
  } catch (e) {
    console.error('email-pros-new-request error:', e.message);
    res.status(500).json({ error: e.message });
  }
});

// ── Report a user (block/report from chat) ────────────────────────
// POST /report-user
// Body: { reporterName, reportedName, reportedId, reason, chatId }
// Ο ίδιος ο report γράφεται απευθείας στο Firestore από το client — αυτό
// το endpoint στέλνει απλά ειδοποίηση email στον διαχειριστή, ώστε να μην
// χρειάζεται να ελέγχει χειροκίνητα τη συλλογή 'reports'.
app.post('/report-user', rateLimit(20, 60_000), async (req, res) => {
  const { reporterName, reportedName, reportedId, reason, chatId } = req.body;
  if (!zohoTransporter && !process.env.SENDGRID_API_KEY) return res.json({ success: false, reason: 'no email provider configured' });

  try {
    const html = `
      <div style="font-family:Arial,sans-serif;max-width:480px;margin:0 auto;background:#0A0800;color:#fff;border-radius:16px;padding:32px;border:1px solid rgba(220,53,69,0.4)">
        <h1 style="color:#ff6b6b;font-size:19px;margin-bottom:12px;">🚩 Νέα αναφορά χρήστη</h1>
        <p style="color:rgba(255,255,255,0.8);font-size:14px;line-height:1.7;">
          <strong>Ανέφερε:</strong> ${reporterName || 'N/A'}<br>
          <strong>Ανέφερε τον/την:</strong> ${reportedName || 'N/A'} (ID: ${reportedId || 'N/A'})<br>
          <strong>Λόγος:</strong> ${reason || 'N/A'}<br>
          <strong>Chat ID:</strong> ${chatId || 'N/A'}
        </p>
        <p style="color:rgba(255,255,255,0.4);font-size:12px;margin-top:20px;">Έλεγξε τη συλλογή 'reports' στο Firestore για πλήρη στοιχεία.</p>
      </div>
    `;
    await sendEmail({ to: 'info@gorealai.gr', subject: `🚩 Αναφορά χρήστη: ${reportedName || ''}`, html });
    res.json({ success: true });
  } catch (e) {
    console.error('report-user error:', e.message);
    res.status(500).json({ error: e.message });
  }
});

// POST /email-pro-new-message
// Body: { proId, senderName, messagePreview }
app.post('/email-pro-new-message', rateLimit(60, 60_000), async (req, res) => {
  const { proId, senderName, messagePreview } = req.body;
  if (!firebaseReady) return res.json({ success: false, reason: 'firebase not ready' });
  if (!proId) return res.json({ success: false, reason: 'missing proId' });

  try {
    // Find pro email: check professionals collection first, then users
    let proEmail = null;
    let proName = 'Επαγγελματία';

    let proPhone = null;
    const proDoc = await admin.firestore().collection('professionals').doc(proId).get();
    if (proDoc.exists) {
      proEmail = proDoc.data().email;
      proPhone = proDoc.data().phone || null;
      proName = proDoc.data().displayName || proDoc.data().name || proName;
    }
    if (!proEmail) {
      const q = await admin.firestore().collection('professionals').where('userId', '==', proId).limit(1).get();
      if (!q.empty) {
        proEmail = q.docs[0].data().email;
        proPhone = proPhone || q.docs[0].data().phone || null;
        proName = q.docs[0].data().displayName || q.docs[0].data().name || proName;
      }
    }
    if (!proEmail) {
      const userDoc = await admin.firestore().collection('users').doc(proId).get();
      if (userDoc.exists) {
        proEmail = userDoc.data().email;
        proPhone = proPhone || userDoc.data().phone || null;
        proName = userDoc.data().name || proName;
      }
    }

    if (!proEmail && !proPhone) return res.json({ success: false, reason: 'pro contact not found' });

    // Push notification + in-app badge entry
    try {
      const userDoc = await admin.firestore().collection('users').doc(proId).get();
      const fcmToken = userDoc.exists ? userDoc.data().fcmToken : null;
      const pushTitle = `💬 ${senderName || 'Νέο μήνυμα'}`;
      const pushBody = messagePreview ? String(messagePreview).substring(0, 100) : 'Νέο μήνυμα';
      if (fcmToken) {
        admin.messaging().send({
          token: fcmToken,
          notification: { title: pushTitle, body: pushBody },
          android: {
            priority: 'high',
            notification: { channelId: 'gorealai_channel', priority: 'high', sound: 'default', icon: 'ic_launcher', title: pushTitle, body: pushBody },
          },
          apns: { payload: { aps: { alert: { title: pushTitle, body: pushBody }, sound: 'default', badge: 1 } } },
          data: { type: 'chat_message' },
        }).catch(e => console.error('pro chat push error:', e.message));
      }
      admin.firestore().collection('users').doc(proId).collection('notifications').add({
        title: pushTitle, body: pushBody, isRead: false, type: 'chat_message',
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      }).catch(() => {});
    } catch (_) {}

    const subject = `💬 Νέο μήνυμα από ${senderName || 'χρήστη'}`;
    const html = `
      <div style="font-family:Arial,sans-serif;max-width:480px;margin:0 auto;background:#0A0800;color:#fff;border-radius:16px;padding:32px;border:1px solid rgba(201,168,76,0.3)">
        <h1 style="color:#FFD47A;font-size:22px;margin-bottom:4px;">💬 Νέο Μήνυμα!</h1>
        <p style="color:rgba(255,255,255,0.6);font-size:13px;margin:4px 0;">Από: <strong style="color:#FFD47A">${senderName || 'Χρήστης'}</strong></p>
        ${messagePreview ? `<p style="color:rgba(255,255,255,0.75);font-size:14px;margin:16px 0;line-height:1.6;border-left:3px solid rgba(201,168,76,0.4);padding-left:12px;">${String(messagePreview).substring(0, 200)}</p>` : ''}
        <a href="https://gorealai.web.app/app" style="display:inline-block;margin-top:20px;padding:13px 28px;background:linear-gradient(135deg,#FFD47A,#C9A84C);color:#000;border-radius:12px;text-decoration:none;font-weight:800;font-size:14px;">Απάντησε τώρα →</a>
        <p style="color:rgba(255,255,255,0.2);font-size:11px;margin-top:24px;">GorealPro · gorealai.web.app · info@gorealai.gr</p>
      </div>
    `;

    if (proEmail) await sendEmail({ to: proEmail, subject, html });
    if (proPhone) sendSms(proPhone, `💬 Νέο μήνυμα από ${senderName || 'χρήστη'} στο GorealPro!\n${messagePreview ? messagePreview.substring(0, 100) + '\n' : ''}Απάντησε: gorealai.web.app/app`);
    console.log(`📧📱 New-message notification to pro ${proId}`);
    res.json({ success: true });
  } catch (e) {
    console.error('email-pro-new-message error:', e.message);
    res.status(500).json({ error: e.message });
  }
});

// POST /email-user-new-message
// Body: { userId, proName, messagePreview }
app.post('/email-user-new-message', rateLimit(60, 60_000), async (req, res) => {
  const { userId, proName, messagePreview } = req.body;
  if (!firebaseReady) return res.json({ success: false, reason: 'firebase not ready' });
  if (!userId) return res.json({ success: false, reason: 'missing userId' });

  try {
    let userEmail = null;
    let userName = 'Χρήστη';

    let userPhone = null;
    const userDoc = await admin.firestore().collection('users').doc(userId).get();
    if (userDoc.exists) {
      userEmail = userDoc.data().email;
      userPhone = userDoc.data().phone || null;
      userName = userDoc.data().name || userName;
    }

    if (!userEmail && !userPhone) return res.json({ success: false, reason: 'user contact not found' });

    // Push notification + in-app badge entry
    try {
      const pushTitle = `💬 ${proName || 'Νέο μήνυμα'}`;
      const pushBody = messagePreview ? String(messagePreview).substring(0, 100) : 'Νέο μήνυμα';
      const fcmToken = userDoc.exists ? userDoc.data().fcmToken : null;
      if (fcmToken) {
        admin.messaging().send({
          token: fcmToken,
          notification: { title: pushTitle, body: pushBody },
          android: {
            priority: 'high',
            notification: { channelId: 'gorealai_channel', priority: 'high', sound: 'default', icon: 'ic_launcher', title: pushTitle, body: pushBody },
          },
          apns: { payload: { aps: { alert: { title: pushTitle, body: pushBody }, sound: 'default', badge: 1 } } },
          data: { type: 'chat_message' },
        }).catch(e => console.error('user chat push error:', e.message));
      }
      admin.firestore().collection('users').doc(userId).collection('notifications').add({
        title: pushTitle, body: pushBody, isRead: false, type: 'chat_message',
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      }).catch(() => {});
    } catch (_) {}

    const subject = `💬 Νέο μήνυμα από ${proName || 'επαγγελματία'}`;
    const html = `
      <div style="font-family:Arial,sans-serif;max-width:480px;margin:0 auto;background:#0A0800;color:#fff;border-radius:16px;padding:32px;border:1px solid rgba(201,168,76,0.3)">
        <h1 style="color:#FFD47A;font-size:22px;margin-bottom:4px;">💬 Νέο Μήνυμα!</h1>
        <p style="color:rgba(255,255,255,0.6);font-size:13px;margin:4px 0;">Από: <strong style="color:#FFD47A">${proName || 'Επαγγελματίας'}</strong></p>
        ${messagePreview ? `<p style="color:rgba(255,255,255,0.75);font-size:14px;margin:16px 0;line-height:1.6;border-left:3px solid rgba(201,168,76,0.4);padding-left:12px;">${String(messagePreview).substring(0, 200)}</p>` : ''}
        <a href="https://gorealai.web.app/app" style="display:inline-block;margin-top:20px;padding:13px 28px;background:linear-gradient(135deg,#FFD47A,#C9A84C);color:#000;border-radius:12px;text-decoration:none;font-weight:800;font-size:14px;">Απάντησε τώρα →</a>
        <p style="color:rgba(255,255,255,0.2);font-size:11px;margin-top:24px;">GorealPro · gorealai.web.app · info@gorealai.gr</p>
      </div>
    `;

    if (userEmail) await sendEmail({ to: userEmail, subject, html });
    if (userPhone) sendSms(userPhone, `💬 Νέο μήνυμα από ${proName || 'επαγγελματία'} στο GorealPro!\n${messagePreview ? messagePreview.substring(0, 100) + '\n' : ''}Απάντησε: gorealai.web.app/app`);
    console.log(`📧📱 New-message notification to user ${userId}`);
    res.json({ success: true });
  } catch (e) {
    console.error('email-user-new-message error:', e.message);
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

// ── Platform stats (πόσοι κατέβασαν από Play Store vs web) ──────────
// GET /platform-stats
app.get('/platform-stats', async (req, res) => {
  if (!firebaseReady) return res.status(503).json({ error: 'Firebase not ready' });
  try {
    const snap = await admin.firestore().collection('users').get();

    // "Σήμερα" σε ώρα Ελλάδας (UTC+3 EEST) — μετατροπή σε UTC για σύγκριση.
    const GREECE_OFFSET_MS = 3 * 60 * 60 * 1000;
    const nowGreece = new Date(Date.now() + GREECE_OFFSET_MS);
    const startOfTodayGreece = Date.UTC(nowGreece.getUTCFullYear(), nowGreece.getUTCMonth(), nowGreece.getUTCDate());
    const startOfTodayUTC = new Date(startOfTodayGreece - GREECE_OFFSET_MS);

    const stats = {
      androidTotal: 0, webTotal: 0, unknownTotal: 0,
      androidToday: 0, webToday: 0,
      androidUsers: 0, androidPros: 0,
      androidUsersToday: 0, androidProsToday: 0,
    };

    snap.forEach((doc) => {
      const d = doc.data();
      const createdAt = d.createdAt && d.createdAt.toDate ? d.createdAt.toDate() : null;
      const isToday = createdAt && createdAt >= startOfTodayUTC;
      const isPro = d.role === 'professional';

      if (d.platform === 'android') {
        stats.androidTotal++;
        if (isToday) stats.androidToday++;
        if (isPro) { stats.androidPros++; if (isToday) stats.androidProsToday++; }
        else { stats.androidUsers++; if (isToday) stats.androidUsersToday++; }
      } else if (d.platform === 'web') {
        stats.webTotal++;
        if (isToday) stats.webToday++;
      } else {
        stats.unknownTotal++;
      }
    });

    res.json(stats);
  } catch (e) {
    console.error('platform-stats error:', e.message);
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

// ── Debug: check why a pro didn't get email ──────────────────────
// GET /debug-pro/:uid?profession=X&location=Y
app.get('/debug-pro/:uid', async (req, res) => {
  const { uid } = req.params;
  const profession = req.query.profession || '';
  const location = req.query.location || '';
  if (!firebaseReady) return res.json({ error: 'firebase not ready' });
  try {
    const profLower = profession.toLowerCase();
    const locLower = location.toLowerCase();

    // Get UID-keyed doc
    const uidDoc = await admin.firestore().collection('professionals').doc(uid).get();
    const uidData = uidDoc.exists ? uidDoc.data() : null;

    // Get auto-ID doc (by userId field)
    const autoSnap = await admin.firestore().collection('professionals').where('userId', '==', uid).limit(1).get();
    const autoData = autoSnap.empty ? null : autoSnap.docs[0].data();

    // Get users doc
    const userDoc = await admin.firestore().collection('users').doc(uid).get();
    const userData = userDoc.exists ? userDoc.data() : null;

    const merged = { ...(autoData || {}), ...(uidData || {}) };
    const email = merged.email || autoData?.email || userData?.email || null;
    const specialties = merged.specialties || autoData?.specialties || [];
    const specialty = merged.specialty || autoData?.specialty || '';
    const areas = merged.areas || autoData?.areas || [];

    const allSpecs = specialties.length > 0 ? specialties : (specialty ? [specialty] : []);
    const specMatch = !profLower || allSpecs.length === 0 || allSpecs.some(s => s.toLowerCase().includes(profLower) || profLower.includes(s.toLowerCase()));
    const areaMatch = !locLower || locLower === 'κοντά μου' || areas.length === 0 || areas.some(a => a.toLowerCase().includes(locLower) || locLower.includes(a.toLowerCase()));

    res.json({
      uid,
      hasEmail: !!email,
      email: email ? email.replace(/(.{2}).*(@.*)/, '$1***$2') : null,
      specialties,
      specialty,
      areas,
      specMatch,
      areaMatch,
      wouldReceive: !!email && specMatch && areaMatch,
      uidDocExists: uidDoc.exists,
      autoDocExists: !autoSnap.empty,
      userDocExists: userDoc.exists,
    });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ── Request-expiry notification (fires once, exactly when the 1h countdown ends) ──
async function sendExpiryNotification(requestId) {
  if (!firebaseReady) return;
  try {
    const ref = admin.firestore().collection('requests').doc(requestId);
    const doc = await ref.get();
    if (!doc.exists) return;
    const d = doc.data();
    if (d.expiryNotified) return; // already sent
    if (d.status === 'completed') return; // ο πελάτης διάλεξε ήδη επαγγελματία, το ξέρει
    if (d.status === 'cancelled') return; // ο πελάτης το ακύρωσε μόνος του, δεν χρειάζεται ειδοποίηση

    await ref.update({ expiryNotified: true });

    const offersCount = d.offersCount || 0;
    const found = offersCount > 0;
    const userId = d.userId;
    if (!userId) return;

    let userEmail = null, fcmToken = null, userPhone = null, userName = d.userName || 'Χρήστη';
    try {
      const userDoc = await admin.firestore().collection('users').doc(userId).get();
      if (userDoc.exists) {
        fcmToken = userDoc.data().fcmToken || null;
        userPhone = userDoc.data().phone || null;
        userName = userDoc.data().name || userName;
      }
    } catch (_) {}
    try {
      const authUser = await admin.auth().getUser(userId);
      userEmail = authUser.email || null;
    } catch (_) {}

    const title = found ? '✅ Βρέθηκε επαγγελματίας!' : '😕 Δεν βρέθηκε επαγγελματίας';
    const body = found
      ? `Έλαβες ${offersCount} προσφορά${offersCount > 1 ? 'ές' : ''} για το αίτημά σου!`
      : 'Δυστυχώς δεν βρέθηκε διαθέσιμος επαγγελματίας αυτή τη στιγμή. Δοκίμασε ξανά αργότερα.';

    if (userEmail) {
      try {
        await sendEmail({
          to: userEmail,
          subject: title,
          html: `
            <div style="font-family:Arial,sans-serif;max-width:480px;margin:0 auto;background:#0A0800;color:#fff;border-radius:16px;padding:32px;border:1px solid rgba(201,168,76,0.3)">
              <h1 style="color:#FFD47A;font-size:22px;margin-bottom:4px;">${title}</h1>
              <p style="color:rgba(255,255,255,0.75);font-size:14px;line-height:1.6;">Γεια σου <strong>${userName}</strong>,</p>
              <p style="color:rgba(255,255,255,0.75);font-size:14px;line-height:1.6;">${body}</p>
              <a href="https://gorealai.web.app/app" style="display:inline-block;margin-top:20px;padding:13px 28px;background:linear-gradient(135deg,#FFD47A,#C9A84C);color:#000;border-radius:12px;text-decoration:none;font-weight:800;font-size:14px;">Άνοιξε την εφαρμογή →</a>
              <p style="color:rgba(255,255,255,0.2);font-size:11px;margin-top:24px;">GorealPro · gorealai.web.app · info@gorealai.gr</p>
            </div>
          `,
        });
      } catch (e) { console.error('expiry email error:', e.message); }
    }

    if (fcmToken) {
      try {
        await admin.messaging().send({
          token: fcmToken,
          notification: { title, body },
          android: {
            priority: 'high',
            notification: { channelId: 'gorealai_channel', priority: 'high', sound: 'default', icon: 'ic_launcher', title, body, notificationCount: 1 },
          },
          apns: { payload: { aps: { alert: { title, body }, sound: 'default', badge: 1 } } },
        });
      } catch (e) { console.error('expiry push error:', e.message); }
    }
    if (userPhone) {
      try {
        await sendSms(userPhone, `GorealPro: ${title.replace(/[✅😕]/g, '').trim()} ${body}`);
      } catch (e) { console.error('expiry SMS error:', e.message); }
    }
    try {
      await admin.firestore().collection('users').doc(userId).collection('notifications').add({
        title, body, isRead: false, type: 'offers_ready', requestId,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } catch (_) {}
    console.log(`⏰ Expiry notification sent for request ${requestId} (found=${found}, offers=${offersCount})`);
  } catch (e) {
    console.error('sendExpiryNotification error:', e.message);
  }
}

// POST /schedule-expiry-notification
// Body: { requestId }
// Καλείται μία φορά, τη στιγμή που δημιουργείται το αίτημα. Προγραμματίζει
// έναν timer που θα εκτελεστεί ΑΚΡΙΒΩΣ όταν λήξει η 1ωρη προθεσμία — όχι
// επαναλαμβανόμενο polling.
app.post('/schedule-expiry-notification', rateLimit(30, 60_000), async (req, res) => {
  const { requestId } = req.body;
  if (!requestId || !firebaseReady) return res.json({ success: false });
  try {
    const doc = await admin.firestore().collection('requests').doc(requestId).get();
    if (!doc.exists) return res.json({ success: false, reason: 'request not found' });
    const expiresAt = doc.data().expiresAt;
    const delayMs = expiresAt ? Math.max(0, expiresAt.toMillis() - Date.now()) : 0;
    setTimeout(() => sendExpiryNotification(requestId), delayMs);
    res.json({ success: true, delayMs });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ── Rehydrate expiry timers on boot ──────────────────────────────
// Οι setTimeout ζουν μόνο στη μνήμη του process — αν ο server κάνει restart
// (νέο deploy, redeploy από Render κ.λπ.) ενώ κάποιο αίτημα μετράει ακόμα,
// ο προγραμματισμένος timer χάνεται. Αυτή η συνάρτηση τρέχει ΜΙΑ φορά στο
// ξεκίνημα (όχι επαναλαμβανόμενο polling) και είτε ξαναπρογραμματίζει τον
// timer για ό,τι έχει μείνει, είτε στέλνει αμέσως όσα έχουν ήδη λήξει.
async function rehydrateExpiryTimers() {
  if (!firebaseReady) return;
  try {
    const snap = await admin.firestore().collection('requests').where('status', '==', 'active').get();
    let rescheduled = 0, firedNow = 0;
    snap.forEach(doc => {
      const d = doc.data();
      if (d.expiryNotified || !d.expiresAt) return;
      const delayMs = d.expiresAt.toMillis() - Date.now();
      if (delayMs <= 0) {
        firedNow++;
        sendExpiryNotification(doc.id);
      } else {
        rescheduled++;
        setTimeout(() => sendExpiryNotification(doc.id), delayMs);
      }
    });
    console.log(`⏰ Expiry timers rehydrated on boot: ${rescheduled} rescheduled, ${firedNow} fired immediately`);
  } catch (e) {
    console.error('rehydrateExpiryTimers error:', e.message);
  }
}
rehydrateExpiryTimers();


// ── TEMP wave-2 outreach blast (fixed recipients/message, removed right after use) ──
let _wave2Status = { total: 0, sent: 0, done: false };
app.post('/_oneoff-wave2-sms', async (req, res) => {
  const message = "Καλησπέρα σας. Ονομάζομαι Μποσινακος Κώστας και μαζί με την ομάδα μου δημιουργήσαμε μια εφαρμογή καινοτόμα στον χώρο εύρεσης επαγγελματια απο τον ενδιαφερόμενο. Πήρα το θάρρος να σας στείλω το παρόν μήνυμα αν θέλετε και εσείς να μας βοηθήσετε στον αγώνα μας, κατεβάζοντας την εφαρμογή απο το Playstore με το όνομα Gorealpro. Η εγγραφή είναι δωρεάν καθώς και οι μηνιαίες συνδρομές έως τέλος του έτους. θεωρώ πως στην παρούσα χρονική περίοδο δεν έχετε κάτι να χάσετε αλλά μόνο να κερδίσετε. προς διευκόλυνσή σας σας παραθέτω το link.  http://play.google.com/store/apps/details?id=gr.gorealai.app . θα χαρούμε ιδιαιτέρως να μας βαθμολογήσετε στο Playstore γράφοντας μια κριτική και ενα rating. σας ευχαριστώ πολύ . Η ομάδα του Gorealpro.   email: info@gorealai.gr";
  const recipients = [{"name":"EXCOM","phone":"6987614306"},{"name":"ΔΑΝΙΗΛΙΔΗΣ ΙΩΑΝΝΗΣ","phone":"6972324797"},{"name":"SFYRISYSTEM","phone":"6945508638"},{"name":"ΔΑΜΙΑΝΑΚΗ ΣΥΝΘΕΤΙΚΑ ΚΟΥΦΩΜΑΤΑ ΙΚΕ","phone":"6947539183"},{"name":"THERMOACTIVE ΚΑΡΑΣΑΚΑΛΙΔΗΣ","phone":"6975899222"},{"name":"ALUMINIUM ADAMOPOULOS","phone":"6972144200"},{"name":"ΦΙΛΙΠΠΑΣ ΠΑΝΑΓΙΩΤΗΣ","phone":"6937042388"},{"name":"ALU-SYN Ε.Π.Ε.","phone":"6979808320"},{"name":"ΕΥΡΩΣΥΝ","phone":"6974364182"},{"name":"ALDEKO SYSTEMS","phone":"6909280540"},{"name":"TENTOPLUS","phone":"6937221655"},{"name":"GIANNOULAS A.","phone":"6947608445"},{"name":"ALUTEC","phone":"6989226885"},{"name":"ΑΝΔΡΕΑΔΑΚΗΣ ΙΚΕ","phone":"6974942650"},{"name":"KOUFOMA","phone":"6944515404"},{"name":"ΚΑΛΟΥΣΗΣ ΚΩΝΣΤΑΝΤΙΝΟΣ","phone":"6983431473"},{"name":"FINSTRAL AG","phone":"6973719009"},{"name":"FIN - PORT","phone":"6973734961"},{"name":"ΦΙΛΙΠΠΑΤΟΣ ΕΥΑΓΓΕΛΟΣ","phone":"6937104030"},{"name":"ΠΟΥΛΙΑΚΑΣ ΓΕΩΡΓΙΟΣ","phone":"6974868218"},{"name":"EXALCO ΚΟΥΛΗΣ","phone":"6947520879"},{"name":"NEW PROFIL","phone":"6981009590"},{"name":"ΦΥΛΤΖΑΝΙΔΗΣ Α. Γ.","phone":"6944693403"},{"name":"ALUMINCO - ΚΑΤΣΟΥΛΗΣ ΚΩΝΣΤΑΝΤΙΝΟΣ","phone":"6955189959"},{"name":"SYNTHESIS","phone":"6948059555"},{"name":"ΚΩΣΤΟΠΟΥΛΟΣ ΙΩΑΝΝΗΣ","phone":"6974337207"},{"name":"ΜΠΑΪΡΑΚΤΑΡΗΣ Α. ΝΙΚΟΛΑΟΣ","phone":"6945505905"},{"name":"ALUPLAST - ΠΑΠΑΔΑΚΗΣ - ΓΡΑΜΜΑΤΙΚΟΣ Ο.Ε.","phone":"6974883752"},{"name":"ΑΛΜΠΑΝΙΔΗΣ","phone":"6941661847"},{"name":"ΛΙΑΚΟΣ ΠΑΝΑΓΙΩΤΗΣ","phone":"6973185812"},{"name":"ΓΚΑΪΤΑΤΖΗΣ ΜΑΡΙΟΣ","phone":"6944448947"},{"name":"EUROLINE","phone":"6943712553"},{"name":"ΟΙΚΟΝΟΜΟΥ ΧΡΗΣΤΟΣ","phone":"6938191225"},{"name":"MINOAS DOORS - ΜΑΝΙΑΣ ΓΕΩΡΓΙΟΣ - ΠΑΡΑΓΙΟΥΔΑΚΗ ΜΑΡΙΛΕΝΑ Ι.Κ.Ε","phone":"6972419926"},{"name":"THANOSDOORS","phone":"6977767238"},{"name":"ΤΡΑΤΣΑΣ ΑΓΓΕΛΟΣ","phone":"6984949337"},{"name":"FIX IT GROUP","phone":"6940206906"},{"name":"ΘΩΡΑΚΙΣΗ - ΧΑΤΖΗΑΝΤΩΝΙΑΔΗΣ ΝΙΚΟΛΑΟΣ","phone":"6936886230"},{"name":"MODALUMIN","phone":"6977433547"},{"name":"ΚΑΡΠΟΥΖΑΣ Σ. ΙΩΑΝΝΗΣ","phone":"6972125119"},{"name":"ΔΕΛΗΛΑΜΠΑΚΗΣ ΧΡΗΣΤΟΣ","phone":"6932536144"},{"name":"ΑΓΓΕΛΟΣ ΚΩΝΣΤΑΝΤΙΝΟΣ","phone":"6937090542"},{"name":"ΥΔΡΑΙΟΣ ΝΙΚΟΛΑΟΣ - Κύμη","phone":"6986322559"},{"name":"ΚΕΡΒΑΝΙΔΗΣ","phone":"6972002951"},{"name":"ΣΕΡΓΙΑΔΗΣ ΑΠΟΣΤΟΛΟΣ","phone":"6948888807"},{"name":"DIALCO","phone":"6932754321"},{"name":"ΔΡΟΣΟΣ ΚΩΝΣΤΑΝΤΙΝΟΣ - Αμπελόκηποι","phone":"6932450860"},{"name":"ΜΠΑΛΑΟΥΡΑΣ ΘΕΟΔΩΡΟΣ","phone":"6948627250"},{"name":"XATZHKLEIDARAS DOORS","phone":"6979673255"},{"name":"ΓΟΓΟΝΙΔΑΚΗΣ ΝΙΚΟΛΑΟΣ Α.Β.Ε.Ε.","phone":"6944533425"},{"name":"ΝΟΥΣΚΑΛΗΣ ΑΘΑΝΑΣΙΟΣ","phone":"6945290219"},{"name":"ΔΙΑΜΑΝΤΟΠΟΥΛΟΣ Ε.","phone":"6936778131"},{"name":"ΜΕΛΕΤΗΣ ΒΑΣΙΛΕΙΟΣ","phone":"6973797082"},{"name":"ΚΑΡΑΦΥΛΛΙΔΗΣ ΧΡΗΣΤΟΣ - Ορεστιάδα","phone":"6944144133"},{"name":"DOMES DESIGN","phone":"6944332234"},{"name":"ΜΟΥΣΤΑΚΗΣ - ΤΣΕΛΙΓΚΑΣ","phone":"6944297229"},{"name":"DORAL - ΚΩΝΣΤΑΝΤΑΚΗΣ ΦΩΤΗΣ","phone":"6937414300"},{"name":"ΠΑΠΑΧΡΙΣΤΟΔΟΥΛΟΥ ΦΩΤΙΟΣ","phone":"6937094420"},{"name":"ROLA.GR - FOURKOS","phone":"6999977200"},{"name":"ΜΠΟΜΠΟΥΔΗΣ ΧΡΗΣΤΟΣ Σ.","phone":"6977270043"},{"name":"ALUTRUST - ΚΥΡΙΜΛΙΔΗΣ ΔΗΜ. ΒΑΣΙΛΕΙΟΣ","phone":"6944479765"},{"name":"RODITIS-GLASS","phone":"6970024385"},{"name":"ΧΡΙΣΤΟΦΗΣ ΝΕΚΤΑΡΙΟΣ","phone":"6947575450"},{"name":"ΠΑΠΑΓΙΑΝΝΙΔΗ ΑΦΟΙ ΟΕ","phone":"6947444178"},{"name":"ΒΕΡΓΟΠΟΥΛΟΣ ΝΙΚΟΛΑΟΣ & ΣΙΑ Ο.Ε.","phone":"6936980623"},{"name":"ΕΠΑΛ Ο.Ε. - ΤΣΑΚΙΡΗΣ Μ. & ΣΙΑ Ο.Ε.","phone":"6978483040"},{"name":"ALU PORT","phone":"6945954715"},{"name":"ΣΑΡΗΓΙΑΝΝΙΔΗΣ ΣΩΤΗΡΙΟΣ","phone":"6938180829"},{"name":"ΠΑΠΑΔΟΠΟΥΛΟΣ ΘΟΔΩΡΗΣ","phone":"6947706155"},{"name":"SALTAS SYSTEM - ΣΑΛΤΑΣ ΔΗΜΗΤΡΙΟΣ Γ.","phone":"6974732142"},{"name":"MARKAL","phone":"6944543753"},{"name":"ΣΑΠΟΥΝΑΣ CONSTRUCTIONS","phone":"6948252682"},{"name":"KUNSTSTOFF SYSTEMS","phone":"6973697526"},{"name":"STABIL PROTECTA","phone":"6977985234"},{"name":"ΧΑΡΙΣΗΣ ΝΙΚΟΛΑΟΣ - Άρτα","phone":"6932253594"},{"name":"ΑΛΟΥΜΕΤΑΛ ΚΑΤΑΣΚΕΥΑΣΤΙΚΗ","phone":"6972496025"},{"name":"ΜΑΝΓΚΤΖΙΤ ΣΙΝΓΚ ΠΕΤΡΟΣ","phone":"6974624412"},{"name":"ALUFIX SYSTEMS EE","phone":"6973662954"},{"name":"CMS ΜΗΖΥΘΡΑΣ Χ. - ΜΗΖΥΘΡΑΣ Σ. Ο.Ε.","phone":"6932721531"},{"name":"ΜΟΥΤΑΣ ΣΤΕΡΓΙΟΣ Α.","phone":"6932742568"},{"name":"ΚΥΚΟΣ ΧΡΙΣΤΟΔΟΥΛΟΣ","phone":"6973554292"},{"name":"ΠΙΤΣΙΝΟΣ ΙΩΑΝΝΗΣ","phone":"6972006053"},{"name":"ΣΟΡΟΛΟΠΗΣ ΣΩΚΡΑΤΗΣ","phone":"6937158355"},{"name":"EURALUMIN","phone":"6975125522"},{"name":"ΚΑΡΡΑ ΑΦΟΙ ΟΕ","phone":"6946064364"},{"name":"ΠΑΝΑΓΙΩΤΙΔΗΣ ΧΑΡΑΛΑΜΠΟΣ","phone":"6945238439"},{"name":"ALUTECH - Ιεράπετρα","phone":"6947427247"},{"name":"Η ΕΜΠΕΙΡΙΑ","phone":"6949448432"},{"name":"TECH SYSTEMS ALUMINIUM","phone":"6946318120"},{"name":"ΑΛΟΥΜΙΝΟΤΕΧΝΙΚΗ","phone":"6932161880"},{"name":"ΚΑΤΑΣΚΕΥΑΣΤΙΚΗ","phone":"6982444100"},{"name":"ΚΩΝΣΤΑΝΤΙΝΙΔΗΣ ΜΙΧΑΗΛ - Κατερίνη","phone":"6938444205"},{"name":"ΚΩΝΣΤΑΝΤΗΣ ΛΑΜΠΡ. ΔΗΜΗΤΡΙΟΣ","phone":"6977710903"},{"name":"ΕΜΠΟΡΟΔΟΜΗ","phone":"6944647360"},{"name":"MODA CUCINA","phone":"6946235050"},{"name":"ALPLAN - ΤΖΑΓΚΑΡΑΚΗΣ ΓΕΩΡΓΙΟΣ","phone":"6947580635"},{"name":"CENTRO DESIGN","phone":"6972693356"},{"name":"ΣΤΟΥΛΗΣ ΙΩΑΝΝΗΣ & ΠΑΝΑΓΙΩΤΗΣ ΟΕ","phone":"6936648382"},{"name":"ALFA PORTA - ΣΤΑΘΗΣ ΚΩΝΣΤΑΝΤΙΝΟΣ","phone":"6942664572"},{"name":"AREDI HOME SOLUTIONS - ΔΑΣΚΑΛΟΠΟΥΛΟΣ ΓΕΩΡΓΙΟΣ","phone":"6975861807"},{"name":"ΓΕΛΑΔΑΡΗΣ ΑΘ. ΣΩΤΗΡΗΣ - ΑΛΟΥΞΥΛ","phone":"6977645793"},{"name":"METAL CONSTRUCTION","phone":"6945360304"},{"name":"METALCORE ΟΕ","phone":"6945290756"},{"name":"ΜΕΤΑΛΛΟΝ - ΜΠΟΖΙΝΗΣ ΧΡΗΣΤΟΣ","phone":"6944787548"},{"name":"ROAL - ΑΝΑΣΤΑΣΑΚΗΣ ΚΩΝ/ΝΟΣ & ΥΙΟΙ ΑΒΕΕ","phone":"6984700083"},{"name":"ΟΜΙΚΡΟΝ ΜΗΧΑΝΙΚΗ & ΚΑΤΑΣΚΕΥΑΣΤΙΚΗ","phone":"6980934000"},{"name":"ΠΑΛΛΑ ΑΦΟΙ ΟΕ","phone":"6932567683"},{"name":"SIDIROMORFES","phone":"6977349838"},{"name":"ΑΣΠΡΟΚΟΥΤΕΛΑΚΗΣ Α.Β.Ε.","phone":"6972226026"},{"name":"ΤΣΟΠΕΛΑΣ ΜΠΑΜΠΗΣ","phone":"6982035078"},{"name":"ΤΣΟΠΕΛΑΣ ΜΠΑΜΠΗΣ","phone":"6986505660"},{"name":"ΒΕΡΟΥΤΑΣ ΚΑΤΑΣΚΕΥΕΣ ΑΛΟΥΜΙΝΙΟΥ Ι.Κ.Ε.","phone":"6949171378"},{"name":"ASKOMET - ΑΣΚΟΞΥΛΑΚΗ ΑΦΟΙ ΑΕ","phone":"6944398511"},{"name":"ΣΥΡΜΑ ΜΟΝΟΠΡΟΣΩΠΗ Ε.Π.Ε.","phone":"6974998758"},{"name":"IWC CONSTRUCTION","phone":"6932707622"},{"name":"POLYZAKIS CONSTRUCTIONS I.K.E.","phone":"6943248509"},{"name":"ΒΙΟΜΕΚ ΞΑΝΘΗΣ","phone":"6945909941"},{"name":"ΚΩΣΤΟΓΛΑΚΗΣ ΑΝΤΩΝΙΟΣ","phone":"6939720924"},{"name":"ALKOSTEEL","phone":"6973833558"},{"name":"TECHNOPOLIS24","phone":"6907285489"},{"name":"ΓΟΛΙΑΘ - ΜΑΘΙΟΥΔΑΚΗΣ ΚΩΝΣΤΑΝΤΙΝΟΣ","phone":"6943154956"},{"name":"ART OF METAL - ΤΣΕΧΟΥ ΕΜΒΕΡ","phone":"6936668554"},{"name":"Τ.Ε.Κ. Ο.Ε. - ΖΛΑΤΙΝΗΣ Ι. & ΣΙΑ Ο.Ε.","phone":"6936746457"},{"name":"METAL GLASS CORINTHIA","phone":"6934638543"},{"name":"ΜΥΪΣΛΗ ΜΠΕΚΙΡ","phone":"6946328896"},{"name":"E-KARYSTINOS","phone":"6983444918"},{"name":"ERGOMAS - ΣΚΕΠΑΡΝΗΣ ΑΛΕΞΑΝΔΡΟΣ","phone":"6937274918"},{"name":"ΑΡΒΑΝΙΤΗΣ ΔΗΜΗΤΡΗΣ - ΗΦΑΙΣΤΟΣ","phone":"6934827817"},{"name":"ΣΑΛΟΝΙΚΙΔΗΣ","phone":"6979551557"},{"name":"ΦΟΥΝΤΟΥΚΙΔΗΣ ΑΝΑΣΤΑΣΙΟΣ","phone":"6977740286"},{"name":"ΚΩΣΤΟΓΛΟΥ","phone":"6958479280"},{"name":"ΚΥΡΙΑΚΙΔΗΣ ΜΑΚΗΣ","phone":"6946306311"},{"name":"PURE INOX","phone":"6948608644"},{"name":"COATINGS AND CONSTRUCTIONS","phone":"6970015117"},{"name":"NS METAL BOX","phone":"6974701859"},{"name":"ΚΩΝΣΤΑΝΤΟΥΡΟΣ ΘΕΟΔΩΡΟΣ","phone":"6989683046"},{"name":"ΜΑΜΑΓΚΕΪΣΒΙΛΙ ΑΛΕΚΟΣ","phone":"6906972007"},{"name":"ΑΝΤΩΝΑΚΟΣ ΚΑΤΑΣΚΕΥΑΣΤΙΚΗ","phone":"6942952257"},{"name":"ΑΝΤΩΝΑΚΟΣ ΚΑΤΑΣΚΕΥΑΣΤΙΚΗ","phone":"6942015460"},{"name":"ΜΕΤΑΛΛΙΚΕΣ ΔΗΜΙΟΥΡΓΙΕΣ","phone":"6973989254"},{"name":"ΣΑΠΟΥΝΑΣ ΡΑΦΑΗΛ","phone":"6972147942"},{"name":"MALKO VAGELIS","phone":"6987217159"},{"name":"ΚΡΕΜΑΣΤΑΣ ΓΙΩΡΓΟΣ","phone":"6980469755"},{"name":"ΜΑΤΕΡΗΣ ΝΙΚΟΛΑΟΣ","phone":"6974642126"},{"name":"ΜΑΤΕΡΗΣ ΝΙΚΟΛΑΟΣ","phone":"6972247851"},{"name":"ΝΤΕΛΗΣ ΝΙΚΟΛΑΟΣ","phone":"6975300263"},{"name":"METALS ART","phone":"6944588820"},{"name":"ΣΙΔΗΡΟΚΑΤΑΣΚΕΥΕΣ ΔΕΡΒΕΝΗΣ","phone":"6945776406"},{"name":"ΣΙΔΗΡΟΚΑΤΑΣΚΕΥΕΣ ΔΕΡΒΕΝΗΣ","phone":"6972677818"},{"name":"TECHNICAL IRONWORK GROWTH T.I.G","phone":"6970193017"},{"name":"ΖΩΙΔΑΚΗΣ ΓΕΩΡΓΙΟΣ","phone":"6981128724"},{"name":"RN CONSTRACTIONS","phone":"6948625768"},{"name":"ΚΟΡΟΜΗΛΑΣ ΑΣΤΕΡΙΟΣ","phone":"6974049739"},{"name":"ΜΕΤΑΛΛΟΔΟΜΙΚΗ ΚΕΡΚΥΡΑΣ ΜΟΝΟΠΡΟΣΩΠΗ ΙΚΕ","phone":"6944424497"},{"name":"METKAM","phone":"6949235173"},{"name":"ΒΟΥΤΣΙΝΟΣ ΜΕΤΑΛΛΙΚΕΣ ΚΑΤΑΣΚΕΥΕΣ ΒΙΟΜΗΧΑΝΙΚΕΣ ΕΓΚΑΤΑΣΤΑΣΕΙΣ","phone":"6907911779"},{"name":"LP FORGE LINE","phone":"6986661427"},{"name":"E-JET","phone":"6945599801"},{"name":"ΤΕΧΝΙΚΗ ΜΗΧΑΝΙΚΗ ΕΠΕ","phone":"6973335910"},{"name":"ΑΛΩΝΙΑΤΗΣ ΙΩΑΝΝΗΣ & ΥΙΟΙ ΟΕ","phone":"6947071949"},{"name":"Ο ΚΡΗΤΙΚΟΣ","phone":"6945768354"},{"name":"ME.C.AL - ΜΠΑΚΑΛΑΡΟΣ ΝΙΚΟΣ","phone":"6936803556"},{"name":"METALDESIGN","phone":"6942467996"},{"name":"METALDESIGN","phone":"6977240771"},{"name":"ΜΑΤΖΙΑΡΗΣ ΧΡΗΣΤΟΣ","phone":"6977868162"},{"name":"ΜΕΤΑΛΛΟΜΟΡΦΗ","phone":"6972003775"},{"name":"ΜΑΡΑΝΤΙΔΗΣ ΛΕΩΝΙΔΑΣ","phone":"6932266531"},{"name":"ΠΑΝΑΓΙΩΤΟΠΟΥΛΟΙ ΑΦΟΙ - GP METAL","phone":"6971549795"},{"name":"ΣΑΚΟΥΛΑΣ ΙΩΑΝΝΗΣ","phone":"6947991509"},{"name":"ΤΕΧΝΟΜΕΤΑΛ ΑΡΚΑΔΙΑΣ - ΨΑΡΟΛΟΓΟΣ ΗΛΙΑΣ","phone":"6931516889"},{"name":"STEELTECH ΚΑΡΚΑΛΗΣ ΧΡΗΣΤΟΣ - ΚΑΒΟΥΡΙΔΗΣ ΓΙΩΡΓΗΣ","phone":"6972325672"},{"name":"ΒΑΣΙΛΟΠΟΥΛΟΣ ΚΥΡΙΛΛΟΣ","phone":"6957786515"},{"name":"ΜΩΡΑΪΤΗ ΑΦΟΙ Ο.Ε.","phone":"6974799089"},{"name":"ΔΕΜΕΡΤΖΗΣ ΠΑΣΧΑΛΗΣ","phone":"6936554497"},{"name":"ART METAL DESIGN","phone":"6977801009"},{"name":"ΠΕΝΤΙΦΡΑΓΚΑΣ ΒΑΣΙΛΕΙΟΣ","phone":"6972058698"},{"name":"ΣΙΔΗΡΟΚΑΤΑΣΚΕΥΕΣ - ΜΑΡΑΓΚΟΣ ΕΜΜ. ΝΕΚΤΑΡΙΟΣ","phone":"6945228850"},{"name":"ΑΡΓΥΡΟΣ ΑΘΑΝΑΣΙΟΣ - Βιομηχανική Περιοχή Πρέβεζας","phone":"6932379332"},{"name":"ΜΑΡΚΟΥ ΠΑΟΛΙΝ","phone":"6977630486"},{"name":"ΣΚΡΙΤΣΟΒΑΛΗΣ ΘΕΟΔΩΡΟΣ Ι.","phone":"6946004958"},{"name":"ΣΤΑΥΡΙΔΗ ΑΦΟΙ Ζ. ΑΕ","phone":"6972098740"}];
  _wave2Status = { total: recipients.length, sent: 0, done: false };
  res.json({ started: true, total: recipients.length });
  (async () => {
    for (const r of recipients) {
      try { await sendSms(r.phone, message); } catch (e) { console.error('wave2 sms error', r.phone, e.message); }
      _wave2Status.sent++;
    }
    _wave2Status.done = true;
    console.log('wave2 outreach done', _wave2Status);
  })();
});
app.get('/_oneoff-wave2-sms/status', (req, res) => res.json(_wave2Status));

// ── Start server ────────────────────────────────────────────────
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`🚀 GorealPro backend running on port ${PORT}`);
});
