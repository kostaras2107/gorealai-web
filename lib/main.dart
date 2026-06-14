import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:math';
import 'package:image_picker/image_picker.dart';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'firebase_options.dart';
import 'splash_screen.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:firebase_storage/firebase_storage.dart';

// ═══════════════════════════════════════
// CONSTANTS
// ═══════════════════════════════════════
const bool kFreeForAll = true; // Δωρεάν premium για χρήστες (όχι επαγγελματίες)
const String kBackendUrl = 'https://ai-backend-kkt7.onrender.com';
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
  // FCM μπορεί να αποτύχει στο web — δεν σταματάμε το app
  try {
    await NotificationService.init();
  } catch (e) {
    debugPrint('NotificationService init error: \$e');
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
    'white': AppTheme(
        id: 'white',
        accent: Color(0xFFFFB340),
        background: Color(0xFFF5F5F7),
        backgroundGradientEnd: Color(0xFFEBEBF0),
        isLight: true,
        textBase: Color(0xFF0D0D1E)),
    'grey': AppTheme(
        id: 'grey',
        accent: Color(0xFFFFB340),
        background: Color(0xFFE5E5EA),
        backgroundGradientEnd: Color(0xFFD8D8E0),
        isLight: true,
        textBase: Color(0xFF0D0D1E)),
  };
  static AppTheme get(String id) => themes[id] ?? themes['obsidian']!;
}

// ── Global helpers ──────────────────────────────────────────────
// Replaces _g(X) throughout the codebase
Color _g(double alpha) => appThemeNotifier.value.adaptive(alpha);
// Replaces Colors.white as text/icon color
Color get _gw => appThemeNotifier.value.text;

final ValueNotifier<AppTheme> appThemeNotifier =
    ValueNotifier<AppTheme>(AppTheme.themes['obsidian']!);

class GorealAiApp extends StatefulWidget {
  final String initialTheme;
  const GorealAiApp({super.key, this.initialTheme = 'obsidian'});
  @override
  State<GorealAiApp> createState() => _GorealAiAppState();
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
// LOGIN SCREEN
// ═══════════════════════════════════════
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  final _name = TextEditingController();
  final _lastName = TextEditingController();
  final _phone = TextEditingController();
  String? _selectedSpecialty;
  String? _selectedArea;
  bool _loading = false;
  bool _isLogin = true;
  String _role = 'user';
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
    _name.dispose();
    _lastName.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _autoLoginWithBiometrics() async {
    final email = await AuthService.getUser();
    final password = await AuthService.getPassword();
    if (email == null || password == null) return;
    final auth = LocalAuthentication();
    try {
      final ok = await auth.authenticate(
          localizedReason: 'Σύνδεση με δαχτυλικό αποτύπωμα',
          options: const AuthenticationOptions(biometricOnly: true));
      if (!ok) return;
      await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: email, password: password);
      if (mounted) {
        Navigator.pushReplacement(
            context, MaterialPageRoute(builder: (_) => const AuthGate()));
      }
    } catch (e) {
      debugPrint('Auto login error: $e');
    }
  }

  Future<void> _submit() async {
    setState(() => _loading = true);
    try {
      if (_isLogin) {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
            email: _email.text.trim(), password: _pass.text.trim());
        await AuthService.saveUser(_email.text.trim());
        await AuthService.savePassword(_pass.text.trim());
        if (mounted) {
          Navigator.pushReplacement(
              context, MaterialPageRoute(builder: (_) => const AuthGate()));
        }
      } else {
        if (_role == 'professional' &&
            (_selectedSpecialty == null || _selectedSpecialty!.isEmpty)) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Παρακαλώ επιλέξτε ειδικότητα')));
          setState(() => _loading = false);
          return;
        }
        final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
            email: _email.text.trim(), password: _pass.text.trim());
        final fullName =
            '${_name.text.trim()} ${_lastName.text.trim()}'.trim();
        await cred.user!.updateDisplayName(fullName);
        await FirebaseFirestore.instance
            .collection('users')
            .doc(cred.user!.uid)
            .set({
          'name': fullName,
          'city': _selectedArea ?? '',
          'phone': _phone.text.trim(),
          'role': _role,
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
            'createdAt': FieldValue.serverTimestamp(),
          });
        }
        await AuthService.saveUser(_email.text.trim());
        await AuthService.savePassword(_pass.text.trim());
        if (mounted) {
          Navigator.pushReplacement(
              context, MaterialPageRoute(builder: (_) => const AuthGate()));
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
                      Text('Βρες τον κατάλληλο επαγγελματία',
                          style: TextStyle(
                              fontSize: 12,
                              color: _g(0.4))),
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
                                      labelText: 'Όνομα'))),
                          const SizedBox(width: 10),
                          Expanded(
                              child: TextField(
                                  controller: _lastName,
                                  decoration: const InputDecoration(
                                      labelText: 'Επώνυμο'))),
                        ]),
                        const SizedBox(height: 12),
                        TextField(
                            controller: _phone,
                            keyboardType: TextInputType.phone,
                            decoration:
                                const InputDecoration(labelText: 'Τηλέφωνο')),
                        const SizedBox(height: 12),
                      ],

                      // Specialty picker
                      if (!_isLogin && _role == 'professional') ...[
                        GestureDetector(
                          onTap: () async {
                            final r = await showModalBottomSheet<String>(
                                context: context,
                                backgroundColor: Colors.transparent,
                                isScrollControlled: true,
                                builder: (ctx) => const _SpecialtyPicker());
                            if (r != null)
                              setState(() => _selectedSpecialty = r);
                          },
                          child: _DropdownField(
                              value: _selectedSpecialty,
                              hint: 'Επιλέξτε ειδικότητα...'),
                        ),
                        const SizedBox(height: 12),
                      ],

                      // Area picker
                      if (!_isLogin) ...[
                        GestureDetector(
                          onTap: () async {
                            final r = await showModalBottomSheet<String>(
                                context: context,
                                backgroundColor: Colors.transparent,
                                isScrollControlled: true,
                                builder: (ctx) => const _AreaPicker());
                            if (r != null) setState(() => _selectedArea = r);
                          },
                          child: _DropdownField(
                              value: _selectedArea,
                              hint: _role == 'professional'
                                  ? 'Επιλέξτε περιοχή εργασίας...'
                                  : 'Επιλέξτε περιοχή...'),
                        ),
                        const SizedBox(height: 12),
                      ],

                      TextField(
                          controller: _email,
                          decoration:
                              const InputDecoration(labelText: 'Email')),
                      const SizedBox(height: 14),
                      TextField(
                          controller: _pass,
                          obscureText: true,
                          decoration:
                              const InputDecoration(labelText: 'Password')),
                      const SizedBox(height: 26),

                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton(
                          onPressed: _loading ? null : _submit,
                          style: ElevatedButton.styleFrom(
                              backgroundColor: kGold,
                              foregroundColor: Colors.black,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(18))),
                          child: _loading
                              ? const CircularProgressIndicator(
                                  color: Colors.black)
                              : Text(
                                  _isLogin
                                      ? 'Είσοδος'
                                      : 'Δημιουργία λογαριασμού',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16)),
                        ),
                      ),

                      if (_isLogin) ...[
                        const SizedBox(height: 14),
                        GestureDetector(
                          onTap: _autoLoginWithBiometrics,
                          child: Container(
                            width: double.infinity,
                            height: 52,
                            decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(
                                    color: kGold.withValues(alpha: 0.4)),
                                color: kGold.withValues(alpha: 0.06)),
                            child: const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.fingerprint,
                                      color: kGold, size: 26),
                                  SizedBox(width: 10),
                                  Text('Είσοδος με δαχτυλικό αποτύπωμα',
                                      style: TextStyle(
                                          color: kGold,
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500)),
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
}

// ═══════════════════════════════════════
// HOME SCREEN — Χρήστες
// ═══════════════════════════════════════
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  String? _userName;
  String? _userId;
  int _navIndex = 0;
  // Ενεργά αιτήματα (για το G button — μέχρι 2)
  List<Map<String, dynamic>> _activeRequests = []; // list of {id, status, desc, criteria, expiresAt}

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
        setState(() => _activeRequests = limited);
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
            // Αν έχει ήδη επιλεγεί επαγγελματίας → δεν το δείχνουμε στο hero
            if (doc.data()['selectedPro'] != null) return false;
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
          setState(() => _activeRequests = recent);
        }).catchError((Object _) { if (mounted) setState(() => _activeRequests = []); });
      }
    }, onError: (Object _) { if (mounted) setState(() => _activeRequests = []); });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _setOnline(false);
    ReminderService.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    _setOnline(s == AppLifecycleState.resumed);
  }

  void _setOnline(bool online) async {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return;
    await FirebaseFirestore.instance.collection('presence').doc(u.uid).set({
      'online': online,
      'lastSeen': FieldValue.serverTimestamp(),
      'uid': u.uid
    });
  }

  Future<void> _loadProfile() async {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return;
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(u.uid)
        .get();
    if (!mounted) return;
    setState(() {
      _userName = doc.data()?['name'] ?? u.email ?? 'User';
      _userId = u.uid;
    });
  }

  void _openRequest() {
    Navigator.push(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 400),
          pageBuilder: (_, __, ___) => RequestScreen(
              userId: _userId ?? '', userName: _userName ?? 'Χρήστης'),
          transitionsBuilder: (_, a, __, c) => SlideTransition(
              position: Tween<Offset>(
                      begin: const Offset(0, 1), end: Offset.zero)
                  .animate(CurvedAnimation(
                      parent: a, curve: Curves.easeOutCubic)),
              child: c),
        ));
  }

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

  void _openEventOrganizer() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _EventOrganizerSheet(userId: _userId ?? '', userName: _userName ?? 'Χρήστης'),
    );
  }

  void _openProjectRequest() {
    Navigator.push(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 400),
          pageBuilder: (_, __, ___) => ProjectRequestScreen(
              userId: _userId ?? '', userName: _userName ?? 'Χρήστης'),
          transitionsBuilder: (_, a, __, c) => SlideTransition(
              position: Tween<Offset>(
                      begin: const Offset(0, 1), end: Offset.zero)
                  .animate(CurvedAnimation(
                      parent: a, curve: Curves.easeOutCubic)),
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
                    Text('Αίτημα ${e.key + 1}',
                        style: TextStyle(fontSize: 10,
                            color: isActive ? kGold : kGreen,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(req['desc'] ?? '', maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: _gw,
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    if (timeLeft.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(timeLeft, style: TextStyle(
                          fontSize: 11,
                          color: isActive ? kGold : kGreen)),
                    ],
                  ])),
                  Icon(Icons.arrow_forward_ios,
                      color: _g(0.3), size: 14),
                ]),
              ),
            );
          }),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  void _navigateToRequest(Map<String, dynamic> req) {
    if (req['status'] == 'active') {
      Navigator.push(context, PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 400),
        pageBuilder: (_, __, ___) => WaitingScreen(
          requestId: req['id'],
          userId: _userId ?? '',
          description: req['desc'] ?? '',
          criteria: req['criteria'] ?? 'cheap',
        ),
        transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
      ));
    } else {
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
                    _NotificationBell(userId: _userId ?? ''),
                  ]),
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
            onFab: _activeRequests.isEmpty ? _openEventOrganizer : _openMyOffers,
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

  Widget _buildHome() {
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const SizedBox(height: 24),

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

        // HERO — Dynamic
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _activeRequests.isNotEmpty
              ? _ActiveRequestHeroCard(
                  requests: _activeRequests,
                  onTap: _openMyOffers,
                  onNewRequest: _openRequest,
                )
              : _EmptyHeroCard(onTap: _openRequest),
        ),
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
                title: 'Περίμενε 15 λεπτά',
                subtitle: 'Οι επαγγελματίες ετοιμάζουν προσφορές',
                active: false),
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
              {'emoji': '🎨', 'label': 'Βαφές', 'profession': 'Ελαιοχρωματιστής'},
              {'emoji': '🌿', 'label': 'Κηπουρός', 'profession': 'Κηπουρός'},
              {'emoji': '🧹', 'label': 'Καθαρισμός', 'profession': 'Καθαρίστρια'},
              {'emoji': '🏗️', 'label': 'Ανακαίνιση', 'profession': 'Συνεργείο Ανακαίνισης'},
              {'emoji': '🔒', 'label': 'Ασφάλεια', 'profession': 'Τεχνικός Ασφαλείας'},
            ]
                .map((c) => GestureDetector(
                      onTap: () => _openRequestWithProfession(c['profession']!),
                      child: Container(
                        width: 80,
                        margin: const EdgeInsets.only(right: 10),
                        decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            color: _g(0.04)),
                        child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(c['emoji']!,
                                  style: const TextStyle(fontSize: 26)),
                              const SizedBox(height: 6),
                              Text(c['label']!,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      fontSize: 9,
                                      color:
                                          _g(0.6),
                                      fontWeight: FontWeight.w500)),
                            ]),
                      ),
                    ))
                .toList(),
          ),
        ),

        const SizedBox(height: 28),

        // ΕΠΑΓΓΕΛΜΑΤΙΕΣ ΚΟΝΤΑ ΣΟΥ
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Row(children: [
            Text('Επαγγελματίες κοντά σου',
                style: TextStyle(color: _g(0.8), fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: kGreen.withValues(alpha: 0.12),
                border: Border.all(color: kGreen.withValues(alpha: 0.3)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 5, height: 5,
                    decoration: const BoxDecoration(shape: BoxShape.circle, color: kGreen)),
                const SizedBox(width: 4),
                const Text('LIVE', style: TextStyle(color: kGreen, fontSize: 9, fontWeight: FontWeight.w700)),
              ]),
            ),
          ]),
        ),
        const _NearbyProsSection(),

        const SizedBox(height: 28),

        // ACTIVE REQUESTS
        if (_userId != null) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Τα αιτήματά σου',
                      style: TextStyle(
                          color: _g(0.8),
                          fontSize: 16,
                          fontWeight: FontWeight.w700)),
                  GestureDetector(
                    onTap: () => Navigator.push(
                        context,
                        PageRouteBuilder(
                          transitionDuration:
                              const Duration(milliseconds: 350),
                          pageBuilder: (_, __, ___) =>
                              RequestHistoryScreen(userId: _userId!),
                          transitionsBuilder: (_, a, __, c) =>
                              FadeTransition(opacity: a, child: c),
                        )),
                    child: Text('Όλα ›',
                        style: TextStyle(
                            color: kGold.withValues(alpha: 0.8), fontSize: 12)),
                  ),
                ]),
          ),
          _ActiveRequestsPreview(userId: _userId!),
        ],

        const SizedBox(height: 28),

        // LIVE ACTIVITY FEED
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Row(children: [
            Container(width: 7, height: 7,
                decoration: const BoxDecoration(shape: BoxShape.circle, color: kGreen)),
            const SizedBox(width: 8),
            Text('Live Activity',
                style: TextStyle(
                    color: _g(0.8),
                    fontSize: 16, fontWeight: FontWeight.w700)),
          ]),
        ),
        _LiveActivityFeed(),
        const SizedBox(height: 8),
      ],
    );
  }
}

// ── Live Activity Feed ──
class _LiveActivityFeed extends StatefulWidget {
  const _LiveActivityFeed();
  @override
  State<_LiveActivityFeed> createState() => _LiveActivityFeedState();
}

class _LiveActivityFeedState extends State<_LiveActivityFeed>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseCtrl;
  final List<Map<String, dynamic>> _activities = [];
  Timer? _timer;
  int _tick = 0;

  // Simulated live activities (real ones would come from Firestore)
  final _staticActivities = [
    {'icon': '🤖', 'text': 'AI ειδοποίησε 8 Ηλεκτρολόγους στην Αθήνα', 'time': '2 λεπτά'},
    {'icon': '💰', 'text': 'Νέα προσφορά 180€ — κατά 20€ χαμηλότερα', 'time': '4 λεπτά'},
    {'icon': '⭐', 'text': 'Verified επαγγελματίας βρέθηκε (4.9★)', 'time': '7 λεπτά'},
    {'icon': '🏆', 'text': 'Χρήστης επέλεξε την καλύτερη τιμή (320€)', 'time': '11 λεπτά'},
    {'icon': '🔥', 'text': '5 προσφορές σε ένα αίτημα — ρεκόρ!', 'time': '15 λεπτά'},
    {'icon': '⚡', 'text': 'Εργασία ολοκληρώθηκε σε 3 ώρες', 'time': '22 λεπτά'},
    {'icon': '🎯', 'text': 'AI εκτίμησε κόστος 250€-380€ σε 0.3 sec', 'time': '28 λεπτά'},
  ];

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1500))..repeat();
    _activities.addAll(_staticActivities.take(3));
    _timer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!mounted) return;
      setState(() {
        _tick = (_tick + 1) % _staticActivities.length;
        if (_activities.length >= 5) _activities.removeLast();
        _activities.insert(0, _staticActivities[_tick]);
      });
    });
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: _activities.asMap().entries.map((e) {
      final idx = e.key;
      final act = e.value;
      return AnimatedOpacity(
        opacity: 1.0,
        duration: const Duration(milliseconds: 500),
        child: Container(
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: idx == 0
                ? kGold.withValues(alpha: 0.07)
                : _g(0.03),
            border: Border.all(
                color: idx == 0
                    ? kGold.withValues(alpha: 0.2)
                    : _g(0.05)),
          ),
          child: Row(children: [
            Text(act['icon']!, style: const TextStyle(fontSize: 16)),
            const SizedBox(width: 10),
            Expanded(child: Text(act['text']!,
                style: TextStyle(
                    color: idx == 0 ? Colors.white : _g(0.5),
                    fontSize: 12, height: 1.3))),
            Text(act['time']!,
                style: TextStyle(
                    color: _g(0.25), fontSize: 10)),
          ]),
        ),
      );
    }).toList(),
  );
}

