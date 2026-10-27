// Φτιάχνει στατικές σελίδες «Επάγγελμα + Περιοχή» για το Google (SEO):
//   landing/ypiresies/index.html                      → όλες οι υπηρεσίες
//   landing/ypiresies/<epaggelma>/index.html          → ένα επάγγελμα, όλες οι περιοχές
//   landing/ypiresies/<epaggelma>/<perioxi>/index.html → π.χ. «Υδραυλικός στο Χαλάνδρι»
// και ενημερώνει landing/sitemap.xml + landing/robots.txt.
// Τρέξιμο: node scripts/gen-service-pages.js   (μετά: firebase deploy --only hosting)
const fs = require('fs');
const path = require('path');

const SITE = 'https://gorealai.gr';
const OUT = path.join(__dirname, '..', 'landing', 'ypiresies');
const PLAY = 'https://play.google.com/store/apps/details?id=gr.gorealai.app';
const IOS = 'https://apps.apple.com/gr/app/gorealpro/id6817919309';
const WEBAPP = 'https://gorealai.web.app/app/';
const STATS = { pros: '500+', specialties: '80+', downloads: '1.600+' };

const PROFESSIONS = [
  {
    slug: 'ilektrologos', name: 'Ηλεκτρολόγος', acc: 'ηλεκτρολόγο', plural: 'ηλεκτρολόγοι', pluralAcc: 'ηλεκτρολόγους', img: 'electrician',
    intro: 'Πρίζα που δεν δουλεύει, ασφάλεια που πέφτει συνέχεια ή φωτιστικό για τοποθέτηση;',
    jobs: ['Βλάβες σε πρίζες, διακόπτες και ασφάλειες', 'Τοποθέτηση φωτιστικών και LED', 'Αλλαγή ή αναβάθμιση ηλεκτρικού πίνακα', 'Ηλεκτρολογική ανακαίνιση διαμερίσματος', 'Γείωση και πιστοποιητικό ηλεκτρολογικής εγκατάστασης', 'Σύνδεση κουζίνας, θερμοσίφωνα και κλιματιστικού'],
    tip: 'Τράβηξε μια φωτογραφία την πρίζα ή τον πίνακα και γράψε από πότε υπάρχει το πρόβλημα. Ο ηλεκτρολόγος καταλαβαίνει αμέσως τι χρειάζεται και σου δίνει πιο ακριβή τιμή.',
    faq: [['Πόσο γρήγορα μπορεί να έρθει ηλεκτρολόγος;', 'Οι προσφορές έρχονται συνήθως μέσα σε λίγα λεπτά και κάθε επαγγελματίας γράφει πότε είναι διαθέσιμος — συχνά ακόμα και την ίδια μέρα.'], ['Μπορώ να στείλω φωτογραφία της βλάβης;', 'Ναι. Μπορείς να επισυνάψεις φωτογραφίες ή βίντεο στο αίτημα, ώστε ο ηλεκτρολόγος να δει το πρόβλημα πριν σου στείλει τιμή.']],
  },
  {
    slug: 'ydravlikos', name: 'Υδραυλικός', acc: 'υδραυλικό', plural: 'υδραυλικοί', pluralAcc: 'υδραυλικούς', img: 'plumber',
    intro: 'Διαρροή, βρύση που στάζει ή θερμοσίφωνας που δεν ζεσταίνει;',
    jobs: ['Διαρροές σε σωλήνες, βρύσες και καζανάκια', 'Αλλαγή μπαταρίας, νιπτήρα ή λεκάνης', 'Τοποθέτηση και επισκευή θερμοσίφωνα', 'Σύνδεση πλυντηρίου και πλυντηρίου πιάτων', 'Ανακαίνιση μπάνιου και κουζίνας', 'Κεντρική θέρμανση και καλοριφέρ'],
    tip: 'Γράψε πού είναι η διαρροή και αν τρέχει συνέχεια νερό. Ένα σύντομο βίντεο βοηθάει τον υδραυλικό να έρθει με τα σωστά ανταλλακτικά.',
    faq: [['Τι κάνω αν έχω διαρροή τώρα;', 'Κλείσε τον γενικό διακόπτη νερού και στείλε αίτημα με φωτογραφία. Οι υδραυλικοί της περιοχής σου βλέπουν το αίτημα αμέσως και σου στέλνουν προσφορά.'], ['Χρεώνομαι για να ζητήσω προσφορές;', 'Όχι. Το GorealPro είναι εντελώς δωρεάν για όποιον ψάχνει επαγγελματία.']],
  },
  {
    slug: 'elaiochromatistis', name: 'Ελαιοχρωματιστής', acc: 'ελαιοχρωματιστή', plural: 'ελαιοχρωματιστές', pluralAcc: 'ελαιοχρωματιστές', img: 'painter',
    intro: 'Θέλεις να βάψεις το σπίτι, ένα δωμάτιο ή την πρόσοψη;',
    jobs: ['Βάψιμο διαμερίσματος και μονοκατοικίας', 'Βάψιμο οροφών και τοίχων με υγρασία', 'Εξωτερικοί χώροι, κάγκελα και πρόσοψη', 'Σπατουλάρισμα και διακοσμητικές τεχνικές', 'Βάψιμο κουφωμάτων και ξύλινων επιφανειών', 'Βάψιμο κοινόχρηστων πολυκατοικίας'],
    tip: 'Γράψε περίπου τα τετραγωνικά, πόσα δωμάτια είναι και αν μένει κάποιος στο σπίτι. Έτσι οι προσφορές βγαίνουν συγκρίσιμες μεταξύ τους.',
    faq: [['Πώς συγκρίνω τις προσφορές;', 'Βλέπεις τις 3 καλύτερες προσφορές με τιμή, διαθεσιμότητα και αξιολογήσεις, και διαλέγεις με βάση αυτό που σε ενδιαφέρει περισσότερο.'], ['Μπορώ να δω προηγούμενες δουλειές του;', 'Ναι, πολλοί επαγγελματίες έχουν portfolio με φωτογραφίες και βίντεο στο προφίλ τους.']],
  },
  {
    slug: 'katharistria', name: 'Καθαρίστρια', acc: 'καθαρίστρια', plural: 'καθαρίστριες', pluralAcc: 'καθαρίστριες', img: 'cleaning',
    intro: 'Χρειάζεσαι καθαρισμό σπιτιού, γραφείου ή μετά από ανακαίνιση;',
    jobs: ['Γενικός καθαρισμός διαμερίσματος', 'Καθαρισμός μετά από ανακαίνιση ή μετακόμιση', 'Τακτικός εβδομαδιαίος καθαρισμός', 'Καθαρισμός γραφείων και καταστημάτων', 'Καθαρισμός κοινόχρηστων χώρων', 'Καθαρισμός Airbnb ανάμεσα σε κρατήσεις'],
    tip: 'Γράψε τα τετραγωνικά, πόσα μπάνια έχει το σπίτι και κάθε πότε θέλεις καθαρισμό. Έτσι η τιμή βγαίνει από την αρχή σωστή.',
    faq: [['Μπορώ να βρω καθαρίστρια για τακτική συνεργασία;', 'Ναι. Γράψε στο αίτημα ότι θέλεις εβδομαδιαίο ή δεκαπενθήμερο καθαρισμό και θα λάβεις προσφορές για τακτική συνεργασία.'], ['Πώς ξέρω αν είναι αξιόπιστη;', 'Στο προφίλ κάθε επαγγελματία βλέπεις αξιολογήσεις από άλλους πελάτες, φωτογραφίες και αν έχει επιβεβαιωμένο ΑΦΜ.']],
  },
  {
    slug: 'klimatistika', name: 'Τεχνικός Κλιματιστικών', acc: 'τεχνικό κλιματιστικών', plural: 'τεχνικοί κλιματιστικών', pluralAcc: 'τεχνικούς κλιματιστικών', img: 'ac',
    intro: 'Κλιματιστικό που δεν κρυώνει ή δεν ζεσταίνει, ή χρειάζεσαι καινούριο;',
    jobs: ['Τοποθέτηση νέου κλιματιστικού', 'Συντήρηση και καθαρισμός κλιματιστικού', 'Συμπλήρωση υγραερίου (freon)', 'Επισκευή βλάβης και διαρροής νερού', 'Μετακίνηση ή αποξήλωση μονάδας', 'Αντλίες θερμότητας'],
    tip: 'Γράψε τη μάρκα και τα BTU του κλιματιστικού και τι ακριβώς κάνει. Μια φωτογραφία της εξωτερικής μονάδας βοηθάει πολύ.',
    faq: [['Κάθε πότε χρειάζεται συντήρηση το κλιματιστικό;', 'Συνήθως μία φορά τον χρόνο, πριν το καλοκαίρι ή πριν τον χειμώνα. Στείλε αίτημα και κανόνισε ραντεβού όποτε σε βολεύει.'], ['Μπορώ να ζητήσω προσφορά και για τοποθέτηση;', 'Ναι. Γράψε αν έχεις ήδη το κλιματιστικό ή αν θέλεις ο τεχνικός να το προμηθεύσει.']],
  },
  {
    slug: 'apofraxeis', name: 'Αποφράξεις', acc: 'συνεργείο αποφράξεων', plural: 'συνεργεία αποφράξεων', pluralAcc: 'συνεργεία αποφράξεων', img: 'drain',
    intro: 'Βούλωσε ο νεροχύτης, η λεκάνη ή η αποχέτευση;',
    jobs: ['Απόφραξη νεροχύτη και μπανιέρας', 'Απόφραξη λεκάνης και σιφωνιών', 'Αποφράξεις αποχέτευσης πολυκατοικίας', 'Καθαρισμός φρεατίων', 'Έλεγχος σωληνώσεων με κάμερα', 'Επείγουσες αποφράξεις'],
    tip: 'Γράψε πού είναι το βούλωμα και από πότε. Αν είναι επείγον, πες το στο αίτημα για να έρθουν προσφορές από όσους μπορούν άμεσα.',
    faq: [['Υπάρχουν συνεργεία για επείγουσα απόφραξη;', 'Ναι. Κάθε επαγγελματίας γράφει στην προσφορά του πότε μπορεί να έρθει, ώστε να διαλέξεις τον πιο γρήγορο.'], ['Χρειάζεται να είμαι στο σπίτι;', 'Συνήθως ναι, εκτός αν πρόκειται για φρεάτιο σε εξωτερικό χώρο. Συνεννοείσαι απευθείας με τον επαγγελματία στο chat.']],
  },
  {
    slug: 'kleidaras', name: 'Κλειδαράς', acc: 'κλειδαρά', plural: 'κλειδαράδες', pluralAcc: 'κλειδαράδες', img: 'locksmith',
    intro: 'Κλειδώθηκες έξω, έχασες τα κλειδιά ή θέλεις αλλαγή κλειδαριάς;',
    jobs: ['Άνοιγμα πόρτας χωρίς ζημιά', 'Αλλαγή κυλίνδρου και κλειδαριάς', 'Θωρακισμένες πόρτες', 'Αντίγραφα κλειδιών', 'Κλειδαριές ασφαλείας', 'Επισκευή κλειδαριάς που κολλάει'],
    tip: 'Γράψε τι πόρτα είναι (απλή ή θωρακισμένη) και αν είσαι κλειδωμένος έξω τώρα, για να σε βρει ο πιο κοντινός κλειδαράς.',
    faq: [['Μπορώ να βρω κλειδαρά άμεσα;', 'Ναι. Στείλε αίτημα και οι κλειδαράδες της περιοχής σου ειδοποιούνται αμέσως. Στις προσφορές βλέπεις πότε μπορεί να έρθει ο καθένας.'], ['Πόσο κοστίζει το άνοιγμα πόρτας;', 'Η τιμή εξαρτάται από την πόρτα και την ώρα. Θα δεις την τιμή κάθε κλειδαρά στην προσφορά του, πριν αποφασίσεις.']],
  },
  {
    slug: 'metakomiseis', name: 'Μετακομίσεις', acc: 'συνεργείο μετακομίσεων', plural: 'συνεργεία μετακομίσεων', pluralAcc: 'συνεργεία μετακομίσεων', img: 'moving',
    intro: 'Μετακομίζεις και ψάχνεις αξιόπιστο συνεργείο;',
    jobs: ['Μετακομίσεις διαμερισμάτων', 'Μεταφορά μεμονωμένων επίπλων', 'Συσκευασία και αμπαλάζ', 'Αποσυναρμολόγηση και συναρμολόγηση επίπλων', 'Μετακομίσεις γραφείων', 'Ανυψωτικό για ψηλούς ορόφους'],
    tip: 'Γράψε από πού προς πού, τον όροφο, αν υπάρχει ασανσέρ και τα βασικά έπιπλα. Μια φωτογραφία του χώρου βοηθάει να βγει σωστή τιμή.',
    faq: [['Πόσο νωρίς να ζητήσω προσφορά;', 'Όσο νωρίτερα τόσο καλύτερα, ειδικά για αρχές και τέλη του μήνα. Θα δεις τη διαθεσιμότητα κάθε συνεργείου στην προσφορά.'], ['Περιλαμβάνεται η συσκευασία;', 'Εξαρτάται από το συνεργείο. Γράψε στο αίτημα αν τη χρειάζεσαι, ώστε να συμπεριληφθεί στην τιμή.']],
  },
  {
    slug: 'baby-sitter', name: 'Baby Sitter', acc: 'baby sitter', plural: 'baby sitters', pluralAcc: 'baby sitters', img: 'babysitter',
    intro: 'Ψάχνεις baby sitter για λίγες ώρες, για τα απογεύματα ή για τα Σαββατοκύριακα;',
    jobs: ['Φύλαξη βρεφών και νηπίων', 'Παραλαβή από σχολείο και απογευματινή φύλαξη', 'Βραδινή φύλαξη και Σαββατοκύριακα', 'Βοήθεια στα μαθήματα', 'Δημιουργική απασχόληση', 'Φύλαξη σε διακοπές'],
    tip: 'Γράψε ηλικία παιδιών, μέρες και ώρες. Προτίμησε baby sitters με το σήμα «Επαληθευμένη», που σημαίνει ότι έχουμε ελέγξει ταυτότητα και ποινικό μητρώο.',
    faq: [['Πώς ξέρω ότι η baby sitter είναι αξιόπιστη;', 'Όσες έχουν το σήμα «Επαληθευμένη» έχουν περάσει έλεγχο ταυτότητας και ποινικού μητρώου. Δες επίσης τις αξιολογήσεις και κανόνισε πρώτα μια γνωριμία.'], ['Μπορώ να βρω baby sitter για τακτική συνεργασία;', 'Ναι. Γράψε στο αίτημα τις μέρες και τις ώρες που χρειάζεσαι.']],
  },
  {
    slug: 'anakainisi', name: 'Ανακαίνιση', acc: 'συνεργείο ανακαίνισης', plural: 'συνεργεία ανακαίνισης', pluralAcc: 'συνεργεία ανακαίνισης', img: 'renovation',
    intro: 'Σκέφτεσαι ανακαίνιση σε μπάνιο, κουζίνα ή ολόκληρο σπίτι;',
    jobs: ['Ολική ανακαίνιση διαμερίσματος', 'Ανακαίνιση μπάνιου', 'Ανακαίνιση κουζίνας', 'Πλακάκια και δάπεδα', 'Γυψοσανίδες και ψευδοροφές', 'Μονώσεις και αντιμετώπιση υγρασίας'],
    tip: 'Γράψε τι θέλεις να αλλάξει, τα τετραγωνικά και πότε θέλεις να ξεκινήσει. Φωτογραφίες του χώρου βοηθούν να πάρεις προσφορές που μπορείς να συγκρίνεις.',
    faq: [['Μπορώ να πάρω προσφορές από πολλά συνεργεία;', 'Ναι. Λαμβάνεις προσφορές από διαφορετικά συνεργεία και βλέπεις τις 3 καλύτερες ταξινομημένες.'], ['Μπορώ να εντάξω την ανακαίνιση στο «Ανακαινίζω»;', 'Συζήτησέ το απευθείας με το συνεργείο, που θα σου πει τι δικαιολογητικά και τιμολόγια χρειάζονται.']],
  },
];

