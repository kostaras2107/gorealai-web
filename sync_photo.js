// Τρέξε: node sync_photo.js
// Συγχρονίζει profilePhotoUrl από users → professionals για όλους

const admin = require('firebase-admin');
const path = require('path');

// Φόρτωσε credentials από backend/.env
const fs = require('fs');
const envPath = path.join(__dirname, 'backend', '.env');
if (fs.existsSync(envPath)) {
  fs.readFileSync(envPath, 'utf8').split('\n').forEach(line => {
    const [k, ...v] = line.split('=');
    if (k && v.length) process.env[k.trim()] = v.join('=').trim();
  });
}

let sa;
try { sa = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT); } catch(e) {
  // Δοκίμασε να φορτώσει από αρχείο
  const f = path.join(__dirname, 'backend', 'serviceAccount.json');
  if (fs.existsSync(f)) sa = require(f);
}

if (!sa) { console.error('❌ Δεν βρέθηκαν credentials.'); process.exit(1); }

admin.initializeApp({ credential: admin.credential.cert(sa) });
const db = admin.firestore();

async function sync() {
  const pros = await db.collection('professionals').get();
  let fixed = 0;
  for (const proDoc of pros.docs) {
    const pd = proDoc.data();
    if (pd.profilePhotoUrl) continue; // ήδη έχει
    const uid = pd.userId || proDoc.id;
    const ud = (await db.collection('users').doc(uid).get()).data() || {};
    const url = ud.profilePhotoUrl;
    if (!url) continue;
    await proDoc.ref.set({ profilePhotoUrl: url }, { merge: true });
    console.log(`✅ ${pd.name} → φωτό αντιγράφηκε`);
    fixed++;
  }
  console.log(`\nΟλοκληρώθηκε: ${fixed} επαγγελματίες διορθώθηκαν.`);
  process.exit(0);
}
sync().catch(e => { console.error(e); process.exit(1); });