// ── Empty Hero Card (no active requests) ──
class _EmptyHeroCard extends StatelessWidget {
  final VoidCallback onTap;
  const _EmptyHeroCard({required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [kGold.withValues(alpha: 0.15), kGold.withValues(alpha: 0.03)]),
        border: Border.all(color: kGold.withValues(alpha: 0.4), width: 1.5),
        boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.1), blurRadius: 30)],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(8),
                  color: kGold.withValues(alpha: 0.15)),
              child: const Text('✦ AI REVERSE AUCTION', style: TextStyle(
                  color: kGold, fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1.5))),
          const Spacer(),
          Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(10),
                  color: kGreen.withValues(alpha: 0.12)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 5, height: 5,
                    decoration: const BoxDecoration(shape: BoxShape.circle, color: kGreen)),
                const SizedBox(width: 5),
                const Text('Άμεση απόκριση', style: TextStyle(
                    color: kGreen, fontSize: 9, fontWeight: FontWeight.w700)),
              ])),
        ]),
        const SizedBox(height: 18),
        const Text('Οι επαγγελματίες ανταγωνίζονται για σένα.',
            style: TextStyle(fontFamily: 'Raleway', fontSize: 28,
                fontWeight: FontWeight.w800, color: Colors.white, height: 1.2)),
        const SizedBox(height: 8),
        Text('Στείλε αίτημα → το AI ειδοποιεί επαγγελματίες → παίρνεις τις 3 καλύτερες προσφορές σε 15 λεπτά.',
            style: TextStyle(fontSize: 12, color: _g(0.5), height: 1.5)),
        const SizedBox(height: 20),
        Container(
          width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(16),
              gradient: const LinearGradient(colors: [kGoldLight, kGold, kGoldDark]),
              boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.35), blurRadius: 20)]),
          child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text('🚀', style: TextStyle(fontSize: 18)),
            SizedBox(width: 10),
            Text('Στείλε αίτημα τώρα', style: TextStyle(
                color: Colors.black, fontSize: 15, fontWeight: FontWeight.w800)),
          ]),
        ),
      ]),
    ),
  );
}

// ── Active Request Hero Card — countdown πρωταγωνιστής ──
class _ActiveRequestHeroCard extends StatefulWidget {
  final List<Map<String, dynamic>> requests;
  final VoidCallback onTap;
  final VoidCallback onNewRequest;
  const _ActiveRequestHeroCard({
    required this.requests, required this.onTap, required this.onNewRequest});
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
    // Παρακολουθεί offers για το πρώτο αίτημα
    FirebaseFirestore.instance
        .collection('requests')
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
                  Text(isCompleted ? '🏆 ΟΛΟΚΛΗΡΩΘΗΚΕ' : '🔴 ΖΩΝΤΑΝΟ ΑΙΤΗΜΑ',
                      style: TextStyle(
                          color: isCompleted ? kGold : kGreen,
                          fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1)),
                ])),
            const Spacer(),
            if (widget.requests.length == 2)
              Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(8),
                      color: _g(0.07)),
                  child: Text('+1 αίτημα', style: TextStyle(
                      color: _g(0.5), fontSize: 9))),
          ]),

          const SizedBox(height: 14),

          // Description
          Text('"${req['desc'] ?? ''}"',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(color: _gw, fontSize: 13,
                  fontStyle: FontStyle.italic, height: 1.4)),

          const SizedBox(height: 16),

          if (!isCompleted) ...[
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
class _HowItWorksStep extends StatelessWidget {
  final String num, emoji, title, subtitle;
  final bool active;
  const _HowItWorksStep(
      {required this.num,
      required this.emoji,
      required this.title,
      required this.subtitle,
      required this.active});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: active
              ? kGold.withValues(alpha: 0.06)
              : _g(0.03),
        ),
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: active
                  ? kGold.withValues(alpha: 0.15)
                  : _g(0.05),
            ),
            child:
                Center(child: Text(emoji, style: const TextStyle(fontSize: 22))),
          ),
          const SizedBox(width: 12),
          Expanded(
              child:
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: TextStyle(
                    color: active
                        ? Colors.white
                        : _g(0.6),
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(subtitle,
                style: TextStyle(
                    color: _g(0.35), fontSize: 11)),
          ])),
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? kGold : _g(0.05),
            ),
            child: Center(
                child: Text(num,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: active
                            ? Colors.black
                            : _g(0.3)))),
          ),
        ]),
      );
}

// ── Active Requests Preview ──
class _ActiveRequestsPreview extends StatelessWidget {
  final String userId;
  const _ActiveRequestsPreview({required this.userId});
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('requests')
          .where('userId', isEqualTo: userId)
          .orderBy('createdAt', descending: true)
          .limit(2)
          .snapshots(),
      builder: (context, snap) {
        if (!snap.hasData || snap.data!.docs.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: _g(0.03)),
              child: Row(children: [
                const Text('📋', style: TextStyle(fontSize: 24)),
                const SizedBox(width: 12),
                Text('Δεν έχεις αιτήματα ακόμα',
                    style: TextStyle(
                        color: _g(0.4),
                        fontSize: 13)),
              ]),
            ),
          );
        }
        return Column(
          children: snap.data!.docs.map((doc) {
            final d = doc.data() as Map<String, dynamic>;
            final status = d['status'] ?? 'active';
            final offers = d['offersCount'] ?? 0;
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: GestureDetector(
                onTap: () {
                  if (status == 'active') {
                    Navigator.push(
                        context,
                        PageRouteBuilder(
                          transitionDuration:
                              const Duration(milliseconds: 400),
                          pageBuilder: (_, __, ___) => WaitingScreen(
                              requestId: doc.id,
                              userId: userId,
                              description: d['description'] ?? '',
                              criteria: d['criteria'] ?? 'cheap'),
                          transitionsBuilder: (_, a, __, c) =>
                              FadeTransition(opacity: a, child: c),
                        ));
                  } else {
                    Navigator.push(
                        context,
                        PageRouteBuilder(
                          transitionDuration:
                              const Duration(milliseconds: 400),
                          pageBuilder: (_, __, ___) => OffersScreen(
                              requestId: doc.id,
                              userId: userId,
                              description: d['description'] ?? '',
                              criteria: d['criteria'] ?? 'cheap'),
                          transitionsBuilder: (_, a, __, c) =>
                              FadeTransition(opacity: a, child: c),
                        ));
                  }
                },
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      color: _g(0.04)),
                  child: Row(children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: status == 'active'
                            ? kGreen.withValues(alpha: 0.1)
                            : kGold.withValues(alpha: 0.1),
                      ),
                      child: Center(
                          child: Text(
                              status == 'active' ? '⏳' : '🏆',
                              style: const TextStyle(fontSize: 22))),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                        child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                          Text(d['description'] ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 3),
                          Text(
                              status == 'active'
                                  ? '$offers προσφορές · Ενεργό'
                                  : 'Ολοκληρώθηκε · $offers προσφορές',
                              style: TextStyle(
                                  color: status == 'active'
                                      ? kGreen
                                      : kGold.withValues(alpha: 0.7),
                                  fontSize: 11)),
                        ])),
                    Icon(Icons.arrow_forward_ios,
                        color: _g(0.2), size: 14),
                  ]),
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }
}


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
            color: const Color(0xFF080808),
            boxShadow: [BoxShadow(
                color: Colors.black.withValues(alpha: 0.5), blurRadius: 20)],
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
                        gradient: hasActiveRequest
                            ? const LinearGradient(colors: [kGreen, Color(0xFF2AA060)])
                            : const RadialGradient(colors: [kGoldLight, kGold, kGoldDark]),
                        border: Border.all(
                            color: hasActiveRequest
                                ? kGreen.withValues(alpha: 0.9)
                                : kGold.withValues(alpha: 0.9),
                            width: 2),
                        boxShadow: [BoxShadow(
                            color: (hasActiveRequest ? kGreen : kGold).withValues(alpha: 0.5),
                            blurRadius: 16, spreadRadius: 1)],
                      ),
                      child: Center(child: hasActiveRequest
                          ? const Icon(Icons.local_offer_rounded,
                              color: Colors.white, size: 28)
                          : const Text('G', style: TextStyle(
                              fontFamily: 'Raleway', fontSize: 30,
                              fontWeight: FontWeight.bold,
                              color: Colors.black, height: 1))),
                    ),
                    // Badge
                    if (hasActiveRequest)
                      Positioned(top: -4, right: -4,
                        child: Container(
                          width: 18, height: 18,
                          decoration: const BoxDecoration(
                              color: Colors.red, shape: BoxShape.circle),
                          child: Center(child: Text('!',
                              style: TextStyle(color: _gw,
                                  fontSize: 11, fontWeight: FontWeight.bold))),
                        ),
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

class _ProMenuCard extends StatelessWidget {
  final String emoji, title, sub;
  final VoidCallback onTap;
  const _ProMenuCard({required this.emoji, required this.title, required this.sub, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: _g(0.04),
        border: Border.all(color: _g(0.08)),
      ),
      child: Row(children: [
        Text(emoji, style: const TextStyle(fontSize: 22)),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(title, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
          Text(sub, style: TextStyle(color: _g(0.35), fontSize: 10), maxLines: 1, overflow: TextOverflow.ellipsis),
        ])),
        Icon(Icons.arrow_forward_ios, color: _g(0.2), size: 11),
      ]),
    ),
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
  String _activeTab = 'requests';
  final Set<String> _submittedIds = {};
  bool _isAvailable = true;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    if (!mounted) return;
    setState(() {
      _proName = doc.data()?['name'] ?? '';
      _proId = user.uid;
      _isAvailable = doc.data()?['isAvailable'] ?? true;
    });
  }

  Future<void> _toggleAvailability(bool val) async {
    setState(() => _isAvailable = val);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      await FirebaseFirestore.instance.collection('professionals').doc(uid).set(
          {'isAvailable': val}, SetOptions(merge: true));
      await FirebaseFirestore.instance.collection('users').doc(uid).set(
          {'isAvailable': val}, SetOptions(merge: true));
    }
  }

  Future<void> _respondBooking(String bookingId, String action) async {
    try {
      final bookingDoc = await FirebaseFirestore.instance
          .collection('bookings')
          .doc(bookingId)
          .get();
      final userId = bookingDoc.data()?['userId'] as String?;

      await FirebaseFirestore.instance
          .collection('bookings')
          .doc(bookingId)
          .update({
        'status': action == 'accept' ? 'accepted' : 'rejected',
        'respondedAt': FieldValue.serverTimestamp(),
      });

      if (userId != null) {
        final isAccepted = action == 'accept';
        await FirebaseFirestore.instance
            .collection('users')
            .doc(userId)
            .collection('notifications')
            .add({
          'title': isAccepted ? '✅ Αίτημα αποδεκτό!' : '❌ Αίτημα απορρίφθηκε',
          'body': isAccepted
              ? 'Ο $_proName αποδέχτηκε το αίτημά σου!'
              : 'Ο $_proName δεν είναι διαθέσιμος αυτή τη στιγμή.',
          'isRead': false,
          'bookingId': bookingId,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      try {
        await http.post(
          Uri.parse('$kBackendUrl/booking-response'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'bookingId': bookingId, 'action': action}),
        );
      } catch (_) {}

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                action == 'accept' ? '✅ Αποδέχτηκες!' : '❌ Απορρίφθηκε')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Σφάλμα: $e')));
      }
    }
  }

  Widget _buildTab(String value, String label) {
    final active = _activeTab == value;
    return GestureDetector(
      onTap: () => setState(() => _activeTab = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: active
              ? const LinearGradient(colors: [kGoldLight, kGold])
              : null,
          color: active ? null : Colors.transparent,
          boxShadow: active
              ? [BoxShadow(color: kGold.withValues(alpha: 0.3), blurRadius: 8)]
              : null,
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 11,
                fontWeight: active ? FontWeight.w800 : FontWeight.w400,
                color: active ? Colors.black : _g(0.4))),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(children: [

          // ══════════════════════════════════════
          // HERO HEADER — gradient banner
          // ══════════════════════════════════════
          Container(
            margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  kGold.withValues(alpha: 0.18),
                  kGold.withValues(alpha: 0.04),
                ],
              ),
              border: Border.all(color: kGold.withValues(alpha: 0.35), width: 1.5),
              boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.08), blurRadius: 24)],
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Top row: logo + actions
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: kGold.withValues(alpha: 0.15),
                    ),
                    child: ShaderMask(
                      shaderCallback: (b) => const LinearGradient(
                          colors: [kGoldLight, kGold]).createShader(b),
                      child: const Text('GOREALAI',
                          style: TextStyle(
                              fontFamily: 'Raleway', fontSize: 10,
                              letterSpacing: 4, fontWeight: FontWeight.w800,
                              color: Colors.white)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
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
              ),
            ]),
          ),

          const SizedBox(height: 12),

          // ══ Διαθεσιμότητα toggle ══
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: _g(0.04),
              border: Border.all(color: _isAvailable ? kGreen.withValues(alpha: 0.3) : _g(0.08)),
            ),
            child: Row(children: [
              Container(width: 10, height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isAvailable ? kGreen : _g(0.2),
                    boxShadow: _isAvailable ? [BoxShadow(color: kGreen.withValues(alpha: 0.6), blurRadius: 6)] : [],
                  )),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Διαθέσιμος για αιτήματα',
                    style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(_isAvailable ? 'Λαμβάνεις νέα αιτήματα' : 'Δεν λαμβάνεις αιτήματα',
                    style: TextStyle(color: _g(0.4), fontSize: 11)),
              ])),
              Switch(
                value: _isAvailable,
                onChanged: _toggleAvailability,
                activeColor: kGreen,
                activeTrackColor: kGreen.withValues(alpha: 0.2),
                inactiveThumbColor: _g(0.3),
                inactiveTrackColor: _g(0.08),
              ),
            ]),
          ),

          const SizedBox(height: 12),

          // ══ Grid menu ══
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              childAspectRatio: 2.4,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              children: [
                _ProMenuCard(emoji: '📋', title: 'Αιτήματα', sub: 'Ολοκλ αιτήματα',
                    onTap: () => setState(() => _activeTab = 'requests')),
                _ProMenuCard(emoji: '💬', title: 'Μηνύματα', sub: 'Εξυπηρέτηση',
                    onTap: () {}),
                _ProMenuCard(emoji: '👤', title: 'Mini CV', sub: 'Βιογραφικό',
                    onTap: () => Navigator.push(context, PageRouteBuilder(
                      pageBuilder: (_, __, ___) => const ProfileScreen(),
                      transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
                    ))),
                _ProMenuCard(emoji: '📸', title: 'Portfolio', sub: 'Φωτογραφίες',
                    onTap: () => Navigator.push(context, PageRouteBuilder(
                      pageBuilder: (_, __, ___) => const ProfileScreen(),
                      transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
                    ))),
                _ProMenuCard(emoji: '📅', title: 'Bookings', sub: 'Προπληρωμένα',
                    onTap: () => setState(() => _activeTab = 'pending')),
                _ProMenuCard(emoji: '❌', title: 'Απορριφθέντα', sub: 'Ιστορικό',
                    onTap: () => setState(() => _activeTab = 'rejected')),
                _ProMenuCard(emoji: '📱', title: 'Social Media', sub: 'Instagram & TikTok',
                    onTap: () {}),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // ══════════════════════════════════════
          // TABS — redesigned pill style
          // ══════════════════════════════════════
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: _g(0.04),
                border: Border.all(color: _g(0.07)),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  _buildTab('requests', '🔔 Αιτήματα'),
                  const SizedBox(width: 4),
                  _buildTab('pending', '⏳ Bookings'),
                  const SizedBox(width: 4),
                  _buildTab('accepted', '✅ Αποδεκτά'),
                  const SizedBox(width: 4),
                  _buildTab('rejected', '❌ Απορριφθέντα'),
                ]),
              ),
            ),
          ),
          const SizedBox(height: 10),

          // Content list
          Expanded(
            child: _activeTab == 'requests'
                ? _buildRequestsList()
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
        final docs = snap.data!.docs
            .where((d) => !_submittedIds.contains(d.id))
            .toList();
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
            final now = DateTime.now();
            final remaining = expiresAt != null
                ? expiresAt.toDate().difference(now)
                : null;
            final remainingStr = remaining != null && remaining.isNegative
                ? 'Έληξε'
                : remaining != null
                    ? '${remaining.inMinutes}λ ${(remaining.inSeconds % 60).toString().padLeft(2, '0')}δ'
                    : '';
            final offersCountInCard = d['offersCount'] as int? ?? 0;
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
                          Text(criteriaLabel, style: const TextStyle(
                              color: kGold, fontSize: 8, fontWeight: FontWeight.w700)),
                        ]),
                      ),
                    ]),

                    const SizedBox(height: 12),
                    // Divider
                    Container(height: 1,
                        color: _g(0.06)),
                    const SizedBox(height: 12),

                    // Description
                    Text(d['description'] ?? '',
                        style: TextStyle(fontSize: 13,
                            color: _g(0.75), height: 1.5)),

                    // Images
                    if ((d['hasImages'] == true || (d['imageCount'] ?? 0) > 0)) ...[
                      const SizedBox(height: 10),
                      _RequestImageGallery(requestData: d, requestId: requestId),
                    ],

                    // User's audio message
                    if ((d['audioUrl'] as String?)?.isNotEmpty == true) ...[
                      const SizedBox(height: 8),
                      _AudioPlayWidget(url: d['audioUrl'] as String),
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
                      if (remainingStr.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            color: _g(0.04),
                            border: Border.all(color: _g(0.1)),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Text('⏱️', style: TextStyle(fontSize: 10)),
                            const SizedBox(width: 4),
                            Text(remainingStr,
                                style: TextStyle(color: _g(0.6),
                                    fontSize: 10, fontWeight: FontWeight.w500)),
                          ]),
                        ),
                      ],
                    ]),

                    const SizedBox(height: 14),

                    // CTA Button
                    _PremiumButton(
                      label: '💼 Στείλε Προσφορά',
                      gradient: const LinearGradient(colors: [kGoldLight, kGold]),
                      textColor: Colors.black,
                      fontSize: 13,
                      onTap: () => _showOfferDialog(requestId, d),
                    ),
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
    String? offerAudioUrl;
    bool offerRecording = false;
    bool offerUploading = false;
    Duration offerDur = Duration.zero;
    Timer? offerTimer;
    final offerRec = AudioRecorder();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                color: const Color(0xFF0D0A04),
                border: Border.all(color: kGold.withValues(alpha: 0.3))),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('💼 Στείλε Προσφορά',
                  style: TextStyle(fontFamily: 'Raleway', fontSize: 18,
                      fontWeight: FontWeight.w800, color: Colors.white)),
              const SizedBox(height: 6),
              Text(requestData['description'] ?? '',
                  maxLines: 2, overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: _g(0.4))),
              const SizedBox(height: 20),
              // Τιμή
              TextField(
                controller: priceCtrl,
                keyboardType: TextInputType.number,
                style: TextStyle(color: _gw, fontSize: 22,
                    fontWeight: FontWeight.w800),
                textAlign: TextAlign.center,
                decoration: InputDecoration(
                  hintText: '0',
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
              // Διαθεσιμότητα
              Row(children: [
                Text('Διαθέσιμος: ', style: TextStyle(
                    fontSize: 12, color: _g(0.5))),
                const SizedBox(width: 8),
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
              const SizedBox(height: 12),
              // Audio message row
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: _g(0.05),
                  border: Border.all(color: kGold.withValues(alpha: 0.2)),
                ),
                child: Row(children: [
                  GestureDetector(
                    onTap: () async {
                      if (offerRecording) {
                        offerTimer?.cancel();
                        final path = await offerRec.stop();
                        setS(() { offerRecording = false; offerUploading = true; });
                        if (path != null) {
                          try {
                            final uid = FirebaseAuth.instance.currentUser?.uid ?? 'anon';
                            final ts = DateTime.now().millisecondsSinceEpoch;
                            Uint8List bytes;
                            if (path.startsWith('blob:')) {
                              final resp = await http.get(Uri.parse(path));
                              bytes = resp.bodyBytes;
                            } else {
                              bytes = await XFile(path).readAsBytes();
                            }
                            final ext = path.contains('.') ? path.split('.').last.split('?').first : 'm4a';
                            final ct = ext == 'webm' ? 'audio/webm' : 'audio/m4a';
                            final ref = FirebaseStorage.instance.ref('offers/audio/${uid}_$ts.$ext');
                            await ref.putData(bytes, SettableMetadata(contentType: ct));
                            final url = await ref.getDownloadURL();
                            setS(() { offerAudioUrl = url; offerUploading = false; });
                          } catch (_) {
                            setS(() => offerUploading = false);
                          }
                        } else {
                          setS(() => offerUploading = false);
                        }
                      } else {
                        final ok = await offerRec.hasPermission();
                        if (!ok) return;
                        await offerRec.start(const RecordConfig(), path: '');
                        setS(() { offerRecording = true; offerDur = Duration.zero; });
                        offerTimer = Timer.periodic(const Duration(seconds: 1), (_) {
                          setS(() => offerDur += const Duration(seconds: 1));
                        });
                      }
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 38, height: 38,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: offerRecording ? Colors.red : kGold.withValues(alpha: 0.15),
                        border: Border.all(color: offerRecording ? Colors.red : kGold.withValues(alpha: 0.4)),
                      ),
                      child: Center(child: Icon(
                        offerRecording ? Icons.stop_rounded : Icons.mic_rounded,
                        color: offerRecording ? Colors.white : kGold, size: 18,
                      )),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: offerUploading
                    ? Row(children: [
                        const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(color: kGold, strokeWidth: 2)),
                        const SizedBox(width: 8),
                        Text('Αποστολή...', style: TextStyle(color: _g(0.5), fontSize: 11)),
                      ])
                    : offerRecording
                    ? Row(children: [
                        Container(width: 6, height: 6, decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.red)),
                        const SizedBox(width: 6),
                        Text('${offerDur.inSeconds}″', style: const TextStyle(color: Colors.red, fontSize: 11, fontWeight: FontWeight.w700)),
                        const SizedBox(width: 6),
                        Text('Ηχογράφηση...', style: TextStyle(color: _g(0.5), fontSize: 11)),
                      ])
                    : offerAudioUrl != null
                    ? Row(children: [
                        const Icon(Icons.mic, color: kGreen, size: 13),
                        const SizedBox(width: 6),
                        Text('Ηχητικό ✓', style: const TextStyle(color: kGreen, fontSize: 11, fontWeight: FontWeight.w600)),
                        const Spacer(),
                        GestureDetector(
                          onTap: () => setS(() => offerAudioUrl = null),
                          child: Icon(Icons.close, color: _g(0.4), size: 14),
                        ),
                      ])
                    : Text('Ηχητικό μήνυμα (προαιρετικό)', style: TextStyle(color: _g(0.4), fontSize: 11)),
                  ),
                ]),
              ),
              const SizedBox(height: 20),
              Row(children: [
                Expanded(child: GestureDetector(
                  onTap: () {
                    offerTimer?.cancel();
                    offerRec.stop();
                    offerRec.dispose();
                    Navigator.pop(ctx);
                  },
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
                    offerTimer?.cancel();
                    offerRec.dispose();
                    Navigator.pop(ctx);
                    await _submitOffer(requestId, requestData, price, msgCtrl.text.trim(), available, audioUrl: offerAudioUrl);
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
    double price, String message, String available, {String? audioUrl}) async {
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
        if (audioUrl != null) 'audioUrl': audioUrl,
      }),
    ).timeout(const Duration(seconds: 8));

    if (response.statusCode == 200) {
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
      await _submitOfferFallback(requestId, price, message, available, audioUrl: audioUrl);
    }
  } catch (e) {
    // Network error — fallback στη Firestore
    await _submitOfferFallback(requestId, price, message, available, audioUrl: audioUrl);
  }
}