const AREAS = [
  { slug: 'athina', name: 'Αθήνα', in: 'στην Αθήνα', near: ['Κυψέλη', 'Παγκράτι', 'Αμπελόκηποι', 'Πατήσια', 'Κολωνάκι', 'Εξάρχεια'] },
  { slug: 'thessaloniki', name: 'Θεσσαλονίκη', in: 'στη Θεσσαλονίκη', near: ['Καλαμαριά', 'Τούμπα', 'Πυλαία', 'Εύοσμος', 'Νεάπολη', 'Κέντρο'] },
  { slug: 'peiraias', name: 'Πειραιάς', in: 'στον Πειραιά', near: ['Καστέλλα', 'Πειραϊκή', 'Νίκαια', 'Κερατσίνι', 'Κορυδαλλός', 'Δραπετσώνα'] },
  { slug: 'peristeri', name: 'Περιστέρι', in: 'στο Περιστέρι', near: ['Αιγάλεω', 'Πετρούπολη', 'Ίλιον', 'Χαϊδάρι', 'Άγιοι Ανάργυροι', 'Καματερό'] },
  { slug: 'chalandri', name: 'Χαλάνδρι', in: 'στο Χαλάνδρι', near: ['Μαρούσι', 'Βριλήσσια', 'Αγία Παρασκευή', 'Ψυχικό', 'Μελίσσια', 'Χολαργός'] },
  { slug: 'nea-smyrni', name: 'Νέα Σμύρνη', in: 'στη Νέα Σμύρνη', near: ['Παλαιό Φάληρο', 'Καλλιθέα', 'Άγιος Δημήτριος', 'Μοσχάτο', 'Δάφνη', 'Ταύρος'] },
  { slug: 'glyfada', name: 'Γλυφάδα', in: 'στη Γλυφάδα', near: ['Βούλα', 'Άλιμος', 'Ελληνικό', 'Βάρη', 'Αργυρούπολη', 'Ηλιούπολη'] },
  { slug: 'kallithea', name: 'Καλλιθέα', in: 'στην Καλλιθέα', near: ['Μοσχάτο', 'Νέα Σμύρνη', 'Ταύρος', 'Παλαιό Φάληρο', 'Πειραιάς', 'Κουκάκι'] },
  { slug: 'irakleio', name: 'Ηράκλειο Κρήτης', in: 'στο Ηράκλειο Κρήτης', near: ['Αλικαρνασσός', 'Γούρνες', 'Μαλάδες', 'Αμμουδάρα', 'Γάζι', 'Κέντρο'] },
  { slug: 'patra', name: 'Πάτρα', in: 'στην Πάτρα', near: ['Ρίο', 'Παραλία', 'Μεσάτιδα', 'Οβρυά', 'Αγυιά', 'Κέντρο'] },
];

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

