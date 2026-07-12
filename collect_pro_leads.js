// Ψάχνει επαγγελματίες στο Google Maps (ανά ειδικότητα + πόλη), βρίσκει το website τους
// και προσπαθεί να εξάγει email επικοινωνίας. Αποθηκεύει σε pro_leads.csv για έλεγχο
// πριν στείλουμε οτιδήποτε (δες send_mass_email.js).
//
// Χρειάζεται στο backend/.env: GOOGLE_PLACES_KEY=... (το ίδιο key που ήδη χρησιμοποιεί
// το backend στο Render — απλά αντέγραψέ το εκεί τοπικά).
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, 'backend', '.env') });
const fs = require('fs');

const GOOGLE_PLACES_KEY = process.env.GOOGLE_PLACES_KEY;
if (!GOOGLE_PLACES_KEY) {
  console.error('❌ Λείπει GOOGLE_PLACES_KEY. Βάλε το στο backend/.env (ίδιο με του Render).');
  process.exit(1);
}

// ── Ειδικότητες (ίδιες με της εφαρμογής) × πόλεις — πρόσθεσε/αφαίρεσε ελεύθερα ──
const PROFESSIONS = [
  'Αλουμινάς', 'Αποφράξεις', 'Γκαραζόπορτες - Ρολά - Συρόμενα', 'Γυάλισμα Μαρμάρων', 'Γυψοσανίδες',
  'Εγκατάσταση Ηλιακών', 'Ελαιοχρωματιστής', 'Ηλεκτρολόγος', 'Κτίστης',
  'Μεταλλικές Κατασκευές', 'Μονώσεις', 'Πλακάς', 'Συντήρηση Κλιματιστικών',
  'Τεχνικός Ανελκυστήρων', 'Υαλουργός', 'Υδραυλικός', 'Υπηρεσία Αποξήλωσης',
  'Smart Home Συστήματα Ασφαλείας', 'Ξυλουργός', 'Ψυκτικός',
];
const CITIES = ['Αθήνα', 'Θεσσαλονίκη', 'Πάτρα'];

const SEARCHES = PROFESSIONS.flatMap((p) => CITIES.map((c) => [p, c]));

const RESULTS_PER_SEARCH = 10;
const EMAIL_BLOCKLIST = /wixpress|sentry|example\.(com|org)|godaddy|schema\.org|w3\.org|gstatic|google-analytics|cloudflare|yourdomain|@2x|\.(png|jpg|jpeg|gif|svg|webp)$/i;

async function textSearch(query) {
  const url = `https://maps.googleapis.com/maps/api/place/textsearch/json?query=${encodeURIComponent(query)}&language=el&key=${GOOGLE_PLACES_KEY}`;
  const r = await fetch(url);
  const data = await r.json();
  if (data.status && data.status !== 'OK' && data.status !== 'ZERO_RESULTS') {
    console.warn(`  ⚠️ Google Places status: ${data.status} ${data.error_message || ''}`);
  }
  return (data.results || []).slice(0, RESULTS_PER_SEARCH);
}

async function placeDetails(placeId) {
  const url = `https://maps.googleapis.com/maps/api/place/details/json?place_id=${placeId}&fields=name,website,formatted_phone_number,formatted_address&language=el&key=${GOOGLE_PLACES_KEY}`;
  const r = await fetch(url);
  const data = await r.json();
  return data.result || {};
}

function extractEmail(html) {
  const mailtoMatch = html.match(/mailto:([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})/i);
  if (mailtoMatch) return mailtoMatch[1];
  const matches = html.match(/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/g) || [];
  const valid = matches.filter(e => !EMAIL_BLOCKLIST.test(e));
  return valid[0] || null;
}

async function findEmailFromWebsite(website) {
  const paths = ['', '/contact', '/epikoinonia', '/contact-us', '/epikoinwnia', '/contact.html', '/el/contact'];
  const base = website.replace(/\/$/, '');
  for (const p of paths) {
    try {
      const r = await fetch(base + p, { signal: AbortSignal.timeout(8000) });
      if (!r.ok) continue;
      const html = await r.text();
      const email = extractEmail(html);
      if (email) return email;
    } catch (e) { /* συνέχισε στο επόμενο path */ }
  }
  return null;
}

const sleep = (ms) => new Promise((res) => setTimeout(res, ms));

async function main() {
  const leads = [];
  const seen = new Set();
  const esc = (v) => `"${String(v || '').replace(/"/g, '""')}"`;
  const saveCsv = () => {
    const csv = [
      'profession,city,name,address,phone,website,email',
      ...leads.map((l) => [l.profession, l.city, l.name, l.address, l.phone, l.website, l.email].map(esc).join(',')),
    ].join('\n');
    fs.writeFileSync('pro_leads.csv', csv, 'utf8');
  };

  for (const [profession, city] of SEARCHES) {
    console.log(`\n🔍 Αναζήτηση: ${profession} ${city}`);
    let results = [];
    try {
      results = await textSearch(`${profession} ${city}`);
    } catch (e) {
      console.error(`  ⚠️ Αποτυχία αναζήτησης (${e.message}) — προσπερνάω`);
      continue;
    }
    for (const p of results) {
      if (seen.has(p.place_id)) continue;
      seen.add(p.place_id);
      await sleep(300);
      try {
        const details = await placeDetails(p.place_id);
        let email = null;
        if (details.website) {
          email = await findEmailFromWebsite(details.website);
        }
        leads.push({
          profession, city,
          name: details.name || p.name || '',
          address: details.formatted_address || p.formatted_address || '',
          phone: details.formatted_phone_number || '',
          website: details.website || '',
          email: email || '',
        });
        console.log(`  ${email ? '✅' : '❌'} ${details.name || p.name} ${email ? '→ ' + email : '(χωρίς email)'}`);
      } catch (e) {
        console.error(`  ⚠️ Σφάλμα στο ${p.name} (${e.message}) — προσπερνάω`);
      }
      await sleep(500);
    }
    saveCsv(); // αποθήκευση προοδευτικά ώστε να μη χαθεί τίποτα σε τυχόν κράσαρισμα
  }

  const withEmail = leads.filter((l) => l.email);
  console.log(`\n📊 Σύνολο: ${leads.length} επιχειρήσεις βρέθηκαν, ${withEmail.length} με email`);
  saveCsv();
  console.log('💾 Αποθηκεύτηκε στο pro_leads.csv — άνοιξέ το και έλεγξέ το πριν τρέξεις το send_mass_email.js');
}

main().catch(console.error);