// Fallback μόνο αν το server δεν απαντά
Future<void> _submitOfferFallback(String requestId, double price,
    String message, String available, {String? audioUrl}) async {
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('⚠️ Έχεις ήδη στείλει προσφορά!')),
        );
      }
      return;
    }

    await FirebaseFirestore.instance.collection('offers').add({
      'requestId': requestId,
      'professionalId': _proId ?? '',
      'professionalName': _proName ?? '',
      'price': price,
      'message': message,
      'availableFrom': available,
      'rating': 4.8,
      'emoji': '🔧',
      'createdAt': FieldValue.serverTimestamp(),
      if (audioUrl != null) 'audioUrl': audioUrl,
    });

    await FirebaseFirestore.instance
        .collection('requests').doc(requestId)
        .update({'offersCount': FieldValue.increment(1)});

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
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Σφάλμα: $e')));
    }
  }
}
}

// ── Request Profession Picker ──
// Τα επαγγέλματα διαβάζονται live από Firestore (admin)
class _RequestProfessionPicker extends StatefulWidget {
  final String? value;
  final ValueChanged<String?> onChanged;
  const _RequestProfessionPicker({required this.value, required this.onChanged});
  @override
  State<_RequestProfessionPicker> createState() => _RequestProfessionPickerState();
}
class _RequestProfessionPickerState extends State<_RequestProfessionPicker> {
  // Fallback list — ίδιο με τη σελίδα admin
  static const _fallback = [
    'Συνεργείο Ανακαίνισης', 'Συνεργείο Κατασκευών', 'Συνεργείο Βαφής & Διακόσμησης',
    'Συνεργείο Ηλεκτρολόγων', 'Συνεργείο Υδραυλικών', 'Συνεργείο Κλιματισμού',
    'Ηλεκτρολόγος', 'Υδραυλικός', 'Ψυκτικός', 'Ελαιοχρωματιστής',
    'Μηχανικός', 'Κτίστης', 'Ξυλουργός', 'Υαλουργός',
    'Τεχνικός Ανελκυστήρων', 'Αποφράξεις', 'Αλουμινάς', 'Πλακάς',
    'Συντήρηση Κλιματιστικών', 'Εγκατάσταση Ηλιακών',
    'Παθολόγος', 'Παιδίατρος', 'Οδοντίατρος', 'Φυσιοθεραπευτής',
    'Ψυχολόγος', 'Διατροφολόγος',
    'Καθαρίστρια', 'Κηπουρός', 'Baby Sitter', 'Μετακομίσεις',
    'Καθηγητής Μαθηματικών', 'Καθηγητής Αγγλικών', 'Personal Trainer',
    'Web Developer', 'Γραφίστας', 'Φωτογράφος', 'Τεχνικός Υπολογιστών',
    'Μηχανικός Αυτοκινήτων', 'Λογιστής', 'Δικηγόρος', 'Αρχιτέκτονας',
  ];

  Future<void> _showPicker() async {
    // Φέρε από Firestore αν υπάρχουν
    List<String> items = List.from(_fallback);
    try {
      final snap = await FirebaseFirestore.instance
          .collection('professionals')
          .where('is_active', isEqualTo: true)
          .get();
      final specialties = snap.docs
          .map((d) => d.data()['specialty'] as String? ?? '')
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList();
      if (specialties.isNotEmpty) {
        for (final s in specialties) {
          if (!items.contains(s)) items.insert(0, s);
        }
      }
    } catch (_) {}

    if (!mounted) return;
    final result = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _SimpleListPicker(
        title: '🔨 Είδος επαγγελματία',
        items: items,
        selected: widget.value,
      ),
    );
    if (result != null) widget.onChanged(result);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: _showPicker,
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: const Color(0xFF0E0B04),
        border: Border.all(
            color: widget.value != null
                ? kGold.withValues(alpha: 0.6)
                : kGold.withValues(alpha: 0.25)),
      ),
      child: Row(children: [
        Text(widget.value != null ? '🔨' : '🔨',
            style: const TextStyle(fontSize: 18)),
        const SizedBox(width: 12),
        Expanded(child: Text(
            widget.value ?? 'Επίλεξε επάγγελμα...',
            style: TextStyle(
                color: widget.value != null
                    ? Colors.white
                    : _g(0.35),
                fontSize: 14))),
        Icon(Icons.arrow_drop_down,
            color: kGold.withValues(alpha: 0.6)),
      ]),
    ),
  );
}

// ── Request Location Picker ──
class _RequestLocationPicker extends StatefulWidget {
  final String? value;
  final ValueChanged<String?> onChanged;
  const _RequestLocationPicker({required this.value, required this.onChanged});
  @override
  State<_RequestLocationPicker> createState() => _RequestLocationPickerState();
}
class _RequestLocationPickerState extends State<_RequestLocationPicker> {
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
    );
    if (result == null) return;
    if (result == '📍 Κοντά μου (GPS)') {
      // Χρήση GPS
      widget.onChanged('Κοντά μου');
    } else {
      widget.onChanged(result);
    }
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: _showPicker,
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: const Color(0xFF0E0B04),
        border: Border.all(
            color: widget.value != null
                ? kGold.withValues(alpha: 0.6)
                : kGold.withValues(alpha: 0.25)),
      ),
      child: Row(children: [
        const Text('📍', style: TextStyle(fontSize: 18)),
        const SizedBox(width: 12),
        Expanded(child: Text(
            widget.value ?? 'Επίλεξε περιοχή...',
            style: TextStyle(
                color: widget.value != null
                    ? Colors.white
                    : _g(0.35),
                fontSize: 14))),
        Icon(Icons.arrow_drop_down,
            color: kGold.withValues(alpha: 0.6)),
      ]),
    ),
  );
}

// ── Simple List Picker (reusable) ──
class _SimpleListPicker extends StatefulWidget {
  final String title;
  final List<String> items;
  final String? selected;
  const _SimpleListPicker({
    required this.title, required this.items, this.selected});
  @override
  State<_SimpleListPicker> createState() => _SimpleListPickerState();
}
class _SimpleListPickerState extends State<_SimpleListPicker> {
  late String? _sel;
  @override
  void initState() {
    super.initState();
    _sel = widget.selected;
  }
  @override
  Widget build(BuildContext context) => Container(
    height: MediaQuery.of(context).size.height * 0.75,
    decoration: const BoxDecoration(
      color: Color(0xFF0E0B04),
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    child: Column(children: [
      Container(width: 36, height: 4,
          margin: const EdgeInsets.only(top: 12, bottom: 14),
          decoration: BoxDecoration(
              color: _g(0.15),
              borderRadius: BorderRadius.circular(2))),
      Text(widget.title, style: const TextStyle(
          color: Colors.white, fontSize: 16,
          fontFamily: 'Raleway', fontWeight: FontWeight.w700)),
      const SizedBox(height: 10),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Divider(color: kGold.withValues(alpha: 0.15), height: 1),
      ),
      Expanded(child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        itemCount: widget.items.length,
        itemBuilder: (_, i) {
          final item = widget.items[i];
          final isSel = _sel == item;
          return GestureDetector(
            onTap: () {
              setState(() => _sel = item);
              Future.delayed(const Duration(milliseconds: 150), () {
                Navigator.pop(context, item);
              });
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: isSel
                    ? kGold.withValues(alpha: 0.12)
                    : _g(0.04),
                border: Border.all(
                    color: isSel
                        ? kGold.withValues(alpha: 0.5)
                        : _g(0.06)),
              ),
              child: Row(children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 20, height: 20,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: isSel ? kGold : _g(0.25),
                          width: isSel ? 6 : 1.5))),
                const SizedBox(width: 12),
                Expanded(child: Text(item, style: TextStyle(
                    color: isSel ? kGold : Colors.white,
                    fontSize: 14,
                    fontWeight: isSel ? FontWeight.w600 : FontWeight.w400))),
                if (isSel) const Icon(Icons.check_rounded, color: kGold, size: 16),
              ]),
            ),
          );
        },
      )),
    ]),
  );
}

// lib/main.dart — αντικατάστησε ολόκληρη την _RequestImageGallery class

class _RequestImageGallery extends StatelessWidget {
  final Map<String, dynamic> requestData;
  final String? requestId;
  const _RequestImageGallery({required this.requestData, this.requestId});

  // Καθαρίζει data URI prefix και επιστρέφει καθαρό base64
  static Uint8List? _decodeImage(String imgData) {
    try {
      if (imgData.isEmpty) return null;
      String clean = imgData;
      // Αφαίρεσε data URI prefix αν υπάρχει (πχ "data:image/jpeg;base64,")
      if (clean.contains(',')) {
        clean = clean.split(',').last;
      }
      // Αφαίρεσε whitespace/newlines που σπάνε το base64
      clean = clean.replaceAll(RegExp(r'\s'), '');
      return base64Decode(clean);
    } catch (e) {
      debugPrint('Image decode error: $e');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final images = requestData['images'] as List?;
    if (images == null || images.isEmpty) {
      return GestureDetector(
        onTap: () async {
          if (requestId == null) return;
          try {
            final doc = await FirebaseFirestore.instance
                .collection('requests')
                .doc(requestId)
                .get();
            if (!context.mounted) return;
            final data = doc.data();
            final imgs = data?['images'] as List?;
            if (imgs == null || imgs.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Ο χρήστης δεν έχει προσθέσει φωτογραφίες')),
              );
              return;
            }
            final all = imgs.map((e) => e.toString()).toList();
            _showFullImage(context, all[0], 0, all);
          } catch (e) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Σφάλμα φόρτωσης: $e')),
              );
            }
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: kGold.withValues(alpha: 0.1)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Text('📷', style: TextStyle(fontSize: 12)),
            const SizedBox(width: 6),
            Text(
              '${requestData['imageCount'] ?? 1} φωτογραφί${((requestData['imageCount'] ?? 1) as int) == 1 ? 'α' : 'ες'} — πάτα για προβολή',
              style: const TextStyle(
                  color: kGold, fontSize: 11, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.open_in_new, color: kGold, size: 11),
          ]),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('📷', style: TextStyle(fontSize: 12)),
        const SizedBox(width: 6),
        Text('${images.length} φωτογραφί${images.length == 1 ? 'α' : 'ες'}',
            style: const TextStyle(
                color: kGold, fontSize: 11, fontWeight: FontWeight.w600)),
      ]),
      const SizedBox(height: 8),
      SizedBox(
        height: 80,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          itemCount: images.length,
          itemBuilder: (context, i) {
            final imgData = images[i] as String? ?? '';
            final bytes = _decodeImage(imgData);

            return GestureDetector(
              onTap: () => _showFullImage(context, imgData, i,
                  images.cast<String>()),
              child: Container(
                width: 80,
                height: 80,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: Colors.black,
                    border: Border.all(
                        color: kGold.withValues(alpha: 0.3))),
                clipBehavior: Clip.antiAlias,
                child: bytes != null
                    ? Image.memory(bytes, fit: BoxFit.cover)
                    : const Center(
                        child: Icon(Icons.broken_image_outlined,
                            color: Colors.white24, size: 28)),
              ),
            );
          },
        ),
      ),
    ]);
  }

  void _showFullImage(BuildContext context, String imgData, int idx,
      List<String> all) {
    final bytes = _decodeImage(imgData);
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('${idx + 1}/${all.length}',
                style: TextStyle(
                    color: _g(0.5),
                    fontSize: 12)),
            GestureDetector(
              onTap: () => Navigator.pop(ctx),
              child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _g(0.1)),
                  child: const Icon(Icons.close,
                      color: Colors.white, size: 18)),
            ),
          ]),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: bytes != null
                ? Image.memory(bytes, fit: BoxFit.contain)
                : const Padding(
                    padding: EdgeInsets.all(32),
                    child: Icon(Icons.broken_image,
                        color: Colors.white30, size: 64),
                  ),
          ),
        ]),
      ),
    );
  }
}

// ── AI Insights Widget ──
class _AIInsightsWidget extends StatelessWidget {
  final String text;
  const _AIInsightsWidget({required this.text});