const CSS = `*{margin:0;padding:0;box-sizing:border-box}
:root{--bg:#0A0803;--card:#14100A;--gold:#E8C66A;--gold2:#F3DC9B;--muted:rgba(255,255,255,.72);--line:rgba(232,198,106,.25)}
body{font-family:Inter,"Segoe UI",Arial,sans-serif;background:var(--bg);color:#fff;line-height:1.6}
a{color:var(--gold)}
.wrap{max-width:860px;margin:0 auto;padding:0 20px}
header{border-bottom:1px solid var(--line);padding:16px 0}
header .wrap{display:flex;justify-content:space-between;align-items:center}
.brand{font-weight:900;letter-spacing:4px;color:var(--gold);text-decoration:none;font-size:15px}
.dl{background:linear-gradient(90deg,#FFE29A,#D4AF55);color:#111;text-decoration:none;font-weight:800;padding:9px 18px;border-radius:12px;font-size:14px}
.hero{position:relative;margin:24px 0 8px;border-radius:24px;overflow:hidden;border:1px solid var(--line)}
.hero img{display:block;width:100%;height:280px;object-fit:cover;filter:brightness(.55)}
.hero .txt{position:absolute;left:0;right:0;bottom:0;padding:24px;background:linear-gradient(180deg,transparent,rgba(10,8,3,.95))}
.crumbs{font-size:12px;color:var(--muted);margin-bottom:6px}.crumbs a{color:var(--muted);text-decoration:none}
h1{font-size:34px;line-height:1.15;font-weight:900}
h1 span{color:var(--gold2)}
.lead{font-size:17px;color:var(--muted);margin-top:8px}
.cta{display:flex;flex-wrap:wrap;gap:10px;margin:22px 0}
.cta a{display:inline-block;padding:13px 20px;border-radius:14px;font-weight:800;text-decoration:none;font-size:15px}
.cta .p{background:linear-gradient(90deg,#FFE29A,#D4AF55);color:#111}
.cta .s{border:1px solid var(--gold);color:var(--gold)}
.stats{display:flex;gap:12px;margin:8px 0 28px}
.stats div{flex:1;border:1px solid var(--line);border-radius:16px;padding:12px;text-align:center;background:rgba(232,198,106,.05)}
.stats b{display:block;font-size:24px;color:var(--gold)}.stats i{font-style:normal;font-size:12px;color:var(--muted)}
h2{font-size:22px;margin:30px 0 12px;color:var(--gold2)}
p{color:var(--muted);margin-bottom:12px}
ul.jobs{list-style:none;display:grid;grid-template-columns:1fr 1fr;gap:10px}
ul.jobs li{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:12px 14px;font-size:14px}
ol.steps{padding-left:22px;color:var(--muted)}ol.steps li{margin-bottom:8px}ol.steps b{color:#fff}
.tip{background:rgba(232,198,106,.07);border:1px solid var(--gold);border-radius:16px;padding:16px;color:#fff;font-size:15px}
details{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px 16px;margin-bottom:10px}
summary{cursor:pointer;font-weight:700}details p{margin:10px 0 0}
.links{display:flex;flex-wrap:wrap;gap:8px}
.links a{border:1px solid var(--line);border-radius:30px;padding:7px 14px;font-size:13px;text-decoration:none;color:var(--gold2)}
footer{border-top:1px solid var(--line);margin-top:40px;padding:24px 0;font-size:13px;color:var(--muted)}
@media(max-width:600px){h1{font-size:27px}ul.jobs{grid-template-columns:1fr}.hero img{height:220px}.stats b{font-size:20px}}`;

