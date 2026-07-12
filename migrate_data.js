// Migration:
// 1. Copy afm from users → professionals for all pros
// 2. Create reviews docs from lastRating/lastReview in professionals
const { initializeApp, cert } = require('firebase-admin/app');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');
const path = require('path');

const serviceAccount = require('./serviceAccount.json');

initializeApp({ credential: cert(serviceAccount) });
const db = getFirestore();

async function run() {
  // ── 1. Copy afm from users → professionals ──
  console.log('📋 Copying afm from users → professionals...');
  const usersSnap = await db.collection('users').where('role', '==', 'professional').get();
  let afmCount = 0;
  for (const userDoc of usersSnap.docs) {
    const data = userDoc.data();
    const afm = (data.afm || '').trim();
    if (!afm) continue;

    // Find professionals doc (by userId field or by uid)
    const proByUserId = await db.collection('professionals').where('userId', '==', userDoc.id).limit(1).get();
    const proRef = proByUserId.empty
      ? db.collection('professionals').doc(userDoc.id)
      : proByUserId.docs[0].ref;

    const proSnap = await proRef.get();
    if (!proSnap.exists) continue;
    const proData = proSnap.data() || {};
    if ((proData.afm || '').trim()) continue; // already has afm

    await proRef.set({ afm }, { merge: true });
    console.log(`  ✅ ${data.name || userDoc.id}: afm=${afm}`);
    afmCount++;
  }
  console.log(`  → ${afmCount} professionals updated with afm\n`);

  // ── 2. Create reviews from lastRating/lastReview ──
  console.log('⭐ Creating reviews from lastRating/lastReview...');
  const prosSnap = await db.collection('professionals').get();
  let reviewCount = 0;
  for (const proDoc of prosSnap.docs) {
    const data = proDoc.data();
    const lastRating = data.lastRating;
    const lastReview = data.lastReview || '';
    if (!lastRating || lastRating === 0) continue;

    const proId = proDoc.id;
    const docId = `legacy_${proId}`;
    const existing = await db.collection('reviews').doc(docId).get();
    if (existing.exists) continue;

    // Check if there are already reviews for this pro
    const existingReviews = await db.collection('reviews').where('proId', '==', proId).limit(1).get();
    if (!existingReviews.empty) continue;

    await db.collection('reviews').doc(docId).set({
      rating: lastRating,
      comment: lastReview,
      userId: '',
      userName: 'Χρήστης',
      proId,
      timestamp: FieldValue.serverTimestamp(),
    });
    console.log(`  ✅ ${data.name || proId}: rating=${lastRating}`);
    reviewCount++;
  }
  console.log(`  → ${reviewCount} reviews created\n`);

  console.log('✅ Migration complete!');
}

run().catch(e => { console.error('❌', e); process.exit(1); });