  String _detectProfession(String t) {
    t = t.toLowerCase();
    if (t.contains('βαψ') || t.contains('βαφ') || t.contains('χρωμ') || t.contains('σαλόνι')) return 'Ελαιοχρωματιστής';
    if (t.contains('ηλεκτρ') || t.contains('ρεύμα') || t.contains('ασφάλεια')) return 'Ηλεκτρολόγος';
    if (t.contains('υδρ') || t.contains('νερ') || t.contains('βρύση') || t.contains('αποχέτ')) return 'Υδραυλικός';
    if (t.contains('κλιματ') || t.contains('air') || t.contains('ψυκτ')) return 'Τεχνικός Κλιματισμού';
    if (t.contains('καθαρ')) return 'Καθαρίστρια';
    if (t.contains('κηπ') || t.contains('δέντρ') || t.contains('γρασίδ')) return 'Κηπουρός';
    if (t.contains('μετακ') || t.contains('μεταφ')) return 'Εταιρεία Μεταφορών';
    if (t.contains('ξυλ') || t.contains('έπιπλ') || t.contains('πόρτ')) return 'Ξυλουργός';
    if (t.contains('φωτ') && (t.contains('γραφ') || t.contains('βάπτ') || t.contains('γάμ'))) return 'Φωτογράφος';
    if (t.contains('web') || t.contains('site') || t.contains('app')) return 'Web Developer';
    return null.toString();
  }

  Map<String, String> _estimateCost(String t) {
    t = t.toLowerCase();
    // Ανιχνεύω τετραγωνικά
    final m2 = RegExp(r'(\d+)\s*τ[μµ]').firstMatch(t);
    final area = m2 != null ? int.tryParse(m2.group(1)!) ?? 0 : 0;

    if (t.contains('βαψ') || t.contains('βαφ')) {
      if (area > 0) {
        final low = (area * 4).round();
        final high = (area * 8).round();
        return {'low': '$low', 'high': '$high', 'unit': '€ (υλικά + εργασία)'};
      }
      return {'low': '150', 'high': '400', 'unit': '€ (εκτίμηση)'};
    }
    if (t.contains('ηλεκτρ')) return {'low': '80', 'high': '250', 'unit': '€'};
    if (t.contains('υδρ')) return {'low': '60', 'high': '200', 'unit': '€'};
    if (t.contains('κλιματ')) return {'low': '100', 'high': '350', 'unit': '€'};
    if (t.contains('καθαρ')) return {'low': '40', 'high': '120', 'unit': '€'};
    return {'low': '50', 'high': '300', 'unit': '€ (εκτίμηση)'};
  }

  @override
  Widget build(BuildContext context) {
    final profession = _detectProfession(text);
    final isProfessionDetected = profession != 'null';
    final cost = _estimateCost(text);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Colors.black,
        border: Border.all(color: kGold.withValues(alpha: 0.3)),
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [kGold.withValues(alpha: 0.08), Colors.transparent]),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('🤖', style: TextStyle(fontSize: 14)),
          const SizedBox(width: 6),
          const Text('AI Ανάλυση', style: TextStyle(
              color: kGold, fontSize: 11, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 10),
        if (isProfessionDetected)
          _InsightRow(icon: '🎯', label: 'Κατηγορία', value: profession),
        _InsightRow(icon: '💰', label: 'Εκτιμώμενο κόστος',
            value: '${cost['low']}€–${cost['high']}${cost['unit']}'),
        _InsightRow(icon: '⏱', label: 'Αναμενόμενος χρόνος', value: '15 λεπτά για προσφορές'),
        _InsightRow(icon: '👥', label: 'Επαγγελματίες', value: 'Θα ειδοποιηθούν αμέσως'),
      ]),
    );
  }
}

class _InsightRow extends StatelessWidget {
  final String icon, label, value;
  const _InsightRow({required this.icon, required this.label, required this.value});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(children: [
      Text(icon, style: const TextStyle(fontSize: 12)),
      const SizedBox(width: 6),
      Text('$label: ', style: TextStyle(
          fontSize: 11, color: _g(0.45))),
      Expanded(child: Text(value, style: const TextStyle(
          fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600),
          overflow: TextOverflow.ellipsis)),
    ]),
  );
}

// ═══════════════════════════════════════
// REQUEST SCREEN — Βήμα 1
// ═══════════════════════════════════════
class RequestScreen extends StatefulWidget {
  final String userId, userName;
  final String? initialProfession, initialLocation;
  const RequestScreen(
      {required this.userId, required this.userName,
      this.initialProfession, this.initialLocation,
      super.key});
  @override
  State<RequestScreen> createState() => _RequestScreenState();
}

class _RequestScreenState extends State<RequestScreen>
    with TickerProviderStateMixin {
  final _textCtrl = TextEditingController();
  final _stt = stt.SpeechToText();
  bool _listening = false;
  String _selectedCriteria = 'cheap';
  bool _filterWithPhoto = false;
  double _filterMinRating = 0.0;
  final List<XFile> _images = [];
  XFile? _video;
  final _picker = ImagePicker();
  bool _sending = false;
  bool _showTip = false;
  String? _selectedProfession;
  String? _selectedLocation;
  late AnimationController _pulseCtrl;
  // Audio recording
  final _audioRec = AudioRecorder();
  bool _audioRecording = false;
  bool _audioUploading = false;
  String? _requestAudioUrl;
  Timer? _audioTimer;
  Duration _audioDur = Duration.zero;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1000))
      ..repeat(reverse: true);
    _textCtrl.addListener(() => setState(() {}));
    if (widget.initialProfession != null) {
      _selectedProfession = widget.initialProfession;
    }
    if (widget.initialLocation != null) {
      _selectedLocation = widget.initialLocation;
    }
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _textCtrl.dispose();
    _audioTimer?.cancel();
    _audioRec.dispose();
    super.dispose();
  }

  Future<void> _startVoice() async {
    final avail = await _stt.initialize();
    if (!avail) return;
    setState(() => _listening = true);
    await _stt.listen(
      onResult: (r) => setState(() => _textCtrl.text = r.recognizedWords),
      localeId: 'el_GR',
      listenFor: const Duration(minutes: 5),
      cancelOnError: false,
      partialResults: true,
    );
  }

  void _stopVoice() {
    _stt.stop();
    setState(() => _listening = false);
  }

  Future<void> _captureVideo() async {
    final video = await _picker.pickVideo(
      source: ImageSource.camera,
      maxDuration: const Duration(seconds: 20),
    );
    if (video != null && mounted) setState(() => _video = video);
  }

  Future<void> _startAudio() async {
    final hasPermission = await _audioRec.hasPermission();
    if (!hasPermission) return;
    await _audioRec.start(const RecordConfig(), path: '');
    setState(() {
      _audioRecording = true;
      _audioDur = Duration.zero;
    });
    _audioTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _audioDur += const Duration(seconds: 1));
    });
  }

  Future<void> _stopAudio() async {
    _audioTimer?.cancel();
    final path = await _audioRec.stop();
    setState(() { _audioRecording = false; _audioUploading = true; });
    if (path == null) { setState(() => _audioUploading = false); return; }
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? 'anon';
      final ts = DateTime.now().millisecondsSinceEpoch;
      Uint8List bytes;
      if (path.startsWith('blob:')) {
        final resp = await http.get(Uri.parse(path));
        bytes = resp.bodyBytes;
      } else {
        bytes = await XFile(path).readAsBytes();
      }
      final ext = path.contains('.') ? path.split('.').last.split('?').first : 'm4a';
      final ct = ext == 'webm' ? 'audio/webm' : 'audio/m4a';
      final ref = FirebaseStorage.instance.ref('requests/audio/${uid}_$ts.$ext');
      await ref.putData(bytes, SettableMetadata(contentType: ct));
      final url = await ref.getDownloadURL();
      if (mounted) setState(() { _requestAudioUrl = url; _audioUploading = false; });
    } catch (_) {
      if (mounted) setState(() => _audioUploading = false);
    }
  }

  // Resize to max 500px to keep Firestore document under 1MB (base64 limit ~750KB for 3 images)
  static Future<Uint8List?> _compressImage(Uint8List bytes) async {
    try {
      final codec = await instantiateImageCodec(bytes, targetWidth: 500, targetHeight: 500, allowUpscaling: false);
      final frame = await codec.getNextFrame();
      final byteData = await frame.image.toByteData(format: ImageByteFormat.png);
      frame.image.dispose();
      return byteData?.buffer.asUint8List();
    } catch (_) { return null; }
  }

  Future<void> _pickImage() async {
    final picked = await _picker.pickMultiImage();
    if (picked.isEmpty) return;
    final compressed = <XFile>[];
    for (final f in picked.take(3)) {
      try {
        final bytes = await f.readAsBytes();
        final small = await _compressImage(bytes);
        compressed.add(small != null
            ? XFile.fromData(small, name: f.name, mimeType: 'image/png')
            : f);
      } catch (_) { compressed.add(f); }
    }
    setState(() => _images.addAll(compressed));
  }

  bool _submitLock = false;  // Guard κατά double submit

  Future<void> _submit() async {
    if (_submitLock) return;  // Αποφυγή double tap
    _submitLock = true;
    // Έλεγξε αν υπάρχουν ήδη 2 ενεργά αιτήματα
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
        'filterWithPhoto': _filterWithPhoto,
        'filterMinRating': _filterMinRating,
        if (_requestAudioUrl != null) 'audioUrl': _requestAudioUrl,
      });

      // Server για AI categorization + pro notifications
      try {
        // Encode images as base64
        List<String> imageBase64 = [];
        for (final img in _images) {
          try {
            final bytes = await img.readAsBytes();
            imageBase64.add(base64Encode(bytes));
          } catch (_) {}
        }
        // Αποθήκευσε images στο Firestore (base64) για να τα βλέπει ο επαγγελματίας
        if (imageBase64.isNotEmpty) {
          await FirebaseFirestore.instance
              .collection('requests')
              .doc(docRef.id)
              .update({'images': imageBase64, 'hasImages': true});
        }

        await http
            .post(
              Uri.parse('$kBackendUrl/submit-request'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'requestId': docRef.id,
                'userId': widget.userId,
                'userName': widget.userName,
                'description': _textCtrl.text.trim(),
                'criteria': _selectedCriteria,
                'profession': _selectedProfession ?? '',
                'location': _selectedLocation ?? '',
                'imageCount': _images.length,
                'images': imageBase64,
              }),
            )
            .timeout(const Duration(seconds: 55));
} catch (_) {
  await _notifyProsDirectly(docRef.id, _textCtrl.text.trim(),
    _selectedProfession ?? '', _selectedLocation ?? '',
    widget.userName, _images.length);
}

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
    String userName,
    int imageCount,
  ) async {
    try {
      final professionLower = profession.toLowerCase();
      final locationLower = location.toLowerCase();
      final snap = await FirebaseFirestore.instance
          .collection('professionals')
          .where('is_active', isEqualTo: true)
          .get();
      int notified = 0;
      for (final doc in snap.docs) {
        final d = doc.data();
        final proUserId = d['userId'] as String? ?? '';
        if (proUserId.isEmpty) continue;
        final specialty = (d['specialty'] as String? ?? '').toLowerCase();
        if (specialty.isNotEmpty && professionLower.isNotEmpty) {
          if (!specialty.contains(professionLower) &&
              !professionLower.contains(specialty)) continue;
        }
        if (location.isNotEmpty && location != 'Κοντά μου') {
          final area = (d['area'] as String? ?? '').toLowerCase();
          if (area.isNotEmpty &&
              !area.contains(locationLower) &&
              !locationLower.contains(area)) continue;
        }
        await FirebaseFirestore.instance
            .collection('users')
            .doc(proUserId)
            .collection('notifications')
            .add({
          'title': '🔔 Νέο αίτημα${profession.isNotEmpty ? " — $profession" : ""}!',
          'body': '$userName: ${description.length > 80 ? "${description.substring(0, 80)}..." : description}',
          'isRead': false,
          'requestId': requestId,
          'type': 'new_request',
          'hasImages': imageCount > 0,
          'imageCount': imageCount,
          'createdAt': FieldValue.serverTimestamp(),
        });
        notified++;
      }
      debugPrint('📬 Flutter fallback: $notified pros notified');
    } catch (e) {
      debugPrint('_notifyProsDirectly error: $e');
    }
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(children: [
          _TopBar(label: '✦ ΝΕΟ ΑΙΤΗΜΑ'),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Τι χρειάζεσαι;', style: TextStyle(
                      fontFamily: 'Raleway', fontSize: 26,
                      fontWeight: FontWeight.w800, color: Colors.white)),
                  const SizedBox(height: 4),
                  Text('Οι επαγγελματίες ανταγωνίζονται — το AI επιλέγει τους 3 καλύτερους.',
                      style: TextStyle(fontSize: 12,
                          color: _g(0.4))),
                  const SizedBox(height: 12),

                  // ══ PILL PICKERS: Profession + Location ══
                  Row(children: [
                    Expanded(child: GestureDetector(
                      onTap: () async {
                        final v = await showModalBottomSheet<String>(
                          context: context,
                          backgroundColor: Colors.transparent,
                          isScrollControlled: true,
                          builder: (_) => _SimpleListPicker(
                            title: '🔨 Είδος επαγγελματία',
                            items: ([
                              'Αλουμινάς', 'Αποφράξεις', 'Αρχιτέκτονας',
                              'Baby Sitter', 'Γραφίστας', 'Δικηγόρος',
                              'Διατροφολόγος', 'Εγκατάσταση Ηλιακών',
                              'Ηλεκτρολόγος', 'Θεραπευτής', 'Καθαρίστρια',
                              'Καθηγητής Αγγλικών', 'Καθηγητής Μαθηματικών',
                              'Κηπουρός', 'Κτίστης', 'Λογιστής',
                              'Μετακομίσεις', 'Μηχανικός', 'Μηχανικός Αυτοκινήτων',
                              'Ξυλουργός', 'Οδοντίατρος', 'Παθολόγος', 'Παιδίατρος',
                              'Personal Trainer', 'Πλακάς', 'Συνεργείο Ανακαίνισης',
                              'Συνεργείο Βαφής & Διακόσμησης', 'Συνεργείο Ηλεκτρολόγων',
                              'Συνεργείο Κατασκευών', 'Συνεργείο Κλιματισμού',
                              'Συνεργείο Υδραυλικών', 'Συντήρηση Κλιματιστικών',
                              'Τεχνικός Ανελκυστήρων', 'Τεχνικός Υπολογιστών',
                              'Υαλουργός', 'Υδραυλικός', 'Φυσιοθεραπευτής',
                              'Φωτογράφος', 'Web Developer', 'Ελαιοχρωματιστής',
                              'Ψυκτικός', 'Ψυχολόγος',
                            ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()))),
                            selected: _selectedProfession,
                          ),
                        );
                        if (v != null && mounted) setState(() => _selectedProfession = v);
                      },
                      child: Container(
                        height: 44,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          color: _g(0.05),
                          border: Border.all(color: _selectedProfession != null
                              ? kGold.withValues(alpha: 0.6)
                              : kGold.withValues(alpha: 0.2)),
                        ),
                        child: Row(children: [
                          const Text('🔨', style: TextStyle(fontSize: 14)),
                          const SizedBox(width: 6),
                          Expanded(child: Text(
                            _selectedProfession ?? 'Επάγγελμα',
                            style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600,
                              color: _selectedProfession != null
                                  ? Colors.white
                                  : _g(0.4),
                            ),
                            overflow: TextOverflow.ellipsis,
                          )),
                          Icon(Icons.expand_more, color: kGold.withValues(alpha: 0.6), size: 16),
                        ]),
                      ),
                    )),
                    const SizedBox(width: 8),
                    Expanded(child: GestureDetector(
                      onTap: () async {
                        final v = await showModalBottomSheet<String>(
                          context: context,
                          backgroundColor: Colors.transparent,
                          isScrollControlled: true,
                          builder: (_) => _SimpleListPicker(
                            title: '📍 Περιοχή εργασίας',
                            items: const [
                              '📍 Κοντά μου (GPS)',
                              'Αθήνα Κέντρο', 'Κολωνάκι', 'Γλυφάδα', 'Βούλα', 'Βουλιαγμένη',
                              'Καλλιθέα', 'Νέα Σμύρνη', 'Παλαιό Φάληρο', 'Άλιμος', 'Χαλάνδρι',
                              'Μαρούσι', 'Κηφισιά', 'Νέα Ιωνία', 'Αγία Παρασκευή', 'Ζωγράφου',
                              'Βύρωνας', 'Ηλιούπολη', 'Περιστέρι', 'Αιγάλεω', 'Πειραιάς',
                              'Θεσσαλονίκη Κέντρο', 'Καλαμαριά', 'Πυλαία', 'Θέρμη',
                              'Πάτρα', 'Ηράκλειο Κρήτης', 'Χανιά', 'Ρέθυμνο', 'Λάρισα', 'Βόλος',
                              'Ιωάννινα', 'Κέρκυρα', 'Ρόδος', 'Μυτιλήνη',
                            ],
                            selected: _selectedLocation,
                          ),
                        );
                        if (v == null) return;
                        if (mounted) setState(() => _selectedLocation = v == '📍 Κοντά μου (GPS)' ? 'Κοντά μου' : v);
                      },
                      child: Container(
                        height: 44,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          color: _g(0.05),
                          border: Border.all(color: _selectedLocation != null
                              ? kGreen.withValues(alpha: 0.6)
                              : kGold.withValues(alpha: 0.2)),
                        ),
                        child: Row(children: [
                          const Text('📍', style: TextStyle(fontSize: 14)),
                          const SizedBox(width: 6),
                          Expanded(child: Text(
                            _selectedLocation ?? 'Περιοχή',
                            style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600,
                              color: _selectedLocation != null
                                  ? Colors.white
                                  : _g(0.4),
                            ),
                            overflow: TextOverflow.ellipsis,
                          )),
                          Icon(Icons.expand_more, color: kGold.withValues(alpha: 0.6), size: 16),
                        ]),
                      ),
                    )),
                  ]),
                  const SizedBox(height: 12),

                  // ══ SEARCH BAR + MIC + SEND — ΕΝΑ ΠΛΑΙΣΙΟ ══
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(22),
                      color: const Color(0xFF0E0B04),
                      border: Border.all(
                        color: _listening
                            ? Colors.red.withValues(alpha: 0.7)
                            : kGold.withValues(alpha: 0.35),
                        width: _listening ? 2 : 1.5,
                      ),
                      boxShadow: [BoxShadow(
                        color: _listening
                            ? Colors.red.withValues(alpha: 0.2)
                            : kGold.withValues(alpha: 0.12),
                        blurRadius: 20,
                      )],
                    ),
                    child: Column(children: [
                      // Voice recording strip
                      if (_listening) Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 7),
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.1),
                          borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(22)),
                        ),
                        child: Row(children: [
                          Container(width: 7, height: 7,
                              decoration: const BoxDecoration(
                                  shape: BoxShape.circle, color: Colors.red)),
                          const SizedBox(width: 8),
                          const Text('Ηχογράφηση... μιλήστε τώρα',
                              style: TextStyle(color: Colors.red,
                                  fontSize: 11, fontWeight: FontWeight.w600)),
                        ]),
                      ),

                      // Text input area
                      Focus(
                        onFocusChange: (hasFocus) => setState(() => _showTip = hasFocus && _textCtrl.text.isEmpty),
                        child: TextField(
                          controller: _textCtrl,
                          maxLines: 5,
                          minLines: 3,
                          style: TextStyle(color: _gw,
                              fontSize: 15, height: 1.6),
                          decoration: InputDecoration(
                            hintText: 'πχ. "Θέλω να βάψω το σαλόνι μου ~30τμ..."',
                            hintStyle: TextStyle(
                                color: _g(0.25),
                                fontSize: 13, height: 1.5),
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                          ),
                        ),
                      ),
                      // Tip bubble
                      AnimatedCrossFade(
                        duration: const Duration(milliseconds: 250),
                        crossFadeState: _showTip ? CrossFadeState.showFirst : CrossFadeState.showSecond,
                        firstChild: Container(
                          margin: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            color: kGold.withValues(alpha: 0.1),
                            border: Border.all(color: kGold.withValues(alpha: 0.3)),
                          ),
                          child: Row(children: [
                            const Text('🤖', style: TextStyle(fontSize: 16)),
                            const SizedBox(width: 8),
                            Expanded(child: Text(
                              'Όσο πιο αναλυτικός είσαι, τόσο πιο στοχευμένες προσφορές θα λάβεις! πχ. μέγεθος χώρου, υλικά, χρόνος.',
                              style: TextStyle(fontSize: 11, color: _g(0.75), height: 1.4),
                            )),
                          ]),
                        ),
                        secondChild: const SizedBox.shrink(),
                      ),

                      // Audio status strip
                      if (_audioRecording || _audioUploading || _requestAudioUrl != null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          child: Row(children: [
                            if (_audioRecording) ...[
                              Container(width: 7, height: 7,
                                  decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.red)),
                              const SizedBox(width: 6),
                              Text('${_audioDur.inSeconds}″', style: const TextStyle(color: Colors.red, fontSize: 11, fontWeight: FontWeight.w700)),
                              const SizedBox(width: 6),
                              Text('Ηχογράφηση...', style: TextStyle(color: _g(0.5), fontSize: 11)),
                            ] else if (_audioUploading) ...[
                              const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(color: kGold, strokeWidth: 2)),
                              const SizedBox(width: 8),
                              Text('Αποστολή...', style: TextStyle(color: _g(0.5), fontSize: 11)),
                            ] else if (_requestAudioUrl != null) ...[
                              const Icon(Icons.mic, color: kGreen, size: 14),
                              const SizedBox(width: 6),
                              Text('Ηχητικό μήνυμα ✓', style: const TextStyle(color: kGreen, fontSize: 11, fontWeight: FontWeight.w600)),
                              const Spacer(),
                              GestureDetector(
                                onTap: () => setState(() => _requestAudioUrl = null),
                                child: Icon(Icons.close, color: _g(0.4), size: 14),
                              ),
                            ],
                          ]),
                        ),

                      // Bottom bar: mic + send INSIDE the box
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: const BorderRadius.vertical(
                              bottom: Radius.circular(22)),
                          color: kGold.withValues(alpha: 0.06),
                        ),
                        padding: const EdgeInsets.all(6),
                        child: Row(children: [
                          // AUDIO REC BUTTON
                          GestureDetector(
                            onTap: _audioRecording ? _stopAudio : _startAudio,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              width: 46, height: 46,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                color: _audioRecording ? Colors.red : _g(0.08),
                                border: Border.all(
                                    color: _audioRecording ? Colors.red : kGold.withValues(alpha: 0.3)),
                              ),
                              child: Center(child: Icon(
                                _audioRecording ? Icons.stop_rounded : Icons.mic_rounded,
                                color: _audioRecording ? Colors.white : kGold,
                                size: 22,
                              )),
                            ),
                          ),
                          const SizedBox(width: 6),
                          // PHOTO BUTTON
                          GestureDetector(
                            onTap: _images.length < 3 ? _pickImage : null,
                            child: Stack(children: [
                              Container(
                                width: 46, height: 46,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(14),
                                  color: _g(0.08),
                                  border: Border.all(color: kGold.withValues(alpha: 0.3)),
                                ),
                                child: Center(child: Icon(
                                  Icons.add_photo_alternate_outlined,
                                  color: _images.isEmpty ? kGold : kGreen,
                                  size: 22,
                                )),
                              ),
                              if (_images.isNotEmpty) Positioned(
                                top: 2, right: 2,
                                child: Container(
                                  width: 16, height: 16,
                                  decoration: const BoxDecoration(color: kGreen, shape: BoxShape.circle),
                                  child: Center(child: Text('${_images.length}',
                                      style: TextStyle(color: _gw, fontSize: 9, fontWeight: FontWeight.w700))),
                                ),
                              ),
                            ]),
                          ),
                          const SizedBox(width: 6),
                          // VIDEO BUTTON
                          GestureDetector(
                            onTap: _captureVideo,
                            child: Container(
                              width: 46, height: 46,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                color: _g(0.08),
                                border: Border.all(color: _video != null
                                    ? kGreen.withValues(alpha: 0.6)
                                    : kGold.withValues(alpha: 0.3)),
                              ),
                              child: Center(child: Icon(
                                Icons.videocam_outlined,
                                color: _video != null ? kGreen : kGold,
                                size: 22,
                              )),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // SEND BUTTON
                          Expanded(child: _sending
                            ? Container(height: 46,
                                decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(14),
                                    gradient: const LinearGradient(colors: [kGoldLight, kGold])),
                                child: const Center(child: SizedBox(width: 20, height: 20,
                                    child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2))))
                            : _PremiumButton(
                                label: '🚀  Στείλε αίτημα',
                                gradient: const LinearGradient(colors: [kGoldLight, kGold, kGoldDark]),
                                textColor: Colors.black,
                                fontSize: 13,
                                onTap: _submit,
                              )),
                        ]),
                      ),
                    ]),
                  ),

                  const SizedBox(height: 14),

                  // AI Insights (conditional, outside card)
                  if (_textCtrl.text.length > 10) ...[
                    _AIInsightsWidget(text: _textCtrl.text),
                    const SizedBox(height: 12),
                  ],

                  // ══ PHOTOS THUMBNAIL ROW (shows selected images) ══
                  if (_images.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 64,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: _images.asMap().entries.map((entry) {
                          final idx = entry.key;
                          final img = entry.value;
                          return Stack(children: [
                            Container(
                              width: 60, height: 60,
                              margin: const EdgeInsets.only(right: 8),
                              decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(10),
                                  color: Colors.black),
                              clipBehavior: Clip.antiAlias,
                              child: FutureBuilder<Uint8List?>(
                                future: img.readAsBytes(),
                                builder: (_, snap) {
                                  if (snap.hasData && snap.data != null)
                                    return Image.memory(snap.data!, fit: BoxFit.cover);
                                  return const Center(child: Icon(Icons.image, color: Colors.white24));
                                },
                              ),
                            ),
                            Positioned(
                              top: 0, right: 4,
                              child: GestureDetector(
                                onTap: () => setState(() => _images.removeAt(idx)),
                                child: Container(
                                  width: 16, height: 16,
                                  decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                                  child: const Icon(Icons.close, color: Colors.white, size: 10),
                                ),
                              ),
                            ),
                          ]);
                        }).toList(),
                      ),
                    ),
                  ],

                  // ══ CRITERIA ══
                  const SizedBox(height: 14),
                  Row(children: [
                    const Text('🎯', style: TextStyle(fontSize: 12)),
                    const SizedBox(width: 6),
                    Text('Τι σε ενδιαφέρει;',
                        style: TextStyle(fontSize: 11,
                            color: _g(0.5),
                            fontWeight: FontWeight.w600)),
                  ]),
                  const SizedBox(height: 10),
                  Row(children: [
                    _CriteriaChip(emoji: '💰', label: 'Φθηνότερο',
                        selected: _selectedCriteria == 'cheap',
                        onTap: () => setState(() => _selectedCriteria = 'cheap')),
                    const SizedBox(width: 8),
                    _CriteriaChip(emoji: '⭐', label: 'Value',
                        selected: _selectedCriteria == 'value',
                        onTap: () => setState(() => _selectedCriteria = 'value')),
                    const SizedBox(width: 8),
                    _CriteriaChip(emoji: '⚡', label: 'Άμεσα',
                        selected: _selectedCriteria == 'fast',
                        onTap: () => setState(() => _selectedCriteria = 'fast')),
                  ]),
                  const SizedBox(height: 8),
                  Row(children: [
                    _CriteriaChip(emoji: '📷', label: 'Με φωτο',
                        selected: _filterWithPhoto,
                        onTap: () => setState(() => _filterWithPhoto = !_filterWithPhoto)),
                    const SizedBox(width: 8),
                    _CriteriaChip(emoji: '4★+', label: '4+',
                        selected: _filterMinRating == 4.0,
                        onTap: () => setState(() => _filterMinRating = _filterMinRating == 4.0 ? 0.0 : 4.0)),
                    const SizedBox(width: 8),
                    _CriteriaChip(emoji: '4.5★', label: '4.5+',
                        selected: _filterMinRating == 4.5,
                        onTap: () => setState(() => _filterMinRating = _filterMinRating == 4.5 ? 0.0 : 4.5)),
                  ]),
                  const SizedBox(height: 10),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Text('🔔', style: TextStyle(fontSize: 10)),
                    const SizedBox(width: 4),
                    Text('Push notification όταν έρθουν προσφορές',
                        style: TextStyle(fontSize: 10,
                            color: _g(0.3))),
                  ]),
                ],
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════
// WAITING SCREEN — Βήμα 2
// ═══════════════════════════════════════
class WaitingScreen extends StatefulWidget {
  final String requestId, userId, description, criteria;
  final String profession;
  const WaitingScreen(
      {required this.requestId,
      required this.userId,
      required this.description,
      required this.criteria,
      this.profession = '',
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
          .collection('requests')
          .doc(widget.requestId)
          .get();
      if (!mounted) return;
      final data = doc.data();
      if (data != null && data['expiresAt'] != null) {
        final expiresAt = (data['expiresAt'] as Timestamp).toDate();
        final now = DateTime.now();
        final diff = expiresAt.difference(now).inSeconds;
        if (diff <= 0) {
          // Έχει ήδη λήξει
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
        _notifyOffersReady();
        _goToOffers();
      } else {
        setState(() => _secondsLeft--);
      }
    });
  }