function layout({ title, description, canonical, body, jsonld }) {
  return `<!doctype html>
<html lang="el">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title>
<meta name="description" content="${esc(description)}">
<link rel="canonical" href="${canonical}">
<meta property="og:type" content="website">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(description)}">
<meta property="og:url" content="${canonical}">
<meta property="og:locale" content="el_GR">
<style>${CSS}</style>
${jsonld ? `<script type="application/ld+json">${JSON.stringify(jsonld)}</script>` : ''}
</head>
<body>
<header><div class="wrap"><a class="brand" href="/">GOREALPRO</a><a class="dl" href="${PLAY}" rel="noopener">Κατέβασε δωρεάν</a></div></header>
<main class="wrap">
${body}
</main>
<footer><div class="wrap">GorealPro · Βρες επαγγελματία σε λίγα λεπτά · <a href="tel:+306937102492">693 710 2492</a> · <a href="mailto:info@gorealai.gr">info@gorealai.gr</a> · <a href="/ypiresies/">Όλες οι υπηρεσίες</a> · <a href="/privacy">Απόρρητο</a></div></footer>
</body>
</html>
`;
}

const ctaBlock = `<div class="cta"><a class="p" href="${PLAY}" rel="noopener">Google Play</a><a class="p" href="${IOS}" rel="noopener">App Store</a><a class="s" href="${WEBAPP}">Άνοιγμα από τον browser</a></div>`;
const statsBlock = `<div class="stats"><div><b>${STATS.pros}</b><i>επαγγελματίες</i></div><div><b>${STATS.specialties}</b><i>ειδικότητες</i></div><div><b>0 €</b><i>για τον πελάτη</i></div></div>`;

