// Στέλνει mass email (μέσω Zoho SMTP, ίδιο με backend/server.js) στα leads που βρήκε
// το collect_pro_leads.js. DRY RUN από προεπιλογή — δεν στέλνει τίποτα μέχρι να τρέξεις
// με το flag --send. Κρατάει sent_log.json ώστε να μην ξαναστείλει στο ίδιο email.
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, 'backend', '.env') });
const fs = require('fs');
const nodemailer = require('nodemailer');

const ZOHO_USER = process.env.ZOHO_USER;
const ZOHO_PASS = process.env.ZOHO_PASS;
if (!ZOHO_USER || !ZOHO_PASS) {
  console.error('❌ Λείπουν ZOHO_USER/ZOHO_PASS. Βάλε τα στο backend/.env (ίδια με του Render).');
  process.exit(1);
}

const DRY_RUN = !process.argv.includes('--send');
const LEADS_FILE = 'pro_leads.csv';
const SENT_LOG_FILE = 'sent_log.json';
const DELAY_MS = 2000; // καθυστέρηση μεταξύ αποστολών

const transporter = nodemailer.createTransport({
  host: 'smtp.zoho.eu', port: 465, secure: true,
  auth: { user: ZOHO_USER, pass: ZOHO_PASS },
});

function parseCsv(text) {
  const lines = text.trim().split('\n');
  const headers = lines[0].split(',').map((h) => h.replace(/"/g, ''));
  return lines.slice(1).map((line) => {
    const values = (line.match(/(".*?"|[^,]+)(?=,|$)/g) || []).map((v) =>
      v.replace(/^"|"$/g, '').replace(/""/g, '"'));
    const obj = {};
    headers.forEach((h, i) => (obj[h] = values[i] || ''));
    return obj;
  });
}

function emailSubject(name) {
  return `${name} — Γίνετε μέλος στο GorealAI`;
}

function emailHtml(name, profession) {
  return `
    <div style="font-family:Arial,sans-serif;max-width:600px;margin:0 auto;color:#222;">
      <h2 style="color:#B8860B;">Γεια σας${name ? ' από ' + name : ''},</h2>
      <p>Είμαστε το <b>GorealAI</b> — μια νέα εφαρμογή που φέρνει σε επαφή πελάτες με επαγγελματίες${profession ? ' όπως εσείς (' + profession + ')' : ''} κοντά τους.</p>
      <p>Η εγγραφή είναι <b>δωρεάν</b> και παίρνει 2 λεπτά. Λαμβάνετε ειδοποίηση όποτε κάποιος στην περιοχή σας χρειάζεται τις υπηρεσίες σας.</p>
      <p style="text-align:center;margin:24px 0;">
        <a href="https://gorealai.web.app/app" style="background:#B8860B;color:#fff;padding:12px 24px;border-radius:8px;text-decoration:none;font-weight:bold;">Εγγραφή Δωρεάν</a>
      </p>
      <p style="font-size:12px;color:#888;">Αν δεν θέλετε να λάβετε ξανά email από εμάς, απαντήστε με "ΟΧΙ" και θα αφαιρεθείτε αμέσως από τη λίστα.</p>
    </div>
  `;
}

async function main() {
  if (!fs.existsSync(LEADS_FILE)) {
    console.error(`❌ Δεν βρέθηκε ${LEADS_FILE}. Τρέξε πρώτα: node collect_pro_leads.js`);
    process.exit(1);
  }
  const leads = parseCsv(fs.readFileSync(LEADS_FILE, 'utf8')).filter((l) => l.email);
  const sentLog = fs.existsSync(SENT_LOG_FILE) ? JSON.parse(fs.readFileSync(SENT_LOG_FILE, 'utf8')) : [];
  const sentSet = new Set(sentLog);

  const toSend = leads.filter((l) => !sentSet.has(l.email));
  console.log(`📧 ${toSend.length} νέα emails προς αποστολή (${leads.length - toSend.length} είχαν ήδη σταλεί)`);

  if (DRY_RUN) {
    console.log('\n🔎 DRY RUN — δεν στέλνεται τίποτα πραγματικά. Δείγμα παραληπτών:');
    toSend.slice(0, 5).forEach((l) => console.log(`  → ${l.email}  (${l.name})`));
    console.log(`\nΓια πραγματική αποστολή: node send_mass_email.js --send`);
    return;
  }

  for (const lead of toSend) {
    try {
      await transporter.sendMail({
        from: `GorealAI <${ZOHO_USER}>`,
        to: lead.email,
        subject: emailSubject(lead.name),
        html: emailHtml(lead.name, lead.profession),
      });
      console.log(`✅ Στάλθηκε: ${lead.email}`);
      sentSet.add(lead.email);
      fs.writeFileSync(SENT_LOG_FILE, JSON.stringify([...sentSet], null, 2));
    } catch (e) {
      console.error(`❌ Σφάλμα για ${lead.email}:`, e.message);
    }
    await new Promise((res) => setTimeout(res, DELAY_MS));
  }
  console.log('\n✅ Ολοκληρώθηκε.');
}

main().catch(console.error);