  void _listenOffers() {
    FirebaseFirestore.instance
        .collection('requests')
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
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: _g(0.5), height: 1.5)),
            const SizedBox(height: 20),
            Row(children: [
              Expanded(child: _PremiumButton(
                label: 'Όχι',
                bgColor: _g(0.06),
                textColor: Colors.white70,
                onTap: () => Navigator.pop(ctx, false),
              )),
              const SizedBox(width: 10),
              Expanded(child: _PremiumButton(
                label: 'Ναι, ακύρωσε',
                bgColor: Colors.red.withValues(alpha: 0.15),
                borderColor: Colors.red.withValues(alpha: 0.4),
                textColor: Colors.red,
                onTap: () => Navigator.pop(ctx, true),
              )),
            ]),
          ]),
        ),
      ),
    );
    if (confirmed == true && mounted) {
      _timer?.cancel();
      await FirebaseFirestore.instance
          .collection('requests')
          .doc(widget.requestId)
          .update({'status': 'cancelled'});
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
  }

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
                ),

                const SizedBox.shrink(),
              ]),
            ),
          ),
        ]),
      ),
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
    with TickerProviderStateMixin {
  late AnimationController _dotsCtrl;
  @override
  void initState() {
    super.initState();
    _dotsCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat();
  }

  @override
  void dispose() {
    _dotsCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: _g(0.03)),
        child: Row(children: [
          Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: kGold.withValues(alpha: 0.08)),
              child: Center(
                  child: Text(widget.emoji,
                      style: const TextStyle(fontSize: 20)))),
          const SizedBox(width: 12),
          Expanded(
              child:
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.name,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            if (widget.typing)
              Row(children: [
                _TypingDots(ctrl: _dotsCtrl),
                const SizedBox(width: 6),
                const Text('Γράφει προσφορά...',
                    style: TextStyle(color: kGreen, fontSize: 10)),
              ])
            else
              Text('⏳ Δεν έχει απαντήσει',
                  style: TextStyle(
                      fontSize: 10,
                      color: _g(0.25))),
          ])),
        ]),
      );
}

class _TypingDots extends StatelessWidget {
  final AnimationController ctrl;
  const _TypingDots({required this.ctrl});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: ctrl,
        builder: (_, __) => Row(
            children: List.generate(3, (i) {
          final phase = (ctrl.value - i * 0.2).clamp(0.0, 1.0);
          final y = (phase < 0.5 ? phase : 1.0 - phase) * 6;
          return Transform.translate(
            offset: Offset(0, -y),
            child: Container(
                width: 4,
                height: 4,
                margin: const EdgeInsets.only(right: 3),
                decoration: const BoxDecoration(
                    shape: BoxShape.circle, color: kGreen)),
          );
        })),
      );
}

// ═══════════════════════════════════════
// TAP SCALE WIDGET — tap-in/tap-out animation
// ═══════════════════════════════════════
class _TapScaleWidget extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  const _TapScaleWidget({required this.child, required this.onTap});
  @override
  State<_TapScaleWidget> createState() => _TapScaleWidgetState();
}

class _TapScaleWidgetState extends State<_TapScaleWidget> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTapDown: (_) => setState(() => _pressed = true),
    onTapUp: (_) {
      setState(() => _pressed = false);
      widget.onTap();
    },
    onTapCancel: () => setState(() => _pressed = false),
    child: AnimatedScale(
      scale: _pressed ? 0.93 : 1.0,
      duration: const Duration(milliseconds: 80),
      curve: Curves.easeOut,
      child: widget.child,
    ),
  );
}

// ═══════════════════════════════════════
// MARQUEE BANNER
// ═══════════════════════════════════════
class _MarqueeBanner extends StatefulWidget {
  final String text;
  const _MarqueeBanner({required this.text});
  @override
  State<_MarqueeBanner> createState() => _MarqueeBannerState();
}

class _MarqueeBannerState extends State<_MarqueeBanner>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(seconds: 12))
      ..repeat();
    _anim = Tween<double>(begin: 0, end: 1).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      color: kGold.withValues(alpha: 0.08),
      child: ClipRect(
        child: AnimatedBuilder(
          animation: _anim,
          builder: (_, __) => FractionalTranslation(
            translation: Offset(-_anim.value, 0),
            child: Row(children: [
              Text(widget.text + widget.text,
                  style: TextStyle(
                      color: kGold.withValues(alpha: 0.85),
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.3)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress;
  const _RingPainter({required this.progress});
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2, cy = size.height / 2, r = size.width / 2 - 6;
    canvas.drawCircle(
        Offset(cx, cy),
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..color = kGold.withValues(alpha: 0.1));
    final fgPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..shader = const SweepGradient(
        startAngle: -3.14159 / 2,
        endAngle: 3.14159 * 1.5,
        colors: [kGoldLight, kGold, kGoldDark],
      ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r));
    canvas.drawArc(Rect.fromCircle(center: Offset(cx, cy), radius: r),
        -3.14159 / 2, 2 * 3.14159 * progress, false, fgPaint);
    final angle = -3.14159 / 2 + 2 * 3.14159 * progress;
    final dotX = cx + r * cos(angle), dotY = cy + r * sin(angle);
    canvas.drawCircle(
        Offset(dotX, dotY),
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
          .update({'status': 'completed', 'selectedPro': offer['name']});

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
                  ),
          ),
        ]),
      ),
    );
  }
}

// ── Offer Card ──
class _OfferCard extends StatelessWidget {
  final Map<String, dynamic> offer;
  final bool isBest;
  final VoidCallback onSelect;
  const _OfferCard(
      {required this.offer,
      required this.isBest,
      required this.onSelect});