function servicePage(p, a) {
  const url = `${SITE}/ypiresies/${p.slug}/${a.slug}/`;
  const title = `${p.name} ${a.in} – Δωρεάν προσφορές σε λίγα λεπτά | GorealPro`;
  const description = `Βρες ${p.acc} ${a.in}. ${p.intro} Γράψε τι χρειάζεσαι και λάβε γραπτές προσφορές με τιμή από ${p.pluralAcc} της περιοχής σου. Δωρεάν.`;
  const otherAreas = AREAS.filter((x) => x.slug !== a.slug).map((x) => `<a href="/ypiresies/${p.slug}/${x.slug}/">${esc(p.name)} ${esc(x.in)}</a>`).join('');
  const otherProfs = PROFESSIONS.filter((x) => x.slug !== p.slug).map((x) => `<a href="/ypiresies/${x.slug}/${a.slug}/">${esc(x.name)} ${esc(a.in)}</a>`).join('');
  const faq = [
    [`Πώς βρίσκω ${p.acc} ${a.in};`, `Κατέβασε το GorealPro, γράψε ή πες με τη φωνή σου τι χρειάζεσαι και διάλεξε την περιοχή σου. Οι ${p.plural} ${a.in} και στις γύρω περιοχές ειδοποιούνται αμέσως και σου στέλνουν γραπτές προσφορές με τιμή.`],
    ...p.faq,
    ['Είναι δωρεάν για εμένα;', 'Ναι. Η εφαρμογή είναι εντελώς δωρεάν για όποιον ψάχνει επαγγελματία και δεν υπάρχει καμία δέσμευση.'],
  ];
  const body = `
<div class="hero"><img src="/img/hero-${p.img}.jpg" alt="${esc(p.name)} ${esc(a.in)}">
<div class="txt"><div class="crumbs"><a href="/">GorealPro</a> › <a href="/ypiresies/">Υπηρεσίες</a> › <a href="/ypiresies/${p.slug}/">${esc(p.name)}</a> › ${esc(a.name)}</div>
<h1>${esc(p.name)} <span>${esc(a.in)}</span></h1>
<div class="lead">${esc(p.intro)} Λάβε δωρεάν προσφορές από ${esc(p.pluralAcc)} της περιοχής σου, συνήθως μέσα σε λίγα λεπτά.</div></div></div>
${ctaBlock}
${statsBlock}
<h2>Τι μπορείς να ζητήσεις</h2>
<ul class="jobs">${p.jobs.map((j) => `<li>${esc(j)}</li>`).join('')}</ul>
<h2>Πώς δουλεύει</h2>
<ol class="steps">
<li><b>Γράψε ή πες με τη φωνή σου</b> τι χρειάζεσαι και πρόσθεσε φωτογραφίες ή βίντεο.</li>
<li><b>Οι ${esc(p.plural)} ${esc(a.in)}</b> και στις γύρω περιοχές (${esc(a.near.join(', '))}) ειδοποιούνται αμέσως.</li>
<li><b>Λαμβάνεις γραπτές προσφορές</b> με τιμή και διαθεσιμότητα και βλέπεις τις 3 καλύτερες.</li>
<li><b>Διαλέγεις</b> με βάση τιμή και αξιολογήσεις και μιλάς απευθείας μαζί τους στο chat ή στο τηλέφωνο.</li>
</ol>
<h2>Συμβουλή για γρηγορότερη προσφορά</h2>
<div class="tip">${esc(p.tip)}</div>
<h2>Συχνές ερωτήσεις</h2>
${faq.map(([q, ans]) => `<details><summary>${esc(q)}</summary><p>${esc(ans)}</p></details>`).join('\n')}
${ctaBlock}
<h2>${esc(p.name)} σε άλλες περιοχές</h2>
<div class="links">${otherAreas}</div>
<h2>Άλλες υπηρεσίες ${esc(a.in)}</h2>
<div class="links">${otherProfs}</div>`;
  const jsonld = [
    { '@context': 'https://schema.org', '@type': 'Service', serviceType: p.name, name: `${p.name} ${a.in}`, areaServed: { '@type': 'City', name: a.name }, provider: { '@type': 'Organization', name: 'GorealPro', url: SITE, telephone: '+306937102492' }, offers: { '@type': 'Offer', price: '0', priceCurrency: 'EUR', description: 'Δωρεάν προσφορές για τον πελάτη' } },
    { '@context': 'https://schema.org', '@type': 'FAQPage', mainEntity: faq.map(([q, ans]) => ({ '@type': 'Question', name: q, acceptedAnswer: { '@type': 'Answer', text: ans } })) },
    { '@context': 'https://schema.org', '@type': 'BreadcrumbList', itemListElement: [
      { '@type': 'ListItem', position: 1, name: 'GorealPro', item: `${SITE}/` },
      { '@type': 'ListItem', position: 2, name: 'Υπηρεσίες', item: `${SITE}/ypiresies/` },
      { '@type': 'ListItem', position: 3, name: p.name, item: `${SITE}/ypiresies/${p.slug}/` },
      { '@type': 'ListItem', position: 4, name: a.name, item: url },
    ] },
  ];
  return { url, html: layout({ title, description, canonical: url, body, jsonld }) };
}

