/**
 * Διορθώνει τα missing fields στο professionals document
 */

const https = require('https');
const fs = require('fs');
const path = require('path');
const os = require('os');

const UID = process.argv[2] || '7RCJfGDcS3NZwpZgz3vYoxT5YFR2';
const PROJECT = 'shoppilot-app-e4104';

const credPath = path.join(os.homedir(), '.config', 'configstore', 'firebase-tools.json');
const creds = JSON.parse(fs.readFileSync(credPath, 'utf8'));
const refreshToken = creds.tokens?.refresh_token;

function httpsPost(hostname, reqPath, data) {
  return new Promise((resolve, reject) => {
    const body = new URLSearchParams(data).toString();
    const opts = {
      hostname, path: reqPath, method: 'POST',
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

const FS_HOST = 'firestore.googleapis.com';
const FS_BASE = `/v1/projects/${PROJECT}/databases/(default)/documents`;

async function main() {
  // Get access token
  console.log('🔐 Ανανεώνω token...');
  const tokenResp = await httpsPost('oauth2.googleapis.com', '/token', {
    client_id: '563584335869-fgrhgmd47bqnekij5i8b5pr03ho849e6.apps.googleusercontent.com',
    client_secret: 'j9iVZfS8kkCEFUPaAeJV0sAi',
    refresh_token: refreshToken,
    grant_type: 'refresh_token',
  });
  const token = tokenResp.access_token;
  if (!token) { console.error('❌ Token failed:', tokenResp); process.exit(1); }
  console.log('✅ Token OK');

  // Read current professionals doc
  console.log(`\n🔍 Διαβάζω professionals/${UID} ...`);
  const doc = await httpsReq('GET', FS_HOST, `${FS_BASE}/professionals/${UID}`, null, token);
  if (doc.error) { console.error('❌', doc.error.message); process.exit(1); }

  const f = doc.fields || {};
  const get = k => f[k]?.stringValue || '';
  const name = get('name') || 'Γιωργος Μποσινακος';
  const city = get('city') || 'Χαλάνδρι';

  console.log(`✅ Βρέθηκε: ${name} | city: ${city}`);

  // PATCH με τα σωστά fields
  const fixedFields = {
    fields: {
      // Το κρίσιμο: is_active = true (αυτό φιλτράρει η query)
      is_active: { booleanValue: true },
      available: { booleanValue: true },
      // userId = document ID (έτσι ψάχνει ο κώδικας)
      userId: { stringValue: UID },
      // areas array για location filtering
      areas: {
        arrayValue: {
          values: [
            { stringValue: city },
            { stringValue: 'Χαλάνδρι' },
          ]
        }
      },
      // area string (παλιό format)
      area: { stringValue: city },
    }
  };

  console.log('\n📝 Προσθέτω: is_active=true, userId, areas...');
  const result = await httpsReq('PATCH', FS_HOST,
    `${FS_BASE}/professionals/${UID}?updateMask.fieldPaths=is_active&updateMask.fieldPaths=available&updateMask.fieldPaths=userId&updateMask.fieldPaths=areas&updateMask.fieldPaths=area`,
    fixedFields, token
  );

  if (result.error) { console.error('❌ Write error:', result.error.message); process.exit(1); }

  console.log('\n🎉 Έγινε! Ο ' + name + ' θα εμφανίζεται τώρα στους κοντινούς επαγγελματίες.');
  console.log('   is_active: true');
  console.log('   userId:    ' + UID);
  console.log('   areas:     [' + city + ', Χαλάνδρι]');
  console.log('\n⚠️  Αν ακόμα δεν εμφανίζεται, πρόσθεσε specialty (ειδικότητα)');
  console.log('   π.χ.: node scripts/fix_pro_fields.js ' + UID + ' "Καθηγητής"');
}

main().catch(e => { console.error('❌', e.message); process.exit(1); });