  // Safe getters για να μην crash με null values
  String get _name => (offer['name'] ?? offer['professionalName'] ?? 'Επαγγελματίας').toString();
  String get _emoji => (offer['emoji'] ?? '🔧').toString();
  String get _specialty => (offer['specialty'] ?? offer['message'] ?? '').toString();
  double get _price => (offer['price'] is num) ? (offer['price'] as num).toDouble() : 0.0;
  double get _rating => (offer['rating'] is num) ? (offer['rating'] as num).toDouble() : 4.8;
  String get _available => (offer['available'] ?? offer['availableFrom'] ?? 'Σύντομα').toString();
  int get _rank => (offer['rank'] is num) ? (offer['rank'] as num).toInt() : 1;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: isBest
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [kGold.withValues(alpha: 0.1), kGold.withValues(alpha: 0.02)])
              : null,
          color: isBest ? null : _g(0.04),
          border: Border.all(color: isBest
              ? kGold.withValues(alpha: 0.3)
              : _g(0.06)),
        ),
        child: Stack(children: [
          if (isBest)
            Positioned(top: 0, left: 20, right: 20,
                child: Container(height: 1,
                  decoration: const BoxDecoration(gradient: LinearGradient(
                      colors: [Colors.transparent, kGold, Colors.transparent])))),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Rank badge
              Align(
                alignment: Alignment.centerRight,
                child: isBest
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
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(15),
                        color: kGold.withValues(alpha: 0.08)),
                    child: Center(child: Text(_emoji,
                        style: const TextStyle(fontSize: 26)))),
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
                          fontSize: 10)),
                  const SizedBox(height: 3),
                  Row(children: [
                    const Text('⭐',
                        style: TextStyle(fontSize: 10)),
                    const SizedBox(width: 2),
                    Text(
                        '${_rating} · ${(offer['reviews'] ?? 0)} κριτικές',
                        style: TextStyle(
                            color: _g(0.5),
                            fontSize: 10)),
                  ]),
                ])),
              ]),

              const SizedBox(height: 14),

              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('${_price.toInt()}€',
                    style: TextStyle(
                        fontFamily: 'Raleway',
                        fontSize: isBest ? 32 : 26,
                        fontWeight: FontWeight.w900,
                        color: isBest ? kGold : kGold.withValues(alpha: 0.7))),
                const SizedBox(width: 8),
                Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text((_specialty.isNotEmpty ? _specialty : 'Διαθέσιμος $_available'),
                        style: TextStyle(
                            fontSize: 10,
                            color: _g(0.35)))),
              ]),

              const SizedBox(height: 10),

              Wrap(spacing: 6, runSpacing: 6, children: [
                _OfferTag(
                    text: '⚡ ${_available}', green: true),
                _OfferTag(
                    text: '📍 ${(offer['distance'] ?? '')}', green: false),
                if ((offer['guarantee'] == true))
                  const _OfferTag(
                      text: '✅ Εγγύηση', green: true),
              ]),

              const SizedBox(height: 14),

              if ((offer['audioUrl'] as String?)?.isNotEmpty == true) ...[
                _AudioPlayWidget(url: offer['audioUrl'] as String),
                const SizedBox(height: 10),
              ],

              _PremiumButton(
                label: isBest
                    ? '✅ Επέλεξε τον ${_name.split(' ').first}'
                    : 'Επέλεξε τον ${_name.split(' ').first} →',
                gradient: isBest ? const LinearGradient(colors: [kGoldLight, kGold]) : null,
                bgColor: isBest ? null : _g(0.05),
                textColor: isBest ? Colors.black : _g(0.6),
                fontSize: isBest ? 13 : 12,
                onTap: onSelect,
              ),
            ]),
          ),
        ]),
      );
}

// ═══════════════════════════════════════
// AUDIO PLAYBACK WIDGET
// ═══════════════════════════════════════
class _AudioPlayWidget extends StatefulWidget {
  final String url;
  const _AudioPlayWidget({required this.url});
  @override
  State<_AudioPlayWidget> createState() => _AudioPlayWidgetState();
}

class _AudioPlayWidgetState extends State<_AudioPlayWidget> {
  final _player = AudioPlayer();
  bool _playing = false;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
      setState(() => _playing = false);
    } else {
      await _player.play(UrlSource(widget.url));
      setState(() => _playing = true);
      _player.onPlayerComplete.listen((_) {
        if (mounted) setState(() => _playing = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: _toggle,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: kGold.withValues(alpha: 0.08),
        border: Border.all(color: kGold.withValues(alpha: 0.25)),
      ),
      child: Row(children: [
        Container(
          width: 32, height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _playing ? kGold : kGold.withValues(alpha: 0.2),
          ),
          child: Icon(
            _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            color: _playing ? Colors.black : kGold, size: 18,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('🎤 Ηχητικό μήνυμα',
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
          Text(_playing ? 'Αναπαραγωγή...' : 'Πάτα για ακρόαση',
              style: TextStyle(color: _g(0.4), fontSize: 10)),
        ])),
        Icon(_playing ? Icons.volume_up_rounded : Icons.mic_rounded,
            color: kGold.withValues(alpha: 0.6), size: 16),
      ]),
    ),
  );
}

class _OfferTag extends StatelessWidget {
  final String text;
  final bool green;
  const _OfferTag({required this.text, required this.green});
  @override
  Widget build(BuildContext context) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: green
                ? kGreen.withValues(alpha: 0.1)
                : _g(0.05)),
        child: Text(text,
            style: TextStyle(
                fontSize: 10,
                color: green ? kGreen : _g(0.4))),
      );
}

// ═══════════════════════════════════════
// PROJECT REQUEST SCREEN — G Button / Projects Mode
// ═══════════════════════════════════════
const List<String> _teamTypes = [
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
  'Συνεργείο Smart Home & Αυτοματισμού',
];

const List<String> _projectLocations = [
  'Κοντά μου',
  'Αθήνα (κέντρο)',
  'Βόρεια Προάστια',
  'Νότια Προάστια',
  'Δυτικά Προάστια',
  'Ανατολική Αττική',
  'Πειραιάς',
  'Θεσσαλονίκη',
  'Πάτρα',
  'Ηράκλειο',
  'Λάρισα',
  'Βόλος',
  'Ιωάννινα',
  'Χανιά',
  'Ρόδος',
  'Κέρκυρα',
  'Μύκονος',
  'Σαντορίνη',
];

class ProjectRequestScreen extends StatefulWidget {
  final String userId, userName;
  const ProjectRequestScreen({required this.userId, required this.userName, super.key});
  @override
  State<ProjectRequestScreen> createState() => _ProjectRequestScreenState();
}

class _ProjectRequestScreenState extends State<ProjectRequestScreen>
    with TickerProviderStateMixin {
  final _textCtrl = TextEditingController();
  String? _selectedTeamType;
  String? _selectedLocation;
  String _selectedCriteria = 'cheap';
  bool _sending = false;
  late AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1000))
      ..repeat(reverse: true);
    _textCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _textCtrl.dispose();
    super.dispose();
  }

  bool get _canSend =>
      _textCtrl.text.trim().isNotEmpty &&
      _selectedTeamType != null &&
      _selectedLocation != null;

  Future<void> _submit() async {
    if (!_canSend || _sending) return;
    setState(() => _sending = true);
    try {
      await FirebaseFirestore.instance
          .collection('project_requests')
          .add({
        'userId': widget.userId,
        'userName': widget.userName,
        'description': _textCtrl.text.trim(),
        'teamType': _selectedTeamType ?? '',
        'location': _selectedLocation ?? '',
        'criteria': _selectedCriteria,
        'status': 'active',
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ Το project αίτημα στάλθηκε!'),
          backgroundColor: Color(0xFF00D4AA),
        ),
      );
      Navigator.pop(context);
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
          context: context,
          backgroundColor: Colors.transparent,
          isScrollControlled: true,
          builder: (ctx) => _SimpleListPicker(
              title: hint, items: items, selected: value),
        );
        if (result != null) onSelect(result);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: _g(0.04),
          border: Border.all(
              color: value != null
                  ? kGold.withValues(alpha: 0.5)
                  : _g(0.1)),
        ),
        child: Row(children: [
          Expanded(
            child: Text(
              value ?? hint,
              style: TextStyle(
                  color: value != null
                      ? Colors.white
                      : _g(0.35),
                  fontSize: 14),
            ),
          ),
          Icon(Icons.keyboard_arrow_down_rounded,
              color: _g(0.4), size: 20),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(children: [
          // Top bar
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: Row(children: [
              _TapScaleWidget(
                onTap: () => Navigator.pop(context),
                child: Container(
                    width: 38, height: 38,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _g(0.05)),
                    child: const Icon(Icons.arrow_back_ios_new,
                        color: Colors.white, size: 16)),
              ),
              const SizedBox(width: 12),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('G — Projects Mode',
                    style: TextStyle(
                        fontFamily: 'Raleway',
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Colors.white)),
                Text('Ανακαινίσεις · Μεγάλα έργα · Πολλοί επαγγελματίες',
                    style: TextStyle(
                        fontSize: 10,
                        color: _g(0.4))),
              ]),
            ]),
          ),

          const SizedBox(height: 4),

          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(children: [
                // Info banner
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    gradient: LinearGradient(
                      colors: [
                        kGold.withValues(alpha: 0.12),
                        kGold.withValues(alpha: 0.04),
                      ],
                    ),
                    border: Border.all(color: kGold.withValues(alpha: 0.2)),
                  ),
                  child: Row(children: [
                    const Text('🏗️', style: TextStyle(fontSize: 22)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Απευθυνόμαστε σε ολόκληρα συνεργεία με εμπειρία σε μεγάλα έργα.',
                        style: TextStyle(
                            fontSize: 12,
                            color: _g(0.7),
                            height: 1.5),
                      ),
                    ),
                  ]),
                ),

                const SizedBox(height: 16),

                // Main card with all fields
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    color: _g(0.03),
                    border: Border.all(color: kGold.withValues(alpha: 0.15)),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    // Description
                    Text('Περίγραψε το project σου',
                        style: TextStyle(
                            fontSize: 11,
                            color: _g(0.5),
                            letterSpacing: 0.5)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _textCtrl,
                      maxLines: 4,
                      style: TextStyle(color: _gw, fontSize: 14, height: 1.5),
                      decoration: InputDecoration(
                        hintText:
                            'πχ. "Θέλω πλήρη ανακαίνιση μπάνιου, αλλαγή πλακιδίων, νέα υδραυλικά..."',
                        hintStyle: TextStyle(
                            color: _g(0.25), fontSize: 13),
                        border: InputBorder.none,
                        fillColor: Colors.transparent,
                        filled: true,
                      ),
                    ),

                    Divider(color: _g(0.07), height: 24),

                    // Team type
                    Text('Είδος συνεργείου',
                        style: TextStyle(
                            fontSize: 11,
                            color: _g(0.5),
                            letterSpacing: 0.5)),
                    const SizedBox(height: 8),
                    _buildPicker('Επίλεξε συνεργείο...', _selectedTeamType,
                        _teamTypes, (v) => setState(() => _selectedTeamType = v)),

                    const SizedBox(height: 12),

                    // Location
                    Text('Τοποθεσία',
                        style: TextStyle(
                            fontSize: 11,
                            color: _g(0.5),
                            letterSpacing: 0.5)),
                    const SizedBox(height: 8),
                    _buildPicker('Επίλεξε περιοχή...', _selectedLocation,
                        _projectLocations,
                        (v) => setState(() => _selectedLocation = v)),

                    Divider(color: _g(0.07), height: 24),

                    // Criteria
                    Text('Προτεραιότητα',
                        style: TextStyle(
                            fontSize: 11,
                            color: _g(0.5),
                            letterSpacing: 0.5)),
                    const SizedBox(height: 10),
                    Row(children: [
                      for (final c in [
                        {'v': 'cheap', 'e': '💰', 'l': 'Χαμηλή τιμή'},
                        {'v': 'value', 'e': '⭐', 'l': 'Καλύτερο αποτέλεσμα'},
                        {'v': 'fast', 'e': '⚡', 'l': 'Άμεση έναρξη'},
                      ]) ...[
                        Expanded(
                          child: _TapScaleWidget(
                            onTap: () =>
                                setState(() => _selectedCriteria = c['v']!),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: _selectedCriteria == c['v']
                                    ? kGold.withValues(alpha: 0.15)
                                    : Colors.transparent,
                                border: Border.all(
                                    color: _selectedCriteria == c['v']
                                        ? kGold.withValues(alpha: 0.5)
                                        : _g(0.08)),
                              ),
                              child: Column(children: [
                                Text(c['e']!, style: const TextStyle(fontSize: 18)),
                                const SizedBox(height: 4),
                                Text(c['l']!,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        fontSize: 9,
                                        color: _selectedCriteria == c['v']
                                            ? kGold
                                            : _g(0.4))),
                              ]),
                            ),
                          ),
                        ),
                        if (c['v'] != 'fast') const SizedBox(width: 8),
                      ],
                    ]),
                  ]),
                ),

                const SizedBox(height: 24),

                // Submit button
                _TapScaleWidget(
                  onTap: _canSend ? _submit : () {},
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    width: double.infinity,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      gradient: _canSend
                          ? const LinearGradient(
                              colors: [Color(0xFFFFD47A), Color(0xFFFFB340)])
                          : null,
                      color: _canSend
                          ? null
                          : _g(0.06),
                      boxShadow: _canSend
                          ? [
                              BoxShadow(
                                  color: kGold.withValues(alpha: 0.35),
                                  blurRadius: 20,
                                  offset: const Offset(0, 6))
                            ]
                          : null,
                    ),
                    child: Center(
                      child: _sending
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  color: Colors.black, strokeWidth: 2))
                          : Text(
                              _canSend ? '🚀 Στείλε Project Αίτημα' : 'Συμπλήρωσε τα πεδία',
                              style: TextStyle(
                                  color: _canSend ? Colors.black : Colors.white38,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800)),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════
// REQUEST HISTORY SCREEN
// ═══════════════════════════════════════
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
            ]),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .doc(userId)
                  .collection('selectedProfessionals')
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
                  padding:
                      const EdgeInsets.fromLTRB(16, 0, 16, 20),
                  itemCount: docs.length,
                  itemBuilder: (_, i) {
                    final d =
                        docs[i].data() as Map<String, dynamic>;
                    final proName = d['professionalName'] as String? ?? '';
                    final emoji = d['emoji'] as String? ?? '🔧';
                    final price = d['price'];
                    final priceStr = price != null ? '${price}€' : '';
                    final requestDesc = d['requestDescription'] as String? ?? '';
                    final ts = d['selectedAt'] as Timestamp?;
                    final date = ts != null ? ts.toDate() : DateTime.now();
                    final dateStr = '${date.day}/${date.month}/${date.year}';

                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        color: kGold.withValues(alpha: 0.06),
                        border: Border.all(color: kGold.withValues(alpha: 0.2)),
                      ),
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
                          const SizedBox(height: 3),
                          Text(requestDesc,
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11,
                                  color: _g(0.45))),
                          const SizedBox(height: 3),
                          Text('$dateStr${priceStr.isNotEmpty ? ' · $priceStr' : ''}',
                              style: TextStyle(fontSize: 10,
                                  color: kGold.withValues(alpha: 0.7))),
                        ])),
                        const Icon(Icons.check_circle,
                            color: kGold, size: 18),
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

  @override
  void dispose() {
    _tabCtrl.dispose();
    _stt.stop();
    super.dispose();
  }

  Future<void> _toggleVoice() async {
    if (_listening) {
      await _stt.stop();
      setState(() => _listening = false);
      if (_buffer.length >= 3) _saveNote(_buffer);
      return;
    }
    final ok = await _stt.initialize();
    if (!ok) return;
    setState(() => _listening = true);
    _stt.listen(
      onResult: (r) => setState(() => _buffer = r.recognizedWords),
      localeId: 'el_GR',
      listenFor: const Duration(minutes: 5),
      partialResults: true,
      cancelOnError: false,
      listenMode: stt.ListenMode.dictation,
    );
  }

  Future<void> _saveNote(String text) async {
    setState(() => _processing = true);
    try {
      final res = await http.post(
        Uri.parse('$kBackendUrl/ai-memory'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'userId': widget.userId,
          'text': text,
          'idempotency_key':
              '${widget.userId}_${DateTime.now().millisecondsSinceEpoch}',
        }),
      );
      if (res.statusCode == 200 && mounted) {
        final d = jsonDecode(res.body);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '✅ Αποθηκεύτηκε: ${d['summary'] ?? text.substring(0, min(40, text.length))}'),
          backgroundColor: const Color(0xFF1A1A1A),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (_) {}
    setState(() {
      _processing = false;
      _buffer = '';
    });
  }

  Color _catColor(String cat) {
    switch (cat) {
      case 'todo':
        return Colors.green;
      case 'shopping':
        return kGold;
      case 'appointment':
        return Colors.blue;
      default:
        return Colors.purple;
    }
  }

  String _catIcon(String cat) {
    switch (cat) {
      case 'todo':
        return '✅';
      case 'shopping':
        return '🛒';
      case 'appointment':
        return '📅';
      default:
        return '📝';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        child: Row(children: [
          const Expanded(
              child: Text('AI Σημειώσεις',
                  style: TextStyle(
                      fontFamily: 'Raleway',
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.white))),
          GestureDetector(
            onTap: _toggleVoice,
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black,
                border: Border.all(
                    color: _listening ? Colors.red : kGold,
                    width: _listening ? 2.5 : 1.5),
                boxShadow: [
                  BoxShadow(
                      color: (_listening ? Colors.red : kGold)
                          .withValues(alpha: 0.4),
                      blurRadius: _listening ? 20 : 8)
                ],
              ),
              child: _processing
                  ? const Center(
                      child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              color: kGold, strokeWidth: 2)))
                  : Icon(_listening ? Icons.mic : Icons.mic_none,
                      color: _listening ? Colors.red : kGold, size: 20),
            ),
          ),
        ]),
      ),
      if (_listening)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: Colors.red.withValues(alpha: 0.08)),
            child: Text(_buffer.isEmpty ? 'Ακούω...' : _buffer,
                style: TextStyle(
                    color: _g(0.7), fontSize: 13)),
          ),
        ),
      const SizedBox(height: 12),
      Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
            color: _g(0.04),
            borderRadius: BorderRadius.circular(12)),
        child: TabBar(
          controller: _tabCtrl,
          isScrollable: true,
          indicatorSize: TabBarIndicatorSize.tab,
          indicator: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: kGold.withValues(alpha: 0.12),
              border: Border.all(color: kGold.withValues(alpha: 0.4))),
          labelColor: kGold,
          unselectedLabelColor: Colors.white38,
          labelStyle: const TextStyle(
              fontSize: 11,
              fontFamily: 'Raleway',
              fontWeight: FontWeight.w600),
          padding: const EdgeInsets.all(4),
          dividerColor: Colors.transparent,
          tabs: _tabs.map((t) => Tab(text: t['label'])).toList(),
        ),
      ),
      const SizedBox(height: 12),
      Expanded(
        child: TabBarView(
          controller: _tabCtrl,
          children: _tabs.map((tab) {
            final category = tab['category']!;
            final stream = category == 'all'
                ? FirebaseFirestore.instance
                    .collection('ai_memory')
                    .where('userId', isEqualTo: widget.userId)
                    .orderBy('createdAt', descending: true)
                    .limit(50)
                    .snapshots()
                : FirebaseFirestore.instance
                    .collection('ai_memory')
                    .where('userId', isEqualTo: widget.userId)
                    .where('category', isEqualTo: category)
                    .orderBy('createdAt', descending: true)
                    .limit(50)
                    .snapshots();
            return StreamBuilder<QuerySnapshot>(
              stream: stream,
              builder: (context, snap) {
                if (!snap.hasData)
                  return const Center(
                      child:
                          CircularProgressIndicator(color: kGold));
                final docs = snap.data!.docs;
                if (docs.isEmpty) {
                  return Center(
                      child:
                          Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(_catIcon(category),
                        style: const TextStyle(fontSize: 44)),
                    const SizedBox(height: 12),
                    Text('Δεν υπάρχουν εγγραφές ακόμα',
                        style: TextStyle(
                            color: _g(0.3),
                            fontSize: 14)),
                    const SizedBox(height: 6),
                    Text('Πάτα το mic και μίλα!',
                        style: TextStyle(
                            color: _g(0.2),
                            fontSize: 12)),
                  ]));
                }
                return ListView.builder(
                  padding:
                      const EdgeInsets.fromLTRB(16, 0, 16, 20),
                  itemCount: docs.length,
                  itemBuilder: (_, i) {
                    final d =
                        docs[i].data() as Map<String, dynamic>;
                    final cat = d['category'] ?? 'note';
                    final isDone = d['done'] == true;
                    final ts = d['createdAt'] as Timestamp?;
                    final date =
                        ts?.toDate() ?? DateTime.now();
                    final dateStr =
                        '${date.day}/${date.month} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        color: isDone
                            ? _g(0.03)
                            : _g(0.06),
                        border: Border.all(
                            color: isDone
                                ? _g(0.05)
                                : _catColor(cat).withValues(alpha: 0.25)),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                          GestureDetector(
                            onTap: cat == 'todo'
                                ? () async {
                                    await docs[i]
                                        .reference
                                        .update({'done': !isDone});
                                  }
                                : null,
                            child: Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _catColor(cat).withValues(alpha: isDone ? 0.05 : 0.1),
                                border: Border.all(
                                    color: _catColor(cat).withValues(alpha: isDone ? 0.1 : 0.3)),
                              ),
                              child: Center(
                                  child: Text(
                                      isDone
                                          ? '✓'
                                          : _catIcon(cat),
                                      style: TextStyle(
                                          fontSize:
                                              isDone ? 16 : 18,
                                          color: isDone
                                              ? Colors.white30
                                              : null))),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                              child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                            Text(
                                d['summary'] ??
                                    d['original_text'] ??
                                    '',
                                style: TextStyle(
                                    fontSize: 14,
                                    color: isDone
                                        ? Colors.white30
                                        : Colors.white,
                                    decoration: isDone
                                        ? TextDecoration.lineThrough
                                        : null,
                                    height: 1.4)),
                            const SizedBox(height: 4),
                            Row(children: [
                              Container(
                                padding:
                                    const EdgeInsets.symmetric(
                                        horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                    borderRadius:
                                        BorderRadius.circular(6),
                                    color: _catColor(cat)
                                        .withValues(alpha: 0.1)),
                                child: Text(cat,
                                    style: TextStyle(
                                        fontSize: 9,
                                        letterSpacing: 1,
                                        color: _catColor(cat)
                                            .withValues(alpha: 0.7))),
                              ),
                              const SizedBox(width: 8),
                              Text(dateStr,
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.white
                                          .withValues(alpha: 0.25))),
                            ]),
                          ])),
                          GestureDetector(
                            onTap: () =>
                                docs[i].reference.delete(),
                            child: Padding(
                                padding: const EdgeInsets.only(
                                    left: 8),
                                child: Icon(Icons.close,
                                    color: Colors.white
                                        .withValues(alpha: 0.2),
                                    size: 16)),
                          ),
                        ]),
                      ),
                    );
                  },
                );
              },
            );
          }).toList(),
        ),
      ),
    ]);
  }
}