function professionHub(p) {
  const url = `${SITE}/ypiresies/${p.slug}/`;
  const title = `${p.name} – Βρες ${p.acc} κοντά σου με δωρεάν προσφορές | GorealPro`;
  const description = `${p.intro} Βρες ${p.acc} στην περιοχή σου και λάβε γραπτές προσφορές με τιμή σε λίγα λεπτά. Δωρεάν για τον πελάτη.`;
  const body = `
<div class="hero"><img src="/img/hero-${p.img}.jpg" alt="${esc(p.name)}">
<div class="txt"><div class="crumbs"><a href="/">GorealPro</a> › <a href="/ypiresies/">Υπηρεσίες</a> › ${esc(p.name)}</div>
<h1>${esc(p.name)} <span>κοντά σου</span></h1><div class="lead">${esc(p.intro)} Λάβε δωρεάν προσφορές σε λίγα λεπτά.</div></div></div>
${ctaBlock}${statsBlock}
<h2>Τι μπορείς να ζητήσεις</h2>
<ul class="jobs">${p.jobs.map((j) => `<li>${esc(j)}</li>`).join('')}</ul>
<h2>Διάλεξε περιοχή</h2>
<div class="links">${AREAS.map((a) => `<a href="/ypiresies/${p.slug}/${a.slug}/">${esc(p.name)} ${esc(a.in)}</a>`).join('')}</div>
<h2>Συμβουλή</h2><div class="tip">${esc(p.tip)}</div>`;
  return { url, html: layout({ title, description, canonical: url, body }) };
}

