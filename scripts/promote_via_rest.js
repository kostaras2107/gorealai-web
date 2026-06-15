/**
 * Προάγει χρήστη σε Επαγγελματία μέσω Firestore REST API.
 * Χρησιμοποιεί το FIREBASE_TOKEN που παράγει το firebase CLI.
 *
 * Χρήση:
 *   firebase login:ci  → αντέγραψε το token
 *   $env:FIREBASE_TOKEN="..." ; node scripts/promote_via_rest.js <UID>
 */

const https = require('https');

const UID = process.argv[2];
const PROJECT = 'shoppilot-app-e4104';
const TOKEN = process.env.FIREBASE_TOKEN;

if (!UID) { console.error('❌ Δώσε UID'); process.exit(1); }
if (!TOKEN) { console.error('❌ Ορίσε FIREBASE_TOKEN=...'); process.exit(1); }

const BASE = `firestore.googleapis.com`;

function firestoreRequest(method, path, body) {
  return new Promise((resolve, reject) => {
    const opts = {
      hostname: BASE,
      path: `/v1/projects/${PROJECT}/databases/(default)/documents/${path}`,
      method,
      headers: {
        'Authorization': `Bearer ${TOKEN}`,
        'Content-Type': 'application/json',
      },
    };
    const req = https.request(opts, res => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => {
        try { resolve(JSON.parse(data)); }
        catch { resolve(data); }
      });
    });
    req.on('error', reject);
    if (body) req.write(JSON.stringify(body));
    req.end();
  });
}

function toFS(val) {
  if (val === null || val === undefined) return { nullValue: null };
  if (typeof val === 'boolean') return { booleanValue: val };
  if (typeof val === 'number') return Number.isInteger(val) ? { integerValue: String(val) } : { doubleValue: val };
  return { stringValue: String(val) };
}

function objToFS(obj) {
  const fields = {};
  for (const [k, v] of Object.entries(obj)) {
    if (v !== undefined && v !== null && v !== '') fields[k] = toFS(v);
  }
  return { fields };
}

async function main() {
  console.log(`\n🔍 Διαβάζω users/${UID} ...`);
  const userDoc = await firestoreRequest('GET', `users/${UID}`);

  if (userDoc.error) {
    console.error('❌ Σφάλμα:', userDoc.error.message);
    process.exit(1);
  }

  const f = userDoc.fields || {};
  const get = key => f[key]?.stringValue || f[key]?.booleanValue?.toString() || '';

  const name     = get('name')     || 'Γιώργος Μποσινάκος';
  const phone    = get('phone')    || '';
  const city     = get('city')     || 'Χαλάνδρι';
  const specialty= get('specialty')|| get('category') || '';
  const email    = get('email')    || '';
  const bio      = get('bio')      || get('description') || '';
  const photoUrl = get('photoUrl') || get('profileImage') || '';

  console.log(`✅ Βρέθηκε: ${name} | ${phone} | ${city}`);

  const proData = {
    uid: UID, name, phone, city, specialty, email, bio, photoUrl,
    role: 'professional', available: true, rating: 0, reviews: 0,
  };

  console.log('📝 Δημιουργώ professionals/' + UID + ' ...');

  // PATCH (create or merge)
  const result = await firestoreRequest(
    'PATCH',
    `professionals/${UID}`,
    objToFS(proData)
  );

  if (result.error) {
    console.error('❌ Σφάλμα στο write:', result.error.message);
    process.exit(1);
  }

  console.log('\n🎉 Επιτυχία! Ο ' + name + ' είναι τώρα Επαγγελματίας.');
  console.log('   Πεδία: name, phone, city, specialty, role=professional, available=true');
}

main().catch(e => { console.error('❌', e.message); process.exit(1); });