// ═══════════════════════════════════════
// PROFILE SCREEN
// ═══════════════════════════════════════
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  String? _name, _email, _city;
  bool _loading = true, _biometricOn = true;
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
                  border: Border.all(color: kGold.withValues(alpha: 0.3))),
              child: Center(
                  child: Text(emoji, style: const TextStyle(fontSize: 18)))),
          const SizedBox(width: 14),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 14,
                    color: Colors.white,
                    fontWeight: FontWeight.w500)),
            Text(subtitle,
                style: TextStyle(
                    fontSize: 11, color: _g(0.35))),
          ])),
          Switch(
              value: value,
              onChanged: onChanged,
              activeColor: kGold,
              activeTrackColor: kGold.withValues(alpha: 0.25),
              inactiveThumbColor: Colors.white30,
              inactiveTrackColor: Colors.white12),
        ]),
      );

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
    _newPassCtrl.clear();
    showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF111111),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(color: kGold.withValues(alpha: 0.2))),
              title: const Text('Αλλαγή κωδικού',
                  style: TextStyle(
                      color: Colors.white, fontFamily: 'Raleway')),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                _GoldTextField(
                    controller: _oldPassCtrl,
                    label: 'Τρέχων κωδικός',
                    obscure: true),
                const SizedBox(height: 12),
                _GoldTextField(
                    controller: _newPassCtrl,
                    label: 'Νέος κωδικός',
                    obscure: true),
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
                    try {
                      final cred = EmailAuthProvider.credential(
                          email: _email!,
                          password: _oldPassCtrl.text.trim());
                      await user
                          .reauthenticateWithCredential(cred);
                      await user.updatePassword(
                          _newPassCtrl.text.trim());
                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content:
                                    Text('Ο κωδικός άλλαξε! ✅')));
                      }
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
                                      _g(0.35))),
                        ]),
                      ],
                    ]),
                  ),

                  const SizedBox(height: 24),
                  _sectionHeader('ΛΟΓΑΡΙΑΣΜΟΣ'),
                  _ProfileRow(
                      icon: Icons.person_outline,
                      emoji: '👤',
                      label: 'Όνομα & Πόλη',
                      value: _name ?? '',
                      onTap: _showEditDialog),
                  _ProfileRow(
                      icon: Icons.alternate_email,
                      emoji: '✉️',
                      label: 'Email',
                      value: _email ?? ''),
                  _ProfileRow(
                      icon: Icons.lock_outline,
                      emoji: '🔒',
                      label: 'Αλλαγή κωδικού',
                      value: '••••••••',
                      onTap: _showChangePasswordDialog),

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
                child: Text(requestData['description'] ?? '',
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12,
                        color: _g(0.6))),
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
      String message, String available, String proId) async {
    try {
      final proDoc = await FirebaseFirestore.instance
          .collection('users').doc(proId).get();
      final proName = proDoc.data()?['name'] ?? 'Επαγγελματίας';

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
                            _showOfferDialogFromNotif(
                                context, requestId, reqDoc.data()!, userId);
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

const List<String> _greekAreas = [
  'Αθήνα Κέντρο', 'Κολωνάκι', 'Γλυφάδα', 'Βούλα', 'Βουλιαγμένη',
  'Καλλιθέα', 'Νέα Σμύρνη', 'Παλαιό Φάληρο', 'Άλιμος', 'Χαλάνδρι',
  'Μαρούσι', 'Κηφισιά', 'Νέα Ιωνία', 'Αγία Παρασκευή', 'Ζωγράφου',
  'Βύρωνας', 'Ηλιούπολη', 'Περιστέρι', 'Αιγάλεω', 'Πειραιάς',
  'Θεσσαλονίκη Κέντρο', 'Καλαμαριά', 'Πυλαία', 'Θέρμη',
  'Πάτρα', 'Ηράκλειο Κρήτης', 'Χανιά', 'Ρέθυμνο', 'Λάρισα', 'Βόλος',
  'Ιωάννινα', 'Κέρκυρα', 'Ρόδος', 'Μυτιλήνη',
];

class _AreaPicker extends StatefulWidget {
  const _AreaPicker();
  @override
  State<_AreaPicker> createState() => _AreaPickerState();
}

class _AreaPickerState extends State<_AreaPicker> {
  String? _selected;
  @override
  Widget build(BuildContext context) => _PickerContainer(
        title: 'Επιλέξτε περιοχή',
        onOk: _selected != null
            ? () => Navigator.pop(context, _selected)
            : null,
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          itemCount: _greekAreas.length,
          itemBuilder: (_, i) {
            final area = _greekAreas[i];
            final isSel = _selected == area;
            return GestureDetector(
              onTap: () => setState(() => _selected = area),
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
          Text(title,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontFamily: 'Raleway',
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Expanded(child: child),
          Padding(
            padding: EdgeInsets.fromLTRB(
                16,
                8,
                16,
                MediaQuery.of(context).viewInsets.bottom + 24),
            child: GestureDetector(
              onTap: onOk,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    color: onOk != null
                        ? kGold
                        : _g(0.1)),
                child: Center(
                    child: Text('OK',
                        style: TextStyle(
                            color: onOk != null
                                ? Colors.black
                                : Colors.white38,
                            fontWeight: FontWeight.bold,
                            fontSize: 15))),
              ),
            ),
          ),
        ]),
      );
}

// ═══════════════════════════════════════
// THEME SELECTOR
// ═══════════════════════════════════════
class _ThemeSelector extends StatefulWidget {
  @override
  State<_ThemeSelector> createState() => _ThemeSelectorState();
}

class _ThemeSelectorState extends State<_ThemeSelector> {
  static const _themes = [
    {'id': 'obsidian', 'name': 'Obsidian Gold', 'emoji': '🌑', 'bg': 0xFF0A0800, 'accent': 0xFFD4A843, 'light': false},
    {'id': 'navy', 'name': 'Midnight Navy', 'emoji': '🌊', 'bg': 0xFF060D1A, 'accent': 0xFFF0C040, 'light': false},
    {'id': 'rose', 'name': 'Charcoal Rose', 'emoji': '🌹', 'bg': 0xFF140C0C, 'accent': 0xFFC4917A, 'light': false},
    {'id': 'forest', 'name': 'Forest Carbon', 'emoji': '🌲', 'bg': 0xFF060E08, 'accent': 0xFF3DBA7E, 'light': false},
    {'id': 'arctic', 'name': 'Arctic Slate', 'emoji': '🧊', 'bg': 0xFF080C14, 'accent': 0xFF64B5F6, 'light': false},
    {'id': 'white', 'name': 'Pearl White', 'emoji': '🤍', 'bg': 0xFFF5F5F7, 'accent': 0xFFFFB340, 'light': true},
    {'id': 'grey', 'name': 'Silver Grey', 'emoji': '🩶', 'bg': 0xFFE5E5EA, 'accent': 0xFFFFB340, 'light': true},
  ];
  String _selected = 'obsidian';

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      setState(() => _selected = p.getString('theme') ?? 'obsidian');
    });
  }

  Future<void> _saveTheme(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme', id);
    setState(() => _selected = id);
    appThemeNotifier.value = AppTheme.get(id);
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 90,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _themes.length,
          separatorBuilder: (_, __) => const SizedBox(width: 10),
          itemBuilder: (_, i) {
            final t = _themes[i];
            final isSelected = _selected == t['id'];
            final accent = Color(t['accent'] as int);
            final isChipLight = t['light'] as bool? ?? false;
            final chipTextColor = isChipLight ? const Color(0xFF0D0D1E) : Colors.white;
            return GestureDetector(
              onTap: () => _saveTheme(t['id'] as String),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 80,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: Color(t['bg'] as int),
                  border: Border.all(
                      color: isSelected ? accent : chipTextColor.withValues(alpha: 0.15),
                      width: isSelected ? 2 : 1),
                  boxShadow: isSelected
                      ? [BoxShadow(color: accent.withValues(alpha: 0.3), blurRadius: 12)]
                      : [],
                ),
                child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                  Text(t['emoji'] as String,
                      style: const TextStyle(fontSize: 22)),
                  const SizedBox(height: 6),
                  Text(t['name'] as String,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      style: TextStyle(
                          fontSize: 8,
                          color: isSelected ? accent : chipTextColor.withValues(alpha: 0.5),
                          fontWeight: isSelected
                              ? FontWeight.w700
                              : FontWeight.w400,
                          height: 1.3)),
                  if (isSelected) ...[
                    const SizedBox(height: 4),
                    Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: accent,
                            boxShadow: [
                              BoxShadow(
                                  color: accent.withValues(alpha: 0.8),
                                  blurRadius: 4)
                            ])),
                  ],
                ]),
              ),
            );
          },
        ),
      );
}

// ═══════════════════════════════════════
// PREMIUM BUTTON — tap in/out effect
// ═══════════════════════════════════════
class _PremiumButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final LinearGradient? gradient;
  final Color? bgColor;
  final Color? borderColor;
  final Color textColor;
  final double fontSize;
  const _PremiumButton({
    required this.label, required this.onTap,
    this.gradient, this.bgColor, this.borderColor,
    this.textColor = Colors.black, this.fontSize = 14,
  });
  @override
  State<_PremiumButton> createState() => _PremiumButtonState();
}
class _PremiumButtonState extends State<_PremiumButton> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTapDown: (_) => setState(() => _pressed = true),
    onTapUp: (_) { setState(() => _pressed = false); widget.onTap(); },
    onTapCancel: () => setState(() => _pressed = false),
    child: AnimatedScale(
      scale: _pressed ? 0.95 : 1.0,
      duration: const Duration(milliseconds: 100),
      curve: Curves.easeOut,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        padding: const EdgeInsets.symmetric(vertical: 13),
        width: double.infinity,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: widget.gradient,
          color: widget.gradient == null
              ? (_pressed
                  ? (widget.bgColor ?? kGold.withValues(alpha: 0.25))
                  : (widget.bgColor ?? kGold.withValues(alpha: 0.15)))
              : null,
          border: widget.borderColor != null ? Border.all(color: widget.borderColor!) : null,
          boxShadow: _pressed ? [] : (widget.gradient != null ? [
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
    ),
  );
}

// ═══════════════════════════════════════
// SHARED WIDGETS
// ═══════════════════════════════════════


class _TopBar extends StatelessWidget {
  final String label;
  const _TopBar({required this.label});
  @override
  Widget build(BuildContext context) => Padding(
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
          const SizedBox(width: 14),
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
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: kGold.withValues(alpha: 0.1)),
            child: Text(label,
                style: const TextStyle(
                    color: kGold,
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5)),
          ),
        ]),
      );
}

class _SectionLabel extends StatelessWidget {
  final String icon, label;
  const _SectionLabel({required this.icon, required this.label});
  @override
  Widget build(BuildContext context) => Row(children: [
        Text(icon, style: const TextStyle(fontSize: 14)),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: _g(0.45),
                letterSpacing: 0.5)),
      ]);
}

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
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: selected
                          ? kGold
                          : _g(0.4))),
            ]),
          ),
        ),
      );
}

class _HNavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _HNavItem(
      {required this.icon,
      required this.label,
      required this.active,
      required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color:
                  active ? kGold.withValues(alpha: 0.12) : Colors.transparent),
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
            ? (Matrix4.identity()..scale(0.98))
            : Matrix4.identity(),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: _pressed
              ? (widget.bgColor ?? _g(0.09))
              : (widget.bgColor ?? _g(0.05)),
          border: Border.all(
              color: _pressed
                  ? (widget.borderColor ?? kGold.withValues(alpha: 0.25))
                  : (widget.borderColor ??
                      _g(0.08))),
        ),
        child: Row(children: [
          Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: iconColor.withValues(alpha: 0.15)),
              child: Center(
                  child: widget.emoji != null
                      ? Text(widget.emoji!,
                          style: const TextStyle(fontSize: 18))
                      : Icon(widget.icon,
                          color: iconColor, size: 20))),
          const SizedBox(width: 14),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
            Text(widget.label,
                style: TextStyle(
                    fontSize: 14,
                    color: textColor,
                    fontWeight: FontWeight.w500)),
            if (widget.value.isNotEmpty)
              Text(widget.value,
                  style: TextStyle(
                      fontSize: 11,
                      color: _g(0.35))),
          ])),
          if (widget.onTap != null)
            Icon(Icons.chevron_right,
                color: _g(0.25), size: 20),
        ]),
      ),
    );
  }
}

class _GoldTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool obscure;
  const _GoldTextField(
      {required this.controller,
      required this.label,
      this.obscure = false});
  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        obscureText: obscure,
        style: TextStyle(color: _gw, fontSize: 14),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(
              color: _g(0.4), fontSize: 12),
          filled: true,
          fillColor: _g(0.05),
          contentPadding: const EdgeInsets.symmetric(
              horizontal: 14, vertical: 12),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: kGold.withValues(alpha: 0.2))),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: kGold.withValues(alpha: 0.2))),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: kGold)),
        ),
      );
}

// ══════════════════════════════════════════════════════
// NEARBY PROS SECTION
// ══════════════════════════════════════════════════════
class _NearbyProsSection extends StatefulWidget {
  const _NearbyProsSection();
  @override
  State<_NearbyProsSection> createState() => _NearbyProsSectionState();
}

class _NearbyProsSectionState extends State<_NearbyProsSection> {
  final PageController _pageCtrl = PageController(viewportFraction: 0.52);
  int _page = 0;
  Timer? _autoScrollTimer;

  @override
  void initState() {
    super.initState();
    _startAutoScroll();
  }

