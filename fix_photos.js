// Migration: copy profilePhotoUrl from users → professionals for all pros that are missing it
const { initializeApp, cert } = require('firebase-admin/app');
const { getFirestore } = require('firebase-admin/firestore');
const path = require('path');

// Try to load service account from backend .env or local file
let serviceAccount;
try {
  require('dotenv').config({ path: path.join(__dirname, 'backend', '.env') });
  if (process.env.FIREBASE_SERVICE_ACCOUNT) {
    serviceAccount = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT);
  }
} catch(e) {}

if (!serviceAccount) {
  console.error('❌ Δεν βρέθηκε FIREBASE_SERVICE_ACCOUNT στο backend/.env');
  console.log('Πήγαινε: Firebase Console → Project Settings → Service Accounts → Generate new private key');
  console.log('Βάλε το JSON στο backend/.env ως: FIREBASE_SERVICE_ACCOUNT={"type":"service_account",...}');
  process.exit(1);
}

initializeApp({ credential: cert(serviceAccount) });
const db = getFirestore();

async function migrate() {
  console.log('🔍 Ψάχνω επαγγελματίες χωρίς profilePhotoUrl...');
  const prosSnap = await db.collection('professionals').get();
  let fixed = 0;

  for (const proDoc of prosSnap.docs) {
    const pd = proDoc.data();
    if (pd.profilePhotoUrl && pd.profilePhotoUrl.length > 0) continue;

    // Βρες το userId
    const userId = pd.userId || proDoc.id;
    const userDoc = await db.collection('users').doc(userId).get();
    if (!userDoc.exists) continue;

    const ud = userDoc.data();
    const photoUrl = ud.profilePhotoUrl;
    if (!photoUrl || photoUrl.length === 0) continue;

    await proDoc.ref.set({ profilePhotoUrl: photoUrl }, { merge: true });
    console.log(`✅ ${pd.name || proDoc.id} → profilePhotoUrl αντιγράφηκε`);
    fixed++;
  }

  console.log(`\n✅ Τέλος! Διορθώθηκαν ${fixed} επαγγελματίες.`);
}

migrate().catch(console.error);
