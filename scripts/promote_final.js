/**
 * Προάγει χρήστη σε Επαγγελματία χρησιμοποιώντας Firebase CLI stored credentials.
 */

const https = require('https');
const fs = require('fs');
const path = require('path');
const os = require('os');

const UID = process.argv[2] || '7RCJfGDcS3NZwpZgz3vYoxT5YFR2';
const PROJECT = 'shoppilot-app-e4104';

// Φόρτωσε Firebase CLI credentials
const credPath = path.join(os.homedir(), '.config', 'configstore', 'firebase-tools.json');
const creds = JSON.parse(fs.readFileSync(credPath, 'utf8'));
const tokens = creds.tokens || {};
const refreshToken = tokens.refresh_token;

if (!refreshToken) {
  console.error('❌ Δεν βρέθηκε refresh token. Κάνε firebase login ξανά.');
  process.exit(1);
}

function httpsPost(hostname, path, data) {
  return new Promise((resolve, reject) => {
    const body = typeof data === 'string' ? data : new URLSearchParams(data).toString();
    const opts = {
      hostname, path, method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': Buffer.byteLength(body) }
    };
    const req = https.request(opts, res => {
      let d = ''; res.on('data', c => d += c);
      res.on('end', () => { try { resolve(JSON.parse(d)); } catch { resolve(d); } });
    });
    req.on('error', reject);
    req.write(body); req.end();
  });
}

function httpsReq(method, hostname, reqPath, body, token) {
  return new Promise((resolve, reject) => {
    const bodyStr = body ? JSON.stringify(body) : '';
    const opts = {
      hostname, path: reqPath, method,
      headers: {
        'Authorization': `Bearer ${token}`,
        'Content-Type': 'application/json',
        ...(bodyStr ? { 'Content-Length': Buffer.byteLength(bodyStr) } : {})
      }
    };
    const req = https.request(opts, res => {
      let d = ''; res.on('data', c => d += c);
      res.on('end', () => { try { resolve(JSON.parse(d)); } catch { resolve(d); } });
    });
    req.on('error', reject);
    if (bodyStr) req.write(bodyStr);
    req.end();
  });
}

function toFSValue(val) {
  if (val === null || val === undefined) return { nullValue: null };
  if (typeof val === 'boolean') return { booleanValue: val };
  if (typeof val === 'number') return Number.isInteger(val) ? { integerValue: String(val) } : { doubleValue: val };
  return { stringValue: String(val) };
}

function objToFS(obj) {
  const fields = {};
  for (const [k, v] of Object.entries(obj)) {
    if (v !== undefined && v !== null) fields[k] = toFSValue(v);
  }
  return { fields };
}

function fsGet(doc, key) {
  const f = doc?.fields?.[key];
  if (!f) return '';
  return f.stringValue ?? f.booleanValue?.toString() ?? String(f.integerValue ?? f.doubleValue ?? '');
}

async function main() {
  // 1. Πάρε access token
  console.log('🔐 Ανανεώνω access token...');
  const tokenResp = await httpsPost('oauth2.googleapis.com', '/token', {
    client_id: '563584335869-fgrhgmd47bqnekij5i8b5pr03ho849e6.apps.googleusercontent.com',
    client_secret: 'j9iVZfS8kkCEFUPaAeJV0sAi',
    refresh_token: refreshToken,
    grant_type: 'refresh_token',
  });

  const accessToken = tokenResp.access_token;
  if (!accessToken) {
    console.error('❌ Αποτυχία token:', JSON.stringify(tokenResp));
    process.exit(1);
  }
  console.log('✅ Token OK');

  const FS_HOST = 'firestore.googleapis.com';
  const FS_BASE = `/v1/projects/${PROJECT}/databases/(default)/documents`;

  // 2. Διάβασε users doc
  console.log(`\n🔍 Διαβάζω users/${UID} ...`);
  const userDoc = await httpsReq('GET', FS_HOST, `${FS_BASE}/users/${UID}`, null, accessToken);

  if (userDoc.error) {
    console.error('❌ Σφάλμα στο users read:', userDoc.error.message);
    process.exit(1);
  }

  const name      = fsGet(userDoc, 'name')        || 'Γιώργος Μποσινάκος';
  const phone     = fsGet(userDoc, 'phone')        || '';
  const city      = fsGet(userDoc, 'city')         || 'Χαλάνδρι';
  const specialty = fsGet(userDoc, 'specialty')    || fsGet(userDoc, 'category') || '';
  const email     = fsGet(userDoc, 'email')        || '';
  const bio       = fsGet(userDoc, 'bio')          || fsGet(userDoc, 'description') || '';
  const photoUrl  = fsGet(userDoc, 'photoUrl')     || fsGet(userDoc, 'profileImage') || '';

  console.log(`✅ Βρέθηκε: ${name}`);
  console.log(`   phone: ${phone || '(κενό)'} | city: ${city} | specialty: ${specialty || '(κενό)'}`);

  // 3. Δημιούργησε professionals doc
  const proData = {
    uid: UID, name, phone, city, specialty, email, bio, photoUrl,
    role: 'professional', available: true, rating: 0, reviews: 0,
  };

  console.log(`\n📝 Γράφω professionals/${UID} ...`);
  const writeResult = await httpsReq(
    'PATCH', FS_HOST,
    `${FS_BASE}/professionals/${UID}`,
    objToFS(proData),
    accessToken
  );

  if (writeResult.error) {
    console.error('❌ Σφάλμα στο write:', writeResult.error.message);
    process.exit(1);
  }

  // 4. Ενημέρωσε και το users doc (role = professional)
  console.log('📝 Ενημερώνω users role...');
  await httpsReq(
    'PATCH', FS_HOST,
    `${FS_BASE}/users/${UID}?updateMask.fieldPaths=role`,
    { fields: { role: { stringValue: 'professional' } } },
    accessToken
  );

  console.log('\n🎉 Επιτυχία! Ο/Η ' + name + ' είναι τώρα Επαγγελματίας στο GorealAI!');
  console.log('   UID:       ' + UID);
  console.log('   name:      ' + name);
  console.log('   phone:     ' + (phone || '(κενό)'));
  console.log('   city:      ' + city);
  console.log('   specialty: ' + (specialty || '(κενό)'));
  console.log('   available: true');
}

main().catch(e => { console.error('❌ Σφάλμα:', e.message); process.exit(1); });