  void _startAutoScroll() {
    _autoScrollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted || !_pageCtrl.hasClients) return;
      final next = (_page + 1);
      _pageCtrl.animateToPage(
        next,
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('professionals')
          .limit(10)
          .snapshots(),
      builder: (context, snap) {
        final docs = snap.hasData ? snap.data!.docs : <QueryDocumentSnapshot>[];
        if (!snap.hasData) return const SizedBox(height: 220);
        if (docs.isEmpty) return const SizedBox(height: 220);
        return _buildPageView(docs);
      },
    );
  }

  Widget _buildPageView(List<QueryDocumentSnapshot> docs) {
    return SizedBox(
      height: 185,
      child: PageView.builder(
        controller: _pageCtrl,
        itemCount: 9999,
        onPageChanged: (i) => setState(() => _page = i),
        itemBuilder: (_, i) {
          final doc = docs[i % docs.length];
          final d = doc.data() as Map<String, dynamic>;
          final proId = doc.data() is Map ? (d['userId'] as String? ?? doc.id) : doc.id;
          final name = d['name'] as String? ?? 'Επαγγελματίας';
          final specialty = d['specialty'] as String? ?? '';
          final rating = (d['rating'] as num?)?.toDouble() ?? 0.0;
          final jobs = (d['completedJobs'] as num?)?.toInt() ?? 0;
          // Try multiple photo field names
          final photoUrl = d['photoUrl'] as String?
              ?? d['profilePhoto'] as String?
              ?? d['avatarUrl'] as String?
              ?? d['imageUrl'] as String?;
          final userId = d['userId'] as String?;
          final isNew = jobs < 5;
          final initials = name.isNotEmpty ? name[0].toUpperCase() : 'P';
          final isActive = i == _page;

          return GestureDetector(
            onTap: () => Navigator.push(context, PageRouteBuilder(
              pageBuilder: (_, __, ___) => _ProPublicProfileScreen(proId: proId, proData: d),
              transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
            )),
            child: AnimatedScale(
              scale: isActive ? 1.0 : 0.93,
              duration: const Duration(milliseconds: 300),
              child: Container(
                margin: const EdgeInsets.fromLTRB(6, 4, 6, 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  color: const Color(0xFF0D0A04),
                  border: Border.all(color: isActive ? kGold.withValues(alpha: 0.4) : kGold.withValues(alpha: 0.12)),
                  boxShadow: [BoxShadow(color: kGold.withValues(alpha: isActive ? 0.1 : 0.03), blurRadius: 16)],
                ),
                child: Column(children: [
                  // Φωτογραφία
                  Expanded(
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
                      child: Stack(fit: StackFit.expand, children: [
                        // Αν υπάρχει photoUrl στο professionals, δείξτο
                        // Αλλιώς κοίτα από users collection
                        if (photoUrl != null)
                          Image.network(photoUrl, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => _proInitialsBox(initials))
                        else if (userId != null)
                          FutureBuilder<DocumentSnapshot>(
                            future: FirebaseFirestore.instance.collection('users').doc(userId).get(),
                            builder: (_, snap) {
                              if (snap.hasData && snap.data!.exists) {
                                final uData = snap.data!.data() as Map<String, dynamic>;
                                final uPhoto = uData['photoUrl'] as String?
                                    ?? uData['profilePhoto'] as String?
                                    ?? uData['avatarUrl'] as String?;
                                if (uPhoto != null) {
                                  return Image.network(uPhoto, fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => _proInitialsBox(initials));
                                }
                              }
                              return _proInitialsBox(initials);
                            },
                          )
                        else
                          _proInitialsBox(initials),
                        // Νέος badge
                        if (isNew)
                          Positioned(top: 8, right: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(6),
                                color: Colors.black.withValues(alpha: 0.65),
                                border: Border.all(color: kGold.withValues(alpha: 0.4)),
                              ),
                              child: const Text('Νέος', style: TextStyle(color: kGold, fontSize: 8, fontWeight: FontWeight.w700)),
                            ),
                          ),
                        // Gradient overlay
                        Positioned.fill(child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter, end: Alignment.bottomCenter,
                              colors: [Colors.transparent, Colors.black.withValues(alpha: 0.4)],
                              stops: const [0.55, 1.0],
                            ),
                          ),
                        )),
                      ]),
                    ),
                  ),
                  // Info
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 7, 10, 8),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 1),
                      Text(specialty, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: _g(0.4), fontSize: 10)),
                      const SizedBox(height: 5),
                      Row(children: [
                        Text('⭐ ${rating > 0 ? rating.toStringAsFixed(1) : "Νέος"}',
                            style: const TextStyle(color: kGold, fontSize: 10, fontWeight: FontWeight.w600)),
                        const Spacer(),
                        Text('~30λ', style: TextStyle(color: _g(0.3), fontSize: 9)),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _proInitialsBox(String initials) => Container(
    color: kGold.withValues(alpha: 0.08),
    child: Center(child: Text(initials,
        style: const TextStyle(color: kGold, fontSize: 36, fontWeight: FontWeight.bold))),
  );
}

// ══════════════════════════════════════════════════════
// PRO PUBLIC PROFILE SCREEN
// ══════════════════════════════════════════════════════
class _ProPublicProfileScreen extends StatelessWidget {
  final String proId;
  final Map<String, dynamic> proData;
  const _ProPublicProfileScreen({required this.proId, required this.proData});

  @override
  Widget build(BuildContext context) {
    final name = proData['name'] as String? ?? 'Επαγγελματίας';
    final specialty = proData['specialty'] as String? ?? '';
    final rating = (proData['rating'] as num?)?.toDouble() ?? 0.0;
    final jobs = (proData['completedJobs'] as num?)?.toInt() ?? 0;
    final photoUrl = proData['photoUrl'] as String?;
    final bio = proData['bio'] as String? ?? '';
    final initials = name.isNotEmpty ? name[0].toUpperCase() : 'P';

    return Scaffold(
      backgroundColor: const Color(0xFF080500),
      body: SafeArea(
        child: Column(children: [
          // Top bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Row(children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(width: 38, height: 38,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: _g(0.06),
                        border: Border.all(color: _g(0.1))),
                    child: Icon(Icons.arrow_back_ios_new, color: _gw, size: 16)),
              ),
              const Spacer(),
              ShaderMask(
                shaderCallback: (b) => const LinearGradient(colors: [kGoldLight, kGold]).createShader(b),
                child: const Text('GOREALAI', style: TextStyle(fontFamily: 'Raleway', fontSize: 12, letterSpacing: 4, color: Colors.white)),
              ),
              const Spacer(),
              const SizedBox(width: 38),
            ]),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(children: [
                // Photo
                Container(
                  width: 110, height: 110,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: kGold, width: 2),
                    boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.3), blurRadius: 20)],
                  ),
                  child: ClipOval(
                    child: photoUrl != null
                        ? Image.network(photoUrl, fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(color: kGold.withValues(alpha: 0.1),
                                child: Center(child: Text(initials, style: const TextStyle(color: kGold, fontSize: 40, fontWeight: FontWeight.bold)))))
                        : Container(color: kGold.withValues(alpha: 0.1),
                            child: Center(child: Text(initials, style: const TextStyle(color: kGold, fontSize: 40, fontWeight: FontWeight.bold)))),
                  ),
                ),
                const SizedBox(height: 16),
                Text(name, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800, fontFamily: 'Raleway')),
                const SizedBox(height: 4),
                Text(specialty, style: TextStyle(color: _g(0.5), fontSize: 14)),
                const SizedBox(height: 16),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  _proStatBox('⭐', rating > 0 ? rating.toStringAsFixed(1) : '-', 'Βαθμ.'),
                  const SizedBox(width: 16),
                  _proStatBox('🏆', '$jobs', 'Δουλειές'),
                  const SizedBox(width: 16),
                  _proStatBox('⚡', '~30λ', 'Απάντηση'),
                ]),
                if (bio.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), color: _g(0.04), border: Border.all(color: _g(0.08))),
                    child: Text(bio, style: TextStyle(color: _g(0.65), fontSize: 13, height: 1.5)),
                  ),
                ],
                const SizedBox(height: 24),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      gradient: const LinearGradient(colors: [kGoldLight, kGold]),
                    ),
                    child: const Center(child: Text('Στείλε αίτημα',
                        style: TextStyle(color: Colors.black, fontSize: 15, fontWeight: FontWeight.w800))),
                  ),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _proStatBox(String emoji, String value, String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
    decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: _g(0.04), border: Border.all(color: _g(0.08))),
    child: Column(children: [
      Text(emoji, style: const TextStyle(fontSize: 20)),
      const SizedBox(height: 4),
      Text(value, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800)),
      Text(label, style: TextStyle(color: _g(0.4), fontSize: 10)),
    ]),
  );
}

// ══════════════════════════════════════════════════════
// EVENT ORGANIZER BOTTOM SHEET
// ══════════════════════════════════════════════════════
class _EventOrganizerSheet extends StatelessWidget {
  final String userId, userName;
  const _EventOrganizerSheet({required this.userId, required this.userName});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0804),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border.all(color: kGold.withValues(alpha: 0.2)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: Container(width: 36, height: 4,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(2), color: _g(0.2)))),
        const SizedBox(height: 20),
        Row(children: [
          GestureDetector(onTap: () => Navigator.pop(context),
              child: Icon(Icons.close, color: _g(0.4), size: 22)),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), color: kGold.withValues(alpha: 0.12)),
            child: const Text('ΝΕΟ ΑΙΤΗΜΑ', style: TextStyle(color: kGold, fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1)),
          ),
        ]),
        const SizedBox(height: 20),
        const Text('Τι οργανώνεις;',
            style: TextStyle(fontFamily: 'Raleway', fontSize: 26, color: Colors.white, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text('Επέλεξε κατηγορία και το AI σου βρίσκει\nτους καλύτερους επαγγελματίες.',
            style: TextStyle(color: _g(0.45), fontSize: 13, height: 1.4)),
        const SizedBox(height: 24),
        ...[
          {'emoji': '💍', 'title': 'Γάμος', 'subs': 'Φωτογράφος · DJ · Catering · Αίθουσα · Ανθοστολιστής'},
          {'emoji': '🎂', 'title': 'Βάφτιση', 'subs': 'Φωτογράφος · Catering · Στολισμός · Μπομπονιέρες'},
          {'emoji': '🎉', 'title': 'Πάρτυ', 'subs': 'DJ · Catering · Στολισμός · Φωτογράφος'},
        ].map((item) => GestureDetector(
          onTap: () {
            Navigator.pop(context);
            showModalBottomSheet(
              context: context,
              backgroundColor: Colors.transparent,
              isScrollControlled: true,
              builder: (_) => _EventFormSheet(
                eventType: item['title']!,
                emoji: item['emoji']!,
                userId: userId,
                userName: userName,
              ),
            );
          },
          child: Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: _g(0.04),
              border: Border.all(color: _g(0.08)),
            ),
            child: Row(children: [
              Text(item['emoji']!, style: const TextStyle(fontSize: 26)),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(item['title']!,
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(item['subs']!, style: TextStyle(color: _g(0.35), fontSize: 11)),
              ])),
              Icon(Icons.arrow_forward_ios, color: _g(0.25), size: 14),
            ]),
          ),
        )),
      ]),
    );
  }
}

// ══════════════════════════════════════════════════════
// EVENT FORM SHEET (Γάμος / Βάφτιση / Πάρτυ)
// ══════════════════════════════════════════════════════
class _EventFormSheet extends StatefulWidget {
  final String eventType, emoji, userId, userName;
  const _EventFormSheet({required this.eventType, required this.emoji, required this.userId, required this.userName});
  @override
  State<_EventFormSheet> createState() => _EventFormSheetState();
}

class _EventFormSheetState extends State<_EventFormSheet> {
  DateTime? _date;
  String? _location;
  double _people = 50;
  double _budget = 3000;
  final _detailsCtrl = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _detailsCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _sending = true);
    try {
      await FirebaseFirestore.instance.collection('event_requests').add({
        'userId': widget.userId,
        'userName': widget.userName,
        'eventType': widget.eventType,
        'date': _date != null ? _date!.toIso8601String() : null,
        'location': _location ?? '',
        'people': _people.round(),
        'budget': _budget.round(),
        'details': _detailsCtrl.text.trim(),
        'status': 'active',
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('✅ Το αίτημά σου στάλθηκε!'),
          backgroundColor: Color(0xFF00D4AA)));
    } catch (e) {
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Σφάλμα: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        decoration: BoxDecoration(
          color: const Color(0xFF0A0804),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          border: Border.all(color: kGold.withValues(alpha: 0.2)),
        ),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Center(child: Container(width: 36, height: 4,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(2), color: _g(0.2)))),
            const SizedBox(height: 16),
            Row(children: [
              GestureDetector(onTap: () => Navigator.pop(context),
                  child: Icon(Icons.arrow_back_ios, color: _g(0.5), size: 18)),
              const SizedBox(width: 8),
              Text('${widget.emoji} ${widget.eventType}',
                  style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 20),

            // Ημερομηνία
            Row(children: [
              Text('📅 ', style: const TextStyle(fontSize: 14)),
              Text('Ημερομηνία', style: TextStyle(color: _g(0.6), fontSize: 13, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: DateTime.now().add(const Duration(days: 30)),
                  firstDate: DateTime.now(),
                  lastDate: DateTime.now().add(const Duration(days: 730)),
                  builder: (ctx, child) => Theme(
                    data: ThemeData.dark().copyWith(
                      colorScheme: const ColorScheme.dark(primary: kGold, surface: Color(0xFF1A1400)),
                    ),
                    child: child!,
                  ),
                );
                if (picked != null) setState(() => _date = picked);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: _g(0.04),
                  border: Border.all(color: _date != null ? kGold.withValues(alpha: 0.4) : _g(0.1)),
                ),
                child: Row(children: [
                  Icon(Icons.calendar_today_outlined, color: _g(0.4), size: 16),
                  const SizedBox(width: 10),
                  Text(
                    _date != null
                        ? '${_date!.day}/${_date!.month}/${_date!.year}'
                        : 'Επίλεξε ημερομηνία',
                    style: TextStyle(color: _date != null ? _gw : _g(0.3), fontSize: 14),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 16),

            // Περιοχή
            Row(children: [
              Text('📍 ', style: const TextStyle(fontSize: 14)),
              Text('Περιοχή', style: TextStyle(color: _g(0.6), fontSize: 13, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () async {
                final areas = ['Αθήνα', 'Θεσσαλονίκη', 'Πάτρα', 'Ηράκλειο', 'Λάρισα',
                    'Βόλος', 'Ιωάννινα', 'Χανιά', 'Ρόδος', 'Κέρκυρα', 'Καβάλα', 'Σέρρες'];
                final result = await showModalBottomSheet<String>(
                  context: context,
                  backgroundColor: Colors.transparent,
                  builder: (_) => _SimpleListPicker(title: 'Επίλεξε περιοχή', items: areas, selected: _location),
                );
                if (result != null) setState(() => _location = result);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: _g(0.04),
                  border: Border.all(color: _location != null ? kGold.withValues(alpha: 0.4) : _g(0.1)),
                ),
                child: Row(children: [
                  Icon(Icons.location_on_outlined, color: _g(0.4), size: 16),
                  const SizedBox(width: 10),
                  Expanded(child: Text(_location ?? 'Επίλεξε περιοχή...',
                      style: TextStyle(color: _location != null ? _gw : _g(0.3), fontSize: 14))),
                  Icon(Icons.keyboard_arrow_down, color: _g(0.3), size: 18),
                ]),
              ),
            ),
            const SizedBox(height: 16),

            // Αριθμός ατόμων
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Row(children: [
                Text('👥 ', style: const TextStyle(fontSize: 14)),
                Text('Αριθμός ατόμων:', style: TextStyle(color: _g(0.6), fontSize: 13, fontWeight: FontWeight.w600)),
              ]),
              Text('${_people.round()}', style: const TextStyle(color: kGold, fontSize: 14, fontWeight: FontWeight.w700)),
            ]),
            SliderTheme(
              data: SliderThemeData(
                activeTrackColor: kGold,
                inactiveTrackColor: _g(0.1),
                thumbColor: kGold,
                overlayColor: kGold.withValues(alpha: 0.1),
              ),
              child: Slider(
                value: _people,
                min: 10, max: 500,
                onChanged: (v) => setState(() => _people = v),
              ),
            ),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('10', style: TextStyle(color: _g(0.3), fontSize: 10)),
              Text('500+', style: TextStyle(color: _g(0.3), fontSize: 10)),
            ]),
            const SizedBox(height: 16),

            // Budget
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Row(children: [
                Text('💰 ', style: const TextStyle(fontSize: 14)),
                Text('Budget:', style: TextStyle(color: _g(0.6), fontSize: 13, fontWeight: FontWeight.w600)),
              ]),
              Text('${_budget.round()}€', style: const TextStyle(color: kGold, fontSize: 14, fontWeight: FontWeight.w700)),
            ]),
            SliderTheme(
              data: SliderThemeData(
                activeTrackColor: kGold,
                inactiveTrackColor: _g(0.1),
                thumbColor: kGold,
                overlayColor: kGold.withValues(alpha: 0.1),
              ),
              child: Slider(
                value: _budget,
                min: 500, max: 30000,
                onChanged: (v) => setState(() => _budget = v),
              ),
            ),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('500€', style: TextStyle(color: _g(0.3), fontSize: 10)),
              Text('30.000€+', style: TextStyle(color: _g(0.3), fontSize: 10)),
            ]),
            const SizedBox(height: 16),

            // Επιπλέον λεπτομέρειες
            Row(children: [
              Text('✏️ ', style: const TextStyle(fontSize: 14)),
              Text('Επιπλέον λεπτομέρειες (προαιρετικό)',
                  style: TextStyle(color: _g(0.6), fontSize: 13, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 8),
            TextField(
              controller: _detailsCtrl,
              maxLines: 3,
              style: TextStyle(color: _gw, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'πχ. "Θέλω υπαίθριο γάμο, στολ boho, με live band..."',
                hintStyle: TextStyle(color: _g(0.25), fontSize: 12),
                filled: true, fillColor: _g(0.04),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: _g(0.1))),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: _g(0.1))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: kGold)),
              ),
            ),
            const SizedBox(height: 24),

            // Submit
            GestureDetector(
              onTap: _sending ? null : _submit,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: _sending
                      ? LinearGradient(colors: [_g(0.1), _g(0.1)])
                      : const LinearGradient(colors: [kGoldLight, kGold]),
                ),
                child: Center(child: _sending
                    ? const SizedBox(width: 22, height: 22,
                        child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2))
                    : const Text('🚀 Αποστολή αιτήματος',
                        style: TextStyle(color: Colors.black, fontSize: 15, fontWeight: FontWeight.w800))),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
