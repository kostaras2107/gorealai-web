const https = require('https');
const fs = require('fs');
const path = require('path');
const os = require('os');

const UID = '7RCJfGDcS3NZwpZgz3vYoxT5YFR2';
const PROJECT = 'shoppilot-app-e4104';
const SPECIALTIES = ['Καθηγητής Αγγλικών', 'Καθηγητής Μαθηματικών', 'Φιλόλογος'];

const credPath = path.join(os.homedir(), '.config', 'configstore', 'firebase-tools.json');
const refreshToken = JSON.parse(fs.readFileSync(credPath, 'utf8')).tokens?.refresh_token;

function post(hostname, p, data) {
  return new Promise((resolve, reject) => {
    const body = new URLSearchParams(data).toString();
    const req = https.request({ hostname, path: p, method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': Buffer.byteLength(body) }
    }, res => { let d=''; res.on('data',c=>d+=c); res.on('end',()=>{ try{resolve(JSON.parse(d))}catch{resolve(d)} }); });
    req.on('error', reject); req.write(body); req.end();
  });
}

function req(method, p, body, token) {
  return new Promise((resolve, reject) => {
    const bodyStr = body ? JSON.stringify(body) : '';
    const r = https.request({ hostname: 'firestore.googleapis.com', path: p, method,
      headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json',
        ...(bodyStr ? { 'Content-Length': Buffer.byteLength(bodyStr) } : {}) }
    }, res => { let d=''; res.on('data',c=>d+=c); res.on('end',()=>{ try{resolve(JSON.parse(d))}catch{resolve(d)} }); });
    r.on('error', reject);
    if (bodyStr) r.write(bodyStr);
    r.end();
  });
}

async function main() {
  console.log('🔐 Token...');
  const t = await post('oauth2.googleapis.com', '/token', {
    client_id: '563584335869-fgrhgmd47bqnekij5i8b5pr03ho849e6.apps.googleusercontent.com',
    client_secret: 'j9iVZfS8kkCEFUPaAeJV0sAi',
    refresh_token: refreshToken, grant_type: 'refresh_token',
  });
  const token = t.access_token;
  if (!token) { console.error('❌ Token failed'); process.exit(1); }

  const base = `/v1/projects/${PROJECT}/databases/(default)/documents`;

  const body = {
    fields: {
      // Πρωτεύουσα ειδικότητα (για old-style query: where specialty == ...)
      specialty: { stringValue: SPECIALTIES[0] },
      // Array ειδικοτήτων (για new-style query: where specialties arrayContains ...)
      specialties: {
        arrayValue: {
          values: SPECIALTIES.map(s => ({ stringValue: s }))
        }
      }
    }
  };

  const fields = 'specialty&updateMask.fieldPaths=specialties';
  console.log('📝 Βάζω ειδικότητες:', SPECIALTIES.join(', '));

  const result = await req('PATCH', `${base}/professionals/${UID}?updateMask.fieldPaths=${fields}`, body, token);

  if (result.error) { console.error('❌', result.error.message); process.exit(1); }

  console.log('\n🎉 Έγινε! Ο Γιώργος Μποσινάκος εμφανίζεται τώρα όταν ψάχνουν:');
  SPECIALTIES.forEach(s => console.log('   ✅ ' + s));
}

main().catch(e => { console.error('❌', e.message); process.exit(1); });
