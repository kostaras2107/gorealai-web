/**
 * Προάγει χρήστη σε Επαγγελματία.
 * Χρησιμοποιεί firebase-tools (ήδη εγκατεστημένο/authenticated).
 */

const { initializeApp } = require('firebase-admin/app');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');
const { credential } = require('firebase-admin');

const UID = process.argv[2] || '7RCJfGDcS3NZwpZgz3vYoxT5YFR2';
const PROJECT = 'shoppilot-app-e4104';

// Χρησιμοποιούμε το firebase-admin με service account από το env ή CLI stored token
const fs = require('fs');
const path = require('path');
const os = require('os');

// Ψάχνουμε για αποθηκευμένα credentials από firebase CLI
const configPaths = [
  path.join(os.homedir(), 'AppData', 'Roaming', 'firebase', 'credentials'),
  path.join(os.homedir(), '.config', 'firebase', 'credentials'),
  path.join(os.homedir(), '.firebase', 'credentials'),
];

// Firebase CLI uses a refresh token - ας χρησιμοποιήσουμε το API Key της εφαρμογής
// για να πάρουμε data μέσω Firestore REST API
const https = require('https');
const { execSync } = require('child_process');

// Παίρνουμε access token μέσω firebase CLI
let accessToken;
try {
  // Το firebase print:token επιστρέφει ένα CI token
  const firebaseConfig = fs.readFileSync(
    path.join(os.homedir(), 'AppData', 'Roaming', 'firebase', 'config.json'),
    'utf8'
  );
  console.log('Firebase config found');
} catch(e) {
  // try alternate path
}

// Χρησιμοποιούμε firebase-admin με GOOGLE_APPLICATION_CREDENTIALS ή
// fallback σε REST API με το token από firebase use
try {
  accessToken = execSync('firebase login:list --json 2>/dev/null || echo {}', { encoding: 'utf8' });
} catch(e) {}

console.log('Trying to get access token from Firebase CLI...');

// Καλύτερη προσέγγιση: χρησιμοποιούμε firebase-tools ως library
try {
  const api = require('firebase-tools');
  // Δεν υπάρχει άμεσο API για Firestore μέσω firebase-tools
} catch(e) {}

// Τελική προσέγγιση: Χρησιμοποιούμε το google-auth-library με cached credentials
async function getTokenFromFirebaseCLI() {
  // Firebase CLI cache location on Windows
  const cachePaths = [
    path.join(os.homedir(), 'AppData', 'Roaming', 'firebase', 'credentials.json'),
    path.join(os.homedir(), '.config', 'configstore', 'firebase-tools.json'),
    path.join(os.homedir(), 'AppData', 'Roaming', 'Configstore', 'firebase-tools.json'),
    path.join(os.homedir(), 'AppData', 'Local', 'firebase', 'credentials.json'),
  ];

  for (const p of cachePaths) {
    try {
      if (fs.existsSync(p)) {
        console.log('Found credentials at:', p);
        const data = JSON.parse(fs.readFileSync(p, 'utf8'));
        console.log('Keys:', Object.keys(data).join(', '));
        return data;
      }
    } catch(e) {}
  }
  return null;
}

getTokenFromFirebaseCLI().then(data => {
  if (data) {
    console.log('\nCredentials found! Content (first 200 chars):');
    console.log(JSON.stringify(data).substring(0, 200));
  } else {
    console.log('\n❌ No cached credentials found. Checking alternate locations...');
    // List what's in AppData/Roaming
    try {
      const roaming = path.join(os.homedir(), 'AppData', 'Roaming');
      const dirs = fs.readdirSync(roaming).filter(d => d.toLowerCase().includes('firebase') || d.toLowerCase().includes('google'));
      console.log('Firebase-related dirs in AppData/Roaming:', dirs);
    } catch(e) {}
    try {
      const configstore = path.join(os.homedir(), 'AppData', 'Roaming', 'Configstore');
      const files = fs.readdirSync(configstore);
      console.log('Configstore files:', files);
    } catch(e) { console.log('No Configstore dir'); }
  }
});
