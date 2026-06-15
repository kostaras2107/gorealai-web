import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:math';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'firebase_options.dart';
import 'splash_screen.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

// ═══════════════════════════════════════
// CONSTANTS
// ═══════════════════════════════════════
const String kBackendUrl = 'https://ai-backend-kkt7.onrender.com';
// Replace with your actual Stripe monthly subscription price ID from dashboard.stripe.com
const String kStripeMonthlyPriceId = 'price_REPLACE_WITH_YOUR_STRIPE_PRICE_ID';
final _analytics = FirebaseAnalytics.instance;
const Color kGold = Color(0xFFFFB340);
const Color kGoldLight = Color(0xFFFFD47A);
const Color kGoldDark = Color(0xFFCC8800);
const Color kBg = Color(0xFF060D1E);
const Color kGreen = Color(0xFF00D4AA);

// ═══════════════════════════════════════
// FCM PUSH NOTIFICATION SERVICE
// ═══════════════════════════════════════
class NotificationService {
  static final FirebaseMessaging _fcm = FirebaseMessaging.instance;

  static Future<void> init() async {
    await _fcm.requestPermission(alert: true, badge: true, sound: true);
    final token = await _fcm.getToken(vapidKey: 'BJsbku1gXCS_uLwKrDcSJ9hIDGEUdthxe7wc_dfbeIcwq4aE1SqK3IdMPZ6j1vj0or-SWNloikIXmzWfW0_YqTY');
    if (token != null) {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .update({'fcmToken': token});
      }
    }
    _fcm.onTokenRefresh.listen((newToken) async {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .update({'fcmToken': newToken});
      }
    });
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      debugPrint('📬 FCM: ${message.notification?.title}');
    });
  }

  static Future<void> saveReminder({
    required String userId,
    required String summary,
    required String text,
    required DateTime reminderTime,
  }) async {
    await FirebaseFirestore.instance.collection('reminders').add({
      'userId': userId,
      'summary': summary,
      'text': text,
      'reminderTime': Timestamp.fromDate(reminderTime),
      'sent': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }
}

// ═══════════════════════════════════════
// IN-APP REMINDER SERVICE
// ═══════════════════════════════════════
class ReminderService {
  static Timer? _timer;

  static void startChecking(BuildContext context, String userId) {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      _checkReminders(context, userId);
    });
  }

  static void stop() => _timer?.cancel();

  static Future<void> _checkReminders(BuildContext context, String userId) async {
    try {
      final now = DateTime.now();
      final snap = await FirebaseFirestore.instance
          .collection('reminders')
          .where('userId', isEqualTo: userId)
          .where('sent', isEqualTo: false)
          .get();
      for (final doc in snap.docs) {
        final data = doc.data();
        final rt = (data['reminderTime'] as Timestamp?)?.toDate();
        if (rt == null) continue;
        if (rt.isAfter(now.subtract(const Duration(minutes: 1))) &&
            rt.isBefore(now.add(const Duration(minutes: 1)))) {
          if (context.mounted) {
            _showDialog(context, data['summary'] ?? 'Υπενθύμιση');
            await doc.reference.update({'sent': true});
          }
        }
      }
    } catch (_) {}
  }

  static void _showDialog(BuildContext context, String message) {
    if (!context.mounted) return;
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: const Color(0xFF111111),
            border: Border.all(color: kGold.withValues(alpha: 0.5)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('⏰', style: TextStyle(fontSize: 40)),
            const SizedBox(height: 12),
            const Text('Υπενθύμιση',
                style: TextStyle(color: kGold, fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(color: _gw, fontSize: 14, height: 1.5)),
            const SizedBox(height: 20),
            GestureDetector(
              onTap: () => Navigator.pop(ctx),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14), color: kGold),
                child: const Center(
                    child: Text('OK',
                        style: TextStyle(
                            color: Colors.black, fontWeight: FontWeight.bold))),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════
// AUTH SERVICE
// ═══════════════════════════════════════
class AuthService {
  static Future<void> saveUser(String email) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('email', email);
    await prefs.setBool('hasAccount', true);
    await prefs.setBool('isLoggedIn', true);
  }

  static Future<String?> getUser() async =>
      (await SharedPreferences.getInstance()).getString('email');

  static Future<void> savePassword(String password) async =>
      (await SharedPreferences.getInstance()).setString('password', password);

  static Future<String?> getPassword() async =>
      (await SharedPreferences.getInstance()).getString('password');

  static Future<bool> hasAccount() async =>
      (await SharedPreferences.getInstance()).getBool('hasAccount') ?? false;

  static Future<void> logout() async =>
      (await SharedPreferences.getInstance()).clear();
}

// ═══════════════════════════════════════
// MAIN
// ═══════════════════════════════════════
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Crashlytics — catch Flutter framework errors
  FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;

  // FCM μπορεί να αποτύχει στο web — δεν σταματάμε το app
  try {
    await NotificationService.init();
  } catch (e) {
    debugPrint('NotificationService init error: $e');
  }
  final prefs = await SharedPreferences.getInstance();
  final savedTheme = prefs.getString('theme') ?? 'obsidian';
  runApp(GorealAiApp(initialTheme: savedTheme));
}

// ═══════════════════════════════════════
// APP THEME SYSTEM
// ═══════════════════════════════════════
class AppTheme {
  final String id;
  final Color accent;
  final Color background;
  final Color backgroundGradientEnd;
  final bool isLight;
  final Color _textBase;
  const AppTheme({
    required this.id,
    required this.accent,
    required this.background,
    required this.backgroundGradientEnd,
    this.isLight = false,
    Color textBase = Colors.white,
  }) : _textBase = textBase;

  // Returns adaptive color — used everywhere instead of Colors.white.withValues(alpha:X)
  // Low alpha (<0.15) = surface/border — boosted in light mode for visibility
  // High alpha (>0.15) = text/icon — same alpha in both modes
  Color adaptive(double alpha) {
    if (!isLight) return Color.fromRGBO(255, 255, 255, alpha);
    final a = alpha < 0.15 ? (alpha * 3.5).clamp(0.0, 1.0) : alpha;
    return Color.fromRGBO(_textBase.red, _textBase.green, _textBase.blue, a);
  }

  // Pure text color (replaces Colors.white as text)
  Color get text => _textBase;

  // Card surface for explicit dark hex cards
  Color get cardColor => isLight ? const Color(0xFFFFFFFF) : const Color(0xFF0E0B04);

  static const Map<String, AppTheme> themes = {
    'obsidian': AppTheme(
        id: 'obsidian',
        accent: Color(0xFFD4A843),
        background: Color(0xFF0A0800),
        backgroundGradientEnd: Color(0xFF050400)),
    'navy': AppTheme(
        id: 'navy',
        accent: Color(0xFFF0C040),
        background: Color(0xFF060D1A),
        backgroundGradientEnd: Color(0xFF030810)),
    'rose': AppTheme(
        id: 'rose',
        accent: Color(0xFFC4917A),
        background: Color(0xFF140C0C),
        backgroundGradientEnd: Color(0xFF0D0606)),
    'forest': AppTheme(
        id: 'forest',
        accent: Color(0xFF3DBA7E),
        background: Color(0xFF060E08),
        backgroundGradientEnd: Color(0xFF030804)),
    'arctic': AppTheme(
        id: 'arctic',
        accent: Color(0xFF64B5F6),
        background: Color(0xFF080C14),
        backgroundGradientEnd: Color(0xFF040710)),
    'liquid': AppTheme(
        id: 'liquid',
        accent: Color(0xFFD4AF37),
        background: Color(0xFFF5F0E8),
        backgroundGradientEnd: Color(0xFFE8DCC4),
        isLight: true,
        textBase: Color(0xFF1A1510)),
  };
  static AppTheme get(String id) => themes[id] ?? themes['obsidian']!;
}

// ── Global helpers ──────────────────────────────────────────────
// Replaces _g(X) throughout the codebase
Color _g(double alpha) => appThemeNotifier.value.adaptive(alpha);
// Replaces Colors.white as text/icon color
Color get _gw => appThemeNotifier.value.text;

// ── Premium glass card decoration ──
BoxDecoration _glassCard({double radius = 16, bool gold = false}) => BoxDecoration(
  borderRadius: BorderRadius.circular(radius),
  gradient: LinearGradient(
    begin: Alignment.topLeft, end: Alignment.bottomRight,
    colors: gold
        ? [kGold.withValues(alpha: 0.12), kGold.withValues(alpha: 0.04)]
        : [Colors.white.withValues(alpha: 0.07), Colors.white.withValues(alpha: 0.025)],
  ),
  border: Border.all(color: Colors.white.withValues(alpha: gold ? 0.18 : 0.07), width: 0.5),
  boxShadow: [
    BoxShadow(color: Colors.black.withValues(alpha: 0.55), blurRadius: 24, offset: const Offset(0, 10)),
    BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 8, offset: const Offset(0, 3)),
    if (gold) BoxShadow(color: kGold.withValues(alpha: 0.08), blurRadius: 20, offset: const Offset(0, 4)),
  ],
);

final ValueNotifier<AppTheme> appThemeNotifier =
    ValueNotifier<AppTheme>(AppTheme.themes['obsidian']!);

class GorealAiApp extends StatefulWidget {
  final String initialTheme;
  const GorealAiApp({super.key, this.initialTheme = 'obsidian'});
  @override
  State<GorealAiApp> createState() => _GorealAiAppState();
}

class _GorealAiAppState extends State<GorealAiApp> {
}

class _GorealAiAppState extends State<GorealAiApp> {
  @override
  void initState() {
    super.initState();
    appThemeNotifier.value = AppTheme.get(widget.initialTheme);
    appThemeNotifier.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    appThemeNotifier.removeListener(() => setState(() {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = appThemeNotifier.value;
    final accent = theme.accent;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'GorealAI',
      theme: ThemeData(
        brightness: theme.isLight ? Brightness.light : Brightness.dark,
        scaffoldBackgroundColor: theme.background,
        primaryColor: accent,
        appBarTheme: AppBarTheme(
          backgroundColor: theme.background,
          elevation: 0,
          centerTitle: true,
          iconTheme: IconThemeData(color: accent),
        ),
        colorScheme: theme.isLight
            ? ColorScheme.light(primary: accent, secondary: accent.withValues(alpha: 0.8), surface: theme.background, onPrimary: Colors.black, onSecondary: Colors.black)
            : ColorScheme.dark(primary: accent, secondary: accent.withValues(alpha: 0.7), surface: const Color(0xFF111111), onPrimary: Colors.black, onSecondary: Colors.black),
        dialogTheme: DialogThemeData(backgroundColor: theme.isLight ? Colors.white : const Color(0xFF111111)),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: theme.isLight ? const Color(0xFFF0F0F0) : const Color(0xFF1A1A1A),
          contentTextStyle: TextStyle(color: theme.isLight ? const Color(0xFF0D0D1E) : Colors.white),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        textButtonTheme: TextButtonThemeData(
            style: TextButton.styleFrom(foregroundColor: kGold)),
        iconTheme: const IconThemeData(color: kGold),
      ),
      home: const SplashScreen(),
    );
  }
}

// ═══════════════════════════════════════
// AUTH GATE
// ═══════════════════════════════════════
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator(color: kGold)));
        }
        if (!snapshot.hasData) return const LoginScreen();
        final user = snapshot.data!;
        if (!user.emailVerified) return const EmailVerificationScreen();
        return FutureBuilder<DocumentSnapshot>(
          future: FirebaseFirestore.instance
              .collection('users')
              .doc(snapshot.data!.uid)
              .get(),
          builder: (context, userSnap) {
            if (userSnap.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                  body:
                      Center(child: CircularProgressIndicator(color: kGold)));
            }
            final role = userSnap.data?.data() != null
                ? (userSnap.data!.data()
                        as Map<String, dynamic>)['role'] ??
                    'user'
                : 'user';
            if (role == 'professional') return const ProfessionalHomeScreen();
            return const HomeScreen();
          },
        );
      },
    );
  }
}

// ═══════════════════════════════════════
// ═══════════════════════════════════════
// EMAIL VERIFICATION SCREEN
// ═══════════════════════════════════════
class EmailVerificationScreen extends StatefulWidget {
  const EmailVerificationScreen({super.key});
  @override
  State<EmailVerificationScreen> createState() => _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<EmailVerificationScreen> {
  bool _checking = false;

  Future<void> _checkVerified() async {
    setState(() => _checking = true);
    await FirebaseAuth.instance.currentUser?.reload();
    final user = FirebaseAuth.instance.currentUser;
    if (user != null && user.emailVerified) {
      if (mounted) {
        Navigator.pushReplacement(
            context, MaterialPageRoute(builder: (_) => const AuthGate()));
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Το email δεν έχει επαληθευτεί ακόμα.')));
      }
    }
    if (mounted) setState(() => _checking = false);
  }

  Future<void> _resend() async {
    try {
      await FirebaseAuth.instance.currentUser?.sendEmailVerification();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('✉️ Νέο email στάλθηκε!')));
      }
    } catch (_) {}
  }

  Color get _g => Colors.white;

  @override
  Widget build(BuildContext context) {
    final email = FirebaseAuth.instance.currentUser?.email ?? '';
    return Scaffold(
      backgroundColor: const Color(0xFF0A0804),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('✉️', style: TextStyle(fontSize: 56)),
              const SizedBox(height: 20),
              const Text('Επαλήθευσε το email σου',
                  style: TextStyle(
                      fontFamily: 'Raleway',
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: Colors.white)),
              const SizedBox(height: 12),
              Text('Στάλθηκε email επαλήθευσης στο\n$email',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 14, height: 1.5)),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _checking ? null : _checkVerified,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: kGold,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                  child: _checking
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                      : const Text('Επαλήθευσα — Συνέχεια',
                          style: TextStyle(fontFamily: 'Raleway', fontWeight: FontWeight.w700, fontSize: 15)),
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _resend,
                child: const Text('Αποστολή νέου email', style: TextStyle(color: kGold)),
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator(color: kGold)));
        }
        if (!snapshot.hasData) return const LoginScreen();
        final user = snapshot.data!;
        final isDemo = user.email == 'demo@gorealai.app';
        if (!user.emailVerified && !isDemo) return const EmailVerificationScreen();
        return FutureBuilder<DocumentSnapshot>(
          future: FirebaseFirestore.instance
              .collection('users')
              .doc(snapshot.data!.uid)
              .get(),
          builder: (context, userSnap) {
            if (userSnap.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                  body:
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  final _confirmPass = TextEditingController();
  final _name = TextEditingController();
  final _lastName = TextEditingController();
  final _phone = TextEditingController();
  String? _selectedSpecialty;
  String? _selectedArea;
  bool _loading = false;
  bool _isLogin = true;
  String _role = 'user';
  Uint8List? _selfieBytes;
  late AnimationController _fadeCtrl;
  late Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900));
    _fade = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _fadeCtrl.forward();
    Future.delayed(const Duration(milliseconds: 300), () async {
      final has = await AuthService.hasAccount();
      if (has) {
        final prefs = await SharedPreferences.getInstance();
        if (prefs.getBool('biometric_enabled') ?? true) {
          _autoLoginWithBiometrics();
        }
      }
    });
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    _email.dispose();
    _pass.dispose();
    _confirmPass.dispose();
    _name.dispose();
    _lastName.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _takeSelfie() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
        source: ImageSource.camera, imageQuality: 80);
    if (picked == null || !mounted) return;
    final bytes = await picked.readAsBytes();
  Future<String?> _uploadSelfie(Uint8List bytes, String uid) async {
    try {
      final bucket = 'shoppilot-app-e4104.firebasestorage.app';
      final path = 'profile_photos/$uid.jpg';
      final idToken = await FirebaseAuth.instance.currentUser?.getIdToken() ?? '';
      final encodedPath = Uri.encodeComponent(path);
      final uploadUrl = 'https://firebasestorage.googleapis.com/v0/b/$bucket/o?uploadType=media&name=$encodedPath';
      final res = await http.post(Uri.parse(uploadUrl),
          headers: {'Content-Type': 'image/jpeg', 'Authorization': 'Firebase $idToken'},
          body: bytes).timeout(const Duration(seconds: 30));
      if (res.statusCode == 200) {
        final token = (jsonDecode(res.body) as Map<String, dynamic>)['downloadTokens'] as String? ?? '';
        return token.isNotEmpty
            ? 'https://firebasestorage.googleapis.com/v0/b/$bucket/o/$encodedPath?alt=media&token=$token'
            : 'https://firebasestorage.googleapis.com/v0/b/$bucket/o/$encodedPath?alt=media';
      }
    } catch (_) {}
    return null;
  }

  Future<void> _autoLoginWithBiometrics() async {
    final email = await AuthService.getUser();
    final password = await AuthService.getPassword();
    if (email == null || password == null) return;
    final auth = LocalAuthentication();
  Future<void> _resend() async {
    try {
      await FirebaseAuth.instance.currentUser?.sendEmailVerification();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('✉️ Νέο email στάλθηκε!')));
      }
    } catch (_) {}
  }

  Color get _g => Colors.white;

  @override
  Widget build(BuildContext context) {
    final email = FirebaseAuth.instance.currentUser?.email ?? '';
    return Scaffold(
      backgroundColor: const Color(0xFF0A0804),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('✉️', style: TextStyle(fontSize: 56)),
              const SizedBox(height: 20),
              const Text('Επαλήθευσε το email σου',
                  style: TextStyle(
                      fontFamily: 'Raleway',
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: Colors.white)),
              const SizedBox(height: 12),
              Text('Στάλθηκε email επαλήθευσης στο\n$email',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 14, height: 1.5)),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _checking ? null : _checkVerified,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: kGold,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                  child: _checking
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                      : const Text('Επαλήθευσα — Συνέχεια',
                          style: TextStyle(fontFamily: 'Raleway', fontWeight: FontWeight.w700, fontSize: 15)),
                ),

        // Upload selfie if taken
        String? selfieUrl;
        if (_selfieBytes != null) {
          selfieUrl = await _uploadSelfie(_selfieBytes!, cred.user!.uid);
        }

        await FirebaseFirestore.instance
            .collection('users')
            .doc(cred.user!.uid)
            .set({
          'name': fullName,
          'city': _selectedArea ?? '',
          'phone': _phone.text.trim(),
          'role': _role,
          if (selfieUrl != null) 'profilePhotoUrl': selfieUrl,
          'createdAt': FieldValue.serverTimestamp(),
        });
        if (_role == 'professional') {
          await FirebaseFirestore.instance.collection('professionals').add({
            'name': fullName,
            'email': _email.text.trim(),
            'phone': _phone.text.trim(),
            'specialty': _selectedSpecialty ?? '',
            'area': _selectedArea ?? '',
            'is_active': true,
            'userId': cred.user!.uid,
            if (selfieUrl != null) 'profilePhotoUrl': selfieUrl,
            'createdAt': FieldValue.serverTimestamp(),
          });
        }
        await AuthService.saveUser(_email.text.trim());
        await AuthService.savePassword(_pass.text.trim());
        _analytics.logSignUp(signUpMethod: 'email');
        if (mounted) {
          Navigator.pushReplacement(
              context, MaterialPageRoute(builder: (_) => const EmailVerificationScreen()));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Σφάλμα: $e')));
      }
    }
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom + 24),
          child: Center(
            child: FadeTransition(
              opacity: _fade,
              child: ClipRRect(
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom + 24),
          child: Center(
            child: FadeTransition(
              opacity: _fade,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(30),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                    width: 360,
                    margin: const EdgeInsets.symmetric(vertical: 32),
                    padding: const EdgeInsets.all(28),
                    decoration: BoxDecoration(
                      color: _g(0.06),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      ShaderMask(
                        shaderCallback: (b) => const LinearGradient(
                            colors: [kGoldLight, kGold]).createShader(b),
                        child: const Text('GorealAI',
                            style: TextStyle(
                                fontSize: 36,
                                fontWeight: FontWeight.w600,
                                color: Colors.white)),
                      ),
                      const SizedBox(height: 6),
                      Text('The first app with Reverse Auction',
                          style: TextStyle(
                              fontSize: 12,
                              color: _g(0.4),
                              letterSpacing: 0.3)),
                      const SizedBox(height: 20),

                      // Role toggle
                      if (!_isLogin) ...[
                        Container(
                          decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              color: _g(0.05)),
                          child: Row(children: [
                            Expanded(
                                child: GestureDetector(
                              onTap: () => setState(() => _role = 'user'),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    color: _role == 'user'
                                        ? kGold
                                        : Colors.transparent),
                                child: Center(
                                    child: Text('👤 Χρήστης',
                                        style: TextStyle(
                                            color: _role == 'user'
                                                ? Colors.black
                                                : Colors.white54,
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13))),
                              ),
                            )),
                            Expanded(
                                child: GestureDetector(
                              onTap: () =>
                                  setState(() => _role = 'professional'),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    color: _role == 'professional'
                                        ? kGold
                                        : Colors.transparent),
                                child: Center(
                                    child: Text('🔧 Επαγγελματίας',
                                        style: TextStyle(
                                            color: _role == 'professional'
                                                ? Colors.black
                                                : Colors.white54,
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13))),
                              ),
                            )),
                          ]),
                        ),
                        const SizedBox(height: 14),
                        Row(children: [
                          Expanded(
                              child: TextField(
                                  controller: _name,
                                  decoration: const InputDecoration(
  }

  @override
  void initState() {
    super.initState();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadProfile();
    _setOnline(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      if (uid.isNotEmpty && mounted) {
        ReminderService.startChecking(context, uid);
        _listenActiveRequest(uid);
      }
    });
  }

  void _listenActiveRequest(String uid) {
    // Παρακολουθεί active αιτήματα (χωρίς orderBy)
    FirebaseFirestore.instance
        .collection('requests')
        .where('userId', isEqualTo: uid)
        .where('status', isEqualTo: 'active')
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final activeReqs = snap.docs.map((doc) {
        final d = doc.data();
        return {
          'id': doc.id,
          'status': 'active',
          'desc': d['description'] ?? '',
          'criteria': d['criteria'] ?? 'cheap',
          'expiresAt': d['expiresAt'],
        };
      }).toList();
          if (selfieUrl != null) 'profilePhotoUrl': selfieUrl,
          'createdAt': FieldValue.serverTimestamp(),
        });
        if (_role == 'professional') {
          await FirebaseFirestore.instance
              .collection('professionals')
              .doc(cred.user!.uid)
              .set({
            'name': fullName,
            'email': _email.text.trim(),
            'phone': _phone.text.trim(),
            // primary fields (backward compat with old matching queries)
            'specialty': _selectedSpecialties.isNotEmpty ? _selectedSpecialties.first : '',
            'area': _selectedAreas.isNotEmpty ? _selectedAreas.first : '',
            // multi-value arrays (new matching)
            'specialties': _selectedSpecialties,
            'areas': _selectedAreas,
            'is_active': true,
            'userId': cred.user!.uid,
            if (selfieUrl != null) 'profilePhotoUrl': selfieUrl,
            'portfolioPhotos': [],
            'createdAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        }
        await AuthService.saveUser(_email.text.trim());
        await AuthService.savePassword(_pass.text.trim());
        _analytics.logSignUp(signUpMethod: 'email');
        if (mounted) {
          Navigator.pushReplacement(
              context, MaterialPageRoute(builder: (_) => const EmailVerificationScreen()));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Σφάλμα: $e')));
      }
    }
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom + 24),
          child: Center(
// MISSING LINE 910
// MISSING LINE 911
// MISSING LINE 912
// MISSING LINE 913
// MISSING LINE 914
// MISSING LINE 915
// MISSING LINE 916
// MISSING LINE 917
// MISSING LINE 918
// MISSING LINE 919
  bool _loading = false;
  bool _isLogin = true;
  bool _obscurePass = true;
  bool _obscureConfirm = true;
  String _role = 'user';
  Uint8List? _selfieBytes;
  late AnimationController _fadeCtrl;
  late Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900));
    _fade = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _fadeCtrl.forward();
    // Check URL param: ?signup=pro → open signup as professional
    try {
      final params = Uri.base.queryParameters;
      if (params['signup'] == 'pro') {
        _isLogin = false;
        _role = 'professional';
      }
    } catch (_) {}
    Future.delayed(const Duration(milliseconds: 300), () async {
      final has = await AuthService.hasAccount();
      if (has) {
        final prefs = await SharedPreferences.getInstance();
        if (prefs.getBool('biometric_enabled') ?? true) {
          _autoLoginWithBiometrics();
  bool _loading = false;
  bool _isLogin = true;
  bool _obscurePass = true;
  bool _obscureConfirm = true;
  String _role = 'user';
  Uint8List? _selfieBytes;
  void _openRequestWithProfession(String profession) {
    Navigator.push(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 400),
          pageBuilder: (_, __, ___) => RequestScreen(
              userId: _userId ?? '',
              userName: _userName ?? 'Χρήστης',
              initialProfession: profession,
              initialLocation: 'Κοντά μου'),
          transitionsBuilder: (_, a, __, c) => SlideTransition(
              position: Tween<Offset>(
                      begin: const Offset(0, 1), end: Offset.zero)
                  .animate(CurvedAnimation(
                      parent: a, curve: Curves.easeOutCubic)),
              child: c),
        ));
  }

                      ],

                      // Specialty picker
                      if (!_isLogin && _role == 'professional') ...[
                        GestureDetector(
                          onTap: () async {
                            final r = await showModalBottomSheet<String>(
                                context: context,
                                backgroundColor: Colors.transparent,
                                isScrollControlled: true,
                                ]),
                          ),
                        ),
                      ],

                      const SizedBox(height: 10),
                      TextButton(
                        onPressed: () => setState(() {
                          _isLogin = !_isLogin;
                          _role = 'user';
                        }),
                        child: Text(
                            _isLogin
                                ? 'Δεν έχεις λογαριασμό; Sign up'
                                : 'Έχεις λογαριασμό; Login',
                            style: TextStyle(color: _g(0.7))),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Dropdown field helper ──
class _DropdownField extends StatelessWidget {
  final String? value;
  final String hint;
  const _DropdownField({required this.value, required this.hint});
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
        decoration: BoxDecoration(
          color: _g(0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: value != null
                  ? kGold.withValues(alpha: 0.6)
                  : kGold.withValues(alpha: 0.2)),
        ),
        child: Row(children: [
          Expanded(
              child: Text(value ?? hint,
                  style: TextStyle(
                      color: value != null
                          ? Colors.white
                          : _g(0.4),
                      fontSize: 14))),
          Icon(Icons.arrow_drop_down, color: kGold.withValues(alpha: 0.6)),
        ]),
      );
class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  String? _userName;
  String? _userId;
  int _navIndex = 0;
  // Ενεργά αιτήματα (για το G button — μέχρι 2)
  List<Map<String, dynamic>> _activeRequests = []; // list of {id, status, desc, criteria, expiresAt}
  List<Map<String, dynamic>> _activeRegularReqs = [];
  List<Map<String, dynamic>> _activeProjectReqs = [];

  String _vocative(String? n) {
    if (n == null || n.isEmpty) return '';
    return n.endsWith('ς') ? n.substring(0, n.length - 1) : n;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadProfile();
    _setOnline(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      if (uid.isNotEmpty && mounted) {
        ReminderService.startChecking(context, uid);
        _listenActiveRequest(uid);
        _listenActiveProjectRequests(uid);
      }
    });
  }

  void _listenActiveRequest(String uid) {
    // Παρακολουθεί active αιτήματα (χωρίς orderBy)
    FirebaseFirestore.instance
        .collection('requests')
        .where('userId', isEqualTo: uid)
        .where('status', isEqualTo: 'active')
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final now = DateTime.now();
      // Auto-cancel stale active requests that have expired
      for (final doc in snap.docs) {
        final expiresAt = doc.data()['expiresAt'];
        if (expiresAt != null) {
          final exp = (expiresAt as Timestamp).toDate();
          if (exp.isBefore(now.subtract(const Duration(minutes: 2)))) {
            doc.reference.update({'status': 'completed'}).catchError((_) {});
          }
        } else {
          // No expiresAt — stale if created > 20 min ago
          final createdTs = doc.data()['createdAt'];
          if (createdTs != null) {
            final created = (createdTs as Timestamp).toDate();
            if (now.difference(created).inMinutes > 20) {
              doc.reference.update({'status': 'completed'}).catchError((_) {});
            }
          }
        }
      }

      final activeReqs = snap.docs.where((doc) {
        final expiresAt = doc.data()['expiresAt'];
        if (expiresAt == null) return false; // No timer = stale, skip
        final exp = (expiresAt as Timestamp).toDate();
        return exp.isAfter(now); // Only show if timer hasn't expired
      }).map((doc) {
        final d = doc.data();
        return {
          'id': doc.id,
          'status': 'active',
          'desc': d['description'] ?? '',
          'criteria': d['criteria'] ?? 'cheap',
          'expiresAt': d['expiresAt'],
        };
      }).toList();

      // Ταξινόμηση κατά createdAt (πιο πρόσφατα πρώτα)
      activeReqs.sort((a, b) {
        final aTs = (snap.docs.firstWhere((d) => d.id == a['id'])
            .data()['createdAt'] as dynamic)?.millisecondsSinceEpoch ?? 0;
        final bTs = (snap.docs.firstWhere((d) => d.id == b['id'])
            .data()['createdAt'] as dynamic)?.millisecondsSinceEpoch ?? 0;
        return bTs.compareTo(aTs);
      });

      final limited = activeReqs.take(2).toList();

      if (limited.isNotEmpty) {
        _activeRegularReqs = limited;
        _mergeActiveRequests();
      } else {
        // Fallback: έλεγξε completed πρόσφατα
        FirebaseFirestore.instance
            .collection('requests')
            .where('userId', isEqualTo: uid)
            .where('status', isEqualTo: 'completed')
            .limit(5)
            .get()
            .then((snap2) {
          if (!mounted) return;
          final now = DateTime.now();
          final recent = snap2.docs.where((doc) {
            final tsMs = (doc.data()['createdAt'] as dynamic)?.millisecondsSinceEpoch;
            if (tsMs == null) return false;
            if (doc.data()['selectedPro'] != null) return false;
            if (doc.data()['offersViewed'] == true) return false;
            return now.difference(DateTime.fromMillisecondsSinceEpoch(tsMs)).inHours < 2;
          }).take(2).map((doc) {
            final d = doc.data();
            return {
              'id': doc.id,
              'status': 'completed',
              'desc': d['description'] ?? '',
              'criteria': d['criteria'] ?? 'cheap',
              'expiresAt': null,
            };
          }).toList();
          _activeRegularReqs = recent;
          _mergeActiveRequests();
        }).catchError((Object _) {
          _activeRegularReqs = [];
          _mergeActiveRequests();
        });
      }
    }, onError: (Object _) {
      _activeRegularReqs = [];
      _mergeActiveRequests();
    });
  }

  void _listenActiveProjectRequests(String uid) {
    FirebaseFirestore.instance
        .collection('project_requests')
        .where('userId', isEqualTo: uid)
        .where('status', isEqualTo: 'active')
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final now = DateTime.now();
      for (final doc in snap.docs) {
        final expiresAt = doc.data()['expiresAt'];
        if (expiresAt != null) {
          final exp = (expiresAt as Timestamp).toDate();
          if (exp.isBefore(now.subtract(const Duration(minutes: 2)))) {
            doc.reference.update({'status': 'completed'}).catchError((_) {});
          }
        }
      }
      _activeProjectReqs = snap.docs.where((doc) {
        final expiresAt = doc.data()['expiresAt'];
        if (expiresAt == null) return false;
        final exp = (expiresAt as Timestamp).toDate();
        return exp.isAfter(now);
      }).map((doc) {
        final d = doc.data();
        return {
          'id': doc.id,
          'status': 'active',
          'desc': d['description'] ?? '',
          'criteria': d['criteria'] ?? 'cheap',
          'expiresAt': d['expiresAt'],
          'isProject': true,
        };
      }).toList();
      _mergeActiveRequests();
    }, onError: (Object _) {
      _activeProjectReqs = [];
      _mergeActiveRequests();
    });
  }

  void _mergeActiveRequests() {
    if (!mounted) return;
    final merged = [..._activeRegularReqs, ..._activeProjectReqs];
    setState(() => _activeRequests = merged.take(2).toList());
  }

  // Ενεργά αιτήματα (για το G button — μέχρι 2)
  List<Map<String, dynamic>> _activeRequests = []; // list of {id, status, desc, criteria, expiresAt}
  List<Map<String, dynamic>> _activeRegularReqs = [];
  List<Map<String, dynamic>> _activeProjectReqs = [];
  List<Map<String, dynamic>> _activeEventReqs = [];

  String _vocative(String? n) {
    if (n == null || n.isEmpty) return '';
    return n.endsWith('ς') ? n.substring(0, n.length - 1) : n;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadProfile();
    _setOnline(true);
    // Listen for offer selection → clear stale hero card
    offerSelectedNotifier.addListener(_onOfferSelected);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      if (uid.isNotEmpty && mounted) {
        ReminderService.startChecking(context, uid);
        _listenActiveRequest(uid);
        _listenActiveProjectRequests(uid);
        _listenActiveEventRequests(uid);
      }
    });
  }

  void _onOfferSelected() {
    if (!mounted) return;
    setState(() {
      _activeRegularReqs = [];
      _activeRequests = [];
    });
  }

  void _listenActiveRequest(String uid) {
    // Παρακολουθεί active αιτήματα (χωρίς orderBy)
    FirebaseFirestore.instance
        .collection('requests')
        .where('userId', isEqualTo: uid)
        .where('status', isEqualTo: 'active')
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final now = DateTime.now();
      // Auto-cancel stale active requests that have expired
      for (final doc in snap.docs) {
        final expiresAt = doc.data()['expiresAt'];
        if (expiresAt != null) {
  void _openPortfolioGallery() {
    Navigator.push(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 400),
          pageBuilder: (_, __, ___) => const PortfolioGalleryScreen(),
          transitionsBuilder: (_, a, __, c) => SlideTransition(
              position: Tween<Offset>(
                      begin: const Offset(1, 0), end: Offset.zero)
                  .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
              child: c),
        ));
  }

  void _openMyOffers() {
    if (_activeRequests.isEmpty) {
      _openRequest();
      return;
    }
    if (_activeRequests.length == 1) {
      _navigateToRequest(_activeRequests.first);
      return;
    }
    // 2 αιτήματα — popup για επιλογή
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(20),
        decoration: const BoxDecoration(
          color: Color(0xFF0E0B04),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 36, height: 4,
          transitionsBuilder: (_, a, __, c) => SlideTransition(
              position: Tween<Offset>(
                      begin: const Offset(0, 1), end: Offset.zero)
                  .animate(CurvedAnimation(
                      parent: a, curve: Curves.easeOutCubic)),
              child: c),
        ));
  }

  void _openPortfolioGallery() {
    Navigator.push(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 400),
          pageBuilder: (_, __, ___) => const EventOrganizerScreen(),
          transitionsBuilder: (_, a, __, c) => SlideTransition(

  void _listenActiveProjectRequests(String uid) {
                  .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
              child: c),
        ));
  }

  void _openMyOffers() {
    if (_activeRequests.isEmpty) {
      _openRequest();
      return;
    }
    if (_activeRequests.length == 1) {
      _navigateToRequest(_activeRequests.first);
      return;
    }
    // 2 αιτήματα — popup για επιλογή
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(20),
        decoration: const BoxDecoration(
          color: Color(0xFF0E0B04),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 36, height: 4,
              decoration: BoxDecoration(color: _g(0.2),
                  borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 16),
          const Text('Τα αιτήματά σου', style: TextStyle(
              fontFamily: 'Raleway', fontSize: 18,
              fontWeight: FontWeight.w800, color: Colors.white)),
          const SizedBox(height: 4),
          Text('Επέλεξε ποιο θέλεις να δεις',
              style: TextStyle(fontSize: 12, color: _g(0.4))),
          const SizedBox(height: 16),
          ..._activeRequests.asMap().entries.map((e) {
            final req = e.value;
            final isActive = req['status'] == 'active';
            // Υπολογισμός χρόνου που απομένει
            String timeLeft = '';
            if (isActive && req['expiresAt'] != null) {
              try {
                final exp = (req['expiresAt'] as dynamic).toDate() as DateTime;
                final diff = exp.difference(DateTime.now());
                if (diff.isNegative) {
                  timeLeft = 'Έληξε';
                } else {
                  final m = diff.inMinutes;
                  final s = diff.inSeconds % 60;
        final expiresAt = doc.data()['expiresAt'];
        if (expiresAt != null) {
          final exp = (expiresAt as Timestamp).toDate();
          if (exp.isBefore(now.subtract(const Duration(minutes: 2)))) {
            doc.reference.update({'status': 'completed'}).catchError((_) {});
          }
        }
      }
      _activeEventReqs = snap.docs.where((doc) {
        final expiresAt = doc.data()['expiresAt'];
        if (expiresAt == null) return false;
        final exp = (expiresAt as Timestamp).toDate();
        return exp.isAfter(now);
      }).map((doc) {
        final d = doc.data();
        return {
          'id': doc.id,
          'status': 'active',
          'desc': '${d['categoryEmoji'] ?? '🎉'} ${d['categoryTitle'] ?? ''} · ${d['location'] ?? ''}',
          'criteria': 'cheap',
          'expiresAt': d['expiresAt'],
          'isEvent': true,
          'offersCount': d['offersCount'] ?? 0,
          'prosNotified': d['prosNotified'] ?? 5,
        };
      }).toList();
      _mergeActiveRequests();
    }, onError: (Object _) {
      _activeEventReqs = [];
      _mergeActiveRequests();
    });
  }

  void _mergeActiveRequests() {
    if (!mounted) return;
    );
  }

  void _navigateToRequest(Map<String, dynamic> req) {
    final collection = req['isProject'] == true ? 'project_requests' : 'requests';
    if (req['status'] == 'active') {
      Navigator.push(context, PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 400),
        pageBuilder: (_, __, ___) => WaitingScreen(
          requestId: req['id'],
          userId: _userId ?? '',
          description: req['desc'] ?? '',
          criteria: req['criteria'] ?? 'cheap',
          collection: collection,
        ),
        transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
      ));
    } else {
      // Mark as viewed so it doesn't reappear on next app launch
      FirebaseFirestore.instance
          .collection(collection)
          .doc(req['id'])
          .update({'offersViewed': true}).catchError((_) {});
      Navigator.push(context, PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 400),
        pageBuilder: (_, __, ___) => OffersScreen(
          requestId: req['id'],
          userId: _userId ?? '',
          description: req['desc'] ?? '',
          criteria: req['criteria'] ?? 'cheap',
        ),
        transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
      )).then((_) {
        if (mounted) setState(() => _activeRequests.removeWhere((r) => r['id'] == req['id'] && r['status'] == 'completed'));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(children: [
          // TOP BAR
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  ShaderMask(
                    shaderCallback: (b) => const LinearGradient(
                            snap.hasData ? snap.data!.docs.length : 0;
                        return Row(children: [
                          Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: kGreen)),
                          const SizedBox(width: 4),
                          Text('$count online',
                              style: TextStyle(
                                  fontSize: 10,
                                  color:
                                      _g(0.3))),
                        ]);
                      },
                    ),
                    const SizedBox(width: 12),
                    _NotificationBell(userId: _userId ?? ''),
                  ]),
                ]),
          ),
        ));
  }

  void _openPortfolioGallery() {
    Navigator.push(
        context,
        requestId: req['id'],
        userId: _userId ?? '',
        description: req['desc'] ?? '',
        criteria: 'cheap',
        collection: 'event_requests',
            child: _buildHome(),
          ),

          // BOTTOM NAV
          _BottomNav(
            navIndex: _navIndex,
            userName: _userName,
            hasActiveRequest: _activeRequests.isNotEmpty,
            activeRequestId: _activeRequests.isNotEmpty ? _activeRequests.first['id'] as String? : null,
            onHome: () => setState(() => _navIndex = 0),
            onFab: _openPortfolioGallery,
            onHistory: () {
              setState(() => _navIndex = 2);
              Navigator.push(
                  context,
                  PageRouteBuilder(
                    transitionDuration: const Duration(milliseconds: 350),
                    pageBuilder: (_, __, ___) =>
                        RequestHistoryScreen(userId: _userId ?? ''),
                    transitionsBuilder: (_, a, __, c) =>
                        FadeTransition(opacity: a, child: c),
                  )).then((_) => setState(() => _navIndex = 0));
            },
            onProfile: () {
              setState(() => _navIndex = 3);
              Navigator.push(
                  context,
                  PageRouteBuilder(
                    transitionDuration: const Duration(milliseconds: 350),
                    pageBuilder: (_, __, ___) => const ProfileScreen(),
                    transitionsBuilder: (_, a, __, c) =>
                        FadeTransition(opacity: a, child: c),
                  )).then((_) => setState(() => _navIndex = 0));
            },
          ),
        ]),
      ),
    );
  }

      });
    }
  }

  @override
                final diff = exp.difference(DateTime.now());
                if (diff.isNegative) {
                  timeLeft = 'Έληξε';
                } else {
                  final m = diff.inMinutes;
                  final s = diff.inSeconds % 60;
                  timeLeft = '${m}:${s.toString().padLeft(2, '0')} απομένουν';
                }
              } catch (_) {}
            }
            return GestureDetector(
              onTap: () {
                Navigator.pop(ctx);
                _navigateToRequest(req);
              },
              child: Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  color: isActive
                      ? kGold.withValues(alpha: 0.08)
                      : kGreen.withValues(alpha: 0.08),
                  border: Border.all(
                      color: isActive
                          ? kGold.withValues(alpha: 0.3)
                          : kGreen.withValues(alpha: 0.3)),
                ),
                child: Row(children: [
                  Container(width: 46, height: 46,
                      decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(13),
                          color: isActive
                              ? kGold.withValues(alpha: 0.12)
                              : kGreen.withValues(alpha: 0.12)),
                      child: Center(child: Text(isActive ? '⏳' : '🏆',
                          style: const TextStyle(fontSize: 24)))),
                  const SizedBox(width: 12),
                  Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start, children: [
                    color: _g(0.45),
                    fontSize: 14)),
          ]),
        ),

        const SizedBox(height: 28),

        // HERO — Dynamic (split when both regular + project active)
        if (_activeRegularReqs.isEmpty && _activeProjectReqs.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _EmptyHeroCard(onTap: _openRequest),
          )
        else ...[
          if (_activeRegularReqs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _ActiveRequestHeroCard(
                requests: _activeRegularReqs,
                onTap: () => _navigateToRequest(_activeRegularReqs.first),
                onNewRequest: _openRequest,
              ),
            ),
          if (_activeRegularReqs.isNotEmpty && _activeProjectReqs.isNotEmpty)
            const SizedBox(height: 12),
          if (_activeProjectReqs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _ActiveRequestHeroCard(
                requests: _activeProjectReqs,
                onTap: () => _navigateToRequest(_activeProjectReqs.first),
                onNewRequest: _openPortfolioGallery,
                isProject: true,
              ),
            ),
        ],
        const SizedBox(height: 28),

        // ΠΩΣ ΛΕΙΤΟΥΡΓΕΙ
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Text('Πώς λειτουργεί;',
              style: TextStyle(
                  color: _g(0.8),
                  fontSize: 16,
                  fontWeight: FontWeight.w700)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(children: [
        const SizedBox(height: 28),

        // HERO — Dynamic (split when both regular + project active)
        if (_activeRegularReqs.isEmpty && _activeProjectReqs.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _EmptyHeroCard(onTap: _openRequest),
          )
        else ...[
          if (_activeRegularReqs.isNotEmpty)
            const SizedBox(height: 10),
            _HowItWorksStep(
                num: '3',
                emoji: '🏆',
                title: 'Επέλεξε την καλύτερη',
                subtitle: 'Το AI σου προτείνει τις 3 κορυφαίες',
                active: false),
          ]),
        ),

        const SizedBox(height: 28),

        // ΚΑΤΗΓΟΡΙΕΣ
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Text('Δημοφιλείς υπηρεσίες',
              style: TextStyle(
                  color: _g(0.8),
                  fontSize: 16,
                  fontWeight: FontWeight.w700)),
        ),
        SizedBox(
          height: 90,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            children: [
              {'emoji': '⚡', 'label': 'Ηλεκτρολόγος', 'profession': 'Ηλεκτρολόγος'},
              {'emoji': '🔧', 'label': 'Υδραυλικός', 'profession': 'Υδραυλικός'},
              {'emoji': '❄️', 'label': 'Κλιματισμός', 'profession': 'Συντήρηση Κλιματιστικών'},
            child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  ShaderMask(
                    shaderCallback: (b) => const LinearGradient(
                        colors: [kGoldLight, kGold]).createShader(b),
                    child: const Text('GOREALAI',
                        style: TextStyle(
                            fontFamily: 'Raleway',
                            fontSize: 14,
                            letterSpacing: 5,
                            fontWeight: FontWeight.w700,
                            color: Colors.white)),
                  ),
                  Row(children: [
                    StreamBuilder<QuerySnapshot>(
                      stream: FirebaseFirestore.instance
                          .collection('presence')
                          .where('online', isEqualTo: true)
                          .snapshots(),
                      builder: (_, snap) {
                        int count = 0;
                        if (snap.hasData) {
                          final cutoff = Timestamp.fromDate(
                              DateTime.now().subtract(const Duration(minutes: 10)));
                          count = snap.data!.docs.where((d) {
                            final data = d.data() as Map<String, dynamic>;
                            final ls = data['lastSeen'];
                            if (ls == null) return true;
                            return (ls as Timestamp).compareTo(cutoff) >= 0;
                    ))
                .toList(),
          ),
        ),

        const SizedBox(height: 28),

        const SizedBox(height: 28),

        // NEARBY PROS SECTION
        _NearbyProsSection(),

        const SizedBox(height: 28),

        // LIVE ACTIVITY FEED
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Row(children: [
            Container(width: 7, height: 7,
                decoration: const BoxDecoration(shape: BoxShape.circle, color: kGreen)),
                ]),
          ),

          // CONTENT
          Expanded(
            child: _buildHome(),
          ),

          // BOTTOM NAV
          _BottomNav(
            navIndex: _navIndex,
            userName: _userName,
            hasActiveRequest: _activeRequests.isNotEmpty,
            activeRequestId: _activeRequests.isNotEmpty ? _activeRequests.first['id'] as String? : null,
            onHome: () => setState(() => _navIndex = 0),
            onFab: _openPortfolioGallery,
            onHistory: () {
              setState(() => _navIndex = 2);
              Navigator.push(
                  context,
                  PageRouteBuilder(
                    transitionDuration: const Duration(milliseconds: 350),
                    pageBuilder: (_, __, ___) =>
                        RequestHistoryScreen(userId: _userId ?? ''),
                    transitionsBuilder: (_, a, __, c) =>
                        FadeTransition(opacity: a, child: c),
                  )).then((_) => setState(() => _navIndex = 0));
            },
            onMessages: () {
              setState(() => _navIndex = 4);
              Navigator.push(
                  context,
                  PageRouteBuilder(
                    transitionDuration: const Duration(milliseconds: 350),
                    pageBuilder: (_, __, ___) =>
                        MessagesScreen(userId: _userId ?? ''),
                    transitionsBuilder: (_, a, __, c) =>
                        FadeTransition(opacity: a, child: c),
                  )).then((_) => setState(() => _navIndex = 0));
            },
            onProfile: () {
              setState(() => _navIndex = 3);
              Navigator.push(
                  context,
                  PageRouteBuilder(
                    transitionDuration: const Duration(milliseconds: 350),
                    pageBuilder: (_, __, ___) => const ProfileScreen(),
                    transitionsBuilder: (_, a, __, c) =>
                        FadeTransition(opacity: a, child: c),
                  )).then((_) => setState(() => _navIndex = 0));
            },
          ),
        ]),
      ),
    );
  }

  Widget _buildHome() {
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const _StatsMarquee(),
        const SizedBox(height: 20),

        // Greeting
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            RichText(
                text: TextSpan(children: [
              const TextSpan(
                  text: 'Γεια σου, ',
                  style: TextStyle(
                      fontFamily: 'Raleway',
                      fontSize: 26,
                      color: Colors.white)),
              TextSpan(
                  text: _vocative(_userName),
                  style: const TextStyle(
                      fontFamily: 'Raleway',
                      fontSize: 26,
                      fontStyle: FontStyle.italic,
                      color: kGold)),
              const TextSpan(
                  text: ' 👋', style: TextStyle(fontSize: 24)),
            ])),
            const SizedBox(height: 6),
            Text('Χρειάζεσαι κάποιον επαγγελματία;',
                style: TextStyle(
                    color: _g(0.45),
                    fontSize: 14)),
          ]),
        ),

        const SizedBox(height: 28),

        // HERO — Dynamic (split when both regular + project active)
        if (_activeRegularReqs.isEmpty && _activeProjectReqs.isEmpty && _activeEventReqs.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _EmptyHeroCard(onTap: _openRequest),
          )
        else ...[
          if (_activeRegularReqs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _ActiveRequestHeroCard(
                requests: _activeRegularReqs,
                onTap: () => _navigateToRequest(_activeRegularReqs.first),
                onNewRequest: _openRequest,
              ),
            ),
          if (_activeRegularReqs.isNotEmpty && _activeProjectReqs.isNotEmpty)
            const SizedBox(height: 12),
          if (_activeProjectReqs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _ActiveRequestHeroCard(
                requests: _activeProjectReqs,
                onTap: () => _navigateToRequest(_activeProjectReqs.first),
                onNewRequest: _openPortfolioGallery,
                isProject: true,
              ),
            ),
          if (_activeEventReqs.isNotEmpty && (_activeRegularReqs.isNotEmpty || _activeProjectReqs.isNotEmpty))
            const SizedBox(height: 12),
          if (_activeEventReqs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _ActiveRequestHeroCard(
                requests: _activeEventReqs,
                onTap: () => _navigateToEventRequest(_activeEventReqs.first),
                onNewRequest: _openPortfolioGallery,
                isEvent: true,
                totalSeconds: 60 * 60,
              ),
              ])),
        ]),
        const SizedBox(height: 18),
        const Text('Γνωρίζεις την ανάγκη σου;',
            style: TextStyle(fontFamily: 'Raleway', fontSize: 28,
                fontWeight: FontWeight.w800, color: Colors.white, height: 1.2)),
        const SizedBox(height: 6),
        Text('Περίγραψέ την και οι επαγγελματίες θα ανταγωνιστούν για σένα.',
            style: TextStyle(fontSize: 14, color: _g(0.75), height: 1.4, fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        Text('Στείλε αίτημα → το AI ειδοποιεί επαγγελματίες ή συνεργεία → παίρνεις τις 3 καλύτερες προσφορές σε 15 λεπτά.',
            style: TextStyle(fontSize: 12, color: _g(0.5), height: 1.5)),
        const SizedBox(height: 20),
        Container(
          width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(children: [
            _HowItWorksStep(
                num: '1',
                emoji: '📝',
                title: 'Περίγραψε το αίτημα',
                subtitle: 'Γράψε ή μίλα για αυτό που χρειάζεσαι',
                active: true),
            const SizedBox(height: 10),
            _HowItWorksStep(
                num: '2',
                emoji: '⏱️',
// ── Active Request Hero Card — countdown πρωταγωνιστής ──
class _ActiveRequestHeroCard extends StatefulWidget {
  final List<Map<String, dynamic>> requests;
  final VoidCallback onTap;
  final VoidCallback onNewRequest;
  final bool isProject;
  const _ActiveRequestHeroCard({
    required this.requests, required this.onTap, required this.onNewRequest,
    this.isProject = false});
  @override
  State<_ActiveRequestHeroCard> createState() => _ActiveRequestHeroCardState();
}

class _ActiveRequestHeroCardState extends State<_ActiveRequestHeroCard> {
  Timer? _timer;
  // Track seconds left per request
  final Map<String, int> _secondsLeft = {};
  int _offersCount = 0;
  int _prosNotified = 0;

  @override
  void initState() {
    super.initState();
    _initTimers();
    _listenOffers();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        for (final key in _secondsLeft.keys.toList()) {
          if (_secondsLeft[key]! > 0) _secondsLeft[key] = _secondsLeft[key]! - 1;
        }
      });
    });
  }

  void _initTimers() {
    for (final req in widget.requests) {
      final exp = req['expiresAt'];
      if (exp != null) {
        try {
          final expDate = (exp as dynamic).toDate() as DateTime;
          final diff = expDate.difference(DateTime.now()).inSeconds;
          _secondsLeft[req['id']] = diff > 0 ? diff : 0;
        } catch (_) {
          _secondsLeft[req['id']] = 15 * 60;
        }
      } else {
        _secondsLeft[req['id']] = 0;
      }
    }
  }

  void _listenOffers() {
    if (widget.requests.isEmpty) return;
    final collection = widget.isProject ? 'project_requests' : 'requests';
    FirebaseFirestore.instance
        .collection(collection)
        .doc(widget.requests.first['id'])
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final data = snap.data();
      if (data != null) {
        setState(() {
          _offersCount = data['offersCount'] ?? 0;
          _prosNotified = data['prosNotified'] ?? _offersCount + 3;
        });
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _fmt(int secs) {
    final m = (secs ~/ 60).toString().padLeft(2, '0');
    final s = (secs % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final req = widget.requests.first;
    final secs = _secondsLeft[req['id']] ?? 0;
    final totalSecs = 15 * 60;
    final progress = secs / totalSecs;
    final isCompleted = req['status'] == 'completed';

    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: isCompleted
                  ? [kGold.withValues(alpha: 0.18), kGold.withValues(alpha: 0.05)]
                  : [kGreen.withValues(alpha: 0.12), Colors.black.withValues(alpha: 0.4)]),
          border: Border.all(
              color: isCompleted ? kGold.withValues(alpha: 0.5) : kGreen.withValues(alpha: 0.4),
              width: 1.5),
          boxShadow: [BoxShadow(
              color: (isCompleted ? kGold : kGreen).withValues(alpha: 0.15), blurRadius: 30)],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

          // Header
          Row(children: [
            Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(8),
                    color: (isCompleted ? kGold : kGreen).withValues(alpha: 0.15)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 5, height: 5, decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isCompleted ? kGold : kGreen)),
                  const SizedBox(width: 5),
                  Text(isCompleted
                      ? (widget.isProject ? '🏆 G-PROJECT ΟΛΟΚΛΗΡΩΘΗΚΕ' : '🏆 ΟΛΟΚΛΗΡΩΘΗΚΕ')
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(8),
                    color: (isCompleted ? kGold : kGreen).withValues(alpha: 0.15)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 5, height: 5, decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isCompleted ? kGold : kGreen)),
          Text('"${req['desc'] ?? ''}"',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(color: _gw, fontSize: 13,
                  fontStyle: FontStyle.italic, height: 1.4)),

          const SizedBox(height: 16),

          if (!isCompleted) ...[
            if (secs == 0) ...[
              // ── CONGRATULATIONS ──
              Row(children: [
                const Text('🎉', style: TextStyle(fontSize: 36)),
                const SizedBox(width: 16),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Συγχαρητήρια!',
                      style: TextStyle(fontFamily: 'Raleway', fontSize: 16,
                          fontWeight: FontWeight.w800, color: kGold)),
                  const SizedBox(height: 4),
                  Text('Βρήκα τους 3 καλύτερους επαγγελματίες για σένα!',
                      style: TextStyle(color: _g(0.7), fontSize: 12, height: 1.4)),
                  const SizedBox(height: 4),
                  Text('$_offersCount προσφορές · Πάτα για να δεις',
                      style: TextStyle(color: kGold.withValues(alpha: 0.7), fontSize: 11)),
                ])),
              ]),
            ] else ...[
            // ── COUNTDOWN HERO ──
            Row(children: [
              // Ring progress mini
              SizedBox(width: 70, height: 70,
                child: Stack(alignment: Alignment.center, children: [
                  SizedBox(width: 70, height: 70,
                      child: CustomPaint(painter: _RingPainter(progress: progress))),
                  Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(_fmt(secs), style: const TextStyle(
                        fontFamily: 'Raleway', fontSize: 14,
                        fontWeight: FontWeight.w800, color: kGold, letterSpacing: 1)),
                    Text('λεπτά', style: TextStyle(
                        fontSize: 7, color: _g(0.4))),
                  ]),
                        fontFamily: 'Raleway', fontSize: 14,
                        fontWeight: FontWeight.w800, color: kGold, letterSpacing: 1)),
                    Text('λεπτά', style: TextStyle(
                        fontSize: 7, color: _g(0.4))),
                  ]),
                ]),
              ),
              const SizedBox(width: 16),
              Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Stat rows
                _StatRow(icon: '🟢', label: '${_prosNotified > 0 ? _prosNotified : "??"} επαγγελματίες ειδοποιήθηκαν'),
                const SizedBox(height: 6),
                _StatRow(icon: '🔥', label: '$_offersCount προσφορές μέχρι τώρα',
                    highlight: _offersCount > 0),
                const SizedBox(height: 6),
                _StatRow(icon: '🤖', label: 'AI αναλύει & κατατάσσει'),
              ])),
            ]),
            ], // end else secs>0
          ] else ...[
            // Completed state
            Row(children: [
              const Text('🏆', style: TextStyle(fontSize: 36)),
              const SizedBox(width: 16),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Οι προσφορές σου είναι έτοιμες!',
                    style: TextStyle(color: _gw, fontSize: 15,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('$_offersCount προσφορές · Πάτα για να δεις τις 3 καλύτερες',
                    style: TextStyle(color: kGold.withValues(alpha: 0.8), fontSize: 12)),
              ])),
            ]),
          ],

          const SizedBox(height: 16),

          // CTA Button
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 13),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: isCompleted
                  ? const LinearGradient(colors: [kGoldLight, kGold])
                  : LinearGradient(colors: [kGreen, const Color(0xFF2AA060)]),
              boxShadow: [BoxShadow(
                  color: (isCompleted ? kGold : kGreen).withValues(alpha: 0.35),
                  blurRadius: 16)],
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(isCompleted ? '🏆' : '⏱', style: const TextStyle(fontSize: 16)),
              const SizedBox(width: 8),
              Text(isCompleted ? 'Δες τις 3 καλύτερες προσφορές' : 'Παρακολούθησε ζωντανά',
                  style: TextStyle(color: _gw, fontSize: 13,
                      fontWeight: FontWeight.w800)),
            ]),
          ),

          if (widget.requests.length < 2) ...[
            const SizedBox(height: 10),
            GestureDetector(
              onTap: widget.onNewRequest,
              child: Center(child: Text('+ Νέο αίτημα',
                  style: TextStyle(color: _g(0.4),
                      fontSize: 11, decoration: TextDecoration.underline))),
            ),
          ],
        ]),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  final String icon, label;
  final bool highlight;
  const _StatRow({required this.icon, required this.label, this.highlight = false});
  @override
  Widget build(BuildContext context) => Row(children: [
    Text(icon, style: const TextStyle(fontSize: 13)),
    const SizedBox(width: 6),
    Text(label, style: TextStyle(
        fontSize: 12, height: 1.3,
        color: highlight ? kGreen : _g(0.65),
        fontWeight: highlight ? FontWeight.w600 : FontWeight.w400)),
  ]);
}

// ── How It Works Step ──
// ── Live ticking countdown for pro request cards ──
class _LiveCountdown extends StatefulWidget {
  final Timestamp expiresAt;
  const _LiveCountdown({required this.expiresAt});
  @override
  State<_LiveCountdown> createState() => _LiveCountdownState();
}
class _LiveCountdownState extends State<_LiveCountdown> {
  late Timer _t;
                Text('Οι προσφορές σου είναι έτοιμες!',
                    style: TextStyle(color: _gw, fontSize: 15,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('$_offersCount προσφορές · Πάτα για να δεις τις 3 καλύτερες',
                    style: TextStyle(color: kGold.withValues(alpha: 0.8), fontSize: 12)),
              ])),
            ]),
          ],

          const SizedBox(height: 16),

          // CTA Button
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 13),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: isCompleted
                  ? const LinearGradient(colors: [kGoldLight, kGold])
                  : LinearGradient(colors: [kGreen, const Color(0xFF2AA060)]),
              boxShadow: [BoxShadow(
                  color: (isCompleted ? kGold : kGreen).withValues(alpha: 0.35),
                  blurRadius: 16)],
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(isCompleted ? '🏆' : '⏱', style: const TextStyle(fontSize: 16)),
              const SizedBox(width: 8),
              Text(isCompleted ? 'Δες τις 3 καλύτερες προσφορές' : 'Παρακολούθησε ζωντανά',
                  style: TextStyle(color: _gw, fontSize: 13,
                      fontWeight: FontWeight.w800)),
            ]),
          ),

          if (widget.requests.length < 2) ...[
            const SizedBox(height: 10),
            GestureDetector(
              onTap: widget.onNewRequest,
              child: Center(child: Text('+ Νέο αίτημα',
                  style: TextStyle(color: _g(0.4),
                      fontSize: 11, decoration: TextDecoration.underline))),
            ),
          ],
        ]),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  final String icon, label;
  final bool highlight;
  const _StatRow({required this.icon, required this.label, this.highlight = false});
  @override
  Widget build(BuildContext context) => Row(children: [
    Text(icon, style: const TextStyle(fontSize: 13)),
    const SizedBox(width: 6),
    Text(label, style: TextStyle(
        fontSize: 12, height: 1.3,
        color: highlight ? kGreen : _g(0.65),
        fontWeight: highlight ? FontWeight.w600 : FontWeight.w400)),
  ]);
}

// ── How It Works Step ──
// ── Live ticking countdown for pro request cards ──
class _LiveCountdown extends StatefulWidget {
  final Timestamp expiresAt;
  const _LiveCountdown({required this.expiresAt});
  @override
  State<_LiveCountdown> createState() => _LiveCountdownState();
}
class _LiveCountdownState extends State<_LiveCountdown> {
  late Timer _t;
  int _secs = 0;
  @override
  void initState() {
    super.initState();
    _update();
    _t = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(_update); });
  }
  void _update() {
    final diff = widget.expiresAt.toDate().difference(DateTime.now()).inSeconds;
    _secs = diff < 0 ? -1 : diff;
  }
    final m = (secs ~/ 60).toString().padLeft(2, '0');
    final s = (secs % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final req = widget.requests.first;
    final secs = _secondsLeft[req['id']] ?? 0;
    final totalSecs = widget.totalSeconds;
    final progress = totalSecs > 0 ? secs / totalSecs : 0.0;
    final isCompleted = req['status'] == 'completed';

    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: isCompleted
                  ? [kGold.withValues(alpha: 0.18), kGold.withValues(alpha: 0.05)]
                  : [kGreen.withValues(alpha: 0.12), Colors.black.withValues(alpha: 0.4)]),
          border: Border.all(
              color: isCompleted ? kGold.withValues(alpha: 0.5) : kGreen.withValues(alpha: 0.4),
              width: 1.5),
          boxShadow: [BoxShadow(
              color: (isCompleted ? kGold : kGreen).withValues(alpha: 0.15), blurRadius: 30)],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

          // Header
          Row(children: [
            Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(8),
                    color: (isCompleted ? kGold : kGreen).withValues(alpha: 0.15)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 5, height: 5, decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isCompleted ? kGold : kGreen)),
                  const SizedBox(width: 5),
                  Text(isCompleted
                      ? (widget.isEvent ? '🏆 EVENT ΟΛΟΚΛΗΡΩΘΗΚΕ' : (widget.isProject ? '🏆 G-PROJECT ΟΛΟΚΛΗΡΩΘΗΚΕ' : '🏆 ΟΛΟΚΛΗΡΩΘΗΚΕ'))
                      : (widget.isEvent ? '🎉 EVENT ΖΩΝΤΑΝΟ' : (widget.isProject ? '🟣 G-PROJECT ΖΩΝΤΑΝΟ' : '🔴 ΖΩΝΤΑΝΟ ΑΙΤΗΜΑ')),
                      style: TextStyle(
                          color: isCompleted ? kGold : (widget.isEvent ? kGold : (widget.isProject ? const Color(0xFFBB86FC) : kGreen)),
                          fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1)),
                ])),
            const Spacer(),
          ]),

          const SizedBox(height: 14),

          // Description
          Text('"${req['desc'] ?? ''}"',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(color: _gw, fontSize: 13,
                  fontStyle: FontStyle.italic, height: 1.4)),

          const SizedBox(height: 16),

          if (!isCompleted) ...[
            if (secs == 0) ...[
              // ── OFFERS READY ──
              Row(children: [
                const Text('🏆', style: TextStyle(fontSize: 36)),
                const SizedBox(width: 16),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Βρήκαμε $_offersCount προσφορές για σένα!',
                      style: const TextStyle(fontFamily: 'Raleway', fontSize: 14,
                          fontWeight: FontWeight.w800, color: kGold)),
                  const SizedBox(height: 4),
                  Text('Πάτα για να δεις τους καλύτερους επαγγελματίες',
                      style: TextStyle(color: _g(0.7), fontSize: 12, height: 1.4)),
                ])),
              ]),
            ] else ...[
            // ── COUNTDOWN HERO ──
            Row(children: [
              // Ring progress mini
              SizedBox(width: 70, height: 70,
                child: Stack(alignment: Alignment.center, children: [
                  SizedBox(width: 70, height: 70,
                      child: CustomPaint(painter: _RingPainter(progress: progress))),
                  Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(_fmt(secs), style: TextStyle(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: kGreen.withValues(alpha: 0.12),
                      border: Border.all(color: kGreen.withValues(alpha: 0.3)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(width: 5, height: 5,
                          decoration: const BoxDecoration(
                              shape: BoxShape.circle, color: kGreen)),
                      const SizedBox(width: 5),
                      const Text('Επαγγελματίας',
                          style: TextStyle(color: kGreen, fontSize: 9,
                              fontWeight: FontWeight.w700)),
                    ]),
                  ),
                ]),
                Row(children: [
                  _NotificationBell(userId: _proId ?? ''),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => Navigator.push(context, PageRouteBuilder(
                      transitionDuration: const Duration(milliseconds: 350),
                      pageBuilder: (_, __, ___) => const ProfileScreen(),
                      transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
                    )),
                    child: Container(
                      width: 36, height: 36,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: kGold.withValues(alpha: 0.12),
                          border: Border.all(color: kGold, width: 1.5),
                          boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.3), blurRadius: 8)]),
                      child: Center(child: Text(
                          _proName?.isNotEmpty == true ? _proName![0].toUpperCase() : 'P',
                          style: const TextStyle(color: kGold, fontSize: 16,
                              fontWeight: FontWeight.bold))),
                    ),
                  ),
                ]),
              ]),

              const SizedBox(height: 16),

              // Greeting
              RichText(text: TextSpan(children: [
                const TextSpan(text: 'Γεια σου, ',
                    style: TextStyle(fontFamily: 'Raleway', fontSize: 24, color: Colors.white)),

// ── Bottom Nav ──
class _BottomNav extends StatelessWidget {
  final int navIndex;
  final String? userName;
  final String? activeRequestId;   // για badge στο G
  final bool hasActiveRequest;
  final VoidCallback onHome, onFab, onHistory, onProfile;
  const _BottomNav(
      {required this.navIndex,
      required this.userName,
      this.activeRequestId,
      this.hasActiveRequest = false,
      required this.onHome,
      required this.onFab,
      required this.onHistory,
      required this.onProfile});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            gradient: const LinearGradient(
              begin: Alignment.topCenter, end: Alignment.bottomCenter,
              colors: [Color(0xFF252525), Color(0xFF161616)],
            ),
            border: Border(
              top: BorderSide(color: Colors.white.withValues(alpha: 0.10), width: 1),
            ),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.65), blurRadius: 30, offset: const Offset(0, 10)),
              BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 10, offset: const Offset(0, 4)),
            ],
          ),
          child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _HNavItem(icon: Icons.home_rounded, label: 'Αρχική',
                    active: navIndex == 0, onTap: onHome),

                // ── G FAB — smart button ──
                GestureDetector(
                  onTap: onFab,
                  child: Stack(clipBehavior: Clip.none, children: [
                    // Pulsing ring αν υπάρχει ενεργό αίτημα
                    if (hasActiveRequest)
                      Positioned.fill(child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0.9, end: 1.15),
                        duration: const Duration(milliseconds: 900),
                        curve: Curves.easeInOut,
                        builder: (_, v, __) => Transform.scale(
                          scale: v,
                          child: Container(decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: kGold.withValues(alpha: 0.4 * (1.15 - v) * 6),
                                width: 2),
                          )),
                        ),
                        onEnd: () {},
                      )),
                    Container(
                      width: 64, height: 64,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const RadialGradient(colors: [kGoldLight, kGold, kGoldDark]),
                        border: Border.all(
                            color: kGold.withValues(alpha: 0.9),
                            width: 2),
                        boxShadow: [BoxShadow(
                            color: kGold.withValues(alpha: 0.5),
                            blurRadius: 16, spreadRadius: 1)],
                      ),
                      child: Center(child: const Text('G', style: TextStyle(
                              fontFamily: 'Raleway', fontSize: 30,
                              fontWeight: FontWeight.bold,
                              color: Colors.black, height: 1))),
                    ),
                  ]),
                ),

                _HNavItem(icon: Icons.history_rounded, label: 'Ιστορικό',
                    active: navIndex == 2, onTap: onHistory),
                // Avatar
                GestureDetector(
                  onTap: onProfile,
                  child: Container(
                    width: 38, height: 38,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: navIndex == 3
                          ? kGold.withValues(alpha: 0.2)
                          : kGold.withValues(alpha: 0.08),
                      border: Border.all(color: kGold,
                          width: navIndex == 3 ? 1.5 : 0.5),
                    ),
                    child: Center(child: Text(
                        userName?.isNotEmpty == true
                            ? userName![0].toUpperCase() : 'G',
                        style: const TextStyle(color: kGold,
                            fontSize: 16, fontWeight: FontWeight.bold))),
                  ),
                ),
              ]),
        ),
      );
}

// ── Pro Stat Chip ──
class _ProStatChip extends StatelessWidget {
  final String icon, label, sub;
  final bool highlight;
  const _ProStatChip({
    required this.icon, required this.label, required this.sub,
    this.highlight = false});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(12),
      color: highlight
          ? kGold.withValues(alpha: 0.12)
          : _g(0.06),
      border: Border.all(
          color: highlight ? kGold.withValues(alpha: 0.4) : _g(0.08)),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Text(icon, style: const TextStyle(fontSize: 14)),
      const SizedBox(width: 6),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(
            color: highlight ? kGold : Colors.white,
            fontSize: 14, fontWeight: FontWeight.w800,
            fontFamily: 'Raleway')),
        Text(sub, style: TextStyle(
            color: _g(0.4), fontSize: 9)),
      ]),
    ]),
  );
}

// ═══════════════════════════════════════
// PROFESSIONAL HOME SCREEN
// ═══════════════════════════════════════
class ProfessionalHomeScreen extends StatefulWidget {
  const ProfessionalHomeScreen({super.key});
  @override
  State<ProfessionalHomeScreen> createState() =>
      _ProfessionalHomeScreenState();
}

class _ProfessionalHomeScreenState extends State<ProfessionalHomeScreen> {
  String? _proName;
  String? _proId;
  String? _proSpecialty;
  String? _proPhotoUrl;
  Uint8List? _proPhotoBytes;
  String _activeTab = 'requests';
  }

  @override
  String? _proId;
  String? _proSpecialty;
  String? _proPhotoUrl;
  Uint8List? _proPhotoBytes;
  String _activeTab = 'requests';
  final Set<String> _submittedIds = {};

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }
  }

  Future<void> _loadProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    // Load specialty from professionals collection
    final proSnap = await FirebaseFirestore.instance
        .collection('professionals')
        .where('userId', isEqualTo: user.uid)
        .limit(1)
        .get();
    if (!mounted) return;
    final photoUrl = doc.data()?['profilePhotoUrl'] as String?;
    setState(() {
      _proName = doc.data()?['name'] ?? '';
      _proId = user.uid;
      _proPhotoUrl = photoUrl;
      _proSpecialty = proSnap.docs.isNotEmpty
          ? (proSnap.docs.first.data()['specialty'] as String? ?? '')
          : '';
    });
    // Prefetch profile photo bytes (bypass CORS)
    if (photoUrl != null && photoUrl.isNotEmpty) {
      _fetchPhotoBytes(photoUrl).then((bytes) {
        if (bytes != null && mounted) setState(() => _proPhotoBytes = bytes);
      });
    }
  }

  Future<Uint8List?> _fetchPhotoBytes(String url) async {
    try {
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) return res.bodyBytes;
    } catch (_) {}
    }
  }

  Future<Uint8List?> _fetchPhotoBytes(String url) async {
    try {
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
          : '';
      _bio = bio;
      _bioCtrl.text = bio;
    });
    // Prefetch profile photo bytes (bypass CORS)
    if (photoUrl != null && photoUrl.isNotEmpty) {
      _fetchPhotoBytes(photoUrl).then((bytes) {
        if (bytes != null && mounted) setState(() => _proPhotoBytes = bytes);
      });
    }
  }
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const RadialGradient(colors: [kGoldLight, kGold, kGoldDark]),
                        border: Border.all(
                            color: kGold.withValues(alpha: 0.9),
                            width: 2),
                        boxShadow: [BoxShadow(
                            color: kGold.withValues(alpha: 0.5),
                            blurRadius: 16, spreadRadius: 1)],
                      ),
                      child: Center(child: const Text('G', style: TextStyle(
                              fontFamily: 'Raleway', fontSize: 30,
                              fontWeight: FontWeight.bold,
                              color: Colors.black, height: 1))),
                    ),
                  ]),
                ),

                _HNavItem(icon: Icons.history_rounded, label: 'Ιστορικό',
                    active: navIndex == 2, onTap: onHistory),
                // Avatar
                GestureDetector(
                  onTap: onProfile,
                  child: Container(
                    width: 38, height: 38,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: navIndex == 3
                          ? kGold.withValues(alpha: 0.2)
                          : kGold.withValues(alpha: 0.08),
                      border: Border.all(color: kGold,
                          width: navIndex == 3 ? 1.5 : 0.5),
                    ),
                    child: Center(child: Text(
                        userName?.isNotEmpty == true
                            ? userName![0].toUpperCase() : 'G',
                        style: const TextStyle(color: kGold,
                            fontSize: 16, fontWeight: FontWeight.bold))),
                  ),
                ),
              ]),
        ),
      );
}

// ── Pro Stat Chip ──
class _ProStatChip extends StatelessWidget {
  final String icon, label, sub;
  final bool highlight;
  const _ProStatChip({
    );
  }
}

class _BottomNav extends StatelessWidget {
  final int navIndex;
  final String? userName;
  final String? activeRequestId;   // για badge στο G
  Future<void> _saveBio() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    setState(() => _savingBio = true);
    final text = _bioCtrl.text.trim();
    try {
      await FirebaseFirestore.instance
          .collection('users').doc(user.uid)
          .update({'bio': text});
      // Also update professionals collection
      final proSnap = await FirebaseFirestore.instance
          .collection('professionals')
          .where('userId', isEqualTo: user.uid)
          .limit(1).get();
      for (final d in proSnap.docs) {
        await d.reference.update({'bio': text});
      }
      if (mounted) {
        setState(() { _bio = text; _savingBio = false; });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('✅ Το προφίλ αποθηκεύτηκε!'),
          backgroundColor: Color(0xFF00D4AA),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (_) {
      if (mounted) setState(() => _savingBio = false);
    }
  }

  static String? _storagePathFromUrl(String url) {
    try {
      final oIdx = url.indexOf('/o/');
      if (oIdx < 0) return null;
      final raw = url.substring(oIdx + 3).split('?').first;
      return Uri.decodeComponent(raw);
    } catch (_) {
      return null;
    }
  }

                // ── G FAB — smart button ──
                GestureDetector(
                  onTap: onFab,
                  child: Stack(clipBehavior: Clip.none, children: [
                    // Pulsing ring αν υπάρχει ενεργό αίτημα
                    if (hasActiveRequest)
                      Positioned.fill(child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0.9, end: 1.15),
                        duration: const Duration(milliseconds: 900),
                        curve: Curves.easeInOut,
                        builder: (_, v, __) => Transform.scale(
                          scale: v,
                          child: Container(decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: kGold.withValues(alpha: 0.4 * (1.15 - v) * 6),
                                width: 2),
                          )),
                        ),
                        onEnd: () {},
                      )),
                    Container(
                      width: 64, height: 64,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const RadialGradient(colors: [kGoldLight, kGold, kGoldDark]),
                        border: Border.all(
                            color: kGold.withValues(alpha: 0.9),
                            width: 2),
                        boxShadow: [BoxShadow(
                            color: kGold.withValues(alpha: 0.5),
                            blurRadius: 16, spreadRadius: 1)],
                      ),
                      child: Center(child: const Text('G', style: TextStyle(
                              fontFamily: 'Raleway', fontSize: 30,
                              fontWeight: FontWeight.bold,
                              color: Colors.black, height: 1))),
                    ),
                  ]),
                ),

                _HNavItem(icon: Icons.history_rounded, label: 'Ιστορικό',
                    active: navIndex == 2, onTap: onHistory),
                // Avatar
                GestureDetector(
                  onTap: onProfile,
                  child: Container(
                    width: 38, height: 38,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: navIndex == 3
                    child: Container(
                      width: 36, height: 36,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: kGold.withValues(alpha: 0.12),
                          border: Border.all(color: kGold, width: 1.5),
                          boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.3), blurRadius: 8)]),
                      child: ClipOval(child: _proPhotoBytes != null
                          ? Image.memory(_proPhotoBytes!, fit: BoxFit.cover)
                          : Center(child: Text(
                              _proName?.isNotEmpty == true ? _proName![0].toUpperCase() : 'P',
                              style: const TextStyle(color: kGold, fontSize: 16,
                                  fontWeight: FontWeight.bold)))),
                    ),
                  ),
                ]),
              ]),

              const SizedBox(height: 16),

              // Greeting
              RichText(text: TextSpan(children: [
                const TextSpan(text: 'Γεια σου, ',
                    style: TextStyle(fontFamily: 'Raleway', fontSize: 24, color: Colors.white)),
                TextSpan(text: _proName ?? '',
                    style: const TextStyle(fontFamily: 'Raleway', fontSize: 24,
                        fontStyle: FontStyle.italic, color: kGold)),
                const TextSpan(text: ' 👋', style: TextStyle(fontSize: 22)),
              ])),


              // Greeting
              RichText(text: TextSpan(children: [
                const TextSpan(text: 'Γεια σου, ',
                    style: TextStyle(fontFamily: 'Raleway', fontSize: 24, color: Colors.white)),
                TextSpan(text: _proName ?? '',
                    style: const TextStyle(fontFamily: 'Raleway', fontSize: 24,
                        fontStyle: FontStyle.italic, color: kGold)),
                const TextSpan(text: ' 👋', style: TextStyle(fontSize: 22)),
              ])),

              const SizedBox(height: 10),

              // Stats row
              StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('requests')
                    .where('status', isEqualTo: 'active')
                    .snapshots(),
                builder: (context, snap) {
                  final activeCount = snap.hasData ? snap.data!.docs.length : 0;
                  return Row(children: [
                    _ProStatChip(icon: '🔔', label: '$activeCount', sub: 'Ενεργά'),
                    const SizedBox(width: 8),
                    StreamBuilder<QuerySnapshot>(
                      stream: FirebaseFirestore.instance
                          .collection('bookings')
                          .where('professionalName', isEqualTo: _proName)
                          .where('status', isEqualTo: 'accepted')
                          .snapshots(),
                      builder: (ctx2, snap2) {
                        final doneCount = snap2.hasData ? snap2.data!.docs.length : 0;
                        return _ProStatChip(icon: '✅', label: '$doneCount', sub: 'Αποδεκτά');
                      },
                    ),
                    const SizedBox(width: 8),
                    StreamBuilder<QuerySnapshot>(
                      stream: FirebaseFirestore.instance
                          .collection('bookings')
                          .where('professionalName', isEqualTo: _proName)
                          .where('status', isEqualTo: 'pending')
                          .snapshots(),
                      builder: (ctx3, snap3) {
                        final pendCount = snap3.hasData ? snap3.data!.docs.length : 0;
                        return _ProStatChip(icon: '⏳', label: '$pendCount', sub: 'Εκκρεμή',
                            highlight: pendCount > 0);
                      },
                    ),
                  ]);
                },
  }

  static String? _storagePathFromUrl(String url) {
    try {
      final oIdx = url.indexOf('/o/');
      if (oIdx < 0) return null;
      final raw = url.substring(oIdx + 3).split('?').first;
      return Uri.decodeComponent(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> _respondBooking(String bookingId, String action) async {
    try {
      final bookingDoc = await FirebaseFirestore.instance
          .collection('bookings')
          .doc(bookingId)
          .get();
      final userId = bookingDoc.data()?['userId'] as String?;

                ]),
              ),
            ),
          ),
          const SizedBox(height: 10),

          // Content list
          Expanded(
            child: _activeTab == 'requests'
                ? _buildRequestsList()
                : _activeTab == 'portfolio'
                    ? ProPortfolioUploadScreen(proId: _proId ?? '', proName: _proName ?? '')
                    : StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('bookings')
                  .where('professionalName', isEqualTo: _proName)
                  .where('status', isEqualTo: _activeTab)
                  .orderBy('createdAt', descending: true)
                  .snapshots(),
              builder: (context, snap) {
                if (!snap.hasData)
                  return const Center(
                      child: CircularProgressIndicator(color: kGold));
                final docs = snap.data!.docs;
                if (docs.isEmpty) {
                  return Center(
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                        Icon(Icons.inbox_outlined,
                            color: _g(0.15),
                            size: 48),
                        const SizedBox(height: 12),
                        Text('Δεν υπάρχουν αιτήματα',
                            style: TextStyle(
                                color: _g(0.3))),
                      ]));
                }
                return ListView.builder(
                  padding:
                      const EdgeInsets.fromLTRB(20, 16, 20, 20),
                  itemCount: docs.length,
                  itemBuilder: (_, i) {
                    final d =
                        docs[i].data() as Map<String, dynamic>;
                    final bookingId = docs[i].id;
                    final isImmediate = d['isImmediate'] == true;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          color: _g(0.05)),
                      child: Column(children: [
                        Container(
                          height: 1,
                          decoration: BoxDecoration(
                            borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(18)),
                            gradient: LinearGradient(colors: [
                              kGold.withValues(alpha: 0.5),
                              Colors.transparent
                            ]),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                            Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                              Text(d['userName'] ?? '',
                                  style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white)),
                              Container(
                                padding:
                                    const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  borderRadius:
                                      BorderRadius.circular(20),
                                  color: isImmediate
                                      ? Colors.green.withValues(alpha: 0.15)
                                      : kGold.withValues(alpha: 0.15),
                                ),
                                child: Text(
                                    isImmediate
                                        ? '⚡ Άμεσα'
                                        : '📅 Προγρ/σμός',
                                    style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        color: isImmediate
                                            ? Colors.green
                                            : kGold)),
                              ),
                            ]),
                            const SizedBox(height: 10),
                            GestureDetector(
                              onTap: () => launchUrl(Uri.parse(
                                  'tel:${d['userPhone']}')),
                              child: Row(children: [
                                const Icon(Icons.phone_outlined,
                                    color: kGold, size: 15),
                                const SizedBox(width: 6),
                                Text(d['userPhone'] ?? '',
                                    style: const TextStyle(
                                        color: kGold,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 14)),
                              ]),
                            ),
                            const SizedBox(height: 5),
                            Row(children: [
                              Icon(Icons.access_time,
                if (docs.isEmpty) {
                  return Center(
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                        Icon(Icons.inbox_outlined,
                            color: _g(0.15),
                            size: 48),
                        const SizedBox(height: 12),
                        Text('Δεν υπάρχουν αιτήματα',
                            style: TextStyle(
                                color: _g(0.3))),
                      ]));
                }
                return ListView.builder(
                  padding:
                      const EdgeInsets.fromLTRB(20, 16, 20, 20),
                  itemCount: docs.length,
                  itemBuilder: (_, i) {
                    final d =
                        docs[i].data() as Map<String, dynamic>;
                    final bookingId = docs[i].id;
                    final isImmediate = d['isImmediate'] == true;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          color: _g(0.05)),
                      child: Column(children: [
                        Container(
                          height: 1,
                          decoration: BoxDecoration(
                            borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(18)),
                            gradient: LinearGradient(colors: [
                              kGold.withValues(alpha: 0.5),
                              Colors.transparent
                            ]),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                            Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                              Text(d['userName'] ?? '',
                                  style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white)),
                              Container(
                                padding:
                                    const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  borderRadius:
                                      BorderRadius.circular(20),
                                  color: isImmediate
                                      ? Colors.green.withValues(alpha: 0.15)
                                      : kGold.withValues(alpha: 0.15),
                                ),
                                child: Text(
                                    isImmediate
                                        ? '⚡ Άμεσα'
                                        : '📅 Προγρ/σμός',
                                    style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        color: isImmediate
                                            ? Colors.green
                                            : kGold)),
                              ),
                            ]),
                            const SizedBox(height: 10),
                            GestureDetector(
                              onTap: () => launchUrl(Uri.parse(
                                  'tel:${d['userPhone']}')),
                              child: Row(children: [
                                const Icon(Icons.phone_outlined,
                                    color: kGold, size: 15),
                                const SizedBox(width: 6),
                                Text(d['userPhone'] ?? '',
                                    style: const TextStyle(
                                        color: kGold,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 14)),
                              ]),
                            ),
                            const SizedBox(height: 5),
                            Row(children: [
                              Icon(Icons.access_time,
                                  color: _g(0.38),
                                  size: 14),
                              const SizedBox(width: 6),
                              Text(d['scheduledTime'] ?? '',
                                  style: TextStyle(
                                      color:
                                          _g(0.5),
                                      fontSize: 12)),
                            ]),
                            if (_activeTab == 'pending') ...[
                              const SizedBox(height: 12),
                              Row(children: [
                                Expanded(
                                    child: GestureDetector(
                                  onTap: () => _respondBooking(
                                      bookingId, 'accept'),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 10),
                                    decoration: BoxDecoration(
                                        borderRadius:
                                            BorderRadius.circular(12),
                                        color: Colors.green
                                            .withValues(alpha: 0.15)),
                                    child: const Center(
                                        child: Text('✅ Αποδοχή',
                                            style: TextStyle(
                                                color: Colors.green,
                                                fontWeight:
                                                    FontWeight.bold,
                                                fontSize: 13))),
                                  ),
                                )),
                                const SizedBox(width: 10),
                                Expanded(
                                    child: GestureDetector(
                                  onTap: () => _respondBooking(
                                      bookingId, 'reject'),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 10),
                                    decoration: BoxDecoration(
                                        borderRadius:
                                            BorderRadius.circular(12),
                                        color: Colors.red
                                            .withValues(alpha: 0.1)),
                                    child: const Center(
                                        child: Text('❌ Απόρριψη',
                                            style: TextStyle(
                                                color: Colors.red,
                                                fontWeight:
                                                    FontWeight.bold,
                                                fontSize: 13))),
                                  ),
                                )),
                              ]),
                            ],
                            if (_activeTab != 'pending') ...[
                              const SizedBox(height: 10),
                              GestureDetector(
                                onTap: () async {
                                  await FirebaseFirestore.instance
                                      .collection('bookings')
                                      .doc(bookingId)
                                      .delete();
                                },
                                child: Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 9),
                                  decoration: BoxDecoration(
                                      borderRadius:
                                          BorderRadius.circular(12),
                                      color:
                                          Colors.red.withValues(alpha: 0.06)),
                                  child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                    Icon(Icons.delete_outline,
                                        color: Colors.red.withValues(alpha: 0.5),
                                        size: 14),
                                    const SizedBox(width: 6),
                                    Text('Διαγραφή',
                                        style: TextStyle(
                                            color:
                                                Colors.red.withValues(alpha: 0.5),
                                            fontSize: 12)),
                                  ]),
                                ),
                              ),
                            ],
                          ]),
                        ),
                      ]),
                    );
                  },
                );
              },
            ),
          ),
        ]),
      ),
    );
  }

  // ── Requests list για επαγγελματίες ──
  Widget _buildRequestsList() {
    if (_proName == null || _proName!.isEmpty) {
                }
                return ListView.builder(
                  padding:
                      const EdgeInsets.fromLTRB(20, 16, 20, 20),
                  itemCount: docs.length,
                  itemBuilder: (_, i) {
                    final d =
                        docs[i].data() as Map<String, dynamic>;
                    final bookingId = docs[i].id;
                    final isImmediate = d['isImmediate'] == true;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          color: _g(0.05)),
                      child: Column(children: [
                        Container(
                          height: 1,
                          decoration: BoxDecoration(
                            borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(18)),
                            gradient: LinearGradient(colors: [
                              kGold.withValues(alpha: 0.5),
                              Colors.transparent
                  },
                );
              },
            ),
          ),
        ]),
      ),
    );
  }

  // ── Mini CV editor ──
  Widget _buildMiniCvEditor() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('👤', style: TextStyle(fontSize: 20)),
          const SizedBox(width: 8),
          const Expanded(child: Text('Δημόσιο Προφίλ (Mini CV)',
              style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700))),
        ]),
        const SizedBox(height: 6),
        Text('Αυτό θα βλέπουν οι χρήστες στο πορτφόλιό σου.',
            style: TextStyle(color: _g(0.4), fontSize: 12, height: 1.5)),
        const SizedBox(height: 16),
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: _g(0.04),
            border: Border.all(color: kGold.withValues(alpha: 0.25)),
          ),
          child: TextField(
            controller: _bioCtrl,
            maxLines: 10,
            maxLength: 600,
            style: TextStyle(color: _g(0.85), fontSize: 13, height: 1.6),
            decoration: InputDecoration(
              hintText: 'Γράψε για εσένα — εμπειρία, ειδικότητες, περιοχές που εξυπηρετείς, τιμές, διαθεσιμότητα...',
              hintStyle: TextStyle(color: _g(0.3), fontSize: 12),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.all(16),
              counterStyle: TextStyle(color: _g(0.25), fontSize: 10),
            ),
          ),
        ),
        const SizedBox(height: 16),
        GestureDetector(
          onTap: _savingBio ? null : _saveBio,
          child: Container(
            width: double.infinity,
                        ]),
                      ],
                    ],

                    const SizedBox(height: 10),
                    Row(children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: kGold.withValues(alpha: 0.08),
                          border: Border.all(color: kGold.withValues(alpha: 0.2)),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Text('📨', style: TextStyle(fontSize: 10)),
                          const SizedBox(width: 4),
                          Text('$offersCountInCard προσφορές',
                              style: const TextStyle(color: kGold, fontSize: 10, fontWeight: FontWeight.w600)),
                        ]),
                      ),
                      if (expiresAt != null) ...[
                        const SizedBox(width: 8),
                        _LiveCountdown(expiresAt: expiresAt),
                      ],
                    ]),

                    const SizedBox(height: 14),

                    // CTA Button or submitted state
                    if (alreadySubmitted) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft, end: Alignment.bottomRight,
                            colors: [kGreen.withValues(alpha: 0.12), Colors.black.withValues(alpha: 0.3)],
                          ),
                          border: Border.all(color: kGreen.withValues(alpha: 0.35)),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Container(width: 6, height: 6,
                                decoration: const BoxDecoration(shape: BoxShape.circle, color: kGreen)),
                            const SizedBox(width: 6),
                            const Text('✅ Η προσφορά στάλθηκε!',
                                style: TextStyle(color: kGreen, fontSize: 11, fontWeight: FontWeight.w700)),
                          ]),
                          const SizedBox(height: 10),
                          Row(children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                color: kGold.withValues(alpha: 0.08),
                                border: Border.all(color: kGold.withValues(alpha: 0.2)),
                              ),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                const Text('📨', style: TextStyle(fontSize: 10)),
                                const SizedBox(width: 4),
                                Text('$offersCountInCard προσφορές',
                                    style: const TextStyle(color: kGold, fontSize: 10,
                                        fontWeight: FontWeight.w600)),
                              ]),
                            ),
                            if (expiresAt != null) ...[
                              const SizedBox(width: 8),
                              _LiveCountdown(expiresAt: expiresAt),
                            ],
                          ]),
                        ]),
                      ),
                    ] else ...[
                    _PremiumButton(
                      label: '💼 Στείλε Προσφορά',
                      gradient: const LinearGradient(colors: [kGoldLight, kGold]),
                      textColor: Colors.black,
                      fontSize: 13,
                      onTap: () => _showOfferDialog(requestId, d),
                    ),
                    ],
                  ]),
                ),
              ]),
            );
          },
        );
      },
    );
  }

  void _showOfferDialog(String requestId, Map<String, dynamic> requestData) {
    final priceCtrl = TextEditingController();
    final msgCtrl = TextEditingController();
    String available = 'Αύριο';
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Dialog(
          backgroundColor: Colors.transparent,
                            ],
                          ]),
                        ),
                      ]),
                    );
                  },
                );
              },
            ),
          ),
        ]),
      ),
    );
  }

  // ── Mini CV editor ──
  Widget _buildMiniCvEditor() {
    // ── PREVIEW mode (bio saved) ──────────────────────────────
    if (!_bioEditMode && _bio.isNotEmpty) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('👤', style: TextStyle(fontSize: 20)),
            const SizedBox(width: 8),
            const Expanded(child: Text('Δημόσιο Προφίλ (Mini CV)',
                style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700))),
            GestureDetector(
              onTap: () => setState(() => _bioEditMode = true),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: kGold.withValues(alpha: 0.4)),
                  color: kGold.withValues(alpha: 0.08),
                ),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.edit_outlined, color: kGold, size: 13),
                  SizedBox(width: 5),
                  Text('Επεξεργασία', style: TextStyle(color: kGold, fontSize: 12, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Text('Αυτό βλέπουν οι χρήστες στο πορτφόλιό σου.',
              style: TextStyle(color: _g(0.35), fontSize: 12, height: 1.5)),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
                ...['Σήμερα', 'Αύριο', 'Μεθαύριο'].map((a) =>
                  GestureDetector(
                    onTap: () => setS(() => available = a),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      margin: const EdgeInsets.only(right: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          color: available == a
                              ? kGold.withValues(alpha: 0.2) : _g(0.05),
                          border: Border.all(
                              color: available == a ? kGold : Colors.transparent)),
                      child: Text(a, style: TextStyle(
                          fontSize: 11,
                          color: available == a ? kGold : _g(0.4))),
                    ),
                  )
                ),
              ]),
              const SizedBox(height: 12),
              // Μήνυμα
              TextField(
                controller: msgCtrl,
                maxLines: 2,
                style: TextStyle(color: _gw, fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'πχ. "Έχω εμπειρία σε βαφές εσωτερικών χώρων..."',
                  hintStyle: TextStyle(color: _g(0.25), fontSize: 12),
                  filled: true, fillColor: _g(0.05),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: kGold.withValues(alpha: 0.3))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: kGold.withValues(alpha: 0.3))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: kGold)),
                  labelText: 'Μήνυμα (προαιρετικό)',
                  labelStyle: TextStyle(color: _g(0.4), fontSize: 12),
                ),
              ),
              const SizedBox(height: 20),
              Row(children: [
                Expanded(child: GestureDetector(
                  onTap: () => Navigator.pop(ctx),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(14),
                        color: _g(0.06)),
                    child: const Center(child: Text('Άκυρο',
                        style: TextStyle(color: Colors.white54, fontSize: 13))),
                  ),
                )),
                const SizedBox(width: 12),
                Expanded(child: GestureDetector(
                  onTap: () async {
                    final price = double.tryParse(priceCtrl.text.trim()) ?? 0;
                    if (price <= 0) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Βάλε τιμή!')));
                      return;
                    }
                    Navigator.pop(ctx);
                    await _submitOffer(requestId, requestData, price, msgCtrl.text.trim(), available);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        gradient: const LinearGradient(colors: [kGoldLight, kGold])),
                    child: const Center(child: Text('Στείλε! 🚀',
                        style: TextStyle(color: Colors.black,
                            fontWeight: FontWeight.w800, fontSize: 13))),
                  ),
                )),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  // lib/main.dart — αντικατάστησε ολόκληρη τη _submitOffer μέθοδο
// στο _ProfessionalHomeScreenState

Future<void> _submitOffer(String requestId, Map<String, dynamic> requestData,
    double price, String message, String available) async {
  try {
    // ΜΗΝ γράφεις στη Firestore εδώ — το server το κάνει
    // Μόνο το server endpoint είναι υπεύθυνο για αποθήκευση

    final response = await http.post(
      Uri.parse('$kBackendUrl/submit-offer'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'requestId': requestId,
        'professionalId': _proId ?? '',
        'professionalName': _proName ?? '',
        'price': price,
        'message': message,
        'availableFrom': available,
        'rating': 4.8,
        'emoji': '🔧',
        if (_proPhotoUrl != null) 'profilePhotoUrl': _proPhotoUrl,
        'specialty': _proSpecialty ?? '',
      }),
    ).timeout(const Duration(seconds: 8));

    if (response.statusCode == 200) {
      // Mark all new_request notifications for this request as read
      if (_proId != null) {
        FirebaseFirestore.instance
            .collection('users').doc(_proId)
            .collection('notifications')
            .where('requestId', isEqualTo: requestId)
            .where('isRead', isEqualTo: false)
            .get()
            .then((s) { for (final n in s.docs) n.reference.update({'isRead': true}); })
            .catchError((_) {});
      }
      // Persist submission in Firestore so it survives refresh
      FirebaseFirestore.instance.collection('requests').doc(requestId)
          .update({'submittedPros': FieldValue.arrayUnion([_proId ?? ''])})
          .catchError((_) {});
      if (mounted) {
        setState(() => _submittedIds.add(requestId));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('✅ Η προσφορά στάλθηκε!'),
            backgroundColor: kGreen.withValues(alpha: 0.9),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } else {
      // Server απέτυχε — fallback μόνο τότε
      await _submitOfferFallback(requestId, price, message, available);
    }
  } catch (e) {
    // Network error — fallback στη Firestore
    await _submitOfferFallback(requestId, price, message, available);
  }
}

// Fallback μόνο αν το server δεν απαντά
Future<void> _submitOfferFallback(String requestId, double price,
    String message, String available) async {
  try {
    // Έλεγξε αν υπάρχει ήδη προσφορά από τον ίδιο επαγγελματία
    final existing = await FirebaseFirestore.instance
        .collection('offers')
        .where('requestId', isEqualTo: requestId)
        .where('professionalId', isEqualTo: _proId ?? '')
        .limit(1)
        .get();
    
    if (existing.docs.isNotEmpty) {
      if (mounted) {
    }

    await FirebaseFirestore.instance.collection('offers').add({
      'requestId': requestId,
      'professionalId': _proId ?? '',
      'professionalName': _proName ?? '',
      'specialty': _proSpecialty ?? '',
      'price': price,
      'message': message,
      'availableFrom': available,
      'rating': 4.8,
      'emoji': '🔧',
      'createdAt': FieldValue.serverTimestamp(),
    });

    await FirebaseFirestore.instance
        .collection('requests').doc(requestId)
        .update({'offersCount': FieldValue.increment(1)});

    // Mark all new_request notifications for this request as read

    await FirebaseFirestore.instance
        .collection('requests').doc(requestId)
        .update({'offersCount': FieldValue.increment(1)});

    // Mark all new_request notifications for this request as read
    if (_proId != null) {
      FirebaseFirestore.instance
          .collection('users').doc(_proId)
          .collection('notifications')
          .where('requestId', isEqualTo: requestId)
          .where('isRead', isEqualTo: false)
          .get()
          .then((s) { for (final n in s.docs) n.reference.update({'isRead': true}); })
          .catchError((_) {});
    }

    FirebaseFirestore.instance.collection('requests').doc(requestId)
        .update({'submittedPros': FieldValue.arrayUnion([_proId ?? ''])})
        .catchError((_) {});
    if (mounted) {
      setState(() => _submittedIds.add(requestId));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                            Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                              Text(d['userName'] ?? '',
                                  style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white)),
                              Container(
                                padding:
                                    const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  borderRadius:
                                      BorderRadius.circular(20),
                                  color: isImmediate
                                      ? Colors.green.withValues(alpha: 0.15)
                                      : kGold.withValues(alpha: 0.15),
                                ),
                                child: Text(
                                    isImmediate
                                        ? '⚡ Άμεσα'
                                        : '📅 Προγρ/σμός',
                                    style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        color: isImmediate
                                            ? Colors.green
                                            : kGold)),
                              ),
                            ]),
                            const SizedBox(height: 10),
                            GestureDetector(
                              onTap: () => launchUrl(Uri.parse(
                                  'tel:${d['userPhone']}')),
                              child: Row(children: [
                                const Icon(Icons.phone_outlined,
                                    color: kGold, size: 15),
                                const SizedBox(width: 6),
                                Text(d['userPhone'] ?? '',
                                    style: const TextStyle(
                                        color: kGold,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 14)),
                              ]),
                            ),
                            const SizedBox(height: 5),
                            Row(children: [
                              Icon(Icons.access_time,
                                  color: _g(0.38),
                                  size: 14),
                              const SizedBox(width: 6),
                              Text(d['scheduledTime'] ?? '',
                                  style: TextStyle(
                                      color:
                                          _g(0.5),
                                      fontSize: 12)),
                            ]),
                            if (_activeTab == 'pending') ...[
                              const SizedBox(height: 12),
                              Row(children: [
                                Expanded(
                                    child: GestureDetector(
                                  onTap: () => _respondBooking(
                                      bookingId, 'accept'),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 10),
                                    decoration: BoxDecoration(
                                        borderRadius:
                                            BorderRadius.circular(12),
                                        color: Colors.green
                                            .withValues(alpha: 0.15)),
                                    child: const Center(
                                        child: Text('✅ Αποδοχή',
                                            style: TextStyle(
                                                color: Colors.green,
                                                fontWeight:
                                                    FontWeight.bold,
                                                fontSize: 13))),
                                  ),
                                )),
                                const SizedBox(width: 10),
                                Expanded(
                                    child: GestureDetector(
                                  onTap: () => _respondBooking(
                                      bookingId, 'reject'),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 10),
                                    decoration: BoxDecoration(
                                        borderRadius:
                                            BorderRadius.circular(12),
                                        color: Colors.red
                                            .withValues(alpha: 0.1)),
                                    child: const Center(
                                        child: Text('❌ Απόρριψη',
                                            style: TextStyle(
                                                color: Colors.red,
                                                fontWeight:
                                                    FontWeight.bold,
                                                fontSize: 13))),
                                  ),
                                )),
                              ]),
                            ],
                            if (_activeTab == 'accepted') ...[
                              const SizedBox(height: 10),
                              GestureDetector(
                                onTap: () {
                                  final userId = d['userId'] as String? ?? '';
                                  if (userId.isEmpty) return;
                                  final chatId = '${userId}_${_proId ?? ''}';
                                  Navigator.push(context, PageRouteBuilder(
                                    pageBuilder: (_, __, ___) => ChatScreen(
                                      chatId: chatId,
                                      currentUserId: _proId ?? '',
                                      currentUserName: _proName ?? 'Επαγγελματίας',
                                      otherName: d['userName'] as String? ?? 'Χρήστης',
                                      isPro: true,
                                    ),
                                    transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
                                    transitionDuration: const Duration(milliseconds: 300),
                                  ));
                                  FirebaseFirestore.instance.collection('chats').doc(chatId)
                                      .set({
                                    'userId': userId,
                                    'proId': _proId ?? '',
                                    'userName': d['userName'] ?? 'Χρήστης',
                                    'proName': _proName ?? 'Επαγγελματίας',
                                    'lastMessageAt': FieldValue.serverTimestamp(),
                                  }, SetOptions(merge: true)).catchError((_) {});
                                },
                                child: Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    gradient: const LinearGradient(colors: [kGoldLight, kGold]),
                                    boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.25), blurRadius: 8)],
                                  ),
                                  child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                    Text('💬', style: TextStyle(fontSize: 14)),
                                    SizedBox(width: 6),
                                    Text('Στείλε μήνυμα',
                                        style: TextStyle(color: Colors.black,
                                            fontWeight: FontWeight.bold, fontSize: 13)),
                                  ]),
                                ),
                              ),
                            ],
                            if (_activeTab != 'pending') ...[
                              const SizedBox(height: 10),
                              GestureDetector(
                                onTap: () async {
                                  await FirebaseFirestore.instance
                                      .collection('bookings')
                                      .doc(bookingId)
                                      .delete();
                                },
                                child: Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 9),
                                  decoration: BoxDecoration(
                                      borderRadius:
                                          BorderRadius.circular(12),
                                      color:
                                          Colors.red.withValues(alpha: 0.06)),
                                  child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                    Icon(Icons.delete_outline,
                                        color: Colors.red.withValues(alpha: 0.5),
                                        size: 14),
                                    const SizedBox(width: 6),
                                    Text('Διαγραφή',
                                        style: TextStyle(
                                            color:
                                                Colors.red.withValues(alpha: 0.5),
                                            fontSize: 12)),
                                  ]),
                                ),
                              ),
                            ],
                          ]),
                        ),
                      ]),
                    );
                  },
                );
              },
            ),
          ),
        ]),
      ),
    );
  }

  // ── Pro Messages Tab ──
  Widget _buildProMessagesTab() {
        'respondedAt': FieldValue.serverTimestamp(),
  Widget _buildMiniCvEditor() {
    // ── PREVIEW mode (bio saved) ──────────────────────────────
    if (!_bioEditMode && _bio.isNotEmpty) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('👤', style: TextStyle(fontSize: 20)),
            const SizedBox(width: 8),
            const Expanded(child: Text('Δημόσιο Προφίλ (Mini CV)',
                style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700))),
            GestureDetector(
              onTap: () => setState(() => _bioEditMode = true),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: kGold.withValues(alpha: 0.4)),
                  color: kGold.withValues(alpha: 0.08),
                ),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.edit_outlined, color: kGold, size: 13),
                  SizedBox(width: 5),
                  Text('Επεξεργασία', style: TextStyle(color: kGold, fontSize: 12, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Text('Αυτό βλέπουν οι χρήστες στο πορτφόλιό σου.',
              style: TextStyle(color: _g(0.35), fontSize: 12, height: 1.5)),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: _g(0.04),
              border: Border.all(color: kGold.withValues(alpha: 0.18)),
            ),
            child: Text(_bio, style: TextStyle(color: _g(0.8), fontSize: 13, height: 1.65)),
          ),
        ]),
      );
    }

    // ── EDIT mode ────────────────────────────────────────────
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('👤', style: TextStyle(fontSize: 20)),
          const SizedBox(width: 8),
          const Expanded(child: Text('Δημόσιο Προφίλ (Mini CV)',
              style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700))),
          if (_bio.isNotEmpty)
            GestureDetector(
              onTap: () => setState(() { _bioCtrl.text = _bio; _bioEditMode = false; }),
              child: Icon(Icons.close, color: _g(0.4), size: 20),
            ),
        ]),
        const SizedBox(height: 6),
        Text('Αυτό θα βλέπουν οι χρήστες στο πορτφόλιό σου.',
            style: TextStyle(color: _g(0.4), fontSize: 12, height: 1.5)),
        const SizedBox(height: 16),
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: _g(0.04),
            border: Border.all(color: kGold.withValues(alpha: 0.25)),
          ),
          child: TextField(
            controller: _bioCtrl,
            maxLines: 10,
            maxLength: 600,
            style: TextStyle(color: _g(0.85), fontSize: 13, height: 1.6),
            decoration: InputDecoration(
              hintText: 'Γράψε για εσένα — εμπειρία, ειδικότητες, περιοχές που εξυπηρετείς, τιμές, διαθεσιμότητα...',
              hintStyle: TextStyle(color: _g(0.3), fontSize: 12),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.all(16),
              counterStyle: TextStyle(color: _g(0.25), fontSize: 10),
            ),
          ),
        ),
        const SizedBox(height: 16),
        GestureDetector(
          onTap: _savingBio ? null : _saveBio,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: _savingBio
                  ? LinearGradient(colors: [_g(0.1), _g(0.1)])
                  : const LinearGradient(colors: [kGoldLight, kGold, kGoldDark]),
              boxShadow: _savingBio ? [] : [BoxShadow(color: kGold.withValues(alpha: 0.3), blurRadius: 12)],
            ),
            child: Center(child: _savingBio
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2))
                : const Text('💾 Αποθήκευση', style: TextStyle(
                    color: Colors.black, fontSize: 14, fontWeight: FontWeight.w800))),
          ),
        ),
      ]),
    );
  }

  // ── Requests list για επαγγελματίες ──
  Widget _buildRequestsList() {
    if (_proName == null || _proName!.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: kGold));
    }
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('requests')
          .where('status', isEqualTo: 'active')
             .limit(20)
          .snapshots(),
                        activeTrackColor: kGreen.withValues(alpha: 0.3),
                        inactiveThumbColor: Colors.grey,
                        inactiveTrackColor: Colors.grey.withValues(alpha: 0.2),
                      ),
              ]),
            ),
          ),

          const SizedBox(height: 10),

          // ══════════════════════════════════════
          // TABS — scrollable pill style
          // ══════════════════════════════════════
          StreamBuilder<QuerySnapshot>(
            stream: (_proId == null || _proId!.isEmpty) ? const Stream.empty()
                : FirebaseFirestore.instance.collection('bookings')
                    .where('professionalId', isEqualTo: _proId).snapshots(),
  static const _areas = [
    'Αθήνα Κέντρο', 'Κολωνάκι', 'Γλυφάδα', 'Βούλα', 'Βουλιαγμένη',
    'Καλλιθέα', 'Νέα Σμύρνη', 'Παλαιό Φάληρο', 'Άλιμος', 'Χαλάνδρι',
    'Μαρούσι', 'Κηφισιά', 'Νέα Ιωνία', 'Αγία Παρασκευή', 'Ζωγράφου',
    'Βύρωνας', 'Ηλιούπολη', 'Περιστέρι', 'Αιγάλεω', 'Πειραιάς',
    'Θεσσαλονίκη Κέντρο', 'Καλαμαριά', 'Πυλαία', 'Θέρμη',
    'Πάτρα', 'Ηράκλειο Κρήτης', 'Χανιά', 'Ρέθυμνο', 'Λάρισα', 'Βόλος',
    'Ιωάννινα', 'Κέρκυρα', 'Ρόδος', 'Μυτιλήνη',
  ];

  Future<void> _showPicker() async {
    final result = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _SimpleListPicker(
        title: '📍 Περιοχή εργασίας',
        items: ['📍 Κοντά μου (GPS)', ..._areas],
        selected: widget.value,
      ),
                    : _activeTab == 'minicv'
                    ? _buildMiniCvEditor()
                    : _activeTab == 'messages'
                    ? _buildProMessagesTab()
                    : StreamBuilder<QuerySnapshot>(
              // Query only by professionalId (single-field index, no composite needed)
              // Status filtering done in-code to avoid Firestore composite index requirement
              stream: (_proId == null || _proId!.isEmpty)
                  ? const Stream.empty()
                  : FirebaseFirestore.instance
                      .collection('bookings')
                      .where('professionalId', isEqualTo: _proId)
                      .snapshots(),
              builder: (context, snap) {
                if (snap.hasError)
                  return Center(
                      child: Text('Σφάλμα φόρτωσης',
                          style: TextStyle(color: _g(0.4))));
                if (!snap.hasData)
                  return const Center(
                      child: CircularProgressIndicator(color: kGold));
                // Filter by status in code
                final docs = snap.data!.docs
                    .where((d) => (d.data() as Map)['status'] == _activeTab)
                    .toList()
                  ..sort((a, b) {
                    final aTs = (a.data() as Map)['createdAt'];
                    final bTs = (b.data() as Map)['createdAt'];
                    if (aTs == null) return 1;
                    if (bTs == null) return -1;
                    return (bTs as Timestamp).compareTo(aTs as Timestamp);
                  });
                if (docs.isEmpty) {
                  return Center(
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                        Icon(Icons.inbox_outlined,
                            color: _g(0.15),
                            size: 48),
                        const SizedBox(height: 12),
                        Text('Δεν υπάρχουν αιτήματα',
                            style: TextStyle(
                                color: _g(0.3))),
                      ]));
                }
      _googlePlaceId = gPlaceId;
      _googleRating = gRating;
      _googleRatingCount = gRatingCount;
      _googleMapsUrl = gMapsUrl;
    });
                      boxShadow: [BoxShadow(
  Future<void> _loadProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    // Load specialty from professionals collection
    final proSnap = await FirebaseFirestore.instance
        .collection('professionals')
        .where('userId', isEqualTo: user.uid)
        .limit(1)
        .get();
    if (!mounted) return;
    final photoUrl = doc.data()?['profilePhotoUrl'] as String?;
    final bio = doc.data()?['bio'] as String? ?? '';
    final rawSpecs = doc.data()?['specialties'];
    final specs = rawSpecs is List ? List<String>.from(rawSpecs.map((e) => e.toString())) : <String>[];
    final available = doc.data()?['available'] as bool? ?? true;
    final avgRating = (doc.data()?['averageRating'] as num?)?.toDouble() ?? 0.0;
    // Load areas from professionals collection
    List<String> areas = [];
    if (proSnap.docs.isNotEmpty) {
      final proData = proSnap.docs.first.data();
      final rawAreas = proData['areas'];
      if (rawAreas is List) {
        areas = List<String>.from(rawAreas.map((e) => e.toString()));
      } else {
        final singleArea = proData['area'] as String?;
        if (singleArea != null && singleArea.isNotEmpty) areas = [singleArea];
      }
    }
    String? gPlaceId;
    double? gRating;
    int gRatingCount = 0;
    String gMapsUrl = '';
    if (proSnap.docs.isNotEmpty) {
              final bDocs = bSnap.data?.docs ?? [];
              final pendBadge = bDocs.where((d) => (d.data() as Map)['status'] == 'pending').length;
              final accBadge = bDocs.where((d) => (d.data() as Map)['status'] == 'accepted').length;
              return StreamBuilder<QuerySnapshot>(
                stream: (_proId == null || _proId!.isEmpty) ? const Stream.empty()
                    : FirebaseFirestore.instance.collection('chats')
                        .where('proId', isEqualTo: _proId).snapshots(),
                builder: (context, chatSnap) {
                  int msgBadge = 0;
                  if (chatSnap.hasData) {
                    for (final doc in chatSnap.data!.docs) {
                      final d = doc.data() as Map<String, dynamic>;
                      msgBadge += (d['unreadPro'] as int?) ?? 0;
                    }
                  }
                  return StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance.collection('requests')
                    .where('status', isEqualTo: 'active').limit(50).snapshots(),
                builder: (context, rSnap) {
                  final matchingReqs = rSnap.data?.docs
                      .where((d) => _proMatchesRequest(d.data() as Map<String, dynamic>))
                      .length ?? 0;
                  final reqBadge = matchingReqs + _eventReqDocs.length;
                  return SizedBox(
                    height: 42,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        _buildProTab('requests', '📋 Αιτήματα', badge: reqBadge),
    }
  }

  Future<Uint8List?> _fetchPhotoBytes(String url) async {
    try {
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: const BorderRadius.vertical(
                              bottom: Radius.circular(22)),
                          color: kGold.withValues(alpha: 0.06),
                        ),
                        padding: const EdgeInsets.all(6),
                        child: Row(children: [
                          // MIC BUTTON
                          GestureDetector(
          // ══════════════════════════════════════
          StreamBuilder<QuerySnapshot>(
            stream: (_proId == null || _proId!.isEmpty) ? const Stream.empty()
                : FirebaseFirestore.instance.collection('bookings')
                    .where('professionalId', isEqualTo: _proId).snapshots(),
            builder: (context, bSnap) {
              final bDocs = bSnap.data?.docs ?? [];
              final pendBadge = bDocs.where((d) => (d.data() as Map)['status'] == 'pending').length;
              final accBadge = bDocs.where((d) => (d.data() as Map)['status'] == 'accepted').length;
              return StreamBuilder<QuerySnapshot>(
                stream: (_proId == null || _proId!.isEmpty) ? const Stream.empty()
                    : FirebaseFirestore.instance.collection('chats')
                        .where('proId', isEqualTo: _proId).snapshots(),
                builder: (context, chatSnap) {
                  int msgBadge = 0;
                  if (chatSnap.hasData) {
                    for (final doc in chatSnap.data!.docs) {
                      final d = doc.data() as Map<String, dynamic>;
                      msgBadge += (d['unreadPro'] as int?) ?? 0;
                    }
  Widget _buildMiniCvEditor() {
    // ── PREVIEW mode (bio saved) ──────────────────────────────
    if (!_bioEditMode && _bio.isNotEmpty) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('👤', style: TextStyle(fontSize: 20)),
            const SizedBox(width: 8),
            const Expanded(child: Text('Δημόσιο Προφίλ (Mini CV)',
                style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700))),
            GestureDetector(
              onTap: () => setState(() => _bioEditMode = true),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: kGold.withValues(alpha: 0.4)),
                  color: kGold.withValues(alpha: 0.08),
                ),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.edit_outlined, color: kGold, size: 13),
                  SizedBox(width: 5),
                  Text('Επεξεργασία', style: TextStyle(color: kGold, fontSize: 12, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Text('Αυτό βλέπουν οι χρήστες στο πορτφόλιό σου.',
              style: TextStyle(color: _g(0.35), fontSize: 12, height: 1.5)),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: _g(0.04),
              border: Border.all(color: kGold.withValues(alpha: 0.18)),
            ),
            child: Text(_bio, style: TextStyle(color: _g(0.8), fontSize: 13, height: 1.65)),
          ),
        ]),
      );
    }

    // ── EDIT mode ────────────────────────────────────────────
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('👤', style: TextStyle(fontSize: 20)),
          const SizedBox(width: 8),
          const Expanded(child: Text('Δημόσιο Προφίλ (Mini CV)',
              style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700))),
          if (_bio.isNotEmpty)
            GestureDetector(
              onTap: () => setState(() { _bioCtrl.text = _bio; _bioEditMode = false; }),
              child: Icon(Icons.close, color: _g(0.4), size: 20),
            ),
        ]),
        const SizedBox(height: 6),
        Text('Αυτό θα βλέπουν οι χρήστες στο πορτφόλιό σου.',
            style: TextStyle(color: _g(0.4), fontSize: 12, height: 1.5)),
        const SizedBox(height: 16),
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: _g(0.04),
            border: Border.all(color: kGold.withValues(alpha: 0.25)),
          ),
          child: TextField(
            controller: _bioCtrl,
            maxLines: 10,
            maxLength: 600,
            style: TextStyle(color: _g(0.85), fontSize: 13, height: 1.6),
            decoration: InputDecoration(
              hintText: 'Γράψε για εσένα — εμπειρία, ειδικότητες, περιοχές που εξυπηρετείς, τιμές, διαθεσιμότητα...',
              hintStyle: TextStyle(color: _g(0.3), fontSize: 12),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.all(16),
              counterStyle: TextStyle(color: _g(0.25), fontSize: 10),
            ),
          ),
        ),
        const SizedBox(height: 16),
        GestureDetector(
          onTap: _savingBio ? null : _saveBio,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: _savingBio
                  ? LinearGradient(colors: [_g(0.1), _g(0.1)])
                  : const LinearGradient(colors: [kGoldLight, kGold, kGoldDark]),
              boxShadow: _savingBio ? [] : [BoxShadow(color: kGold.withValues(alpha: 0.3), blurRadius: 12)],
            ),
            child: Center(child: _savingBio
                ? const SizedBox(width: 18, height: 18,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 40, height: 4,
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  color: Colors.white.withValues(alpha: 0.2))),
          const SizedBox(height: 20),
          Text('Προσθήκη μέσου', style: TextStyle(
              color: _gw, fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 20),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            _MediaOption(icon: Icons.camera_alt_outlined, label: 'Κάμερα\nΦωτογραφία', onTap: () async {
              Navigator.pop(ctx);
              await _captureImage(ImageSource.camera);
            }),
            _MediaOption(icon: Icons.photo_library_outlined, label: 'Βιβλιοθήκη\nΦωτογραφιών', onTap: () async {
              Navigator.pop(ctx);
              await _captureImage(ImageSource.gallery);
            }),
            _MediaOption(icon: Icons.videocam_outlined, label: 'Κάμερα\nΒίντεο', onTap: () async {
              Navigator.pop(ctx);
              await _captureVideo(ImageSource.camera);
            }),
            _MediaOption(icon: Icons.video_library_outlined, label: 'Βιβλιοθήκη\nΒίντεο', onTap: () async {
              Navigator.pop(ctx);
              await _captureVideo(ImageSource.gallery);
            }),
          ]),
        ]),
      ),
    );
  }

  Future<void> _captureImage(ImageSource source) async {
    List<XFile> picked = [];
    if (source == ImageSource.gallery) {
      picked = await _picker.pickMultiImage();
    } else {
      final f = await _picker.pickImage(source: ImageSource.camera);
      if (f != null) picked = [f];
    }
    if (picked.isEmpty) return;
    final compressed = <XFile>[];
    for (final f in picked.take(3 - _images.length - _videoFiles.length)) {
      try {
        final bytes = await f.readAsBytes();
        final small = await _compressImage(bytes);
        compressed.add(small != null
            ? XFile.fromData(small, name: f.name, mimeType: 'image/png') : f);
      } catch (_) { compressed.add(f); }
    }
    setState(() => _images.addAll(compressed));
  }

  Future<void> _captureVideo(ImageSource source) async {
    if (_images.length + _videoFiles.length >= 3) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Μέγιστο 3 αρχεία')));
      return;
    }
    final video = await _picker.pickVideo(
        source: source, maxDuration: const Duration(seconds: 30));
    if (video == null) return;
    final size = await video.length();
    if (size > 80 * 1024 * 1024) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Το βίντεο είναι πολύ μεγάλο (max 80 MB)')));
      return;
    }
    setState(() => _videoFiles.add(video));
  }

  bool _submitLock = false;  // Guard κατά double submit

  Future<void> _submit() async {
    if (_submitLock) return;  // Αποφυγή double tap
    _submitLock = true;
    if (_textCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Περίγραψε τι χρειάζεσαι!')));
      return;

  Future<void> _submit() async {
    if (_submitLock) return;  // Αποφυγή double tap
    _submitLock = true;
    if (_textCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Περίγραψε τι χρειάζεσαι!')));
      return;
    }
    // Έλεγξε αν υπάρχουν ήδη 2 ενεργά αιτήματα
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final existing = await FirebaseFirestore.instance
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final existing = await FirebaseFirestore.instance
          .collection('requests')
          .where('userId', isEqualTo: user.uid)
          .where('status', isEqualTo: 'active')
          .get();
      if (existing.docs.length >= 2) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Μπορείς να έχεις μέχρι 2 ενεργά αιτήματα!')));
        return;
      }
    }
    setState(() => _sending = true);
    try {
      final docRef = await FirebaseFirestore.instance
          .collection('requests')
          .add({
        'userId': widget.userId,
        'userName': widget.userName,
        'description': _textCtrl.text.trim(),
        'criteria': _selectedCriteria,
        'profession': _selectedProfession ?? '',
        'location': _selectedLocation ?? '',
        'status': 'active',
        'offersCount': 0,
        'createdAt': FieldValue.serverTimestamp(),
        'expiresAt': Timestamp.fromDate(
            DateTime.now().add(const Duration(minutes: 15))),
        'imageCount': _images.length,
      });

      // ── 1. Read ALL bytes before navigation (XFile blob URLs expire after widget disposal on web) ──
      List<String> imageBase64 = [];
      for (final img in _images) {
        try { imageBase64.add(base64Encode(await img.readAsBytes())); } catch (_) {}
      }

      // Read video bytes NOW while XFile is still valid
      final List<({String name, Uint8List bytes, String mime})> videoData = [];
      for (final vid in _videoFiles) {
        try {
          final bytes = await vid.readAsBytes();
          videoData.add((name: vid.name, bytes: bytes, mime: vid.mimeType ?? 'video/mp4'));
        } catch (_) {}
      }

      // ── 2. Save images to Firestore ──
      if (imageBase64.isNotEmpty) {
        await FirebaseFirestore.instance
            .collection('requests')
            .doc(docRef.id)
            .update({'images': imageBase64, 'hasImages': true});
      }

      // ── 3. Upload videos in background using pre-read bytes (safe after navigation) ──
      if (videoData.isNotEmpty) {
        final requestDocId = docRef.id;
        final uploadUserId = widget.userId;
        Future(() async {
          // Log start of upload
          await FirebaseFirestore.instance.collection('debug_uploads').add({
            'status': 'start', 'count': videoData.length,
            'requestId': requestDocId, 'userId': uploadUserId,
            'ts': FieldValue.serverTimestamp(),
          });
          final videoUrls = <String>[];
          for (int i = 0; i < videoData.length; i++) {
            final v = videoData[i];
            try {
              if (v.bytes.isEmpty) {
                await FirebaseFirestore.instance.collection('debug_uploads').add({
                  'error': 'bytes_empty', 'index': i, 'requestId': requestDocId,
                  'ts': FieldValue.serverTimestamp(),
                });
                continue;
              }
              final ext = v.mime.contains('mp4') ? 'mp4'
                  : v.mime.contains('webm') ? 'webm'
                  : v.mime.contains('quicktime') ? 'mov' : 'mp4';
              final contentType = v.mime.isNotEmpty ? v.mime : 'video/mp4';
              final fileName = 'video_${i}_${DateTime.now().millisecondsSinceEpoch}.$ext';
              // Use Firebase Storage REST API directly (avoids SDK CORS hang on web)
              final user = FirebaseAuth.instance.currentUser;
              if (user == null) throw Exception('not_authenticated');
              final idToken = await user.getIdToken();
              const bucket = 'shoppilot-app-e4104.firebasestorage.app';
              final objectPath = 'requests/$requestDocId/videos/$fileName';
              final encodedPath = Uri.encodeComponent(objectPath);
              final uploadUrl = Uri.parse(
                'https://firebasestorage.googleapis.com/v0/b/$bucket/o'
                '?uploadType=media&name=$encodedPath',
              );
              final uploadResp = await http.post(
                uploadUrl,
                headers: {
                  'Authorization': 'Firebase $idToken',
                  'Content-Type': contentType,
                },
                body: v.bytes,
              ).timeout(const Duration(seconds: 120));
              if (uploadResp.statusCode != 200) {
                throw Exception('HTTP ${uploadResp.statusCode}: ${uploadResp.body}');
              }
              final respJson = jsonDecode(uploadResp.body) as Map<String, dynamic>;
              final token = respJson['downloadTokens'] as String? ?? '';
              final url = 'https://firebasestorage.googleapis.com/v0/b/$bucket'
                  '/o/$encodedPath?alt=media&token=$token';
              videoUrls.add(url);
              await FirebaseFirestore.instance.collection('debug_uploads').add({
                'status': 'ok', 'index': i, 'requestId': requestDocId,
                'url': url, 'bytes': v.bytes.length, 'mime': contentType,
                'ts': FieldValue.serverTimestamp(),
              });
            } catch (e) {
              debugPrint('Video upload error [$i]: $e');
              // Write error to Firestore so we can diagnose in production
              try {
                await FirebaseFirestore.instance.collection('debug_uploads').add({
                  'error': e.toString(), 'index': i, 'requestId': requestDocId,
                  'userId': uploadUserId, 'bytesLen': v.bytes.length,
                  'mime': v.mime,
                  'ts': FieldValue.serverTimestamp(),
                });
              } catch (_) {}
            }
          }
          if (videoUrls.isNotEmpty) {
            await FirebaseFirestore.instance
                .collection('requests')
                .doc(requestDocId)
                .update({'videoUrls': videoUrls, 'hasVideos': true});
            // Also update each pro's notification doc so the card shows video links
            try {
              final reqSnap = await FirebaseFirestore.instance
                  .collection('requests').doc(requestDocId).get();
              final notifiedPros = List<String>.from(
                  reqSnap.data()?['notifiedPros'] ?? []);
              for (final proId in notifiedPros) {
                final notifQuery = await FirebaseFirestore.instance
                    .collection('users').doc(proId)
                    .collection('notifications')
                    .where('requestId', isEqualTo: requestDocId)
                    .get();
                for (final nd in notifQuery.docs) {
                  nd.reference.update({
                    'videoUrls': videoUrls,
                    'hasVideos': true,
                    'videoUrls': videoUrls,
                    'hasVideos': true,
                  }).catchError((_) {});
                }
              }
            } catch (_) {}
          }
        });
      final _notifUser = widget.userName;
      final _notifImgCount = _images.length;
      Future(() => _notifyProsDirectly(_notifRequestId, _notifDesc,
          _notifProf, _notifLoc, _notifUser, _notifImgCount));

      if (!mounted) return;
      Navigator.pushReplacement(
          context,
          PageRouteBuilder(
            transitionDuration: const Duration(milliseconds: 400),
            pageBuilder: (_, __, ___) => WaitingScreen(
              requestId: docRef.id,
              userId: widget.userId,
              description: _textCtrl.text.trim(),
              criteria: _selectedCriteria,
              profession: _selectedProfession ?? '',
            ),
            transitionsBuilder: (_, a, __, c) =>
                FadeTransition(opacity: a, child: c),
          ));
    } catch (e) {
      _submitLock = false;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Σφάλμα: $e')));
    }
  }
Future<void> _notifyProsDirectly(
    String requestId,
    String description,
                                  final userId = d['userId'] as String? ?? '';
                                  if (userId.isEmpty) return;
                                  final chatId = '${userId}_${_proId ?? ''}';
                                  Navigator.push(context, PageRouteBuilder(
                                    pageBuilder: (_, __, ___) => ChatScreen(
                                      chatId: chatId,
                                      currentUserId: _proId ?? '',
                                      currentUserName: _proName ?? 'Επαγγελματίας',
                                      otherName: d['userName'] as String? ?? 'Χρήστης',
                                      isPro: true,
Future<void> _notifyProsDirectly(
    String requestId,
    String description,
    String profession,
    String location,
    String userName,
    int imageCount,
  ) async {
    try {
      // Wait 5s so backend's Firestore trigger fires first — then we overwrite it
      await Future.delayed(const Duration(seconds: 5));

      // Χτίζουμε query με φίλτρα απευθείας στο Firestore
      Query<Map<String, dynamic>> q = FirebaseFirestore.instance
          .collection('professionals')
          .where('is_active', isEqualTo: true);
      // Φίλτρο επαγγέλματος — αν έχει δοθεί, στέλνουμε ΜΟΝΟ σε αυτή την ειδικότητα
      if (profession.isNotEmpty) {
        q = q.where('specialty', isEqualTo: profession);
      }
      // Φίλτρο τοποθεσίας — αν έχει δοθεί και δεν είναι "Κοντά μου"
      if (location.isNotEmpty && location != 'Κοντά μου') {
        q = q.where('area', isEqualTo: location);
      }
      final snap = await q.get();
      int notified = 0;
      final notifiedProIds = <String>[];
      final db = FirebaseFirestore.instance;
      for (final doc in snap.docs) {
        final proUserId = (doc.data()['userId'] as String? ?? '');
        if (proUserId.isEmpty) continue;
        // DELETE any existing notifications for this requestId (backend duplicates)
        try {
          final existing = await db
              .collection('users').doc(proUserId)
              .collection('notifications')
              .where('requestId', isEqualTo: requestId)
              .get();
          for (final old in existing.docs) {
            await old.reference.delete();
          }
        } catch (_) {}
        // CREATE the single correct notification
        await db
            .collection('users')
            .doc(proUserId)
            .collection('notifications')
            .add({
          'title': '🔔 Νέο αίτημα${profession.isNotEmpty ? " για $profession" : ""}!',
          'body': '$userName: ${description.length > 80 ? "${description.substring(0, 80)}..." : description}',
          'isRead': false,
          'requestId': requestId,
          'type': 'new_request',
          'hasImages': imageCount > 0,
          'imageCount': imageCount,
          'createdAt': FieldValue.serverTimestamp(),
        });
        notifiedProIds.add(proUserId);
        notified++;
      }
      // Store notified pro IDs in request so cancellation can clean them up
      if (notifiedProIds.isNotEmpty) {
        FirebaseFirestore.instance
            .collection('requests')
            .doc(requestId)
            .update({'notifiedPros': notifiedProIds}).catchError((_) {});
      }
      debugPrint('📬 Flutter fallback: $notified pros notified (profession=$profession, location=$location)');
    } catch (e) {
      debugPrint('_notifyProsDirectly error: $e');
                  },
                );
              },
            ),
          ),
        ]),
      ),
    );
  }

  // ── Pro Messages Tab ──
  Widget _buildProMessagesTab() {
    if (_proId == null || _proId!.isEmpty) {
      return Center(child: Text('—', style: TextStyle(color: _g(0.3))));
    }
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('chats')
          .where('proId', isEqualTo: _proId)
          .snapshots(),
      builder: (ctx, snap) {
        if (snap.hasError)
          return Center(child: Text('Σφάλμα φόρτωσης', style: TextStyle(color: _g(0.3))));
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator(color: kGold));
        }
        // Sort by lastMessageAt in code (avoids composite index requirement)
        final docs = [...snap.data!.docs]
          ..sort((a, b) {
            final aTs = (a.data() as Map)['lastMessageAt'] as Timestamp?;
            final bTs = (b.data() as Map)['lastMessageAt'] as Timestamp?;
            if (aTs == null && bTs == null) return 0;
            if (aTs == null) return 1;
            if (bTs == null) return -1;
            return bTs.compareTo(aTs);
          });
        if (docs.isEmpty) {
          return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.chat_bubble_outline, color: _g(0.15), size: 52),
        bool isPremium = false;
        if (snap.hasData && snap.data!.exists) {
          final d = snap.data!.data() as Map<String, dynamic>?;
          isPremium = d?['isPremium'] == true;
        }
        return SingleChildScrollView(
          ]));
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
          itemCount: docs.length,
          itemBuilder: (_, i) {
            final d = docs[i].data() as Map<String, dynamic>;
            final chatId = docs[i].id;
            final chatRef = docs[i].reference;
            final userName = d['userName'] as String? ?? 'Χρήστης';
            final lastMsg = d['lastMessage'] as String? ?? '';
            final ts = d['lastMessageAt'] as Timestamp?;
            final unread = (d['unreadPro'] as int?) ?? 0;
            final timeStr = ts != null
                ? '${ts.toDate().hour.toString().padLeft(2, '0')}:${ts.toDate().minute.toString().padLeft(2, '0')}'
                : '';

            Future<void> deleteChat() async {
              // Delete all messages first, then the chat doc
              try {
                final msgs = await chatRef.collection('messages').get();
                for (final m in msgs.docs) { await m.reference.delete(); }
                await chatRef.delete();
              } catch (_) {}
            }

            return Dismissible(
              key: Key(chatId),
              direction: DismissDirection.endToStart,
              confirmDismiss: (_) async {
                return await showDialog<bool>(
                  context: ctx,
                  builder: (dCtx) => AlertDialog(
                    backgroundColor: const Color(0xFF111111),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                    : const LinearGradient(colors: [kGoldLight, kGold, kGoldDark]),
                boxShadow: _savingBio ? [] : [BoxShadow(color: kGold.withValues(alpha: 0.25), blurRadius: 10)],
              ),
              child: Center(child: _savingBio
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2))
                  : const Text('💾 Αποθήκευση βιο', style: TextStyle(
                      color: Colors.black, fontSize: 13, fontWeight: FontWeight.w800))),
            ),
          ),
        ],

        const SizedBox(height: 22),

        // ── Ειδικότητες ───────────────────────────────────
        Row(children: [
          const Expanded(child: _MiniCvSection(label: 'ΕΙΔΙΚΟΤΗΤΕΣ')),
          GestureDetector(
            onTap: _showSpecialtiesSheet,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: kGold.withValues(alpha: 0.1),
                border: Border.all(color: kGold.withValues(alpha: 0.3)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.edit_outlined, color: kGold, size: 11),
                const SizedBox(width: 4),
                const Text('Επεξεργασία', style: TextStyle(color: kGold, fontSize: 11, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        if (_savingSpecialties)
          const Padding(padding: EdgeInsets.all(8), child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: kGold, strokeWidth: 2))))
        else if (_specialties.isEmpty)
          GestureDetector(
            onTap: _showSpecialtiesSheet,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kGold.withValues(alpha: 0.2), style: BorderStyle.solid),
                color: kGold.withValues(alpha: 0.04),
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.add_circle_outline, color: kGold.withValues(alpha: 0.6), size: 16),
                const SizedBox(width: 8),
                Text('Πρόσθεσε ειδικότητες', style: TextStyle(color: kGold.withValues(alpha: 0.6), fontSize: 13)),
              ]),
            ),
          )
        else
          Wrap(spacing: 8, runSpacing: 8, children: _specialties.map((s) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: kGold.withValues(alpha: 0.1),
              border: Border.all(color: kGold.withValues(alpha: 0.3)),
            ),
            child: Text(s, style: const TextStyle(color: kGold, fontSize: 12, fontWeight: FontWeight.w600)),
          )).toList()),

        const SizedBox(height: 22),

        // ── Περιοχές εξυπηρέτησης ─────────────────────────
        Row(children: [
          const Expanded(child: _MiniCvSection(label: 'ΠΕΡΙΟΧΕΣ ΕΞΥΠΗΡΕΤΗΣΗΣ')),
          GestureDetector(
            onTap: _showAreasSheet,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: kGold.withValues(alpha: 0.08),
                border: Border.all(color: kGold.withValues(alpha: 0.2)),
              ),
              child: Text(_areas.isEmpty ? '+ Πρόσθεσε' : 'Επεξεργασία',
                  style: const TextStyle(color: kGold, fontSize: 11, fontWeight: FontWeight.w700)),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        if (_savingAreas)
          const Padding(padding: EdgeInsets.all(8), child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: kGold, strokeWidth: 2))))
        else if (_areas.isEmpty)
          GestureDetector(
            onTap: _showAreasSheet,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
                color: Colors.blue.withValues(alpha: 0.04),
              ),
  Widget _buildRequestsList() {
    if (_proName == null || _proName!.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: kGold));
    }
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('requests')
          .where('status', isEqualTo: 'active')
             .limit(20)
          .snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator(color: kGold));
        }
        final docs = snap.data!.docs.toList();
        if (docs.isEmpty) {
          return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 80, height: 80,
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: kGold.withValues(alpha: 0.06),
                  border: Border.all(color: kGold.withValues(alpha: 0.15))),
              child: const Center(child: Text('🔔', style: TextStyle(fontSize: 36))),
            ),
            const SizedBox(height: 16),
            Text('Κανένα ενεργό αίτημα',
                style: TextStyle(color: _gw, fontSize: 16,
                    fontWeight: FontWeight.w700, fontFamily: 'Raleway')),
            const SizedBox(height: 6),
            Text('Θα ειδοποιηθείς αμέσως όταν έρθει νέο αίτημα',
                textAlign: TextAlign.center,
                style: TextStyle(color: _g(0.35), fontSize: 12)),
          ]));
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          itemCount: docs.length,
          itemBuilder: (_, i) {
            final d = docs[i].data() as Map<String, dynamic>;
            final requestId = docs[i].id;
            final criteria = d['criteria'] ?? 'cheap';
            final criteriaEmoji = criteria == 'cheap' ? '💰' : criteria == 'value' ? '⭐' : '⚡';
            final criteriaLabel = criteria == 'cheap' ? 'Φθηνότερο' : criteria == 'value' ? 'Value' : 'Άμεσα';
            final profession = d['profession'] as String? ?? '';
            final location = d['location'] as String? ?? '';
            final expiresAt = d['expiresAt'] as Timestamp?;
            final offersCountInCard = d['offersCount'] as int? ?? 0;
            final submittedPros = List<String>.from(d['submittedPros'] ?? []);
            final alreadySubmitted = _submittedIds.contains(requestId) ||
                submittedPros.contains(_proId ?? '');
            return Container(
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: const Color(0xFF0E0B04),
                border: Border.all(color: kGold.withValues(alpha: 0.2)),
                boxShadow: [BoxShadow(
                    color: kGold.withValues(alpha: 0.06), blurRadius: 16)],
              ),
              child: Column(children: [
                // Top accent line
                Container(height: 2,
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                    gradient: LinearGradient(colors: [
                      kGold.withValues(alpha: 0.0),
                      kGold.withValues(alpha: 0.7),
                      kGold.withValues(alpha: 0.0),
                    ]),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    // Header row
                    Row(children: [
                      Container(
                        width: 44, height: 44,
                        decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(13),
                            gradient: LinearGradient(
                                colors: [kGold.withValues(alpha: 0.2), kGold.withValues(alpha: 0.06)])),
                        child: Center(child: Text(
                            criteriaEmoji, style: const TextStyle(fontSize: 22))),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(d['userName'] ?? 'Χρήστης',
                            style: const TextStyle(fontSize: 15,
                                fontWeight: FontWeight.w700, color: Colors.white)),
                        const SizedBox(height: 3),
                        Row(children: [
                          if (profession.isNotEmpty) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(6),
                                  color: kGold.withValues(alpha: 0.1)),
                              child: Text(profession,
                                  style: const TextStyle(color: kGold,
                                      fontSize: 10, fontWeight: FontWeight.w600)),
                            ),
                            const SizedBox(width: 5),
                          ],
                          if (location.isNotEmpty)
                            Text('📍 $location', style: TextStyle(
                                color: _g(0.4), fontSize: 10)),
                        ]),
                      ])),
                      // Criteria badge
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            color: kGold.withValues(alpha: 0.08),
                            border: Border.all(color: kGold.withValues(alpha: 0.25))),
                        child: Column(children: [
                          Text(criteriaEmoji, style: const TextStyle(fontSize: 14)),
                        const Color(0xFF7C3AED).withValues(alpha: 0.0),
                      ]),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Container(
                          width: 44, height: 44,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(13),
                            color: const Color(0xFF7C3AED).withValues(alpha: 0.15),
                          ),
                          child: Center(child: Text(ev['categoryEmoji'] ?? '🎉',
                              style: const TextStyle(fontSize: 22))),
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(ev['userName'] ?? 'Χρήστης',
                              style: const TextStyle(fontSize: 15,
                                  fontWeight: FontWeight.w700, color: Colors.white)),
                          const SizedBox(height: 3),
                          Row(children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(6),
                                  color: const Color(0xFF7C3AED).withValues(alpha: 0.15)),
                              child: Text(ev['categoryTitle'] ?? '',
                                  style: const TextStyle(color: Color(0xFFBB86FC),
                                      fontSize: 10, fontWeight: FontWeight.w600)),
                            ),
                            const SizedBox(width: 5),
                            if ((ev['location'] as String? ?? '').isNotEmpty)
                              Text('📍 ${ev['location']}', style: TextStyle(color: _g(0.4), fontSize: 10)),
                          ]),
                        ])),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                          decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              color: const Color(0xFF7C3AED).withValues(alpha: 0.1),
                              border: Border.all(color: const Color(0xFF7C3AED).withValues(alpha: 0.3))),
                          child: const Column(children: [
                            Text('🎊', style: TextStyle(fontSize: 14)),
                            Text('EVENT', style: TextStyle(color: Color(0xFFBB86FC),
                                fontSize: 8, fontWeight: FontWeight.w800)),
                          ]),
                        ),
                      ]),
                      const SizedBox(height: 12),
                      Row(children: [
                        _eventInfoChip('👥', '${ev['guests'] ?? '?'} άτομα'),
                        const SizedBox(width: 8),
                        _eventInfoChip('💰', '${ev['budget'] ?? '?'}€'),
                        if (dateStr.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          _eventInfoChip('📅', dateStr),
                        ],
                      ]),
                      if ((ev['notes'] as String? ?? '').isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(ev['notes'] as String,
                            maxLines: 2, overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: _g(0.45), fontSize: 12, height: 1.4)),
                      ],
                      const SizedBox(height: 12),
                      if (evOffersCount > 0)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text('📩 $evOffersCount ${evOffersCount == 1 ? 'προσφορά' : 'προσφορές'} μέχρι τώρα',
                              style: TextStyle(color: _g(0.35), fontSize: 11)),
                        ),
                      if (evAlreadySubmitted)
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            color: kGreen.withValues(alpha: 0.08),
                            border: Border.all(color: kGreen.withValues(alpha: 0.35)),
                          ),
                          child: const Row(children: [
                            Icon(Icons.check_circle_outline, color: kGreen, size: 14),
                            SizedBox(width: 6),
                            Text('✅ Η προσφορά στάλθηκε!',
                                style: TextStyle(color: kGreen, fontSize: 11, fontWeight: FontWeight.w700)),
                          ]),
                        )
                      else
                        _PremiumButton(
                          label: '💼 Στείλε Προσφορά',
                          gradient: const LinearGradient(
                              colors: [Color(0xFFBB86FC), Color(0xFF7C3AED)]),
                          textColor: Colors.white,
                          fontSize: 13,
                          onTap: () => _showEventOfferDialog(eventId, ev),
                        ),
                    ]),
                  ),
                ]),
              );
            }

            // ── Regular request card ──
            final ri = i - _eventReqDocs.length;
            final d = docs[ri].data() as Map<String, dynamic>;
            final requestId = docs[ri].id;
class _WaitingScreenState extends State<WaitingScreen>
    with TickerProviderStateMixin {
  Timer? _timer;
  int _secondsLeft = 15 * 60;
  int _offersCount = 0;

  @override
  void initState() {
    super.initState();
    _initFromFirestore();
    _listenOffers();
  }

  Future<void> _initFromFirestore() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection(widget.collection)
          .doc(widget.requestId)
          .get();
      if (!mounted) return;
      final data = doc.data();
      if (data != null && data['expiresAt'] != null) {
        final expiresAt = (data['expiresAt'] as Timestamp).toDate();
        final now = DateTime.now();
        final diff = expiresAt.difference(now).inSeconds;
        if (diff <= 0) {
          FirebaseFirestore.instance
              .collection(widget.collection)
              .doc(widget.requestId)
              .update({'status': 'completed'}).catchError((_) {});
          _showOffersReadyDialog();
          return;
        }
  const WaitingScreen(
      {required this.requestId,
      required this.userId,
      required this.description,
      required this.criteria,
      this.profession = '',
      this.collection = 'requests',
      super.key});
  @override
  State<WaitingScreen> createState() => _WaitingScreenState();
}

class _WaitingScreenState extends State<WaitingScreen>
    with TickerProviderStateMixin {
  Timer? _timer;
  int _secondsLeft = 15 * 60;
  int _offersCount = 0;

  @override
  void initState() {
    super.initState();
    _initFromFirestore();
    _listenOffers();
  }

  Future<void> _initFromFirestore() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection(widget.collection)
          .doc(widget.requestId)
          .get();
      if (!mounted) return;
      final data = doc.data();
      if (data != null && data['expiresAt'] != null) {
        final expiresAt = (data['expiresAt'] as Timestamp).toDate();
        final now = DateTime.now();
        final diff = expiresAt.difference(now).inSeconds;
        if (diff <= 0) {
          FirebaseFirestore.instance
              .collection(widget.collection)
              .doc(widget.requestId)
              .update({'status': 'completed'}).catchError((_) {});
          _goToOffers();
          return;
        }
        setState(() => _secondsLeft = diff);
      }
    } catch (_) {}
    _startTimer();
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      if (_secondsLeft <= 0) {
        t.cancel();
        // Mark request as completed so it no longer shows as active on home
        FirebaseFirestore.instance
            .collection(widget.collection)
            .doc(widget.requestId)
            .update({'status': 'completed'}).catchError((_) {});
        _notifyOffersReady();
        _goToOffers();
      } else {
        setState(() => _secondsLeft--);
      }
    });
  }

  void _listenOffers() {
    FirebaseFirestore.instance
        .collection(widget.collection)
        .doc(widget.requestId)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(() => _offersCount = snap.data()?['offersCount'] ?? 0);
    });
  }

  Future<void> _confirmCancel(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            color: const Color(0xFF0D0A04),
            border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('🚫', style: TextStyle(fontSize: 44)),
            const SizedBox(height: 12),
            const Text('Ακύρωση αιτήματος;', style: TextStyle(
                fontFamily: 'Raleway', fontSize: 18,
                fontWeight: FontWeight.w800, color: Colors.white)),
            const SizedBox(height: 8),
            Text('Το αίτημα θα διαγραφεί και οι επαγγελματίες δεν θα μπορούν να στείλουν προσφορά.',
      if (!mounted) return;
      setState(() => _offersCount = snap.data()?['offersCount'] ?? 0);
    });
  }

  Future<void> _confirmCancel(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            color: const Color(0xFF0D0A04),
            border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('🚫', style: TextStyle(fontSize: 44)),
            const SizedBox(height: 12),
        ),
      ),
    );
    if (confirmed == true && mounted) {
      _timer?.cancel();
      final reqRef = FirebaseFirestore.instance.collection(widget.collection).doc(widget.requestId);
      // Read notified pros list before cancelling
      final reqSnap = await reqRef.get();
      final notifiedPros = List<String>.from(reqSnap.data()?['notifiedPros'] ?? []);
      await reqRef.update({'status': 'cancelled'});
      // Remove the new_request notification from each notified professional
      for (final proId in notifiedPros) {
        try {
          final notifSnap = await FirebaseFirestore.instance
              .collection('users').doc(proId)
              .collection('notifications')
              .where('requestId', isEqualTo: widget.requestId)
              .get();
          for (final doc in notifSnap.docs) {
            await doc.reference.delete();
          }
        } catch (_) {}
      }
      if (mounted) Navigator.popUntil(context, (r) => r.isFirst);
    }
  }

  void _goToOffers() {
    if (!mounted) return;
    Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 500),
          pageBuilder: (_, __, ___) => OffersScreen(
              requestId: widget.requestId,
              userId: widget.userId,
              description: widget.description,
              criteria: widget.criteria),
          transitionsBuilder: (_, a, __, c) =>
              FadeTransition(opacity: a, child: c),
        ));
  }

  // Στέλνει push στον χρήστη ότι οι προσφορές είναι έτοιμες
  Future<void> _notifyOffersReady() async {
    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users').doc(widget.userId).get();
      final fcmToken = userDoc.data()?['fcmToken'] as String?;
      if (fcmToken != null && fcmToken.isNotEmpty) {
  }

  void _goToOffers() {
    if (!mounted) return;
    Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 500),
          pageBuilder: (_, __, ___) => OffersScreen(
              requestId: widget.requestId,
              userId: widget.userId,
              description: widget.description,
              criteria: widget.criteria),
          transitionsBuilder: (_, a, __, c) =>
              FadeTransition(opacity: a, child: c),
        ));
  }

  // Στέλνει push στον χρήστη ότι οι προσφορές είναι έτοιμες
  Future<void> _notifyOffersReady() async {
    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users').doc(widget.userId).get();
      final fcmToken = userDoc.data()?['fcmToken'] as String?;
      if (fcmToken != null && fcmToken.isNotEmpty) {
        await http.post(
          Uri.parse('$kBackendUrl/send-push'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'token': fcmToken,
            'title': '🏆 Οι προσφορές σου είναι έτοιμες!',
            'body': 'Το AI επέλεξε τις 3 καλύτερες για σένα. Δες τώρα!',
            'data': {'type': 'offers_ready', 'requestId': widget.requestId},
          }),
        ).timeout(const Duration(seconds: 6));
      }
      // Notification μέσα στην εφαρμογή
      await FirebaseFirestore.instance
          .collection('users').doc(widget.userId)
          .collection('notifications').add({
        'title': '🏆 Οι προσφορές σου είναι έτοιμες!',
        'body': 'Το AI επέλεξε τις 3 καλύτερες. Πάτα εδώ για να δεις!',
        'isRead': false,
        'type': 'offers_ready',
        'requestId': widget.requestId,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('notifyOffersReady error: \$e');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String get _timeStr {
    final m = (_secondsLeft ~/ 60).toString().padLeft(2, '0');
    final s = (_secondsLeft % 60).toString().padLeft(2, '0');
    return '$m:$s';
            child: Row(children: [

  double get _progress => _secondsLeft / (15 * 60);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: Row(children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _g(0.05)),
                    child: const Icon(Icons.arrow_back_ios_new,
                        color: Colors.white, size: 16)),
              ),
              const Spacer(),
              ShaderMask(
                shaderCallback: (b) => const LinearGradient(
                    colors: [kGoldLight, kGold]).createShader(b),
                child: const Text('GOREALAI',
                    style: TextStyle(
                        fontFamily: 'Raleway',
                        fontSize: 13,
                        letterSpacing: 5,
                        fontWeight: FontWeight.w800,
                        color: Colors.white)),
              ),
              const Spacer(),
              Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color: kGreen.withValues(alpha: 0.12)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(width: 5, height: 5,
                        decoration: const BoxDecoration(
                            shape: BoxShape.circle, color: kGreen)),
                    const SizedBox(width: 5),
                    const Text('Ενεργό', style: TextStyle(
                        color: kGreen, fontSize: 9, fontWeight: FontWeight.w700)),
                  ]),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => _confirmCancel(context),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: Colors.red.withValues(alpha: 0.1),
                        border: Border.all(color: Colors.red.withValues(alpha: 0.3))),
                    child: const Text('✕ Ακύρωση', style: TextStyle(
                        color: Colors.red, fontSize: 9, fontWeight: FontWeight.w700)),
                  ),
                ),
              ]),
            ]),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(children: [
                const SizedBox(height: 16),

                // Ring timer
                SizedBox(
                  width: 160,
                  height: 160,
                  child: Stack(alignment: Alignment.center, children: [
                    Container(
                        width: 140,
                        height: 140,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                  color: kGold.withValues(alpha: 0.15),
                                  blurRadius: 40)
                            ])),
                    SizedBox(
                        width: 160,
                        height: 160,
                        child: CustomPaint(
                            painter:
                                _RingPainter(progress: _progress))),
                    Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(_timeStr,
                          style: const TextStyle(
                              fontFamily: 'Raleway',
                              fontSize: 32,
                              fontWeight: FontWeight.w800,
                              color: kGold,
                              letterSpacing: 2)),
                      const SizedBox(height: 2),
                      Text('απομένουν',
                          style: TextStyle(
                              fontSize: 10,
                              color: _g(0.35))),
                    ]),
                  ]),
                ),

                const SizedBox(height: 20),
                const Text('Αίτημα εστάλη! ✅',
                    style: TextStyle(
                        fontFamily: 'Raleway',
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
                const SizedBox(height: 6),
                Text('Οι επαγγελματίες ετοιμάζουν προσφορά...',
                    style: TextStyle(
                        fontSize: 12,
                        color: _g(0.4))),

                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: kGreen.withValues(alpha: 0.1)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                            shape: BoxShape.circle, color: kGreen)),
                    const SizedBox(width: 8),
                    Text('Στάλθηκε · $_offersCount προσφορές',
                        style: const TextStyle(
                            color: kGreen,
                            fontSize: 11,
                            fontWeight: FontWeight.w600)),
                  ]),
                ),

                const SizedBox(height: 28),

                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      color: kGold.withValues(alpha: 0.05)),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text('Το αίτημά σου',
                        style: TextStyle(
                            fontSize: 10,
                            color: _g(0.35),
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Text('"${widget.description}"',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontStyle: FontStyle.italic,
                            height: 1.5)),
                  ]),
                ),

                const SizedBox(height: 20),
                Row(children: [
                  const Text('Ετοιμάζουν προσφορά...',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                  const Spacer(),
                  const Text('Live',
                      style: TextStyle(fontSize: 10, color: kGreen)),
                  const SizedBox(width: 4),
                  Container(
                      width: 5,
                      height: 5,
                      decoration: const BoxDecoration(
                          shape: BoxShape.circle, color: kGreen)),
                ]),
                const SizedBox(height: 10),
                _ProWaitingCard(
                    emoji: '🔍',
                    name: widget.profession.isNotEmpty ? widget.profession : 'Επαγγελματίας',
                    typing: true),
                _ProWaitingCard(
                    emoji: '🔍',
                    name: widget.profession.isNotEmpty ? widget.profession : 'Επαγγελματίας',
                    typing: true),
                _ProWaitingCard(
                    emoji: '🔍',
                    name: widget.profession.isNotEmpty ? widget.profession : 'Επαγγελματίας',
                    typing: false),

                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      color: _g(0.03)),
                  child: Row(children: [
                    const Text('🔔', style: TextStyle(fontSize: 22)),
                    const SizedBox(width: 12),
                    Expanded(
                        child: RichText(
                            text: TextSpan(
                      style: TextStyle(
                          fontSize: 12,
                          color: _g(0.45),
                          height: 1.5),
                      children: const [
                        TextSpan(text: 'Θα λάβεις '),
                        TextSpan(
                            text: 'push notification',
                            style: TextStyle(
                                color: kGold,
                                fontWeight: FontWeight.w600)),
                        TextSpan(text: ' όταν ολοκληρωθεί.'),
                      ],
                    ))),
                  ]),
    );
  }
}

// ── Pro Waiting Card ──
class _ProWaitingCard extends StatefulWidget {
  final String emoji, name;
  final bool typing;
  const _ProWaitingCard(
      {required this.emoji, required this.name, required this.typing});
  @override
  State<_ProWaitingCard> createState() => _ProWaitingCardState();
}

class _ProWaitingCardState extends State<_ProWaitingCard>
                hintStyle: TextStyle(color: _g(0.2), fontSize: 22),
                suffixText: '€',
                suffixStyle: const TextStyle(color: kGold, fontSize: 18),
                filled: true, fillColor: _g(0.05),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: kGold.withValues(alpha: 0.3))),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: kGold.withValues(alpha: 0.3))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: kGold)),
                labelText: 'Τιμή σου',
                labelStyle: const TextStyle(color: kGold, fontSize: 12),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: msgCtrl,
              maxLines: 3,
              style: TextStyle(color: _gw, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Περίγραψε τι περιλαμβάνει η προσφορά σου...',
                hintStyle: TextStyle(color: _g(0.25), fontSize: 12),
                filled: true, fillColor: _g(0.05),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: kGold.withValues(alpha: 0.3))),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: kGold.withValues(alpha: 0.3))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: kGold)),
                labelText: 'Μήνυμα',
                labelStyle: TextStyle(color: _g(0.4), fontSize: 12),
              ),
            ),
            const SizedBox(height: 20),
            Row(children: [
              Expanded(child: GestureDetector(
                onTap: () => Navigator.pop(ctx),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: _g(0.06)),
                  child: const Center(child: Text('Άκυρο',
                      style: TextStyle(color: Colors.white54, fontSize: 13))),
                ),
              )),
              const SizedBox(width: 12),
              Expanded(child: GestureDetector(
                onTap: () async {
                  final price = double.tryParse(priceCtrl.text.trim()) ?? 0;
                  if (price <= 0) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Βάλε τιμή!')));
                    return;
                  }
                  Navigator.pop(ctx);
                  await _submitEventOffer(eventId, eventData, price, msgCtrl.text.trim());
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
  }
}

// Fallback μόνο αν το server δεν απαντά
Future<void> _submitOfferFallback(String requestId, double price,
    String message, String available) async {
  try {
    // Έλεγξε αν υπάρχει ήδη προσφορά από τον ίδιο επαγγελματία
    final existing = await FirebaseFirestore.instance
        .collection('offers')
        .where('requestId', isEqualTo: requestId)
        .where('professionalId', isEqualTo: _proId ?? '')
        .limit(1)
        .get();
Future<void> _submitEventOffer(String eventId, Map<String, dynamic> eventData,
    double price, String message) async {
  try {
    final alreadySubmitted = List<String>.from(eventData['submittedPros'] ?? []);
    if (alreadySubmitted.contains(_proId ?? '')) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('⚠️ Έχεις ήδη στείλει προσφορά!')));
      return;
    }
    // Write offer to event_offers subcollection
    await FirebaseFirestore.instance
        .collection('event_requests').doc(eventId)
        .collection('event_offers').add({
      'eventId': eventId,
      'professionalId': _proId ?? '',
      'professionalName': _proName ?? '',
      'specialty': _proSpecialty ?? '',
      'price': price,
    _timer?.cancel();
    super.dispose();
  }

  String get _timeStr {
    final m = (_secondsLeft ~/ 60).toString().padLeft(2, '0');
    final s = (_secondsLeft % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  double get _progress => _secondsLeft / (15 * 60);

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _secondsLeft > 0,
      child: Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(children: [
      canPop: _secondsLeft > 0,
      child: Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: Row(children: [
              // Back button hidden when offers are ready
              if (_secondsLeft > 0)
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _g(0.05)),
                      child: const Icon(Icons.arrow_back_ios_new,
                          color: Colors.white, size: 16)),
                )
              else
                const SizedBox(width: 38),
              const Spacer(),
              ShaderMask(
                shaderCallback: (b) => const LinearGradient(
                    colors: [kGoldLight, kGold]).createShader(b),
                child: const Text('GOREALAI',
                    style: TextStyle(
                        fontFamily: 'Raleway',
                        fontSize: 13,
                        letterSpacing: 5,
                        fontWeight: FontWeight.w800,
                        color: Colors.white)),
              ),
              const Spacer(),
              Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color: kGreen.withValues(alpha: 0.12)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(width: 5, height: 5,
                        decoration: const BoxDecoration(
                            shape: BoxShape.circle, color: kGreen)),
                    const SizedBox(width: 5),
                    const Text('Ενεργό', style: TextStyle(
                        color: kGreen, fontSize: 9, fontWeight: FontWeight.w700)),
                  ]),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => _confirmCancel(context),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: Colors.red.withValues(alpha: 0.1),
                        border: Border.all(color: Colors.red.withValues(alpha: 0.3))),
                    child: const Text('✕ Ακύρωση', style: TextStyle(
                        color: Colors.red, fontSize: 9, fontWeight: FontWeight.w700)),
                  ),
                ),
              ]),
            ]),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
    
    if (existing.docs.isNotEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
              profession: _selectedProfession ?? '',
            ),
            transitionsBuilder: (_, a, __, c) =>
                FadeTransition(opacity: a, child: c),
          ));
    } catch (e) {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _startStream() {
    setState(() { _loading = true; });
    _prosSub?.cancel();
    _prosSub = FirebaseFirestore.instance
        .collection('professionals')
        .where('is_active', isEqualTo: true)
        .limit(20)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final list = snap.docs.map((d) => {'id': d.id, ...d.data()}).toList();
      list.shuffle();
      setState(() { _pros = list; _loading = false; });
      _startAutoScroll();
    }, onError: (_) {
      if (mounted) setState(() => _loading = false);
    });
  }

  void _stopStream() {
    _prosSub?.cancel();
    _prosSub = null;
  }

  // keep for legacy call sites inside the widget
  Future<void> _loadPros() async {
    _startStream();
  }

  void _startAutoScroll() {
    if (!_scrollCtrl.hasClients || _pros.isEmpty) return;
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted || !_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: Duration(seconds: 4 + _pros.length * 3),
        curve: Curves.linear,
      ).then((_) {
        if (!mounted || !_live) return;
        _scrollCtrl.jumpTo(0);
        _startAutoScroll();
      });
    });
  }

  void _toggleLive(bool v) {
    setState(() => _live = v);
    if (v) {
      _startStream();
    } else {
      _stopStream();
      _autoScrollCtrl.stop();
      setState(() => _pros = []);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Header row
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: Row(children: [
          Expanded(child: Row(children: [
            Text('Επαγγελματίες κοντά σου',
                style: TextStyle(color: _g(0.8), fontSize: 16, fontWeight: FontWeight.w700)),
          ])),
          // Premium OFF/LIVE toggle
          GestureDetector(
            onTap: () => _toggleLive(!_live),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeInOut,
              width: 72, height: 30,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(15),
                gradient: _live
                    ? const LinearGradient(colors: [kGoldLight, kGold, kGoldDark])
                    : null,
                color: _live ? null : Colors.black,
                border: Border.all(
                  color: _live ? kGold.withValues(alpha: 0.6) : _g(0.15),
                  width: _live ? 1 : 0.5,
                ),
                boxShadow: _live ? [
                  BoxShadow(color: kGold.withValues(alpha: 0.4), blurRadius: 10, spreadRadius: 0),
                ] : [],
              ),
              child: Stack(children: [
                AnimatedAlign(
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeInOut,
                  alignment: _live ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    width: 24, height: 24,
                style: TextStyle(color: _g(0.8), fontSize: 16, fontWeight: FontWeight.w700)),
          ])),
          // Premium OFF/LIVE toggle
          GestureDetector(
            onTap: () => _toggleLive(!_live),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeInOut,
              width: 72, height: 30,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(15),
                gradient: _live
                    ? const LinearGradient(colors: [kGoldLight, kGold, kGoldDark])
                    : null,
                color: _live ? null : Colors.black,
                border: Border.all(
                  color: _live ? kGold.withValues(alpha: 0.6) : _g(0.15),
                  width: _live ? 1 : 0.5,
                ),
                boxShadow: _live ? [
                  BoxShadow(color: kGold.withValues(alpha: 0.4), blurRadius: 10, spreadRadius: 0),
                ] : [],
              ),
              child: Stack(children: [
                AnimatedAlign(
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeInOut,
                  alignment: _live ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    width: 24, height: 24,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _live ? Colors.black : _g(0.25),
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 4)],
                    ),
                    child: Center(child: _live
                        ? const Icon(Icons.wifi, color: kGold, size: 12)
                        : Icon(Icons.wifi_off, color: _g(0.4), size: 11)),
                  ),
                ),
                Center(child: AnimatedOpacity(
                  opacity: _live ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: const Padding(
                    padding: EdgeInsets.only(right: 28),
                    child: Text('LIVE', style: TextStyle(
                        color: Colors.black, fontSize: 8,
                        fontWeight: FontWeight.w900, letterSpacing: 0.5)),
                  ),
                )),
                Center(child: AnimatedOpacity(
                  opacity: _live ? 0 : 1,
                  duration: const Duration(milliseconds: 200),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 26),
                    child: Text('OFF', style: TextStyle(
                        color: _g(0.35), fontSize: 8,
                        fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                  ),
                )),
              ]),
            ),
          ),
        ]),
      ),

      // Content
      if (!_live)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Container(
            height: 110,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: LinearGradient(colors: [_g(0.04), _g(0.02)]),
              border: Border.all(color: _g(0.07), width: 0.5),
            ),
            child: Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.location_off_outlined, color: _g(0.25), size: 26),
              const SizedBox(height: 6),
              Text('Ενεργοποίησε το Live για να δεις',
                  style: TextStyle(color: _g(0.3), fontSize: 11)),
              Text('επαγγελματίες κοντά σου',
                  style: TextStyle(color: _g(0.25), fontSize: 10)),
            ])),
          ),
        )
      else if (_loading)
        SizedBox(
          height: 110,
          child: Center(child: SizedBox(
            width: 20, height: 20,
            child: CircularProgressIndicator(color: kGold.withValues(alpha: 0.7), strokeWidth: 2),
          )),
        )
      else if (_pros.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
  }
}

// ── Nearby Pro Card (with photo) ──
class _NearbyProCardState extends State<_NearbyProCard> {
  Uint8List? _photoBytes;

  @override
  void initState() {
    super.initState();
    final url = (widget.pro['profilePhotoUrl'] ?? widget.pro['photo_url'] ?? '') as String;
    if (url.isNotEmpty) _fetchPhoto(url);
  }

  Future<void> _fetchPhoto(String url) async {
    try {
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200 && mounted) setState(() => _photoBytes = res.bodyBytes);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final pro = widget.pro;
    final name = (pro['name'] as String? ?? pro['displayName'] as String? ?? 'Επαγγελματίας');
    final specialty = pro['specialty'] as String? ?? pro['profession'] as String? ?? '';
    final area = pro['area'] as String? ?? '';
    final rating = (pro['rating'] as num?)?.toDouble() ?? 0.0;
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'Π';
    final isOnline = pro['is_active'] == true;

    return Container(
      width: 130,
      margin: const EdgeInsets.only(right: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: _g(0.05),
        border: Border.all(color: _g(0.09), width: 0.5),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 18, offset: const Offset(0, 6)),
        ],
      ),
      child: Column(children: [
        // Photo header (top half)
        ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: SizedBox(
            width: 130, height: 86,
            child: _photoBytes != null
                ? Image.memory(_photoBytes!, fit: BoxFit.cover, width: 130, height: 86)
                : Container(
                    color: kGold.withValues(alpha: 0.07),
                    child: Center(child: Text(
                        initial,
                        style: const TextStyle(color: kGold, fontSize: 34, fontWeight: FontWeight.w800))),
                  ),
          ),
        ),
        // Info bottom
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Column(mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: _gw, fontSize: 11, fontWeight: FontWeight.w700))),
                if (isOnline) Container(
                  width: 7, height: 7,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: kGreen,
                      boxShadow: [BoxShadow(color: kGreen.withValues(alpha: 0.6), blurRadius: 4)]),
                ),
              ]),
              const SizedBox(height: 2),
              Text(specialty, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kGold, fontSize: 9, fontWeight: FontWeight.w600)),
              if (area.isNotEmpty) ...[
                const SizedBox(height: 1),
                Text('📍 $area', maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: _g(0.4), fontSize: 8.5)),
              ],
            ]),
          ),
        ),
  @override
  void initState() {
    super.initState();
    _startListeners();
  }

  void _startListeners() {
    _usersSub = FirebaseFirestore.instance
        .collection('users')
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      _users = snap.docs.length;
      _premium = snap.docs.where((d) => d.data()['isPremium'] == true).length;
      _rebuild();
    }, onError: (_) {});

                      boxShadow: [BoxShadow(color: kGreen.withValues(alpha: 0.6), blurRadius: 4)]),
                ),
              ]),
              const SizedBox(height: 2),
              Text(specialty, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kGold, fontSize: 9, fontWeight: FontWeight.w600)),
              if (area.isNotEmpty) ...[
                const SizedBox(height: 1),
                Text('📍 $area', maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: _g(0.4), fontSize: 8.5)),
              ],
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _letterBox(String initial) => Container(
    color: kGold.withValues(alpha: 0.07),
    child: Center(child: Text(initial,
        style: const TextStyle(color: kGold, fontSize: 34, fontWeight: FontWeight.w800))),
  );
}

// ── Stats Marquee ──
class _StatsMarquee extends StatefulWidget {
  const _StatsMarquee();
  @override
  State<_StatsMarquee> createState() => _StatsMarqueeState();
}

class _StatsMarqueeState extends State<_StatsMarquee> {
  String _marqueeText = '👤 ... Χρήστες   ·   ⭐ ... Premium   ·   🔧 ... Επαγγελματίες   •   ';
  int _users = 0, _premium = 0, _pros = 0;
  StreamSubscription<QuerySnapshot>? _usersSub, _prosSub;

  @override
  void initState() {
    super.initState();
    _startListeners();
  }

  void _startListeners() {
    _usersSub = FirebaseFirestore.instance
        .collection('users')
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      _users = snap.docs.length;
      _premium = snap.docs.where((d) => d.data()['isPremium'] == true).length;
      _rebuild();
                  animation: _pulseScale,
                  builder: (_, __) => Stack(alignment: Alignment.center, children: [
                    Container(
                      width: 10 * _pulseScale.value,
                      height: 10 * _pulseScale.value,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: kGreen.withValues(alpha: (0.4 / _pulseScale.value).clamp(0.0, 1.0)),
                      ),
                    ),
                    Container(
                      width: 10, height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle, color: kGreen,
                        boxShadow: [BoxShadow(color: kGreen.withValues(alpha: 0.8), blurRadius: 6)],
                      ),
                    ),
                  ]),
                )),
            // Name + specialty over photo bottom
            Positioned(bottom: 10, left: 12, right: 12,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800,
                        shadows: [Shadow(blurRadius: 6, color: Colors.black)])),
                Text(specialty, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: kGold, fontSize: 11, fontWeight: FontWeight.w600)),
              ]),
            ),
          ]),
        ),
        // ── Info + CTA ──
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (area.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(children: [
                  Icon(Icons.location_on, color: _g(0.35), size: 11),
                  const SizedBox(width: 2),
                  Expanded(child: Text(area, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: _g(0.4), fontSize: 10))),
                ]),
              ),
            // Stats
            Row(children: [
              _chip('⭐', rating.toStringAsFixed(1)),
              const SizedBox(width: 6),
              _chip('🏆', jobs > 0 ? '$jobs έργα' : 'Νέος'),
              const SizedBox(width: 6),
              _chip('⚡', '~30λ'),
            ]),
            const SizedBox(height: 10),
            // CTA
            GestureDetector(
              onTap: () => _onRequestTap(context),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: const LinearGradient(colors: [kGoldLight, kGold, kGoldDark]),
                  boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.35), blurRadius: 10)],
                ),
                child: const Center(child: Text('Ζήτα Προσφορά 📩',
                    style: TextStyle(color: Colors.black, fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 0.3))),
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _chip(String emoji, String val) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(8),
      color: _g(0.06), border: Border.all(color: _g(0.1), width: 0.5),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Text(emoji, style: const TextStyle(fontSize: 10)),
      const SizedBox(width: 3),
      Text(val, style: TextStyle(color: _g(0.65), fontSize: 10, fontWeight: FontWeight.w600)),
    ]),
  );

  Widget _letterBox(String initial) => Container(
    color: kGold.withValues(alpha: 0.06),
    child: Center(child: Text(initial, style: const TextStyle(color: kGold, fontSize: 40, fontWeight: FontWeight.w800))),
  );

  Future<void> _onRequestTap(BuildContext context) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
      final isPremium = doc.data()?['isPremium'] == true;
      if (!isPremium && context.mounted) { _showPremiumGate(context); return; }
      final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
      final isPremium = doc.data()?['isPremium'] == true;
      if (!isPremium && context.mounted) { _showPremiumGate(context); return; }
    } catch (_) {}
    if (!context.mounted) return;
    Navigator.push(context, PageRouteBuilder(
      pageBuilder: (_, __, ___) => DirectRequestScreen(pro: widget.pro),
      transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
      transitionDuration: const Duration(milliseconds: 350),
  void _showPremiumGate(BuildContext ctx) {
        5,
        Paint()
          ..color = kGoldLight
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
    canvas.drawCircle(Offset(dotX, dotY), 4, Paint()..color = kGoldLight);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.progress != progress;
}

// ═══════════════════════════════════════
// OFFERS SCREEN — Βήμα 3
// ═══════════════════════════════════════
class OffersScreen extends StatefulWidget {
  final String requestId, userId, description, criteria;
  const OffersScreen(
      {required this.requestId,
      required this.userId,
      required this.description,
      required this.criteria,
      super.key});
  @override
  State<OffersScreen> createState() => _OffersScreenState();
}

class _OffersScreenState extends State<OffersScreen>
    with TickerProviderStateMixin {
  List<Map<String, dynamic>> _offers = [];
  bool _loading = true;
  late AnimationController _fadeCtrl;

  static const _demoOffers = [
    {
      'name': 'Νίκος Χρωματιστής',
      'specialty': 'Ελαιοχρωματιστής · 8χρ εμπειρία',
      'rating': 4.9,
      'reviews': 127,
      'price': 120,
      'details': 'Εργασία μόνο · Υλικά δικά σου · 1 μέρα',
      'available': 'Αύριο',
      'distance': '2.1 χλμ',
      'guarantee': true,
      'emoji': '🎨',
      'rank': 1
    },
    {
      'name': 'Σταύρος Βαφέας',
      'specialty': 'Μπογιατζής · 5χρ εμπειρία',
      'rating': 4.7,
      'reviews': 89,
      'price': 150,
      'details': 'Εργασία μόνο · 1 μέρα',
      'available': 'Μεθαύριο',
      'distance': '3.5 χλμ',
      'guarantee': false,
      'emoji': '🖌️',
      'rank': 2
    },
    {
        .collection('users')
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      _users = snap.docs.length;
      _premium = snap.docs.where((d) => d.data()['isPremium'] == true).length;
      _rebuild();
    }, onError: (_) {});

    _prosSub = FirebaseFirestore.instance
        .collection('professionals')
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      _pros = snap.docs.length;
      _rebuild();
    }, onError: (_) {});
  }
        vsync: this, duration: const Duration(milliseconds: 600))
      ..forward();
    _loadOffers();
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadOffers() async {
    // Πρώτα server endpoint για AI filtered
    try {
      final res = await http
          .get(Uri.parse('$kBackendUrl/get-offers/${widget.requestId}'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final offers = (data['offers'] as List?) ?? [];
        if (offers.isNotEmpty) {
          await Future.delayed(const Duration(milliseconds: 800));
          if (mounted) {
            setState(() {
              _offers = offers.cast();
              _loading = false;
            });
            return;
          }
        }
      }
    } catch (_) {}

    // Fallback: Firestore
    await Future.delayed(const Duration(milliseconds: 800));
    try {
      final snap = await FirebaseFirestore.instance
          .collection('offers')
          .where('requestId', isEqualTo: widget.requestId)
          .orderBy('price')
          .limit(3)
          .get();
      if (snap.docs.isNotEmpty) {
  Future<void> _selectOffer(Map<String, dynamic> offer) async {
    // Δημιουργία booking στη Firestore
    try {
      final user = FirebaseAuth.instance.currentUser;
      final userDoc = user != null
          ? await FirebaseFirestore.instance.collection('users').doc(user.uid).get()
          : null;
      final userName = userDoc?.data()?['name'] ?? 'Χρήστης';
      final userPhone = userDoc?.data()?['phone'] ?? '';

      await FirebaseFirestore.instance.collection('bookings').add({
        'userId': user?.uid ?? '',
        'userName': userName,
        'userPhone': userPhone,
        'professionalName': offer['name'] ?? offer['professionalName'] ?? '',
        'professionalId': offer['professionalId'] ?? '',
        'price': offer['price'] ?? 0,
        'requestId': widget.requestId,
        'status': 'pending',
        'isImmediate': true,
        'scheduledTime': 'Άμεσα',
        'createdAt': FieldValue.serverTimestamp(),
      });

      // Admin analytics: καταγράφω κλικ επιλογής
      final proId2 = offer['professionalId'] as String? ?? '';
      final proName2 = (offer['name'] ?? offer['professionalName'] ?? '').toString();
      if (proName2.isNotEmpty) {
        final clickRef = FirebaseFirestore.instance
            .collection('admin_analytics')
            .doc('pro_selections');
        final proKey = proId2.isNotEmpty ? proId2 : proName2;
        await clickRef.set({
          'clicks_$proKey': FieldValue.increment(1),
          'name_$proKey': proName2,
          'lastUpdated': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }

      // Αποθήκευση επιλεγμένου επαγγελματία στο ιστορικό χρήστη
      if (user != null) {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('selectedProfessionals')
            .add({
          'professionalName': offer['name'] ?? offer['professionalName'] ?? '',
          'professionalId': offer['professionalId'] ?? '',
          'specialty': offer['specialty'] ?? '',
          'emoji': offer['emoji'] ?? '🔧',
          'price': offer['price'] ?? 0,
          'message': offer['message'] ?? '',
          'availableFrom': offer['availableFrom'] ?? '',
          'requestDescription': widget.description,
          'requestId': widget.requestId,
          'selectedAt': FieldValue.serverTimestamp(),
        });
      }

      // Ενημέρωση request ως completed
      await FirebaseFirestore.instance
          .collection('requests')
          .doc(widget.requestId)
          .update({'status': 'completed', 'selectedPro': offer['name'] ?? offer['professionalName'] ?? offer['professionalId'] ?? 'selected'});

      // Notification + FCM push στον επαγγελματία
      final proId = offer['professionalId'] as String?;
      if (proId != null && proId.isNotEmpty) {
        await FirebaseFirestore.instance
            .collection('users').doc(proId)
            .collection('notifications').add({
          'title': '🎉 Αποδέχτηκαν την προσφορά σου!',
          'body': '$userName επέλεξε εσένα!',
          'isRead': false,
          'type': 'offer_accepted',
          'userName': userName,
          'userPhone': userPhone,
          'requestId': widget.requestId,
          'createdAt': FieldValue.serverTimestamp(),
        });
        // FCM push
        try {
          final proUserDoc = await FirebaseFirestore.instance
              .collection('users').doc(proId).get();
          final fcmToken = proUserDoc.data()?['fcmToken'] as String?;
          if (fcmToken != null && fcmToken.isNotEmpty) {
            await http.post(
              Uri.parse('$kBackendUrl/send-push'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'token': fcmToken,
                'title': '🎉 Επέλεξαν εσένα!',
                'body': '$userName αποδέχτηκε την προσφορά σου! Τηλ: $userPhone',
                'data': {
                  'type': 'offer_accepted',
                  'requestId': widget.requestId,
                  'userName': userName,
                  'userPhone': userPhone,
                },
              }),
            ).timeout(const Duration(seconds: 6));
          }
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('Booking error: \$e');
    }

    if (!mounted) return;
    // Safe name από offer map
    final proName = (offer['name'] ?? offer['professionalName'] ?? 'τον επαγγελματία').toString();
    final proEmoji = (offer['emoji'] ?? '🔧').toString();
    showDialog(
        context: context,
        builder: (ctx) => Dialog(
              backgroundColor: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    color: const Color(0xFF0D0A04),
                    border: Border.all(color: kGold.withValues(alpha: 0.3))),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(proEmoji, style: const TextStyle(fontSize: 52)),
                  const SizedBox(height: 12),
                  Text('Επέλεξες τον\n$proName!',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontFamily: 'Raleway',
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: Colors.white)),
                  const SizedBox(height: 8),
                  Text('Το booking δημιουργήθηκε!\nΟ επαγγελματίας θα επικοινωνήσει μαζί σου.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 13,
                          color: _g(0.5))),
                  const SizedBox(height: 24),
                  _PremiumButton(
                    label: 'Τέλεια! 🎉',
                    gradient: const LinearGradient(colors: [kGoldLight, kGold]),
                    textColor: Colors.black,
                    onTap: () {
                      Navigator.pop(ctx);
                      Navigator.popUntil(context, (r) => r.isFirst);
                    },
                  ),
                ]),
              ),
            ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: Row(children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _g(0.05)),
                    child: const Icon(Icons.arrow_back_ios_new,
                        color: Colors.white, size: 16)),
              ),
              const Spacer(),
              ShaderMask(
                shaderCallback: (b) => const LinearGradient(
                    colors: [kGoldLight, kGold]).createShader(b),
                child: const Text('GOREALAI',
                    style: TextStyle(
                        fontFamily: 'Raleway',
                        fontSize: 13,
                        letterSpacing: 5,
                        fontWeight: FontWeight.w800,
                        color: Colors.white)),
              ),
              const Spacer(),
              if (!_loading)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color: kGold.withValues(alpha: 0.1)),
                  child: Text('${_offers.length} προσφορές ✦',
                      style: const TextStyle(
                          color: kGold,
                          fontSize: 9,
                          fontWeight: FontWeight.w700)),
                )
              else
                const SizedBox(width: 80),
            ]),
          ),
          Expanded(
            child: _loading
                ? Center(
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                      const SizedBox(
                          width: 48,
                          height: 48,
                          child: CircularProgressIndicator(
                              color: kGold, strokeWidth: 2)),
                      const SizedBox(height: 20),
                      const Text('✦ AI αξιολογεί τις προσφορές...',
                          style: TextStyle(
                              color: kGold,
                              fontSize: 13,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      Text(
                          'Ανάλυση τιμών, αξιολογήσεων, διαθεσιμότητας',
                          style: TextStyle(
                              fontSize: 11,
                              color: _g(0.3))),
                    ]))
                : _offers.isEmpty
                    ? _NoOffersWidget(onRetry: () {
                        Navigator.pop(context);
                      })
                    : FadeTransition(
                    opacity: _fadeCtrl,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                        const SizedBox(height: 4),
                        const Text('Οι καλύτερες\nπροσφορές 🏆',
                            style: TextStyle(
                                fontFamily: 'Raleway',
                                fontSize: 24,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                                height: 1.2)),
                        const SizedBox(height: 4),
                        Text(widget.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 11,
                                color:
                                    _g(0.35))),
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              color: kGold.withValues(alpha: 0.06)),
                          child: Row(children: [
                            const Text('✦',
                                style: TextStyle(
                                    color: kGold, fontSize: 18)),
                            const SizedBox(width: 10),
                            Expanded(
                                child: RichText(
                                    text: TextSpan(
                              style: TextStyle(
                                  fontSize: 11,
                                  color:
                                      _g(0.5),
                                  height: 1.4),
                              children: [
                                const TextSpan(text: 'AI επέλεξε βάσει '),
                                TextSpan(
                                    text: _criteriaLabel(),
                                    style: const TextStyle(
                                        color: kGold,
                                        fontWeight: FontWeight.w600)),
                                TextSpan(
                                    text:
                                        ' από ${_offers.length} προσφορές'),
                              ],
                            ))),
                          ]),
                        ),
                        const SizedBox(height: 16),
                        ..._offers.asMap().entries.map((e) =>
                            _OfferCard(
                              offer: e.value,
                              isBest: e.key == 0,
                              onSelect: () =>
                                  _selectOffer(e.value),
                            )),
                      ]),
                    ),
class _OfferCardState extends State<_OfferCard> {
  Uint8List? _photoBytes;

  String get _name => (widget.offer['name'] ?? widget.offer['professionalName'] ?? 'Επαγγελματίας').toString();
  String get _emoji => (widget.offer['emoji'] ?? '🔧').toString();
  String get _specialty => (widget.offer['specialty'] ?? widget.offer['message'] ?? '').toString();
  double get _price => (widget.offer['price'] is num) ? (widget.offer['price'] as num).toDouble() : 0.0;
  double get _rating => (widget.offer['rating'] is num) ? (widget.offer['rating'] as num).toDouble() : 4.8;
  String get _available => (widget.offer['available'] ?? widget.offer['availableFrom'] ?? 'Σύντομα').toString();
  int get _rank => (widget.offer['rank'] is num) ? (widget.offer['rank'] as num).toInt() : 1;

  @override
  void initState() {
    super.initState();
    final photoUrl = widget.offer['profilePhotoUrl'] as String?;
    if (photoUrl != null && photoUrl.isNotEmpty) {
      _fetchPhoto(photoUrl);
    }
  }

  Future<void> _fetchPhoto(String url) async {
    try {
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200 && mounted) setState(() => _photoBytes = res.bodyBytes);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: widget.isBest
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [kGold.withValues(alpha: 0.1), kGold.withValues(alpha: 0.02)])
              : null,
          color: widget.isBest ? null : _g(0.04),
          border: Border.all(color: widget.isBest
              ? kGold.withValues(alpha: 0.3)
              : _g(0.06)),
        ),
        child: Stack(children: [
          if (widget.isBest)
            Positioned(top: 0, left: 20, right: 20,
                child: Container(height: 1,
                  decoration: const BoxDecoration(gradient: LinearGradient(
                      colors: [Colors.transparent, kGold, Colors.transparent])))),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Align(
                alignment: Alignment.centerRight,
                child: widget.isBest
                    ? Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          gradient: const LinearGradient(colors: [kGoldLight, kGold]),
                          boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.4), blurRadius: 10)],
                        ),
                        child: const Text('🏆 #1 ΚΑΛΥΤΕΡΗ',
                            style: TextStyle(color: Colors.black,
                                fontSize: 9, fontWeight: FontWeight.w800)))
                    : Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8),
                            color: _g(0.06)),
                        child: Text('#$_rank', style: TextStyle(
                            color: _g(0.35),
                            fontSize: 10, fontWeight: FontWeight.w600))),
              ),

              const SizedBox(height: 10),

              Row(children: [
                Container(
                    width: 50, height: 50,
                    decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(15),
                        color: kGold.withValues(alpha: 0.08)),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(15),
                      child: _photoBytes != null
                          ? Image.memory(_photoBytes!, fit: BoxFit.cover)
                          : Center(child: Text(_emoji,
                              style: const TextStyle(fontSize: 26))),
                    )),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_name,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(_specialty,
                      style: TextStyle(
                          color: _g(0.4),
    _startTimer();
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      // Always recalculate from expiresAt if available (survives tab backgrounding)
      final secs = _expiresAt != null
          ? _expiresAt!.difference(DateTime.now()).inSeconds
          : _secondsLeft - 1;
      if (secs <= 0) {
        t.cancel();
        if (!mounted) return;
        setState(() => _secondsLeft = 0);
        // Mark request as completed so it no longer shows as active on home
        FirebaseFirestore.instance
            .collection(widget.collection)
            .doc(widget.requestId)
            .update({'status': 'completed'}).catchError((_) {});
          Text('Αναβάθμισε σε Premium για να στέλνεις αιτήματα απευθείας σε επαγγελματίες της επιλογής σου.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _g(0.5), fontSize: 13, height: 1.5)),
          const SizedBox(height: 20),
          _PremiumButton(
            label: '💳 Αναβάθμιση — 1,99€/μήνα',
            gradient: const LinearGradient(colors: [kGoldLight, kGold, kGoldDark]),
            textColor: Colors.black,
            onTap: () async {
              Navigator.pop(c);
              // Go to ProfileScreen for subscription
              await Navigator.push(ctx, PageRouteBuilder(
                pageBuilder: (_, __, ___) => const ProfileScreen(),
                transitionsBuilder: (_, a, __, c2) => FadeTransition(opacity: a, child: c2),
                transitionDuration: const Duration(milliseconds: 350),
              ));
              // After returning, re-check premium and proceed automatically
              if (!ctx.mounted) return;
              final user = FirebaseAuth.instance.currentUser;
              if (user == null) return;
              try {
                final doc = await FirebaseFirestore.instance
                    .collection('users').doc(user.uid).get();
                if (doc.data()?['isPremium'] == true && onSubscribed != null) {
                  onSubscribed();
                }
              } catch (_) {}
            },
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: () => Navigator.pop(c),
              child: Text('Ίσως αργότερα', style: TextStyle(color: _g(0.35), fontSize: 12))),
        ]),
      ),
    ));
  }
}

// ── Stats Marquee ──
class _StatsMarquee extends StatefulWidget {
  const _StatsMarquee();
  @override
  State<_StatsMarquee> createState() => _StatsMarqueeState();
}

class _StatsMarqueeState extends State<_StatsMarquee> {
  String _marqueeText = '👤 ... Χρήστες   ·   ⭐ ... Premium   ·   🔧 ... Επαγγελματίες   •   ';
  int _users = 0, _premium = 0, _pros = 0;
  StreamSubscription<QuerySnapshot>? _usersSub, _prosSub;

  @override
  void initState() {
    super.initState();
    _startListeners();
  }

  void _startListeners() {
    _usersSub = FirebaseFirestore.instance
        .collection('users')
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      _users = snap.docs.length;
      _premium = snap.docs.where((d) => d.data()['isPremium'] == true).length;
      _rebuild();
    }, onError: (_) {});

    _prosSub = FirebaseFirestore.instance
        .collection('professionals')
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      _pros = snap.docs.length;
      _rebuild();
    }, onError: (_) {});
  }

  void _rebuild() {
    setState(() {
      _marqueeText = '👤 $_users Εγγεγραμμένοι Χρήστες   ·   ⭐ $_premium Premium   ·   🔧 $_pros Επαγγελματίες   •   ';
    });
  }

  @override
  void dispose() {
    _usersSub?.cancel();
    _prosSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _MarqueeBanner(text: _marqueeText);
}

// ═══════════════════════════════════════
// ════════════════════════════════════════════════
// ════════════════════════════════════════════════
// PRO PORTFOLIO UPLOAD SCREEN  (premium — before/after photos)
// ════════════════════════════════════════════════
class ProPortfolioUploadScreen extends StatefulWidget {
  final String proId;
  final String proName;
  const ProPortfolioUploadScreen({super.key, required this.proId, required this.proName});
  @override
  State<ProPortfolioUploadScreen> createState() => _ProPortfolioUploadScreenState();
  final Map<String, Uint8List> _localCache = {}; // url → bytes for immediate display
  final Map<String, String> _captions = {}; // url → caption
  bool _loading = true;
  bool _uploading = false;
  String? _proDocId;

  @override
  void initState() {
    super.initState();
    _loadPhotos();
  }

  Future<void> _loadPhotos() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('professionals')
          .where('userId', isEqualTo: widget.proId)
          .limit(1)
          .get();
      if (!mounted) return;
      if (snap.docs.isNotEmpty) {
        _proDocId = snap.docs.first.id;
        final data = snap.docs.first.data();
        final meta = Map<String, dynamic>.from(data['portfolioPhotosMeta'] ?? {});
        final photos = List<String>.from(data['portfolioPhotos'] ?? []);
        setState(() {
          _photos = photos;
          meta.forEach((k, v) { if (v is String) _captions[k] = v; });
          _loading = false;
        });
        // No prefetch needed — _ProPhotoTile uses Image.network directly
      } else {
        // No pro doc yet — create one linked to this user
        final newRef = FirebaseFirestore.instance.collection('professionals').doc();
        await newRef.set({
          'userId': widget.proId,
          'name': widget.proName,
          'is_active': true,
          'portfolioPhotos': [],
        }, SetOptions(merge: true));
        _proDocId = newRef.id;
        if (mounted) setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickAndUpload() async {
    final picker = ImagePicker();
    final picked = await picker.pickMultiImage(imageQuality: 85);
    if (picked.isEmpty || !mounted) return;
    setState(() => _uploading = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('not_authenticated');
      final idToken = await user.getIdToken();
      const bucket = 'shoppilot-app-e4104.firebasestorage.app';
      final newUrls = <String>[];
      for (final xfile in picked) {
        final bytes = await xfile.readAsBytes();
        final ext = xfile.name.split('.').last.toLowerCase();
        final ct = ext == 'png' ? 'image/png' : 'image/jpeg';
        final ts = DateTime.now().millisecondsSinceEpoch;
        final safeName = xfile.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
        final objectPath = 'professionals/${_proDocId ?? widget.proId}/portfolio/${ts}_$safeName';
        final encodedPath = Uri.encodeComponent(objectPath);
        final resp = await http.post(
          Uri.parse('https://firebasestorage.googleapis.com/v0/b/$bucket/o'
              '?uploadType=media&name=$encodedPath'),
          headers: {'Authorization': 'Firebase $idToken', 'Content-Type': ct},
          body: bytes,
        ).timeout(const Duration(seconds: 120));
        if (resp.statusCode == 200) {
          final j = jsonDecode(resp.body) as Map<String, dynamic>;
          final token = j['downloadTokens'] as String? ?? '';
          final url = token.isNotEmpty
              ? 'https://firebasestorage.googleapis.com/v0/b/$bucket/o/$encodedPath?alt=media&token=$token'
              : 'https://firebasestorage.googleapis.com/v0/b/$bucket/o/$encodedPath?alt=media';
          _localCache[url] = bytes; // cache for immediate display
          newUrls.add(url);
        }
      }
      if (newUrls.isNotEmpty) {
                if (mounted) setState(() { _photos = [..._photos, ...newUrls]; });
        if (_proDocId != null) {
          try {
            await FirebaseFirestore.instance
                .collection('professionals')
                .doc(_proDocId)
                .set({'portfolioPhotos': FieldValue.arrayUnion(newUrls)}, SetOptions(merge: true));
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('⚠️ Αποθήκευση απέτυχε: $e')));
            }
          }
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('⚠️ Αποτυχία ανεβάσματος. Δοκίμασε ξανά.')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Σφάλμα: $e')));
      }
    }
    if (mounted) setState(() => _uploading = false);
  }

  Future<void> _deletePhoto(String url) async {
    if (mounted) setState(() { _photos.remove(url); _captions.remove(url); _localCache.remove(url); });
    if (_proDocId != null) {
      FirebaseFirestore.instance.collection('professionals').doc(_proDocId)
          .update({'portfolioPhotos': FieldValue.arrayRemove([url]),
                   'portfolioPhotosMeta.$url': FieldValue.delete()})
          .catchError((_) {});
    }
    if (mounted) setState(() => _uploading = false);
  }
    if (mounted) setState(() { _photos.remove(url); _captions.remove(url); _localCache.remove(url); });
    if (_proDocId != null) {
      FirebaseFirestore.instance.collection('professionals').doc(_proDocId)
          .update({'portfolioPhotos': FieldValue.arrayRemove([url]),
                   'portfolioPhotosMeta.$url': FieldValue.delete()})
          .catchError((_) {});
    }
  }

  void _editCaption(String url) {
    final ctrl = TextEditingController(text: _captions[url] ?? '');
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF0D0A04),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: kGold.withValues(alpha: 0.3))),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('✏️ Λεζάντα φωτογραφίας',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 16),
            TextField(
              controller: ctrl,
              maxLines: 2,
              style: TextStyle(color: _gw, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'πχ. "Βαφή σαλονιού - Before & After"',
                hintStyle: TextStyle(color: _g(0.3), fontSize: 12),
        // FCM push
        try {
          final proUserDoc = await FirebaseFirestore.instance
              .collection('users').doc(proId).get();
          final fcmToken = proUserDoc.data()?['fcmToken'] as String?;
          if (fcmToken != null && fcmToken.isNotEmpty) {
            await http.post(
              Uri.parse('$kBackendUrl/send-push'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'token': fcmToken,
                'title': '🎉 Επέλεξαν εσένα!',
                .collection('requests')
                .doc(requestDocId)
                .update({'videoUrls': videoUrls, 'hasVideos': true});
            // Wait for _notifyProsDirectly (has 5s internal delay) to finish
            // creating notification docs before we update them with video URLs
            await Future.delayed(const Duration(seconds: 12));
            // Update each pro's notification doc with the actual video URLs
            try {
                  if (_proDocId != null) {
                    FirebaseFirestore.instance.collection('professionals').doc(_proDocId)
                        .update({'portfolioPhotosMeta.$url': caption}).catchError((_) {});
                  }
                  Navigator.pop(ctx);
                },
                child: Container(padding: const EdgeInsets.symmetric(vertical: 11),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(12),
                        gradient: const LinearGradient(colors: [kGoldLight, kGold])),
                    child: const Center(child: Text('Αποθήκευση',
                        style: TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: 13)))),
              )),
            ]),
          ]),
        ),
      ),
    );
  }

  @override
                  }).catchError((_) {});
                }
              }
            } catch (_) {}
          }
        }  // end video upload block
      }

      // Analytics
      _analytics.logEvent(name: 'submit_request', parameters: {
        'profession': _selectedProfession ?? '',
        'has_images': _images.isNotEmpty ? 'true' : 'false',
      });

      // ── 4. Notify pros in background (5s delay overwrites backend duplicates) ──
      final _notifRequestId = docRef.id;
      final _notifDesc = _textCtrl.text.trim();
      final _notifProf = _selectedProfession ?? '';
      final _notifLoc = _selectedLocation ?? '';
      final _notifUser = widget.userName;
      final _notifImgCount = _images.length;
      Future(() => _notifyProsDirectly(_notifRequestId, _notifDesc,
          _notifProf, _notifLoc, _notifUser, _notifImgCount,
          hasVideos: videoData.isNotEmpty));

      if (!mounted) return;
      Navigator.pushReplacement(
          context,
          PageRouteBuilder(
            transitionDuration: const Duration(milliseconds: 400),
            pageBuilder: (_, __, ___) => WaitingScreen(
              requestId: docRef.id,
              userId: widget.userId,
              description: _textCtrl.text.trim(),
              criteria: _selectedCriteria,
              profession: _selectedProfession ?? '',
            ),
            transitionsBuilder: (_, a, __, c) =>
                FadeTransition(opacity: a, child: c),
          ));
    } catch (e) {
      _submitLock = false;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Σφάλμα: $e')));
    }
  }
Future<void> _notifyProsDirectly(
    String requestId,
    String description,
    String profession,
    String location,
                            style: TextStyle(color: _g(0.35), fontSize: 14)),
                        const SizedBox(height: 8),
                        Text('Πάτα «Προσθήκη» για να ξεκινήσεις',
                            style: TextStyle(color: _g(0.25), fontSize: 12)),
                      ]))
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2, crossAxisSpacing: 10, mainAxisSpacing: 10,
                          childAspectRatio: 1.0,
                        ),
                        itemCount: _photos.length,
                        itemBuilder: (_, i) => _ProPhotoTile(
                          url: _photos[i],
                          bytes: _localCache[_photos[i]],
                          caption: _captions[_photos[i]],
                          onDelete: () => _deletePhoto(_photos[i]),
                          onEditCaption: () => _editCaption(_photos[i]),
                          onTap: () => _openFullscreen(i),
                        ),
                      ),
              ),
            ]),
    );
  }

  void _openFullscreen(int startIndex) {
    Navigator.push(context, PageRouteBuilder(
      pageBuilder: (_, __, ___) => _FullscreenPhotoViewer(
          photos: _photos,
          bytesCache: Map.from(_localCache),
          startIndex: startIndex),
      transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
    ));
  }
}
class _ProPhotoTile extends StatelessWidget {
  final String url;
  final Uint8List? bytes;
  final String? caption;
  final VoidCallback onDelete;
  final VoidCallback onEditCaption;
  final VoidCallback onTap;
  const _ProPhotoTile({required this.url, this.bytes, this.caption,
      required this.onDelete, required this.onEditCaption, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Column(children: [
      Expanded(child: Stack(fit: StackFit.expand, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: bytes != null
              ? Image.memory(bytes!, fit: BoxFit.cover)
              : Image.network(
                  url,
class _ProPhotoTile extends StatefulWidget {
  final String url;
  final Uint8List? initialBytes;
  final String? caption;
  final VoidCallback onDelete;
  final VoidCallback onEditCaption;
  final VoidCallback onTap;
  const _ProPhotoTile({required this.url, Uint8List? bytes, this.caption,
      required this.onDelete, required this.onEditCaption, required this.onTap})
      : initialBytes = bytes;

  @override
  State<_ProPhotoTile> createState() => _ProPhotoTileState();
}

class _ProPhotoTileState extends State<_ProPhotoTile> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    if (widget.initialBytes != null) {
      _bytes = widget.initialBytes;
    } else {
      _fetchBytes();
    }
  }

  @override
  void didUpdateWidget(_ProPhotoTile old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _bytes = widget.initialBytes;
      if (_bytes == null) _fetchBytes();
    } else if (widget.initialBytes != null && _bytes == null) {
      setState(() => _bytes = widget.initialBytes);
    }
  }

  Future<void> _fetchBytes() async {
    try {
      final res = await http.get(Uri.parse(widget.url)).timeout(const Duration(seconds: 15));
      if (res.statusCode == 200 && mounted) setState(() => _bytes = res.bodyBytes);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: widget.onTap,
    child: Column(children: [
      Expanded(child: Stack(fit: StackFit.expand, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: _bytes != null
              ? Image.memory(_bytes!, fit: BoxFit.cover)
              : Container(
                  decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      color: _g(0.06)),
                  child: const Center(
                    child: CircularProgressIndicator(
                        color: kGold, strokeWidth: 2))),
        ),
        Positioned(
          top: 5, right: 5,
          child: GestureDetector(
            onTap: widget.onDelete,
            child: Container(width: 24, height: 24,
              decoration: BoxDecoration(shape: BoxShape.circle,
                  color: Colors.black.withValues(alpha: 0.65)),
              child: const Icon(Icons.close, color: Colors.white70, size: 13)),
          ),
        ),
      ])),
      // Caption row
      GestureDetector(
        onTap: widget.onEditCaption,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),

class _FullscreenPhotoViewerState extends State<_FullscreenPhotoViewer> {
  late PageController _pageCtrl;
  late int _current;
  final Map<String, Uint8List> _cache = {};

  @override
  void initState() {
    super.initState();
    _current = widget.startIndex;
    _pageCtrl = PageController(initialPage: widget.startIndex);
    _cache.addAll(widget.bytesCache);
    // Fetch any missing bytes
    for (final url in widget.photos) {
      if (!_cache.containsKey(url)) _fetchBytes(url);
    }
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchBytes(String url) async {
    try {
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
      if (res.statusCode == 200 && mounted) setState(() => _cache[url] = res.bodyBytes);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        PageView.builder(
          controller: _pageCtrl,
          itemCount: widget.photos.length,
          onPageChanged: (i) => setState(() => _current = i),
          itemBuilder: (_, i) {
            final url = widget.photos[i];
            final bytes = _cache[url];
            return InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: Center(
                child: bytes != null
                    ? Image.memory(bytes, fit: BoxFit.contain)
                    : Image.network(url, fit: BoxFit.contain,
                        loadingBuilder: (_, child, progress) => progress == null
                            ? child
                            : const Center(child: CircularProgressIndicator(color: kGold)),
                        errorBuilder: (_, __, ___) => const Center(
                            child: Icon(Icons.broken_image_outlined, color: Colors.white24, size: 48))),
              ),
            );
          },
        ),
        // Close button
        SafeArea(child: Padding(
          padding: const EdgeInsets.all(12),
          child: GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withValues(alpha: 0.6)),
              child: const Icon(Icons.close, color: Colors.white, size: 18)),
          ),
        )),
        // Page indicator
        if (widget.photos.length > 1)
          Positioned(
            bottom: 32, left: 0, right: 0,
            child: Row(mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(widget.photos.length, (i) => AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: i == _current ? 16 : 6, height: 6,
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    color: i == _current ? kGold : Colors.white24),
              )),
            ),
          ),
      ]),
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _startListener() {
    _sub = FirebaseFirestore.instance
        .collection('professionals')
        .doc(_proDocId)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      if (snap.exists) {
        final data = snap.data() as Map<String, dynamic>;
        final meta = Map<String, dynamic>.from(data['portfolioPhotosMeta'] ?? {});
        final photos = List<String>.from(data['portfolioPhotos'] ?? []);
        setState(() {
          _photos = photos;
          _captions.clear();
          meta.forEach((k, v) { if (v is String) _captions[k] = v; });
          _loading = false;
        });
          _captions.clear();
          meta.forEach((k, v) { if (v is String) _captions[k] = v; });
          _loading = false;
        });
        // Pre-fetch bytes for any photos not already cached
        for (final url in photos) {
          if (!_localCache.containsKey(url)) {
            http.get(Uri.parse(url)).timeout(const Duration(seconds: 15)).then((res) {
              if (res.statusCode == 200 && mounted) {
                setState(() => _localCache[url] = res.bodyBytes);
              }
            }).catchError((_) {});
          }
        }
      } else {
        // Doc doesn't exist yet (e.g. old account pre-migration) — create it
        FirebaseFirestore.instance
            .collection('professionals')
            .doc(_proDocId)
            .set({
          'userId': widget.proId,
          'name': widget.proName,
          'is_active': true,
          'portfolioPhotos': [],
        }, SetOptions(merge: true));
        if (mounted) setState(() => _loading = false);
      }
    }, onError: (_) {
      if (mounted) setState(() => _loading = false);
    });
  }

  Future<void> _pickAndUpload() async {
    final picker = ImagePicker();
    final picked = await picker.pickMultiImage(imageQuality: 85);
    if (picked.isEmpty || !mounted) return;
    setState(() => _uploading = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('not_authenticated');
      final idToken = await user.getIdToken();
      const bucket = 'shoppilot-app-e4104.firebasestorage.app';
      final newUrls = <String>[];
      for (final xfile in picked) {
        final bytes = await xfile.readAsBytes();
        final ext = xfile.name.split('.').last.toLowerCase();
        final ct = ext == 'png' ? 'image/png' : 'image/jpeg';
        final ts = DateTime.now().millisecondsSinceEpoch;
        final safeName = xfile.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
        final objectPath = 'professionals/$_proDocId/portfolio/${ts}_$safeName';
        final encodedPath = Uri.encodeComponent(objectPath);
        final resp = await http.post(
          Uri.parse('https://firebasestorage.googleapis.com/v0/b/$bucket/o'
              '?uploadType=media&name=$encodedPath'),
          headers: {'Authorization': 'Firebase $idToken', 'Content-Type': ct},
          body: bytes,
        ).timeout(const Duration(seconds: 120));
        if (resp.statusCode == 200) {
          final j = jsonDecode(resp.body) as Map<String, dynamic>;
          final token = j['downloadTokens'] as String? ?? '';
          final url = token.isNotEmpty
              ? 'https://firebasestorage.googleapis.com/v0/b/$bucket/o/$encodedPath?alt=media&token=$token'
              : 'https://firebasestorage.googleapis.com/v0/b/$bucket/o/$encodedPath?alt=media';
          _localCache[url] = bytes; // cache for immediate display
          newUrls.add(url);
        }
      }
      if (newUrls.isNotEmpty) {
        if (mounted) setState(() { _photos = [..._photos, ...newUrls]; });
        try {
          await FirebaseFirestore.instance
              .collection('professionals')
              .doc(_proDocId)
              .update({'portfolioPhotos': FieldValue.arrayUnion(newUrls)});
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('⚠️ Αποθήκευση απέτυχε: $e')));
          }
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('⚠️ Αποτυχία ανεβάσματος. Δοκίμασε ξανά.')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Σφάλμα: $e')));
      }
    }
    if (mounted) setState(() => _uploading = false);
  }

  Future<void> _deletePhoto(String url) async {
    if (mounted) setState(() { _photos.remove(url); _captions.remove(url); _localCache.remove(url); });
    FirebaseFirestore.instance.collection('professionals').doc(_proDocId)
        .update({'portfolioPhotos': FieldValue.arrayRemove([url]),
                 'portfolioPhotosMeta.$url': FieldValue.delete()})
        .catchError((_) {});
  }

  void _editCaption(String url) {
    final ctrl = TextEditingController(text: _captions[url] ?? '');
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF0D0A04),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: kGold.withValues(alpha: 0.3))),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('✏️ Λεζάντα φωτογραφίας',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 16),
            TextField(
              controller: ctrl,
              maxLines: 2,
              style: TextStyle(color: _gw, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'πχ. "Βαφή σαλονιού - Before & After"',
                hintStyle: TextStyle(color: _g(0.3), fontSize: 12),
                filled: true, fillColor: _g(0.05),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: kGold.withValues(alpha: 0.3))),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: kGold.withValues(alpha: 0.3))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: kGold)),
              ),
            ),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(child: GestureDetector(
                onTap: () => Navigator.pop(ctx),
                child: Container(padding: const EdgeInsets.symmetric(vertical: 11),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: _g(0.06)),
                    child: const Center(child: Text('Άκυρο', style: TextStyle(color: Colors.white54, fontSize: 13)))),
              )),
              const SizedBox(width: 10),
              Expanded(child: GestureDetector(
                onTap: () {
                  final caption = ctrl.text.trim();
                  if (mounted) setState(() => _captions[url] = caption);
                  FirebaseFirestore.instance.collection('professionals').doc(_proDocId)
                      .update({'portfolioPhotosMeta.$url': caption}).catchError((_) {});
                  Navigator.pop(ctx);
                },
                child: Container(padding: const EdgeInsets.symmetric(vertical: 11),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(12),
                        gradient: const LinearGradient(colors: [kGoldLight, kGold])),
                    child: const Center(child: Text('Αποθήκευση',
                        style: TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: 13)))),
              )),
            ]),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kBg,
      child: _loading
          ? const Center(child: CircularProgressIndicator(color: kGold))
          : Column(children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(children: [
                  ShaderMask(
                    shaderCallback: (b) => const LinearGradient(
                        colors: [kGoldLight, kGold]).createShader(b),
                    child: const Text('📸 Portfolio μου',
                        style: TextStyle(fontFamily: 'Raleway', fontSize: 18,
                            fontWeight: FontWeight.w800, color: Colors.white)),
                  ),
                  const Spacer(),
                  _uploading
                      ? const SizedBox(width: 24, height: 24,
                          child: CircularProgressIndicator(color: kGold, strokeWidth: 2))
                      : GestureDetector(
                          onTap: _pickAndUpload,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              gradient: const LinearGradient(colors: [kGoldLight, kGold]),
                              boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.3), blurRadius: 8)],
                            ),
                            child: const Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.add_photo_alternate_outlined, color: Colors.black, size: 16),
                              SizedBox(width: 6),
                              Text('Προσθήκη', style: TextStyle(color: Colors.black,
                                  fontSize: 12, fontWeight: FontWeight.w800)),
                            ]),
                          ),
                        ),
                ]),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final name = pro['name'] as String? ?? pro['displayName'] as String? ?? 'Επαγγελματίας';
    final specialty = pro['specialty'] as String? ?? '';
    final area = pro['area'] as String? ?? '';
    final avatarUrl = pro['photoUrl'] as String? ?? pro['avatarUrl'] as String?;
    final photos = List<String>.from(pro['portfolioPhotos'] ?? []);
    final coverPhoto = photos.isNotEmpty ? photos.first : null;

    return GestureDetector(
      onTap: () => _openGallery(context),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: const Color(0xFF0E0B04),
          border: Border.all(color: kGold.withValues(alpha: 0.2)),
          boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.06), blurRadius: 12)],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Cover photo area
          Expanded(child: Stack(children: [
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
              child: coverPhoto != null
                  ? Image.network(coverPhoto, fit: BoxFit.cover,
                      width: double.infinity, height: double.infinity,
                      errorBuilder: (_, __, ___) => _defaultCover())
                  : _defaultCover(),
            ),
            // Pro avatar top-left
            Positioned(top: 8, left: 8,
              child: Container(
                width: 32, height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: kGold, width: 1.5),
                  color: kBg,
                ),
                child: ClipOval(child: avatarUrl != null
                    ? Image.network(avatarUrl, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _avatarFallback(name))
                    : _avatarFallback(name)),
              ),
            ),
            // Photo count badge
            if (photos.length > 1)
              Positioned(top: 8, right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('${photos.length} 📷',
                      style: const TextStyle(color: Colors.white, fontSize: 9)),
                ),
              ),
          ])),
          // Info
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(specialty.isNotEmpty ? specialty : name,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 11,
                      fontWeight: FontWeight.w700)),
              if (area.isNotEmpty)
                Text(area, maxLines: 1,
                    style: TextStyle(color: _g(0.45), fontSize: 10)),
              const SizedBox(height: 6),
              Container(
          child: bytes != null
              ? Image.memory(bytes!, fit: BoxFit.cover)
              : Image.network(
                  url,
                  fit: BoxFit.cover,
                  loadingBuilder: (_, child, progress) => progress == null
                      ? child
                          onDelete: () => _deletePhoto(_photos[i]),
                          onEditCaption: () => _editCaption(_photos[i]),
                          onTap: () => _openFullscreen(i),
                        ),
                      ),
              ),
            ]),
    );
  }

  void _openFullscreen(int startIndex) {
    Navigator.push(context, PageRouteBuilder(
      pageBuilder: (_, __, ___) => _FullscreenPhotoViewer(
          photos: _photos,
          bytesCache: _localCache,
          startIndex: startIndex),
      transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
    ));
  }
}

class _ProPhotoTile extends StatelessWidget {
  final String url;
  final Uint8List? bytes;
  final String? caption;
  final VoidCallback onDelete;
  final VoidCallback onEditCaption;
  final VoidCallback onTap;
  const _ProPhotoTile({required this.url, this.bytes, this.caption,
      required this.onDelete, required this.onEditCaption, required this.onTap});

  @override

  @override
  Widget build(BuildContext context) {
    final name = pro['name'] as String? ?? pro['displayName'] as String? ?? 'Επαγγελματίας';
    final specialty = pro['specialty'] as String? ?? '';
    final area = pro['area'] as String? ?? '';
    final avatarUrl = pro['photoUrl'] as String? ?? pro['avatarUrl'] as String?;

    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Row(children: [
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(width: 38, height: 38,
                decoration: BoxDecoration(shape: BoxShape.circle,
                    color: _g(0.06), border: Border.all(color: _g(0.12))),
                child: const Icon(Icons.arrow_back_ios_new, color: Colors.white70, size: 16)),
            ),
            const SizedBox(width: 12),
          top: 5, right: 5,
          child: GestureDetector(
            onTap: onDelete,
            child: Container(width: 24, height: 24,
class _FullscreenPhotoViewer extends StatefulWidget {
  final List<String> photos;
  final Map<String, Uint8List> bytesCache;
  final int startIndex;
  const _FullscreenPhotoViewer(
      {required this.photos, Map<String, Uint8List>? bytesCache, required this.startIndex})
      : bytesCache = bytesCache ?? const {};
  @override
  State<_FullscreenPhotoViewer> createState() => _FullscreenPhotoViewerState();
}

class _FullscreenPhotoViewerState extends State<_FullscreenPhotoViewer> {
  late PageController _pageCtrl;
  late int _current;

  @override
  void initState() {
    super.initState();
    _current = widget.startIndex;
    _pageCtrl = PageController(initialPage: widget.startIndex);
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        PageView.builder(
          controller: _pageCtrl,
          itemCount: widget.photos.length,
          onPageChanged: (i) => setState(() => _current = i),
          itemBuilder: (_, i) {
            final url = widget.photos[i];
            final bytes = widget.bytesCache[url];
            return InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: Center(
                child: bytes != null
                    ? Image.memory(bytes, fit: BoxFit.contain)
                    : Image.network(url, fit: BoxFit.contain,
                        loadingBuilder: (_, child, progress) => progress == null
                            ? child
                            : const Center(child: CircularProgressIndicator(color: kGold)),
                        errorBuilder: (_, __, ___) => const Center(
                            child: Icon(Icons.broken_image_outlined, color: Colors.white24, size: 48))),
              ),
            );
          },
        ),
        // Close button
        SafeArea(child: Padding(
          padding: const EdgeInsets.all(12),
          child: GestureDetector(
      final docRef = await FirebaseFirestore.instance
          .collection('requests')
          .add({
        'userId': authUid,
        'userName': widget.userName,
        'description': _textCtrl.text.trim(),
        'criteria': _selectedCriteria,
        'immediate': _wantsImmediate,
        'minRating': _minRating,
        'withPhotos': _wantsWithPhotos,
        'profession': _selectedProfession ?? '',
        'location': _selectedLocation ?? '',
        'status': 'active',
        'offersCount': 0,
        'createdAt': FieldValue.serverTimestamp(),
        'expiresAt': Timestamp.fromDate(
            DateTime.now().add(const Duration(minutes: 15))),
        'imageCount': _images.length,
      });

      // ── 1. Read ALL bytes before navigation (XFile blob URLs expire after widget disposal on web) ──
      List<String> imageBase64 = [];
      for (final img in _images) {
          }
        } catch (e) {
          debugPrint('Video readAsBytes() error: $e');
        }
      }

      // ── 2. Save images to Firestore ──
      if (imageBase64.isNotEmpty) {
        await FirebaseFirestore.instance
class ProPortfolioScreen extends StatefulWidget {
  final Map<String, dynamic> pro;
  const ProPortfolioScreen({super.key, required this.pro});
  @override
  State<ProPortfolioScreen> createState() => _ProPortfolioScreenState();
}

class _ProPortfolioScreenState extends State<ProPortfolioScreen> {
  Uint8List? _photoBytes;

  @override
  void initState() {
    super.initState();
    final url = (widget.pro['profilePhotoUrl'] ?? widget.pro['photo_url'] ?? '') as String;
    if (url.isNotEmpty) {
      http.get(Uri.parse(url)).timeout(const Duration(seconds: 10)).then((res) {
        if (res.statusCode == 200 && mounted) setState(() => _photoBytes = res.bodyBytes);
      }).catchError((_) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final pro = widget.pro;
    final name = (pro['name'] ?? pro['displayName'] ?? 'Επαγγελματίας') as String;
    final specialty = (pro['specialty'] ?? pro['profession'] ?? '') as String;
    final area = (pro['area'] ?? '') as String;
    final bio = (pro['bio'] ?? pro['description'] ?? '') as String;
    final isVerified = pro['verified'] == true;
    final isOnline = pro['is_active'] == true;
    final rating = ((pro['rating'] ?? pro['average_rating'] ?? 4.8) as num).toDouble();
    final jobs = ((pro['jobs_count'] ?? pro['completed_jobs'] ?? 0) as num).toInt();
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'Π';
    final portfolioPhotos = (pro['portfolioPhotos'] ?? pro['photos'] ?? []) as List;

    return Scaffold(
      backgroundColor: kBg,
      body: CustomScrollView(
        slivers: [
          // ── Header photo ──
          SliverAppBar(
            expandedHeight: 240,
            pinned: true,
            backgroundColor: kBg,
            leading: GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withValues(alpha: 0.5),
                ),
                child: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 16),
              ),
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(fit: StackFit.expand, children: [
                _photoBytes != null
                    ? Image.memory(_photoBytes!, fit: BoxFit.cover)
                    : Container(
                        color: kGold.withValues(alpha: 0.06),
                        child: Center(child: Text(initial,
                            style: const TextStyle(color: kGold, fontSize: 72, fontWeight: FontWeight.w800))),
                      ),
                // gradient overlay
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter, end: Alignment.bottomCenter,
                      stops: [0.5, 1.0],
                      colors: [Colors.transparent, kBg],
                    ),
                  ),
                ),
                // Badges
                Positioned(bottom: 16, left: 16, right: 16,
                  child: Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Flexible(child: Text(name,
                            style: const TextStyle(color: Colors.white, fontSize: 22,
                                fontWeight: FontWeight.w800, shadows: [Shadow(blurRadius: 8, color: Colors.black)]))),
                        if (isVerified) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), color: kGold),
                            child: const Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.verified_rounded, color: Colors.black, size: 10),
                              SizedBox(width: 2),
                              Text('Verified', style: TextStyle(color: Colors.black, fontSize: 9, fontWeight: FontWeight.w900)),
                            ]),
                          ),
                        ],
                      ]),
                      Text(specialty, style: const TextStyle(color: kGold, fontSize: 13, fontWeight: FontWeight.w600)),
                    ])),
                    if (isOnline)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          color: kGreen.withValues(alpha: 0.15),
                          border: Border.all(color: kGreen.withValues(alpha: 0.5)),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Container(width: 7, height: 7,
                              decoration: const BoxDecoration(shape: BoxShape.circle, color: kGreen)),
                          const SizedBox(width: 5),
                          const Text('Online', style: TextStyle(color: kGreen, fontSize: 11, fontWeight: FontWeight.w700)),
                        ]),
                      ),
                  ]),
                ),
              ]),
            ),
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Stats row
                Row(children: [
                  _statPill('⭐', rating.toStringAsFixed(1), 'Βαθμολογία'),
                  const SizedBox(width: 10),
                  _statPill('🏆', jobs > 0 ? '$jobs' : 'Νέος', 'Έργα'),
                  const SizedBox(width: 10),
                  _statPill('⚡', '~30λ', 'Απόκριση'),
                ]),
                if (area.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Row(children: [
                    Icon(Icons.location_on, color: _g(0.35), size: 13),
                    const SizedBox(width: 4),
                    Text(area, style: TextStyle(color: _g(0.45), fontSize: 12)),
                  ]),
                ],
                if (bio.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('Σχετικά', style: TextStyle(color: _g(0.5), fontSize: 11,
                      fontWeight: FontWeight.w700, letterSpacing: 0.8)),
                  const SizedBox(height: 6),
                  Text(bio, style: TextStyle(color: _g(0.7), fontSize: 13, height: 1.6)),
                ],
                // Portfolio photos
                if (portfolioPhotos.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text('Πορτφόλιο', style: TextStyle(color: _g(0.5), fontSize: 11,
                      fontWeight: FontWeight.w700, letterSpacing: 0.8)),
                  const SizedBox(height: 10),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2, crossAxisSpacing: 8, mainAxisSpacing: 8,
                        childAspectRatio: 1.1),
                    itemCount: portfolioPhotos.length,
                    itemBuilder: (_, i) {
                      final url = portfolioPhotos[i] as String? ?? '';
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: url.isNotEmpty
                            ? Image.network(url, fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Container(
                                    color: _g(0.06),
                                    child: Icon(Icons.image_outlined, color: _g(0.2), size: 30)))
                            : Container(color: _g(0.06)),
                      );
                    },
                  ),
                ],
              ]),
            ),
          ),
        ],
      ),
      // ── Bottom CTA ──
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: GestureDetector(
            onTap: () {
              Navigator.push(context, PageRouteBuilder(
                pageBuilder: (_, __, ___) => DirectRequestScreen(pro: widget.pro),
                transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
                transitionDuration: const Duration(milliseconds: 350),
              ));
            },
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: const LinearGradient(colors: [kGoldLight, kGold, kGoldDark]),
                boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.4), blurRadius: 16)],
              ),
              child: const Center(child: Text('Ζήτα Προσφορά 📩',
                  style: TextStyle(color: Colors.black, fontSize: 15,
                      fontWeight: FontWeight.w900, letterSpacing: 0.5))),
            ),
          ),
        ),
      ),
    );
  }

  Widget _statPill(String emoji, String value, String label) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: _g(0.05),
        border: Border.all(color: _g(0.09)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(emoji, style: const TextStyle(fontSize: 16)),
        const SizedBox(height: 3),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 14,
            fontWeight: FontWeight.w800, fontFamily: 'Raleway')),
        Text(label, style: TextStyle(color: _g(0.35), fontSize: 9)),
      ]),
    ),
  );
}

// ════════════════════════════════════════════════
// DIRECT REQUEST SCREEN — User sends request to specific pro
// ════════════════════════════════════════════════
class DirectRequestScreen extends StatefulWidget {
  final Map<String, dynamic> pro;
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: _g(0.05),
        border: Border.all(color: _g(0.09)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(emoji, style: const TextStyle(fontSize: 16)),
        const SizedBox(height: 3),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 14,
            fontWeight: FontWeight.w800, fontFamily: 'Raleway')),
    super.initState();
    final url = (widget.pro['profilePhotoUrl'] ?? widget.pro['photo_url'] ?? '') as String;
    if (url.isNotEmpty) {
      http.get(Uri.parse(url)).timeout(const Duration(seconds: 10)).then((res) {
        if (res.statusCode == 200 && mounted) setState(() => _photoBytes = res.bodyBytes);
      }).catchError((_) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final pro = widget.pro;
    final name = (pro['name'] ?? pro['displayName'] ?? 'Επαγγελματίας') as String;
    final specialty = (pro['specialty'] ?? pro['profession'] ?? '') as String;
    final area = (pro['area'] ?? '') as String;
    final bio = (pro['bio'] ?? pro['description'] ?? '') as String;
    final isVerified = pro['verified'] == true;
    final isOnline = pro['is_active'] == true;
    final rating = ((pro['rating'] ?? pro['average_rating'] ?? 4.8) as num).toDouble();
    final jobs = ((pro['jobs_count'] ?? pro['completed_jobs'] ?? 0) as num).toInt();
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'Π';
    final portfolioProjects = ((pro['portfolioProjects'] as List?) ?? [])
        .map((p) => Map<String, dynamic>.from(p as Map)).toList();
    // Fallback: old flat photos
    final legacyPhotos = (pro['portfolioPhotos'] ?? pro['photos'] ?? []) as List;

    return Scaffold(
      backgroundColor: kBg,
      body: Column(
        children: [
          // ── Header ──────────────────────────────────────────
          SizedBox(
            height: 220,
            child: Stack(fit: StackFit.expand, children: [
              // Photo or placeholder
              _photoBytes != null
                  ? Image.memory(_photoBytes!, fit: BoxFit.cover)
                  : Container(
                      color: const Color(0xFF1A1500),
                      child: Center(child: Text(initial,
                          style: const TextStyle(color: kGold, fontSize: 80,
                              fontWeight: FontWeight.w800))),
                    ),
              // gradient bottom
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter, end: Alignment.bottomCenter,
                    stops: [0.4, 1.0],
                    colors: [Colors.transparent, kBg],
                  ),
                ),
              ),
              // Back button
              Positioned(
                top: MediaQuery.of(context).padding.top + 8,
                left: 12,
                child: GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withValues(alpha: 0.55),
                    ),
                    child: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 16),
                  ),
                ),
              ),
              // Online badge
              if (isOnline)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 10,
                  right: 14,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      color: kGreen.withValues(alpha: 0.18),
                      border: Border.all(color: kGreen.withValues(alpha: 0.6)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(width: 7, height: 7,
                          decoration: const BoxDecoration(shape: BoxShape.circle, color: kGreen)),
                      const SizedBox(width: 5),
                      const Text('Online', style: TextStyle(color: kGreen, fontSize: 11, fontWeight: FontWeight.w700)),
                    ]),
                  ),
                ),
              // Name + specialty bottom
              Positioned(
                bottom: 12, left: 16, right: 16,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(child: Text(name,
                        style: const TextStyle(color: Colors.white, fontSize: 22,
                            fontWeight: FontWeight.w800,
                            shadows: [Shadow(blurRadius: 10, color: Colors.black)]))),
                    if (isVerified) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), color: kGold),
                        child: const Text('✓ Verified',
                            style: TextStyle(color: Colors.black, fontSize: 9, fontWeight: FontWeight.w900)),
                      ),
                    ],
                  ]),
                  if (specialty.isNotEmpty)
                    Text(specialty, style: const TextStyle(color: kGold, fontSize: 13, fontWeight: FontWeight.w600)),
                ]),
              ),
            ]),
          ),

          // ── Scrollable content ───────────────────────────────
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Stats row — glass pills
                Row(children: [
                  _statPill('⭐', rating.toStringAsFixed(1), 'Βαθμολογία'),
                  const SizedBox(width: 8),
                  _statPill('🏆', jobs > 0 ? '$jobs' : 'Νέος', 'Έργα'),
                  const SizedBox(width: 8),
                  _statPill('⚡', '~30λ', 'Απόκριση'),
                ]),
                if (area.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Row(children: [
                    Icon(Icons.location_on_outlined, color: kGold.withValues(alpha: 0.6), size: 13),
                    const SizedBox(width: 4),
                    Text(area, style: TextStyle(color: _g(0.45), fontSize: 12)),
                  ]),
                ],
                // Mini CV / Bio
                if (bio.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Row(children: [
                    Container(width: 3, height: 16,
                        decoration: BoxDecoration(borderRadius: BorderRadius.circular(2),
                            gradient: const LinearGradient(
                                begin: Alignment.topCenter, end: Alignment.bottomCenter,
                                colors: [kGoldLight, kGold]))),
                    const SizedBox(width: 8),
                    const Text('MINI CV', style: TextStyle(color: kGold, fontSize: 11,
                        fontWeight: FontWeight.w800, letterSpacing: 1.2)),
                  ]),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      color: _g(0.04),
                      border: Border.all(color: kGold.withValues(alpha: 0.12)),
                    ),
                    child: Text(bio, style: TextStyle(color: _g(0.75), fontSize: 13, height: 1.65)),
                  ),
                ],
                // Portfolio
                const SizedBox(height: 20),
                Row(children: [
                  Container(width: 3, height: 16,
                      decoration: BoxDecoration(borderRadius: BorderRadius.circular(2),
                          gradient: const LinearGradient(
                              begin: Alignment.topCenter, end: Alignment.bottomCenter,
                              colors: [kGoldLight, kGold]))),
                  const SizedBox(width: 8),
                  const Text('PORTFOLIO', style: TextStyle(color: kGold, fontSize: 11,
                      fontWeight: FontWeight.w800, letterSpacing: 1.2)),
                ]),
                const SizedBox(height: 12),
                if (portfolioProjects.isEmpty && legacyPhotos.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(14),
                        color: _g(0.04), border: Border.all(color: _g(0.08))),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Text('📷', style: TextStyle(fontSize: 28)),
                      const SizedBox(height: 8),
                      Text('Δεν υπάρχουν φωτογραφίες ακόμα',
                          style: TextStyle(color: _g(0.3), fontSize: 12)),
                    ]),
                  )
                else if (portfolioProjects.isNotEmpty)
                  ...portfolioProjects.map((proj) {
                    final projTitle = proj['title'] as String? ?? '';
                    final projPhotos = List<String>.from(proj['photos'] ?? []);
                    if (projPhotos.isEmpty) return const SizedBox.shrink();
                    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      // Project title
                      Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          color: kGold.withValues(alpha: 0.08),
                          border: Border.all(color: kGold.withValues(alpha: 0.2)),
                        ),
                        child: Row(children: [
                          const Text('📁', style: TextStyle(fontSize: 13)),
                          const SizedBox(width: 7),
                          Expanded(child: Text(projTitle,
                              style: const TextStyle(color: Colors.white, fontSize: 13,
                                  fontWeight: FontWeight.w700))),
                          Text('${projPhotos.length} φωτ.',
                              style: TextStyle(color: _g(0.35), fontSize: 10)),
                        ]),
                      ),
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3, crossAxisSpacing: 5, mainAxisSpacing: 5,
                            childAspectRatio: 1.0),
                        itemCount: projPhotos.length,
                        itemBuilder: (_, i) {
                          final url = projPhotos[i];
                          return GestureDetector(
                            onTap: () => Navigator.push(context, PageRouteBuilder(
                              pageBuilder: (_, __, ___) => _FullscreenPhotoViewer(
                                  photos: projPhotos, startIndex: i),
                              transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
                            )),
                            child: ClipRRect(borderRadius: BorderRadius.circular(10),
                              child: Image.network(url, fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => Container(color: _g(0.06),
                                      child: Icon(Icons.image_outlined, color: _g(0.2))))),
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                    ]);
                  })
                else
                  // Legacy flat photos
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3, crossAxisSpacing: 5, mainAxisSpacing: 5,
                        childAspectRatio: 1.0),
                    itemCount: legacyPhotos.length,
                    itemBuilder: (_, i) {
                      final url = legacyPhotos[i] as String? ?? '';
                      return GestureDetector(
                        onTap: () => Navigator.push(context, PageRouteBuilder(
                          pageBuilder: (_, __, ___) => _FullscreenPhotoViewer(
                              photos: legacyPhotos.map((e) => e as String).toList(), startIndex: i),
                          transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
                        )),
                        child: ClipRRect(borderRadius: BorderRadius.circular(10),
                          child: Image.network(url, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(color: _g(0.06)))),
                      );
                    },
                  ),
              ]),
            ),
          ),

          // ── CTA ─────────────────────────────────────────────
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: GestureDetector(
                onTap: () => Navigator.push(context, PageRouteBuilder(
                  pageBuilder: (_, __, ___) => DirectRequestScreen(pro: widget.pro),
                  transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
                  transitionDuration: const Duration(milliseconds: 350),
                )),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    gradient: const LinearGradient(colors: [kGoldLight, kGold, kGoldDark]),
                    boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.4), blurRadius: 16)],
                  ),
                  child: const Center(child: Text('Ζήτα Προσφορά 📩',
                      style: TextStyle(color: Colors.black, fontSize: 15,
// MISSING LINE 8250
// MISSING LINE 8251
// MISSING LINE 8252
// MISSING LINE 8253
// MISSING LINE 8254
// MISSING LINE 8255
// MISSING LINE 8256
// MISSING LINE 8257
// MISSING LINE 8258
// MISSING LINE 8259
                  animation: _pulseScale,
                  builder: (_, __) => Stack(alignment: Alignment.center, children: [
                    Container(
                      width: 8 * _pulseScale.value, height: 8 * _pulseScale.value,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: kGreen.withValues(alpha: (0.4 / _pulseScale.value).clamp(0.0, 1.0)),
                      ),
                    ),
                    Container(width: 8, height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle, color: kGreen,
                        boxShadow: [BoxShadow(color: kGreen.withValues(alpha: 0.9), blurRadius: 5)],
                      ),
                    ),
                  ]),
                )),
            // ── Stats (bottom) ──
            Positioned(bottom: 8, left: 8, right: 8,
              child: Column(children: [
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  _chip('⭐', rating.toStringAsFixed(1)),
                  const SizedBox(width: 4),
                  _chip('🏆', jobs > 0 ? '$jobs' : 'Νέος'),
                  const SizedBox(width: 4),
                  _chip('⚡', '~30λ'),
                ]),
// REQUEST HISTORY SCREEN
// ═══════════════════════════════════════
class RequestHistoryScreen extends StatelessWidget {
                  .limit(30)
                  .snapshots(),
              builder: (context, snap) {
                if (!snap.hasData)
                  return const Center(
                      child: CircularProgressIndicator(color: kGold));
                final rawDocs = snap.data!.docs.toList()
                  ..sort((a, b) {
                    int getMs(dynamic doc) {
                      try {
                        final data = doc.data() as Map<String, dynamic>;
                        final ts = data['selectedAt'];
                        if (ts == null) return 0;
                        return (ts as Timestamp).toDate().millisecondsSinceEpoch;
                      } catch (_) { return 0; }
                    }
                    return getMs(b).compareTo(getMs(a));
                  });
                final docs = rawDocs;
                if (docs.isEmpty) {
                  return Center(
                      child:
                          Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.person_outline,
                        color: _g(0.15),
                        size: 52),
                    const SizedBox(height: 12),
                    Text('Δεν έχεις επιλέξει επαγγελματία ακόμα',
                        style: TextStyle(
                            color: _g(0.3),
                            fontSize: 14)),
                  ]));
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                  itemCount: docs.length,
                  itemBuilder: (_, i) {
                    final d = docs[i].data() as Map<String, dynamic>;
                    final proName = d['professionalName'] as String? ?? '';
                    final specialty = d['specialty'] as String? ?? '';
                    final emoji = d['emoji'] as String? ?? '🔧';
                    final price = d['price'];
                    final priceStr = price != null ? '${price}€' : '';
                    final requestDesc = d['requestDescription'] as String? ?? '';
                    final ts = d['selectedAt'] as Timestamp?;
                    final date = ts != null ? ts.toDate() : DateTime.now();
                    final dateStr = '${date.day}/${date.month}/${date.year}';

                    return Dismissible(
                      key: Key(docs[i].id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          color: Colors.red.withValues(alpha: 0.15),
                        ),
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        child: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 22),
                      ),
                      confirmDismiss: (_) async {
                        return await showDialog<bool>(
                          context: context,
                          builder: (_) => AlertDialog(
                            backgroundColor: const Color(0xFF1A1A1A),
                            title: Text('Διαγραφή;', style: TextStyle(color: _gw, fontSize: 16)),
                            content: Text('Να διαγραφεί η επιλογή "$proName";',
                                style: TextStyle(color: _g(0.6), fontSize: 13)),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(context, false),
                                  child: Text('Άκυρο', style: TextStyle(color: _g(0.5)))),
                              TextButton(onPressed: () => Navigator.pop(context, true),
                                  child: const Text('Διαγραφή', style: TextStyle(color: Colors.redAccent))),
                            ],
                          ),
                        ) ?? false;
                      },
                      onDismissed: (_) => docs[i].reference.delete(),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(14),
                        decoration: _glassCard(radius: 16, gold: true),
                        child: Row(children: [
                          Container(
                              width: 44, height: 44,
                              decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  color: kGold.withValues(alpha: 0.1)),
                              child: Center(child: Text(emoji,
                                  style: const TextStyle(fontSize: 22)))),
                          const SizedBox(width: 12),
                          Expanded(child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(proName,
                                maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: _gw,
                                    fontSize: 14, fontWeight: FontWeight.w700)),
                            if (specialty.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(specialty,
                                  style: TextStyle(fontSize: 11,
                                      color: kGold.withValues(alpha: 0.8),
                                      fontWeight: FontWeight.w600)),
                            ],
                            const SizedBox(height: 3),
                            Text(requestDesc,
                                maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11, color: _g(0.45))),
                  const SizedBox(height: 24),
                  _PremiumButton(
                    label: 'Τέλεια! 🎉',
                    gradient: const LinearGradient(colors: [kGoldLight, kGold]),
                    textColor: Colors.black,
                    onTap: () {
                      // Signal HomeScreen to clear stale active requests
                      offerSelectedNotifier.value++;
                      Navigator.pop(ctx); // close the confirmation dialog
                      // Pop everything back to root (HomeScreen is already
                      // alive beneath OffersReadyScreen/OffersScreen).
                      // No new HomeScreen mount → _checkUnviewedOffers won't re-run.
                      Navigator.of(context).popUntil((route) => route.isFirst);
                    },
                  ),
                ]),
              ),
            ));
  }

// MISSING LINE 8420
// MISSING LINE 8421
// MISSING LINE 8422
// MISSING LINE 8423
// MISSING LINE 8424
// MISSING LINE 8425
// MISSING LINE 8426
// MISSING LINE 8427
// MISSING LINE 8428
// MISSING LINE 8429
// MISSING LINE 8430
// MISSING LINE 8431
// MISSING LINE 8432
// MISSING LINE 8433
// MISSING LINE 8434
// MISSING LINE 8435
// MISSING LINE 8436
// MISSING LINE 8437
// MISSING LINE 8438
// MISSING LINE 8439
// MISSING LINE 8440
// MISSING LINE 8441
// MISSING LINE 8442
// MISSING LINE 8443
// MISSING LINE 8444
// MISSING LINE 8445
// MISSING LINE 8446
// MISSING LINE 8447
// MISSING LINE 8448
// MISSING LINE 8449
// MISSING LINE 8450
// MISSING LINE 8451
// MISSING LINE 8452
// MISSING LINE 8453
// MISSING LINE 8454
// MISSING LINE 8455
// MISSING LINE 8456
// MISSING LINE 8457
                  ),
                ],
                // Reviews section
                const SizedBox(height: 20),
                Row(children: [
                  Container(width: 3, height: 16,
                      decoration: BoxDecoration(borderRadius: BorderRadius.circular(2),
                          gradient: const LinearGradient(
                              begin: Alignment.topCenter, end: Alignment.bottomCenter,
                              colors: [kGoldLight, kGold]))),
                  const SizedBox(width: 8),
                  const Text('ΑΞΙΟΛΟΓΗΣΕΙΣ', style: TextStyle(color: kGold, fontSize: 11,
                      fontWeight: FontWeight.w800, letterSpacing: 1.2)),
                ]),
                const SizedBox(height: 10),
                StreamBuilder<QuerySnapshot>(
                  stream: (pro['id'] ?? pro['uid'] ?? '').toString().isEmpty
                      ? const Stream.empty()
                      : FirebaseFirestore.instance
                          .collection('reviews')
                          .where('proId', isEqualTo: (pro['id'] ?? pro['uid'] ?? '').toString())
                          .limit(5)
                          .snapshots(),
                  builder: (ctx, revSnap) {
                    if (!revSnap.hasData) {
                      return Container(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        decoration: BoxDecoration(borderRadius: BorderRadius.circular(14),
                            color: _g(0.04), border: Border.all(color: _g(0.08))),
                        child: Center(child: Text('Δεν υπάρχουν αξιολογήσεις ακόμα',
                            style: TextStyle(color: _g(0.3), fontSize: 12))),
                      );
                    }
                    final revDocs = revSnap.data!.docs;
                    if (revDocs.isEmpty) {
                      return Container(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        decoration: BoxDecoration(borderRadius: BorderRadius.circular(14),
                            color: _g(0.04), border: Border.all(color: _g(0.08))),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          const Text('⭐', style: TextStyle(fontSize: 24)),
                          const SizedBox(height: 6),
                          Text('Δεν υπάρχουν αξιολογήσεις ακόμα',
                              style: TextStyle(color: _g(0.3), fontSize: 12)),
                        ]),
                      );
                    }
                    return Column(children: revDocs.map((rd) {
                      final rv = rd.data() as Map<String, dynamic>;
                      final rvRating = (rv['rating'] as int?) ?? 5;
                      final rvComment = (rv['comment'] as String?) ?? '';
                      final rvTs = rv['createdAt'] as Timestamp?;
                      final rvDate = rvTs != null ? rvTs.toDate() : DateTime.now();
                      final rvDateStr = '${rvDate.day}/${rvDate.month}/${rvDate.year}';
                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          color: _g(0.04),
                          border: Border.all(color: kGold.withValues(alpha: 0.1)),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            ...List.generate(5, (si) => Icon(
                              si < rvRating ? Icons.star_rounded : Icons.star_outline_rounded,
                              color: si < rvRating ? kGold : _g(0.2), size: 14,
                            )),
                            const Spacer(),
                            Text(rvDateStr, style: TextStyle(color: _g(0.3), fontSize: 10)),
                          ]),
                          if (rvComment.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(rvComment, style: TextStyle(color: _g(0.65), fontSize: 12, height: 1.5)),
                          ],
      'guarantee': true,
      'emoji': '🎨',
      'rank': 1
    },
    {
      'name': 'Σταύρος Βαφέας',
      'specialty': 'Μπογιατζής · 5χρ εμπειρία',
      'rating': 4.7,
      'reviews': 89,
      'price': 150,
      'details': 'Εργασία μόνο · 1 μέρα',
      'available': 'Μεθαύριο',
      'distance': '3.5 χλμ',
      'guarantee': false,
      'emoji': '🖌️',
      'rank': 2
    },
    {
      'name': 'Δημήτρης Χρωματίζω',
      'specialty': 'Ελαιοχρωματιστής · 12χρ εμπειρία',
      'rating': 4.8,
      'reviews': 203,
      'price': 180,
      'details': 'Εργασία + υλικά · 1.5 μέρα',
      'available': 'Αύριο',
      'distance': '5.0 χλμ',
      'guarantee': true,
      'emoji': '👨‍🎨',
      'rank': 3
    },
  ];

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600))
      ..forward();
    _loadOffers();
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadOffers() async {
    // Πρώτα server endpoint για AI filtered
    try {
      final res = await http
          .get(Uri.parse('$kBackendUrl/get-offers/${widget.requestId}'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final offers = (data['offers'] as List?) ?? [];
        if (offers.isNotEmpty) {
          await Future.delayed(const Duration(milliseconds: 800));
          if (mounted) {
            setState(() {
              _offers = offers.cast();
              _loading = false;
            });
            return;
          }
        }
      }
    } catch (_) {}

    // Fallback: Firestore
    await Future.delayed(const Duration(milliseconds: 800));
    try {
      final snap = await FirebaseFirestore.instance
          .collection('offers')
          .where('requestId', isEqualTo: widget.requestId)
          .orderBy('price')
          .limit(3)
          .get();
      if (snap.docs.isNotEmpty) {
        if (mounted) {
          setState(() {
            _offers = snap.docs.map((d) => d.data()).toList();
            _loading = false;
          });
          return;
        }
      }
    } catch (_) {}

    // Demo
    if (mounted) {
      setState(() {
        _offers = List.from(_demoOffers);
        _loading = false;
      });
    }
  }

  String _criteriaLabel() {
    if (widget.criteria == 'cheap') return 'χαμηλότερης τιμής';
    if (widget.criteria == 'value') return 'καλύτερου value for money';
    return 'ταχύτερης διαθεσιμότητας';
  }

  Future<void> _selectOffer(Map<String, dynamic> offer) async {
    try {
      // ── Step 1: Resolve professionalId FIRST (may be missing from server response) ──
      String proId = ((offer['professionalId'] as String?) ?? '').trim();
      if (proId.isEmpty) {
        try {
          // Fetch all offers for this request from Firestore and match by name
          final proName = (offer['name'] ?? offer['professionalName'] ?? '').toString();
          final offerSnap = await FirebaseFirestore.instance
              .collection('offers')
              .where('requestId', isEqualTo: widget.requestId)
              .limit(10)
              .get();
          for (final doc in offerSnap.docs) {
            final d = doc.data();
            final storedName = (d['professionalName'] ?? d['name'] ?? '').toString();
            if (storedName == proName) {
              proId = (d['professionalId'] as String? ?? '').trim();
              if (proId.isNotEmpty) break;
            }
          }
          // Last resort: take the first offer's proId
          if (proId.isEmpty && offerSnap.docs.isNotEmpty) {
        return;
      }
    }
    setState(() => _sending = true);
    try {
      // Χρησιμοποιούμε πάντα το τρέχον auth uid (ασφαλέστερο από widget.userId)
      final authUid = user?.uid ?? widget.userId;
      final docRef = await FirebaseFirestore.instance
          .collection('requests')
          .add({
        'userId': authUid,
        'userName': widget.userName,
        'description': _textCtrl.text.trim(),
        'criteria': _selectedCriteria,
        'immediate': _wantsImmediate,
        'minRating': _minRating,
        'withPhotos': _wantsWithPhotos,
        'profession': _selectedProfession ?? '',
        'location': _selectedLocation ?? '',
        'status': 'active',
    try {
      // ── Step 1: Resolve professionalId FIRST (may be missing from server response) ──
      String proId = ((offer['professionalId'] as String?) ?? '').trim();
      if (proId.isEmpty) {
        try {
          // Fetch all offers for this request from Firestore and match by name
          final proName = (offer['name'] ?? offer['professionalName'] ?? '').toString();
          final offerSnap = await FirebaseFirestore.instance
              .collection('offers')
              .where('requestId', isEqualTo: widget.requestId)
              .limit(10)
              .get();
          for (final doc in offerSnap.docs) {
            final d = doc.data();
            final storedName = (d['professionalName'] ?? d['name'] ?? '').toString();
            if (storedName == proName) {
              proId = (d['professionalId'] as String? ?? '').trim();
              if (proId.isNotEmpty) break;
            }
          }
          // Last resort: take the first offer's proId
          if (proId.isEmpty && offerSnap.docs.isNotEmpty) {
            proId = (offerSnap.docs.first.data()['professionalId'] as String? ?? '').trim();
          }
        } catch (_) {}
      }

      // ── Step 2: User info ──
      final user = FirebaseAuth.instance.currentUser;
      final userDoc = user != null
          ? await FirebaseFirestore.instance.collection('users').doc(user.uid).get()
          : null;
      final userName = userDoc?.data()?['name'] ?? 'Χρήστης';
class DirectRequestScreen extends StatefulWidget {
  final Map<String, dynamic> pro;
  const DirectRequestScreen({super.key, required this.pro});
  @override
  State<DirectRequestScreen> createState() => _DirectRequestScreenState();
}

class _DirectRequestScreenState extends State<DirectRequestScreen> {
  final _msgCtrl = TextEditingController();
  final List<Uint8List> _photos = [];
  bool _sending = false;

  @override
  void dispose() {
    _msgCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    try {
      final picker = ImagePicker();
      final xf = await picker.pickImage(source: ImageSource.gallery, imageQuality: 75);
      if (xf == null) return;
      final bytes = await xf.readAsBytes();
      if (mounted) setState(() => _photos.add(bytes));
    } catch (_) {}
  }

  Future<void> _send() async {
    final msg = _msgCtrl.text.trim();
    if (msg.isEmpty && _photos.isEmpty) return;
    setState(() => _sending = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final userDoc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
      final userName = userDoc.data()?['name'] ?? 'Χρήστης';
      final userPhone = userDoc.data()?['phone'] ?? '';

      final pro = widget.pro;
      final proId = (pro['id'] ?? pro['uid'] ?? '') as String;
      final proName = (pro['name'] ?? pro['displayName'] ?? 'Επαγγελματίας') as String;
      final proPhotoUrl = (pro['profilePhotoUrl'] ?? pro['photo_url'] ?? '') as String;

      // Upload photos to Storage
      final List<String> photoUrls = [];
      for (int i = 0; i < _photos.length; i++) {
        try {
          final ref = FirebaseStorage.instance
              .ref('direct_requests/${user.uid}/${DateTime.now().millisecondsSinceEpoch}_$i.jpg');
          await ref.putData(_photos[i], SettableMetadata(contentType: 'image/jpeg'));
          final url = await ref.getDownloadURL();
          photoUrls.add(url);
        } catch (_) {}
      }

      // Create direct_request doc
      final docRef = await FirebaseFirestore.instance.collection('direct_requests').add({
        'userId': user.uid,
        'proId': proId,
        'userName': userName,
        'userPhone': userPhone,
        'proName': proName,
        'proPhotoUrl': proPhotoUrl,
        'message': msg,
        'photoUrls': photoUrls,
        'status': 'pending',
        'offer': null,
        'createdAt': FieldValue.serverTimestamp(),
      });

      // Notify professional
      if (proId.isNotEmpty) {
        await FirebaseFirestore.instance
            .collection('users').doc(proId)
            .collection('notifications').add({
          'title': '📩 Νέο αίτημα από $userName',
          'body': msg.isNotEmpty ? msg : '${photoUrls.length} φωτογραφίες',
          'type': 'direct_request',
          'directRequestId': docRef.id,
          'userId': user.uid,
          'userName': userName,
          'userPhone': userPhone,
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Το αίτημά σου στάλθηκε!'), backgroundColor: Colors.green),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Σφάλμα: $e'), backgroundColor: Colors.red),

// ════════════════════════════════════════════════
// PORTFOLIO GALLERY SCREEN  (G button — 1.99€/μήνα συνδρομή)
// ════════════════════════════════════════════════
class PortfolioGalleryScreen extends StatefulWidget {
  }

  @override
  Widget build(BuildContext context) {
    final pro = widget.pro;
    final name = (pro['name'] ?? pro['displayName'] ?? 'Επαγγελματίας') as String;
    final specialty = (pro['specialty'] ?? pro['profession'] ?? '') as String;
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(child: Column(children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
          child: Row(children: [
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(width: 38, height: 38,
                decoration: BoxDecoration(shape: BoxShape.circle, color: _g(0.06)),
                          fontFamily: 'Raleway',
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: Colors.white)),
                  const SizedBox(height: 8),
                  Text('Το booking δημιουργήθηκε!\nΟ επαγγελματίας θα επικοινωνήσει μαζί σου.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 13,
                          color: _g(0.5))),
                  const SizedBox(height: 24),
                  _PremiumButton(
                    label: 'Τέλεια! 🎉',
                    gradient: const LinearGradient(colors: [kGoldLight, kGold]),
                    textColor: Colors.black,
                    onTap: () {
                      Navigator.pop(ctx); // close the confirmation dialog
                      // Pop OffersScreen → back to HomeScreen (overlay still mounted)
                      Navigator.of(context).pop();
                      // Clear the overlay and signal HomeScreen to refresh
                      offersReadyNotifier.value = null;
                      offerSelectedNotifier.value++;
                    },
                  ),
                ]),
              ),
            ));
      setState(() {
        _offers = List.from(_demoOffers);
        _loading = false;
      });
    }
  }

  String _criteriaLabel() {
    if (widget.criteria == 'cheap') return 'χαμηλότερης τιμής';
    if (widget.criteria == 'value') return 'καλύτερου value for money';
    return 'ταχύτερης διαθεσιμότητας';
  }

  Future<void> _selectOffer(Map<String, dynamic> offer) async {
    try {
      // ── Step 1: Resolve professionalId FIRST (may be missing from server response) ──
  Future<void> _submit() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    setState(() => _submitting = true);
    try {
      final cat = _categories.firstWhere((c) => c['id'] == _categoryId);
      await FirebaseFirestore.instance.collection('event_requests').add({
        'userId': user.uid,
        'category': _categoryId,
        'categoryTitle': cat['title'],
        'categoryEmoji': cat['emoji'],
        'location': _selectedArea ?? _locationCtrl.text.trim(),
        'guests': _guests,
        'budget': _budget.round(),
        'date': _date?.toIso8601String() ?? '',
        'notes': _notesCtrl.text.trim(),
        'status': 'active',
        'offers': [],
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) setState(() { _submitting = false; _step = 2; });
    } catch (_) {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          transitionBuilder: (child, anim) => SlideTransition(
            position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
                .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
            child: FadeTransition(opacity: anim, child: child),
          ),
          child: _step == 0 ? _buildCategoryPicker()
              : _step == 1 ? _buildDetailsForm()
              : _buildSuccess(),
        ),
      ),
    );
  }

  // ── Step 0: Category Picker ─────────────────────
  Widget _buildCategoryPicker() {
    return Column(key: const ValueKey(0), children: [
      // Header
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        child: Row(children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(shape: BoxShape.circle, color: _g(0.07)),
              child: Icon(Icons.close, color: _g(0.6), size: 18)),
          ),
        ]),
      ),
      const SizedBox(height: 24),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ShaderMask(
            shaderCallback: (b) => const LinearGradient(colors: [kGoldLight, kGold]).createShader(b),
            child: const Text('Τι οργανώνεις;',
          child: Column(children: _categories.map((cat) {
            return GestureDetector(
              onTap: () {
                setState(() {
                  _categoryId = cat['id'] as String;
                  _categoryTitle = cat['title'] as String;
                  _categoryEmoji = cat['emoji'] as String;
                  _step = 1;
                });
              },
              child: Container(
                margin: const EdgeInsets.only(bottom: 14),
                          style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700))),
                      _statusBadge(status),
                    ]),
                    const SizedBox(height: 6),
                  border: Border.all(color: kGold.withValues(alpha: 0.18)),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 12)],
                ),
                child: Row(children: [
                  Container(
                    width: 60, height: 60,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(colors: [
                        kGold.withValues(alpha: 0.18), kGold.withValues(alpha: 0.04)]),
                            kGold.withValues(alpha: 0.1), kGold.withValues(alpha: 0.04)]),
                          border: Border.all(color: kGold.withValues(alpha: 0.3)),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('💼 Προσφορά: ${offer['price']}€',
                              style: const TextStyle(color: kGold, fontSize: 14, fontWeight: FontWeight.w800)),
                          if ((offer['message'] as String? ?? '').isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(offer['message'] as String,
                                style: TextStyle(color: _g(0.6), fontSize: 12, height: 1.4)),
                          ],
                          const SizedBox(height: 12),
                          Row(children: [
                            Expanded(child: GestureDetector(
                              onTap: () => _acceptOffer(context, docId, d),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(10),
                                  color: kGreen.withValues(alpha: 0.15),
                                  border: Border.all(color: kGreen.withValues(alpha: 0.4)),
                                ),
                                child: const Center(child: Text('✅ Αποδοχή',
                                    style: TextStyle(color: kGreen, fontSize: 12, fontWeight: FontWeight.w700))),
                              ),
                            )),
                            const SizedBox(width: 8),
                            Expanded(child: GestureDetector(
                              onTap: () => _rejectOffer(docId),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(10),
                                  color: Colors.red.withValues(alpha: 0.1),
                                  border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                                ),
                                child: const Center(child: Text('❌ Απόρριψη',
                                    style: TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.w700))),
                              ),
                            )),
                          ]),
                        ]),
                      ),
                    ],
                  ]),
                );
              },
            );
          },
        )),
      ])),
    );
  }

  Widget _statusBadge(String status) {
    Color c; String label;
    switch (status) {
      case 'replied': c = kGold; label = '💬 Απάντηση'; break;
      case 'accepted': c = kGreen; label = '✅ Αποδέχτηκες'; break;
      case 'rejected': c = Colors.red; label = '❌ Απορρίφθηκε'; break;
      default: c = Colors.blueAccent; label = '⏳ Αναμονή';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: c.withValues(alpha: 0.12),
        border: Border.all(color: c.withValues(alpha: 0.35)),
      ),
      child: Text(label, style: TextStyle(color: c, fontSize: 10, fontWeight: FontWeight.w700)),
    );
  }

  Future<void> _acceptOffer(BuildContext context, String docId, Map<String, dynamic> d) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final offer = d['offer'] as Map<String, dynamic>;
      final proId = d['proId'] as String? ?? '';

      await FirebaseFirestore.instance.collection('direct_requests').doc(docId).update({'status': 'accepted'});
      await FirebaseFirestore.instance.collection('bookings').add({
        'userId': user.uid,
        'userName': d['userName'] ?? '',
        'userPhone': d['userPhone'] ?? '',
        'professionalName': d['proName'] ?? '',
        'professionalId': proId,
        'price': offer['price'] ?? 0,
        'requestId': docId,
        'status': 'pending',
        'isImmediate': true,
        'scheduledTime': 'Άμεσα',
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (proId.isNotEmpty) {
        await FirebaseFirestore.instance
            .collection('users').doc(proId)
            .collection('notifications').add({
          'title': '🎉 Αποδέχτηκαν την προσφορά σου!',
          'body': '${d['userName'] ?? 'Χρήστης'} αποδέχτηκε την προσφορά σου!',
          'type': 'offer_accepted',
          'userName': d['userName'] ?? '',
          'userPhone': d['userPhone'] ?? '',
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Αποδέχτηκες την προσφορά!'), backgroundColor: Colors.green),
        );
      }
    } catch (_) {}
  }

  Future<void> _rejectOffer(String docId) async {
    await FirebaseFirestore.instance
        .collection('direct_requests').doc(docId)
        .update({'status': 'rejected'}).catchError((_) {});
  }
}

// ════════════════════════════════════════════════
// DIRECT REPLY SCREEN — Professional responds to direct request
// ════════════════════════════════════════════════
class DirectReplyScreen extends StatefulWidget {
  final String directRequestId;
  const DirectReplyScreen({super.key, required this.directRequestId});
  @override
  State<DirectReplyScreen> createState() => _DirectReplyScreenState();
}

class _DirectReplyScreenState extends State<DirectReplyScreen> {
  final _priceCtrl = TextEditingController();
  final _msgCtrl = TextEditingController();
  Map<String, dynamic>? _reqData;
  bool _loading = true, _sending = false;

  @override
  void initState() {
    super.initState();
    _loadRequest();
  }

  @override
  void dispose() {
    _priceCtrl.dispose();
    _msgCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadRequest() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('direct_requests').doc(widget.directRequestId).get();
      if (mounted) setState(() { _reqData = doc.data(); _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _sendOffer() async {
    final price = double.tryParse(_priceCtrl.text.replaceAll(',', '.'));
    if (price == null) return;
    setState(() => _sending = true);
  final String currentUserId;
  final String currentUserName;
  final String otherName;
  final bool isPro;          // true = current user is the professional
  const ChatScreen({
    super.key,
    required this.chatId,
    required this.currentUserId,
    required this.currentUserName,
    required this.otherName,
    required this.isPro,
  });
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _msgCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _markAsRead();
  }

  @override
  void dispose() {
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _markAsRead() async {
    try {
      final field = widget.isPro ? 'unreadPro' : 'unreadUser';
      await FirebaseFirestore.instance
                  gradient: LinearGradient(
                    begin: Alignment.topCenter, end: Alignment.bottomCenter,
                    stops: [0.4, 1.0],
                    colors: [Colors.transparent, kBg],
                  ),
                ),
              ),
              // Back button
              Positioned(
                top: MediaQuery.of(context).padding.top + 8,
                left: 12,
                child: GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withValues(alpha: 0.55),
                    ),
                    child: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 16),
                  ),
                ),
              ),
              // Online badge
              if (isOnline)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 10,
                  right: 14,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      color: kGreen.withValues(alpha: 0.18),
                      border: Border.all(color: kGreen.withValues(alpha: 0.6)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(width: 7, height: 7,
                          decoration: const BoxDecoration(shape: BoxShape.circle, color: kGreen)),
                      const SizedBox(width: 5),
                      const Text('Online', style: TextStyle(color: kGreen, fontSize: 11, fontWeight: FontWeight.w700)),
                    ]),
                  ),
                ),
              // Name + specialty bottom
              Positioned(
                bottom: 12, left: 16, right: 16,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      otherName: proName,
                      isPro: false,
                    ),
                    transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
                    transitionDuration: const Duration(milliseconds: 300),
                  )),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      color: _g(0.04),
                      border: Border.all(color: unread > 0
                          ? kGold.withValues(alpha: 0.4) : _g(0.08)),
                    ),
                    child: Row(children: [
                      // Avatar
                      Container(width: 46, height: 46,
                        decoration: BoxDecoration(shape: BoxShape.circle,
                            color: kGold.withValues(alpha: 0.12),
                            border: Border.all(color: kGold.withValues(alpha: 0.25))),
                        child: Center(child: Text(
                            proName.isNotEmpty ? proName[0].toUpperCase() : '?',
                            style: const TextStyle(color: kGold, fontSize: 18, fontWeight: FontWeight.w800)))),
                      const SizedBox(width: 12),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(proName, style: TextStyle(color: _gw, fontSize: 14,
                            fontWeight: unread > 0 ? FontWeight.w800 : FontWeight.w600)),
                        const SizedBox(height: 3),
                        Text(lastMsg.isNotEmpty ? lastMsg : 'Ξεκίνα τη συνομιλία...',
                    border: Border.all(color: kGreen.withValues(alpha: 0.3))),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 5, height: 5,
                      decoration: const BoxDecoration(shape: BoxShape.circle, color: kGreen)),
                  const SizedBox(width: 5),
                            ])),
                          ])
                        : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              const Text('🚀', style: TextStyle(fontSize: 22)),
                              const SizedBox(width: 10),
                              const Expanded(child: Text('Αναβάθμιση σε Premium', style: TextStyle(color: Colors.white, fontFamily: 'Raleway', fontWeight: FontWeight.w700, fontSize: 15))),
                            ]),
                            const SizedBox(height: 6),
                            Text('Απεριόριστα αιτήματα, προτεραιότητα AI, αφαίρεση διαφημίσεων.', style: TextStyle(color: _g(0.5), fontSize: 12, height: 1.4)),
                            const SizedBox(height: 14),
                            _PremiumButton(
                              label: _stripeLoading ? 'Φόρτωση...' : '💳  Συνδρομή — 9,99€/μήνα',
                              gradient: const LinearGradient(colors: [kGoldLight, kGold, kGoldDark]),
                              textColor: Colors.black,
                              onTap: () { if (!_stripeLoading) _startStripeCheckout(); },
                            ),
                          ]),
                  ),

                  const SizedBox(height: 20),
                  _sectionHeader('ΑΣΦΑΛΕΙΑ'),
                  _buildToggleRow(
                      '👆',
                      'Biometric Login',
                      'Face ID / Fingerprint',
                      _biometricOn, (v) async {
                    setState(() => _biometricOn = v);
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool('biometric_enabled', v);
                  }),

                  const SizedBox(height: 20),
                  _sectionHeader('ΘΕΜΑ'),
                  _ThemeSelector(),
                  const SizedBox(height: 20),

                  _sectionHeader('ΣΧΕΤΙΚΑ'),
                  const _ProfileRow(
                      icon: Icons.info_outline,
                      emoji: 'ℹ️',
                      label: 'Έκδοση',
class NotificationsScreen extends StatelessWidget {
  final String userId;
  const NotificationsScreen({super.key, required this.userId});

  Future<void> _markAllRead() async {
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .collection('notifications')
        .where('isRead', isEqualTo: false)
        .get();
    for (final doc in snap.docs)
      await doc.reference.update({'isRead': true});
  }

  // Offer dialog που ανοίγει από notification
  static void _showOfferDialogFromNotif(BuildContext context,
      String requestId, Map<String, dynamic> requestData, String proId) {
    final priceCtrl = TextEditingController();
    final msgCtrl = TextEditingController();
    String available = 'Αύριο';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.all(22),
        .where('isRead', isEqualTo: false)
        .get();
    for (final doc in snap.docs)
      await doc.reference.update({'isRead': true});
  }

  // Offer dialog που ανοίγει από notification
  static void _showOfferDialogFromNotif(BuildContext context,
      String requestId, Map<String, dynamic> requestData, String proId) {
    final priceCtrl = TextEditingController();
    final msgCtrl = TextEditingController();
    String available = 'Αύριο';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              color: const Color(0xFF0A0800),
              border: Border.all(color: kGold.withValues(alpha: 0.4)),
              boxShadow: [BoxShadow(
                  color: kGold.withValues(alpha: 0.15), blurRadius: 30)],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                const Text('💼', style: TextStyle(fontSize: 22)),
                const SizedBox(width: 10),
                const Expanded(child: Text('Στείλε Προσφορά',
                    style: TextStyle(fontFamily: 'Raleway', fontSize: 17,
                        fontWeight: FontWeight.w800, color: Colors.white))),
                GestureDetector(
                  onTap: () => Navigator.pop(ctx),
                  child: Icon(Icons.close,
                      color: _g(0.4), size: 20),
                ),
              ]),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: kGold.withValues(alpha: 0.07)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(requestData['description'] ?? '',
                      maxLines: 3, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: _g(0.6))),
                  if ((requestData['videoUrls'] as List?)?.isNotEmpty == true) ...[
                    const SizedBox(height: 8),
                    ...((requestData['videoUrls'] as List).asMap().entries.map((e) =>
                      GestureDetector(
                        onTap: () => launchUrl(Uri.parse(e.value as String), mode: LaunchMode.externalApplication),
                        child: Container(
                          margin: const EdgeInsets.only(top: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            color: kGold.withValues(alpha: 0.12),
                            border: Border.all(color: kGold.withValues(alpha: 0.4)),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.play_circle_outline, color: kGold, size: 14),
                            const SizedBox(width: 5),
                            Text('▶ Βίντεο ${e.key + 1} — πάτα για προβολή',
                                style: const TextStyle(color: kGold, fontSize: 11, fontWeight: FontWeight.w700)),
                          ]),
                        ),
                      )
                    )),
                  ],
                ]),
              ),
              const SizedBox(height: 14),
              // Τιμή
              TextField(
                controller: priceCtrl,
                keyboardType: TextInputType.number,
                style: TextStyle(color: _gw,
                    fontSize: 24, fontWeight: FontWeight.w800),
                textAlign: TextAlign.center,
                decoration: InputDecoration(
                  labelText: 'Τιμή σου (€)',
                  labelStyle: const TextStyle(color: kGold, fontSize: 12),
                  suffixText: '€',
                  suffixStyle: const TextStyle(color: kGold, fontSize: 18),
                  filled: true,
                  fillColor: _g(0.05),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: kGold.withValues(alpha: 0.3))),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: kGold.withValues(alpha: 0.3))),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: kGold, width: 2)),
                ),
              ),
              const SizedBox(height: 12),
              // Διαθεσιμότητα
              Row(children: [
                Text('Διαθέσιμος: ', style: TextStyle(
                    fontSize: 12, color: _g(0.5))),
                const SizedBox(width: 6),
                ...['Σήμερα', 'Αύριο', 'Μεθαύριο'].map((a) =>
                  GestureDetector(
                    onTap: () => setS(() => available = a),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      margin: const EdgeInsets.only(right: 6),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: available == a
                            ? kGold.withValues(alpha: 0.2)
                            : _g(0.05),
                        border: Border.all(
                            color: available == a
                                ? kGold : Colors.transparent),
                      ),
                      child: Text(a, style: TextStyle(
                          fontSize: 11,
                          color: available == a
                              ? kGold : _g(0.4))),
                    ),
                  )
                ),
              ]),
              const SizedBox(height: 12),
              // Μήνυμα
              TextField(
                controller: msgCtrl, maxLines: 2,
                style: TextStyle(color: _gw, fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Προσθήκη μηνύματος (προαιρετικό)...',
                  hintStyle: TextStyle(
                      color: _g(0.25), fontSize: 12),
                  filled: true,
                  fillColor: _g(0.05),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: kGold.withValues(alpha: 0.3))),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: kGold.withValues(alpha: 0.3))),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: kGold)),
                ),
              ),
              const SizedBox(height: 16),
              // Buttons
              Row(children: [
                Expanded(child: GestureDetector(
                  onTap: () => Navigator.pop(ctx),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        color: _g(0.06)),
                    child: const Center(child: Text('Άκυρο',
                        style: TextStyle(color: Colors.white54, fontSize: 13))),
                  ),
                )),
                const SizedBox(width: 10),
                Expanded(child: GestureDetector(
                  onTap: () async {
                    final price = double.tryParse(priceCtrl.text.trim()) ?? 0;
                    if (price <= 0) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Βάλε τιμή!')));
                      return;
                    }
                    Navigator.pop(ctx);
                    await _submitOfferFromNotif(context, requestId,
                        requestData, price, msgCtrl.text.trim(),
                        available, proId);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      gradient: const LinearGradient(
                          colors: [kGoldLight, kGold]),
                      boxShadow: [BoxShadow(
                          color: kGold.withValues(alpha: 0.3), blurRadius: 12)],
                    ),
                    child: const Center(child: Text('🚀 Στείλε!',
                        style: TextStyle(color: Colors.black,
                            fontWeight: FontWeight.w800, fontSize: 14))),
                  ),
                )),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  static Future<void> _submitOfferFromNotif(
      BuildContext context, String requestId,
      Map<String, dynamic> requestData, double price,
      String message, String available, String proId,
      {String? notifDocId}) async {
    try {
      final proDoc = await FirebaseFirestore.instance
          .collection('users').doc(proId).get();
      final proName = proDoc.data()?['name'] ?? 'Επαγγελματίας';
      // Mark notification as read
      if (notifDocId != null) {
        await FirebaseFirestore.instance
            .collection('users').doc(proId)
            .collection('notifications').doc(notifDocId)
            .update({'isRead': true});
      } else {
        // Mark all new_request notifications for this request as read
        final notifs = await FirebaseFirestore.instance
            .collection('users').doc(proId)
            .collection('notifications')
            .where('requestId', isEqualTo: requestId)
            .where('isRead', isEqualTo: false)
            .get();
        for (final n in notifs.docs) await n.reference.update({'isRead': true});
      }

      // Γράψε offer
      await FirebaseFirestore.instance.collection('offers').add({
        'requestId': requestId,
        'professionalId': proId,
        'professionalName': proName,
        'price': price,
        'message': message,
        'availableFrom': available,
        'rating': 4.8,
        'emoji': '🔧',
        'createdAt': FieldValue.serverTimestamp(),
      });

      // Αύξηση offersCount
      await FirebaseFirestore.instance
          .collection('requests').doc(requestId)
          .update({'offersCount': FieldValue.increment(1)});

      // ΔΕΝ στέλνουμε notification — ειδοποίηση μόνο όταν λήξει ο χρόνος

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('✅ Η προσφορά στάλθηκε!'),
          backgroundColor: kGreen.withValues(alpha: 0.9),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Σφάλμα: \$e')));
      }
    }
  }

  // Dialog για τον επαγγελματία όταν ο χρήστης αποδέχτηκε
  static void _showBookingAcceptedDialog(
      BuildContext context, Map<String, dynamic> notifData) {
    final userName = notifData['userName'] as String? ?? 'Χρήστης';
    final userPhone = notifData['userPhone'] as String? ?? '';
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            color: const Color(0xFF060E08),
            border: Border.all(color: kGreen.withValues(alpha: 0.5)),
            boxShadow: [BoxShadow(
                color: kGreen.withValues(alpha: 0.2), blurRadius: 30)],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('🎉', style: TextStyle(fontSize: 52)),
            const SizedBox(height: 12),
            const Text('Αποδέχτηκαν την προσφορά σου!',
                textAlign: TextAlign.center,
                style: TextStyle(fontFamily: 'Raleway', fontSize: 20,
                    fontWeight: FontWeight.w800, color: Colors.white)),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: kGreen.withValues(alpha: 0.08),
                border: Border.all(color: kGreen.withValues(alpha: 0.3)),
              ),
              child: Column(children: [
                Row(children: [
                  const Text('👤', style: TextStyle(fontSize: 18)),
                          const SizedBox(width: 10),
                          Text(userPhone, style: const TextStyle(
                              color: kGreen, fontSize: 18,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.5)),
                        ],
                      ),
                    ),
                  ),
                ],
              ]),
            ),
            const SizedBox(height: 20),
            GestureDetector(
              onTap: () => Navigator.pop(ctx),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 13),
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    gradient: const LinearGradient(
                        colors: [kGoldLight, kGold])),
                child: const Center(child: Text('Τέλεια! 🎉',
                    style: TextStyle(color: Colors.black,
                        fontWeight: FontWeight.w800, fontSize: 15))),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Row(children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _g(0.05),
                        border: Border.all(
                            color: kGold.withValues(alpha: 0.2))),
                    child: const Icon(Icons.arrow_back_ios_new,
                        color: kGold, size: 16)),
              ),
              const SizedBox(width: 14),
              const Expanded(
                  child: Text('Ειδοποιήσεις',
                      style: TextStyle(
                          fontFamily: 'Raleway',
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white))),
              GestureDetector(
                onTap: _markAllRead,
                child: Text('Διαβάστηκαν',
                    style: TextStyle(
                        fontSize: 11, color: kGold.withValues(alpha: 0.6))),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .doc(userId)
                  .collection('notifications')
                  .orderBy('createdAt', descending: true)
                  .snapshots(),
              builder: (context, snap) {
                if (!snap.hasData)
                  return const Center(
                      child: CircularProgressIndicator(color: kGold));
                final docs = snap.data!.docs;
                if (docs.isEmpty) {
                  return Center(
                      child:
                          Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.notifications_none,
                        color: _g(0.15),
                        size: 52),
                    const SizedBox(height: 12),
                    Text('Δεν υπάρχουν ειδοποιήσεις',
                        style: TextStyle(
                            color: _g(0.3),
                            fontSize: 14)),
                  ]));
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                  itemCount: docs.length,
                  itemBuilder: (_, i) {
                    final d = docs[i].data() as Map<String, dynamic>;
                    final isRead = d['isRead'] == true;
                    final type = d['type'] as String? ?? '';
                    final requestId = d['requestId'] as String? ?? '';
                    final isNewRequest = type == 'new_request';
                    final isOfferAccepted = type == 'offer_accepted';

                    // Emoji βάσει τύπου
                    String emoji = '🔔';
                    if (isNewRequest) emoji = '📋';
                    if (isOfferAccepted) emoji = '🎉';
                    if ((d['title'] as String? ?? '').startsWith('✅')) emoji = '✅';
                    if ((d['title'] as String? ?? '').startsWith('💼')) emoji = '💼';

                    return GestureDetector(
                      onTap: () async {
                        // Σημείωσε ως διαβασμένο
                        await docs[i].reference.update({'isRead': true});
                        if (!context.mounted) return;

                        // Αν είναι new_request → άνοιξε offer dialog
                        if (isNewRequest && requestId.isNotEmpty) {
                          final reqDoc = await FirebaseFirestore.instance
                              .collection('requests').doc(requestId).get();
                          if (!context.mounted) return;
                          if (reqDoc.exists) {
                            final reqData = Map<String, dynamic>.from(reqDoc.data()!);
                            // Merge videoUrls from request into notification data for display
                            final videoUrls = reqData['videoUrls'] as List?;
                            if (videoUrls != null && videoUrls.isNotEmpty) {
                              reqData['videoUrls'] = videoUrls;
                              reqData['hasVideos'] = true;
                            }
                            _showOfferDialogFromNotif(
                                context, requestId, reqData, userId);
                          }
                        }
                        // Αν είναι offer_accepted → εμφάνισε στοιχεία χρήστη
                        if (isOfferAccepted) {
                          _showBookingAcceptedDialog(context, d);
                        }
                      },
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          color: isRead
                              ? _g(0.04)
                              : (isNewRequest
                                  ? kGold.withValues(alpha: 0.08)
                                  : kGreen.withValues(alpha: 0.07)),
                          border: Border.all(
                              color: isRead
                                  ? _g(0.07)
                                  : (isNewRequest
                                      ? kGold.withValues(alpha: 0.3)
                                      : kGreen.withValues(alpha: 0.3))),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 42, height: 42,
                              decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: isRead
                                      ? _g(0.05)
                                      : (isNewRequest
                                          ? kGold.withValues(alpha: 0.12)
                                          : kGreen.withValues(alpha: 0.12))),
                              child: Center(child: Text(emoji,
                                  style: const TextStyle(fontSize: 20))),
                            ),
                            const SizedBox(width: 12),
                            Expanded(child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              Text(d['title'] ?? '',
                                  style: TextStyle(
                                      fontWeight: isRead
                                          ? FontWeight.w400 : FontWeight.w700,
                                      color: isRead ? Colors.white70 : Colors.white,
                                      fontSize: 14)),
                              const SizedBox(height: 4),
                              Text(d['body'] ?? '',
                                  style: TextStyle(fontSize: 12, height: 1.5,
                                      color: _g(0.45))),
                              if ((d['hasImages'] == true || (d['imageCount'] ?? 0) > 0)) ...[
                                const SizedBox(height: 4),
                                Row(children: [
                                  const Text('📷 ', style: TextStyle(fontSize: 11)),
                                  Text('${d['imageCount'] ?? 1} φωτογραφί${(d['imageCount'] ?? 1) == 1 ? 'α' : 'ες'}',
                                      style: const TextStyle(color: kGold,
                                          fontSize: 11, fontWeight: FontWeight.w600)),
                                ]),
                              ],
                              if (d['hasVideos'] == true) ...[
                                const SizedBox(height: 6),
                                if ((d['videoUrls'] as List?)?.isNotEmpty == true)
                                  ...((d['videoUrls'] as List).asMap().entries.map((e) =>
                                    GestureDetector(
                                      onTap: () => launchUrl(Uri.parse(e.value as String), mode: LaunchMode.externalApplication),
                                      child: Container(
                                        margin: const EdgeInsets.only(bottom: 4),
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(8),
                                          color: kGold.withValues(alpha: 0.1),
                                          border: Border.all(color: kGold.withValues(alpha: 0.4)),
                                        ),
                                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                                          const Icon(Icons.play_circle_outline, color: kGold, size: 14),
                                          const SizedBox(width: 5),
                                          Text('▶ Βίντεο ${e.key + 1} — πάτα για προβολή',
                                              style: const TextStyle(color: kGold, fontSize: 11, fontWeight: FontWeight.w700)),
                                        ]),
                                          fontSize: 11, fontWeight: FontWeight.w600)),
                                ]),
                              ],
                              if (d['hasVideos'] == true) ...[
                                const SizedBox(height: 6),
                                    const Icon(Icons.videocam, color: kGold, size: 13),
                                    const SizedBox(width: 4),
                                    Text('Βίντεο (ανεβαίνει...)',
                                        style: TextStyle(color: _g(0.4), fontSize: 11, fontStyle: FontStyle.italic)),
                                  ]),
                              ],
                              if (isNewRequest && !isRead) ...[
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(10),
                                      gradient: const LinearGradient(
                                          colors: [kGoldLight, kGold])),
                                  child: const Text('💼 Στείλε Προσφορά →',
                                      style: TextStyle(color: Colors.black,
                                          fontSize: 11, fontWeight: FontWeight.w800)),
                                ),
                              ],
                              if (isOfferAccepted) ...[
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(10),
                                      color: kGreen.withValues(alpha: 0.15)),
                                  child: const Text('📞 Δες στοιχεία επικοινωνίας',
                                      style: TextStyle(color: kGreen,
                                          fontSize: 11, fontWeight: FontWeight.w700)),
                                ),
                              ],
                            ])),
                            GestureDetector(
                              onTap: () => docs[i].reference.delete(),
                              child: Container(
                                  width: 28, height: 28,
                                  margin: const EdgeInsets.only(left: 8),
                                  decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Colors.red.withValues(alpha: 0.1)),
                                  child: Icon(Icons.close,
                                      color: Colors.red.withValues(alpha: 0.6),
                                      size: 14)),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════
// SPECIALTY & AREA PICKERS
// ═══════════════════════════════════════
const List<Map<String, dynamic>> _specialtyCategories = [
  {
    'category': 'Τεχνικοί',
    'items': [
      'Ηλεκτρολόγος', 'Υδραυλικός', 'Ψυκτικός', 'Ελαιοχρωματιστής',
      'Μηχανικός', 'Κτίστης', 'Ξυλουργός', 'Υαλουργός',
      'Τεχνικός Ανελκυστήρων', 'Αποφράξεις', 'Αλουμινάς', 'Πλακάς',
      'Συντήρηση Κλιματιστικών', 'Εγκατάσταση Ηλιακών'
    ]
  },
  {
    'category': 'Υγεία',
    'items': [
      'Παθολόγος', 'Παιδίατρος', 'Οδοντίατρος', 'Φυσιοθεραπευτής',
      'Ψυχολόγος', 'Διατροφολόγος', 'Νοσηλευτής κατ\' οίκον'
    ]
                                  child: Icon(Icons.close,
                                      color: Colors.red.withValues(alpha: 0.6),
                                      size: 14)),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════
// SPECIALTY & AREA PICKERS
// ═══════════════════════════════════════
const List<Map<String, dynamic>> _specialtyCategories = [
  {
    'category': 'Τεχνικοί',
    'items': [
      'Ηλεκτρολόγος', 'Υδραυλικός', 'Ψυκτικός', 'Ελαιοχρωματιστής',
      'Μηχανικός', 'Κτίστης', 'Ξυλουργός', 'Υαλουργός',
      'Τεχνικός Ανελκυστήρων', 'Αποφράξεις', 'Αλουμινάς', 'Πλακάς',
      'Συντήρηση Κλιματιστικών', 'Εγκατάσταση Ηλιακών'
    ]
  },
  {
                  title: const Text('Διαγραφή Project',
                      style: TextStyle(color: Colors.white, fontSize: 15)),
                  content: Text('Θέλεις να διαγράψεις το project "$title" και όλες τις φωτογραφίες;',
                      style: TextStyle(color: _g(0.5), fontSize: 13)),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx),
                        child: Text('Άκυρο', style: TextStyle(color: _g(0.4)))),
                    TextButton(onPressed: () { Navigator.pop(ctx); onDeleteProject(); },
                        child: const Text('Διαγραφή', style: TextStyle(color: Colors.redAccent))),
                  ],
                ),
              ),
              child: Container(padding: const EdgeInsets.all(5),
                  child: Icon(Icons.delete_outline, color: _g(0.3), size: 18)),
            ),
          ]),
        ),
        if (photos.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
            child: GestureDetector(
// MISSING LINE 9989
// MISSING LINE 9990
// MISSING LINE 9991
// MISSING LINE 9992
// MISSING LINE 9993
class _ProPortfolioScreenState extends State<ProPortfolioScreen> {
  Uint8List? _photoBytes;
  double? _liveRating;
  int? _liveReviewCount;

  @override
  void initState() {
    super.initState();
    final url = (widget.pro['profilePhotoUrl'] ?? widget.pro['photo_url'] ?? '') as String;
    if (url.isNotEmpty) {
      http.get(Uri.parse(url)).timeout(const Duration(seconds: 10)).then((res) {
        if (res.statusCode == 200 && mounted) setState(() => _photoBytes = res.bodyBytes);
      }).catchError((_) {});
    }
    // Fetch live rating from users collection (authoritative source)
    final proId = (widget.pro['id'] ?? widget.pro['uid'] ?? '') as String;
    if (proId.isNotEmpty) {
      FirebaseFirestore.instance.collection('users').doc(proId).get().then((snap) {
        if (!mounted || !snap.exists) return;
        final d = snap.data() ?? {};
        final r = ((d['averageRating'] ?? 0) as num).toDouble();
        final c = ((d['reviewCount'] ?? 0) as num).toInt();
        if (c > 0) setState(() { _liveRating = r; _liveReviewCount = c; });
      }).catchError((_) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final pro = widget.pro;
                    ? const LinearGradient(colors: [kGoldLight, kGold, kGoldDark])
                    : null,
                color: _live ? null : Colors.black,
                border: Border.all(
                  color: _live ? kGold.withValues(alpha: 0.6) : _g(0.15),
                  width: _live ? 1 : 0.5,
                ),
                boxShadow: _live ? [
                  BoxShadow(color: kGold.withValues(alpha: 0.4), blurRadius: 10, spreadRadius: 0),
                ] : [],
              ),
              child: Stack(children: [
                AnimatedAlign(
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeInOut,
                  alignment: _live ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    width: 24, height: 24,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _live ? Colors.black : _g(0.25),
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 4)],
                    ),
                    child: Center(child: _live
                        ? const Icon(Icons.wifi, color: kGold, size: 12)
                        : Icon(Icons.wifi_off, color: _g(0.4), size: 11)),
                  ),
                ),
                Center(child: AnimatedOpacity(
                  opacity: _live ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: const Padding(
                    padding: EdgeInsets.only(right: 28),
                    child: Text('LIVE', style: TextStyle(
                        color: Colors.black, fontSize: 8,
                        fontWeight: FontWeight.w900, letterSpacing: 0.5)),
                  ),
                )),
                Center(child: AnimatedOpacity(
                  opacity: _live ? 0 : 1,
                  duration: const Duration(milliseconds: 200),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 26),
                    child: Text('OFF', style: TextStyle(
                        color: _g(0.35), fontSize: 8,
                        fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                  ),
                )),
              ]),
            ),
          ),
        ]),
      ),

      // Content
      if (!_live)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Container(
            height: 110,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: LinearGradient(colors: [_g(0.04), _g(0.02)]),
              border: Border.all(color: _g(0.07), width: 0.5),
            ),
class MessagesScreen extends StatefulWidget {
  final String userId;
  const MessagesScreen({super.key, required this.userId});
  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {

  Future<void> _deleteChat(String chatId, String proName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: const Color(0xFF111111),
            border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('🗑️', style: TextStyle(fontSize: 36)),
            const SizedBox(height: 10),
            const Text('Διαγραφή συνομιλίας;',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text('Η συνομιλία με $proName θα διαγραφεί. Δεν μπορεί να αναιρεθεί.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 13, height: 1.4)),
            const SizedBox(height: 20),
            Row(children: [
              Expanded(child: GestureDetector(
                onTap: () => Navigator.pop(ctx, false),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: Colors.white.withValues(alpha: 0.06),
                  ),
                  child: const Center(child: Text('Άκυρο',
                      style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600))),
                ),
              )),
              const SizedBox(width: 10),
              Expanded(child: GestureDetector(
                onTap: () => Navigator.pop(ctx, true),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: Colors.red.withValues(alpha: 0.15),
                    border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
                  ),
                  child: const Center(child: Text('Διαγραφή',
                      style: TextStyle(color: Colors.red, fontWeight: FontWeight.w700))),
                ),
              )),
            ]),
          ]),
        ),
      ),
    );
    if (confirmed != true) return;
    try {
      // Delete all messages in the subcollection first
      final msgs = await FirebaseFirestore.instance
          .collection('chats').doc(chatId).collection('messages').get();
      for (final m in msgs.docs) { await m.reference.delete(); }
      // Then delete the chat document
      await FirebaseFirestore.instance.collection('chats').doc(chatId).delete();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
          child: Row(children: [
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(width: 38, height: 38,
                decoration: BoxDecoration(shape: BoxShape.circle, color: _g(0.06)),
                child: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 16)),
            ),
            const SizedBox(width: 14),
            const Text('Μηνύματα', style: TextStyle(color: Colors.white,
class _NotificationsScreenState extends State<NotificationsScreen> {
  final Set<String> _deletedIds = {};
  List<QueryDocumentSnapshot> _docs = [];
  StreamSubscription<QuerySnapshot>? _sub;
  bool _loadingNotifs = true;

  String get userId => widget.userId;

  @override
  void initState() {
    super.initState();
    _sub = FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .collection('notifications')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(() {
        _docs = snap.docs.where((d) => !_deletedIds.contains(d.id)).toList();
        _loadingNotifs = false;
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _markAllRead() async {
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .collection('notifications')
        .where('isRead', isEqualTo: false)
        .get();
    for (final doc in snap.docs)
      await doc.reference.update({'isRead': true});
  }

  // Offer dialog που ανοίγει από notification
  static void _showOfferDialogFromNotif(BuildContext context,
      String requestId, Map<String, dynamic> requestData, String proId) {
    final priceCtrl = TextEditingController();
    final msgCtrl = TextEditingController();
    String available = 'Αύριο';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              color: const Color(0xFF0A0800),
              border: Border.all(color: kGold.withValues(alpha: 0.4)),
              boxShadow: [BoxShadow(
                  color: kGold.withValues(alpha: 0.15), blurRadius: 30)],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                const Text('💼', style: TextStyle(fontSize: 22)),
                const SizedBox(width: 10),
                const Expanded(child: Text('Στείλε Προσφορά',
                    style: TextStyle(fontFamily: 'Raleway', fontSize: 17,
                        fontWeight: FontWeight.w800, color: Colors.white))),
                GestureDetector(
                  onTap: () => Navigator.pop(ctx),
                  child: Icon(Icons.close,
                      color: _g(0.4), size: 20),
                ),
              ]),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: kGold.withValues(alpha: 0.07)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(requestData['description'] ?? '',
                      maxLines: 3, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: _g(0.6))),
                  if ((requestData['videoUrls'] as List?)?.isNotEmpty == true) ...[
                    const SizedBox(height: 8),
                    ...((requestData['videoUrls'] as List).asMap().entries.map((e) =>
                      GestureDetector(
                        onTap: () => launchUrl(Uri.parse(e.value as String), mode: LaunchMode.externalApplication),
                        child: Container(
                          margin: const EdgeInsets.only(top: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            color: kGold.withValues(alpha: 0.12),
                            border: Border.all(color: kGold.withValues(alpha: 0.4)),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.play_circle_outline, color: kGold, size: 14),
                            const SizedBox(width: 5),
                            Text('▶ Βίντεο ${e.key + 1} — πάτα για προβολή',
                                style: const TextStyle(color: kGold, fontSize: 11, fontWeight: FontWeight.w700)),
                          ]),
                        ),
                      )
                    )),
                  ],
                ]),
              ),
              const SizedBox(height: 14),
              // Τιμή
              TextField(
                controller: priceCtrl,
                keyboardType: TextInputType.number,
                style: TextStyle(color: _gw,
                    fontSize: 24, fontWeight: FontWeight.w800),
                textAlign: TextAlign.center,
                decoration: InputDecoration(
                  labelText: 'Τιμή σου (€)',
                  labelStyle: const TextStyle(color: kGold, fontSize: 12),
                  suffixText: '€',
                  suffixStyle: const TextStyle(color: kGold, fontSize: 18),
                  filled: true,
                  fillColor: _g(0.05),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: kGold.withValues(alpha: 0.3))),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: kGold.withValues(alpha: 0.3))),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: kGold, width: 2)),
                ),
              ),
              const SizedBox(height: 12),
              // Διαθεσιμότητα
              Row(children: [
                Text('Διαθέσιμος: ', style: TextStyle(
                    fontSize: 12, color: _g(0.5))),
                const SizedBox(width: 6),
                ...['Σήμερα', 'Αύριο', 'Μεθαύριο'].map((a) =>
                  GestureDetector(
                    onTap: () => setS(() => available = a),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                child: Center(child: Text(
                    widget.otherName.isNotEmpty ? widget.otherName[0].toUpperCase() : '?',
                    style: const TextStyle(color: kGold, fontSize: 16, fontWeight: FontWeight.w800))),
              ),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.otherName, style: const TextStyle(color: Colors.white,
                    fontSize: 15, fontWeight: FontWeight.w700)),
                Text(widget.isPro ? 'Πελάτης' : 'Επαγγελματίας',
                    style: TextStyle(color: _g(0.35), fontSize: 11)),
              ])),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(8),
                    color: kGreen.withValues(alpha: 0.1),
                    border: Border.all(color: kGreen.withValues(alpha: 0.3))),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 5, height: 5,
                      decoration: const BoxDecoration(shape: BoxShape.circle, color: kGreen)),
                  const SizedBox(width: 5),
                  const Text('Online', style: TextStyle(color: kGreen, fontSize: 10, fontWeight: FontWeight.w600)),
                ]),
              ),
            ]),
          ),

          // ── Messages list ──
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('chats').doc(widget.chatId)
                  .collection('messages')
                  .orderBy('createdAt', descending: false)
                  .snapshots(),
              builder: (ctx, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator(color: kGold));
class RequestHistoryScreen extends StatelessWidget {
  final String userId;
  const RequestHistoryScreen({super.key, required this.userId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Row(children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _g(0.05),
                        border: Border.all(
                            color: kGold.withValues(alpha: 0.2))),
                    child: const Icon(Icons.arrow_back_ios_new,
                        color: kGold, size: 16)),
              ),
              const SizedBox(width: 14),
              const Text('Επαγγελματίες που επέλεξες',
                  style: TextStyle(
                      fontFamily: 'Raleway',
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
                  child: Container(
            BoxShadow(color: kGold.withValues(alpha: 0.3), blurRadius: 14, offset: const Offset(0, 4))
          ] : null),
        ),
        child: Center(child: Text(widget.label, style: TextStyle(
            color: widget.textColor, fontSize: widget.fontSize,
            fontWeight: FontWeight.w800))),
      ),
    ),
  );
}

// ═══════════════════════════════════════
// NO OFFERS WIDGET
// ═══════════════════════════════════════
class _NoOffersWidget extends StatelessWidget {
  final VoidCallback onRetry;
  const _NoOffersWidget({required this.onRetry});
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('😔', style: TextStyle(fontSize: 60)),
        const SizedBox(height: 20),
        const Text('Δυστυχώς δεν βρέθηκαν προσφορές',
            textAlign: TextAlign.center,
            style: TextStyle(fontFamily: 'Raleway', fontSize: 20,
                fontWeight: FontWeight.w800, color: Colors.white)),
        const SizedBox(height: 10),
        Text('Μπορεί να μην υπάρχουν διαθέσιμοι επαγγελματίες αυτή τη στιγμή. Προσπάθησε ξανά!',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: _g(0.45), height: 1.5)),
        const SizedBox(height: 28),
        _PremiumButton(
          label: '🔄 Δοκίμασε ξανά',
          gradient: const LinearGradient(colors: [kGoldLight, kGold]),
          textColor: Colors.black,
          onTap: onRetry,
        ),
      ]),
            .collection('notifications')
            .where('requestId', isEqualTo: requestId)
            .where('isRead', isEqualTo: false)
            .get();
        for (final n in notifs.docs) await n.reference.update({'isRead': true});
      }

      // Γράψε offer
      await FirebaseFirestore.instance.collection('offers').add({
        'requestId': requestId,
        'professionalId': proId,
        'professionalName': proName,
        'price': price,
        'message': message,
        'availableFrom': available,
        'rating': 4.8,
        'emoji': '🔧',
        'createdAt': FieldValue.serverTimestamp(),
      });

      // Αύξηση offersCount
      await FirebaseFirestore.instance
          .collection('requests').doc(requestId)
          .update({'offersCount': FieldValue.increment(1)});

      // ΔΕΝ στέλνουμε notification — ειδοποίηση μόνο όταν λήξει ο χρόνος

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('✅ Η προσφορά στάλθηκε!'),
          backgroundColor: kGreen.withValues(alpha: 0.9),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Σφάλμα: \$e')));
      }
    }
  }

  // Dialog για τον επαγγελματία όταν ο χρήστης αποδέχτηκε
  static void _showBookingAcceptedDialog(
      BuildContext context, Map<String, dynamic> notifData) {
    final userName = notifData['userName'] as String? ?? 'Χρήστης';
    final userPhone = notifData['userPhone'] as String? ?? '';
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            color: const Color(0xFF060E08),
            border: Border.all(color: kGreen.withValues(alpha: 0.5)),
            boxShadow: [BoxShadow(
                color: kGreen.withValues(alpha: 0.2), blurRadius: 30)],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('🎉', style: TextStyle(fontSize: 52)),
            const SizedBox(height: 12),
            const Text('Αποδέχτηκαν την προσφορά σου!',
                textAlign: TextAlign.center,
                style: TextStyle(fontFamily: 'Raleway', fontSize: 20,
                    fontWeight: FontWeight.w800, color: Colors.white)),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: kGreen.withValues(alpha: 0.08),
                border: Border.all(color: kGreen.withValues(alpha: 0.3)),
              ),
              child: Column(children: [
                Row(children: [
                  const Text('👤', style: TextStyle(fontSize: 18)),
                  const SizedBox(width: 10),
                  Text(userName, style: const TextStyle(
                      color: Colors.white, fontSize: 16,
                      fontWeight: FontWeight.w700)),
                ]),
                if (userPhone.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  GestureDetector(
                    onTap: () => launchUrl(Uri.parse('tel:\$userPhone')),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          vertical: 12, horizontal: 16),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        color: kGreen.withValues(alpha: 0.15),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.phone, color: kGreen, size: 22),
                          const SizedBox(width: 10),
                          Text(userPhone, style: const TextStyle(
                              color: kGreen, fontSize: 18,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.5)),
                        ],
                      ),
                    ),
                  ),
                ],
              ]),
            ),
            const SizedBox(height: 20),
            GestureDetector(
              onTap: () => Navigator.pop(ctx),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 13),
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    gradient: const LinearGradient(
                        colors: [kGoldLight, kGold])),
                child: const Center(child: Text('Τέλεια! 🎉',
                    style: TextStyle(color: Colors.black,
                        fontWeight: FontWeight.w800, fontSize: 15))),
              ),
            ),
          ]),
        ),
                      color: kGold,
                      boxShadow: [
                        BoxShadow(
                            color: kGold.withValues(alpha: 0.8), blurRadius: 6)
                      ])),
            ],
          ]),
        ),
      );
}

class _NotificationBell extends StatelessWidget {
  final String userId;
  const _NotificationBell({required this.userId});
  @override
  Widget build(BuildContext context) {
    if (userId.isEmpty) return const SizedBox(width: 34);
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('notifications')
          .where('isRead', isEqualTo: false)
          .snapshots(),
      builder: (context, snap) {
        final count = snap.hasData ? snap.data!.docs.length : 0;
        return GestureDetector(
          onTap: () => Navigator.push(
              context,
              PageRouteBuilder(
                transitionDuration: const Duration(milliseconds: 400),
                pageBuilder: (_, __, ___) =>
                    NotificationsScreen(userId: userId),
                transitionsBuilder: (_, a, __, c) =>
                    FadeTransition(opacity: a, child: c),
              )),
          child: Stack(clipBehavior: Clip.none, children: [
            Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _g(0.05),
                    border:
                        Border.all(color: kGold.withValues(alpha: 0.2))),
                child: Icon(
                    count > 0
                        ? Icons.notifications
                        : Icons.notifications_none,
                    color: kGold.withValues(alpha: 0.7),
                    size: 17)),
            if (count > 0)
              Positioned(
                top: -4,
                right: -4,
                child: Container(
                    width: 18,
                    height: 18,
                    decoration: const BoxDecoration(
                        color: Colors.red, shape: BoxShape.circle),
                    final isRead = d['isRead'] == true;
                    final type = d['type'] as String? ?? '';
                    final requestId = d['requestId'] as String? ?? '';
                    final isNewRequest = type == 'new_request';
                    final isOfferAccepted = type == 'offer_accepted';

                    // Emoji βάσει τύπου
                    String emoji = '🔔';
                    if (isNewRequest) emoji = '📋';
                    if (isOfferAccepted) emoji = '🎉';
                    if ((d['title'] as String? ?? '').startsWith('✅')) emoji = '✅';
                    if ((d['title'] as String? ?? '').startsWith('💼')) emoji = '💼';

                    return GestureDetector(
                      onTap: () async {
                        // Σημείωσε ως διαβασμένο
                        await docs[i].reference.update({'isRead': true});
                        if (!context.mounted) return;

                        // Αν είναι new_request → άνοιξε offer dialog
                        if (isNewRequest && requestId.isNotEmpty) {
                          final reqDoc = await FirebaseFirestore.instance
                              .collection('requests').doc(requestId).get();
                          if (!context.mounted) return;
                          if (reqDoc.exists) {
                            final reqData = Map<String, dynamic>.from(reqDoc.data()!);
                            // Merge videoUrls from request into notification data for display
                            final videoUrls = reqData['videoUrls'] as List?;
                            if (videoUrls != null && videoUrls.isNotEmpty) {
                              reqData['videoUrls'] = videoUrls;
                              reqData['hasVideos'] = true;
                            }
                            _showOfferDialogFromNotif(
                                context, requestId, reqData, userId);
                          }
                        }
                        // Αν είναι offer_accepted → εμφάνισε στοιχεία χρήστη
                        if (isOfferAccepted) {
                          _showBookingAcceptedDialog(context, d);
                        }
                      },
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          color: isRead
                              ? _g(0.04)
                              : (isNewRequest
                                  ? kGold.withValues(alpha: 0.08)
                                  : kGreen.withValues(alpha: 0.07)),
                          border: Border.all(
                              color: isRead
                                  ? _g(0.07)
                                  : (isNewRequest
                                      ? kGold.withValues(alpha: 0.3)
                                      : kGreen.withValues(alpha: 0.3))),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 42, height: 42,
                              decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: isRead
                                      ? _g(0.05)
                                      : (isNewRequest
                                          ? kGold.withValues(alpha: 0.12)
                                          : kGreen.withValues(alpha: 0.12))),
                              child: Center(child: Text(emoji,
                                  style: const TextStyle(fontSize: 20))),
                            ),
                            const SizedBox(width: 12),
                            Expanded(child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              Text(d['title'] ?? '',
                                  style: TextStyle(
                                      fontWeight: isRead
                                          ? FontWeight.w400 : FontWeight.w700,
                                      color: isRead ? Colors.white70 : Colors.white,
                                      fontSize: 14)),
                              const SizedBox(height: 4),
                              Text(d['body'] ?? '',
                                  style: TextStyle(fontSize: 12, height: 1.5,
                                      color: _g(0.45))),
                              if ((d['hasImages'] == true || (d['imageCount'] ?? 0) > 0)) ...[
                                const SizedBox(height: 4),
                                Row(children: [
                                  const Text('📷 ', style: TextStyle(fontSize: 11)),
                                  Text('${d['imageCount'] ?? 1} φωτογραφί${(d['imageCount'] ?? 1) == 1 ? 'α' : 'ες'}',
                                      style: const TextStyle(color: kGold,
                                          fontSize: 11, fontWeight: FontWeight.w600)),
                                ]),
                              ],
                              if (d['hasVideos'] == true) ...[
                                const SizedBox(height: 6),
                                if ((d['videoUrls'] as List?)?.isNotEmpty == true)
                                  ...((d['videoUrls'] as List).asMap().entries.map((e) =>
                                    GestureDetector(
                                      onTap: () => launchUrl(Uri.parse(e.value as String), mode: LaunchMode.externalApplication),
                                      child: Container(
                                        margin: const EdgeInsets.only(bottom: 4),
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(8),
                                          color: kGold.withValues(alpha: 0.1),
                                          border: Border.all(color: kGold.withValues(alpha: 0.4)),
                                        ),
                                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                                          const Icon(Icons.play_circle_outline, color: kGold, size: 14),
                                          const SizedBox(width: 5),
                                          Text('▶ Βίντεο ${e.key + 1} — πάτα για προβολή',
                                              style: const TextStyle(color: kGold, fontSize: 11, fontWeight: FontWeight.w700)),
                                        ]),
                                      ),
                                    )
                                  ))
                                else
                                  Row(children: [
                                    const Icon(Icons.videocam, color: kGold, size: 13),
                                    const SizedBox(width: 4),
                                    Text('Βίντεο (ανεβαίνει...)',
                                        style: TextStyle(color: _g(0.4), fontSize: 11, fontStyle: FontStyle.italic)),
                                  ]),
                              ],
                              if (isNewRequest && !isRead) ...[
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(10),
                                      gradient: const LinearGradient(
                                          colors: [kGoldLight, kGold])),
                                  child: const Text('💼 Στείλε Προσφορά →',
                                      style: TextStyle(color: Colors.black,
                                          fontSize: 11, fontWeight: FontWeight.w800)),
                                ),
                              ],
                              if (isOfferAccepted) ...[
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(10),
                                      color: kGreen.withValues(alpha: 0.15)),
                                  child: const Text('📞 Δες στοιχεία επικοινωνίας',
                                      style: TextStyle(color: kGreen,
                                          fontSize: 11, fontWeight: FontWeight.w700)),
                                ),
                              ],
                            ])),
                            GestureDetector(
                              onTap: () {
                                final docId = docs[i].id;
                                final docRef = docs[i].reference;
                                setState(() {
                                  _deletedIds.add(docId);
                                  _docs.removeWhere((d) => d.id == docId);
                                });
                                docRef.delete().catchError((_) {
                                  if (mounted) setState(() {
                                    _deletedIds.remove(docId);
                                    // Stream will re-add it on next emission
                                  });
                                });
                              },
                              child: Container(
                                  width: 28, height: 28,
                                  margin: const EdgeInsets.only(left: 8),
                                  decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Colors.red.withValues(alpha: 0.1)),
                                  child: Icon(Icons.close,
                                      color: Colors.red.withValues(alpha: 0.6),
                                      size: 14)),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              }),
          ),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════
// SPECIALTY & AREA PICKERS
// ═══════════════════════════════════════
const List<Map<String, dynamic>> _specialtyCategories = [
  {
    'category': 'Τεχνικοί',
    'items': [
      'Ηλεκτρολόγος', 'Υδραυλικός', 'Ψυκτικός', 'Ελαιοχρωματιστής',
      'Μηχανικός', 'Κτίστης', 'Ξυλουργός', 'Υαλουργός',
      'Τεχνικός Ανελκυστήρων', 'Αποφράξεις', 'Αλουμινάς', 'Πλακάς',
      'Συντήρηση Κλιματιστικών', 'Εγκατάσταση Ηλιακών'
    ]
  },
  {
    'category': 'Υγεία',
    'items': [
      }).catchError((_) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final pro = widget.pro;
    final name = (pro['name'] ?? pro['displayName'] ?? 'Επαγγελματίας') as String;
    final specialty = (pro['specialty'] ?? pro['profession'] ?? '') as String;
  static const _eventAreas = [
    'Αθήνα Κέντρο', 'Κολωνάκι', 'Γλυφάδα', 'Βούλα', 'Βουλιαγμένη',
    'Καλλιθέα', 'Νέα Σμύρνη', 'Παλαιό Φάληρο', 'Άλιμος', 'Χαλάνδρι',
    'Μαρούσι', 'Κηφισιά', 'Εκάλη', 'Πεντέλη', 'Νέα Ιωνία',
    'Αγία Παρασκευή', 'Ζωγράφου', 'Βύρωνας', 'Ηλιούπολη',
    'Περιστέρι', 'Αιγάλεω', 'Πειραιάς', 'Κορωπί', 'Παιανία',
    'Θεσσαλονίκη Κέντρο', 'Καλαμαριά', 'Πυλαία', 'Θέρμη',
    'Πάτρα', 'Ηράκλειο Κρήτης', 'Χανιά', 'Ρέθυμνο',
    'Λάρισα', 'Βόλος', 'Ιωάννινα', 'Κέρκυρα', 'Ρόδος', 'Μυτιλήνη',
  ];

  static const _categories = [
    {
      'id': 'wedding',
      'emoji': '💍',
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: _g(0.03),
        border: Border.all(color: kGold.withValues(alpha: 0.15)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Project header
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
          child: Row(children: [
            Container(width: 3, height: 18,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(2),
                    gradient: const LinearGradient(
                        begin: Alignment.topCenter, end: Alignment.bottomCenter,
                        colors: [kGoldLight, kGold]))),
            const SizedBox(width: 10),
            Expanded(child: GestureDetector(
              onTap: onRenameProject,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(child: Text(title,
                    style: const TextStyle(color: Colors.white, fontSize: 14,
// MISSING LINE 10887
// MISSING LINE 10888
// MISSING LINE 10889
// MISSING LINE 10890
// MISSING LINE 10891
// MISSING LINE 10892
// MISSING LINE 10893
// MISSING LINE 10894
// MISSING LINE 10895
// MISSING LINE 10896
// MISSING LINE 10897
// MISSING LINE 10898
// MISSING LINE 10899
// MISSING LINE 10900
// MISSING LINE 10901
// MISSING LINE 10902
// MISSING LINE 10903
// MISSING LINE 10904
// MISSING LINE 10905
// MISSING LINE 10906
// MISSING LINE 10907
// MISSING LINE 10908
// MISSING LINE 10909
// MISSING LINE 10910
// MISSING LINE 10911
// MISSING LINE 10912
// MISSING LINE 10913
// MISSING LINE 10914
// MISSING LINE 10915
// MISSING LINE 10916
// MISSING LINE 10917
// MISSING LINE 10918
// MISSING LINE 10919
// MISSING LINE 10920
// MISSING LINE 10921
// MISSING LINE 10922
// MISSING LINE 10923
// MISSING LINE 10924
// MISSING LINE 10925
// MISSING LINE 10926
// MISSING LINE 10927
// MISSING LINE 10928
// MISSING LINE 10929
// MISSING LINE 10930
// MISSING LINE 10931
// MISSING LINE 10932
// MISSING LINE 10933
// MISSING LINE 10934
// MISSING LINE 10935
// MISSING LINE 10936
// MISSING LINE 10937
// MISSING LINE 10938
// MISSING LINE 10939
// MISSING LINE 10940
// MISSING LINE 10941
// MISSING LINE 10942
// MISSING LINE 10943
// MISSING LINE 10944
// MISSING LINE 10945
// MISSING LINE 10946
// MISSING LINE 10947
// MISSING LINE 10948
// MISSING LINE 10949
// MISSING LINE 10950
// MISSING LINE 10951
// MISSING LINE 10952
// MISSING LINE 10953
// MISSING LINE 10954
      await FirebaseFirestore.instance
          .collection('direct_requests').doc(widget.directRequestId)
          .update({
        'status': 'replied',
        'offer': {'price': price, 'message': _msgCtrl.text.trim()},
      });
      // Notify user
      final userId = d['userId'] as String? ?? '';
      if (userId.isNotEmpty) {
        final pro = FirebaseAuth.instance.currentUser;
        final proName = d['proName'] ?? 'Επαγγελματίας';
        await FirebaseFirestore.instance
            .collection('users').doc(userId)
            .collection('notifications').add({
          'title': '💼 Νέα Προσφορά από $proName',
          'body': '${price.toStringAsFixed(0)}€ — πάτα Μηνύματα για να δεις',
          'type': 'direct_offer',
          'directRequestId': widget.directRequestId,
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Η προσφορά στάλθηκε!'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _sending = false);
                                  child: Icon(Icons.broken_image_outlined, color: _g(0.3)))),
                    ),
                    Positioned(top: 3, right: 3,
                      child: GestureDetector(
                        onTap: () => onDeletePhoto(url),
// MISSING LINE 10990
// MISSING LINE 10991
// MISSING LINE 10992
                          child: const Icon(Icons.close, color: Colors.white70, size: 12)),
                      ),
                    ),
                  ]),
                );
              },
            ),
          ),
      ]),
    );
  }
}

// ════════════════════════════════════════════════
// FULLSCREEN PHOTO VIEWER
// ════════════════════════════════════════════════
class _FullscreenPhotoViewer extends StatefulWidget {
  final List<String> photos;
  final Map<String, Uint8List> bytesCache;
  final int startIndex;
  const _FullscreenPhotoViewer(
      {required this.photos, Map<String, Uint8List>? bytesCache, required this.startIndex})
      : bytesCache = bytesCache ?? const {};
  @override
  State<_FullscreenPhotoViewer> createState() => _FullscreenPhotoViewerState();
}

class _FullscreenPhotoViewerState extends State<_FullscreenPhotoViewer> {
  late PageController _pageCtrl;
  late int _current;

  @override
  void initState() {
    super.initState();
    _current = widget.startIndex;
    _pageCtrl = PageController(initialPage: widget.startIndex);
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        PageView.builder(
          controller: _pageCtrl,
          itemCount: widget.photos.length,
          onPageChanged: (i) => setState(() => _current = i),
          itemBuilder: (_, i) {
            final url = widget.photos[i];
            final bytes = widget.bytesCache[url];
            return InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: Center(
                child: bytes != null
                    ? Image.memory(bytes, fit: BoxFit.contain)
                    : Image.network(url, fit: BoxFit.contain,
                        loadingBuilder: (_, child, progress) => progress == null
                            ? child
                            : const Center(child: CircularProgressIndicator(color: kGold)),
                        errorBuilder: (_, __, ___) => const Center(
                            child: Icon(Icons.broken_image_outlined, color: Colors.white24, size: 48))),
              ),
            );
          },
        ),
        // Close button
        SafeArea(child: Padding(
          padding: const EdgeInsets.all(12),
          child: GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                        child: Text('#$_rank', style: TextStyle(
                            color: _g(0.35),
                            fontSize: 10, fontWeight: FontWeight.w600))),
              ),

              const SizedBox(height: 10),

              Row(children: [
                // Profile photo (56x56 circle)
                Container(
                    width: 56, height: 56,
                    decoration: BoxDecoration(
      final chatRef = FirebaseFirestore.instance.collection('chats').doc(widget.chatId);
      await chatRef.collection('messages').add({
        'text': text,
        'photoUrls': photoUrls,
        'videoUrls': videoUrls,
        'senderId': widget.currentUserId,
        'senderName': widget.currentUserName,
        'createdAt': FieldValue.serverTimestamp(),
      });
      final unreadField = widget.isPro ? 'unreadUser' : 'unreadPro';
      await chatRef.set({
        'lastMessage': previewText,
        'lastMessageAt': FieldValue.serverTimestamp(),
        unreadField: FieldValue.increment(1),
        widget.isPro ? 'unreadPro' : 'unreadUser': 0,
      }, SetOptions(merge: true));

      if (mounted) setState(() {
        _selectedImages.clear();
        _selectedVideoFiles.clear();
        _selectedVideoNames.clear();
      });
      await Future.delayed(const Duration(milliseconds: 100));
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    } catch (_) {}
    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(children: [
          // ── Header ──
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),

      // Notify professional (links to chat)
      if (proId.isNotEmpty) {
        await FirebaseFirestore.instance
            .collection('users').doc(proId)
            .collection('notifications').add({
          'title': '💬 Νέο μήνυμα από $userName',
          'body': msg.isNotEmpty ? msg : '${photoUrls.length} φωτογραφίες',
          'type': 'direct_chat',
          'chatId': chatId,
          'userId': user.uid,
          'userName': userName,
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      if (!mounted) return;
      // Pop DirectRequestScreen and open ChatScreen so user sees the conversation
      Navigator.pop(context);
      Navigator.push(context, PageRouteBuilder(
        pageBuilder: (_, __, ___) => ChatScreen(
          chatId: chatId,
          currentUserId: user.uid,
          currentUserName: userName,
          otherName: proName,
          isPro: false,
        ),
        transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
        transitionDuration: const Duration(milliseconds: 300),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Σφάλμα: $e'), backgroundColor: Colors.red),
            height: 220,
            child: Stack(fit: StackFit.expand, children: [
              // Photo or placeholder
              _photoBytes != null
                  ? Image.memory(_photoBytes!, fit: BoxFit.cover)
      if (cached != null && cached > 0) {
        _googleRating = cached;
        _googleRatingCount = cachedCount;
        _googleMapsUrl = cachedUrl;
      }
      // Refresh from backend in background
      Future(() async {
        try {
          final resp = await http.get(
            Uri.parse('$kBackendUrl/places-rating?placeId=$googlePlaceId'),
          ).timeout(const Duration(seconds: 10));
          final d = jsonDecode(resp.body) as Map<String, dynamic>;
          final r = (d['rating'] as num?)?.toDouble();
          final c = (d['userRatingsTotal'] as num?)?.toInt() ?? 0;
          final mu = d['mapsUrl'] as String? ?? '';
                label: widget.isBest
                    ? '✅ Επέλεξε τον ${_name.split(' ').first}'
                    : 'Επέλεξε τον ${_name.split(' ').first} →',
                gradient: widget.isBest ? const LinearGradient(colors: [kGoldLight, kGold]) : null,
                bgColor: widget.isBest ? null : _g(0.05),
                textColor: widget.isBest ? Colors.black : _g(0.6),
                fontSize: widget.isBest ? 13 : 12,
                onTap: widget.onSelect,
              ),
            ]),
          ),
        ]),
      );
}

class _OfferTag extends StatelessWidget {
  final String text;
  final bool green;
  const _OfferTag({required this.text, required this.green});
  @override
// MISSING LINE 11200
// MISSING LINE 11201
// MISSING LINE 11202
// MISSING LINE 11203
// MISSING LINE 11204
// MISSING LINE 11205
// MISSING LINE 11206
// MISSING LINE 11207
// MISSING LINE 11208
// MISSING LINE 11209
// MISSING LINE 11210
// MISSING LINE 11211
// MISSING LINE 11212
// MISSING LINE 11213
// MISSING LINE 11214
// MISSING LINE 11215
// MISSING LINE 11216
// MISSING LINE 11217
// MISSING LINE 11218
// MISSING LINE 11219
// MISSING LINE 11220
// MISSING LINE 11221
// MISSING LINE 11222
// MISSING LINE 11223
// MISSING LINE 11224
// MISSING LINE 11225
// MISSING LINE 11226
// MISSING LINE 11227
// MISSING LINE 11228
// MISSING LINE 11229
// MISSING LINE 11230
// MISSING LINE 11231
// MISSING LINE 11232
// MISSING LINE 11233
// MISSING LINE 11234
// MISSING LINE 11235
// MISSING LINE 11236
// MISSING LINE 11237
// MISSING LINE 11238
// MISSING LINE 11239
// MISSING LINE 11240
// MISSING LINE 11241
// MISSING LINE 11242
// MISSING LINE 11243
// MISSING LINE 11244
// MISSING LINE 11245
// MISSING LINE 11246
// MISSING LINE 11247
// MISSING LINE 11248
// MISSING LINE 11249
// MISSING LINE 11250
// MISSING LINE 11251
// MISSING LINE 11252
// MISSING LINE 11253
// MISSING LINE 11254
// MISSING LINE 11255
// MISSING LINE 11256
// MISSING LINE 11257
// MISSING LINE 11258
// MISSING LINE 11259
// MISSING LINE 11260
// MISSING LINE 11261
// MISSING LINE 11262
// MISSING LINE 11263
// MISSING LINE 11264
// MISSING LINE 11265
// MISSING LINE 11266
class _DirectRequestScreenState extends State<DirectRequestScreen> {
  final _msgCtrl = TextEditingController();
  final List<Uint8List> _photos = [];
  bool _sending = false;

  @override
  void dispose() {
    _msgCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    try {
                color: _g(0.05), border: Border.all(color: _g(0.1)),
              ),
              child: TextField(
                controller: _msgCtrl,
                maxLines: 4,
                style: TextStyle(color: _gw, fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Περίγραψε τι περιλαμβάνει η προσφορά σου...',
                  hintStyle: TextStyle(color: _g(0.25), fontSize: 12),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.all(14),
                ),
              ),
            ),
          ]),
        )),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: _PremiumButton(
            label: _sending ? 'Αποστολή...' : '💼 Στείλε Προσφορά',
            gradient: const LinearGradient(colors: [kGoldLight, kGold, kGoldDark]),
            textColor: Colors.black,
            onTap: _sending ? () {} : _sendOffer,
          ),
        ),
      ])),
    );
  }
}

// ════════════════════════════════════════════════
// EVENT ORGANIZER SCREEN  (G button)
// ════════════════════════════════════════════════
class EventOrganizerScreen extends StatefulWidget {
  const EventOrganizerScreen({super.key});
  @override
  State<EventOrganizerScreen> createState() => _EventOrganizerScreenState();
}

class _EventOrganizerScreenState extends State<EventOrganizerScreen> {
  int _step = 0; // 0=category, 1=details, 2=success
  String? _categoryId;
  String _categoryTitle = '';
  String _categoryEmoji = '';

  final _locationCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  int _guests = 50;
  double _budget = 3000;
  DateTime? _date;
        'professionalName': d['proName'] ?? '',
        'professionalId': proId,
        'price': offer['price'] ?? 0,
        'requestId': docId,
        'status': 'pending',
        'isImmediate': true,
        'scheduledTime': 'Άμεσα',
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (proId.isNotEmpty) {
    'Κορυδαλλός', 'Νίκαια', 'Κερατσίνι', 'Δραπετσώνα', 'Πειραιάς', 'Πέραμα', 'Σαλαμίνα',
    'Αχαρνές', 'Κρυονέρι', 'Διόνυσος', 'Ωρωπός', 'Μαραθώνας', 'Ραφήνα', 'Αρτέμιδα',
    'Μαρκόπουλο', 'Κορωπί', 'Παιανία', 'Κρόπια', 'Παλλήνη', 'Γέρακας', 'Ανθούσα',
    'Θεσσαλονίκη Κέντρο', 'Καλαμαριά', 'Πυλαία', 'Σταυρούπολη', 'Αμπελόκηποι Θεσσαλονίκης',
    'Ευόσμος', 'Κορδελιό', 'Νεάπολη Θεσσαλονίκης', 'Συκιές', 'Πολίχνη', 'Τριανδρία',
    'Νέα Μηχανιώνα', 'Θέρμη', 'Πάτρα', 'Αίγιο', 'Ηράκλειο Κρήτης', 'Χανιά', 'Ρέθυμνο',
    'Άγιος Νικόλαος', 'Λάρισα', 'Βόλος', 'Τρίκαλα', 'Καρδίτσα', 'Ιωάννινα', 'Άρτα',
    'Πρέβεζα', 'Λευκάδα', 'Κέρκυρα', 'Καβάλα', 'Δράμα', 'Σέρρες', 'Κιλκίς',
    'Αλεξανδρούπολη', 'Κομοτηνή', 'Ξάνθη', 'Ρόδος', 'Κως', 'Μυτιλήνη', 'Χίος', 'Σάμος',
  ];

  static const _categories = [
    {
      'id': 'wedding',
      'emoji': '💍',
      'title': 'Γάμος',
      'subtitle': 'Φωτογράφος · DJ · Catering · Αίθουσα · Ανθοπωλείο',
      'pros': ['Φωτογράφος', 'DJ', 'Catering', 'Αίθουσα', 'Ανθοδέτης'],
    },
    {
      'id': 'baptism',
      'emoji': '👶',
      'title': 'Βάφτιση',
      'subtitle': 'Φωτογράφος · Catering · Στολισμός · Μπομπονιέρες',
      'pros': ['Φωτογράφος', 'Catering', 'Στολιστής', 'Ανθοδέτης'],
    },
    {
      'id': 'party',
      'emoji': '🎉',
      'title': 'Πάρτυ',
      'subtitle': 'DJ · Catering · Στολισμός · Φωτογράφος',
      'pros': ['DJ', 'Catering', 'Στολιστής', 'Φωτογράφος'],
    },
  ];

  @override
  void dispose() {
    _locationCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    setState(() => _submitting = true);
    try {
      final cat = _categories.firstWhere((c) => c['id'] == _categoryId);
      await FirebaseFirestore.instance.collection('event_requests').add({
        'userId': user.uid,
        'category': _categoryId,
        'categoryTitle': cat['title'],
        'categoryEmoji': cat['emoji'],
        'location': _selectedArea ?? _locationCtrl.text.trim(),
        'guests': _guests,
        'budget': _budget.round(),
        'date': _date?.toIso8601String() ?? '',
        'notes': _notesCtrl.text.trim(),
        'status': 'active',
        'offers': [],
        'offersCount': 0,
        'prosNotified': 5,
        'expiresAt': Timestamp.fromDate(DateTime.now().add(const Duration(hours: 1))),
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) setState(() { _submitting = false; _step = 2; });
    } catch (_) {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          transitionBuilder: (child, anim) => SlideTransition(
            position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
                .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
            child: FadeTransition(opacity: anim, child: child),
          ),
          child: _step == 0 ? _buildCategoryPicker()
              : _step == 1 ? _buildDetailsForm()
              : _buildSuccess(),
        ),
      ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon,
                color:
                    active ? kGold : _g(0.3),
                size: 22),
            const SizedBox(height: 3),
            Text(label,
                style: TextStyle(
                    fontFamily: 'Raleway',
                    fontSize: 9,
                    color: active ? kGold : _g(0.3),
                    fontWeight: active
                        ? FontWeight.w600
                        : FontWeight.w400)),
            if (active) ...[
              const SizedBox(height: 3),
              Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: kGold,
                      boxShadow: [
                        BoxShadow(
                            color: kGold.withValues(alpha: 0.8), blurRadius: 6)
                      ])),
            ],
          ]),
        ),
      );
            userId: widget.userId,
            description: _textCtrl.text.trim(),
            criteria: _selectedCriteria,
            profession: _selectedTeamType ?? '',
            collection: 'project_requests',
          ),
          transitionsBuilder: (_, anim, __, child) =>
              FadeTransition(opacity: anim, child: child),
        ),
      );
    } catch (e) {
      setState(() => _sending = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Σφάλμα: $e')));
    }
  }

  Widget _buildPicker(String hint, String? value, List<String> items,
      void Function(String) onSelect) {
    return _TapScaleWidget(
      onTap: () async {
        final result = await showModalBottomSheet<String>(
                ]),
                const SizedBox(height: 12),
                if (portfolioProjects.isEmpty && legacyPhotos.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(14),
                        color: _g(0.04), border: Border.all(color: _g(0.08))),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Text('📷', style: TextStyle(fontSize: 28)),
                    ),
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 22),
  Future<void> _startStripeCheckout() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    setState(() => _stripeLoading = true);
    try {
      final res = await http.post(
        Uri.parse('$kBackendUrl/create-checkout-session'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'userId': user.uid, 'email': user.email ?? ''}),
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final url = jsonDecode(res.body)['url'] as String?;
        if (url != null && url.isNotEmpty) {
          await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
          if (mounted) {
            showDialog(context: context, builder: (ctx) => Dialog(
              backgroundColor: const Color(0xFF0D0A04),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: kGold.withValues(alpha: 0.3))),
              child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('💳', style: TextStyle(fontSize: 40)),
                const SizedBox(height: 12),
                const Text('Ολοκλήρωσε την πληρωμή', style: TextStyle(color: Colors.white, fontFamily: 'Raleway', fontWeight: FontWeight.w700, fontSize: 16)),
                const SizedBox(height: 8),
                Text('Μόλις πληρώσεις, πάτα "Ανανέωση" για να ενεργοποιηθεί το Premium.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 13, height: 1.5)),
                const SizedBox(height: 20),
                _PremiumButton(label: 'Ανανέωση', gradient: const LinearGradient(colors: [kGoldLight, kGold]), textColor: Colors.black, onTap: () async {
                  Navigator.pop(ctx);
                  await _loadProfile();
                }),
                const SizedBox(height: 8),
                TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Κλείσιμο', style: TextStyle(color: Colors.white.withValues(alpha: 0.4)))),
              ])),
            ));
          }
        }
      } else {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Σφάλμα σύνδεσης με Stripe')));
      }
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Σφάλμα. Δοκίμασε ξανά.')));
    }
    if (mounted) setState(() => _stripeLoading = false);
  }

  void _showEditDialog() {
    _nameCtrl.text = _name ?? '';
    _cityCtrl.text = _city ?? '';
    showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF111111),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(color: kGold.withValues(alpha: 0.2))),
              title: const Text('Επεξεργασία',
                  style: TextStyle(
                      color: Colors.white, fontFamily: 'Raleway')),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                _GoldTextField(
                    controller: _nameCtrl, label: 'Όνομα'),
// MISSING LINE 11553
// MISSING LINE 11554
// MISSING LINE 11555
// MISSING LINE 11556
// MISSING LINE 11557
// MISSING LINE 11558
// MISSING LINE 11559
// MISSING LINE 11560
// MISSING LINE 11561
// MISSING LINE 11562
// MISSING LINE 11563
// MISSING LINE 11564
// MISSING LINE 11565
// MISSING LINE 11566
// MISSING LINE 11567
// MISSING LINE 11568
// MISSING LINE 11569
// MISSING LINE 11570
// MISSING LINE 11571
// MISSING LINE 11572
// MISSING LINE 11573
// MISSING LINE 11574
// MISSING LINE 11575
// MISSING LINE 11576
// MISSING LINE 11577
// MISSING LINE 11578
// MISSING LINE 11579
// MISSING LINE 11580
// MISSING LINE 11581
// MISSING LINE 11582
// MISSING LINE 11583
// MISSING LINE 11584
// MISSING LINE 11585
// MISSING LINE 11586
class _OfferCardState extends State<_OfferCard> {
  String get _name => (widget.offer['name'] ?? widget.offer['professionalName'] ?? 'Επαγγελματίας').toString();
  String get _emoji => (widget.offer['emoji'] ?? '🔧').toString();
  String get _specialty => (widget.offer['specialty'] ?? widget.offer['message'] ?? '').toString();
  double get _price => (widget.offer['price'] is num) ? (widget.offer['price'] as num).toDouble() : 0.0;
  double get _rating => (widget.offer['rating'] is num) ? (widget.offer['rating'] as num).toDouble() : 4.8;
  String get _available => (widget.offer['available'] ?? widget.offer['availableFrom'] ?? 'Σύντομα').toString();
  int get _rank => (widget.offer['rank'] is num) ? (widget.offer['rank'] as num).toInt() : 1;
  String get _photoUrl => (widget.offer['profilePhotoUrl'] ?? '').toString();

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: widget.isBest
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [kGold.withValues(alpha: 0.1), kGold.withValues(alpha: 0.02)])
              : null,
          color: widget.isBest ? null : _g(0.04),
          border: Border.all(color: widget.isBest
              ? kGold.withValues(alpha: 0.3)
              : _g(0.06)),
        ),
        child: Stack(children: [
          if (widget.isBest)
            Positioned(top: 0, left: 20, right: 20,
                child: Container(height: 1,
                  decoration: const BoxDecoration(gradient: LinearGradient(
                      colors: [Colors.transparent, kGold, Colors.transparent])))),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Align(
                alignment: Alignment.centerRight,
                child: widget.isBest
                    ? Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          gradient: const LinearGradient(colors: [kGoldLight, kGold]),
                          boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.4), blurRadius: 10)],
                        ),
                        child: const Text('🏆 #1 ΚΑΛΥΤΕΡΗ',
                            style: TextStyle(color: Colors.black,
                                fontSize: 9, fontWeight: FontWeight.w800)))
                    : Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8),
                            color: _g(0.06)),
                        child: Text('#$_rank', style: TextStyle(
                            color: _g(0.35),
                            fontSize: 10, fontWeight: FontWeight.w600))),
              ),

              const SizedBox(height: 10),

              Row(children: [
                // Profile photo (56x56 circle)
                Container(
                    width: 56, height: 56,
class _DirectRequestScreenState extends State<DirectRequestScreen> {
  final _msgCtrl = TextEditingController();
  final List<Uint8List> _photos = [];
  bool _sending = false;
  String _userName = '';

  @override
  void initState() {
    super.initState();
    // Pre-fetch user name so _send() doesn't block on it
    _loadUserName();
  }

  Future<void> _loadUserName() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      if (mounted) setState(() => _userName = (doc.data()?['name'] as String?) ?? '');
    } catch (_) {}
  }

  @override
  void dispose() {
    _msgCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    try {
      final picker = ImagePicker();
      final xf = await picker.pickImage(source: ImageSource.gallery, imageQuality: 75);
      if (xf == null) return;
      final bytes = await xf.readAsBytes();
      if (mounted) setState(() => _photos.add(bytes));
    } catch (_) {}
  }

  Future<void> _send() async {
    final msg = _msgCtrl.text.trim();
    if (msg.isEmpty && _photos.isEmpty) return;
    if (_sending) return;
    setState(() => _sending = true);

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) { if (mounted) setState(() => _sending = false); return; }

    final userName = _userName.isNotEmpty ? _userName : 'Χρήστης';
    final pro = widget.pro;
    final proId = (pro['userId'] ?? pro['uid'] ?? pro['id'] ?? '') as String;
    final proName = (pro['name'] ?? pro['displayName'] ?? 'Επαγγελματίας') as String;
    final chatId = '${user.uid}_$proId';

    try {
      // Upload photos (small, keep sync)
      final List<String> photoUrls = [];
      for (int i = 0; i < _photos.length; i++) {
        try {
          final ref = FirebaseStorage.instance
              .ref('chat_photos/${user.uid}/${DateTime.now().millisecondsSinceEpoch}_$i.jpg');
          await ref.putData(_photos[i], SettableMetadata(contentType: 'image/jpeg'));
          photoUrls.add(await ref.getDownloadURL());
        } catch (_) {}
      }

      final msgText = msg.isNotEmpty
          ? (photoUrls.isNotEmpty ? '$msg\n📷 ${photoUrls.length} φωτογραφίες' : msg)
          : '📷 ${photoUrls.length} φωτογραφίες';

      final db = FirebaseFirestore.instance;

      // Run chat-doc update and message-add in parallel
      await Future.wait([
        db.collection('chats').doc(chatId).set({
          'userId': user.uid,
          'proId': proId,
          'userName': userName,
          'proName': proName,
          'lastMessage': msgText,
          'lastMessageAt': FieldValue.serverTimestamp(),
          'unreadUser': 0,
          'unreadPro': FieldValue.increment(1),
        }, SetOptions(merge: true)),
        db.collection('chats').doc(chatId).collection('messages').add({
          'senderId': user.uid,
          'senderName': userName,
          'text': msgText,
          'photoUrls': photoUrls,
          'videoUrls': <String>[],
          'createdAt': FieldValue.serverTimestamp(),
        }),
      ]);

      // Notification + FCM push — fire and forget
      if (proId.isNotEmpty) {
        Future(() async {
          try {
            await db.collection('users').doc(proId).collection('notifications').add({
              'title': '💬 Νέο μήνυμα από $userName',
              'body': msg.isNotEmpty ? msg : '${photoUrls.length} φωτογραφίες',
              'type': 'direct_chat',
              'chatId': chatId,
              'userId': user.uid,
              'userName': userName,
              'isRead': false,
              'createdAt': FieldValue.serverTimestamp(),
            });
            // FCM push
            final proUserDoc = await db.collection('users').doc(proId).get();
            final fcmToken = proUserDoc.data()?['fcmToken'] as String?;
            if (fcmToken != null && fcmToken.isNotEmpty) {
              await http.post(
                Uri.parse('$kBackendUrl/notify-chat-message'),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({
                  'fcmToken': fcmToken,
class ChatScreen extends StatefulWidget {
  final String chatId;       // "${userId}_${proId}"
  final String currentUserId;
  final String currentUserName;
  final String otherName;
  final bool isPro;          // true = current user is the professional
  const ChatScreen({
    super.key,
    required this.chatId,
    required this.currentUserId,
    required this.currentUserName,
    required this.otherName,
    required this.isPro,
  });
  @override
  State<ChatScreen> createState() => _ChatScreenState();
      // Fetch user's display name
      String userName = 'Χρήστης';
      try {
        final uDoc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
        userName = uDoc.data()?['name'] as String? ?? user.displayName ?? 'Χρήστης';
      } catch (_) {}
      await FirebaseFirestore.instance.collection('event_requests').add({
        'userId': user.uid,
        'userName': userName,
        'category': _categoryId,
        'categoryTitle': cat['title'],
        'categoryEmoji': cat['emoji'],
        'location': _selectedArea ?? _locationCtrl.text.trim(),
        'guests': _guests,
        'budget': _budget.round(),
        'date': _date?.toIso8601String() ?? '',
        'notes': _notesCtrl.text.trim(),
        'status': 'active',
        'offersCount': 0,
        'submittedPros': [],
        'prosNotified': 5,
        'expiresAt': Timestamp.fromDate(DateTime.now().add(const Duration(hours: 1))),
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) setState(() { _submitting = false; _step = 2; });
    } catch (_) {
      if (mounted) setState(() => _submitting = false);
    }
  }

  }

  Future<void> _markAsRead() async {
    try {
  final String text;
  final bool green;
  const _OfferTag({required this.text, required this.green});
  @override
      if (mounted) setState(() => _selectedImages.add(bytes));
    } catch (_) {}
  }

  Future<void> _pickVideo() async {
    try {
      final picker = ImagePicker();
      final xf = await picker.pickVideo(source: ImageSource.gallery);
      if (xf == null) return;
      if (mounted) setState(() {
        _selectedVideoFiles.add(xf);
        _selectedVideoNames.add(xf.name);
      });
    } catch (_) {}
  }

  Future<void> _sendMessage() async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty && _selectedImages.isEmpty && _selectedVideoFiles.isEmpty) return;
    if (_sending) return;
    _msgCtrl.clear();
    setState(() => _sending = true);

    try {
      // Upload images
      final List<String> photoUrls = [];
      for (int i = 0; i < _selectedImages.length; i++) {
        try {
          final ref = FirebaseStorage.instance.ref(
              'chat_media/${widget.chatId}/${DateTime.now().millisecondsSinceEpoch}_img_$i.jpg');
          await ref.putData(_selectedImages[i], SettableMetadata(contentType: 'image/jpeg'));
          photoUrls.add(await ref.getDownloadURL());
        } catch (_) {}
      }
      // Upload videos
      final List<String> videoUrls = [];
      for (int i = 0; i < _selectedVideoFiles.length; i++) {
        try {
          final xf = _selectedVideoFiles[i] as XFile;
          final bytes = await xf.readAsBytes();
          final ext = xf.name.split('.').last;
          final ref = FirebaseStorage.instance.ref(
              'chat_media/${widget.chatId}/${DateTime.now().millisecondsSinceEpoch}_vid_$i.$ext');
          await ref.putData(bytes, SettableMetadata(contentType: 'video/$ext'));
          videoUrls.add(await ref.getDownloadURL());
        } catch (_) {}
      }

      // Build preview text for metadata
      String previewText = text;
      if (photoUrls.isNotEmpty && text.isEmpty) previewText = '📷 ${photoUrls.length} φωτογραφία';
      if (videoUrls.isNotEmpty && text.isEmpty) previewText = '🎥 Βίντεο';
      if ((photoUrls.isNotEmpty || videoUrls.isNotEmpty) && text.isNotEmpty) {
        previewText = text;
      }

      final chatRef = FirebaseFirestore.instance.collection('chats').doc(widget.chatId);
      await chatRef.collection('messages').add({
        'text': text,
        'photoUrls': photoUrls,
        'videoUrls': videoUrls,
        'senderId': widget.currentUserId,
        'senderName': widget.currentUserName,
        'createdAt': FieldValue.serverTimestamp(),
      });
      final unreadField = widget.isPro ? 'unreadUser' : 'unreadPro';
      await chatRef.set({
        'lastMessage': previewText,
        'lastMessageAt': FieldValue.serverTimestamp(),
        unreadField: FieldValue.increment(1),
        widget.isPro ? 'unreadPro' : 'unreadUser': 0,
      }, SetOptions(merge: true));

      if (mounted) setState(() {
        _selectedImages.clear();
        _selectedVideoFiles.clear();
        _selectedVideoNames.clear();
      });
      await Future.delayed(const Duration(milliseconds: 100));
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    } catch (_) {}
    if (mounted) setState(() => _sending = false);
    setState(() => _submitting = true);
    try {
      final cat = _categories.firstWhere((c) => c['id'] == _categoryId);
      // Fetch user's display name
      String userName = 'Χρήστης';
      try {
        final uDoc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
        userName = uDoc.data()?['name'] as String? ?? user.displayName ?? 'Χρήστης';
      } catch (_) {}
      await FirebaseFirestore.instance.collection('event_requests').add({
        'userId': user.uid,
        'userName': userName,
        'category': _categoryId,
        'categoryTitle': cat['title'],
        'categoryEmoji': cat['emoji'],
        'categoryPros': List<String>.from(cat['pros'] as List),
        'location': _selectedArea ?? _locationCtrl.text.trim(),
        'guests': _guests,
        'budget': _budget.round(),
        'date': _date?.toIso8601String() ?? '',
        'notes': _notesCtrl.text.trim(),
        'status': 'active',
        'offersCount': 0,
        'submittedPros': [],
        'prosNotified': 5,
        'expiresAt': Timestamp.fromDate(DateTime.now().add(const Duration(hours: 1))),
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) setState(() { _submitting = false; _step = 2; });
    } catch (_) {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: AnimatedSwitcher(
        _selectedVideoFiles.clear();
        _selectedVideoNames.clear();
// MISSING LINE 11947
// MISSING LINE 11948
// MISSING LINE 11949
// MISSING LINE 11950
// MISSING LINE 11951
// MISSING LINE 11952
// MISSING LINE 11953
// MISSING LINE 11954
// MISSING LINE 11955
// MISSING LINE 11956
// MISSING LINE 11957
// MISSING LINE 11958
// MISSING LINE 11959
// ═══════════════════════════════════════
const List<Map<String, dynamic>> _specialtyCategories = [
  {
    'category': 'Τεχνικοί',
    'items': [
      'Ηλεκτρολόγος', 'Υδραυλικός', 'Ψυκτικός', 'Ελαιοχρωματιστής',
      'Μηχανικός', 'Κτίστης', 'Ξυλουργός', 'Υαλουργός',
      'Τεχνικός Ανελκυστήρων', 'Αποφράξεις', 'Αλουμινάς', 'Πλακάς',
      'Συντήρηση Κλιματιστικών', 'Εγκατάσταση Ηλιακών'
    ]
  },
  {
    'category': 'Υγεία',
    'items': [
      'Παθολόγος', 'Παιδίατρος', 'Οδοντίατρος', 'Φυσιοθεραπευτής',
      'Ψυχολόγος', 'Διατροφολόγος', 'Νοσηλευτής κατ\' οίκον'
    ]
  },
  {
    'category': 'Σπίτι',
    'items': ['Καθαρίστρια', 'Κηπουρός', 'Baby Sitter', 'Μετακομίσεις']
  },
  {
    'category': 'Εκπαίδευση',
    'items': [
      'Καθηγητής Μαθηματικών',
      'Καθηγητής Αγγλικών',
      'Personal Trainer'
    ]
  },
  {
    'category': 'Ψηφιακές',
    'items': [
      'Web Developer',
      'Γραφίστας',
      'Φωτογράφος',
      'Τεχνικός Υπολογιστών'
    ]
  },
  {
    'category': 'Άλλα',
    'items': ['Μηχανικός Αυτοκινήτων', 'Λογιστής', 'Δικηγόρος', 'Αρχιτέκτονας']
  },
  {
    'category': 'Συνεργεία',
    'items': [
      'Συνεργείο Ανακαίνισης',
      'Συνεργείο Κατασκευών',
      'Συνεργείο Βαφής & Διακόσμησης',
      'Συνεργείο Ηλεκτρολόγων',
      'Συνεργείο Υδραυλικών',
      'Συνεργείο Κλιματισμού',
      'Συνεργείο Αλουμινίου & Κουφωμάτων',
      'Συνεργείο Πλακιδίων & Δαπέδων',
      'Συνεργείο Κήπου & Εξωτερικών Χώρων',
      'Συνεργείο Γυψοσανίδας & Οροφής',
      'Συνεργείο Ξυλουργικών Εργασιών',
    ]
  },
];

class _SpecialtyPicker extends StatefulWidget {
  const _SpecialtyPicker();
  @override
  State<_SpecialtyPicker> createState() => _SpecialtyPickerState();
  Future<void> _markAsRead() async {
    try {
      final field = widget.isPro ? 'unreadPro' : 'unreadUser';
      await FirebaseFirestore.instance
          .collection('chats').doc(widget.chatId)
          .set({field: 0}, SetOptions(merge: true));
      // If pro is reading, also clear any bell notifications tied to this chat
      if (widget.isPro) {
        final notifSnap = await FirebaseFirestore.instance
            .collection('users').doc(widget.currentUserId)
            .collection('notifications')
            .where('chatId', isEqualTo: widget.chatId)
            .where('isRead', isEqualTo: false)
            .get();
        for (final n in notifSnap.docs) {
          n.reference.update({'isRead': true}).catchError((_) {});
        }
      }
    } catch (_) {}
  }

  Future<void> _pickImage() async {
    try {
      final picker = ImagePicker();
      final xf = await picker.pickImage(source: ImageSource.gallery, imageQuality: 75);
      if (xf == null) return;
      final bytes = await xf.readAsBytes();
      if (mounted) setState(() => _selectedImages.add(bytes));
    } catch (_) {}
  }

  Future<void> _pickVideo() async {
    try {
      final picker = ImagePicker();
      final xf = await picker.pickVideo(source: ImageSource.gallery);
      if (xf == null) return;
      if (mounted) setState(() {
        _selectedVideoFiles.add(xf);
        _selectedVideoNames.add(xf.name);
      });
    } catch (_) {}
  }

  Future<void> _sendMessage() async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty && _selectedImages.isEmpty && _selectedVideoFiles.isEmpty) return;
    if (_sending) return;
    _msgCtrl.clear();
    setState(() => _sending = true);

    try {
      // Upload images
      final List<String> photoUrls = [];
      for (int i = 0; i < _selectedImages.length; i++) {
        try {
          final ref = FirebaseStorage.instance.ref(
              'chat_media/${widget.chatId}/${DateTime.now().millisecondsSinceEpoch}_img_$i.jpg');
          await ref.putData(_selectedImages[i], SettableMetadata(contentType: 'image/jpeg'));
          photoUrls.add(await ref.getDownloadURL());
        } catch (_) {}
      }
      // Upload videos
      final List<String> videoUrls = [];
      for (int i = 0; i < _selectedVideoFiles.length; i++) {
        try {
          final xf = _selectedVideoFiles[i] as XFile;
          final bytes = await xf.readAsBytes();
          final ext = xf.name.split('.').last;
          final ref = FirebaseStorage.instance.ref(
              'chat_media/${widget.chatId}/${DateTime.now().millisecondsSinceEpoch}_vid_$i.$ext');
          await ref.putData(bytes, SettableMetadata(contentType: 'video/$ext'));
          videoUrls.add(await ref.getDownloadURL());
        } catch (_) {}
      }

      // Build preview text for metadata
      String previewText = text;
      if (photoUrls.isNotEmpty && text.isEmpty) previewText = '📷 ${photoUrls.length} φωτογραφία';
      if (videoUrls.isNotEmpty && text.isEmpty) previewText = '🎥 Βίντεο';
      if ((photoUrls.isNotEmpty || videoUrls.isNotEmpty) && text.isNotEmpty) {
        previewText = text;
      }

      final chatRef = FirebaseFirestore.instance.collection('chats').doc(widget.chatId);
      await chatRef.collection('messages').add({
        'text': text,
        'photoUrls': photoUrls,
        'videoUrls': videoUrls,
        'senderId': widget.currentUserId,
        'senderName': widget.currentUserName,
        'createdAt': FieldValue.serverTimestamp(),
      });
      final unreadField = widget.isPro ? 'unreadUser' : 'unreadPro';
      await chatRef.set({
        'lastMessage': previewText,
        'lastMessageAt': FieldValue.serverTimestamp(),
        unreadField: FieldValue.increment(1),
        widget.isPro ? 'unreadPro' : 'unreadUser': 0,
      }, SetOptions(merge: true));

      // Send push notification to the other party
      Future(() async {
        try {
          final chatDoc = await chatRef.get();
          final chatData = chatDoc.data() as Map<String, dynamic>?;
          if (chatData == null) return;
          // Determine the other party's userId
          final otherUserId = widget.isPro
              ? (chatData['userId'] as String? ?? '')
              : (chatData['proId'] as String? ?? '');
          if (otherUserId.isEmpty) return;
          final otherUserDoc = await FirebaseFirestore.instance
              .collection('users').doc(otherUserId).get();
          final fcmToken = otherUserDoc.data()?['fcmToken'] as String?;
          if (fcmToken == null || fcmToken.isEmpty) return;
          await http.post(
            Uri.parse('$kBackendUrl/notify-chat-message'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'fcmToken': fcmToken,
              'senderName': widget.currentUserName,
              'messagePreview': previewText,
            }),
          );
        } catch (e) {
          debugPrint('Chat push notification error: $e');
        }
      });

      if (mounted) setState(() {
        _selectedImages.clear();
        _selectedVideoFiles.clear();
        _selectedVideoNames.clear();
      });
      await Future.delayed(const Duration(milliseconds: 100));
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    } catch (_) {}
    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(children: [
          // ── Header ──
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: kBg,
              border: Border(bottom: BorderSide(color: kGold.withValues(alpha: 0.12))),
              } catch (_) {}
            }
            if (videoUrls.isNotEmpty) {
              await msgRef.update({'videoUrls': videoUrls, 'videoUploading': false});
            }
          } catch (_) {}
        });
      }
  @override
  void initState() {
    super.initState();
    _loadPros();
  }

  Future<void> _loadPros() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('professionals')
          .where('is_active', isEqualTo: true)
          .limit(30)
          .get();
      if (!mounted) return;
      setState(() {
        _pros = snap.docs.map((d) => {'id': d.id, ...d.data()}).toList();
        _prosLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _prosLoading = false);
              'senderName': widget.currentUserName,
              'messagePreview': previewText,
            }),
          ).timeout(const Duration(seconds: 55));
        } catch (e) {
          debugPrint('Chat push notification error: $e');
        }
      });

      return; // _sending already set to false above
    } catch (_) {}
    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(children: [
          // ── Header ──
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: kBg,
              border: Border(bottom: BorderSide(color: kGold.withValues(alpha: 0.12))),
            ),
            child: Row(children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(width: 36, height: 36,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: _g(0.06)),
                    child: const Icon(Icons.arrow_back_ios_new, color: kGold, size: 16)),
              ),
              const SizedBox(width: 12),
              Container(width: 38, height: 38,
                decoration: BoxDecoration(shape: BoxShape.circle,
                    color: kGold.withValues(alpha: 0.12),
                    border: Border.all(color: kGold.withValues(alpha: 0.3))),
                child: Center(child: Text(
                    widget.otherName.isNotEmpty ? widget.otherName[0].toUpperCase() : '?',
                    style: const TextStyle(color: kGold, fontSize: 16, fontWeight: FontWeight.w800))),
              ),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.otherName, style: const TextStyle(color: Colors.white,
                    fontSize: 15, fontWeight: FontWeight.w700)),
                Text(widget.isPro ? 'Πελάτης' : 'Επαγγελματίας',
                    style: TextStyle(color: _g(0.35), fontSize: 11)),
              ])),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(8),
                    color: kGreen.withValues(alpha: 0.1),
                    border: Border.all(color: kGreen.withValues(alpha: 0.3))),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 5, height: 5,
                      decoration: const BoxDecoration(shape: BoxShape.circle, color: kGreen)),
                  const SizedBox(width: 5),
                  const Text('Online', style: TextStyle(color: kGreen, fontSize: 10, fontWeight: FontWeight.w600)),
                ]),
              ),
            ]),
          ),

          // ── Messages list ──
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('chats').doc(widget.chatId)
                  .collection('messages')
                  .orderBy('createdAt', descending: false)
                  .snapshots(),
              builder: (ctx, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator(color: kGold));
                }
                final msgs = snap.data!.docs;
                if (msgs.isEmpty) {
                  return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text('💬', style: TextStyle(fontSize: 40)),
                    const SizedBox(height: 12),
                    Text('Ξεκίνα τη συνομιλία!',
                        style: TextStyle(color: _g(0.4), fontSize: 14)),
                    const SizedBox(height: 6),
                    Text('Στείλε το πρώτο μήνυμα παρακάτω.',
                        style: TextStyle(color: _g(0.25), fontSize: 12)),
                  ]));
                }
                // Auto-scroll on new messages
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_scrollCtrl.hasClients) {
                    _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
                  }
                });
                return ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  itemCount: msgs.length,
                  itemBuilder: (_, i) {
                    final d = msgs[i].data() as Map<String, dynamic>;
                    final isMine = d['senderId'] == widget.currentUserId;
                    final text = d['text'] as String? ?? '';
                    final ts = d['createdAt'] as Timestamp?;
                    final timeStr = ts != null
                        ? '${ts.toDate().hour.toString().padLeft(2,'0')}:${ts.toDate().minute.toString().padLeft(2,'0')}'
                        : '';
                    final photoUrls = List<String>.from(d['photoUrls'] ?? []);
                    final videoUrls = List<String>.from(d['videoUrls'] ?? []);
                    final hasMedia = photoUrls.isNotEmpty || videoUrls.isNotEmpty;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                    value: '',
                    iconColor: Colors.red,
                    textColor: Colors.red,
                    borderColor: Colors.red.withValues(alpha: 0.2),
                    bgColor: Colors.red.withValues(alpha: 0.06),
                    onTap: () async {
                      await FirebaseAuth.instance.signOut();
                      await AuthService.logout();
                      if (mounted) {
                        Navigator.of(context).popUntil((r) => r.isFirst);
                      }
                    },
                  ),
                  const SizedBox(height: 40),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════
// NOTIFICATIONS SCREEN
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .doc(userId)
                  .collection('selectedProfessionals')
                  .limit(30)
                  .snapshots(),
              builder: (context, snap) {
                if (snap.hasError || snap.connectionState == ConnectionState.done && !snap.hasData)
                  return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.history_outlined, color: _g(0.15), size: 52),
                    const SizedBox(height: 12),
                    Text('Δεν βρέθηκε ιστορικό', style: TextStyle(color: _g(0.3), fontSize: 14)),
                  ]));
                if (!snap.hasData)
                  return const Center(
                      child: CircularProgressIndicator(color: kGold));
                final rawDocs = snap.data!.docs.toList()
                  ..sort((a, b) {
                    int getMs(dynamic doc) {
                      try {
                        final data = doc.data() as Map<String, dynamic>;
                        final ts = data['selectedAt'];
                        if (ts == null) return 0;
                        return (ts as Timestamp).toDate().millisecondsSinceEpoch;
                      } catch (_) { return 0; }
                    }
                    return getMs(b).compareTo(getMs(a));
                  });
                final docs = rawDocs;
                if (docs.isEmpty) {
                  return Center(
                      child:
                          Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.person_outline,
                        color: _g(0.15),
                        size: 52),
                    const SizedBox(height: 12),
                    Text('Δεν έχεις επιλέξει επαγγελματία ακόμα',
                        style: TextStyle(
                            color: _g(0.3),
                            fontSize: 14)),
                  ]));
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                  itemCount: docs.length,
                  itemBuilder: (_, i) {
                    final d = docs[i].data() as Map<String, dynamic>;
                    final proName = d['professionalName'] as String? ?? '';
                    final specialty = d['specialty'] as String? ?? '';
                    final emoji = d['emoji'] as String? ?? '🔧';
                    final price = d['price'];
                    final priceStr = price != null ? '${price}€' : '';
                    final requestDesc = d['requestDescription'] as String? ?? '';
                    final ts = d['selectedAt'] as Timestamp?;
                    final date = ts != null ? ts.toDate() : DateTime.now();
                    final dateStr = '${date.day}/${date.month}/${date.year}';

                    return Dismissible(
                      key: Key(docs[i].id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          color: Colors.red.withValues(alpha: 0.15),
                        ),
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        child: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 22),
                      ),
                      confirmDismiss: (_) async {
                        return await showDialog<bool>(
                          context: context,
                          builder: (_) => AlertDialog(
                            backgroundColor: const Color(0xFF1A1A1A),
                            title: Text('Διαγραφή;', style: TextStyle(color: _gw, fontSize: 16)),
                            content: Text('Να διαγραφεί η επιλογή "$proName";',
                                style: TextStyle(color: _g(0.6), fontSize: 13)),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(context, false),
                                  child: Text('Άκυρο', style: TextStyle(color: _g(0.5)))),
                              TextButton(onPressed: () => Navigator.pop(context, true),
                                  child: const Text('Διαγραφή', style: TextStyle(color: Colors.redAccent))),
                            ],
                          ),
                        ) ?? false;
                      },
                      onDismissed: (_) => docs[i].reference.delete(),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(14),
                        decoration: _glassCard(radius: 16, gold: true),
                        child: Row(children: [
                          Container(
                              width: 44, height: 44,
                              decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                Text('Αξιολογήθηκε', style: TextStyle(fontSize: 7, color: kGold.withValues(alpha: 0.7))),
                              ])
                            else
                              GestureDetector(
                                onTap: () async {
                                  final result = await showDialog<Map<String, dynamic>>(
                                    context: context,
                                    builder: (_) => _RatingDialog(proName: proName),
                                  );
                                  if (result != null && context.mounted) {
                                    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
                                    await _submitRating(
                                      context: context,
                                      selectionDocId: docs[i].id,
                                      userId: uid,
                                      proId: d['professionalId'] as String? ?? '',
                                      proName: proName,
                                      requestId: d['requestId'] as String? ?? '',
                                      rating: result['rating'] as int,
                                      comment: result['comment'] as String? ?? '',
                                    );
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(content: Text('✅ Η αξιολόγησή σου υποβλήθηκε!')));
                                    }
                                  }
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                  decoration: BoxDecoration(
                            GestureDetector(
                              onTap: () {
                                final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
                                final proId = d['professionalId'] as String? ?? '';
                                if (uid.isEmpty || proId.isEmpty) return;
                                final chatId = '${uid}_$proId';
                                Navigator.push(context, PageRouteBuilder(
                                  pageBuilder: (_, __, ___) => ChatScreen(
                                    chatId: chatId,
                                    currentUserId: uid,
                                    currentUserName: '',
                                    otherName: proName,
                                    isPro: false,
                                  ),
                                  transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
                                  transitionDuration: const Duration(milliseconds: 300),
                                ));
                                // Ensure chat document exists
                                FirebaseFirestore.instance.collection('chats').doc(chatId)
                                    .set({
                                  'userId': uid,
                                  'proId': proId,
                                  'userName': '',
                                  'proName': proName,
                                  'lastMessageAt': FieldValue.serverTimestamp(),
                                }, SetOptions(merge: true)).catchError((_) {});
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  gradient: const LinearGradient(colors: [kGoldLight, kGold]),
                                ),
                                child: const Text('💬 Chat',
                                    style: TextStyle(color: Colors.black, fontSize: 9, fontWeight: FontWeight.w800)),
                              ),
                            ),
                            const SizedBox(height: 5),
                            if (d['rated'] == true)
                              Column(mainAxisSize: MainAxisSize.min, children: [
                                Row(mainAxisSize: MainAxisSize.min,
                                    children: List.generate(d['myRating'] as int? ?? 5, (_) =>
                                        const Icon(Icons.star_rounded, color: kGold, size: 10))),
                                const SizedBox(height: 2),
                                Text('Αξιολογήθηκε', style: TextStyle(fontSize: 7, color: kGold.withValues(alpha: 0.7))),
                              ])
                            else
                              GestureDetector(
                                onTap: () async {
                                  final result = await showDialog<Map<String, dynamic>>(
                                    context: context,
                                    builder: (_) => _RatingDialog(proName: proName),
                                  );
                                  if (result != null && context.mounted) {
                                    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
                                    await _submitRating(
                                      context: context,
                                      selectionDocId: docs[i].id,
                                      userId: uid,
                                      proId: d['professionalId'] as String? ?? '',
                                      proName: proName,
                                      requestId: d['requestId'] as String? ?? '',
                                      rating: result['rating'] as int,
                                      comment: result['comment'] as String? ?? '',
                                    );
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(content: Text('✅ Η αξιολόγησή σου υποβλήθηκε!')));
                                    }
                                  }
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: kGold.withValues(alpha: 0.4)),
                                    color: kGold.withValues(alpha: 0.08),
                                  ),
                                  child: const Text('⭐ Αξιολόγησε',
                                      style: TextStyle(color: kGold, fontSize: 9, fontWeight: FontWeight.w700)),
                                ),
                              ),
                            const SizedBox(height: 4),
                            Text('σύρε→', style: TextStyle(fontSize: 8, color: _g(0.25))),
                          ]),
                final ext = xf.name.split('.').last;
                final ref = FirebaseStorage.instance.ref(
                    'chat_media/${widget.chatId}/${DateTime.now().millisecondsSinceEpoch}_vid_$i.$ext');
                await ref.putData(bytes, SettableMetadata(contentType: 'video/$ext'));
                videoUrls.add(await ref.getDownloadURL());
              } catch (_) {}
            }
            if (videoUrls.isNotEmpty) {
              await msgRef.update({'videoUrls': videoUrls, 'videoUploading': false});
            }
          } catch (_) {}
        });
      }

      // ── Send push notification to the other party (background) ──
      Future(() async {
        try {
          final chatDoc = await chatRef.get();
          final chatData = chatDoc.data() as Map<String, dynamic>?;
          if (chatData == null) return;
          final otherUserId = widget.isPro
              ? (chatData['userId'] as String? ?? '')
              : (chatData['proId'] as String? ?? '');
          if (otherUserId.isEmpty) return;
          final otherUserDoc = await FirebaseFirestore.instance
              .collection('users').doc(otherUserId).get();
          final fcmToken = otherUserDoc.data()?['fcmToken'] as String?;
          if (fcmToken == null || fcmToken.isEmpty) return;
          await http.post(
            Uri.parse('$kBackendUrl/notify-chat-message'),
// MISSING LINE 12590
// MISSING LINE 12591
// MISSING LINE 12592
// MISSING LINE 12593
// MISSING LINE 12594
// MISSING LINE 12595
// MISSING LINE 12596
// MISSING LINE 12597
// MISSING LINE 12598
// MISSING LINE 12599
// MISSING LINE 12600
// MISSING LINE 12601
// MISSING LINE 12602
// MISSING LINE 12603
// MISSING LINE 12604
// MISSING LINE 12605
// MISSING LINE 12606
// MISSING LINE 12607
// MISSING LINE 12608
// MISSING LINE 12609
// MISSING LINE 12610
// MISSING LINE 12611
// MISSING LINE 12612
// MISSING LINE 12613
Future<void> _submitRating({
  required BuildContext context,
  required String selectionDocId,
  required String userId,
  required String proId,
  required String proName,
  required String requestId,
  required int rating,
  required String comment,
}) async {
  try {
    // 1. Save review
    await FirebaseFirestore.instance.collection('reviews').add({
      'rating': rating,
      'comment': comment,
      'userId': userId,
      'proId': proId,
      'proName': proName,
      'requestId': requestId,
      'createdAt': FieldValue.serverTimestamp(),
    });
    // 2. Update pro's averageRating + reviewCount (transaction)
    if (proId.isNotEmpty) {
      final proRef = FirebaseFirestore.instance.collection('users').doc(proId);
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(proRef);
        final data = snap.data() ?? {};
        final oldCount = ((data['reviewCount'] ?? 0) as num).toInt();
        final oldAvg = ((data['averageRating'] ?? 0) as num).toDouble();
        final newCount = oldCount + 1;
        final newAvg = ((oldAvg * oldCount) + rating) / newCount;
        tx.update(proRef, {'reviewCount': newCount, 'averageRating': newAvg});
      });
    }
    // 3. Mark selectedProfessionals doc as rated
    if (userId.isNotEmpty && selectionDocId.isNotEmpty) {
      await FirebaseFirestore.instance
          .collection('users').doc(userId)
          .collection('selectedProfessionals').doc(selectionDocId)
          .update({'rated': true, 'myRating': rating});
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Σφάλμα αξιολόγησης: $e')));
    }
  }
}

// ═══════════════════════════════════════
// AI MEMORY SCREEN
// ═══════════════════════════════════════
class AiMemoryScreen extends StatefulWidget {
  final String userId;
  const AiMemoryScreen({super.key, required this.userId});
  @override
  State<AiMemoryScreen> createState() => _AiMemoryScreenState();
}

class _AiMemoryScreenState extends State<AiMemoryScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  final _stt = stt.SpeechToText();
  bool _listening = false;
  String _buffer = '';
  bool _processing = false;

  final _tabs = const [
    {'label': '📋 Όλα', 'category': 'all'},
    {'label': '✅ To-Do', 'category': 'todo'},
    {'label': '🛒 Αγορές', 'category': 'shopping'},
    {'label': '📅 Ραντεβού', 'category': 'appointment'},
    {'label': '📝 Σημειώσεις', 'category': 'note'},
  ];

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: _tabs.length, vsync: this);
  }
// MISSING LINE 12694
// MISSING LINE 12695
// MISSING LINE 12696
// MISSING LINE 12697
// MISSING LINE 12698
// MISSING LINE 12699
// MISSING LINE 12700
// MISSING LINE 12701
// MISSING LINE 12702
// MISSING LINE 12703
// MISSING LINE 12704
// MISSING LINE 12705
// MISSING LINE 12706
// MISSING LINE 12707
// MISSING LINE 12708
// MISSING LINE 12709
// MISSING LINE 12710
// MISSING LINE 12711
// MISSING LINE 12712
// MISSING LINE 12713
// MISSING LINE 12714
// MISSING LINE 12715
// MISSING LINE 12716
// MISSING LINE 12717
// MISSING LINE 12718
// MISSING LINE 12719
// MISSING LINE 12720
// MISSING LINE 12721
// MISSING LINE 12722
// MISSING LINE 12723
// MISSING LINE 12724
// MISSING LINE 12725
// MISSING LINE 12726
// MISSING LINE 12727
// MISSING LINE 12728
// MISSING LINE 12729
// MISSING LINE 12730
// MISSING LINE 12731
// MISSING LINE 12732
// MISSING LINE 12733
// MISSING LINE 12734
// MISSING LINE 12735
// MISSING LINE 12736
// MISSING LINE 12737
// MISSING LINE 12738
// MISSING LINE 12739
// MISSING LINE 12740
// MISSING LINE 12741
// MISSING LINE 12742
// MISSING LINE 12743
// MISSING LINE 12744
// MISSING LINE 12745
// MISSING LINE 12746
// MISSING LINE 12747
// MISSING LINE 12748
// MISSING LINE 12749
// MISSING LINE 12750
// MISSING LINE 12751
// MISSING LINE 12752
// MISSING LINE 12753
// MISSING LINE 12754
// MISSING LINE 12755
// MISSING LINE 12756
// MISSING LINE 12757
// MISSING LINE 12758
// MISSING LINE 12759
// MISSING LINE 12760
// MISSING LINE 12761
// MISSING LINE 12762
// MISSING LINE 12763
// MISSING LINE 12764
// MISSING LINE 12765
// MISSING LINE 12766
// MISSING LINE 12767
// MISSING LINE 12768
// MISSING LINE 12769
                      label: 'Πολιτική απορρήτου',
                      value: '',
                      onTap: () async => launchUrl(
                          Uri.parse('https://gorealai.web.app/privacy'),
                          mode: LaunchMode.platformDefault)),

                  const SizedBox(height: 20),
                  _ProfileRow(
                    icon: Icons.logout,
                    emoji: '🚪',
                    label: 'Αποσύνδεση',
                    value: '',
                    iconColor: Colors.red,
                    textColor: Colors.red,
                    borderColor: Colors.red.withValues(alpha: 0.2),
                    bgColor: Colors.red.withValues(alpha: 0.06),
                    onTap: () async {
                      await FirebaseAuth.instance.signOut();
                      await AuthService.logout();
                      if (mounted) {
                        Navigator.of(context).popUntil((r) => r.isFirst);
                      }
                    },
                  ),
                  const SizedBox(height: 40),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════
// NOTIFICATIONS SCREEN
// ═══════════════════════════════════════
class NotificationsScreen extends StatefulWidget {
  final String userId;
  const NotificationsScreen({super.key, required this.userId});
        'senderId': widget.currentUserId,
        'senderName': widget.currentUserName,
        'createdAt': FieldValue.serverTimestamp(),
        if (hasVideos) 'videoUploading': true,
      });
      final unreadField = widget.isPro ? 'unreadUser' : 'unreadPro';
      // Parse userId/proId from chatId (format: "userId_proId") so they are
      // always present on the doc — needed for the messages-list query.
                borderRadius: BorderRadius.circular(16),
                color: kGreen.withValues(alpha: 0.08),
                border: Border.all(color: kGreen.withValues(alpha: 0.3)),
              ),
              child: Column(children: [
                Row(children: [
                  const Text('👤', style: TextStyle(fontSize: 18)),
                  const SizedBox(width: 10),
                  Text(userName, style: const TextStyle(
                      color: Colors.white, fontSize: 16,
                      fontWeight: FontWeight.w700)),
                ]),
                if (userPhone.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  GestureDetector(
                    onTap: () => launchUrl(Uri.parse('tel:\$userPhone')),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          vertical: 12, horizontal: 16),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        color: kGreen.withValues(alpha: 0.15),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.phone, color: kGreen, size: 22),
                          const SizedBox(width: 10),
                          Text(userPhone, style: const TextStyle(
                              color: kGreen, fontSize: 18,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.5)),
                        ],
                      ),
                    ),
                  ),
                ],
              ]),
            ),
            const SizedBox(height: 20),
            GestureDetector(
              onTap: () => Navigator.pop(ctx),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 13),
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    gradient: const LinearGradient(
                        colors: [kGoldLight, kGold])),
                child: const Center(child: Text('Τέλεια! 🎉',
                    style: TextStyle(color: Colors.black,
                        fontWeight: FontWeight.w800, fontSize: 15))),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Row(children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _g(0.05),
                        border: Border.all(
                            color: kGold.withValues(alpha: 0.2))),
                    child: const Icon(Icons.arrow_back_ios_new,
                        color: kGold, size: 16)),
              ),
              const SizedBox(width: 14),
              const Expanded(
                  child: Text('Ειδοποιήσεις',
                      style: TextStyle(
                          fontFamily: 'Raleway',
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
// MISSING LINE 12908
// MISSING LINE 12909
// MISSING LINE 12910
// MISSING LINE 12911
// MISSING LINE 12912
// MISSING LINE 12913
// MISSING LINE 12914
// MISSING LINE 12915
// MISSING LINE 12916
// MISSING LINE 12917
// MISSING LINE 12918
// MISSING LINE 12919
// MISSING LINE 12920
// MISSING LINE 12921
// MISSING LINE 12922
// MISSING LINE 12923
// MISSING LINE 12924
// MISSING LINE 12925
// MISSING LINE 12926
// MISSING LINE 12927
// MISSING LINE 12928
// MISSING LINE 12929
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                  itemCount: docs.length,
                  itemBuilder: (_, i) {
                    final d = docs[i].data() as Map<String, dynamic>;
                    final isRead = d['isRead'] == true;
                    final type = d['type'] as String? ?? '';
                    final requestId = d['requestId'] as String? ?? '';
                    final isNewRequest = type == 'new_request';
                    final isOfferAccepted = type == 'offer_accepted';
                    final isDirectRequest = type == 'direct_request';
                    final isDirectOffer = type == 'direct_offer';

                    // Emoji βάσει τύπου
                    String emoji = '🔔';
                    if (isNewRequest) emoji = '📋';
                    if (isOfferAccepted) emoji = '🎉';
                    if (isDirectRequest) emoji = '📩';
                    if (isDirectOffer) emoji = '💬';
                    if ((d['title'] as String? ?? '').startsWith('✅')) emoji = '✅';
                    if ((d['title'] as String? ?? '').startsWith('💼')) emoji = '💼';

                    return GestureDetector(
                      onTap: () async {
                        // Σημείωσε ως διαβασμένο
                        await docs[i].reference.update({'isRead': true});
                        if (!context.mounted) return;

                        // Αν είναι new_request → άνοιξε offer dialog
                        if (isNewRequest && requestId.isNotEmpty) {
                          final reqDoc = await FirebaseFirestore.instance
                              .collection('requests').doc(requestId).get();
                          if (!context.mounted) return;
                          if (reqDoc.exists) {
                            final reqData = Map<String, dynamic>.from(reqDoc.data()!);
                            // Merge videoUrls from request into notification data for display
                            final videoUrls = reqData['videoUrls'] as List?;
                            if (videoUrls != null && videoUrls.isNotEmpty) {
                              reqData['videoUrls'] = videoUrls;
                              reqData['hasVideos'] = true;
                            }
                            _showOfferDialogFromNotif(
                                context, requestId, reqData, userId);
                          }
                        }
                        // Αν είναι offer_accepted → εμφάνισε στοιχεία χρήστη
                        if (isOfferAccepted) {
                          _showBookingAcceptedDialog(context, d);
                        }
                        // Αν είναι direct_request → άνοιξε DirectReplyScreen
                        if (isDirectRequest) {
                          final directRequestId = d['directRequestId'] as String? ?? '';
                          if (directRequestId.isNotEmpty && context.mounted) {
                            Navigator.push(context, PageRouteBuilder(
                              pageBuilder: (_, __, ___) =>
                                  DirectReplyScreen(directRequestId: directRequestId),
                              transitionsBuilder: (_, a, __, c) =>
                                  FadeTransition(opacity: a, child: c),
                              transitionDuration: const Duration(milliseconds: 350),
                            ));
                          }
                        }
                      },
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          color: isRead
                              ? _g(0.04)
                              : (isNewRequest || isDirectRequest
                                  ? kGold.withValues(alpha: 0.08)
                                  : isDirectOffer
                                      ? Colors.blueAccent.withValues(alpha: 0.06)
                                      : kGreen.withValues(alpha: 0.07)),
                          border: Border.all(
                              color: isRead
                                  ? _g(0.07)
                                  : (isNewRequest || isDirectRequest
                                      ? kGold.withValues(alpha: 0.3)
                                      : isDirectOffer
                                          ? Colors.blueAccent.withValues(alpha: 0.3)
                                          : kGreen.withValues(alpha: 0.3))),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 42, height: 42,
                              decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: isRead
                                      ? _g(0.05)
                                      : (isNewRequest
                                          ? kGold.withValues(alpha: 0.12)
                                          : kGreen.withValues(alpha: 0.12))),
                              child: Center(child: Text(emoji,
                                  style: const TextStyle(fontSize: 20))),
                            ),
                            const SizedBox(width: 12),
// MISSING LINE 13030
// MISSING LINE 13031
// MISSING LINE 13032
// MISSING LINE 13033
// MISSING LINE 13034
// MISSING LINE 13035
// MISSING LINE 13036
// MISSING LINE 13037
// MISSING LINE 13038
// MISSING LINE 13039
// MISSING LINE 13040
// MISSING LINE 13041
// MISSING LINE 13042
// MISSING LINE 13043
// MISSING LINE 13044
// MISSING LINE 13045
// MISSING LINE 13046
// MISSING LINE 13047
// MISSING LINE 13048
// MISSING LINE 13049
// MISSING LINE 13050
// MISSING LINE 13051
// MISSING LINE 13052
// MISSING LINE 13053
// MISSING LINE 13054
// MISSING LINE 13055
// MISSING LINE 13056
// MISSING LINE 13057
// MISSING LINE 13058
// MISSING LINE 13059
// MISSING LINE 13060
// MISSING LINE 13061
// MISSING LINE 13062
// MISSING LINE 13063
// MISSING LINE 13064
// MISSING LINE 13065
// MISSING LINE 13066
// MISSING LINE 13067
// MISSING LINE 13068
// MISSING LINE 13069
// MISSING LINE 13070
// MISSING LINE 13071
// MISSING LINE 13072
// MISSING LINE 13073
// MISSING LINE 13074
// MISSING LINE 13075
// MISSING LINE 13076
// MISSING LINE 13077
// MISSING LINE 13078
// MISSING LINE 13079
// MISSING LINE 13080
// MISSING LINE 13081
// MISSING LINE 13082
// MISSING LINE 13083
// MISSING LINE 13084
// MISSING LINE 13085
// MISSING LINE 13086
// MISSING LINE 13087
// MISSING LINE 13088
// MISSING LINE 13089
// MISSING LINE 13090
// MISSING LINE 13091
// MISSING LINE 13092
// MISSING LINE 13093
// MISSING LINE 13094
// MISSING LINE 13095
// MISSING LINE 13096
// MISSING LINE 13097
// MISSING LINE 13098
// MISSING LINE 13099
// MISSING LINE 13100
// MISSING LINE 13101
// MISSING LINE 13102
// MISSING LINE 13103
// MISSING LINE 13104
// MISSING LINE 13105
// MISSING LINE 13106
// MISSING LINE 13107
// MISSING LINE 13108
// MISSING LINE 13109
// MISSING LINE 13110
// MISSING LINE 13111
// MISSING LINE 13112
// MISSING LINE 13113
// MISSING LINE 13114
// MISSING LINE 13115
// MISSING LINE 13116
// MISSING LINE 13117
// MISSING LINE 13118
// MISSING LINE 13119
// MISSING LINE 13120
// MISSING LINE 13121
// MISSING LINE 13122
// MISSING LINE 13123
// MISSING LINE 13124
// MISSING LINE 13125
// MISSING LINE 13126
// MISSING LINE 13127
// MISSING LINE 13128
// MISSING LINE 13129
// MISSING LINE 13130
// MISSING LINE 13131
// MISSING LINE 13132
// MISSING LINE 13133
// MISSING LINE 13134
// MISSING LINE 13135
// MISSING LINE 13136
// MISSING LINE 13137
// MISSING LINE 13138
// MISSING LINE 13139
// MISSING LINE 13140
// MISSING LINE 13141
// MISSING LINE 13142
// MISSING LINE 13143
// MISSING LINE 13144
// MISSING LINE 13145
// MISSING LINE 13146
// MISSING LINE 13147
// MISSING LINE 13148
// MISSING LINE 13149
// MISSING LINE 13150
// MISSING LINE 13151
// MISSING LINE 13152
// MISSING LINE 13153
// MISSING LINE 13154
// MISSING LINE 13155
// MISSING LINE 13156
// MISSING LINE 13157
// MISSING LINE 13158
// MISSING LINE 13159
// MISSING LINE 13160
// MISSING LINE 13161
// MISSING LINE 13162
// MISSING LINE 13163
// MISSING LINE 13164
// MISSING LINE 13165
// MISSING LINE 13166
// MISSING LINE 13167
// MISSING LINE 13168
// MISSING LINE 13169
// MISSING LINE 13170
// MISSING LINE 13171
// MISSING LINE 13172
// MISSING LINE 13173
// MISSING LINE 13174
// MISSING LINE 13175
// MISSING LINE 13176
// MISSING LINE 13177
// MISSING LINE 13178
// MISSING LINE 13179
// MISSING LINE 13180
// MISSING LINE 13181
// MISSING LINE 13182
// MISSING LINE 13183
// MISSING LINE 13184
// MISSING LINE 13185
// MISSING LINE 13186
// MISSING LINE 13187
// MISSING LINE 13188
// MISSING LINE 13189
// MISSING LINE 13190
// MISSING LINE 13191
// MISSING LINE 13192
// MISSING LINE 13193
// MISSING LINE 13194
// MISSING LINE 13195
// MISSING LINE 13196
// MISSING LINE 13197
// MISSING LINE 13198
// MISSING LINE 13199
// MISSING LINE 13200
// MISSING LINE 13201
// MISSING LINE 13202
// MISSING LINE 13203
// MISSING LINE 13204
// MISSING LINE 13205
// MISSING LINE 13206
// MISSING LINE 13207
// MISSING LINE 13208
// MISSING LINE 13209
// MISSING LINE 13210
// MISSING LINE 13211
// MISSING LINE 13212
// MISSING LINE 13213
// MISSING LINE 13214
// MISSING LINE 13215
// MISSING LINE 13216
// MISSING LINE 13217
// MISSING LINE 13218
// MISSING LINE 13219
// MISSING LINE 13220
// MISSING LINE 13221
// MISSING LINE 13222
// MISSING LINE 13223
// MISSING LINE 13224
// MISSING LINE 13225
// MISSING LINE 13226
// MISSING LINE 13227
// MISSING LINE 13228
// MISSING LINE 13229
// MISSING LINE 13230
// MISSING LINE 13231
// MISSING LINE 13232
// MISSING LINE 13233
// MISSING LINE 13234
// MISSING LINE 13235
// MISSING LINE 13236
// MISSING LINE 13237
// MISSING LINE 13238
// MISSING LINE 13239
// MISSING LINE 13240
// MISSING LINE 13241
// MISSING LINE 13242
// MISSING LINE 13243
// MISSING LINE 13244
// MISSING LINE 13245
// MISSING LINE 13246
// MISSING LINE 13247
// MISSING LINE 13248
// MISSING LINE 13249
                : _docs.isEmpty
                    ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.notifications_none, color: _g(0.15), size: 52),
                        const SizedBox(height: 12),
                        Text('Δεν υπάρχουν ειδοποιήσεις',
                            style: TextStyle(color: _g(0.3), fontSize: 14)),
                      ]))
                    : Builder(builder: (context) {
                final docs = _docs;
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                  itemCount: docs.length,
                  itemBuilder: (_, i) {
                    final d = docs[i].data() as Map<String, dynamic>;
                    final isRead = d['isRead'] == true;
                    final type = d['type'] as String? ?? '';
                    final requestId = d['requestId'] as String? ?? '';
                    final isNewRequest = type == 'new_request';
                    final isOfferAccepted = type == 'offer_accepted';
                    final isDirectRequest = type == 'direct_request';
                    final isDirectOffer = type == 'direct_offer';
                    final isDirectChat = type == 'direct_chat';

                    // Emoji βάσει τύπου
                    String emoji = '🔔';
                    if (isNewRequest) emoji = '📋';
                    if (isOfferAccepted) emoji = '🎉';
                    if (isDirectRequest) emoji = '📩';
                    if (isDirectOffer) emoji = '💬';
                    if (isDirectChat) emoji = '💬';
                    if ((d['title'] as String? ?? '').startsWith('✅')) emoji = '✅';
                    if ((d['title'] as String? ?? '').startsWith('💼')) emoji = '💼';

                    return GestureDetector(
                      onTap: () async {
                        // Σημείωσε ως διαβασμένο
                        await docs[i].reference.update({'isRead': true});
                        if (!context.mounted) return;

                        // Αν είναι new_request → άνοιξε offer dialog
                        if (isNewRequest && requestId.isNotEmpty) {
                          final reqDoc = await FirebaseFirestore.instance
                              .collection('requests').doc(requestId).get();
                          if (!context.mounted) return;
                          if (reqDoc.exists) {
                            final reqData = Map<String, dynamic>.from(reqDoc.data()!);
                            // Merge videoUrls from request into notification data for display
                            final videoUrls = reqData['videoUrls'] as List?;
                            if (videoUrls != null && videoUrls.isNotEmpty) {
                              reqData['videoUrls'] = videoUrls;
                              reqData['hasVideos'] = true;
                            }
                            _showOfferDialogFromNotif(
                                context, requestId, reqData, userId);
                          }
                        }
                        // Αν είναι offer_accepted → εμφάνισε στοιχεία χρήστη
                        if (isOfferAccepted) {
                          _showBookingAcceptedDialog(context, d);
                        }
                        // Αν είναι direct_request (legacy) → άνοιξε DirectReplyScreen
                        if (isDirectRequest) {
                          final directRequestId = d['directRequestId'] as String? ?? '';
                          if (directRequestId.isNotEmpty && context.mounted) {
                            Navigator.push(context, PageRouteBuilder(
                              pageBuilder: (_, __, ___) =>
                                  DirectReplyScreen(directRequestId: directRequestId),
                              transitionsBuilder: (_, a, __, c) =>
                                  FadeTransition(opacity: a, child: c),
                              transitionDuration: const Duration(milliseconds: 350),
                            ));
                          }
                        }
                        // Αν είναι direct_chat → άνοιξε ChatScreen απευθείας
                        if (isDirectChat) {
                          final chatId = d['chatId'] as String? ?? '';
                          final uName = d['userName'] as String? ?? 'Χρήστης';
                          if (chatId.isNotEmpty && context.mounted) {
                            Navigator.push(context, PageRouteBuilder(
                              pageBuilder: (_, __, ___) => ChatScreen(
                                chatId: chatId,
                                currentUserId: userId,
                                currentUserName: '',
                                otherName: uName,
                                isPro: true,
                              ),
                              transitionsBuilder: (_, a, __, c) =>
                                  FadeTransition(opacity: a, child: c),
                              transitionDuration: const Duration(milliseconds: 350),
                            ));
                          }
                        }
                      },
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          color: isRead
                              ? _g(0.04)
                              : (isNewRequest || isDirectRequest
                                  ? kGold.withValues(alpha: 0.08)
                                  : isDirectOffer || isDirectChat
                                      ? Colors.blueAccent.withValues(alpha: 0.06)
                                      : kGreen.withValues(alpha: 0.07)),
                          border: Border.all(
                              color: isRead
                                  ? _g(0.07)
                                  : (isNewRequest || isDirectRequest
                                      ? kGold.withValues(alpha: 0.3)
                                      : isDirectOffer || isDirectChat
                                          ? Colors.blueAccent.withValues(alpha: 0.3)
                                          : kGreen.withValues(alpha: 0.3))),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 42, height: 42,
                              decoration: BoxDecoration(
          await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
          if (mounted) {
            showDialog(context: context, builder: (ctx) => Dialog(
              backgroundColor: const Color(0xFF0D0A04),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: kGold.withValues(alpha: 0.3))),
              child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('💳', style: TextStyle(fontSize: 40)),
                const SizedBox(height: 12),
                const Text('Ολοκλήρωσε την πληρωμή', style: TextStyle(color: Colors.white, fontFamily: 'Raleway', fontWeight: FontWeight.w700, fontSize: 16)),
                const SizedBox(height: 8),
                Text('Μόλις πληρώσεις, πάτα "Ανανέωση" για να ενεργοποιηθεί το Premium.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 13, height: 1.5)),
                const SizedBox(height: 20),
                _PremiumButton(label: 'Ανανέωση', gradient: const LinearGradient(colors: [kGoldLight, kGold]), textColor: Colors.black, onTap: () async {
                  Navigator.pop(ctx);
                  await _loadProfile();
                }),
                const SizedBox(height: 8),
                TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Κλείσιμο', style: TextStyle(color: Colors.white.withValues(alpha: 0.4)))),
              ])),
            ));
          }
        }
      } else {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Σφάλμα σύνδεσης με Stripe')));
      }
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Σφάλμα. Δοκίμασε ξανά.')));
    }
    if (mounted) setState(() => _stripeLoading = false);
  }

  void _showEditDialog() {
    _nameCtrl.text = _name ?? '';
    _cityCtrl.text = _city ?? '';
    showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF111111),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(color: kGold.withValues(alpha: 0.2))),
              title: const Text('Επεξεργασία',
                  style: TextStyle(
                      color: Colors.white, fontFamily: 'Raleway')),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                _GoldTextField(
                    controller: _nameCtrl, label: 'Όνομα'),
                const SizedBox(height: 12),
                _GoldTextField(
                    controller: _cityCtrl, label: 'Πόλη'),
              ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Άκυρο',
                        style: TextStyle(color: Colors.white54))),
                TextButton(
                  onPressed: () async {
                    final user = FirebaseAuth.instance.currentUser;
                    if (user == null) return;
                    await FirebaseFirestore.instance
                        .collection('users')
                        .doc(user.uid)
                        .update({
                      'name': _nameCtrl.text.trim(),
                      'city': _cityCtrl.text.trim()
                    });
                    await user
                        .updateDisplayName(_nameCtrl.text.trim());
                    setState(() {
                      _name = _nameCtrl.text.trim();
                      _city = _cityCtrl.text.trim();
                    });
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: const Text('Αποθήκευση',
                      style: TextStyle(color: kGold)),
                ),
              ],
            ));
  }

  void _showChangePasswordDialog() {
    _oldPassCtrl.clear();
// MISSING LINE 13454
// MISSING LINE 13455
// MISSING LINE 13456
// MISSING LINE 13457
// MISSING LINE 13458
// MISSING LINE 13459
// MISSING LINE 13460
// MISSING LINE 13461
// MISSING LINE 13462
// MISSING LINE 13463
// MISSING LINE 13464
// MISSING LINE 13465
// MISSING LINE 13466
// MISSING LINE 13467
// MISSING LINE 13468
// MISSING LINE 13469
// MISSING LINE 13470
// MISSING LINE 13471
// MISSING LINE 13472
// MISSING LINE 13473
// MISSING LINE 13474
// MISSING LINE 13475
// MISSING LINE 13476
// MISSING LINE 13477
// MISSING LINE 13478
// MISSING LINE 13479
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Row(children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _g(0.05),
                        border: Border.all(
                            color: kGold.withValues(alpha: 0.2))),
                    child: const Icon(Icons.arrow_back_ios_new,
                        color: kGold, size: 16)),
              ),
              const SizedBox(width: 14),
                    } catch (e) {
                      if (ctx.mounted)
                        ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Σφάλμα: $e')));
                    }
                  },
                  child: const Text('Αλλαγή',
                      style: TextStyle(color: kGold)),
                ),
              ],
            ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Row(children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _g(0.05),
                        border: Border.all(
                            color: kGold.withValues(alpha: 0.2))),
                    child: const Icon(Icons.arrow_back_ios_new,
                        color: kGold, size: 16)),
              ),
              const SizedBox(width: 14),
              const Text('Προφίλ & Ρυθμίσεις',
                  style: TextStyle(
                      fontFamily: 'Raleway',
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
            ]),
          ),
          const SizedBox(height: 20),
          if (_loading)
            const Expanded(
                child: Center(
                    child: CircularProgressIndicator(color: kGold)))
          else
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(children: [
                  // Avatar
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      color: kGold.withValues(alpha: 0.05),
                      border: Border.all(
                          color: kGold.withValues(alpha: 0.15)),
                    ),
                    child: Column(children: [
                      Container(
                        width: 76,
                        height: 76,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: kGold.withValues(alpha: 0.1),
                          border: Border.all(
                              color: kGold.withValues(alpha: 0.4),
                              width: 2),
                          boxShadow: [
                            BoxShadow(
                                color: kGold.withValues(alpha: 0.25),
                                blurRadius: 20)
                          ],
                        ),
                        child: Center(
                            child: Text(
                                _name?.isNotEmpty == true
                                    ? _name![0].toUpperCase()
                                    : 'G',
                                style: const TextStyle(
                                    fontFamily: 'Raleway',
                                    fontSize: 30,
                                    fontWeight: FontWeight.bold,
                                    color: kGold))),
                      ),
                      const SizedBox(height: 12),
                      Text(_name ?? '',
                          style: const TextStyle(
                              fontFamily: 'Raleway',
                              fontSize: 20,
                              fontStyle: FontStyle.italic,
                              color: kGold)),
                      const SizedBox(height: 2),
                      Text(_email ?? '',
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(14),
                        decoration: _glassCard(radius: 16, gold: true),
                        child: Row(children: [
                          Container(
                              width: 44, height: 44,
                              decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  color: kGold.withValues(alpha: 0.1)),
                              child: Center(child: Text(emoji,
                                  style: const TextStyle(fontSize: 22)))),
                          const SizedBox(width: 12),
                          Expanded(child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(proName,
                                maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: _gw,
                                    fontSize: 14, fontWeight: FontWeight.w700)),
                            if (specialty.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(specialty,
                                  style: TextStyle(fontSize: 11,
                                      color: kGold.withValues(alpha: 0.8),
                                      fontWeight: FontWeight.w600)),
                            ],
                            const SizedBox(height: 3),
                            Text(requestDesc,
                                maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11, color: _g(0.45))),
                            const SizedBox(height: 3),
                            Text('$dateStr${priceStr.isNotEmpty ? ' · $priceStr' : ''}',
                                style: TextStyle(fontSize: 10,
                                    color: kGold.withValues(alpha: 0.7))),
                          ])),
                          Column(mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.end, children: [
                            // Chat button
                            GestureDetector(
                              onTap: () {
                                final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
                                final proId = d['professionalId'] as String? ?? '';
                                if (uid.isEmpty || proId.isEmpty) return;
                                final chatId = '${uid}_$proId';
                                Navigator.push(context, PageRouteBuilder(
                                  pageBuilder: (_, __, ___) => ChatScreen(
                                    chatId: chatId,
                                    currentUserId: uid,
                              ],
                            ),
                            child: _uploadingPhoto
                                ? const Center(child: SizedBox(width: 28, height: 28,
                                    child: CircularProgressIndicator(color: kGold, strokeWidth: 2)))
                                : ClipOval(child: _photoBytes != null
                                    ? Image.memory(_photoBytes!, fit: BoxFit.cover)
                                    : _photoUrl != null && _photoUrl!.isNotEmpty
                                        ? Image.network(_photoUrl!, fit: BoxFit.cover,
                                            errorBuilder: (_, __, ___) => Center(child: Text(
                                                _name?.isNotEmpty == true ? _name![0].toUpperCase() : 'G',
                                                style: const TextStyle(fontFamily: 'Raleway', fontSize: 30, fontWeight: FontWeight.bold, color: kGold))))
                                        : Center(child: Text(
                                            _name?.isNotEmpty == true ? _name![0].toUpperCase() : 'G',
                                            style: const TextStyle(fontFamily: 'Raleway', fontSize: 30, fontWeight: FontWeight.bold, color: kGold)))),
                          ),
                          // Camera badge
                          Positioned(
                            bottom: 0, right: 0,
                            child: Container(
                              width: 24, height: 24,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: kGold,
                                border: Border.all(color: kBg, width: 2),
                              ),
                              child: const Icon(Icons.camera_alt_rounded, color: Colors.black, size: 13),
                            ),
                          ),
                        ]),
                      ),
                      const SizedBox(height: 12),
                      Text(_name ?? '',
                          style: const TextStyle(
                              fontFamily: 'Raleway',
                              fontSize: 20,
                              fontStyle: FontStyle.italic,
                              color: kGold)),
                      const SizedBox(height: 2),
                      Text(_email ?? '',
                          style: TextStyle(
                              fontSize: 12,
                              color: _g(0.4))),
                      if (_city?.isNotEmpty == true) ...[
                        const SizedBox(height: 2),
                        Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.location_on_outlined,
                              size: 12,
                              color: _g(0.3)),
                          const SizedBox(width: 3),
                          Text(_city!,
                              style: TextStyle(
                                  fontSize: 12,
                                  color:
                                      context: context,
                                      selectionDocId: docs[i].id,
                                      userId: uid,
                                      proId: d['professionalId'] as String? ?? '',
                                      proName: proName,
                                      requestId: d['requestId'] as String? ?? '',
                                      rating: result['rating'] as int,
                                      comment: result['comment'] as String? ?? '',
                                    );
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(content: Text('✅ Η αξιολόγησή σου υποβλήθηκε!')));
                                    }
                                  }
                                },
                                child: Container(
                  _categoryEmoji = cat['emoji'] as String;
                  _guests = 50;
                  _budget = 3000;
                  _date = null;
                  _selectedArea = null;
                  _step = 1;
                });
              },
              child: Container(
                margin: const EdgeInsets.only(bottom: 14),
// MISSING LINE 13729
// MISSING LINE 13730
// MISSING LINE 13731
// MISSING LINE 13732
// MISSING LINE 13733
// MISSING LINE 13734
// MISSING LINE 13735
// MISSING LINE 13736
// MISSING LINE 13737
// MISSING LINE 13738
// MISSING LINE 13739
// MISSING LINE 13740
// MISSING LINE 13741
// MISSING LINE 13742
// MISSING LINE 13743
// MISSING LINE 13744
// MISSING LINE 13745
// MISSING LINE 13746
// MISSING LINE 13747
// MISSING LINE 13748
// MISSING LINE 13749
// MISSING LINE 13750
// MISSING LINE 13751
// MISSING LINE 13752
// MISSING LINE 13753
// MISSING LINE 13754
// MISSING LINE 13755
// MISSING LINE 13756
// MISSING LINE 13757
// MISSING LINE 13758
// MISSING LINE 13759
// MISSING LINE 13760
// MISSING LINE 13761
// MISSING LINE 13762
// MISSING LINE 13763
// MISSING LINE 13764
// MISSING LINE 13765
// MISSING LINE 13766
// MISSING LINE 13767
// MISSING LINE 13768
// MISSING LINE 13769
// MISSING LINE 13770
// MISSING LINE 13771
// MISSING LINE 13772
// MISSING LINE 13773
// MISSING LINE 13774
// MISSING LINE 13775
// MISSING LINE 13776
// MISSING LINE 13777
// MISSING LINE 13778
// MISSING LINE 13779
// MISSING LINE 13780
// MISSING LINE 13781
// MISSING LINE 13782
// MISSING LINE 13783
// MISSING LINE 13784
// MISSING LINE 13785
// MISSING LINE 13786
// MISSING LINE 13787
// MISSING LINE 13788
// MISSING LINE 13789
// MISSING LINE 13790
// MISSING LINE 13791
// MISSING LINE 13792
// MISSING LINE 13793
// MISSING LINE 13794
// MISSING LINE 13795
// MISSING LINE 13796
// MISSING LINE 13797
      await FirebaseFirestore.instance.collection('event_requests').add({
        'userId': user.uid,
        'userName': userName,
        'category': _categoryId,
        'categoryTitle': cat['title'],
        'categoryEmoji': cat['emoji'],
        'categoryPros': List<String>.from(cat['pros'] as List),
        'location': _selectedArea ?? _locationCtrl.text.trim(),
        'guests': _guests,
        'budget': _budget.round(),
        'date': _date?.toIso8601String() ?? '',
        'notes': _notesCtrl.text.trim(),
        'status': 'active',
        'offersCount': 0,
        'submittedPros': [],
        'prosNotified': 5,
        'expiresAt': Timestamp.fromDate(DateTime.now().add(const Duration(hours: 1))),
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) setState(() { _submitting = false; _step = 2; });
    } catch (_) {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          transitionBuilder: (child, anim) => SlideTransition(
            position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
                .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
// MISSING LINE 13833
// MISSING LINE 13834
// MISSING LINE 13835
// MISSING LINE 13836
// MISSING LINE 13837
// MISSING LINE 13838
// MISSING LINE 13839
// MISSING LINE 13840
// MISSING LINE 13841
// MISSING LINE 13842
// MISSING LINE 13843
// MISSING LINE 13844
// MISSING LINE 13845
// MISSING LINE 13846
// MISSING LINE 13847
// MISSING LINE 13848
// MISSING LINE 13849
// MISSING LINE 13850
// MISSING LINE 13851
// MISSING LINE 13852
// MISSING LINE 13853
// MISSING LINE 13854
// MISSING LINE 13855
// MISSING LINE 13856
// MISSING LINE 13857
// MISSING LINE 13858
// MISSING LINE 13859
// MISSING LINE 13860
// MISSING LINE 13861
// MISSING LINE 13862
// MISSING LINE 13863
// MISSING LINE 13864
// MISSING LINE 13865
// MISSING LINE 13866
// MISSING LINE 13867
// MISSING LINE 13868
// MISSING LINE 13869
// MISSING LINE 13870
// MISSING LINE 13871
// MISSING LINE 13872
// MISSING LINE 13873
// MISSING LINE 13874
// MISSING LINE 13875
// MISSING LINE 13876
// MISSING LINE 13877
// MISSING LINE 13878
// MISSING LINE 13879
// MISSING LINE 13880
// MISSING LINE 13881
// MISSING LINE 13882
// MISSING LINE 13883
class _RatingDialog extends StatefulWidget {
  final String proName;
  const _RatingDialog({required this.proName});
  @override
  State<_RatingDialog> createState() => _RatingDialogState();
}
class _RatingDialogState extends State<_RatingDialog> {
  int _stars = 0;
  final _commentCtrl = TextEditingController();

  @override
  void dispose() { _commentCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          color: const Color(0xFF111111),
          border: Border.all(color: kGold.withValues(alpha: 0.35)),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.6), blurRadius: 30)],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('⭐', style: TextStyle(fontSize: 36)),
          const SizedBox(height: 10),
          Text('Αξιολόγησε τον\n${widget.proName}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700, height: 1.4)),
          const SizedBox(height: 18),
          // Stars
          Row(mainAxisAlignment: MainAxisAlignment.center, children: List.generate(5, (i) {
            final filled = i < _stars;
            return GestureDetector(
              onTap: () => setState(() => _stars = i + 1),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Icon(
                  filled ? Icons.star_rounded : Icons.star_outline_rounded,
                  color: filled ? kGold : _g(0.25), size: 40,
                ),
              ),
            );
          })),
          const SizedBox(height: 6),
          if (_stars > 0)
            Text(['', '😕 Κακό', '😐 Μέτριο', '🙂 Καλό', '😊 Πολύ καλό', '🤩 Εξαιρετικό'][_stars],
                style: TextStyle(color: kGold.withValues(alpha: 0.8), fontSize: 12)),
          const SizedBox(height: 14),
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: _g(0.05),
              border: Border.all(color: kGold.withValues(alpha: 0.2)),
            ),
            child: TextField(
              controller: _commentCtrl, maxLines: 3, maxLength: 300,
              style: TextStyle(color: _g(0.85), fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Σχόλιο (προαιρετικό)...',
                hintStyle: TextStyle(color: _g(0.3), fontSize: 12),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.all(14),
                counterStyle: TextStyle(color: _g(0.2), fontSize: 9),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(
              child: GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: _g(0.06), border: Border.all(color: _g(0.1)),
                  ),
                  child: Center(child: Text('Άκυρο', style: TextStyle(color: _g(0.55), fontSize: 14))),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: GestureDetector(
                onTap: _stars == 0 ? null : () =>
                    Navigator.pop(context, {'rating': _stars, 'comment': _commentCtrl.text.trim()}),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: _stars > 0 ? const LinearGradient(colors: [kGoldLight, kGold]) : null,
                    color: _stars == 0 ? _g(0.06) : null,
                  ),
                  child: Center(child: Text('Υποβολή',
                      style: TextStyle(
                          color: _stars > 0 ? Colors.black : _g(0.25),
                          fontWeight: FontWeight.w700, fontSize: 14))),
                ),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

Future<void> _submitRating({
  required BuildContext context,
  required String selectionDocId,
  required String userId,
  required String proId,
  required String proName,
  required String requestId,
  required int rating,
  required String comment,
// MISSING LINE 14004
  try {
    // 1. Save review
    await FirebaseFirestore.instance.collection('reviews').add({
      'rating': rating,
      'comment': comment,
      'userId': userId,
      'proId': proId,
      'proName': proName,
      'requestId': requestId,
      'createdAt': FieldValue.serverTimestamp(),
    });
    // 2. Update pro's averageRating + reviewCount in BOTH collections (transaction)
    if (proId.isNotEmpty) {
      final userRef = FirebaseFirestore.instance.collection('users').doc(proId);
      final profRef = FirebaseFirestore.instance.collection('professionals').doc(proId);
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(userRef);
        final data = snap.data() ?? {};
        final oldCount = ((data['reviewCount'] ?? 0) as num).toInt();
        final oldAvg = ((data['averageRating'] ?? 0) as num).toDouble();
        final newCount = oldCount + 1;
        final newAvg = ((oldAvg * oldCount) + rating) / newCount;
        tx.update(userRef, {'reviewCount': newCount, 'averageRating': newAvg});
        tx.set(profRef, {'reviewCount': newCount, 'averageRating': newAvg}, SetOptions(merge: true));
      });
    }
    // 3. Mark selectedProfessionals doc as rated
    if (userId.isNotEmpty && selectionDocId.isNotEmpty) {
      await FirebaseFirestore.instance
          .collection('users').doc(userId)
          .collection('selectedProfessionals').doc(selectionDocId)
          .update({'rated': true, 'myRating': rating});
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Σφάλμα αξιολόγησης: $e')));
    }
  }
}

// ═══════════════════════════════════════
// AI MEMORY SCREEN
// ═══════════════════════════════════════
class AiMemoryScreen extends StatefulWidget {
  final String userId;
  const AiMemoryScreen({super.key, required this.userId});
  @override
  State<AiMemoryScreen> createState() => _AiMemoryScreenState();
}

class _AiMemoryScreenState extends State<AiMemoryScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  final _stt = stt.SpeechToText();
  bool _listening = false;
  String _buffer = '';
  bool _processing = false;

  final _tabs = const [
// MISSING LINE 14065
// MISSING LINE 14066
// MISSING LINE 14067
// MISSING LINE 14068
// MISSING LINE 14069
// MISSING LINE 14070
// MISSING LINE 14071
// MISSING LINE 14072
// MISSING LINE 14073
// MISSING LINE 14074
// MISSING LINE 14075
// MISSING LINE 14076
// MISSING LINE 14077
// MISSING LINE 14078
// MISSING LINE 14079
// MISSING LINE 14080
// MISSING LINE 14081
// MISSING LINE 14082
// MISSING LINE 14083
// MISSING LINE 14084
// MISSING LINE 14085
// MISSING LINE 14086
// MISSING LINE 14087
// MISSING LINE 14088
// MISSING LINE 14089
  },
  {
    'category': 'Συνεργεία',
    'items': [
      'Συνεργείο Ανακαίνισης',
      'Συνεργείο Κατασκευών',
      'Συνεργείο Βαφής & Διακόσμησης',
class _SpecialtyPicker extends StatefulWidget {
  const _SpecialtyPicker();
  @override
  State<_SpecialtyPicker> createState() => _SpecialtyPickerState();
}

class _SpecialtyPickerState extends State<_SpecialtyPicker> {
  String? _selected;
  @override
  Widget build(BuildContext context) => _PickerContainer(
        title: 'Επιλέξτε ειδικότητα',
        onOk: _selected != null
            ? () => Navigator.pop(context, _selected)
            : null,
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          itemCount: _specialtyCategories.length,
          itemBuilder: (_, catIdx) {
            final cat = _specialtyCategories[catIdx];
            return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
                child: Text(cat['category'],
                    style: TextStyle(
                        fontFamily: 'Raleway',
                        fontSize: 9,
                        letterSpacing: 3,
                        color: kGold.withValues(alpha: 0.6))),
              ),
              ...(cat['items'] as List<String>).map((item) {
                final isSel = _selected == item;
                return GestureDetector(
                  onTap: () => setState(() => _selected = item),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 13),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: isSel
                          ? kGold.withValues(alpha: 0.12)
                          : _g(0.04),
                      border: Border.all(
                          color: isSel
                              ? kGold.withValues(alpha: 0.5)
                              : _g(0.07)),
                    ),
                    child: Row(children: [
                      AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: isSel
                                      ? kGold
                                      : _g(0.25),
                                  width: isSel ? 6 : 1.5))),
                      const SizedBox(width: 12),
                      Text(item,
                          style: TextStyle(
                              color: isSel ? kGold : Colors.white,
                              fontSize: 14,
                              fontWeight: isSel
                                  ? FontWeight.w600
                                  : FontWeight.w400)),
                    ]),
                  ),
                );
              }),
            ]);
          },
        ),
      );
}

class _NotificationBell extends StatelessWidget {
  final String userId;
  const _NotificationBell({required this.userId});
  @override
  Widget build(BuildContext context) {
    if (userId.isEmpty) return const SizedBox(width: 34);
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('notifications')
          .where('isRead', isEqualTo: false)
          .snapshots(),
      builder: (context, snap) {
        final count = snap.hasData ? snap.data!.docs.length : 0;
        return GestureDetector(
          onTap: () => Navigator.push(
              context,
              PageRouteBuilder(
                transitionDuration: const Duration(milliseconds: 400),
                pageBuilder: (_, __, ___) =>
                    NotificationsScreen(userId: userId),
                transitionsBuilder: (_, a, __, c) =>
                    FadeTransition(opacity: a, child: c),
              )),
          child: Stack(clipBehavior: Clip.none, children: [
            Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _g(0.05),
                    border:
                        Border.all(color: kGold.withValues(alpha: 0.2))),
                child: Icon(
                    count > 0
                        ? Icons.notifications
                        : Icons.notifications_none,
                    color: kGold.withValues(alpha: 0.7),
                    size: 17)),
            if (count > 0)
              Positioned(
                top: -4,
                right: -4,
                child: Container(
                    width: 18,
                    height: 18,
                    decoration: const BoxDecoration(
                        color: Colors.red, shape: BoxShape.circle),
                    child: Center(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: isSel
                                  ? kGold
                                  : _g(0.25),
                              width: isSel ? 6 : 1.5))),
                  const SizedBox(width: 12),
                  Text(area,
                      style: TextStyle(
                          color: isSel ? kGold : Colors.white,
                          fontSize: 14,
                          fontWeight: isSel
                              ? FontWeight.w600
                              : FontWeight.w400)),
                ]),
              ),
            );
          },
        ),
      );
}

class _PickerContainer extends StatelessWidget {
  final String title;
  final Widget child;
  final VoidCallback? onOk;
  const _PickerContainer(
      {required this.title, required this.child, required this.onOk});
  @override
  Widget build(BuildContext context) => Container(
        height: MediaQuery.of(context).size.height * 0.8,
        decoration: BoxDecoration(
            color: const Color(0xFF111111),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(color: kGold.withValues(alpha: 0.15))),
        child: Column(children: [
          Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 12, bottom: 16),
              decoration: BoxDecoration(
                  color: _g(0.15),
                  borderRadius: BorderRadius.circular(2))),
// SPECIALTY & AREA PICKERS
// ═══════════════════════════════════════
const List<Map<String, dynamic>> _specialtyCategories = [
  {
    'category': 'Τεχνικοί',
    'items': [
      'Ηλεκτρολόγος', 'Υδραυλικός', 'Ψυκτικός', 'Ελαιοχρωματιστής',
      'Μηχανικός', 'Κτίστης', 'Ξυλουργός', 'Υαλουργός',
      'Τεχνικός Ανελκυστήρων', 'Αποφράξεις', 'Αλουμινάς', 'Πλακάς',
      'Συντήρηση Κλιματιστικών', 'Εγκατάσταση Ηλιακών'
    ]
  },
  {
    'category': 'Υγεία',
    'items': [
      'Παθολόγος', 'Παιδίατρος', 'Οδοντίατρος', 'Φυσιοθεραπευτής',
      'Ψυχολόγος', 'Διατροφολόγος', 'Νοσηλευτής κατ\' οίκον'
    ]
  },
  {
    'category': 'Σπίτι',
    'items': ['Καθαρίστρια', 'Κηπουρός', 'Baby Sitter', 'Μετακομίσεις']
  },
  {
    'category': 'Εκπαίδευση',
    'items': [
      'Καθηγητής Μαθηματικών',
      'Καθηγητής Αγγλικών',
      'Personal Trainer'
    ]
  },
  {
    'category': 'Ψηφιακές',
    'items': [
      'Web Developer',
      'Γραφίστας',
      'Φωτογράφος',
      'Τεχνικός Υπολογιστών'
    ]
  },
  {
    'category': 'Εκδηλώσεις',
    'items': [
      'Εκδηλώσεις Γάμου',
      'Εκδηλώσεις Βάφτισης',
      'Διοργάνωση Πάρτυ',
      'Φωτογράφος Γάμου',
      'DJ / Μουσική Εκδηλώσεων',
      'Catering',
      'Ανθοδέτης / Στολισμός',
      'Αίθουσα Εκδηλώσεων',
    ]
  },
  {
    'category': 'Άλλα',
    'items': ['Μηχανικός Αυτοκινήτων', 'Λογιστής', 'Δικηγόρος', 'Αρχιτέκτονας']
  },
  {
    'category': 'Συνεργεία',
    'items': [
      'Συνεργείο Ανακαίνισης',
      'Συνεργείο Κατασκευών',
      'Συνεργείο Βαφής & Διακόσμησης',
      'Συνεργείο Ηλεκτρολόγων',
      'Συνεργείο Υδραυλικών',
      'Συνεργείο Κλιματισμού',
      'Συνεργείο Αλουμινίου & Κουφωμάτων',
      'Συνεργείο Πλακιδίων & Δαπέδων',
      'Συνεργείο Κήπου & Εξωτερικών Χώρων',
      'Συνεργείο Γυψοσανίδας & Οροφής',
      'Συνεργείο Ξυλουργικών Εργασιών',
    ]
  },
];

// ── Multi-pick field shown in registration form ──────────────────────
  State<ProjectRequestScreen> createState() => _ProjectRequestScreenState();
}

class _ProjectRequestScreenState extends State<ProjectRequestScreen>
class _ProfileScreenState extends State<ProfileScreen> {
  String? _name, _email, _city;
  String? _photoUrl;
  Uint8List? _photoBytes;
  bool _uploadingPhoto = false;
  bool _loading = true, _biometricOn = true, _isPremium = false;
  bool _stripeLoading = false;
  final _nameCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _oldPassCtrl = TextEditingController();
  final _newPassCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _cityCtrl.dispose();
    _oldPassCtrl.dispose();
    _newPassCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() => _loading = false);
      return;
    }
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _name = doc.data()?['name'] ?? user.displayName ?? '';
      _city = doc.data()?['city'] ?? '';
      _email = user.email ?? '';
      _photoUrl = doc.data()?['profilePhotoUrl'] as String?;
      _isPremium = doc.data()?['isPremium'] == true;
      _nameCtrl.text = _name ?? '';
      _cityCtrl.text = _city ?? '';
      _biometricOn = prefs.getBool('biometric_enabled') ?? true;
      _loading = false;
    });
  }

  Widget _sectionHeader(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(t,
              style: TextStyle(
                  fontFamily: 'Raleway',
                  fontSize: 9,
                  letterSpacing: 3,
                  color: kGold.withValues(alpha: 0.4))),
        ),
      );

  Widget _buildToggleRow(String emoji, String label, String subtitle,
          bool value, ValueChanged<bool> onChanged) =>
      Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: _g(0.05)),
        child: Row(children: [
          Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: kGold.withValues(alpha: 0.15),
// MISSING LINE 14434
// MISSING LINE 14435
  Future<void> _submit() async {
    if (!_canSend || _sending) return;
    setState(() => _sending = true);
    try {
      final expiresAt = Timestamp.fromDate(
          DateTime.now().add(const Duration(minutes: 15)));
      final docRef = await FirebaseFirestore.instance
          .collection('project_requests')
          .add({
        'userId': widget.userId,
        'userName': widget.userName,
        'description': _textCtrl.text.trim(),
        'teamType': _selectedTeamType ?? '',
        'location': _selectedLocation ?? '',
        'criteria': _selectedCriteria,
        'status': 'active',
        'imageCount': _images.length,
        'hasVideos': _videoFiles.isNotEmpty,
        'createdAt': FieldValue.serverTimestamp(),
        'expiresAt': expiresAt,
      });

      // Read all bytes NOW while XFile is still valid
// MISSING LINE 14459
// MISSING LINE 14460
// MISSING LINE 14461
// MISSING LINE 14462
// MISSING LINE 14463
// MISSING LINE 14464
// MISSING LINE 14465
// MISSING LINE 14466
// MISSING LINE 14467
// MISSING LINE 14468
// MISSING LINE 14469
// MISSING LINE 14470
// MISSING LINE 14471
// MISSING LINE 14472
// MISSING LINE 14473
// MISSING LINE 14474
// MISSING LINE 14475
// MISSING LINE 14476
// MISSING LINE 14477
// MISSING LINE 14478
// MISSING LINE 14479
        'minRating': _minRating,
        'withPhotos': _wantsWithPhotos,
        'status': 'active',
        'imageCount': _images.length,
        'hasVideos': _videoFiles.isNotEmpty,
        'createdAt': FieldValue.serverTimestamp(),
        'expiresAt': expiresAt,
      });

      // Read all bytes NOW while XFile is still valid
      List<String> imageBase64 = [];
      for (final img in _images) {
        try { imageBase64.add(base64Encode(await img.readAsBytes())); } catch (_) {}
      }
      final List<({String name, Uint8List bytes, String mime})> videoData = [];
      for (final vid in _videoFiles) {
        try {
          videoData.add((name: vid.name, bytes: await vid.readAsBytes(), mime: vid.mimeType ?? 'video/mp4'));
        } catch (_) {}
      }

      if (imageBase64.isNotEmpty) {
        await FirebaseFirestore.instance.collection('project_requests').doc(docRef.id)
            .update({'images': imageBase64, 'hasImages': true});
      }

      if (videoData.isNotEmpty) {
        final docId = docRef.id;
        final projUserId = widget.userId;
        Future(() async {
          final urls = <String>[];
          for (int i = 0; i < videoData.length; i++) {
            final v = videoData[i];
            try {
              final ext = v.mime.contains('mp4') ? 'mp4' : v.mime.contains('webm') ? 'webm' : 'mp4';
              final contentType = v.mime.isNotEmpty ? v.mime : 'video/mp4';
              final fileName = 'video_${i}_${DateTime.now().millisecondsSinceEpoch}.$ext';
              final user = FirebaseAuth.instance.currentUser;
              if (user == null) throw Exception('not_authenticated');
              final idToken = await user.getIdToken();
              const bucket = 'shoppilot-app-e4104.firebasestorage.app';
              final objectPath = 'project_requests/$docId/videos/$fileName';
              final encodedPath = Uri.encodeComponent(objectPath);
              final uploadResp = await http.post(
                Uri.parse('https://firebasestorage.googleapis.com/v0/b/$bucket/o'
                    '?uploadType=media&name=$encodedPath'),
                headers: {
                  'Authorization': 'Firebase $idToken',
                  'Content-Type': contentType,
                },
                body: v.bytes,
              ).timeout(const Duration(seconds: 120));
              if (uploadResp.statusCode != 200) {
                throw Exception('HTTP ${uploadResp.statusCode}: ${uploadResp.body}');
              }
              final respJson = jsonDecode(uploadResp.body) as Map<String, dynamic>;
              final token = respJson['downloadTokens'] as String? ?? '';
class _NotificationBell extends StatelessWidget {
  final String userId;
  const _NotificationBell({required this.userId});
  @override
  Widget build(BuildContext context) {
    if (userId.isEmpty) return const SizedBox(width: 34);
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('notifications')
          .where('isRead', isEqualTo: false)
          .snapshots(),
      builder: (context, snap) {
        final count = snap.hasData ? snap.data!.docs.length : 0;
        return GestureDetector(
          onTap: () => Navigator.push(
              context,
              PageRouteBuilder(
                transitionDuration: const Duration(milliseconds: 400),
                pageBuilder: (_, __, ___) =>
                    NotificationsScreen(userId: userId),
                transitionsBuilder: (_, a, __, c) =>
                    FadeTransition(opacity: a, child: c),
              )),
          child: Stack(clipBehavior: Clip.none, children: [
            Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _g(0.05),
                    border:
                        Border.all(color: kGold.withValues(alpha: 0.2))),
                child: Icon(
                    count > 0
                        ? Icons.notifications
                        : Icons.notifications_none,
                    color: kGold.withValues(alpha: 0.7),
                    size: 17)),
            if (count > 0)
              Positioned(
                top: -4,
                right: -4,
                child: Container(
                    width: 18,
                    height: 18,
                    decoration: const BoxDecoration(
                        color: Colors.red, shape: BoxShape.circle),
                    child: Center(
                        child: Text(count > 9 ? '9+' : '$count',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold)))),
              ),
          ]),
        );
      },
    );
  }
}

class _ProfileRow extends StatefulWidget {
  final IconData icon;
  final String label, value;
  final VoidCallback? onTap;
  final Color? iconColor, textColor, borderColor, bgColor;
  final String? emoji;
  const _ProfileRow(
      {required this.icon,
      required this.label,
      required this.value,
      this.onTap,
      this.iconColor,
      this.textColor,
      this.borderColor,
      this.bgColor,
      this.emoji});
  @override
    ]
  },
  {
    'category': 'Υγεία',
    'items': [
      'Παθολόγος', 'Παιδίατρος', 'Οδοντίατρος', 'Φυσιοθεραπευτής',
      'Ψυχολόγος', 'Διατροφολόγος', 'Νοσηλευτής κατ\' οίκον'
    ]
  },
  {
    'category': 'Σπίτι',
    'items': ['Καθαρίστρια', 'Κηπουρός', 'Baby Sitter', 'Μετακομίσεις']
  },
  {
    'category': 'Εκπαίδευση',
    'items': [
      'Καθηγητής Μαθηματικών',
      'Καθηγητής Αγγλικών',
      'Καθηγητής Γαλλικών',
      'Καθηγητής Ιταλικών',
      'Καθηγητής Γερμανικών',
      'Καθηγητής Ισπανικών',
      'Φιλόλογος',
      'Καθηγητής Φυσικής',
      'Καθηγητής Χημείας',
      'Καθηγητής Πληροφορικής',
      'Καθηγητής Βιολογίας',
      'Personal Trainer'
    ]
  },
  {
    'category': 'Ψηφιακές',
    'items': [
      'Web Developer',
      'Γραφίστας',
      'Φωτογράφος',
      'Τεχνικός Υπολογιστών'
    ]
  },
  {
    'category': 'Εκδηλώσεις',
    'items': [
      'Εκδηλώσεις Γάμου',
      'Εκδηλώσεις Βάφτισης',
      'Διοργάνωση Πάρτυ',
      'Φωτογράφος Γάμου',
      'DJ / Μουσική Εκδηλώσεων',
      'Catering',
      'Ανθοδέτης / Στολισμός',
      'Αίθουσα Εκδηλώσεων',
    ]
  },
  {
    'category': 'Ομορφιά & Αισθητική',
    'items': ['Tattoo Artist', 'Τεχνίτρια Νυχιών']
  },
  {
    'category': 'Άλλα',
    'items': ['Μηχανικός Αυτοκινήτων', 'Λογιστής', 'Δικηγόρος', 'Αρχιτέκτονας']
  },
  {
    'category': 'Συνεργεία',
    'items': [
      'Συνεργείο Ανακαίνισης',
      'Συνεργείο Κατασκευών',
      'Συνεργείο Βαφής & Διακόσμησης',
      'Συνεργείο Ηλεκτρολόγων',
      'Συνεργείο Υδραυλικών',
      'Συνεργείο Κλιματισμού',
      'Συνεργείο Αλουμινίου & Κουφωμάτων',
      'Συνεργείο Πλακιδίων & Δαπέδων',
      'Συνεργείο Κήπου & Εξωτερικών Χώρων',
      'Συνεργείο Γυψοσανίδας & Οροφής',
      'Συνεργείο Ξυλουργικών Εργασιών',
    ]
  },
];

// MISSING LINE 14695
// MISSING LINE 14696
// MISSING LINE 14697
// MISSING LINE 14698
// MISSING LINE 14699
// MISSING LINE 14700
// MISSING LINE 14701
// MISSING LINE 14702
// MISSING LINE 14703
// MISSING LINE 14704
// MISSING LINE 14705
// MISSING LINE 14706
// MISSING LINE 14707
// MISSING LINE 14708
// MISSING LINE 14709
// MISSING LINE 14710
// MISSING LINE 14711
// MISSING LINE 14712
// MISSING LINE 14713
// MISSING LINE 14714
// MISSING LINE 14715
// MISSING LINE 14716
// MISSING LINE 14717
// MISSING LINE 14718
// MISSING LINE 14719
// MISSING LINE 14720
// MISSING LINE 14721
// MISSING LINE 14722
// MISSING LINE 14723
// MISSING LINE 14724
// MISSING LINE 14725
// MISSING LINE 14726
// MISSING LINE 14727
// MISSING LINE 14728
// MISSING LINE 14729
// MISSING LINE 14730
// MISSING LINE 14731
// MISSING LINE 14732
// MISSING LINE 14733
// MISSING LINE 14734
// MISSING LINE 14735
// MISSING LINE 14736
// MISSING LINE 14737
// MISSING LINE 14738
// MISSING LINE 14739
                            _buildPicker('Επίλεξε...', _selectedLocation, _projectLocations, (v) => setState(() => _selectedLocation = v)),
                          ])),
                        ]),
                      ]),
                    ),

                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Divider(color: _g(0.06), height: 28),
                    ),

                    // Criteria
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Προτεραιότητα', style: TextStyle(fontSize: 10, color: _g(0.4), letterSpacing: 0.7, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 10),
                        Row(children: [
                          for (final c in [
                            {'v': 'cheap', 'e': '💰', 'l': 'Χαμηλή τιμή'},
                            {'v': 'value', 'e': '⭐', 'l': 'Καλύτερο αποτ.'},
                            {'v': 'fast', 'e': '⚡', 'l': 'Άμεση έναρξη'},
                          ]) ...[
                            Expanded(
                              child: _TapScaleWidget(
                                onTap: () => setState(() => _selectedCriteria = c['v']!),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 150),
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(14),
                                    gradient: _selectedCriteria == c['v']
                                        ? LinearGradient(colors: [kGold.withValues(alpha: 0.18), kGold.withValues(alpha: 0.06)])
                                        : null,
                                    color: _selectedCriteria == c['v'] ? null : _g(0.03),
                                    border: Border.all(
                                        color: _selectedCriteria == c['v'] ? kGold.withValues(alpha: 0.55) : _g(0.07),
                                        width: _selectedCriteria == c['v'] ? 1 : 0.5),
                                    boxShadow: _selectedCriteria == c['v'] ? [BoxShadow(color: kGold.withValues(alpha: 0.15), blurRadius: 8)] : null,
                                  ),
                                  child: Column(children: [
                                    Text(c['e']!, style: const TextStyle(fontSize: 20)),
                                    const SizedBox(height: 5),
                                    Text(c['l']!, textAlign: TextAlign.center,
                                        style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600,
                                            color: _selectedCriteria == c['v'] ? kGold : _g(0.38))),
                                  ]),
                                ),
                              ),
                            ),
                            if (c['v'] != 'fast') const SizedBox(width: 8),
                          ],
                        ]),
                      ]),
                    ),
                  ]),
                ),

                const SizedBox(height: 16),

                // ── Media button + thumbnails ──
                Row(children: [
                  GestureDetector(
                    onTap: _pickMedia,
                    child: Stack(clipBehavior: Clip.none, children: [
                      Container(
                        width: 48, height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
// MISSING LINE 14809
// MISSING LINE 14810
// MISSING LINE 14811
// MISSING LINE 14812
// MISSING LINE 14813
// MISSING LINE 14814
// MISSING LINE 14815
// MISSING LINE 14816
// MISSING LINE 14817
// MISSING LINE 14818
// MISSING LINE 14819
                            GestureDetector(
                              onTap: () async {
                                final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
                                final proId = d['professionalId'] as String? ?? '';
                                if (uid.isEmpty) return;

                                // Premium check + fetch user name
                                bool isPremium = false;
                                String myName = '';
                                try {
                                  final userDoc = await FirebaseFirestore.instance
                                      .collection('users').doc(uid).get();
                                  isPremium = userDoc.data()?['isPremium'] == true || userDoc.data()?['isOwner'] == true;
                                  myName = (userDoc.data()?['name'] as String?) ?? '';
                                } catch (_) {}

                                if (!context.mounted) return;

                                if (!isPremium) {
                                  _showPortfolioPremiumGateDialog(context, {
                                    'name': proName,
                                    'displayName': proName,
                                    'id': proId,
                                  });
                                  return;
                                }

                                if (proId.isEmpty) return;
                                final chatId = '${uid}_$proId';
                                Navigator.push(context, PageRouteBuilder(
                                  pageBuilder: (_, __, ___) => ChatScreen(
                                    chatId: chatId,
                                    currentUserId: uid,
                                    currentUserName: myName,
                                    otherName: proName,
                                    isPro: false,
                                  ),
                                  transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
                                  transitionDuration: const Duration(milliseconds: 300),
                                ));
                                FirebaseFirestore.instance.collection('chats').doc(chatId)
                                    .set({
                                  'userId': uid, 'proId': proId,
                                  'userName': myName, 'proName': proName,
                                  'lastMessageAt': FieldValue.serverTimestamp(),
                                }, SetOptions(merge: true)).catchError((_) {});
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(20),
                                  gradient: const LinearGradient(colors: [kGoldLight, kGold]),
                                  boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.3), blurRadius: 6)],
                                ),
                                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                          mode: LaunchMode.platformDefault)),

                  const SizedBox(height: 20),
                  _ProfileRow(
                    icon: Icons.logout,
                    emoji: '🚪',
                    label: 'Αποσύνδεση',
                    value: '',
                    iconColor: Colors.red,
                    textColor: Colors.red,
                    borderColor: Colors.red.withValues(alpha: 0.2),
                    bgColor: Colors.red.withValues(alpha: 0.06),
                    onTap: () async {
                      await FirebaseAuth.instance.signOut();
                      await AuthService.logout();
                      if (mounted) {
                        Navigator.of(context).popUntil((r) => r.isFirst);
                      }
                    },
                  ),
                  const SizedBox(height: 40),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════
// NOTIFICATIONS SCREEN
// ═══════════════════════════════════════
class NotificationsScreen extends StatefulWidget {
  final String userId;
  const NotificationsScreen({super.key, required this.userId});
  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final Set<String> _deletedIds = {};
  List<QueryDocumentSnapshot> _docs = [];
  StreamSubscription<QuerySnapshot>? _sub;
  bool _loadingNotifs = true;

  String get userId => widget.userId;

  @override
  void initState() {
    super.initState();
    _sub = FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .collection('notifications')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(() {
        _docs = snap.docs.where((d) => !_deletedIds.contains(d.id)).toList();
        _loadingNotifs = false;
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _markAllRead() async {
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .collection('notifications')
        .where('isRead', isEqualTo: false)
        .get();
    for (final doc in snap.docs)
// MISSING LINE 14955
// MISSING LINE 14956
// MISSING LINE 14957
// MISSING LINE 14958
// MISSING LINE 14959
// MISSING LINE 14960
// MISSING LINE 14961
// MISSING LINE 14962
// MISSING LINE 14963
// MISSING LINE 14964
// MISSING LINE 14965
// MISSING LINE 14966
// MISSING LINE 14967
// MISSING LINE 14968
// MISSING LINE 14969
// MISSING LINE 14970
// MISSING LINE 14971
// MISSING LINE 14972
// MISSING LINE 14973
// MISSING LINE 14974
// MISSING LINE 14975
// MISSING LINE 14976
// MISSING LINE 14977
// MISSING LINE 14978
// MISSING LINE 14979
// MISSING LINE 14980
// MISSING LINE 14981
// MISSING LINE 14982
// MISSING LINE 14983
// MISSING LINE 14984
// MISSING LINE 14985
// MISSING LINE 14986
// MISSING LINE 14987
// MISSING LINE 14988
// MISSING LINE 14989
// MISSING LINE 14990
// MISSING LINE 14991
// MISSING LINE 14992
// MISSING LINE 14993
// MISSING LINE 14994
// MISSING LINE 14995
// MISSING LINE 14996
// MISSING LINE 14997
// MISSING LINE 14998
// MISSING LINE 14999
// MISSING LINE 15000
// MISSING LINE 15001
// MISSING LINE 15002
// MISSING LINE 15003
// MISSING LINE 15004
// MISSING LINE 15005
// MISSING LINE 15006
// MISSING LINE 15007
// MISSING LINE 15008
// MISSING LINE 15009
// MISSING LINE 15010
// MISSING LINE 15011
// MISSING LINE 15012
// MISSING LINE 15013
// MISSING LINE 15014
// MISSING LINE 15015
// MISSING LINE 15016
// MISSING LINE 15017
// MISSING LINE 15018
// MISSING LINE 15019
// MISSING LINE 15020
// MISSING LINE 15021
// MISSING LINE 15022
// MISSING LINE 15023
// MISSING LINE 15024
                      label: 'Έκδοση',
                      value: '2.0.0'),
                  _ProfileRow(
                      icon: Icons.privacy_tip_outlined,
                      emoji: '🛡️',
                      label: 'Πολιτική απορρήτου',
                      value: '',
                      onTap: () async => launchUrl(
                          Uri.parse('https://gorealai.web.app/privacy'),
                          mode: LaunchMode.platformDefault)),

                  const SizedBox(height: 20),
// MISSING LINE 15037
// MISSING LINE 15038
// MISSING LINE 15039
// MISSING LINE 15040
// MISSING LINE 15041
// MISSING LINE 15042
// MISSING LINE 15043
// MISSING LINE 15044
// MISSING LINE 15045
// MISSING LINE 15046
// MISSING LINE 15047
// MISSING LINE 15048
// MISSING LINE 15049
// MISSING LINE 15050
// MISSING LINE 15051
// MISSING LINE 15052
// MISSING LINE 15053
// MISSING LINE 15054
// MISSING LINE 15055
// MISSING LINE 15056
// MISSING LINE 15057
// MISSING LINE 15058
// MISSING LINE 15059
// MISSING LINE 15060
// MISSING LINE 15061
// MISSING LINE 15062
// MISSING LINE 15063
// MISSING LINE 15064
// MISSING LINE 15065
// MISSING LINE 15066
// MISSING LINE 15067
// MISSING LINE 15068
// MISSING LINE 15069
// MISSING LINE 15070
// MISSING LINE 15071
// MISSING LINE 15072
// MISSING LINE 15073
// MISSING LINE 15074
// MISSING LINE 15075
// MISSING LINE 15076
// MISSING LINE 15077
// MISSING LINE 15078
// MISSING LINE 15079
// MISSING LINE 15080
// MISSING LINE 15081
// MISSING LINE 15082
// MISSING LINE 15083
// MISSING LINE 15084
// MISSING LINE 15085
// MISSING LINE 15086
// MISSING LINE 15087
// MISSING LINE 15088
// MISSING LINE 15089
// MISSING LINE 15090
// MISSING LINE 15091
// MISSING LINE 15092
// MISSING LINE 15093
// MISSING LINE 15094
// MISSING LINE 15095
// MISSING LINE 15096
// MISSING LINE 15097
// MISSING LINE 15098
// MISSING LINE 15099
// MISSING LINE 15100
// MISSING LINE 15101
// MISSING LINE 15102
                      icon: Icons.privacy_tip_outlined,
                      emoji: '🛡️',
                      label: 'Πολιτική απορρήτου',
                      value: '',
                      onTap: () async => launchUrl(
                          Uri.parse('https://gorealai.web.app/privacy.html'),
                          mode: LaunchMode.platformDefault)),

                  const SizedBox(height: 20),
                  _ProfileRow(
                    icon: Icons.logout,
                    emoji: '🚪',
// MISSING LINE 15115
// MISSING LINE 15116
// MISSING LINE 15117
// MISSING LINE 15118
// MISSING LINE 15119
// MISSING LINE 15120
// MISSING LINE 15121
// MISSING LINE 15122
// MISSING LINE 15123
// MISSING LINE 15124
// MISSING LINE 15125
// MISSING LINE 15126
// MISSING LINE 15127
// MISSING LINE 15128
// MISSING LINE 15129
// MISSING LINE 15130
// MISSING LINE 15131
// MISSING LINE 15132
// MISSING LINE 15133
// MISSING LINE 15134
// MISSING LINE 15135
// MISSING LINE 15136
// MISSING LINE 15137
// MISSING LINE 15138
// MISSING LINE 15139
// MISSING LINE 15140
// MISSING LINE 15141
// MISSING LINE 15142
// MISSING LINE 15143
// MISSING LINE 15144
// MISSING LINE 15145
// MISSING LINE 15146
// MISSING LINE 15147
// MISSING LINE 15148
// MISSING LINE 15149
// MISSING LINE 15150
// MISSING LINE 15151
// MISSING LINE 15152
// MISSING LINE 15153
// MISSING LINE 15154
// MISSING LINE 15155
// MISSING LINE 15156
// MISSING LINE 15157
// MISSING LINE 15158
// MISSING LINE 15159
// MISSING LINE 15160
// MISSING LINE 15161
// MISSING LINE 15162
}

class _NotificationBell extends StatelessWidget {
  final String userId;
  const _NotificationBell({required this.userId});
  @override
  Widget build(BuildContext context) {
    if (userId.isEmpty) return const SizedBox(width: 34);
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('notifications')
          .where('isRead', isEqualTo: false)
          .snapshots(),
      builder: (context, snap) {
        final count = snap.hasData ? snap.data!.docs.length : 0;
        return GestureDetector(
          onTap: () => Navigator.push(
              context,
              PageRouteBuilder(
                transitionDuration: const Duration(milliseconds: 400),
                pageBuilder: (_, __, ___) =>
                    NotificationsScreen(userId: userId),
                transitionsBuilder: (_, a, __, c) =>
                    FadeTransition(opacity: a, child: c),
              )),
          child: Stack(clipBehavior: Clip.none, children: [
            Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _g(0.05),
                    border:
                        Border.all(color: kGold.withValues(alpha: 0.2))),
                child: Icon(
                    count > 0
                        ? Icons.notifications
                        : Icons.notifications_none,
                    color: kGold.withValues(alpha: 0.7),
                    size: 17)),
            if (count > 0)
              Positioned(
                top: -4,
                right: -4,
                child: Container(
                    width: 18,
                    height: 18,
                    decoration: const BoxDecoration(
                        color: Colors.red, shape: BoxShape.circle),
                    child: Center(
                        child: Text(count > 9 ? '9+' : '$count',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold)))),
              ),
          ]),
        );
      },
    );
  }
}

class _ProfileRow extends StatefulWidget {
  final IconData icon;
  final String label, value;
  final VoidCallback? onTap;
                  height: 4,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: kGold,
                      boxShadow: [
                        BoxShadow(
                            color: kGold.withValues(alpha: 0.8), blurRadius: 6)
                      ])),
            ],
          ]),
        ),
// ── Pro Dashboard Button — shown in HomeScreen header for professionals only ──
class _ProDashboardButton extends StatelessWidget {
  final String userId;
  const _ProDashboardButton({required this.userId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('notifications')
          .where('isRead', isEqualTo: false)
          .snapshots(),
      builder: (context, snap) {
        final count = snap.hasData ? snap.data!.docs.length : 0;
        return GestureDetector(
          onTap: () => Navigator.push(
            context,
            PageRouteBuilder(
              transitionDuration: const Duration(milliseconds: 400),
              pageBuilder: (_, __, ___) => const ProfessionalHomeScreen(),
              transitionsBuilder: (_, a, __, c) =>
                  FadeTransition(opacity: a, child: c),
            ),
          ),
          child: Stack(clipBehavior: Clip.none, children: [
            Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(17),
                color: kGold.withValues(alpha: 0.12),
                border: Border.all(color: kGold.withValues(alpha: 0.5)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.work_outline_rounded,
                    color: kGold, size: 14),
                const SizedBox(width: 5),
                const Text('Επαγγελματίας',
                    style: TextStyle(
                        color: kGold,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3)),
              ]),
            ),
            if (count > 0)
              Positioned(
                top: -4,
                right: -4,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: const BoxDecoration(
                      color: Colors.red, shape: BoxShape.circle),
                  child: Center(
                    child: Text(count > 9 ? '9+' : '$count',
                        style: const TextStyle(
                            color: Colors.white,
// MISSING LINE 15303
// MISSING LINE 15304
// MISSING LINE 15305
// MISSING LINE 15306
// MISSING LINE 15307
// MISSING LINE 15308
// MISSING LINE 15309
// MISSING LINE 15310
// MISSING LINE 15311
// MISSING LINE 15312
// MISSING LINE 15313
// MISSING LINE 15314
// MISSING LINE 15315
// MISSING LINE 15316
// MISSING LINE 15317
// MISSING LINE 15318
// MISSING LINE 15319
// MISSING LINE 15320
// MISSING LINE 15321
// MISSING LINE 15322
// MISSING LINE 15323
// MISSING LINE 15324
// MISSING LINE 15325
// MISSING LINE 15326
// MISSING LINE 15327
// MISSING LINE 15328
// MISSING LINE 15329
// MISSING LINE 15330
// MISSING LINE 15331
// MISSING LINE 15332
// MISSING LINE 15333
// MISSING LINE 15334
// MISSING LINE 15335
// MISSING LINE 15336
// MISSING LINE 15337
// MISSING LINE 15338
// MISSING LINE 15339
// MISSING LINE 15340
// MISSING LINE 15341
// MISSING LINE 15342
// MISSING LINE 15343
// MISSING LINE 15344
// MISSING LINE 15345
// MISSING LINE 15346
// MISSING LINE 15347
// MISSING LINE 15348
// MISSING LINE 15349
// MISSING LINE 15350
// MISSING LINE 15351
// MISSING LINE 15352
// MISSING LINE 15353
// MISSING LINE 15354
// MISSING LINE 15355
// MISSING LINE 15356
// MISSING LINE 15357
// MISSING LINE 15358
// MISSING LINE 15359
// MISSING LINE 15360
// MISSING LINE 15361
// MISSING LINE 15362
// MISSING LINE 15363
// MISSING LINE 15364
// MISSING LINE 15365
// MISSING LINE 15366
// MISSING LINE 15367
// MISSING LINE 15368
// MISSING LINE 15369
// MISSING LINE 15370
// MISSING LINE 15371
// MISSING LINE 15372
// MISSING LINE 15373
// MISSING LINE 15374
// MISSING LINE 15375
// MISSING LINE 15376
// MISSING LINE 15377
// MISSING LINE 15378
// MISSING LINE 15379
// MISSING LINE 15380
// MISSING LINE 15381
// MISSING LINE 15382
// MISSING LINE 15383
// MISSING LINE 15384
const List<Map<String, dynamic>> _specialtyCategories = [
  {
    'category': 'Τεχνικοί',
    'items': [
      'Ηλεκτρολόγος', 'Υδραυλικός', 'Ψυκτικός', 'Ελαιοχρωματιστής',
      'Μηχανικός', 'Κτίστης', 'Ξυλουργός', 'Υαλουργός',
      'Τεχνικός Ανελκυστήρων', 'Αποφράξεις', 'Αλουμινάς', 'Πλακάς',
      'Συντήρηση Κλιματιστικών', 'Εγκατάσταση Ηλιακών',
      'Υπηρεσία Αποξήλωσης',
      'Πόρτες Ασφαλείας', 'Τέντες', 'Μονώσεις', 'Σιδηρουργός', 'Μαρμαράς',
    ]
  },
  {
    'category': 'Υγεία',
    'items': [
      'Παθολόγος', 'Παιδίατρος', 'Οδοντίατρος', 'Φυσιοθεραπευτής',
      'Ψυχολόγος', 'Διατροφολόγος', 'Νοσηλευτής κατ\' οίκον'
    ]
  },
  {
    'category': 'Σπίτι',
    'items': ['Καθαρίστρια', 'Κηπουρός', 'Baby Sitter', 'Μετακομίσεις']
  },
  {
    'category': 'Εκπαίδευση',
    'items': [
      'Καθηγητής Μαθηματικών',
      'Καθηγητής Αγγλικών',
      'Καθηγητής Γαλλικών',
      'Καθηγητής Ιταλικών',
class _ProDashboardButton extends StatelessWidget {
  final String userId;
  const _ProDashboardButton({required this.userId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('notifications')
          .where('isRead', isEqualTo: false)
          .snapshots(),
      builder: (context, snap) {
        final count = snap.hasData ? snap.data!.docs.length : 0;
        return GestureDetector(
          onTap: () => Navigator.push(
            context,
            PageRouteBuilder(
              transitionDuration: const Duration(milliseconds: 400),
              pageBuilder: (_, __, ___) => const ProfessionalHomeScreen(),
              transitionsBuilder: (_, a, __, c) =>
                  FadeTransition(opacity: a, child: c),
            ),
          ),
          child: Stack(clipBehavior: Clip.none, children: [
            Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: kGold.withValues(alpha: 0.1),
                border: Border.all(color: kGold.withValues(alpha: 0.45)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.work_outline_rounded, color: kGold, size: 14),
                const SizedBox(width: 6),
                const Text('Επαγγελματίας',
                    style: TextStyle(
                        color: kGold,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2)),
                const SizedBox(width: 4),
                Icon(Icons.arrow_forward_ios_rounded, color: kGold.withValues(alpha: 0.6), size: 11),
              ]),
            ),
            if (count > 0)
              Positioned(
                top: -4,
                right: -4,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: const BoxDecoration(
                      color: Colors.red, shape: BoxShape.circle),
                  child: Center(
                    child: Text(count > 9 ? '9+' : '$count',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
          ]),
        );
      },
    );
  }
}

class _ProfileRow extends StatefulWidget {
  final IconData icon;
  final String label, value;
  final VoidCallback? onTap;
  final Color? iconColor, textColor, borderColor, bgColor;
  final String? emoji;
  const _ProfileRow(
      {required this.icon,
        );
      },
    );
  }
}

class _ProfileRow extends StatefulWidget {
  final IconData icon;
  final String label, value;
  final VoidCallback? onTap;
  final Color? iconColor, textColor, borderColor, bgColor;
  final String? emoji;
  const _ProfileRow(
      {required this.icon,
      required this.label,
                Row(children: [
                  const Text('👤', style: TextStyle(fontSize: 18)),
                  const SizedBox(width: 10),
                  Text(userName, style: const TextStyle(
                      color: Colors.white, fontSize: 16,
                      fontWeight: FontWeight.w700)),
                ]),
                if (userPhone.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  GestureDetector(
                    onTap: () => launchUrl(Uri.parse('tel:\$userPhone')),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          vertical: 12, horizontal: 16),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        color: kGreen.withValues(alpha: 0.15),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.phone, color: kGreen, size: 22),
                          const SizedBox(width: 10),
                          Text(userPhone, style: const TextStyle(
                              color: kGreen, fontSize: 18,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.5)),
                        ],
                      ),
                    ),
                  ),
                ],
              ]),
            ),
            const SizedBox(height: 20),
            GestureDetector(
              onTap: () => Navigator.pop(ctx),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 13),
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    gradient: const LinearGradient(
                        colors: [kGoldLight, kGold])),
                child: const Center(child: Text('Τέλεια! 🎉',
                    style: TextStyle(color: Colors.black,
                        fontWeight: FontWeight.w800, fontSize: 15))),
              ),
            ),
          ]),
        ),
      ),
  void initState() {
    super.initState();
    _selected = List<String>.from(widget.initial);
  }
  @override
  Widget build(BuildContext context) => _PickerContainer(
        title: 'Ειδικότητες — επίλεξε όσες θέλεις',
        onOk: _selected.isNotEmpty
            ? () => Navigator.pop(context, _selected)
            : null,
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          itemCount: _specialtyCategories.length,
          itemBuilder: (_, catIdx) {
            final cat = _specialtyCategories[catIdx];
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
                child: Text(cat['category'],
                    style: TextStyle(fontFamily: 'Raleway', fontSize: 9,
                        letterSpacing: 3, color: kGold.withValues(alpha: 0.6))),
              ),
              ...(cat['items'] as List<String>).map((item) {
                final isSel = _selected.contains(item);
                return GestureDetector(
                  onTap: () => setState(() {
                    isSel ? _selected.remove(item) : _selected.add(item);
                  }),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: isSel ? kGold.withValues(alpha: 0.12) : _g(0.04),
                      border: Border.all(color: isSel ? kGold.withValues(alpha: 0.5) : _g(0.07)),
                    ),
                    child: Row(children: [
                      AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: 20, height: 20,
                          decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(4),
                              color: isSel ? kGold : Colors.transparent,
                              border: Border.all(color: isSel ? kGold : _g(0.25), width: 1.5)),
                          child: isSel
                              ? const Icon(Icons.check, color: Colors.black, size: 13)
                              : null),
                      const SizedBox(width: 12),
                      Text(item, style: TextStyle(
                            style: TextStyle(color: _g(0.3), fontSize: 14)),
                      ]))
                    : Builder(builder: (context) {
                final docs = _docs;
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                  itemCount: docs.length,
                  itemBuilder: (_, i) {
                    final d = docs[i].data() as Map<String, dynamic>;
                    final isRead = d['isRead'] == true;
                    final type = d['type'] as String? ?? '';
                    final requestId = d['requestId'] as String? ?? '';
                    final isNewRequest = type == 'new_request';
                    final isOfferAccepted = type == 'offer_accepted';
                    final isDirectRequest = type == 'direct_request';
                    final isDirectOffer = type == 'direct_offer';
                    final isDirectChat = type == 'direct_chat';

                    // Emoji βάσει τύπου
                    String emoji = '🔔';
                    if (isNewRequest) emoji = '📋';
                    if (isOfferAccepted) emoji = '🎉';
                    if (isDirectRequest) emoji = '📩';
                    if (isDirectOffer) emoji = '💬';
                    if (isDirectChat) emoji = '💬';
                    if ((d['title'] as String? ?? '').startsWith('✅')) emoji = '✅';
                    if ((d['title'] as String? ?? '').startsWith('💼')) emoji = '💼';

                    return GestureDetector(
                      onTap: () async {
                        // Σημείωσε ως διαβασμένο
                        await docs[i].reference.update({'isRead': true});
                        if (!context.mounted) return;

                        // Αν είναι new_request → άνοιξε offer dialog
                        if (isNewRequest && requestId.isNotEmpty) {
                          final reqDoc = await FirebaseFirestore.instance
                              .collection('requests').doc(requestId).get();
                          if (!context.mounted) return;
                          if (reqDoc.exists) {
                            final reqData = Map<String, dynamic>.from(reqDoc.data()!);
                            // Merge videoUrls from request into notification data for display
                            final videoUrls = reqData['videoUrls'] as List?;
                            if (videoUrls != null && videoUrls.isNotEmpty) {
                              reqData['videoUrls'] = videoUrls;
                              reqData['hasVideos'] = true;
                            }
                            _showOfferDialogFromNotif(
                                context, requestId, reqData, userId);
                          }
                        }
                        // Αν είναι offer_accepted → εμφάνισε στοιχεία χρήστη
                        if (isOfferAccepted) {
                          _showBookingAcceptedDialog(context, d);
                        }
                        // Αν είναι direct_request (legacy) → άνοιξε DirectReplyScreen
                        if (isDirectRequest) {
                          final directRequestId = d['directRequestId'] as String? ?? '';
                          if (directRequestId.isNotEmpty && context.mounted) {
                            Navigator.push(context, PageRouteBuilder(
                              pageBuilder: (_, __, ___) =>
                                  DirectReplyScreen(directRequestId: directRequestId),
                              transitionsBuilder: (_, a, __, c) =>
                                  FadeTransition(opacity: a, child: c),
                              transitionDuration: const Duration(milliseconds: 350),
                            ));
                          }
                        }
                        // Αν είναι direct_chat → άνοιξε ChatScreen απευθείας
                        if (isDirectChat) {
                          final chatId = d['chatId'] as String? ?? '';
                          final uName = d['userName'] as String? ?? 'Χρήστης';
                          if (chatId.isNotEmpty && context.mounted) {
                            Navigator.push(context, PageRouteBuilder(
                              pageBuilder: (_, __, ___) => ChatScreen(
                                chatId: chatId,
                                currentUserId: userId,
                                currentUserName: '',
                                otherName: uName,
                                isPro: true,
                              ),
                              transitionsBuilder: (_, a, __, c) =>
                                  FadeTransition(opacity: a, child: c),
                              transitionDuration: const Duration(milliseconds: 350),
                            ));
                          }
                        }

                  const SizedBox(height: 20),

                  if (!accepted) ...[
                    // Κουμπί Αποδοχή
                    GestureDetector(
                      onTap: loading ? null : () async {
                        setS2(() => loading = true);
                        // Ενημέρωσε booking status σε accepted
                        // Αν bookingId είναι γνωστό, update αυτό
                        // Αν όχι, ψάξε με requestId + professionalId
                        final requestId = notifData['requestId'] as String? ?? '';
                        if (bookingId.isNotEmpty) {
                          try {
                            await FirebaseFirestore.instance
                                .collection('bookings')
                                .doc(bookingId)
                                .update({
                              'status': 'accepted',
                              'professionalId': proId, // ← Διορθώνει empty proId
                              'respondedAt': FieldValue.serverTimestamp(),
                            });
                          } catch (_) {}
                        } else if (requestId.isNotEmpty && proId.isNotEmpty) {
                          // Fallback: βρες booking με requestId
                          try {
                            final snap = await FirebaseFirestore.instance
                                .collection('bookings')
                                .where('requestId', isEqualTo: requestId)
                                .limit(1)
                                .get();
                            for (final doc in snap.docs) {
                              await doc.reference.update({
                                'status': 'accepted',
                                'professionalId': proId,
                                'respondedAt': FieldValue.serverTimestamp(),
                              });
                            }
                          } catch (_) {}
                        }
                        setS2(() {
                          accepted = true;
                          loading = false;
                        });
                      },
                      child: Container(
                        width: double.infinity,
                        padding:
                            const EdgeInsets.symmetric(vertical: 13),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          color: loading
                              ? kGreen.withValues(alpha: 0.3)
                              : kGreen,
                        ),
                        child: Center(
                          child: loading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                      color: Colors.white, strokeWidth: 2))
                              : const Text('✅ Αποδοχή',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 15)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    GestureDetector(
                      onTap: () => Navigator.pop(ctx2),
                      child: Container(
                        width: double.infinity,
                        padding:
                            const EdgeInsets.symmetric(vertical: 11),
                        decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            color: Colors.white.withValues(alpha: 0.05)),
                        child: Center(
                            child: Text('Αργότερα',
                                style: TextStyle(
                                    color:
                                        Colors.white.withValues(alpha: 0.5),
                                    fontSize: 13))),
                      ),
                    ),
                  ] else ...[
                    GestureDetector(
                      onTap: () => Navigator.pop(ctx2),
                      child: Container(
                        width: double.infinity,
                        padding:
                            const EdgeInsets.symmetric(vertical: 13),
                        decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            gradient: const LinearGradient(
                                colors: [kGoldLight, kGold])),
                        child: const Center(
                            child: Text('Τέλεια! 🎉',
                                style: TextStyle(
                                    color: Colors.black,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 15))),
                      ),
                    ),
                  ],
                ]),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Row(children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
// MISSING LINE 15833
// MISSING LINE 15834
// MISSING LINE 15835
// MISSING LINE 15836
// MISSING LINE 15837
// MISSING LINE 15838
// MISSING LINE 15839
// MISSING LINE 15840
// MISSING LINE 15841
// MISSING LINE 15842
// MISSING LINE 15843
// MISSING LINE 15844
// MISSING LINE 15845
// MISSING LINE 15846
// MISSING LINE 15847
// MISSING LINE 15848
// MISSING LINE 15849
// MISSING LINE 15850
// MISSING LINE 15851
// MISSING LINE 15852
// MISSING LINE 15853
// MISSING LINE 15854
// MISSING LINE 15855
// MISSING LINE 15856
// MISSING LINE 15857
// MISSING LINE 15858
// MISSING LINE 15859
// MISSING LINE 15860
// MISSING LINE 15861
// MISSING LINE 15862
// MISSING LINE 15863
// MISSING LINE 15864
// MISSING LINE 15865
// MISSING LINE 15866
// MISSING LINE 15867
// MISSING LINE 15868
// MISSING LINE 15869
// MISSING LINE 15870
// MISSING LINE 15871
// MISSING LINE 15872
// MISSING LINE 15873
// MISSING LINE 15874
// MISSING LINE 15875
// MISSING LINE 15876
// MISSING LINE 15877
// MISSING LINE 15878
// MISSING LINE 15879
// MISSING LINE 15880
// MISSING LINE 15881
// MISSING LINE 15882
// MISSING LINE 15883
// MISSING LINE 15884
// MISSING LINE 15885
// MISSING LINE 15886
// MISSING LINE 15887
// MISSING LINE 15888
// MISSING LINE 15889
// MISSING LINE 15890
// MISSING LINE 15891
// MISSING LINE 15892
// MISSING LINE 15893
// MISSING LINE 15894
// MISSING LINE 15895
// MISSING LINE 15896
// MISSING LINE 15897
// MISSING LINE 15898
// MISSING LINE 15899
// MISSING LINE 15900
// MISSING LINE 15901
// MISSING LINE 15902
// MISSING LINE 15903
// MISSING LINE 15904
// MISSING LINE 15905
// MISSING LINE 15906
// MISSING LINE 15907
// MISSING LINE 15908
// MISSING LINE 15909
// MISSING LINE 15910
// MISSING LINE 15911
// MISSING LINE 15912
// MISSING LINE 15913
// MISSING LINE 15914
// MISSING LINE 15915
// MISSING LINE 15916
// MISSING LINE 15917
// MISSING LINE 15918
// MISSING LINE 15919
// MISSING LINE 15920
// MISSING LINE 15921
// MISSING LINE 15922
// MISSING LINE 15923
// MISSING LINE 15924
// MISSING LINE 15925
// MISSING LINE 15926
// MISSING LINE 15927
// MISSING LINE 15928
// MISSING LINE 15929
// MISSING LINE 15930
// MISSING LINE 15931
// MISSING LINE 15932
// MISSING LINE 15933
// MISSING LINE 15934
// MISSING LINE 15935
// MISSING LINE 15936
// MISSING LINE 15937
// MISSING LINE 15938
// MISSING LINE 15939
// MISSING LINE 15940
// MISSING LINE 15941
// MISSING LINE 15942
// MISSING LINE 15943
// MISSING LINE 15944
// MISSING LINE 15945
// MISSING LINE 15946
// MISSING LINE 15947
// MISSING LINE 15948
// MISSING LINE 15949
// MISSING LINE 15950
// MISSING LINE 15951
// MISSING LINE 15952
// MISSING LINE 15953
// MISSING LINE 15954
// MISSING LINE 15955
// MISSING LINE 15956
// MISSING LINE 15957
// MISSING LINE 15958
// MISSING LINE 15959
// MISSING LINE 15960
// MISSING LINE 15961
// MISSING LINE 15962
// MISSING LINE 15963
// MISSING LINE 15964
// MISSING LINE 15965
// MISSING LINE 15966
// MISSING LINE 15967
// MISSING LINE 15968
// MISSING LINE 15969
// MISSING LINE 15970
// MISSING LINE 15971
// MISSING LINE 15972
// MISSING LINE 15973
// MISSING LINE 15974
// MISSING LINE 15975
// MISSING LINE 15976
// MISSING LINE 15977
// MISSING LINE 15978
// MISSING LINE 15979
// MISSING LINE 15980
// MISSING LINE 15981
// MISSING LINE 15982
// MISSING LINE 15983
// MISSING LINE 15984
// MISSING LINE 15985
// MISSING LINE 15986
// MISSING LINE 15987
// MISSING LINE 15988
// MISSING LINE 15989
// MISSING LINE 15990
// MISSING LINE 15991
// MISSING LINE 15992
// MISSING LINE 15993
// MISSING LINE 15994
// MISSING LINE 15995
// MISSING LINE 15996
// MISSING LINE 15997
// MISSING LINE 15998
// MISSING LINE 15999
// MISSING LINE 16000
// MISSING LINE 16001
// MISSING LINE 16002
// MISSING LINE 16003
// MISSING LINE 16004
// MISSING LINE 16005
// MISSING LINE 16006
// MISSING LINE 16007
// MISSING LINE 16008
// MISSING LINE 16009
// MISSING LINE 16010
// MISSING LINE 16011
// MISSING LINE 16012
// MISSING LINE 16013
// MISSING LINE 16014
// MISSING LINE 16015
// MISSING LINE 16016
// MISSING LINE 16017
// MISSING LINE 16018
// MISSING LINE 16019
// MISSING LINE 16020
// MISSING LINE 16021
// MISSING LINE 16022
// MISSING LINE 16023
// MISSING LINE 16024
// MISSING LINE 16025
// MISSING LINE 16026
// MISSING LINE 16027
// MISSING LINE 16028
// MISSING LINE 16029
// MISSING LINE 16030
// MISSING LINE 16031
// MISSING LINE 16032
// MISSING LINE 16033
// MISSING LINE 16034
// MISSING LINE 16035
// MISSING LINE 16036
// MISSING LINE 16037
// MISSING LINE 16038
// MISSING LINE 16039
// MISSING LINE 16040
// MISSING LINE 16041
// MISSING LINE 16042
// MISSING LINE 16043
// MISSING LINE 16044
// MISSING LINE 16045
// MISSING LINE 16046
// MISSING LINE 16047
// MISSING LINE 16048
// MISSING LINE 16049
// MISSING LINE 16050
// MISSING LINE 16051
// MISSING LINE 16052
// MISSING LINE 16053
// MISSING LINE 16054
// MISSING LINE 16055
// MISSING LINE 16056
// MISSING LINE 16057
// MISSING LINE 16058
// MISSING LINE 16059
// MISSING LINE 16060
// MISSING LINE 16061
// MISSING LINE 16062
// MISSING LINE 16063
// MISSING LINE 16064
// MISSING LINE 16065
// MISSING LINE 16066
// MISSING LINE 16067
// MISSING LINE 16068
// MISSING LINE 16069
// MISSING LINE 16070
// MISSING LINE 16071
// MISSING LINE 16072
// MISSING LINE 16073
// MISSING LINE 16074
// MISSING LINE 16075
// MISSING LINE 16076
// MISSING LINE 16077
// MISSING LINE 16078
// MISSING LINE 16079
// MISSING LINE 16080
// MISSING LINE 16081
// MISSING LINE 16082
// MISSING LINE 16083
// MISSING LINE 16084
// MISSING LINE 16085
// MISSING LINE 16086
// MISSING LINE 16087
// MISSING LINE 16088
// MISSING LINE 16089
// MISSING LINE 16090
// MISSING LINE 16091
// MISSING LINE 16092
// MISSING LINE 16093
// MISSING LINE 16094
// MISSING LINE 16095
// MISSING LINE 16096
// MISSING LINE 16097
// MISSING LINE 16098
// MISSING LINE 16099
// MISSING LINE 16100
// MISSING LINE 16101
// MISSING LINE 16102
// MISSING LINE 16103
// MISSING LINE 16104
// MISSING LINE 16105
// MISSING LINE 16106
// MISSING LINE 16107
// MISSING LINE 16108
// MISSING LINE 16109
// MISSING LINE 16110
// MISSING LINE 16111
// MISSING LINE 16112
// MISSING LINE 16113
// MISSING LINE 16114

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Row(children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _g(0.05),
                        border: Border.all(
                            color: kGold.withValues(alpha: 0.2))),
                    child: const Icon(Icons.arrow_back_ios_new,
                        color: kGold, size: 16)),
              ),
              const SizedBox(width: 14),
              const Expanded(
                  child: Text('Ειδοποιήσεις',
                      style: TextStyle(
                          fontFamily: 'Raleway',
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
// MISSING LINE 16145
// MISSING LINE 16146
// MISSING LINE 16147
// MISSING LINE 16148
// MISSING LINE 16149
// MISSING LINE 16150
// MISSING LINE 16151
// MISSING LINE 16152
// MISSING LINE 16153
// MISSING LINE 16154
// MISSING LINE 16155
// MISSING LINE 16156
// MISSING LINE 16157
// MISSING LINE 16158
// MISSING LINE 16159
// MISSING LINE 16160
// MISSING LINE 16161
// MISSING LINE 16162
// MISSING LINE 16163
// MISSING LINE 16164
// MISSING LINE 16165
// MISSING LINE 16166
class _ProDashboardButton extends StatelessWidget {
  final String userId;
  const _ProDashboardButton({required this.userId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('notifications')
          .where('isRead', isEqualTo: false)
          .snapshots(),
      builder: (context, notifSnap) {
        final notifCount = notifSnap.hasData ? notifSnap.data!.docs.length : 0;
        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('chats')
              .where('proId', isEqualTo: userId)
              .snapshots(),
          builder: (context, chatSnap) {
            int chatUnread = 0;
            if (chatSnap.hasData) {
              for (final doc in chatSnap.data!.docs) {
                final d = doc.data() as Map<String, dynamic>;
                chatUnread += (d['unreadPro'] as int?) ?? 0;
              }
            }
            // Pro button shows ONLY unread messages (not notifications).
            // Notifications have their own bell icon inside ProfessionalHomeScreen.
            final count = chatUnread;
            return GestureDetector(
          onTap: () => Navigator.push(
            context,
            PageRouteBuilder(
              transitionDuration: const Duration(milliseconds: 400),
              pageBuilder: (_, __, ___) => const ProfessionalHomeScreen(),
              transitionsBuilder: (_, a, __, c) =>
                  FadeTransition(opacity: a, child: c),
            ),
          ),
          child: Stack(clipBehavior: Clip.none, children: [
            Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: kGold.withValues(alpha: 0.1),
                border: Border.all(color: kGold.withValues(alpha: 0.45)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.work_outline_rounded, color: kGold, size: 14),
                const SizedBox(width: 6),
                const Text('Επαγγελματίας',
                    style: TextStyle(
                        color: kGold,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2)),
                const SizedBox(width: 4),
                Icon(Icons.arrow_forward_ios_rounded, color: kGold.withValues(alpha: 0.6), size: 11),
              ]),
            ),
            if (count > 0)
              Positioned(
                top: -4,
                right: -4,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: const BoxDecoration(
                      color: Colors.red, shape: BoxShape.circle),
                  child: Center(
                    child: Text(count > 9 ? '9+' : '$count',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
          ]),
        );
          }, // end chatSnap builder
        ); // end chats StreamBuilder
      },
    );
  }
}

class _ProfileRow extends StatefulWidget {
  final IconData icon;
  final String label, value;
  final VoidCallback? onTap;
  final Color? iconColor, textColor, borderColor, bgColor;
  final String? emoji;
  const _ProfileRow(
      {required this.icon,
      required this.label,
      required this.value,
  }
}

class _ProfileRow extends StatefulWidget {
  final IconData icon;
  final String label, value;
  final VoidCallback? onTap;
  final Color? iconColor, textColor, borderColor, bgColor;
  final String? emoji;
  const _ProfileRow(
      {required this.icon,
      required this.label,
      required this.value,
// MISSING LINE 16280
// MISSING LINE 16281
// MISSING LINE 16282
// MISSING LINE 16283
// MISSING LINE 16284
// MISSING LINE 16285
// MISSING LINE 16286
// MISSING LINE 16287
// MISSING LINE 16288
// MISSING LINE 16289
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('notifications')
          .where('isRead', isEqualTo: false)
          .snapshots(),
      builder: (context, snap) {
        final count = snap.hasData ? snap.data!.docs.length : 0;
        return GestureDetector(
          onTap: () => Navigator.push(
              context,
              PageRouteBuilder(
                transitionDuration: const Duration(milliseconds: 400),
                pageBuilder: (_, __, ___) =>
                    NotificationsScreen(userId: userId),
                transitionsBuilder: (_, a, __, c) =>
                    FadeTransition(opacity: a, child: c),
              )),
          child: Stack(clipBehavior: Clip.none, children: [
            Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _g(0.05),
                    border:
                        Border.all(color: kGold.withValues(alpha: 0.2))),
                child: Icon(
                    count > 0
                        ? Icons.notifications
                        : Icons.notifications_none,
                    color: kGold.withValues(alpha: 0.7),
                    size: 17)),
            if (count > 0)
              Positioned(
                top: -4,
                right: -4,
                child: Container(
                    width: 18,
                    height: 18,
                    decoration: const BoxDecoration(
                        color: Colors.red, shape: BoxShape.circle),
                    child: Center(
                        child: Text(count > 9 ? '9+' : '$count',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold)))),
              ),
          ]),
        );
      },
    );
  }
}

// ── Pro Dashboard Button — shown in HomeScreen header for professionals only ──
class _ProDashboardButton extends StatefulWidget {
  final String userId;
  const _ProDashboardButton({required this.userId});
// MISSING LINE 16350
// MISSING LINE 16351
// MISSING LINE 16352
// MISSING LINE 16353
class _ProDashboardButtonState extends State<_ProDashboardButton> {
  List<String> _proSpecialties = [];

  @override
  void initState() {
    super.initState();
    _loadSpecialties();
  }

  Future<void> _loadSpecialties() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users').doc(widget.userId).get();
      final specs = doc.data()?['specialties'];
      if (specs is List && mounted) {
        setState(() => _proSpecialties = List<String>.from(specs.map((e) => e.toString())));
      }
    } catch (_) {}
  }

  bool _matchesRequest(Map<String, dynamic> d) {
    final profession = (d['profession'] as String? ?? '').toLowerCase().trim();
    if (profession.isEmpty) return true;
    for (final sp in _proSpecialties) {
      final spLow = sp.toLowerCase();
      if (spLow.contains(profession) || profession.contains(spLow)) return true;
    }
    return false;
  }

  bool _matchesEvent(Map<String, dynamic> d) {
    final categoryPros = List<String>.from(d['categoryPros'] ?? []);
    if (categoryPros.isEmpty) return true;
    for (final cp in categoryPros) {
      final cpLow = cp.toLowerCase();
      for (final sp in _proSpecialties) {
        final spLow = sp.toLowerCase();
        if (spLow.contains(cpLow) || cpLow.contains(spLow)) return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('notifications')
          .where('isRead', isEqualTo: false)
          .snapshots(),
      builder: (context, notifSnap) {
        final notifCount = notifSnap.hasData ? notifSnap.data!.docs.length : 0;
        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('chats')
              .where('proId', isEqualTo: userId)
              .snapshots(),
          builder: (context, chatSnap) {
            int chatUnread = 0;
            if (chatSnap.hasData) {
              for (final doc in chatSnap.data!.docs) {
                final d = doc.data() as Map<String, dynamic>;
                chatUnread += (d['unreadPro'] as int?) ?? 0;
              }
            }
            return StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('event_requests')
                  .where('status', isEqualTo: 'active')
                  .snapshots(),
              builder: (context, evSnap) {
                int eventCount = 0;
                if (evSnap.hasData) {
                  final now = DateTime.now();
                  for (final doc in evSnap.data!.docs) {
                    final data = doc.data() as Map<String, dynamic>;
                    final exp = data['expiresAt'] as Timestamp?;
                    if (exp != null && exp.toDate().isAfter(now)) eventCount++;
                  }
                }
                return StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('users').doc(userId)
                      .collection('notifications')
                      .where('isRead', isEqualTo: false)
                      .where('type', isEqualTo: 'offer_accepted')
                      .snapshots(),
                  builder: (context, acceptSnap) {
                    final acceptedCount = acceptSnap.data?.docs.length ?? 0;
                    // Pro button: unread chats + active events + accepted offer notifications
                    final count = chatUnread + eventCount + acceptedCount;
            return GestureDetector(
          onTap: () => Navigator.push(
            context,
            PageRouteBuilder(
              transitionDuration: const Duration(milliseconds: 400),
              pageBuilder: (_, __, ___) => const ProfessionalHomeScreen(),
              transitionsBuilder: (_, a, __, c) =>
                  FadeTransition(opacity: a, child: c),
            ),
          ),
          child: Stack(clipBehavior: Clip.none, children: [
            Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: kGold.withValues(alpha: 0.1),
                border: Border.all(color: kGold.withValues(alpha: 0.45)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.work_outline_rounded, color: kGold, size: 14),
                const SizedBox(width: 6),
                const Text('Επαγγελματίας',
                    style: TextStyle(
                        color: kGold,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2)),
                const SizedBox(width: 4),
                Icon(Icons.arrow_forward_ios_rounded, color: kGold.withValues(alpha: 0.6), size: 11),
              ]),
            ),
            if (count > 0)
              Positioned(
                top: -4,
                right: -4,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: const BoxDecoration(
                      color: Colors.red, shape: BoxShape.circle),
                  child: Center(
                    child: Text(count > 9 ? '9+' : '$count',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
          ]),
        );
                  }, // end acceptSnap builder
                ); // end offer_accepted StreamBuilder
              }, // end evSnap builder
            ); // end event_requests StreamBuilder
          }, // end chatSnap builder
        ); // end chats StreamBuilder
      },
    );
  }
}

class _ProfileRow extends StatefulWidget {
  final IconData icon;
  final String label, value;
  final VoidCallback? onTap;
  final Color? iconColor, textColor, borderColor, bgColor;
  final String? emoji;
  const _ProfileRow(
      {required this.icon,
      required this.label,
      required this.value,
      this.onTap,
      this.iconColor,
      this.textColor,
      this.borderColor,
      this.bgColor,
      this.emoji});
  @override
  State<_ProfileRow> createState() => _ProfileRowState();
}

class _ProfileRowState extends State<_ProfileRow> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final iconColor = widget.iconColor ?? kGold;
    final textColor = widget.textColor ?? Colors.white;
    return GestureDetector(
      onTapDown: widget.onTap != null
          ? (_) => setState(() => _pressed = true)
          : null,
      onTapUp: widget.onTap != null
          ? (_) {
              setState(() => _pressed = false);
              widget.onTap!();
            }
          : null,
      onTapCancel: widget.onTap != null
          ? () => setState(() => _pressed = false)
          : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(16),
        transform: _pressed
// MISSING LINE 16554
// MISSING LINE 16555
// MISSING LINE 16556
// MISSING LINE 16557
// MISSING LINE 16558
// MISSING LINE 16559
// MISSING LINE 16560
// MISSING LINE 16561
// MISSING LINE 16562
// MISSING LINE 16563
// MISSING LINE 16564
// MISSING LINE 16565
// MISSING LINE 16566
// MISSING LINE 16567
// MISSING LINE 16568
// MISSING LINE 16569
// MISSING LINE 16570
// MISSING LINE 16571
// MISSING LINE 16572
// MISSING LINE 16573
// MISSING LINE 16574
// MISSING LINE 16575
// MISSING LINE 16576
// MISSING LINE 16577
// MISSING LINE 16578
// MISSING LINE 16579
// MISSING LINE 16580
// MISSING LINE 16581
// MISSING LINE 16582
// MISSING LINE 16583
// MISSING LINE 16584
// MISSING LINE 16585
// MISSING LINE 16586
// MISSING LINE 16587
// MISSING LINE 16588
// MISSING LINE 16589
// MISSING LINE 16590
// MISSING LINE 16591
// MISSING LINE 16592
// MISSING LINE 16593
// MISSING LINE 16594
// MISSING LINE 16595
// MISSING LINE 16596
// MISSING LINE 16597
// MISSING LINE 16598
// MISSING LINE 16599
// MISSING LINE 16600
// MISSING LINE 16601
// MISSING LINE 16602
// MISSING LINE 16603
// MISSING LINE 16604
// MISSING LINE 16605
// MISSING LINE 16606
// MISSING LINE 16607
// MISSING LINE 16608
// MISSING LINE 16609
// MISSING LINE 16610
// MISSING LINE 16611
// MISSING LINE 16612
// MISSING LINE 16613
// MISSING LINE 16614
// MISSING LINE 16615
// MISSING LINE 16616
// MISSING LINE 16617
// MISSING LINE 16618
// MISSING LINE 16619
// MISSING LINE 16620
// MISSING LINE 16621
// MISSING LINE 16622
// MISSING LINE 16623
// MISSING LINE 16624
// MISSING LINE 16625
// MISSING LINE 16626
// MISSING LINE 16627
// MISSING LINE 16628
// MISSING LINE 16629
// MISSING LINE 16630
// MISSING LINE 16631
// MISSING LINE 16632
// MISSING LINE 16633
// MISSING LINE 16634
// MISSING LINE 16635
// MISSING LINE 16636
// MISSING LINE 16637
// MISSING LINE 16638
// MISSING LINE 16639
// MISSING LINE 16640
// MISSING LINE 16641
// MISSING LINE 16642
// MISSING LINE 16643
// MISSING LINE 16644
// MISSING LINE 16645
// MISSING LINE 16646
// MISSING LINE 16647
// MISSING LINE 16648
// MISSING LINE 16649
// MISSING LINE 16650
// MISSING LINE 16651
// MISSING LINE 16652
// MISSING LINE 16653
// MISSING LINE 16654
// MISSING LINE 16655
// MISSING LINE 16656
// MISSING LINE 16657
// MISSING LINE 16658
// MISSING LINE 16659
// MISSING LINE 16660
// MISSING LINE 16661
// MISSING LINE 16662
// MISSING LINE 16663
// MISSING LINE 16664
// MISSING LINE 16665
// MISSING LINE 16666
// MISSING LINE 16667
// MISSING LINE 16668
// MISSING LINE 16669
// MISSING LINE 16670
// MISSING LINE 16671
// MISSING LINE 16672
// MISSING LINE 16673
// MISSING LINE 16674
// MISSING LINE 16675
// MISSING LINE 16676
// MISSING LINE 16677
// MISSING LINE 16678
// MISSING LINE 16679
// MISSING LINE 16680
// MISSING LINE 16681
// MISSING LINE 16682
// MISSING LINE 16683
// MISSING LINE 16684
// MISSING LINE 16685
// MISSING LINE 16686
// MISSING LINE 16687
// MISSING LINE 16688
// MISSING LINE 16689
// MISSING LINE 16690
// MISSING LINE 16691
// MISSING LINE 16692
// MISSING LINE 16693
// MISSING LINE 16694
// MISSING LINE 16695
// MISSING LINE 16696
// MISSING LINE 16697
// MISSING LINE 16698
// MISSING LINE 16699
// MISSING LINE 16700
// MISSING LINE 16701
// MISSING LINE 16702
// MISSING LINE 16703
// MISSING LINE 16704
// MISSING LINE 16705
// MISSING LINE 16706
// MISSING LINE 16707
// MISSING LINE 16708
// MISSING LINE 16709
// MISSING LINE 16710
// MISSING LINE 16711
// MISSING LINE 16712
// MISSING LINE 16713
// MISSING LINE 16714
// MISSING LINE 16715
// MISSING LINE 16716
// MISSING LINE 16717
// MISSING LINE 16718
// MISSING LINE 16719
// MISSING LINE 16720
// MISSING LINE 16721
// MISSING LINE 16722
// MISSING LINE 16723
// MISSING LINE 16724
// MISSING LINE 16725
// MISSING LINE 16726
// MISSING LINE 16727
// MISSING LINE 16728
// MISSING LINE 16729
// MISSING LINE 16730
// MISSING LINE 16731
// MISSING LINE 16732
// MISSING LINE 16733
// MISSING LINE 16734
// MISSING LINE 16735
// MISSING LINE 16736
// MISSING LINE 16737
// MISSING LINE 16738
// MISSING LINE 16739
// MISSING LINE 16740
// MISSING LINE 16741
// MISSING LINE 16742
// MISSING LINE 16743
// MISSING LINE 16744
// MISSING LINE 16745
// MISSING LINE 16746
// MISSING LINE 16747
// MISSING LINE 16748
// MISSING LINE 16749
// MISSING LINE 16750
// MISSING LINE 16751
// MISSING LINE 16752
// MISSING LINE 16753
// MISSING LINE 16754
// MISSING LINE 16755
// MISSING LINE 16756
// MISSING LINE 16757
// MISSING LINE 16758
// MISSING LINE 16759
// MISSING LINE 16760
// MISSING LINE 16761
// MISSING LINE 16762
// MISSING LINE 16763
// MISSING LINE 16764
// MISSING LINE 16765
// MISSING LINE 16766
// MISSING LINE 16767
// MISSING LINE 16768
// MISSING LINE 16769
// MISSING LINE 16770
// MISSING LINE 16771
// MISSING LINE 16772
// MISSING LINE 16773
// MISSING LINE 16774
// MISSING LINE 16775
// MISSING LINE 16776
// MISSING LINE 16777
// MISSING LINE 16778
// MISSING LINE 16779
// MISSING LINE 16780
// MISSING LINE 16781
// MISSING LINE 16782
// MISSING LINE 16783
// MISSING LINE 16784
// MISSING LINE 16785
// MISSING LINE 16786
class _NotificationBell extends StatelessWidget {
  final String userId;
  const _NotificationBell({required this.userId});
  @override
  Widget build(BuildContext context) {
    if (userId.isEmpty) return const SizedBox(width: 34);
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('notifications')
          .where('isRead', isEqualTo: false)
          .snapshots(),
      builder: (context, snap) {
        final count = snap.hasData ? snap.data!.docs.length : 0;
        return GestureDetector(
          onTap: () => Navigator.push(
              context,
              PageRouteBuilder(
                transitionDuration: const Duration(milliseconds: 400),
                pageBuilder: (_, __, ___) =>
                    NotificationsScreen(userId: userId),
                transitionsBuilder: (_, a, __, c) =>
                    FadeTransition(opacity: a, child: c),
              )),
          child: Stack(clipBehavior: Clip.none, children: [
            Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _g(0.05),
                    border:
                        Border.all(color: kGold.withValues(alpha: 0.2))),
                child: Icon(
                    count > 0
                        ? Icons.notifications
                        : Icons.notifications_none,
                    color: kGold.withValues(alpha: 0.7),
                    size: 17)),
            if (count > 0)
              Positioned(
                top: -4,
                right: -4,
                child: Container(
                    width: 18,
                    height: 18,
                    decoration: const BoxDecoration(
                        color: Colors.red, shape: BoxShape.circle),
                    child: Center(
                        child: Text(count > 9 ? '9+' : '$count',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold)))),
              ),
          ]),
        );
      },
    );
  }
}

// ── Pro Dashboard Button — shown in HomeScreen header for professionals only ──
class _ProDashboardButton extends StatefulWidget {
  final String userId;
  const _ProDashboardButton({required this.userId});
  @override
  State<_ProDashboardButton> createState() => _ProDashboardButtonState();
}

class _ProDashboardButtonState extends State<_ProDashboardButton> {
  List<String> _proSpecialties = [];

  @override
  void initState() {
    super.initState();
    _loadSpecialties();
  }

// MISSING LINE 16867
// MISSING LINE 16868
// MISSING LINE 16869
// MISSING LINE 16870
// MISSING LINE 16871
// MISSING LINE 16872
// MISSING LINE 16873
// MISSING LINE 16874
// MISSING LINE 16875
// MISSING LINE 16876
// MISSING LINE 16877
// MISSING LINE 16878
// MISSING LINE 16879
// MISSING LINE 16880
// MISSING LINE 16881
// MISSING LINE 16882
// MISSING LINE 16883
// MISSING LINE 16884
// MISSING LINE 16885
// MISSING LINE 16886
// MISSING LINE 16887
// MISSING LINE 16888
// MISSING LINE 16889
// MISSING LINE 16890
// MISSING LINE 16891
// MISSING LINE 16892
// MISSING LINE 16893
// MISSING LINE 16894
// MISSING LINE 16895
// MISSING LINE 16896
// MISSING LINE 16897
// MISSING LINE 16898
// MISSING LINE 16899
// MISSING LINE 16900
// MISSING LINE 16901
// MISSING LINE 16902
// MISSING LINE 16903
// MISSING LINE 16904
// MISSING LINE 16905
// MISSING LINE 16906
// MISSING LINE 16907
// MISSING LINE 16908
// MISSING LINE 16909
// MISSING LINE 16910
// MISSING LINE 16911
// MISSING LINE 16912
// MISSING LINE 16913
// MISSING LINE 16914
// MISSING LINE 16915
// MISSING LINE 16916
// MISSING LINE 16917
// MISSING LINE 16918
// MISSING LINE 16919
// MISSING LINE 16920
// MISSING LINE 16921
// MISSING LINE 16922
// MISSING LINE 16923
// MISSING LINE 16924
// MISSING LINE 16925
// MISSING LINE 16926
// MISSING LINE 16927
// MISSING LINE 16928
// MISSING LINE 16929
// MISSING LINE 16930
// MISSING LINE 16931
// MISSING LINE 16932
// MISSING LINE 16933
// MISSING LINE 16934
// MISSING LINE 16935
// MISSING LINE 16936
// MISSING LINE 16937
// MISSING LINE 16938
// MISSING LINE 16939
// MISSING LINE 16940
// MISSING LINE 16941
// MISSING LINE 16942
// MISSING LINE 16943
// MISSING LINE 16944
// MISSING LINE 16945
// MISSING LINE 16946
// MISSING LINE 16947
// MISSING LINE 16948
// MISSING LINE 16949
// MISSING LINE 16950
// MISSING LINE 16951
// MISSING LINE 16952
// MISSING LINE 16953
// MISSING LINE 16954
// MISSING LINE 16955
// MISSING LINE 16956
// MISSING LINE 16957
// MISSING LINE 16958
// MISSING LINE 16959
// MISSING LINE 16960
// MISSING LINE 16961
// MISSING LINE 16962
// MISSING LINE 16963
// MISSING LINE 16964
// MISSING LINE 16965
// MISSING LINE 16966
// MISSING LINE 16967
// MISSING LINE 16968
// MISSING LINE 16969
// MISSING LINE 16970
// MISSING LINE 16971
// MISSING LINE 16972
// MISSING LINE 16973
// MISSING LINE 16974
// MISSING LINE 16975
// MISSING LINE 16976
// MISSING LINE 16977
// MISSING LINE 16978
// MISSING LINE 16979
// MISSING LINE 16980
// MISSING LINE 16981
// MISSING LINE 16982
// MISSING LINE 16983
// MISSING LINE 16984
// MISSING LINE 16985
// MISSING LINE 16986
// MISSING LINE 16987
// MISSING LINE 16988
// MISSING LINE 16989
// MISSING LINE 16990
// MISSING LINE 16991
// MISSING LINE 16992
// MISSING LINE 16993
// MISSING LINE 16994
// MISSING LINE 16995
// MISSING LINE 16996
// MISSING LINE 16997
// MISSING LINE 16998
// MISSING LINE 16999
// MISSING LINE 17000
// MISSING LINE 17001
// MISSING LINE 17002
// MISSING LINE 17003
// MISSING LINE 17004
// MISSING LINE 17005
// MISSING LINE 17006
// MISSING LINE 17007
// MISSING LINE 17008
// MISSING LINE 17009
// MISSING LINE 17010
// MISSING LINE 17011
// MISSING LINE 17012
// MISSING LINE 17013
// MISSING LINE 17014
// MISSING LINE 17015
// MISSING LINE 17016
// MISSING LINE 17017
// MISSING LINE 17018
// MISSING LINE 17019
// MISSING LINE 17020
// MISSING LINE 17021
// MISSING LINE 17022
// MISSING LINE 17023
// MISSING LINE 17024
// MISSING LINE 17025
// MISSING LINE 17026
// MISSING LINE 17027
// MISSING LINE 17028
// MISSING LINE 17029
// MISSING LINE 17030
// MISSING LINE 17031
// MISSING LINE 17032
// MISSING LINE 17033
// MISSING LINE 17034
// MISSING LINE 17035
// MISSING LINE 17036
// MISSING LINE 17037
// MISSING LINE 17038
// MISSING LINE 17039
// MISSING LINE 17040
// MISSING LINE 17041
// MISSING LINE 17042
// MISSING LINE 17043
// MISSING LINE 17044
// MISSING LINE 17045
// MISSING LINE 17046
// MISSING LINE 17047
// MISSING LINE 17048
// MISSING LINE 17049
// MISSING LINE 17050
// MISSING LINE 17051
// MISSING LINE 17052
// MISSING LINE 17053
// MISSING LINE 17054
// MISSING LINE 17055
// MISSING LINE 17056
// MISSING LINE 17057
// MISSING LINE 17058
// MISSING LINE 17059
// MISSING LINE 17060
// MISSING LINE 17061
// MISSING LINE 17062
// MISSING LINE 17063
// MISSING LINE 17064
// MISSING LINE 17065
// MISSING LINE 17066
// MISSING LINE 17067
// MISSING LINE 17068
// MISSING LINE 17069
// MISSING LINE 17070
// MISSING LINE 17071
// MISSING LINE 17072
// MISSING LINE 17073
// MISSING LINE 17074
// MISSING LINE 17075
// MISSING LINE 17076
// MISSING LINE 17077
// MISSING LINE 17078
// MISSING LINE 17079
// MISSING LINE 17080
// MISSING LINE 17081
// MISSING LINE 17082
// MISSING LINE 17083
// MISSING LINE 17084
// MISSING LINE 17085
// MISSING LINE 17086
// MISSING LINE 17087
// MISSING LINE 17088
// MISSING LINE 17089
// MISSING LINE 17090
// MISSING LINE 17091
// MISSING LINE 17092
// MISSING LINE 17093
// MISSING LINE 17094
// MISSING LINE 17095
// MISSING LINE 17096
// MISSING LINE 17097
// MISSING LINE 17098
// MISSING LINE 17099

  @override
  void dispose() {
    _nameCtrl.dispose();
    _cityCtrl.dispose();
    _oldPassCtrl.dispose();
    _newPassCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() => _loading = false);
      return;
    }
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _name = doc.data()?['name'] ?? user.displayName ?? '';
      _city = doc.data()?['city'] ?? '';
      _email = user.email ?? '';
      _photoUrl = doc.data()?['profilePhotoUrl'] as String?;
      _isPremium = kFreeForAll || doc.data()?['isPremium'] == true || doc.data()?['isOwner'] == true;
      _nameCtrl.text = _name ?? '';
      _cityCtrl.text = _city ?? '';
      _biometricOn = prefs.getBool('biometric_enabled') ?? true;
      _loading = false;
    });
    // Detect pro type for pricing
    try {
      final proSnap = await FirebaseFirestore.instance
          .collection('professionals')
          .where('userId', isEqualTo: user.uid)
          .limit(1)
          .get();
      if (proSnap.docs.isNotEmpty) {
        final pd = proSnap.docs.first.data();
        final mainSpec = (pd['specialty'] as String? ?? '').toLowerCase();
        final specs = [mainSpec, ...List<String>.from(pd['specialties'] ?? []).map((s) => s.toLowerCase())];
        final isBusiness = specs.any((s) => s.contains('συνεργείο'));
        final isEventPro = specs.any((s) => _kEventSpecialties.contains(s));
        if (mounted) setState(() => _subscriptionPrice = (isBusiness || isEventPro) ? '59,99' : '19,99');
      }
    } catch (_) {}
  }

  void _confirmDeleteAccount(BuildContext ctx) {
    showDialog(
      context: ctx,
      builder: (c) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            color: const Color(0xFF0D0A04),
            border: Border.all(color: Colors.red.withValues(alpha: 0.4), width: 1.5),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('🗑️', style: TextStyle(fontSize: 44)),
            const SizedBox(height: 12),
            const Text('Διαγραφή λογαριασμού;',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontFamily: 'Raleway',
                    fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            Text('Θα διαγραφούν μόνιμα όλα σου τα δεδομένα (προφίλ, αιτήματα, chat, κρατήσεις). Αυτή η ενέργεια δεν αναιρείται.',
                textAlign: TextAlign.center,
// MISSING LINE 17173
// MISSING LINE 17174
// MISSING LINE 17175
// MISSING LINE 17176
// MISSING LINE 17177
// MISSING LINE 17178
// MISSING LINE 17179
// MISSING LINE 17180
// MISSING LINE 17181
// MISSING LINE 17182
// MISSING LINE 17183
// MISSING LINE 17184
// MISSING LINE 17185
// MISSING LINE 17186
// MISSING LINE 17187
// MISSING LINE 17188
// MISSING LINE 17189
      'Ηλεκτρολόγος', 'Υδραυλικός', 'Ψυκτικός', 'Ελαιοχρωματιστής',
      'Μηχανικός', 'Κτίστης', 'Ξυλουργός', 'Υαλουργός',
      'Τεχνικός Ανελκυστήρων', 'Αποφράξεις', 'Αλουμινάς', 'Πλακάς',
      'Συντήρηση Κλιματιστικών', 'Εγκατάσταση Ηλιακών',
      'Υπηρεσία Αποξήλωσης',
      'Πόρτες Ασφαλείας', 'Τέντες', 'Μονώσεις', 'Σιδηρουργός', 'Μαρμαράς',
    ]
  },
  {
    'category': 'Υγεία',
    'items': [
      'Παθολόγος', 'Παιδίατρος', 'Οδοντίατρος', 'Φυσιοθεραπευτής',
      'Ψυχολόγος', 'Διατροφολόγος', 'Νοσηλευτής κατ\' οίκον'
    ]
  },
  {
    'category': 'Σπίτι',
    'items': ['Καθαρίστρια', 'Κηπουρός', 'Baby Sitter', 'Μετακομίσεις']
  },
  {
    'category': 'Εκπαίδευση',
    'items': [
      'Καθηγητής Μαθηματικών',
      'Καθηγητής Αγγλικών',
      'Καθηγητής Γαλλικών',
      'Καθηγητής Ιταλικών',
      'Καθηγητής Γερμανικών',
      'Καθηγητής Ισπανικών',
      'Φιλόλογος',
      'Καθηγητής Φυσικής',
      'Καθηγητής Χημείας',
      'Καθηγητής Πληροφορικής',
      'Καθηγητής Βιολογίας',
      'Personal Trainer'
    ]
  },
  {
    'category': 'Ψηφιακές',
    'items': [
      'Web Developer',
      'Γραφίστας',
      'Φωτογράφος',
      'Τεχνικός Υπολογιστών'
    ]
  },
  {
    'category': 'Εκδηλώσεις',
    'items': [
      'Εκδηλώσεις Γάμου',
      'Εκδηλώσεις Βάφτισης',
      'Διοργάνωση Πάρτυ',
      'Φωτογράφος Γάμου',
      'DJ / Μουσική Εκδηλώσεων',
      'Catering',
      'Ανθοδέτης / Στολισμός',
      'Αίθουσα Εκδηλώσεων',
    ]
  },
  {
    'category': 'Ομορφιά & Αισθητική',
    'items': ['Tattoo Artist', 'Τεχνίτρια Νυχιών']
  },
  {
    'category': 'Άλλα',
    'items': ['Μηχανικός Αυτοκινήτων', 'Λογιστής', 'Δικηγόρος', 'Αρχιτέκτονας']
  },
  {
    'category': 'Συνεργεία',
    'items': [
      'Συνεργείο Ανακαίνισης',
      'Συνεργείο Κατασκευών',
      'Συνεργείο Βαφής & Διακόσμησης',
      'Συνεργείο Ηλεκτρολόγων',
      'Συνεργείο Υδραυλικών',
      'Συνεργείο Κλιματισμού',
      'Συνεργείο Αλουμινίου & Κουφωμάτων',
      'Συνεργείο Πλακιδίων & Δαπέδων',
      'Συνεργείο Κήπου & Εξωτερικών Χώρων',
      'Συνεργείο Γυψοσανίδας & Οροφής',
      'Συνεργείο Ξυλουργικών Εργασιών',
    ]
  },
];

// ── Multi-pick field shown in registration form ──────────────────────
class _MultiPickerField extends StatelessWidget {
  final String hint;
  final String subtitle;
  final IconData icon;
  final List<String> selected;
  final VoidCallback onTap;
  final void Function(String) onRemove;
  const _MultiPickerField({
    required this.hint, required this.subtitle, required this.icon,
    required this.selected, required this.onTap, required this.onRemove,
  });
  @override
  Widget build(BuildContext context) {
// MISSING LINE 17288
// MISSING LINE 17289
// MISSING LINE 17290
// MISSING LINE 17291
// MISSING LINE 17292
// MISSING LINE 17293
// MISSING LINE 17294
// MISSING LINE 17295
// MISSING LINE 17296
// MISSING LINE 17297
// MISSING LINE 17298
// MISSING LINE 17299
// MISSING LINE 17300
// MISSING LINE 17301
// MISSING LINE 17302
// MISSING LINE 17303
// MISSING LINE 17304
// MISSING LINE 17305
// MISSING LINE 17306
// MISSING LINE 17307
// MISSING LINE 17308
// MISSING LINE 17309
// MISSING LINE 17310
// MISSING LINE 17311
// MISSING LINE 17312
// MISSING LINE 17313
// MISSING LINE 17314
// MISSING LINE 17315
// MISSING LINE 17316
// MISSING LINE 17317
// MISSING LINE 17318
// MISSING LINE 17319
// MISSING LINE 17320
// MISSING LINE 17321
// MISSING LINE 17322
// MISSING LINE 17323
// MISSING LINE 17324
// MISSING LINE 17325
// MISSING LINE 17326
// MISSING LINE 17327
// MISSING LINE 17328
// MISSING LINE 17329
// MISSING LINE 17330
// MISSING LINE 17331
// MISSING LINE 17332
class _NotificationBell extends StatelessWidget {
  final String userId;
  const _NotificationBell({required this.userId});
  @override
  Widget build(BuildContext context) {
    if (userId.isEmpty) return const SizedBox(width: 34);
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('notifications')
          .where('isRead', isEqualTo: false)
          .snapshots(),
      builder: (context, snap) {
        final count = snap.hasData ? snap.data!.docs.length : 0;
        return GestureDetector(
          onTap: () => Navigator.push(
              context,
              PageRouteBuilder(
                transitionDuration: const Duration(milliseconds: 400),
                pageBuilder: (_, __, ___) =>
                    NotificationsScreen(userId: userId),
                transitionsBuilder: (_, a, __, c) =>
                    FadeTransition(opacity: a, child: c),
              )),
          child: Stack(clipBehavior: Clip.none, children: [
            Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _g(0.05),
                    border:
                        Border.all(color: kGold.withValues(alpha: 0.2))),
                child: Icon(
                    count > 0
                        ? Icons.notifications
                        : Icons.notifications_none,
                    color: kGold.withValues(alpha: 0.7),
                    size: 17)),
            if (count > 0)
              Positioned(
                top: -4,
                right: -4,
                child: Container(
                    width: 18,
                    height: 18,
                    decoration: const BoxDecoration(
                        color: Colors.red, shape: BoxShape.circle),
                    child: Center(
                        child: Text(count > 9 ? '9+' : '$count',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold)))),
              ),
          ]),
        );
      },
    );
  }
}

// ── Pro Dashboard Button — shown in HomeScreen header for professionals only ──
class _ProDashboardButton extends StatefulWidget {
  final String userId;
  const _ProDashboardButton({required this.userId});
  @override
  State<_ProDashboardButton> createState() => _ProDashboardButtonState();
}

class _ProDashboardButtonState extends State<_ProDashboardButton> {
  List<String> _proSpecialties = [];

  @override
  void initState() {
    super.initState();
    _loadSpecialties();
  }

  Future<void> _loadSpecialties() async {
    try {
      final allSpecs = <String>{};
      // Load from users doc
      final doc = await FirebaseFirestore.instance
          .collection('users').doc(widget.userId).get();
      final rawSpecs = doc.data()?['specialties'];
      if (rawSpecs is List) {
        allSpecs.addAll(rawSpecs.map((e) => e.toString()));
      }
      // Also load from professionals collection (primary source of specialties)
      final proSnap = await FirebaseFirestore.instance
          .collection('professionals')
          .where('userId', isEqualTo: widget.userId)
          .limit(1)
          .get();
      if (proSnap.docs.isNotEmpty) {
        final pd = proSnap.docs.first.data();
        final main = pd['specialty'] as String? ?? '';
        if (main.isNotEmpty) allSpecs.add(main);
        final proSpecs = pd['specialties'];
        if (proSpecs is List) allSpecs.addAll(proSpecs.map((e) => e.toString()));
      }
      if (mounted) setState(() => _proSpecialties = allSpecs.toList());
    } catch (_) {}
  }

  bool _matchesRequest(Map<String, dynamic> d) {
    final profession = (d['profession'] as String? ?? '').toLowerCase().trim();
    if (profession.isEmpty) return true;
    for (final sp in _proSpecialties) {
      final spLow = sp.toLowerCase();
      if (spLow.contains(profession) || profession.contains(spLow)) return true;
    }
    return false;
  }

  bool _matchesEvent(Map<String, dynamic> d) {
    final categoryPros = List<String>.from(d['categoryPros'] ?? []);
    // Old docs without categoryPros → only event-category professionals
    if (categoryPros.isEmpty) {
      return _proSpecialties.any((sp) =>
          _kEventSpecialties.contains(sp.toLowerCase()));
    }
    final cpLowList = categoryPros.map((cp) => cp.toLowerCase()).toList();
    for (final sp in _proSpecialties) {
      final spLow = sp.toLowerCase();
      // Pro's specialty must CONTAIN the categoryPros keyword (not reverse)
      for (final cpLow in cpLowList) {
        if (spLow.contains(cpLow)) return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('chats')
          .where('proId', isEqualTo: widget.userId)
          .snapshots(),
      builder: (context, chatSnap) {
        int chatUnread = 0;
        if (chatSnap.hasData) {
          for (final doc in chatSnap.data!.docs) {
            final d = doc.data() as Map<String, dynamic>;
            chatUnread += (d['unreadPro'] as int?) ?? 0;
          }
        }
        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('event_requests')
              .where('status', isEqualTo: 'active')
              .snapshots(),
          builder: (context, evSnap) {
            int eventCount = 0;
            if (evSnap.hasData) {
              final now = DateTime.now();
              for (final doc in evSnap.data!.docs) {
                final data = doc.data() as Map<String, dynamic>;
                final exp = data['expiresAt'] as Timestamp?;
                if (exp != null && exp.toDate().isAfter(now) && _matchesEvent(data)) {
                  eventCount++;
                }
              }
            }
            return StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('users').doc(widget.userId)
                  .collection('notifications')
                  .where('isRead', isEqualTo: false)
                  .where('type', isEqualTo: 'offer_accepted')
                  .snapshots(),
              builder: (context, acceptSnap) {
                final acceptedCount = acceptSnap.data?.docs.length ?? 0;
                return StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('requests')
                      .where('status', isEqualTo: 'active')
                      .snapshots(),
                  builder: (context, reqSnap) {
                    int matchingReqCount = 0;
                    if (reqSnap.hasData) {
                      for (final doc in reqSnap.data!.docs) {
                        final data = doc.data() as Map<String, dynamic>;
                        if (_matchesRequest(data)) matchingReqCount++;
                      }
                    }
                    // Pro button: unread chats + matching events + accepted notifications + matching requests
                    final count = chatUnread + eventCount + acceptedCount + matchingReqCount;
            return GestureDetector(
          onTap: () => Navigator.push(
            context,
            PageRouteBuilder(
              transitionDuration: const Duration(milliseconds: 400),
              pageBuilder: (_, __, ___) => const ProfessionalHomeScreen(),
              transitionsBuilder: (_, a, __, c) =>
                  FadeTransition(opacity: a, child: c),
            ),
          ),
          child: Stack(clipBehavior: Clip.none, children: [
            Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: kGold.withValues(alpha: 0.1),
                border: Border.all(color: kGold.withValues(alpha: 0.45)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.work_outline_rounded, color: kGold, size: 14),
                const SizedBox(width: 6),
                const Text('Επαγγελματίας',
                    style: TextStyle(
                        color: kGold,
                        fontSize: 12,
              )),
          child: Stack(clipBehavior: Clip.none, children: [
            Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _g(0.05),
                    border:
                        Border.all(color: kGold.withValues(alpha: 0.2))),
                child: Icon(
                    count > 0
                        ? Icons.notifications
                        : Icons.notifications_none,
                    color: kGold.withValues(alpha: 0.7),
                    size: 17)),
            if (count > 0)
              Positioned(
                top: -4,
                right: -4,
                child: Container(
                    width: 18,
                    height: 18,
                    decoration: const BoxDecoration(
                        color: Colors.red, shape: BoxShape.circle),
  {
    'category': 'Σπίτι',
    'items': ['Καθαρίστρια', 'Κηπουρός', 'Baby Sitter', 'Μετακομίσεις']
  },
  {
    'category': 'Εκπαίδευση',
    'items': [
      'Καθηγητής Μαθηματικών',
      'Καθηγητής Αγγλικών',
      'Καθηγητής Γαλλικών',
      'Καθηγητής Ιταλικών',
      'Καθηγητής Γερμανικών',
      'Καθηγητής Ισπανικών',
      'Φιλόλογος',
      'Καθηγητής Φυσικής',
      'Καθηγητής Χημείας',
      'Καθηγητής Πληροφορικής',
      'Καθηγητής Βιολογίας',
      'Personal Trainer'
    ]
}

class _ProDashboardButtonState extends State<_ProDashboardButton> {
  List<String> _proSpecialties = [];

  @override
  void initState() {
    super.initState();
    _loadSpecialties();
  }

  Future<void> _loadSpecialties() async {
    try {
      final allSpecs = <String>{};
      // Load from users doc
      final doc = await FirebaseFirestore.instance
          .collection('users').doc(widget.userId).get();
      final rawSpecs = doc.data()?['specialties'];
      if (rawSpecs is List) {
        allSpecs.addAll(rawSpecs.map((e) => e.toString()));
      }
      // Also load from professionals collection (primary source of specialties)
      final proSnap = await FirebaseFirestore.instance
          .collection('professionals')
          .where('userId', isEqualTo: widget.userId)
          .limit(1)
          .get();
      if (proSnap.docs.isNotEmpty) {
        final pd = proSnap.docs.first.data();
        final main = pd['specialty'] as String? ?? '';
        if (main.isNotEmpty) allSpecs.add(main);
        final proSpecs = pd['specialties'];
        if (proSpecs is List) allSpecs.addAll(proSpecs.map((e) => e.toString()));
      }
      if (mounted) setState(() => _proSpecialties = allSpecs.toList());
    } catch (_) {}
  }

  bool _matchesRequest(Map<String, dynamic> d) {
    final profession = (d['profession'] as String? ?? '').toLowerCase().trim();
    if (profession.isEmpty) return true;
    for (final sp in _proSpecialties) {
      final spLow = sp.toLowerCase();
      if (spLow.contains(profession) || profession.contains(spLow)) return true;
    }
    return false;
  }

  bool _matchesEvent(Map<String, dynamic> d) {
    final categoryPros = List<String>.from(d['categoryPros'] ?? []);
    // Old docs without categoryPros → only event-category professionals
    if (categoryPros.isEmpty) {
      return _proSpecialties.any((sp) =>
          _kEventSpecialties.contains(sp.toLowerCase()));
    }
    final cpLowList = categoryPros.map((cp) => cp.toLowerCase()).toList();
    for (final sp in _proSpecialties) {
      final spLow = sp.toLowerCase();
      // Pro's specialty must CONTAIN the categoryPros keyword (not reverse)
      for (final cpLow in cpLowList) {
        if (spLow.contains(cpLow)) return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('chats')
          .where('proId', isEqualTo: widget.userId)
          .snapshots(),
      builder: (context, chatSnap) {
        int chatUnread = 0;
        if (chatSnap.hasData) {
          for (final doc in chatSnap.data!.docs) {
            final d = doc.data() as Map<String, dynamic>;
            chatUnread += (d['unreadPro'] as int?) ?? 0;
          }
        }
        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('event_requests')
              .where('status', isEqualTo: 'active')
              .snapshots(),
          builder: (context, evSnap) {
            int eventCount = 0;
            if (evSnap.hasData) {
              final now = DateTime.now();
              for (final doc in evSnap.data!.docs) {
                final data = doc.data() as Map<String, dynamic>;
                final exp = data['expiresAt'] as Timestamp?;
                if (exp != null && exp.toDate().isAfter(now) && _matchesEvent(data)) {
                  eventCount++;
                }
              }
            }
            return StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('users').doc(widget.userId)
                  .collection('notifications')
                  .where('isRead', isEqualTo: false)
                  .where('type', isEqualTo: 'offer_accepted')
                  .snapshots(),
              builder: (context, acceptSnap) {
                final acceptedCount = acceptSnap.data?.docs.length ?? 0;
                return StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('requests')
                      .where('status', isEqualTo: 'active')
                      .snapshots(),
                  builder: (context, reqSnap) {
                    int matchingReqCount = 0;
                    if (reqSnap.hasData) {
                      for (final doc in reqSnap.data!.docs) {
                        final data = doc.data() as Map<String, dynamic>;
                        if (_matchesRequest(data)) matchingReqCount++;
                      }
                    }
                    // Pro button: unread chats + matching events + accepted notifications + matching requests
                    final count = chatUnread + eventCount + acceptedCount + matchingReqCount;
            return GestureDetector(
          onTap: () => Navigator.push(
            context,
            PageRouteBuilder(
              transitionDuration: const Duration(milliseconds: 400),
              pageBuilder: (_, __, ___) => const ProfessionalHomeScreen(),
              transitionsBuilder: (_, a, __, c) =>
                  FadeTransition(opacity: a, child: c),
            ),
          ),
          child: Stack(clipBehavior: Clip.none, children: [
            Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: kGold.withValues(alpha: 0.1),
                border: Border.all(color: kGold.withValues(alpha: 0.45)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.work_outline_rounded, color: kGold, size: 14),
                const SizedBox(width: 6),
                const Text('Επαγγελματίας',
                    style: TextStyle(
                        color: kGold,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2)),
                const SizedBox(width: 4),
                Icon(Icons.arrow_forward_ios_rounded, color: kGold.withValues(alpha: 0.6), size: 11),
              ]),
            ),
            if (count > 0)
              Positioned(
                top: -4,
                right: -4,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: const BoxDecoration(
                      color: Colors.red, shape: BoxShape.circle),
                  child: Center(
                    child: Text(count > 9 ? '9+' : '$count',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
          ]),
        );
                  }, // end reqSnap builder
                ); // end requests StreamBuilder
              }, // end acceptSnap builder
            ); // end offer_accepted StreamBuilder
          }, // end evSnap builder
        ); // end event_requests StreamBuilder
      }, // end chatSnap builder
    ); // end chats StreamBuilder
  }
}

class _ProfileRow extends StatefulWidget {
  final IconData icon;
  final String label, value;
  final VoidCallback? onTap;
  final Color? iconColor, textColor, borderColor, bgColor;
  final String? emoji;
  const _ProfileRow(
      {required this.icon,
      required this.label,
      required this.value,
      this.onTap,
      this.iconColor,
      this.textColor,
      this.borderColor,
      this.bgColor,
// MISSING LINE 17795
// MISSING LINE 17796
// MISSING LINE 17797
// MISSING LINE 17798
// MISSING LINE 17799
// MISSING LINE 17800
// MISSING LINE 17801
// MISSING LINE 17802
// MISSING LINE 17803
// MISSING LINE 17804
// MISSING LINE 17805
// MISSING LINE 17806
// MISSING LINE 17807
// MISSING LINE 17808
// MISSING LINE 17809
// MISSING LINE 17810
// MISSING LINE 17811
// MISSING LINE 17812
// MISSING LINE 17813
// MISSING LINE 17814
// MISSING LINE 17815
// MISSING LINE 17816
// MISSING LINE 17817
// MISSING LINE 17818
// MISSING LINE 17819
// MISSING LINE 17820
// MISSING LINE 17821
// MISSING LINE 17822
// MISSING LINE 17823
// MISSING LINE 17824
// MISSING LINE 17825
// MISSING LINE 17826
// MISSING LINE 17827
// MISSING LINE 17828
// MISSING LINE 17829
// MISSING LINE 17830
// MISSING LINE 17831
// MISSING LINE 17832
// MISSING LINE 17833
// MISSING LINE 17834
// MISSING LINE 17835
// MISSING LINE 17836
// MISSING LINE 17837
// MISSING LINE 17838
// MISSING LINE 17839
// MISSING LINE 17840
// MISSING LINE 17841
// MISSING LINE 17842
// MISSING LINE 17843
// MISSING LINE 17844
// MISSING LINE 17845
// MISSING LINE 17846
// MISSING LINE 17847
// MISSING LINE 17848
// MISSING LINE 17849
// MISSING LINE 17850
// MISSING LINE 17851
// MISSING LINE 17852
// MISSING LINE 17853
// MISSING LINE 17854
// MISSING LINE 17855
// MISSING LINE 17856
// MISSING LINE 17857
// MISSING LINE 17858
// MISSING LINE 17859
// MISSING LINE 17860
// MISSING LINE 17861
// MISSING LINE 17862
// MISSING LINE 17863
// MISSING LINE 17864
// MISSING LINE 17865
// MISSING LINE 17866
// MISSING LINE 17867
// MISSING LINE 17868
// MISSING LINE 17869
// MISSING LINE 17870
// MISSING LINE 17871
// MISSING LINE 17872
// MISSING LINE 17873
// MISSING LINE 17874
// MISSING LINE 17875
// MISSING LINE 17876
// MISSING LINE 17877
// MISSING LINE 17878
// MISSING LINE 17879
// MISSING LINE 17880
// MISSING LINE 17881
// MISSING LINE 17882
// MISSING LINE 17883
// MISSING LINE 17884
// MISSING LINE 17885
// MISSING LINE 17886
// MISSING LINE 17887
// MISSING LINE 17888
// MISSING LINE 17889
// MISSING LINE 17890
// MISSING LINE 17891
// MISSING LINE 17892
// MISSING LINE 17893
// MISSING LINE 17894
// MISSING LINE 17895
// MISSING LINE 17896
// MISSING LINE 17897
// MISSING LINE 17898
// MISSING LINE 17899
// MISSING LINE 17900
// MISSING LINE 17901
// MISSING LINE 17902
// MISSING LINE 17903
// MISSING LINE 17904
// MISSING LINE 17905
// MISSING LINE 17906
// MISSING LINE 17907
// MISSING LINE 17908
// MISSING LINE 17909
// MISSING LINE 17910
// MISSING LINE 17911
// MISSING LINE 17912
// MISSING LINE 17913
// MISSING LINE 17914
// MISSING LINE 17915
// MISSING LINE 17916
// MISSING LINE 17917
// MISSING LINE 17918
// MISSING LINE 17919
// MISSING LINE 17920
// MISSING LINE 17921
// MISSING LINE 17922
// MISSING LINE 17923
// MISSING LINE 17924
// MISSING LINE 17925
// MISSING LINE 17926
// MISSING LINE 17927
// MISSING LINE 17928
// MISSING LINE 17929
// MISSING LINE 17930
// MISSING LINE 17931
// MISSING LINE 17932
// MISSING LINE 17933
// MISSING LINE 17934
// MISSING LINE 17935
// MISSING LINE 17936
// MISSING LINE 17937
// MISSING LINE 17938
// MISSING LINE 17939
// MISSING LINE 17940
// MISSING LINE 17941
// MISSING LINE 17942
// MISSING LINE 17943
// MISSING LINE 17944
// MISSING LINE 17945
// MISSING LINE 17946
// MISSING LINE 17947
// MISSING LINE 17948
// MISSING LINE 17949
// MISSING LINE 17950
// MISSING LINE 17951
// MISSING LINE 17952
// MISSING LINE 17953
// MISSING LINE 17954
// MISSING LINE 17955
// MISSING LINE 17956
// MISSING LINE 17957
// MISSING LINE 17958
// MISSING LINE 17959
// MISSING LINE 17960
// MISSING LINE 17961
// MISSING LINE 17962
// MISSING LINE 17963
// MISSING LINE 17964
// MISSING LINE 17965
// MISSING LINE 17966
// MISSING LINE 17967
// MISSING LINE 17968
// MISSING LINE 17969
// MISSING LINE 17970
// MISSING LINE 17971
// MISSING LINE 17972
// MISSING LINE 17973
// MISSING LINE 17974
// MISSING LINE 17975
// MISSING LINE 17976
// MISSING LINE 17977
// MISSING LINE 17978
// MISSING LINE 17979
// MISSING LINE 17980
// MISSING LINE 17981
// MISSING LINE 17982
// MISSING LINE 17983
// MISSING LINE 17984
// MISSING LINE 17985
// MISSING LINE 17986
// MISSING LINE 17987
// MISSING LINE 17988
// MISSING LINE 17989
// MISSING LINE 17990
// MISSING LINE 17991
// MISSING LINE 17992
// MISSING LINE 17993
// MISSING LINE 17994
// MISSING LINE 17995
// MISSING LINE 17996
// MISSING LINE 17997
// MISSING LINE 17998
// MISSING LINE 17999
// MISSING LINE 18000
// MISSING LINE 18001
// MISSING LINE 18002
// MISSING LINE 18003
// MISSING LINE 18004
// MISSING LINE 18005
// MISSING LINE 18006
// MISSING LINE 18007
// MISSING LINE 18008
// MISSING LINE 18009
// MISSING LINE 18010
// MISSING LINE 18011
// MISSING LINE 18012
// MISSING LINE 18013
// MISSING LINE 18014
// MISSING LINE 18015
// MISSING LINE 18016
// MISSING LINE 18017
// MISSING LINE 18018
// MISSING LINE 18019
// MISSING LINE 18020
// MISSING LINE 18021
// MISSING LINE 18022
// MISSING LINE 18023
// MISSING LINE 18024
// MISSING LINE 18025
// MISSING LINE 18026
// MISSING LINE 18027
// MISSING LINE 18028
// MISSING LINE 18029
// MISSING LINE 18030
// MISSING LINE 18031
// MISSING LINE 18032
// MISSING LINE 18033
// MISSING LINE 18034
// MISSING LINE 18035
// MISSING LINE 18036
// MISSING LINE 18037
// MISSING LINE 18038
// MISSING LINE 18039
// MISSING LINE 18040
// MISSING LINE 18041
// MISSING LINE 18042
// MISSING LINE 18043
// MISSING LINE 18044
// MISSING LINE 18045
// MISSING LINE 18046
// MISSING LINE 18047
// MISSING LINE 18048
// MISSING LINE 18049
// MISSING LINE 18050
// MISSING LINE 18051
// MISSING LINE 18052
// MISSING LINE 18053
// MISSING LINE 18054
// MISSING LINE 18055
// MISSING LINE 18056
// MISSING LINE 18057
// MISSING LINE 18058
// MISSING LINE 18059
// MISSING LINE 18060
// MISSING LINE 18061
// MISSING LINE 18062
// MISSING LINE 18063
// MISSING LINE 18064
// MISSING LINE 18065
// MISSING LINE 18066
// MISSING LINE 18067
// MISSING LINE 18068
// MISSING LINE 18069
// MISSING LINE 18070
// MISSING LINE 18071
// MISSING LINE 18072
// MISSING LINE 18073
// MISSING LINE 18074
// MISSING LINE 18075
// MISSING LINE 18076
// MISSING LINE 18077
// MISSING LINE 18078
// MISSING LINE 18079
// MISSING LINE 18080
// MISSING LINE 18081
// MISSING LINE 18082
// MISSING LINE 18083
// MISSING LINE 18084
// MISSING LINE 18085
// MISSING LINE 18086
// MISSING LINE 18087
// MISSING LINE 18088
// MISSING LINE 18089
// MISSING LINE 18090
// MISSING LINE 18091
// MISSING LINE 18092
// MISSING LINE 18093
// MISSING LINE 18094
// MISSING LINE 18095
// MISSING LINE 18096
// MISSING LINE 18097
// MISSING LINE 18098
// MISSING LINE 18099
// MISSING LINE 18100
// MISSING LINE 18101
// MISSING LINE 18102
// MISSING LINE 18103
// MISSING LINE 18104
// MISSING LINE 18105
// MISSING LINE 18106
// MISSING LINE 18107
// MISSING LINE 18108
// MISSING LINE 18109
// MISSING LINE 18110
// MISSING LINE 18111
// MISSING LINE 18112
// MISSING LINE 18113
// MISSING LINE 18114
// MISSING LINE 18115
// MISSING LINE 18116
// MISSING LINE 18117
// MISSING LINE 18118
// MISSING LINE 18119
// MISSING LINE 18120
// MISSING LINE 18121
// MISSING LINE 18122
// MISSING LINE 18123
// MISSING LINE 18124
// MISSING LINE 18125
// MISSING LINE 18126
// MISSING LINE 18127
// MISSING LINE 18128
// MISSING LINE 18129
// MISSING LINE 18130
// MISSING LINE 18131
// MISSING LINE 18132
// MISSING LINE 18133
// MISSING LINE 18134
// MISSING LINE 18135
// MISSING LINE 18136
// MISSING LINE 18137
// MISSING LINE 18138
// MISSING LINE 18139
// MISSING LINE 18140
// MISSING LINE 18141
// MISSING LINE 18142
// MISSING LINE 18143
// MISSING LINE 18144
// MISSING LINE 18145
// MISSING LINE 18146
// MISSING LINE 18147
// MISSING LINE 18148
// MISSING LINE 18149
// MISSING LINE 18150
// MISSING LINE 18151
// MISSING LINE 18152
// MISSING LINE 18153
// MISSING LINE 18154
// MISSING LINE 18155
// MISSING LINE 18156
// MISSING LINE 18157
// MISSING LINE 18158
// MISSING LINE 18159
// MISSING LINE 18160
// MISSING LINE 18161
// MISSING LINE 18162
// MISSING LINE 18163
// MISSING LINE 18164
// MISSING LINE 18165
// MISSING LINE 18166
// MISSING LINE 18167
// MISSING LINE 18168
// MISSING LINE 18169
// MISSING LINE 18170
// MISSING LINE 18171
// MISSING LINE 18172
// MISSING LINE 18173
// MISSING LINE 18174
// MISSING LINE 18175
// MISSING LINE 18176
// MISSING LINE 18177
// MISSING LINE 18178
// MISSING LINE 18179
// MISSING LINE 18180
// MISSING LINE 18181
// MISSING LINE 18182
// MISSING LINE 18183
// MISSING LINE 18184
// MISSING LINE 18185
// MISSING LINE 18186
// MISSING LINE 18187
// MISSING LINE 18188
// MISSING LINE 18189
// MISSING LINE 18190
// MISSING LINE 18191
// MISSING LINE 18192
// MISSING LINE 18193
// MISSING LINE 18194
// MISSING LINE 18195
// MISSING LINE 18196
// MISSING LINE 18197
// MISSING LINE 18198
// MISSING LINE 18199
// MISSING LINE 18200
// MISSING LINE 18201
// MISSING LINE 18202
// MISSING LINE 18203
// MISSING LINE 18204
// MISSING LINE 18205
// MISSING LINE 18206
// MISSING LINE 18207
// MISSING LINE 18208
// MISSING LINE 18209
// MISSING LINE 18210
// MISSING LINE 18211
// MISSING LINE 18212
// MISSING LINE 18213
// MISSING LINE 18214
// MISSING LINE 18215
// MISSING LINE 18216
// MISSING LINE 18217
// MISSING LINE 18218
// MISSING LINE 18219
// MISSING LINE 18220
// MISSING LINE 18221
// MISSING LINE 18222
// MISSING LINE 18223
// MISSING LINE 18224
// MISSING LINE 18225
// MISSING LINE 18226
// MISSING LINE 18227
// MISSING LINE 18228
// MISSING LINE 18229
// MISSING LINE 18230
// MISSING LINE 18231
// MISSING LINE 18232
// MISSING LINE 18233
// MISSING LINE 18234
// MISSING LINE 18235
// MISSING LINE 18236
// MISSING LINE 18237
// MISSING LINE 18238
// MISSING LINE 18239
// MISSING LINE 18240
class _CriteriaChip extends StatelessWidget {
  final String emoji, label;
  final bool selected;
  final VoidCallback onTap;
  const _CriteriaChip(
      {required this.emoji,
      required this.label,
      required this.selected,
      required this.onTap});
  @override
  Widget build(BuildContext context) => Expanded(
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: selected
                  ? kGold.withValues(alpha: 0.12)
                  : _g(0.04),
              border:
                  selected ? Border.all(color: kGold, width: 1.5) : null,
              boxShadow: selected
                  ? [
                      BoxShadow(
                          color: kGold.withValues(alpha: 0.2), blurRadius: 12)
                    ]
                  : null,
            ),
            child: Column(children: [
              Text(emoji, style: const TextStyle(fontSize: 20)),
              const SizedBox(height: 5),
              Text(label,
                  textAlign: TextAlign.center,
// MISSING LINE 18276
// MISSING LINE 18277
// MISSING LINE 18278
// MISSING LINE 18279
// MISSING LINE 18280
// MISSING LINE 18281
// MISSING LINE 18282
// MISSING LINE 18283
// MISSING LINE 18284
// MISSING LINE 18285
// MISSING LINE 18286
// MISSING LINE 18287
// MISSING LINE 18288
// MISSING LINE 18289
// MISSING LINE 18290
// MISSING LINE 18291
// MISSING LINE 18292
// MISSING LINE 18293
// MISSING LINE 18294
// MISSING LINE 18295
// MISSING LINE 18296
// MISSING LINE 18297
// MISSING LINE 18298
// MISSING LINE 18299
// MISSING LINE 18300
// MISSING LINE 18301
// MISSING LINE 18302
// MISSING LINE 18303
// MISSING LINE 18304
// MISSING LINE 18305
// MISSING LINE 18306
// MISSING LINE 18307
// MISSING LINE 18308
// MISSING LINE 18309
// MISSING LINE 18310
// MISSING LINE 18311
// MISSING LINE 18312
// MISSING LINE 18313
// MISSING LINE 18314
// MISSING LINE 18315
// MISSING LINE 18316
// MISSING LINE 18317
// MISSING LINE 18318
// MISSING LINE 18319
// MISSING LINE 18320
// MISSING LINE 18321
// MISSING LINE 18322
// MISSING LINE 18323
// MISSING LINE 18324
// MISSING LINE 18325
// MISSING LINE 18326
// MISSING LINE 18327
// MISSING LINE 18328
// MISSING LINE 18329
// MISSING LINE 18330
// MISSING LINE 18331
// MISSING LINE 18332
// MISSING LINE 18333
// MISSING LINE 18334
// MISSING LINE 18335
// MISSING LINE 18336
// MISSING LINE 18337
// MISSING LINE 18338
// MISSING LINE 18339
// MISSING LINE 18340
// MISSING LINE 18341
// MISSING LINE 18342
// MISSING LINE 18343
// MISSING LINE 18344
// MISSING LINE 18345
// MISSING LINE 18346
// MISSING LINE 18347
// MISSING LINE 18348
// MISSING LINE 18349
// MISSING LINE 18350
// MISSING LINE 18351
// MISSING LINE 18352
// MISSING LINE 18353
// MISSING LINE 18354
// MISSING LINE 18355
// MISSING LINE 18356
// MISSING LINE 18357
// MISSING LINE 18358
// MISSING LINE 18359
// MISSING LINE 18360
// MISSING LINE 18361
// MISSING LINE 18362
// MISSING LINE 18363
// MISSING LINE 18364
// MISSING LINE 18365
// MISSING LINE 18366
// MISSING LINE 18367
// MISSING LINE 18368
// MISSING LINE 18369
// MISSING LINE 18370
// MISSING LINE 18371
// MISSING LINE 18372
// MISSING LINE 18373
// MISSING LINE 18374
// MISSING LINE 18375
// MISSING LINE 18376
// MISSING LINE 18377
// MISSING LINE 18378
// MISSING LINE 18379
// MISSING LINE 18380
// MISSING LINE 18381
// MISSING LINE 18382
// MISSING LINE 18383
// MISSING LINE 18384
// MISSING LINE 18385
// MISSING LINE 18386
// MISSING LINE 18387
// MISSING LINE 18388
// MISSING LINE 18389
// MISSING LINE 18390
// MISSING LINE 18391
// MISSING LINE 18392
// MISSING LINE 18393
// MISSING LINE 18394
// MISSING LINE 18395
// MISSING LINE 18396
// MISSING LINE 18397
// MISSING LINE 18398
// MISSING LINE 18399
// MISSING LINE 18400
// MISSING LINE 18401
// MISSING LINE 18402
// MISSING LINE 18403
// MISSING LINE 18404
// MISSING LINE 18405
// MISSING LINE 18406
// MISSING LINE 18407
// MISSING LINE 18408
// MISSING LINE 18409
// MISSING LINE 18410
// MISSING LINE 18411
// MISSING LINE 18412
// MISSING LINE 18413
// MISSING LINE 18414
// MISSING LINE 18415
// MISSING LINE 18416
// MISSING LINE 18417
// MISSING LINE 18418
// MISSING LINE 18419
// MISSING LINE 18420
// MISSING LINE 18421
// MISSING LINE 18422
// MISSING LINE 18423
// MISSING LINE 18424
// MISSING LINE 18425
// MISSING LINE 18426
// MISSING LINE 18427
// MISSING LINE 18428
// MISSING LINE 18429
// MISSING LINE 18430
// MISSING LINE 18431
// MISSING LINE 18432
// MISSING LINE 18433
// MISSING LINE 18434
// MISSING LINE 18435
// MISSING LINE 18436
// MISSING LINE 18437
// MISSING LINE 18438
// MISSING LINE 18439
// MISSING LINE 18440
// MISSING LINE 18441
// MISSING LINE 18442
// MISSING LINE 18443
// MISSING LINE 18444
// MISSING LINE 18445
// MISSING LINE 18446
// MISSING LINE 18447
// MISSING LINE 18448
// MISSING LINE 18449
// MISSING LINE 18450
// MISSING LINE 18451
// MISSING LINE 18452
// MISSING LINE 18453
// MISSING LINE 18454
// MISSING LINE 18455
// MISSING LINE 18456
// MISSING LINE 18457
// MISSING LINE 18458
// MISSING LINE 18459
// MISSING LINE 18460
// MISSING LINE 18461
// MISSING LINE 18462
// MISSING LINE 18463
// MISSING LINE 18464
// MISSING LINE 18465
// MISSING LINE 18466
// MISSING LINE 18467
// MISSING LINE 18468
// MISSING LINE 18469
// MISSING LINE 18470
// MISSING LINE 18471
// MISSING LINE 18472
// MISSING LINE 18473
// MISSING LINE 18474
// MISSING LINE 18475
// MISSING LINE 18476
// MISSING LINE 18477
// MISSING LINE 18478
// MISSING LINE 18479
// MISSING LINE 18480
// MISSING LINE 18481
// MISSING LINE 18482
// MISSING LINE 18483
// MISSING LINE 18484
// MISSING LINE 18485
// MISSING LINE 18486
// MISSING LINE 18487
// MISSING LINE 18488
// MISSING LINE 18489
// MISSING LINE 18490
// MISSING LINE 18491
// MISSING LINE 18492
// MISSING LINE 18493
// MISSING LINE 18494
// MISSING LINE 18495
// MISSING LINE 18496
// MISSING LINE 18497
// MISSING LINE 18498
// MISSING LINE 18499
// MISSING LINE 18500
// MISSING LINE 18501
// MISSING LINE 18502
// MISSING LINE 18503
// MISSING LINE 18504
// MISSING LINE 18505
// MISSING LINE 18506
// MISSING LINE 18507
// MISSING LINE 18508
// MISSING LINE 18509
// MISSING LINE 18510
// MISSING LINE 18511
// MISSING LINE 18512
// MISSING LINE 18513

class _ProDashboardButtonState extends State<_ProDashboardButton> {
  List<String> _proSpecialties = [];
  int _lastVisitMs = 0; // timestamp when pro last visited dashboard — used to clear request badge

  @override
  void initState() {
    super.initState();
    _loadSpecialties();
    _loadLastVisit();
  }

  Future<void> _loadLastVisit() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _lastVisitMs = prefs.getInt('proLastDashboardVisit') ?? 0);
  }

  Future<void> _markVisited() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('proLastDashboardVisit', now);
    if (mounted) setState(() => _lastVisitMs = now);
  }

  Future<void> _loadSpecialties() async {
    try {
      final allSpecs = <String>{};
      // Load from users doc
      final doc = await FirebaseFirestore.instance
          .collection('users').doc(widget.userId).get();
      final rawSpecs = doc.data()?['specialties'];
      if (rawSpecs is List) {
        allSpecs.addAll(rawSpecs.map((e) => e.toString()));
      }
      // Also load from professionals collection (primary source of specialties)
      final proSnap = await FirebaseFirestore.instance
          .collection('professionals')
          .where('userId', isEqualTo: widget.userId)
          .limit(1)
          .get();
      if (proSnap.docs.isNotEmpty) {
        final pd = proSnap.docs.first.data();
        final main = pd['specialty'] as String? ?? '';
        if (main.isNotEmpty) allSpecs.add(main);
        final proSpecs = pd['specialties'];
        if (proSpecs is List) allSpecs.addAll(proSpecs.map((e) => e.toString()));
      }
      if (mounted) setState(() => _proSpecialties = allSpecs.toList());
    } catch (_) {}
  }

  bool _matchesRequest(Map<String, dynamic> d) {
    final profession = (d['profession'] as String? ?? '').toLowerCase().trim();
    if (profession.isEmpty) return true;
    for (final sp in _proSpecialties) {
      final spLow = sp.toLowerCase();
      if (spLow.contains(profession) || profession.contains(spLow)) return true;
    }
    return false;
  }

  bool _matchesEvent(Map<String, dynamic> d) {
    final categoryPros = List<String>.from(d['categoryPros'] ?? []);
    // Old docs without categoryPros → only event-category professionals
    if (categoryPros.isEmpty) {
      return _proSpecialties.any((sp) =>
          _kEventSpecialties.contains(sp.toLowerCase()));
    }
    final cpLowList = categoryPros.map((cp) => cp.toLowerCase()).toList();
    for (final sp in _proSpecialties) {
      final spLow = sp.toLowerCase();
      // Pro's specialty must CONTAIN the categoryPros keyword (not reverse)
      for (final cpLow in cpLowList) {
        if (spLow.contains(cpLow)) return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('chats')
          .where('proId', isEqualTo: widget.userId)
          .snapshots(),
      builder: (context, chatSnap) {
        int chatUnread = 0;
        if (chatSnap.hasData) {
          for (final doc in chatSnap.data!.docs) {
            final d = doc.data() as Map<String, dynamic>;
            chatUnread += (d['unreadPro'] as int?) ?? 0;
          }
        }
        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('event_requests')
              .where('status', isEqualTo: 'active')
              .snapshots(),
          builder: (context, evSnap) {
            int eventCount = 0;
            if (evSnap.hasData) {
              final now = DateTime.now();
              for (final doc in evSnap.data!.docs) {
                final data = doc.data() as Map<String, dynamic>;
                final exp = data['expiresAt'] as Timestamp?;
                if (exp != null && exp.toDate().isAfter(now) && _matchesEvent(data)) {
                  eventCount++;
                }
              }
            }
            return StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('users').doc(widget.userId)
                  .collection('notifications')
                  .where('isRead', isEqualTo: false)
                  .where('type', isEqualTo: 'offer_accepted')
                  .snapshots(),
              builder: (context, acceptSnap) {
                final acceptedCount = acceptSnap.data?.docs.length ?? 0;
                return StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('requests')
                      .where('status', isEqualTo: 'active')
                      .snapshots(),
                  builder: (context, reqSnap) {
                    // Only count requests created AFTER the last time pro visited dashboard
                    int matchingReqCount = 0;
                    if (reqSnap.hasData) {
                      for (final doc in reqSnap.data!.docs) {
                        final data = doc.data() as Map<String, dynamic>;
                        if (!_matchesRequest(data)) continue;
                        final createdMs = (data['createdAt'] as Timestamp?)?.millisecondsSinceEpoch ?? 0;
                        if (createdMs > _lastVisitMs) matchingReqCount++;
                      }
                    }
                    // Pro button: unread chats + matching events + accepted notifications + new requests
                    final count = chatUnread + eventCount + acceptedCount + matchingReqCount;
            return GestureDetector(
          onTap: () async {
            await _markVisited(); // clear request badge
            if (context.mounted) Navigator.push(
              context,
              PageRouteBuilder(
                transitionDuration: const Duration(milliseconds: 400),
                pageBuilder: (_, __, ___) => const ProfessionalHomeScreen(),
                transitionsBuilder: (_, a, __, c) =>
                    FadeTransition(opacity: a, child: c),
              ),
            );
                    // Only count requests created AFTER the last time pro visited dashboard
                    int matchingReqCount = 0;
                    if (reqSnap.hasData) {
                      for (final doc in reqSnap.data!.docs) {
                        final data = doc.data() as Map<String, dynamic>;
                        if (!_matchesRequest(data)) continue;
                        final createdMs = (data['createdAt'] as Timestamp?)?.millisecondsSinceEpoch ?? 0;
                        if (createdMs > _lastVisitMs) matchingReqCount++;
                      }
                    }
                    // Pro button: unread chats + matching events + accepted notifications + new requests
                    final count = chatUnread + eventCount + acceptedCount + matchingReqCount;
            return GestureDetector(
          onTap: () async {
            await _markVisited(); // clear request badge
            if (context.mounted) Navigator.push(
              context,
              PageRouteBuilder(
                transitionDuration: const Duration(milliseconds: 400),
                pageBuilder: (_, __, ___) => const ProfessionalHomeScreen(),
                transitionsBuilder: (_, a, __, c) =>
                    FadeTransition(opacity: a, child: c),
              ),
            );
          },
          child: Stack(clipBehavior: Clip.none, children: [
            Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: kGold.withValues(alpha: 0.1),
                border: Border.all(color: kGold.withValues(alpha: 0.45)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.work_outline_rounded, color: kGold, size: 14),
                const SizedBox(width: 6),
                const Text('Επαγγελματίας',
                    style: TextStyle(
                        color: kGold,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2)),
                const SizedBox(width: 4),
                Icon(Icons.arrow_forward_ios_rounded, color: kGold.withValues(alpha: 0.6), size: 11),
              ]),
            ),
            if (count > 0)
              Positioned(
                top: -4,
                right: -4,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: const BoxDecoration(
                      color: Colors.red, shape: BoxShape.circle),
                  child: Center(
                    child: Text(count > 9 ? '9+' : '$count',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
          ]),
        );
                  }, // end reqSnap builder
                ); // end requests StreamBuilder
              }, // end acceptSnap builder
            ); // end offer_accepted StreamBuilder
          }, // end evSnap builder
        ); // end event_requests StreamBuilder
      }, // end chatSnap builder
    ); // end chats StreamBuilder
  }
}

class _ProfileRow extends StatefulWidget {
  final IconData icon;
  final String label, value;
  final VoidCallback? onTap;
  final Color? iconColor, textColor, borderColor, bgColor;
  final String? emoji;
  const _ProfileRow(
      {required this.icon,
      required this.label,
      required this.value,
      this.onTap,
      this.iconColor,
      this.textColor,
      this.borderColor,
      this.bgColor,
      this.emoji});
    // ── 1. Specialty check ──
    final profession = (d['profession'] as String? ?? '').toLowerCase().trim();
    if (profession.isNotEmpty) {
      final specMatches = _proSpecialties.any((sp) {
        final spLow = sp.toLowerCase();
        return spLow.contains(profession) || profession.contains(spLow);
      });
      if (!specMatches) return false;
    }
    // ── 2. Location check ──
    final reqLocation = (d['location'] as String? ?? '').toLowerCase().trim();
    if (reqLocation.isNotEmpty && reqLocation != 'κοντά μου') {
      if (_proAreas.isNotEmpty) {
        final areaMatches = _proAreas.any((a) =>
            a.toLowerCase().contains(reqLocation) ||
            reqLocation.contains(a.toLowerCase()));
        if (!areaMatches) return false;
      }
    }
    return true;
  }

  bool _matchesEvent(Map<String, dynamic> d) {
    // ── 1. Specialty check ──
    final categoryPros = List<String>.from(d['categoryPros'] ?? []);
    bool specMatches;
    if (categoryPros.isEmpty) {
      specMatches = _proSpecialties.any((sp) =>
          _kEventSpecialties.contains(sp.toLowerCase()));
    } else {
      final cpLowList = categoryPros.map((cp) => cp.toLowerCase()).toList();
      specMatches = _proSpecialties.any((sp) {
        final spLow = sp.toLowerCase();
        return cpLowList.any((cpLow) => spLow.contains(cpLow));
      });
    }
    if (!specMatches) return false;

    // ── 2. Location check ──
    final eventLocation = (d['location'] as String? ?? '').toLowerCase().trim();
    if (eventLocation.isNotEmpty && _proAreas.isNotEmpty) {
      final areaMatches = _proAreas.any((a) =>
          a.toLowerCase().contains(eventLocation) ||
          eventLocation.contains(a.toLowerCase()));
      if (!areaMatches) return false;
    }

    return true;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('chats')
          .where('proId', isEqualTo: widget.userId)
          .snapshots(),
      builder: (context, chatSnap) {
        int chatUnread = 0;
        if (chatSnap.hasData) {
          for (final doc in chatSnap.data!.docs) {
            final d = doc.data() as Map<String, dynamic>;
            chatUnread += (d['unreadPro'] as int?) ?? 0;
          }
        }
        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('event_requests')
              .where('status', isEqualTo: 'active')
              .snapshots(),
          builder: (context, evSnap) {
            int eventCount = 0;
            if (evSnap.hasData) {
              final now = DateTime.now();
              for (final doc in evSnap.data!.docs) {
                final data = doc.data() as Map<String, dynamic>;
                final exp = data['expiresAt'] as Timestamp?;
                if (exp != null && exp.toDate().isAfter(now) && _matchesEvent(data)) {
                  eventCount++;
                }
              }
            }
            return StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('users').doc(widget.userId)
                  .collection('notifications')
                  .where('isRead', isEqualTo: false)
                  .where('type', isEqualTo: 'offer_accepted')
                  .snapshots(),
              builder: (context, acceptSnap) {
                final acceptedCount = acceptSnap.data?.docs.length ?? 0;
                return StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('requests')
                      .where('status', isEqualTo: 'active')
                      .snapshots(),
                  builder: (context, reqSnap) {
                    // Only count requests created AFTER the last time pro visited dashboard
                    int matchingReqCount = 0;
                    if (reqSnap.hasData) {
                      for (final doc in reqSnap.data!.docs) {
                        final data = doc.data() as Map<String, dynamic>;
                        if (!_matchesRequest(data)) continue;
                        final createdMs = (data['createdAt'] as Timestamp?)?.millisecondsSinceEpoch ?? 0;
                        if (createdMs > _lastVisitMs) matchingReqCount++;
                      }
                    }
                    // Pro button: unread chats + matching events + accepted notifications + new requests
                    final count = chatUnread + eventCount + acceptedCount + matchingReqCount;
            return GestureDetector(
          onTap: () async {
            await _markVisited(); // clear request badge
            if (context.mounted) Navigator.push(
              context,
              PageRouteBuilder(
                transitionDuration: const Duration(milliseconds: 400),
                pageBuilder: (_, __, ___) => const ProfessionalHomeScreen(),
                transitionsBuilder: (_, a, __, c) =>
                    FadeTransition(opacity: a, child: c),
              ),
            );
          },
          child: Stack(clipBehavior: Clip.none, children: [
            Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: kGold.withValues(alpha: 0.1),
                border: Border.all(color: kGold.withValues(alpha: 0.45)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.work_outline_rounded, color: kGold, size: 14),
                const SizedBox(width: 6),
                const Text('Επαγγελματίας',
                    style: TextStyle(
                        color: kGold,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2)),
                const SizedBox(width: 4),
                Icon(Icons.arrow_forward_ios_rounded, color: kGold.withValues(alpha: 0.6), size: 11),
