/**
 * Προάγει έναν χρήστη σε Επαγγελματία:
 * Διαβάζει το users document και δημιουργεί αντίστοιχο professionals document.
 *
 * Χρήση: node scripts/promote_to_professional.js <UID>
 */

const { initializeApp, applicationDefault } = require('firebase-admin/app');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');

const uid = process.argv[2];
if (!uid) {
  console.error('❌  Δώσε UID: node scripts/promote_to_professional.js <UID>');
  process.exit(1);
}

initializeApp({
  credential: applicationDefault(),
  projectId: 'shoppilot-app-e4104',
});

const db = getFirestore();

async function main() {
  console.log(`\n🔍  Διαβάζω users/${uid} ...`);

  const userSnap = await db.collection('users').doc(uid).get();
  if (!userSnap.exists) {
    console.error('❌  Δεν βρέθηκε ο χρήστης στο users collection!');
    process.exit(1);
  }
  const u = userSnap.data();
  console.log('✅  Βρέθηκε:', u.name || '(χωρίς όνομα)', '|', u.email || u.phone || '');

  // Ελέγχω αν υπάρχει ήδη στο professionals
  const proSnap = await db.collection('professionals').doc(uid).get();
  if (proSnap.exists) {
    console.log('ℹ️   Υπάρχει ήδη στο professionals collection. Ενημερώνω...');
  }

  const proData = {
    // Βασικά στοιχεία
    uid:       uid,
    name:      u.name      || '',
    email:     u.email     || '',
    phone:     u.phone     || '',
    city:      u.city      || '',
    specialty: u.specialty || u.category || '',
    bio:       u.bio       || u.description || '',
    // Εικόνες
    photoUrl:  u.photoUrl  || u.profileImage || '',
    selfieUrl: u.selfieUrl || '',
    // Role & status
    role:      'professional',
    available: true,
    // Ratings
    rating:    u.rating    || 0,
    reviews:   u.reviews   || 0,
    // Timestamps
    createdAt: u.createdAt || FieldValue.serverTimestamp(),
    promotedAt: FieldValue.serverTimestamp(),
  };

  // Αφαίρεσε undefined values
  Object.keys(proData).forEach(k => {
    if (proData[k] === undefined) delete proData[k];
  });

  await db.collection('professionals').doc(uid).set(proData, { merge: true });

  // Ενημέρωσε και το users doc
  await db.collection('users').doc(uid).update({ role: 'professional' });

  console.log('\n🎉  Επιτυχία! Ο χρήστης είναι τώρα Επαγγελματίας.');
  console.log('   professionals/' + uid);
  console.log('   Στοιχεία που αποθηκεύτηκαν:');
  console.log('   name:     ', proData.name);
  console.log('   phone:    ', proData.phone);
  console.log('   city:     ', proData.city);
  console.log('   specialty:', proData.specialty);
  console.log('   available:', proData.available);
}

main().catch(e => {
  console.error('❌ Σφάλμα:', e.message);
  process.exit(1);
});