function rootHub() {
  const url = `${SITE}/ypiresies/`;
  const title = 'Υπηρεσίες – Βρες επαγγελματία στην περιοχή σου | GorealPro';
  const description = 'Ηλεκτρολόγοι, υδραυλικοί, ελαιοχρωματιστές, καθαρίστριες, κλειδαράδες, baby sitters και 80+ ειδικότητες. Λάβε δωρεάν προσφορές σε λίγα λεπτά.';
  const body = `
<h1 style="margin-top:28px">Βρες επαγγελματία <span>στην περιοχή σου</span></h1>
<p class="lead">Γράψε τι χρειάζεσαι και λάβε γραπτές προσφορές με τιμή από επαγγελματίες κοντά σου. Δωρεάν για τον πελάτη.</p>
${ctaBlock}${statsBlock}
${PROFESSIONS.map((p) => `<h2><a href="/ypiresies/${p.slug}/" style="text-decoration:none">${esc(p.name)}</a></h2><div class="links">${AREAS.map((a) => `<a href="/ypiresies/${p.slug}/${a.slug}/">${esc(a.name)}</a>`).join('')}</div>`).join('\n')}`;
  return { url, html: layout({ title, description, canonical: url, body }) };
}

function write(rel, html) {
  const file = path.join(OUT, rel, 'index.html');
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, html);
}

const urls = [`${SITE}/`];
const root = rootHub(); write('', root.html); urls.push(root.url);
for (const p of PROFESSIONS) {
  const hub = professionHub(p); write(p.slug, hub.html); urls.push(hub.url);
  for (const a of AREAS) { const pg = servicePage(p, a); write(path.join(p.slug, a.slug), pg.html); urls.push(pg.url); }
}

const today = new Date().toISOString().slice(0, 10);
fs.writeFileSync(path.join(__dirname, '..', 'landing', 'sitemap.xml'),
  `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.map((u) => `  <url><loc>${u}</loc><lastmod>${today}</lastmod></url>`).join('\n')}\n</urlset>\n`);
fs.writeFileSync(path.join(__dirname, '..', 'landing', 'robots.txt'),
  `User-agent: *\nAllow: /\nDisallow: /admin.html\nDisallow: /app/\n\nSitemap: ${SITE}/sitemap.xml\n`);
console.log(`pages: ${urls.length - 1} (+ home) · sitemap: ${urls.length} urls`);
