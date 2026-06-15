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
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'firebase_options.dart';
import 'splash_screen.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

// ═══════════════════════════════════════
const String kBackendUrl = 'https://ai-backend-kkt7.onrender.com';
const String kStripeMonthlyPriceId = 'price_REPLACE_WITH_YOUR_STRIPE_PRICE_ID';
// Όλοι οι χρήστες έχουν δωρεάν πρόσβαση
const bool kFreeForAll = true;
final _analytics = FirebaseAnalytics.instance;
const Color kGold = Color(0xFFFFB340);
const Color kGoldLight = Color(0xFFFFD47A);
const Color kGoldDark = Color(0xFFCC8800);
const Color kBg = Color(0xFF060D1E);
// ═══════════════════════════════════════
// FCM PUSH NOTIFICATION SERVICE
// ═══════════════════════════════════════
class NotificationService {
  static final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  static final FlutterLocalNotificationsPlugin _localNotif =
      FlutterLocalNotificationsPlugin();

  static const _androidChannel = AndroidNotificationChannel(
    'gorealai_channel',
    'GorealAI Notifications',
    description: 'Ειδοποιήσεις από το GorealAI',
    importance: Importance.high,
  );

  static Future<void> init() async {
    // Register background handler
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    // Initialise flutter_local_notifications (needed for foreground display on Android)
    await _localNotif.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );

    // Create the Android notification channel (Android 8+)
    if (!kIsWeb) {
      await _localNotif
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(_androidChannel);
    }

    // Request permission
    await _fcm.requestPermission(alert: true, badge: true, sound: true);

    // Show notifications even when app is in foreground (iOS)
    await _fcm.setForegroundNotificationPresentationOptions(
        alert: true, badge: true, sound: true);

    // Get FCM token — vapidKey only for web
    final token = await _fcm.getToken(
        vapidKey: kIsWeb
            ? 'BJsbku1gXCS_uLwKrDcSJ9hIDGEUdthxe7wc_dfbeIcwq4aE1SqK3IdMPZ6j1vj0or-SWNloikIXmzWfW0_YqTY'
            : null);
    if (token != null) {
      // Cache token locally; will be saved to Firestore after login
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pending_fcm_token', token);
      // Also save immediately if already logged in
      await saveTokenForUser(token);
    }

    // Token refresh listener
    _fcm.onTokenRefresh.listen((newToken) async {
      await saveTokenForUser(newToken);
    });

    // Foreground message handler
    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      debugPrint('📬 FCM foreground: ${message.notification?.title}');
      final notification = message.notification;
      final title = notification?.title ?? '';
      final body = notification?.body ?? '';

      // Show system notification via local_notifications when app is open
      if (notification != null && !kIsWeb) {
        // Count unread notifications to set badge
        int badgeCount = 1;
        try {
          final uid = FirebaseAuth.instance.currentUser?.uid;
          if (uid != null) {
            final snap = await FirebaseFirestore.instance
                .collection('users').doc(uid)
                .collection('notifications')
                .where('isRead', isEqualTo: false)
                .get();
            badgeCount = snap.docs.length;
          }
        } catch (_) {}

        _localNotif.show(
          notification.hashCode,
          title,
          body,
          NotificationDetails(
            android: AndroidNotificationDetails(
              _androidChannel.id,
              _androidChannel.name,
              channelDescription: _androidChannel.description,
              importance: Importance.high,
              priority: Priority.high,
              icon: '@mipmap/ic_launcher',
              number: badgeCount, // badge count on launcher icon
            ),
          ),
        );
      }

      // Also show in-app overlay banner
      if (title.isNotEmpty) {
        _inAppNotifNotifier.value = _InAppNotif(
            title: title,
            body: body,
            id: DateTime.now().millisecondsSinceEpoch.toString());
      }
    });
  }

  // Καλείται μετά το login για να σωθεί το FCM token
  static Future<void> saveTokenForUser([String? tokenOverride]) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      String? token = tokenOverride;
      if (token == null) {
        final prefs = await SharedPreferences.getInstance();
        token = prefs.getString('pending_fcm_token');
        token ??= await _fcm.getToken(
            vapidKey: kIsWeb
                ? 'BJsbku1gXCS_uLwKrDcSJ9hIDGEUdthxe7wc_dfbeIcwq4aE1SqK3IdMPZ6j1vj0or-SWNloikIXmzWfW0_YqTY'
                : null);
      }
      if (token == null || token.isEmpty) return;
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .set({'fcmToken': token}, SetOptions(merge: true));
      debugPrint('✅ FCM token saved for ${user.uid}');
    } catch (e) {
      debugPrint('FCM token save error: $e');
    }
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
// IN-APP PUSH NOTIFICATION OVERLAY
// ═══════════════════════════════════════
class _InAppNotif {
  final String title;
  final String body;
  final String id;
  const _InAppNotif({required this.title, required this.body, required this.id});
}

final ValueNotifier<_InAppNotif?> _inAppNotifNotifier = ValueNotifier(null);

class InAppNotifOverlay extends StatefulWidget {
  final Widget child;
  const InAppNotifOverlay({super.key, required this.child});
  @override
  State<InAppNotifOverlay> createState() => _InAppNotifOverlayState();
}

class _InAppNotifOverlayState extends State<InAppNotifOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _animCtrl;
  late Animation<Offset> _slideAnim;
  late Animation<double> _fadeAnim;
  _InAppNotif? _current;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 350));
    _slideAnim = Tween<Offset>(begin: const Offset(0, -1.5), end: Offset.zero)
        .animate(CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutBack));
    _fadeAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOut);
    _inAppNotifNotifier.addListener(_onNotif);
  }

  @override
  void dispose() {
    _inAppNotifNotifier.removeListener(_onNotif);
    _hideTimer?.cancel();
    _animCtrl.dispose();
    super.dispose();
  }

  void _onNotif() {
    final notif = _inAppNotifNotifier.value;
    if (notif == null) return;
    setState(() => _current = notif);
    _animCtrl.forward(from: 0);
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      _animCtrl.reverse().then((_) {
        if (mounted) setState(() => _current = null);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      widget.child,
      if (_current != null)
        Positioned(
          top: MediaQuery.of(context).padding.top + 8,
          left: 16, right: 16,
          child: SlideTransition(
            position: _slideAnim,
            child: FadeTransition(
              opacity: _fadeAnim,
              child: GestureDetector(
                onTap: () {
                  _hideTimer?.cancel();
                  _animCtrl.reverse().then((_) {
                    if (mounted) setState(() => _current = null);
                  });
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    color: const Color(0xFF1A1500),
                    border: Border.all(color: kGold.withValues(alpha: 0.5)),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 20),
                      BoxShadow(color: kGold.withValues(alpha: 0.1), blurRadius: 12),
                    ],
                  ),
                  child: Row(children: [
                    Container(
                      width: 38, height: 38,
                      decoration: BoxDecoration(shape: BoxShape.circle,
                          color: kGold.withValues(alpha: 0.15)),
                      child: const Center(child: Text('🔔', style: TextStyle(fontSize: 18))),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min, children: [
                      Text(_current!.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 13,
                              fontWeight: FontWeight.w700)),
                      if (_current!.body.isNotEmpty)
                        Text(_current!.body, maxLines: 2, overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: _g(0.55), fontSize: 11, height: 1.4)),
                    ])),
                    Icon(Icons.close, color: _g(0.3), size: 16),
                  ]),
                ),
              ),
            ),
          ),
        ),
    ]);
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
final ValueNotifier<int> offerSelectedNotifier = ValueNotifier<int>(0);

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

  static Future<void> logout() async =>
      (await SharedPreferences.getInstance()).clear();
}

// ═══════════════════════════════════════
// Background FCM handler — must be top-level function
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('📬 FCM background: ${message.notification?.title}');
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
  @override
  State<GorealAiApp> createState() => _GorealAiAppState();
}

class _GorealAiAppState extends State<GorealAiApp> {
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
      home: InAppNotifOverlay(child: const SplashScreen()),
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
                      Center(child: CircularProgressIndicator(color: kGold)));
            }
            final role = userSnap.data?.data() != null
                ? (userSnap.data!.data()
                        as Map<String, dynamic>)['role'] ??
                    'user'
                : 'user';
            // Professionals now land on HomeScreen too (they get a Pro button in the header)
            return const HomeScreen();
          },
        );
      },
    );
  }
}

// ═══════════════════════════════════════
// EMAIL VERIFICATION SCREEN
// ═══════════════════════════════════════
class EmailVerificationScreen extends StatefulWidget {
  const EmailVerificationScreen({super.key});
  @override
  State<EmailVerificationScreen> createState() => _EmailVerificationScreenState();
}
          return const Scaffold(
              backgroundColor: kBg,
              body: Center(child: CircularProgressIndicator(color: kGold)));
        }
        if (!snapshot.hasData) return const LoginScreen();
        final user = snapshot.data!;
        final isDemo = user.email == 'demo@gorealai.app';
        if (!user.emailVerified && !isDemo) return const EmailVerificationScreen();
        return FutureBuilder<DocumentSnapshot>(
          future: _getUserDoc(user.uid),
          builder: (context, userSnap) {
            if (userSnap.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                  backgroundColor: kBg,
                  body: Center(child: CircularProgressIndicator(color: kGold)));
            }
            // Professionals now land on HomeScreen too (they get a Pro button in the header)
            return const HomeScreen();
          },
        );
      },
    );
  }
}

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
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  // Cache the user-doc future so it isn't recreated on every rebuild.
  // This prevents the white-screen flash when popping back to AuthGate
  // (e.g. after closing OffersReadyScreen without selecting a professional).
  Future<DocumentSnapshot>? _userDocFuture;
  String? _cachedUid;

  Future<DocumentSnapshot> _getUserDoc(String uid) {
    if (_userDocFuture == null || _cachedUid != uid) {
      _cachedUid = uid;
      _userDocFuture = FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
    }
    return _userDocFuture!;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
              backgroundColor: kBg,
              body: Center(child: CircularProgressIndicator(color: kGold)));
        }
        if (!snapshot.hasData) return const LoginScreen();
        final user = snapshot.data!;
        final isDemo = user.email == 'demo@gorealai.app';
        if (!user.emailVerified && !isDemo) return const EmailVerificationScreen();
        return FutureBuilder<DocumentSnapshot>(
          future: _getUserDoc(user.uid),
          builder: (context, userSnap) {
            if (userSnap.connectionState == ConnectionState.waiting) {
              return const Scaffold(
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
              backgroundColor: kBg,
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
              backgroundColor: kBg,
              body: Center(child: CircularProgressIndicator(color: kGold)));
        }
        if (!snapshot.hasData) return const LoginScreen();
        final user = snapshot.data!;
        final isDemo = user.email == 'demo@gorealai.app';
        if (!user.emailVerified && !isDemo) return const EmailVerificationScreen();
        return FutureBuilder<DocumentSnapshot>(
          future: _getUserDoc(user.uid, user.emailVerified),
          builder: (context, userSnap) {
            if (userSnap.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                  backgroundColor: kBg,
                  body: Center(child: CircularProgressIndicator(color: kGold)));
            }
            // Professionals land on HomeScreen too — they have an "Επαγγελματίας" button top-right
            return const HomeScreen();
          },
        );
      },
    );
  }
}

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
  bool _resending = false;
  int _resendCooldown = 0; // seconds remaining before next resend
  Timer? _pollTimer;
  Timer? _cooldownTimer;

  @override
  void initState() {
    super.initState();
    // Auto-check every 8 seconds — user just clicks link and app auto-enters
    _pollTimer = Timer.periodic(const Duration(seconds: 8), (_) => _checkVerified(silent: true));
    // Send initial verification email automatically
    _sendInitial();
  }

  Future<void> _sendInitial() async {
    try {
      await FirebaseAuth.instance.currentUser?.sendEmailVerification(ActionCodeSettings(
        url: 'https://gorealai.web.app',
        handleCodeInApp: false,
      ));
    } catch (_) {}
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _cooldownTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkVerified({bool silent = false}) async {
    if (!silent) setState(() => _checking = true);
    try {
      await FirebaseAuth.instance.currentUser?.reload();
      final user = FirebaseAuth.instance.currentUser;
      if (user != null && user.emailVerified) {
        _pollTimer?.cancel();
        if (mounted) {
          Navigator.pushReplacement(
              context, MaterialPageRoute(builder: (_) => const AuthGate()));
        }
        return;
      }
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Το email δεν έχει επαληθευτεί ακόμα. Έλεγξε τα εισερχόμενά σου.')));
      }
    } catch (_) {}
    if (!silent && mounted) setState(() => _checking = false);
  }

  Future<void> _resend() async {
    if (_resendCooldown > 0 || _resending) return;
    setState(() => _resending = true);
    try {
      await FirebaseAuth.instance.currentUser?.sendEmailVerification(ActionCodeSettings(
        url: 'https://gorealai.web.app',
        _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
          if (!mounted) { t.cancel(); return; }
          setState(() => _resendCooldown--);
          if (_resendCooldown <= 0) t.cancel();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _resending = false);
        final msg = e.toString().contains('too-many-requests')
            ? 'Πολλά αιτήματα. Περίμενε λίγα λεπτά.'
            : 'Σφάλμα αποστολής. Δοκίμασε ξανά.';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    }
  }

  Future<void> _changeEmail() async {
    // Delete account → back to register so they can re-register with correct email
    final confirmed = await showDialog<bool>(
      context: context,

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  final _confirmPass = TextEditingController();
  final _name = TextEditingController();
  final _lastName = TextEditingController();
  final _phone = TextEditingController();
  List<String> _selectedSpecialties = [];
  List<String> _selectedAreas = [];
  }

  Future<void> _autoLoginWithBiometrics() async {
    final email = await AuthService.getUser();
    final password = await AuthService.getPassword();
    if (email == null || password == null) return;
    final auth = LocalAuthentication();
    try {
      final ok = await auth.authenticate(
          localizedReason: 'Σύνδεση με δαχτυλικό αποτύπωμα',
          options: const AuthenticationOptions(biometricOnly: false));
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
                        Row(children: [
                          Expanded(
                              child: TextField(
                                  controller: _name,
                                  decoration: const InputDecoration(
// [GAP: LINE 820 NOT CAPTURED]
// [GAP: LINE 821 NOT CAPTURED]
// [GAP: LINE 822 NOT CAPTURED]
// [GAP: LINE 823 NOT CAPTURED]
// [GAP: LINE 824 NOT CAPTURED]
// [GAP: LINE 825 NOT CAPTURED]
// [GAP: LINE 826 NOT CAPTURED]
// [GAP: LINE 827 NOT CAPTURED]
// [GAP: LINE 828 NOT CAPTURED]
// [GAP: LINE 829 NOT CAPTURED]
// [GAP: LINE 830 NOT CAPTURED]
// [GAP: LINE 831 NOT CAPTURED]
// [GAP: LINE 832 NOT CAPTURED]
// [GAP: LINE 833 NOT CAPTURED]
// [GAP: LINE 834 NOT CAPTURED]
// [GAP: LINE 835 NOT CAPTURED]
// [GAP: LINE 836 NOT CAPTURED]
// [GAP: LINE 837 NOT CAPTURED]
// [GAP: LINE 838 NOT CAPTURED]
// [GAP: LINE 839 NOT CAPTURED]
// [GAP: LINE 840 NOT CAPTURED]
// [GAP: LINE 841 NOT CAPTURED]
// [GAP: LINE 842 NOT CAPTURED]
// [GAP: LINE 843 NOT CAPTURED]
// [GAP: LINE 844 NOT CAPTURED]
// [GAP: LINE 845 NOT CAPTURED]
// [GAP: LINE 846 NOT CAPTURED]
// [GAP: LINE 847 NOT CAPTURED]
// [GAP: LINE 848 NOT CAPTURED]
// [GAP: LINE 849 NOT CAPTURED]
// [GAP: LINE 850 NOT CAPTURED]
// [GAP: LINE 851 NOT CAPTURED]
// [GAP: LINE 852 NOT CAPTURED]
// [GAP: LINE 853 NOT CAPTURED]
// [GAP: LINE 854 NOT CAPTURED]
// [GAP: LINE 855 NOT CAPTURED]
// [GAP: LINE 856 NOT CAPTURED]
// [GAP: LINE 857 NOT CAPTURED]
// [GAP: LINE 858 NOT CAPTURED]
// [GAP: LINE 859 NOT CAPTURED]
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
    try {
      // Έλεγξε αν η συσκευή υποστηρίζει biometrics
      final canCheck = await auth.canCheckBiometrics;
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
  final _confirmPass = TextEditingController();
  final _name = TextEditingController();
  final _lastName = TextEditingController();
  final _phone = TextEditingController();
  List<String> _selectedSpecialties = [];
  List<String> _selectedAreas = [];
  bool _loading = false;
  bool _isLogin = true;
  bool _obscurePass = true;
  bool _obscureConfirm = true;
  String _role = 'user';
  Uint8List? _selfieBytes;
// [GAP: LINE 956 NOT CAPTURED]
// [GAP: LINE 957 NOT CAPTURED]
// [GAP: LINE 958 NOT CAPTURED]
// [GAP: LINE 959 NOT CAPTURED]
// [GAP: LINE 960 NOT CAPTURED]
// [GAP: LINE 961 NOT CAPTURED]
// [GAP: LINE 962 NOT CAPTURED]
// [GAP: LINE 963 NOT CAPTURED]
// [GAP: LINE 964 NOT CAPTURED]
// [GAP: LINE 965 NOT CAPTURED]
// [GAP: LINE 966 NOT CAPTURED]
// [GAP: LINE 967 NOT CAPTURED]
// [GAP: LINE 968 NOT CAPTURED]
// [GAP: LINE 969 NOT CAPTURED]
// [GAP: LINE 970 NOT CAPTURED]
// [GAP: LINE 971 NOT CAPTURED]
// [GAP: LINE 972 NOT CAPTURED]
// [GAP: LINE 973 NOT CAPTURED]
// [GAP: LINE 974 NOT CAPTURED]
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

                      // Selfie for professionals
                      if (!_isLogin && _role == 'professional') ...[
                        GestureDetector(
                          onTap: _takeSelfie,
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              color: kGold.withValues(alpha: 0.07),
                              border: Border.all(
                                  color: _selfieBytes != null
                                      ? kGold
                                      : kGold.withValues(alpha: 0.3),
                                  width: _selfieBytes != null ? 2 : 1),
                            ),
                            child: _selfieBytes != null
                                ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                    ClipOval(
                  style: TextStyle(
                      color: value != null
                          ? Colors.white
                          : _g(0.4),
                      fontSize: 14))),
            email: _email.text.trim(), password: _pass.text.trim());
        await AuthService.saveUser(_email.text.trim());
        await AuthService.savePassword(_pass.text.trim());
        await NotificationService.saveTokenForUser(); // αποθήκευσε FCM token μετά το login
        _analytics.logLogin(loginMethod: 'email');
        if (mounted) {
          Navigator.pushReplacement(
              context, MaterialPageRoute(builder: (_) => const AuthGate()));
        }
      } else {
        // Validate confirm password
        if (_pass.text.trim() != _confirmPass.text.trim()) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Οι κωδικοί δεν ταιριάζουν')));
          setState(() => _loading = false);
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
        await NotificationService.saveTokenForUser(); // αποθήκευσε FCM token μετά το login
        _analytics.logLogin(loginMethod: 'email');
        if (mounted) {
          Navigator.pushReplacement(
              context, MaterialPageRoute(builder: (_) => const AuthGate()));
        }
      } else {
        // Validate confirm password
        if (_pass.text.trim() != _confirmPass.text.trim()) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Οι κωδικοί δεν ταιριάζουν')));
          setState(() => _loading = false);
          return;
        }
        if (_role == 'professional' && _selectedSpecialties.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Παρακαλώ επιλέξτε τουλάχιστον μία ειδικότητα')));
          setState(() => _loading = false);
          return;
        }
        final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
            email: _email.text.trim(), password: _pass.text.trim());
        final fullName =
            '${_name.text.trim()} ${_lastName.text.trim()}'.trim();
        await cred.user!.updateDisplayName(fullName);
        // Send verification email — wrap in try/catch so a delivery failure
        // (e.g. SMTP block) does NOT stop the Firestore document creation below.
        try { await cred.user!.sendEmailVerification(); } catch (_) {}

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
          'city': _selectedAreas.isNotEmpty ? _selectedAreas.first : '',
          'phone': _phone.text.trim(),
          'role': _role,
          if (selfieUrl != null) 'profilePhotoUrl': selfieUrl,
          'createdAt': FieldValue.serverTimestamp(),
        });
        if (_role == 'professional') {
          await FirebaseFirestore.instance
              .collection('professionals')
              .doc(cred.user!.uid)
              .set({
            'name': fullName,
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
        final errStr = e.toString();
        if (errStr.contains('email-already-in-use')) {
          // Show a helpful dialog with options
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF111111),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
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

  @override
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                        foregroundColor: kGold,
                        side: BorderSide(color: kGold.withValues(alpha: 0.5)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                    onPressed: () async {
                      Navigator.pop(ctx);
                      try {
                        await FirebaseAuth.instance.sendPasswordResetEmail(email: _email.text.trim());
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                              content: Text('📧 Στάλθηκε email επαναφοράς κωδικού!')));
                        }
                      } catch (_) {}
                    },
                    child: const Text('Επαναφορά κωδικού'),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Άκυρο', style: TextStyle(color: Colors.white38, fontSize: 12)),
                ),
              ],
            ),
          );
        } else if (errStr.contains('wrong-password') || errStr.contains('invalid-credential')) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('❌ Λάθος email ή κωδικός. Δοκίμασε ξανά.')));
        } else if (errStr.contains('user-not-found')) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('❌ Δεν βρέθηκε λογαριασμός με αυτό το email.')));
        } else if (errStr.contains('too-many-requests')) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('⏳ Πολλές αποτυχημένες προσπάθειες. Δοκίμασε σε λίγα λεπτά.')));
        } else if (errStr.contains('network-request-failed')) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('📶 Πρόβλημα σύνδεσης. Έλεγξε το internet σου.')));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Σφάλμα: $errStr')));
        }
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
            .where('userId', isEqualTo: uid)
            .where('status', isEqualTo: 'completed')
            .get();
        for (final doc in snap.docs) {
          final d = doc.data();
          if (d['offersViewed'] == true) continue;
          final ts = d['createdAt'] as Timestamp?;
          if (ts != null && ts.compareTo(cutoff) < 0) continue;
          if (!mounted) return;
          // Show via overlay — zero browser history change
          offersReadyNotifier.value = _OffersReadyData(
            requestId: doc.id,
            userId: uid,
            description: d['description'] ?? '',
            criteria: d['criteria'] ?? 'cheap',
            offersCount: (d['offersCount'] as int?) ?? 0,
            collection: col,
          );
          return;
        }
      }
    } catch (_) {}
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
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  String? _userName;
  String? _userId;
  bool _isPro = false;
  int _navIndex = 0;
  // Ενεργά αιτήματα (για το G button — μέχρι 2)
  List<Map<String, dynamic>> _activeRequests = []; // list of {id, status, desc, criteria, expiresAt}
  List<Map<String, dynamic>> _activeRegularReqs = [];
  List<Map<String, dynamic>> _activeProjectReqs = [];
  List<Map<String, dynamic>> _activeEventReqs = [];
  int _unreadMessages = 0;
  StreamSubscription<QuerySnapshot>? _unreadMsgSub;

  String _vocative(String? n) {
    if (n == null || n.isEmpty) return '';
    // Keep only the first name (before any space)
    final first = n.trim().split(' ').first;
    // Remove trailing ς for vocative form (Γιώργος → Γιώργο)
    return first.endsWith('ς') ? first.substring(0, first.length - 1) : first;
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
        _listenUnreadMessages(uid);
        // Restore: if app restarted while offers were ready but not yet viewed,
        // send user directly to OffersReadyScreen instead of HomeScreen.
        _checkUnviewedOffers(uid);
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

  /// Called on HomeScreen mount. If the app restarted while the user had
  /// completed offers waiting (offersViewed != true), show OffersReadyScreen
  /// as an overlay via the notifier (no navigation → no browser history bug).
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

  void _listenActiveEventRequests(String uid) {
    FirebaseFirestore.instance
        .collection('event_requests')
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
                                : 'Έχεις λογαριασμό; Login',
                            style: TextStyle(color: _g(0.7))),
                      ),
                      const SizedBox(height: 4),
                      GestureDetector(
                        onTap: _loginAsDemo,
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: kGold.withValues(alpha: 0.35)),
                            color: kGold.withValues(alpha: 0.07),
                          ),
                          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                            const Text('🎯', style: TextStyle(fontSize: 15)),
                            const SizedBox(width: 8),
                            Text('Demo Login',

                      // Selfie for professionals
                      if (!_isLogin && _role == 'professional') ...[
                        GestureDetector(
                          onTap: _takeSelfie,
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              color: kGold.withValues(alpha: 0.07),
                              border: Border.all(
                                  color: _selfieBytes != null
                                      ? kGold
                                      : kGold.withValues(alpha: 0.3),
                                  width: _selfieBytes != null ? 2 : 1),
                            ),
                            child: _selfieBytes != null
                                ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                    ClipOval(
                                      child: Image.memory(_selfieBytes!,
                                          width: 48, height: 48, fit: BoxFit.cover),
                                    ),
                                    const SizedBox(width: 12),
                                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                      const Text('✅ Selfie ελήφθη',
                                          style: TextStyle(color: kGold, fontWeight: FontWeight.w700, fontSize: 13)),
                                      Text('Πάτα για να αλλάξεις',
                                          style: TextStyle(color: _g(0.4), fontSize: 11)),
                                    ]),
                                  ])
                                : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                    Icon(Icons.camera_alt_outlined,
                                        color: kGold.withValues(alpha: 0.8), size: 20),
                                    const SizedBox(width: 8),
                                    Text('📸 Τράβηξε selfie (προαιρετικό)',
                                        style: TextStyle(
                                            color: _g(0.6), fontSize: 13, fontWeight: FontWeight.w500)),
                                  ]),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],

                      TextField(
                          controller: _email,
                          decoration:
                              const InputDecoration(labelText: 'Email')),
                      const SizedBox(height: 14),
                      StatefulBuilder(
                  ])),
                  Icon(Icons.arrow_forward_ios,
                      color: _g(0.3), size: 14),
                ]),
              ),
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
                          : kGreen.withValues(alpha: 0.3)),
                ),
                child: Row(children: [
                  Container(width: 46, height: 46,
  void _openPortfolioGallery() {
    Navigator.push(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 400),
          pageBuilder: (_, __, ___) => const EventOrganizerScreen(),
          transitionsBuilder: (_, a, __, c) => SlideTransition(
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

  void _showPortfolioPremiumGate(BuildContext ctx, Map<String, dynamic> pro) {
    final proName = (pro['name'] ?? pro['displayName'] ?? 'Επαγγελματίας') as String;
    showDialog(context: ctx, builder: (c) => Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          color: const Color(0xFF0D0A04),
          border: Border.all(color: kGold.withValues(alpha: 0.5), width: 1.5),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('📸', style: TextStyle(fontSize: 50)),
          const SizedBox(height: 12),
          const Text('Premium Feature', style: TextStyle(color: Colors.white,
              fontFamily: 'Raleway', fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text('Αναβάθμισε σε Premium για να δεις το portfolio του $proName και να στείλεις απευθείας μήνυμα σε επαγγελματίες.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 13, height: 1.5)),
          const SizedBox(height: 20),
          GestureDetector(
            onTap: () async {
              Navigator.pop(c);
              await Navigator.push(ctx, PageRouteBuilder(
                pageBuilder: (_, __, ___) => const ProfileScreen(),
                transitionsBuilder: (_, a, __, c2) => FadeTransition(opacity: a, child: c2),
                transitionDuration: const Duration(milliseconds: 350),
              ));
              // After returning, re-check and open portfolio if now premium
              if (!ctx.mounted) return;
              final user = FirebaseAuth.instance.currentUser;
              if (user == null) return;
              try {
                final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
                if (doc.data()?['isPremium'] == true && ctx.mounted) {
                  Navigator.of(ctx).push(PageRouteBuilder(
                    pageBuilder: (_, __, ___) => ProPortfolioScreen(pro: pro),
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

      // When timer has expired AND offers exist → show overlay instead of vanishing
      for (final doc in snap.docs) {
        final d = doc.data();
        if (d['offersViewed'] == true) continue;
        final expiresAt = d['expiresAt'];
        if (expiresAt == null) continue;
        final exp = (expiresAt as Timestamp).toDate();
        if (!exp.isAfter(now)) {
          final offersCount = (d['offersCount'] as int?) ?? 0;
          if (offersCount > 0 && offersReadyNotifier.value == null) {
            offersReadyNotifier.value = _OffersReadyData(
              requestId: doc.id,
              userId: uid,
              description: d['description'] ?? '',
              criteria: d['criteria'] ?? 'cheap',
              offersCount: offersCount,
              collection: 'requests',
            );
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
          'offersCount': (d['offersCount'] as int?) ?? 0,
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

      // Show only active requests — no fallback for completed
      _activeRegularReqs = limited;
      _mergeActiveRequests();
    }, onError: (Object _) {
      _activeRegularReqs = [];
      _mergeActiveRequests();
    });
  }

  void _listenActiveProjectRequests(String uid) {
      // Mark offersViewed in Firestore immediately so app restart won't re-show this card
      FirebaseFirestore.instance
          .collection('requests')
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
        if (mounted) setState(() {
          _activeRequests.removeWhere((r) => r['id'] == req['id']);
          _activeRegularReqs.removeWhere((r) => r['id'] == req['id']);
        });
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // ── OffersReady overlay ──────────────────────────────────────────────────
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
              padding: const EdgeInsets.fromLTRB(0, 8, 20, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [_ProDashboardButton(userId: _userId!)],
              ),
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
            unreadMessages: _unreadMessages,
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
      // Mark offersViewed in Firestore immediately so app restart won't re-show this card
      FirebaseFirestore.instance
          .collection('requests')
          .doc(req['id'])
          .update({'offersViewed': true}).catchError((_) {});
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
        // Greeting
        const SizedBox(height: 18),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            RichText(
                text: TextSpan(children: [
              const TextSpan(
                  text: 'Γεια σου, ',
  bool _isPro = false;
  int _navIndex = 0;
  // Ενεργά αιτήματα (για το G button — μέχρι 2)
  List<Map<String, dynamic>> _activeRequests = []; // list of {id, status, desc, criteria, expiresAt}
  List<Map<String, dynamic>> _activeRegularReqs = [];
  List<Map<String, dynamic>> _activeProjectReqs = [];
  List<Map<String, dynamic>> _activeEventReqs = [];
  int _unreadMessages = 0;
  StreamSubscription<QuerySnapshot>? _unreadMsgSub;

  String _vocative(String? n) {
    if (n == null || n.isEmpty) return '';
    final first = n.trim().split(' ').first;
    // Ονόματα που παίρνουν -ε στην κλητική (όχι απλή αφαίρεση -ς)
    const Map<String, String> vocativeE = {
      'Νικόλαος': 'Νικόλαε',
      'Κωνσταντίνος': 'Κωνσταντίνε',

      'Στέφανος': 'Στέφανε',
      'Αλέξανδρος': 'Αλέξανδρε',
      'Θεόδωρος': 'Θεόδωρε',
      'Θόδωρος': 'Θόδωρε',
      'Λάμπρος': 'Λάμπρε',
      'Άγγελος': 'Άγγελε',
      'Ευάγγελος': 'Ευάγγελε',
      'Δημήτριος': 'Δημήτριε',
      'Βασίλειος': 'Βασίλειε',
    };
    if (vocativeE.containsKey(first)) return vocativeE[first]!;
    // Όλα τα άλλα: αφαίρεση -ς
    // -ης→-η (Γιάννης→Γιάννη), -ας→-α (Κώστας→Κώστα), -ος→-ο (Γιώργος→Γιώργο)
    if (first.endsWith('ς')) return first.substring(0, first.length - 1);
    // Θηλυκά & αμετάβλητα: Μαρία, Ελένη, Κατερίνα
    return first;
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
        _listenUnreadMessages(uid);
        // Restore: if app restarted while offers were ready but not yet viewed,
        // send user directly to OffersReadyScreen instead of HomeScreen.
        _checkUnviewedOffers(uid);
        // Ensure FCM token is saved for auto-authenticated users
        NotificationService.saveTokenForUser();
        // Wake up Render backend (free tier sleeps after 15 min inactivity)
        Future(() async {
          try {
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: kGreen)),
                          const SizedBox(width: 4),
                          Text('$count online',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: _g(0.3))),
                        ]);
                      },
                    ),
                    const SizedBox(width: 12),
                    // Bell hidden for pros — the Pro button already shows the badge
                    if (!_isPro) _NotificationBell(userId: _userId ?? ''),
                  ]),
                ]),
          ),

          // ── Pro button (only for professionals) — right-aligned ──
          if (_isPro && _userId != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 8, 20, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [_ProDashboardButton(userId: _userId!)],
              ),
            ),

          // CONTENT
          Expanded(
            child: _buildHome(),
          ),
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
    final collection = widget.isEvent
  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  void _openPortfolioGallery() {
    Navigator.push(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 400),
          pageBuilder: (_, __, ___) => const EventOrganizerScreen(),
          transitionsBuilder: (_, a, __, c) => SlideTransition(
              position: Tween<Offset>(
                      begin: const Offset(0, 1), end: Offset.zero)
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
  } // end _buildHomeScaffold

  Widget _buildHome() {
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        // Greeting
        const SizedBox(height: 18),
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
      }
    }
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
    final collection = widget.isEvent
        ? 'event_requests'
        : (widget.isProject ? 'project_requests' : 'requests');
    FirebaseFirestore.instance
        .collection(collection)
        .doc(widget.requests.first['id'])
        .snapshots()
          ),
        ),

        const SizedBox(height: 28),

        const SizedBox(height: 28),

        // NEARBY PROS SECTION
        _NearbyProsSection(
          onProTap: (pro) async {
            // Premium gate: only premium users can view portfolio
            final user = FirebaseAuth.instance.currentUser;
            bool isPremium = false;
            if (user != null) {
              try {
                final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
                isPremium = doc.data()?['isPremium'] == true || doc.data()?['isOwner'] == true;
              } catch (_) {}
            }
            if (!context.mounted) return;
            if (!isPremium) {
              _showPortfolioPremiumGate(context, pro);
              return;
            }
            Navigator.of(context).push(PageRouteBuilder(
              pageBuilder: (_, __, ___) => ProPortfolioScreen(pro: pro),
              transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
              transitionDuration: const Duration(milliseconds: 350),
            ));
          },
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
                    if (!_isPro) _NotificationBell(userId: _userId ?? ''),
                  ]),
                ]),
          ),

          // ── Pro button (only for professionals) — right-aligned ──
          if (_isPro && _userId != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 8, 20, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [_ProDashboardButton(userId: _userId!)],
              ),
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
            unreadMessages: _unreadMessages,
            onHome: () => setState(() => _navIndex = 0),
            onFab: _openPortfolioGallery,
            onHistory: () {
              setState(() => _navIndex = 2);

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
                        fontFamily: 'Raleway', fontSize: secs >= 3600 ? 11 : 14,
                        fontWeight: FontWeight.w800, color: kGold, letterSpacing: 1)),
                    Text(secs >= 3600 ? 'ώρες' : 'λεπτά', style: TextStyle(
                        fontSize: 7, color: _g(0.4))),
// [GAP: LINE 2325 NOT CAPTURED]
// [GAP: LINE 2326 NOT CAPTURED]
// [GAP: LINE 2327 NOT CAPTURED]
// [GAP: LINE 2328 NOT CAPTURED]
// [GAP: LINE 2329 NOT CAPTURED]
// [GAP: LINE 2330 NOT CAPTURED]
// [GAP: LINE 2331 NOT CAPTURED]
// [GAP: LINE 2332 NOT CAPTURED]
// [GAP: LINE 2333 NOT CAPTURED]
// [GAP: LINE 2334 NOT CAPTURED]
// [GAP: LINE 2335 NOT CAPTURED]
// [GAP: LINE 2336 NOT CAPTURED]
// [GAP: LINE 2337 NOT CAPTURED]
// [GAP: LINE 2338 NOT CAPTURED]
// [GAP: LINE 2339 NOT CAPTURED]
// [GAP: LINE 2340 NOT CAPTURED]
// [GAP: LINE 2341 NOT CAPTURED]
// [GAP: LINE 2342 NOT CAPTURED]
// [GAP: LINE 2343 NOT CAPTURED]
// [GAP: LINE 2344 NOT CAPTURED]
// [GAP: LINE 2345 NOT CAPTURED]
// [GAP: LINE 2346 NOT CAPTURED]
// [GAP: LINE 2347 NOT CAPTURED]
// [GAP: LINE 2348 NOT CAPTURED]
// [GAP: LINE 2349 NOT CAPTURED]
// [GAP: LINE 2350 NOT CAPTURED]
// [GAP: LINE 2351 NOT CAPTURED]
// [GAP: LINE 2352 NOT CAPTURED]
// [GAP: LINE 2353 NOT CAPTURED]
// [GAP: LINE 2354 NOT CAPTURED]
// [GAP: LINE 2355 NOT CAPTURED]
// [GAP: LINE 2356 NOT CAPTURED]
// [GAP: LINE 2357 NOT CAPTURED]
// [GAP: LINE 2358 NOT CAPTURED]
// [GAP: LINE 2359 NOT CAPTURED]
// [GAP: LINE 2360 NOT CAPTURED]
// [GAP: LINE 2361 NOT CAPTURED]
// [GAP: LINE 2362 NOT CAPTURED]
// [GAP: LINE 2363 NOT CAPTURED]
// [GAP: LINE 2364 NOT CAPTURED]
// [GAP: LINE 2365 NOT CAPTURED]
// [GAP: LINE 2366 NOT CAPTURED]
// [GAP: LINE 2367 NOT CAPTURED]
// [GAP: LINE 2368 NOT CAPTURED]

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
    final collection = widget.isEvent
        ? 'event_requests'
        : (widget.isProject ? 'project_requests' : 'requests');
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
class _ActiveRequestHeroCard extends StatefulWidget {
  final List<Map<String, dynamic>> requests;
  final VoidCallback onTap;
  final VoidCallback onNewRequest;
  final bool isProject;
  final bool isEvent;
  final int totalSeconds;
  const _ActiveRequestHeroCard({
    required this.requests, required this.onTap, required this.onNewRequest,
    this.isProject = false, this.isEvent = false, this.totalSeconds = 15 * 60});
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
      setState(() => _recalcFromExpiry());
    });
  }

  void _recalcFromExpiry() {
    for (final req in widget.requests) {
      final prevSecs = _secondsLeft[req['id']] ?? 1;
      final exp = req['expiresAt'];
      int newSecs;
      if (exp != null) {
        try {
          final expDate = (exp as dynamic).toDate() as DateTime;
          final diff = expDate.difference(DateTime.now()).inSeconds;
          newSecs = diff > 0 ? diff : 0;
        } catch (_) {
          newSecs = 0;
        }
      } else {
        newSecs = prevSecs > 0 ? prevSecs - 1 : 0;
      }
      _secondsLeft[req['id']] = newSecs;

      // Timer just hit zero — if offers exist, show overlay instead of vanishing
      if (prevSecs > 0 && newSecs == 0 && !widget.isEvent && !widget.isProject) {
        if (_offersCount > 0 && offersReadyNotifier.value == null) {
          final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && offersReadyNotifier.value == null) {
              offersReadyNotifier.value = _OffersReadyData(
                requestId: req['id'],
                userId: uid,
                description: req['desc'] ?? '',
                criteria: req['criteria'] ?? 'cheap',
                offersCount: _offersCount,
                collection: 'requests',
              );
            }
          });
        }
      }
    }
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
    final collection = widget.isEvent
        ? 'event_requests'
        : (widget.isProject ? 'project_requests' : 'requests');
    FirebaseFirestore.instance
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
  Uint8List? _proPhotoBytes;
  String _activeTab = 'requests';
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
                        fontFamily: 'Raleway', fontSize: secs >= 3600 ? 11 : 14,
                        fontWeight: FontWeight.w800, color: kGold, letterSpacing: 1)),
                    Text(secs >= 3600 ? 'ώρες' : 'λεπτά', style: TextStyle(
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
      children: [
        // Greeting
        const SizedBox(height: 18),
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
  @override
  void dispose() { _t.cancel(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    if (_secs < 0) return const SizedBox.shrink();
    final m = (_secs ~/ 60).toString().padLeft(2, '0');
    final s = (_secs % 60).toString().padLeft(2, '0');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: _g(0.04),
        border: Border.all(color: _g(0.1)),
      ),
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
  @override
  void dispose() { _t.cancel(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    if (_secs < 0) return const SizedBox.shrink();
    final m = (_secs ~/ 60).toString().padLeft(2, '0');
    final s = (_secs % 60).toString().padLeft(2, '0');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: _g(0.04),
        border: Border.all(color: _g(0.1)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Text('⏱️', style: TextStyle(fontSize: 10)),
        const SizedBox(width: 4),
        Text('$m:$s λ', style: TextStyle(color: _g(0.6), fontSize: 10, fontWeight: FontWeight.w500)),
      ]),
    );
  }
}

class _HowItWorksStep extends StatelessWidget {
  final String num, emoji, title, subtitle;
  final bool active;
  const _HowItWorksStep(
      {required this.num,
      required this.emoji,
      required this.title,

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
      ..color = handColor.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawCircle(Offset(cx, cy), r, borderPaint);

    // ── Tick marks (12, 3, 6, 9) ──
    final tickPaint = Paint()
      ..color = handColor.withValues(alpha: 0.25)
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.round;
    for (int i = 0; i < 12; i++) {
      final angle = (i * 30 - 90) * (math.pi / 180);
      final isMajor = i % 3 == 0;
      final outer = r - 1;
      final inner = outer - (isMajor ? 4.0 : 2.0);
      canvas.drawLine(
        Offset(cx + inner * math.cos(angle), cy + inner * math.sin(angle)),
        Offset(cx + outer * math.cos(angle), cy + outer * math.sin(angle)),
        tickPaint,
      );
    }

    // ── Κεντρική κουκκίδα ──
    final centerDot = Paint()..color = handColor;
    canvas.drawCircle(Offset(cx, cy), 2.0, centerDot);

    if (secondsRemaining <= 0) return;

    // ── Δείκτης λεπτών (remaining minutes out of total) ──
    // Στρέφεται από 12 → αντίθετα (countdown: ξεκινά από 12, πηγαίνει αριστερόστροφα)
    final fraction = secondsRemaining / totalSeconds; // 1.0 = full, 0.0 = expired
    // Minute hand: starts at 12 o'clock (top), rotates clockwise as time passes
    // At full time: points to 12 (fraction=1 → no rotation yet)
    // Actually: we want minute hand showing how much time is LEFT
    // → minute hand at (1 - fraction) * 360 degrees from 12 = clockwise as time runs out
    final minuteAngle = ((1 - fraction) * 360 - 90) * (math.pi / 180);
    final minuteLen = r * 0.58;
    final minutePaint = Paint()
      ..color = handColor
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(cx, cy),
      Offset(cx + minuteLen * math.cos(minuteAngle),
             cy + minuteLen * math.sin(minuteAngle)),
      minutePaint,
    );

    // ── Δείκτης δευτερολέπτων (within current minute) ──
    final secsInMinute = secondsRemaining % 60;
    final secAngle = (secsInMinute / 60 * 360 - 90) * (math.pi / 180);
    final secLen = r * 0.75;
    final secPaint = Paint()
      ..color = handColor.withValues(alpha: 0.5)
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(cx, cy),
      Offset(cx + secLen * math.cos(secAngle),
             cy + secLen * math.sin(secAngle)),
      secPaint,
    );

    // ── Arc: υπόλοιπος χρόνος ──
    final arcPaint = Paint()
      ..color = handColor.withValues(alpha: 0.12)
      ..style = PaintingStyle.fill;
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: r - 2),
      -math.pi / 2,
      fraction * 2 * math.pi,
      true,
      arcPaint,
    );
  }

  @override
  bool shouldRepaint(_AnalogClockPainter old) =>
      old.secondsRemaining != secondsRemaining ||
      old.handColor != handColor;
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
      final picked = await picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      setState(() => _uploadingPhoto = true);
      // Upload to Firebase Storage
      final ref = FirebaseStorage.instance
          .ref('profile_photos/${user.uid}/profile.jpg');
      await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
      final url = await ref.getDownloadURL();
      // Update Firestore user doc
      await FirebaseFirestore.instance
          .collection('users').doc(user.uid)
          .update({'profilePhotoUrl': url});
      // Also update professionals collection
      final proSnap = await FirebaseFirestore.instance
          .collection('professionals')
          .where('userId', isEqualTo: user.uid)
          .limit(1).get();
      for (final d in proSnap.docs) {
        await d.reference.update({'profilePhotoUrl': url});
      }
      if (!mounted) return;
      setState(() {
        _proPhotoUrl = url;
        _proPhotoBytes = bytes;
        _uploadingPhoto = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('✅ Φωτογραφία ενημερώθηκε!'),
          backgroundColor: Color(0xFF00D4AA),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _uploadingPhoto = false);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Σφάλμα ανεβάσματος: $e')));
      }
    }
  }

  Future<void> _saveBio() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    setState(() => _savingBio = true);

class _ProfessionalHomeScreenState extends State<ProfessionalHomeScreen> {
  String? _proName;
  String? _proId;
  String? _proSpecialty;
  String? _proPhotoUrl;
  Uint8List? _proPhotoBytes;
  String _activeTab = 'requests';
  final Set<String> _submittedIds = {};
  bool _uploadingPhoto = false;
  // Mini CV
  String _bio = '';
  final TextEditingController _bioCtrl = TextEditingController();
  bool _savingBio = false;
  bool _bioEditMode = false;
  // Specialties
  List<String> _specialties = [];
  bool _savingSpecialties = false;
  // Availability toggle
  bool _available = true;
  bool _savingAvailability = false;

  // ── Predefined specialties by category ──
  static const Map<String, List<String>> kSpecialtyCategories = {
  }

  static String? _storagePathFromUrl(String url) {
    try {
      final oIdx = url.indexOf('/o/');
      if (oIdx < 0) return null;
      final raw = url.substring(oIdx + 3).split('?').first;
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
    setState(() {
      _proName = doc.data()?['name'] ?? '';
      _proId = user.uid;
      _proPhotoUrl = photoUrl;
      _proSpecialty = proSnap.docs.isNotEmpty
          ? (proSnap.docs.first.data()['specialty'] as String? ?? '')
          : '';
      _bio = bio;
      _bioCtrl.text = bio;
      _bioEditMode = bio.isEmpty;
      _specialties = specs;
      _available = available;
    });
    // Prefetch profile photo bytes (bypass CORS)
    if (photoUrl != null && photoUrl.isNotEmpty) {
      _fetchPhotoBytes(photoUrl).then((bytes) {
        if (bytes != null && mounted) setState(() => _proPhotoBytes = bytes);
      });
    }
  }
      await FirebaseFirestore.instance
          .collection('bookings')
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
  final Set<String> _submittedIds = {};
  bool _uploadingPhoto = false;
  String _fmt() {
    final m = (_secs ~/ 60).toString().padLeft(2, '0');
    final s = (_secs % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    if (_secs < 0) return const SizedBox.shrink();
    final progress = (_secs / _totalSecs).clamp(0.0, 1.0);
    final urgent = _secs < 120;
    return SizedBox(
      width: 56, height: 56,
      child: Stack(alignment: Alignment.center, children: [
        SizedBox(
          width: 56, height: 56,
          child: urgent
            ? CustomPaint(painter: _UrgentRingPainter(progress: progress))
            : CustomPaint(painter: _RingPainter(progress: progress)),
        ),
        Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_fmt(),
              style: TextStyle(
                  fontFamily: 'Raleway',
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: urgent ? Colors.redAccent : kGold,
                  letterSpacing: 0.5)),
          Text('λεπτά', style: TextStyle(fontSize: 6, color: _g(0.4))),
        ]),
      ]),
    );
  }
}

// Urgent ring painter (κόκκινο)
class _UrgentRingPainter extends CustomPainter {
  final double progress;
  const _UrgentRingPainter({required this.progress});
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2, cy = size.height / 2, r = size.width / 2 - 5;
    canvas.drawCircle(Offset(cx, cy), r,
        Paint()..style = PaintingStyle.stroke..strokeWidth = 4
              ..color = Colors.red.withValues(alpha: 0.15));
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: r),
      -pi / 2, 2 * pi * progress, false,
      Paint()..style = PaintingStyle.stroke..strokeWidth = 4
             ..strokeCap = StrokeCap.round..color = Colors.redAccent,
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

class _ProfessionalHomeScreenState extends State<ProfessionalHomeScreen> {
  String? _proName;
  String? _proId;
  String? _proSpecialty;
  String? _proPhotoUrl;
  Uint8List? _proPhotoBytes;
  String _activeTab = 'requests';
  final Set<String> _submittedIds = {};
  bool _uploadingPhoto = false;
  // Mini CV
  String _bio = '';
  final TextEditingController _bioCtrl = TextEditingController();
  bool _savingBio = false;
  bool _bioEditMode = false;
  // Specialties
  List<String> _specialties = [];
  bool _savingSpecialties = false;
  // Service areas
  List<String> _areas = [];
  bool _savingAreas = false;
  // Availability toggle
  bool _available = true;
  bool _savingAvailability = false;

  // ── Predefined specialties by category ──
  static const Map<String, List<String>> kSpecialtyCategories = {
    '🔧 Υδραυλικά': ['Βλάβες υδραυλικών', 'Αποχέτευση', 'Επισκευή boiler', 'Εγκατάσταση boiler', 'Θέρμανση / καλοριφέρ', 'Κεντρική θέρμανση', 'Ηλιακά / Solar'],
    '⚡ Ηλεκτρολόγοι': ['Ηλεκτρολογικές βλάβες', 'Πίνακες ασφαλειών', 'Εγκατάσταση φωτιστικών', 'Smart home / automation', 'Γείωση & ασφάλεια'],
    '❄️ HVAC / Κλιματισμός': ['Κλιματιστικά', 'Συντήρηση κλιματιστικού', 'Φωτοβολταϊκά', 'VRV / VRF συστήματα'],
    '🪟 Κουφώματα & Τζάμια': ['Αλουμίνια & PVC', 'Διπλά τζάμια', 'Σίτες & ρολά', 'Ντουζιέρες & καμπίνες', 'Πόρτες Ασφαλείας'],
    '🏠 Μονώσεις & Τέντες': ['Μονώσεις δώματος', 'Μονώσεις τοίχων', 'Ηχομόνωση', 'Τέντες & σκίαστρα', 'Περγκολές'],
    '⚒️ Σιδηρουργικά & Μαρμαρικά': ['Σιδηρουργός', 'Κιγκλιδώματα', 'Μαρμαράς', 'Μαρμάρινες επιφάνειες'],
    '🏗️ Ανακαινίσεις': ['Γενικές ανακαινίσεις', 'Μπάνιο renovation', 'Κουζίνα renovation', 'Πλακάκια & δάπεδα', 'Γυψοσανίδες'],
    '🎨 Βαφή & Διακόσμηση': ['Βαφή εσωτερικών', 'Βαφή εξωτερικών', 'Ταπετσαρία', 'Stucco & εφέ'],
    '🔒 Κλειδαριές & Ασφάλεια': ['Κλειδαράς', 'Εγκατάσταση θωρακισμένης', 'Συναγερμοί & κάμερες'],
    '🌿 Κήπος & Εξωτερικοί χώροι': ['Συντήρηση κήπου', 'Γκαζόν & φύτευση', 'Άρδευση & ποτιστικά', 'Καθαρισμός χώρων'],
    '🧹 Καθαρισμός': ['Γενικός καθαρισμός', 'Βιομηχανικός καθαρισμός', 'Καθαρισμός μετά ανακαίνιση', 'Καθαρισμός τζαμιών'],
    '📦 Μεταφορές & Μετακομίσεις': ['Μετακομίσεις', 'Ανύψωση βαρέων', 'Μεταφορά επίπλων'],
  };

    '🧹 Καθαρισμός': ['Γενικός καθαρισμός', 'Βιομηχανικός καθαρισμός', 'Καθαρισμός μετά ανακαίνιση', 'Καθαρισμός τζαμιών'],
    '📦 Μεταφορές & Μετακομίσεις': ['Μετακομίσεις', 'Ανύψωση βαρέων', 'Μεταφορά επίπλων'],
  };

  @override
  void initState() {
    super.initState();
    _proId = FirebaseAuth.instance.currentUser?.uid;
    _loadProfile();
    _listenEventRequests();
  }

  bool _proMatchesEvent(Map<String, dynamic> eventData) {
    final categoryPros = List<String>.from(eventData['categoryPros'] ?? []);
    if (categoryPros.isEmpty) return true; // old docs without filter → show to all
        .where('status', isEqualTo: 'active')
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final now = DateTime.now();
      final active = snap.docs.where((doc) {
        final exp = doc.data()['expiresAt'] as Timestamp?;
        return exp != null && exp.toDate().isAfter(now);
      }).toList()
        ..sort((a, b) {
          final aTs = a.data()['createdAt'] as Timestamp?;
          final bTs = b.data()['createdAt'] as Timestamp?;
          if (aTs == null) return 1;
          if (bTs == null) return -1;

// ═══════════════════════════════════════
// PROFESSIONAL HOME SCREEN
// ═══════════════════════════════════════
class ProfessionalHomeScreen extends StatefulWidget {
      if (!mounted) return;
      final now = DateTime.now();
      final active = snap.docs.where((doc) {
        final data = doc.data();
        final exp = data['expiresAt'] as Timestamp?;
        if (exp == null || !exp.toDate().isAfter(now)) return false;
        return _proMatchesEvent(data);
      }).toList()
        ..sort((a, b) {
          final bTs = b.data()['createdAt'] as Timestamp?;
          if (aTs == null) return 1;
          if (bTs == null) return -1;
          return bTs.compareTo(aTs);
        });
        });
      setState(() => _eventReqDocs = active);
  final int navIndex;
  final String? userName;
  final String? activeRequestId;   // για badge στο G
  final bool hasActiveRequest;
  final int unreadMessages;
  final VoidCallback onHome, onFab, onHistory, onMessages, onProfile;
  const _BottomNav(
      {required this.navIndex,
      required this.userName,
      this.activeRequestId,
      this.hasActiveRequest = false,
      this.unreadMessages = 0,
      required this.onHome,
      required this.onFab,
      required this.onHistory,
      required this.onMessages,
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

                Stack(clipBehavior: Clip.none, children: [
                  _HNavItem(icon: Icons.chat_bubble_outline_rounded, label: 'Μηνύματα',
                      active: navIndex == 4, onTap: onMessages),
                  if (unreadMessages > 0)
                    Positioned(
                      top: 2, right: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.red.withValues(alpha: 0.6),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                        child: Text(
                          unreadMessages > 99 ? '99+' : '$unreadMessages',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            height: 1.2,
                          ),
                        ),
                      ),
                    ),
                ]),

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
          userEmail = userDoc.data()?['email'] as String?;
          userName = userDoc.data()?['name'] as String? ?? 'Χρήστης';
          userFcmToken = userDoc.data()?['fcmToken'] as String?;
        } catch (_) {}
      }

      try {
        await http.post(
          Uri.parse('$kBackendUrl/booking-response'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'bookingId': bookingId,
            'action': action,
            'proName': _proName ?? '',
            'userEmail': userEmail ?? '',
            'userName': userName ?? '',
            'userFcmToken': userFcmToken ?? '',
          }),
        );
      } catch (_) {}
      // FCM push directly to user
      if (userFcmToken != null && userFcmToken.isNotEmpty) {
        try {
          await http.post(
            Uri.parse('$kBackendUrl/send-push'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'token': userFcmToken,
              'title': action == 'accept' ? '✅ Αποδέχτηκαν το αίτημά σου!' : '❌ Δεν ήταν διαθέσιμος',
              'body': action == 'accept'
  void _showAreasSheet() {
    final selected = List<String>.from(_areas);
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
  final int unreadMessages;
  final VoidCallback onHome, onFab, onHistory, onMessages, onProfile;
  const _BottomNav(
      {required this.navIndex,
      required this.userName,
      this.activeRequestId,
      this.hasActiveRequest = false,
      this.unreadMessages = 0,
      required this.onHome,
      required this.onFab,
      required this.onHistory,
      required this.onMessages,
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

                Stack(clipBehavior: Clip.none, children: [
                  _HNavItem(icon: Icons.chat_bubble_outline_rounded, label: 'Μηνύματα',
                      active: navIndex == 4, onTap: onMessages),
                  if (unreadMessages > 0)
                    Positioned(
                      top: 2, right: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.red.withValues(alpha: 0.6),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                        child: Text(
                          unreadMessages > 99 ? '99+' : '$unreadMessages',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            height: 1.2,
                          ),
                        ),
                      ),
                    ),
                ]),

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
                  const SizedBox(width: 4),
                  _buildTab('portfolio', '📸 Portfolio'),
          ],
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

          // ══════════════════════════════════════
          // TOP BAR — greeting + avatar
          // ══════════════════════════════════════
          // ── Top bar: greeting + notifications + avatar ──
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: Row(children: [
              // Greeting
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Καλημέρα 👋', style: TextStyle(fontSize: 11, color: _g(0.4), fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                ShaderMask(
                  shaderCallback: (b) => const LinearGradient(colors: [kGoldLight, kGold]).createShader(b),
                  child: Text(_proName ?? '', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Colors.white)),
                ),
              ])),
              // Notification bell
              _NotificationBell(userId: _proId ?? ''),
              const SizedBox(width: 10),
              // Avatar
              GestureDetector(
                onTap: _changeProfilePhoto,
                onLongPress: () => Navigator.push(context, PageRouteBuilder(
                  transitionDuration: const Duration(milliseconds: 350),
                  pageBuilder: (_, __, ___) => const ProfileScreen(),
                  transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
                )),
                child: Stack(clipBehavior: Clip.none, children: [
                  Container(
                    width: 44, height: 44,
  Widget _buildProTab(String value, String label, {int badge = 0}) {
    final active = _activeTab == value;
    return GestureDetector(
      onTap: () => setState(() => _activeTab = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: active ? kGold : Colors.transparent,
          border: active ? null : Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: TextStyle(
              fontSize: 12, fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? Colors.black : Colors.white.withValues(alpha: 0.5))),
          if (badge > 0) ...[
            const SizedBox(width: 5),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: active ? Colors.black.withValues(alpha: 0.25) : kGold,
              ),
              child: Text('$badge', style: TextStyle(
                  fontSize: 9, fontWeight: FontWeight.w800,
                  color: active ? Colors.white : Colors.black)),
            ),
          ],
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

          // ══════════════════════════════════════
          // TOP BAR — greeting + avatar
  String? _proName;
  String? _proId;
  String? _proSpecialty;
  String? _proPhotoUrl;
  Uint8List? _proPhotoBytes;
  String _activeTab = 'requests';
  final Set<String> _submittedIds = {};
  bool _uploadingPhoto = false;
  // Mini CV
  String _bio = '';
  final TextEditingController _bioCtrl = TextEditingController();
  bool _savingBio = false;
  bool _bioEditMode = false;
  // Specialties
  List<String> _specialties = [];
  bool _savingSpecialties = false;
  // Service areas
  List<String> _areas = [];
  bool _savingAreas = false;
  // Availability toggle
  bool _available = true;
  bool _savingAvailability = false;
  // Google Places
  String? _googlePlaceId;
  double? _googleRating;
  int _googleRatingCount = 0;
  String _googleMapsUrl = '';
  bool _savingGooglePlace = false;
  // Event requests (from event_requests collection)
  List<QueryDocumentSnapshot> _eventReqDocs = [];
  bool _savingAreas = false;
  // Availability toggle
  bool _available = true;
  static const Map<String, List<String>> kSpecialtyCategories = {
    // ── Τεχνικά ──
    '🔧 Υδραυλικά': [
      'Βλάβες υδραυλικών', 'Αποχέτευση', 'Αποφράξεις σωλήνων',
      'Επισκευή boiler', 'Εγκατάσταση boiler', 'Θέρμανση / καλοριφέρ',
      'Κεντρική θέρμανση', 'Ηλιακά / Solar', 'Επισκευή βρύσης / καζανάκι',
      'Εγκατάσταση μπάνιου', 'Εγκατάσταση κουζίνας',
    ],
    '⚡ Ηλεκτρολόγοι': [
      'Ηλεκτρολογικές βλάβες', 'Πίνακες ασφαλειών',
      'Εγκατάσταση φωτιστικών', 'Ρηματισμός', 'Εγκατάσταση ρευματοδοτών',
      'Smart home / automation', 'Γείωση & ασφάλεια', 'Φωτοβολταϊκά',
    ],
    '❄️ HVAC / Κλιματισμός': [
      'Εγκατάσταση κλιματιστικού', 'Συντήρηση κλιματιστικού',
      'Επισκευή κλιματιστικού', 'VRV / VRF συστήματα',
      'Εγκατάσταση φωτοβολταϊκών', 'Αντλία θερμότητας',
    ],
    '🪟 Κουφώματα & Τζάμια': [
      'Αλουμίνια & PVC', 'Διπλά τζάμια', 'Σίτες & ρολά',
      'Ντουζιέρες & καμπίνες', 'Πόρτες Ασφαλείας',
      'Εγκατάσταση παραθύρων', 'Επισκευή τζαμιών', 'Υαλοτοιχία',
    ],
    '🏠 Μονώσεις & Τέντες': [
      'Μονώσεις δώματος', 'Μονώσεις τοίχων', 'Θερμομόνωση',
      'Ηχομόνωση', 'Τέντες & σκίαστρα', 'Περγκολές', 'Αδιαβροχοποίηση',
    ],
    '⚒️ Σιδηρουργικά & Μαρμαρικά': [
      'Κιγκλιδώματα', 'Μεταλλικές κατασκευές', 'Σκάλες & μπαλκόνια',
      'Μαρμάρινες επιφάνειες', 'Γρανίτης & quartz',
    ],
  // ── Predefined specialties by category ──
  static const Map<String, List<String>> kSpecialtyCategories = {
    // ── Τεχνικά ──
    '🔧 Υδραυλικά': [
      'Βλάβες υδραυλικών', 'Αποχέτευση', 'Αποφράξεις σωλήνων',
      'Επισκευή boiler', 'Εγκατάσταση boiler', 'Θέρμανση / καλοριφέρ',
      'Κεντρική θέρμανση', 'Ηλιακά / Solar', 'Επισκευή βρύσης / καζανάκι',
      'Εγκατάσταση μπάνιου', 'Εγκατάσταση κουζίνας',
    ],
    '⚡ Ηλεκτρολόγοι': [
      'Ηλεκτρολογικές βλάβες', 'Πίνακες ασφαλειών',
      'Εγκατάσταση φωτιστικών', 'Ρηματισμός', 'Εγκατάσταση ρευματοδοτών',
      'Smart home / automation', 'Γείωση & ασφάλεια', 'Φωτοβολταϊκά',
    ],
    '❄️ HVAC / Κλιματισμός': [
      'Εγκατάσταση κλιματιστικού', 'Συντήρηση κλιματιστικού',
      'Επισκευή κλιματιστικού', 'VRV / VRF συστήματα',
      'Εγκατάσταση φωτοβολταϊκών', 'Αντλία θερμότητας',
    ],
    '🪟 Κουφώματα & Τζάμια': [
      'Αλουμίνια & PVC', 'Διπλά τζάμια', 'Σίτες & ρολά',
      'Ντουζιέρες & καμπίνες', 'Πόρτες Ασφαλείας',
      'Εγκατάσταση παραθύρων', 'Επισκευή τζαμιών', 'Υαλοτοιχία',
    ],
    '🏠 Μονώσεις & Τέντες': [
      'Μονώσεις δώματος', 'Μονώσεις τοίχων', 'Θερμομόνωση',
      'Ηχομόνωση', 'Τέντες & σκίαστρα', 'Περγκολές', 'Αδιαβροχοποίηση',
    ],
    '⚒️ Σιδηρουργικά & Μαρμαρικά': [
      'Κιγκλιδώματα', 'Μεταλλικές κατασκευές', 'Σκάλες & μπαλκόνια',
      'Μαρμάρινες επιφάνειες', 'Γρανίτης & quartz',
    ],
    '🏗️ Ανακαινίσεις & Κατασκευές': [
      'Γενικές ανακαινίσεις', 'Μπάνιο renovation', 'Κουζίνα renovation',
      'Πλακάκια & δάπεδα', 'Γυψοσανίδες', 'Σπατουλαριστά',
      'Αποξήλωση', 'Οικοδομικές εργασίες', 'Αποπεράτωση κατοικίας',
    ],
    '🎨 Βαφή & Διακόσμηση': [
      'Βαφή εσωτερικών', 'Βαφή εξωτερικών', 'Ταπετσαρία',
      'Stucco & εφέ', 'Βαφή ξύλινων επιφανειών',
    ],
    '🔒 Κλειδαριές & Ασφάλεια': [
      'Κλειδαράς', 'Εγκατάσταση θωρακισμένης',
      'Συναγερμοί & κάμερες', 'Εγκατάσταση χρηματοκιβωτίου',
    ],
    '🔨 Ξυλουργικά & Επίπλωση': [
      'Κατασκευή επίπλων', 'Επισκευή επίπλων',
      'Ντουλάπες & εντοιχισμένα', 'Ξύλινα δάπεδα / παρκέ',
      'Συναρμολόγηση επίπλων', 'Κουζινικά έπιπλα',
    ],
    '🛗 Ανελκυστήρες': [
      'Εγκατάσταση ανελκυστήρα', 'Συντήρηση ανελκυστήρα',
      'Επισκευή ανελκυστήρα', 'Πιστοποίηση ανελκυστήρα',
      'Αναβάθμιση ανελκυστήρα',
    ],
    '🌿 Κήπος & Εξωτερικοί χώροι': [
      'Συντήρηση κήπου', 'Γκαζόν & φύτευση', 'Κλάδεμα δένδρων',
      'Άρδευση & ποτιστικά', 'Τεχνητό γρασίδι', 'Εξωτερικός φωτισμός',
    ],
    '🧹 Καθαρισμός': [
      'Γενικός καθαρισμός', 'Βιομηχανικός καθαρισμός',
      'Καθαρισμός μετά ανακαίνιση', 'Καθαρισμός τζαμιών',
      'Καθαρισμός χαλιών', 'Ozone / απολύμανση',
    ],
    '📦 Μεταφορές & Μετακομίσεις': [
      'Μετακομίσεις', 'Μεταφορά επίπλων', 'Ανύψωση βαρέων',
      'Αποθήκευση', 'Συσκευασία & αποσυσκευασία',
    ],

    // ── Αυτοκίνητο ──
    '🚗 Αυτοκίνητο': [
      'Γενική επισκευή', 'Service & συντήρηση', 'Φρένα & αμορτισέρ',
      'Σύστημα ψύξης', 'Ηλεκτρολογικά αυτοκινήτου',
      'Κλιματισμός αυτοκινήτου', 'Ελαστικά & ζάντες',
      'Φανοποιία & βαφή', 'Διαγνωστικός έλεγχος', 'ΚΤΕΟ & πιστοποιητικά',
    ],

    // ── Υγεία ──
    '🏥 Παθολόγος / Γενική Ιατρική': [
      'Γενική εξέταση', 'Χρόνιες παθήσεις', 'Εμβολιασμοί',
      'Εξετάσεις αίματος', 'Τηλεϊατρική', 'Πιστοποιητικά υγείας',
    ],
    '👶 Παιδίατρος': [
      'Γενική παιδιατρική', 'Εμβολιασμοί παιδιών',
      'Παιδικές ασθένειες', 'Ανάπτυξη & έλεγχος', 'Τηλεϊατρική',
    ],
    '🦷 Οδοντίατρος': [
      'Γενική οδοντιατρική', 'Σφραγίσματα', 'Λεύκανση δοντιών',
      'Εμφυτεύματα', 'Ακτινογραφίες', 'Παιδοδοντιατρική', 'Ορθοδοντική',
    ],
    '💪 Φυσιοθεραπεία': [
      'Φυσιοθεραπεία', 'Αποκατάσταση τραυματισμών',
      'Μυοσκελετικά προβλήματα', 'Σπορ φυσιοθεραπεία',
      'Κινησιοθεραπεία', 'Μάλαξη θεραπευτική',
    ],
    '🧠 Ψυχική Υγεία': [
      'Ψυχοθεραπεία', 'Γνωσιακή-συμπεριφορική θεραπεία',
      'Συμβουλευτική ζεύγους', 'Παιδοψυχολόγος',
      'Coaching', 'Ομαδική θεραπεία', 'EMDR',
    ],
    '🥗 Διατροφολόγος': [
      'Διατροφικό πλάνο αδυνατίσματος', 'Διατροφή αθλητών',
      'Διαβήτης & χρόνιες παθήσεις', 'Χορτοφαγική / vegan διατροφή',
      'Διατροφή εγκύου', 'Διατροφή παιδιών',
    ],
    '🏠 Νοσηλευτής κατ\' οίκον': [
      'Νοσηλεία κατ\' οίκον', 'Φροντίδα ηλικιωμένων',
      'Αποκατάσταση μετά νοσηλεία', 'Ενέσεις & επιδέσεις',
      'Τραυματιολογία', 'Συνοδός ασθενούς',
    ],

    // ── Σπίτι / Φροντίδα ──
    '👶 Baby Sitter & Φροντίδα': [
      'Baby sitting', 'Φύλαξη παιδιών κατ\' οίκον',
      'Βοηθός νηπιαγωγείου', 'Απογευματινή φροντίδα',
      'Φροντίδα ηλικιωμένων', 'Συνοδός',
    ],

    // ── Εκπαίδευση ──
    '📐 Μαθηματικά & Θετικές Επιστήμες': [
      'Μαθηματικά Γυμνασίου', 'Μαθηματικά Λυκείου',
      'Φυσική', 'Χημεία', 'Βιολογία',
      'Πληροφορική', 'Στατιστική', 'Τεχνολογία',
    ],
    '🌍 Ξένες Γλώσσες': [
      'Αγγλικά', 'Γαλλικά', 'Γερμανικά',
      'Ιταλικά', 'Ισπανικά', 'Ρωσικά',
      'IELTS / TOEFL προετοιμασία', 'Επαγγελματικά αγγλικά',
    ],
    '✏️ Ανθρωπιστικές Επιστήμες': [
      'Φιλολογία', 'Ιστορία', 'Λατινικά',
      'Αρχαία ελληνικά', 'Νεοελληνική λογοτεχνία', 'Έκθεση / Γραφή',
    ],
    '🏋️ Personal Trainer': [
      'Γυμναστική απώλειας βάρους', 'Μυϊκή ενδυνάμωση',
      'Cardio & αντοχή', 'Pilates', 'Yoga',
      'Crossfit', 'Online προπόνηση', 'Διατροφή αθλητών',
    ],

    // ── Ψηφιακές ──
    '💻 Web & Software': [
      'Web Development', 'Frontend (React / Vue)',
      'Backend (Node / PHP / Python)', 'WordPress',
      'E-commerce / Eshop', 'SEO & Google Ads',
      'Mobile app', 'UI/UX design',
    ],
    '🎨 Γραφιστική & Social Media': [
      'Logo design', 'Εταιρική ταυτότητα',
      'Social media posts', 'Video editing',
      'Motion graphics', 'Print design',
    ],
    '🖥️ Τεχνικός Υπολογιστών': [
      'Επισκευή laptop / PC', 'Εγκατάσταση λογισμικού',
      'Αντίγραφα ασφαλείας', 'Αντιμετώπιση ιών',
      'Αναβάθμιση hardware', 'Δίκτυα & router',
    ],

    // ── Φωτογραφία ──
    '📸 Φωτογραφία & Βίντεο': [
      'Φωτογράφηση γάμου', 'Φωτογράφηση βάφτισης',
      'Φωτογράφηση εκδηλώσεων', 'Portrait & studio',
      'Φωτογράφηση ακινήτων', 'Product photography',
      'Βιντεογράφηση', 'Drone shots',
    ],

    // ── Εκδηλώσεις ──
    '🎉 Εκδηλώσεις': [
      'Οργάνωση γάμου', 'Οργάνωση βάφτισης',
      'Πάρτυ γενεθλίων', 'Εταιρική εκδήλωση',
      'Catering', 'Στολισμός χώρου',
      'DJ / Μουσική', 'Αίθουσα εκδηλώσεων',
      'Ανθοδέτης & λουλούδια',
    ],

    // ── Ομορφιά ──
    '💅 Νύχια & Αισθητική': [
      'Νύχια gel', 'Ακρυλικά νύχια', 'Manicure',
      'Pedicure', 'Nail art', 'Ημιμόνιμο',
    ],
    '🖋️ Tattoo & Piercing': [
      'Tattoo', 'Cover-up tattoo', 'Piercing',
      'Μόνιμο μακιγιάζ / microblading', 'Laser αφαίρεση tattoo',
    ],

    // ── Νομικά / Οικονομικά ──
    '⚖️ Νομικές Υπηρεσίες': [
      'Εργατικό δίκαιο', 'Αστικό δίκαιο',
      'Ποινικό δίκαιο', 'Ακίνητα & συμβόλαια',
      'Εταιρικό δίκαιο', 'Διαζύγια & οικογενειακό',
      'Τροχαία & αποζημιώσεις',
    ],
    '📊 Λογιστικές Υπηρεσίες': [
      'Φορολογικές δηλώσεις', 'Μισθοδοσία',
      'Έναρξη επιχείρησης', 'ΦΠΑ & λογιστική',
      'Ε.Φ.Κ.Α. & ασφαλιστικά', 'Business plan',
    ],

    // ── Αρχιτεκτονική ──
    '🏛️ Αρχιτεκτονική & Μηχανικοί': [
      'Αρχιτεκτονικές μελέτες', 'Σχεδιασμός εσωτερικών χώρων',
      'Πολεοδομικές άδειες', 'Ενεργειακό πιστοποιητικό',
      'Στατική μελέτη', 'Τοπογράφος', '3D visualization',
    child: Container(
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: selected ? kGold.withValues(alpha: 0.1) : Colors.transparent,
        border: Border.all(color: selected ? kGold.withValues(alpha: 0.35) : Colors.transparent),
      ),
      child: Row(children: [
        Expanded(child: Text(label, style: TextStyle(
            color: selected ? kGold : Colors.white.withValues(alpha: 0.75), fontSize: 13))),
        if (selected) const Icon(Icons.check_circle, color: kGold, size: 16)
        else Icon(Icons.add_circle_outline, color: Colors.white.withValues(alpha: 0.2), size: 16),
      ]),
    ),
  );
}

// Exact specialties from the 'Εκδηλώσεις' registration category (lowercase)
// Used to filter which professionals see event requests
    } else {
      final cpLowList = categoryPros.map((cp) => cp.toLowerCase()).toList();
      specMatches = allSpecs.any((sp) {
        if (sp.isEmpty) return false;
        return cpLowList.any((cpLow) => sp.contains(cpLow));
      });
    }
    // ── 4. Photo check ──
    final withPhotos = reqData['withPhotos'] as bool? ?? false;
    if (withPhotos) {
      final hasPhoto = _proPhotoUrl != null && _proPhotoUrl!.isNotEmpty;
      if (!hasPhoto) return false;
    }

    // ── 5. Rating check ──
    final minRating = (reqData['minRating'] as num?)?.toDouble();
    if (minRating != null && minRating > 0) {
      if (_proAverageRating < minRating) return false;
    }

    return true;
  }

  Future<void> _saveAreas(List<String> areas) async {
    final user = FirebaseAuth.instance.currentUser;
  String _tiktok = '';
  final Set<String> _submittedIds = {};
  bool _uploadingPhoto = false;
  // Mini CV
  String _bio = '';
  final TextEditingController _bioCtrl = TextEditingController();
  bool _savingBio = false;
  bool _bioEditMode = false;
  // Main profession
  bool _savingMainSpecialty = false;
  // Specialties
  List<String> _specialties = [];
  bool _savingSpecialties = false;
  // Service areas
  List<String> _areas = [];
  bool _savingAreas = false;
  // Availability toggle
  bool _available = true;
  bool _savingAvailability = false;
  // Pro average rating (for request filter matching)
  double _proAverageRating = 0.0;
  // Google Places
  String? _googlePlaceId;
  double? _googleRating;
  int _googleRatingCount = 0;
    if (!mounted) return;
    final photoUrl = doc.data()?['profilePhotoUrl'] as String?;
    final bio = doc.data()?['bio'] as String? ?? '';
    final rawSpecs = doc.data()?['specialties'];
    final specs = rawSpecs is List ? List<String>.from(rawSpecs.map((e) => e.toString())) : <String>[];
    final available = doc.data()?['available'] as bool? ?? true;
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
      final pd = proSnap.docs.first.data();
      gPlaceId = pd['googlePlaceId'] as String?;
      gRating = (pd['googleRating'] as num?)?.toDouble();
      gRatingCount = (pd['googleRatingCount'] as num?)?.toInt() ?? 0;
      gMapsUrl = pd['googleMapsUrl'] as String? ?? '';
    }
    setState(() {
      _proName = doc.data()?['name'] ?? '';
      _proId = user.uid;
      _proPhotoUrl = photoUrl;
      _proSpecialty = proSnap.docs.isNotEmpty
          ? (proSnap.docs.first.data()['specialty'] as String? ?? '')
          : '';
      _bio = bio;
      _bioCtrl.text = bio;
      _bioEditMode = bio.isEmpty;
      _specialties = specs;
      _areas = areas;
      _available = available;
      _googlePlaceId = gPlaceId;
      _googleRating = gRating;
      _googleRatingCount = gRatingCount;
      _googleMapsUrl = gMapsUrl;
    });
// [GAP: LINE 4017 NOT CAPTURED]
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
      final pd = proSnap.docs.first.data();
      gPlaceId = pd['googlePlaceId'] as String?;
      gRating = (pd['googleRating'] as num?)?.toDouble();
      gRatingCount = (pd['googleRatingCount'] as num?)?.toInt() ?? 0;
      gMapsUrl = pd['googleMapsUrl'] as String? ?? '';
    }
    setState(() {
      _proName = doc.data()?['name'] ?? '';
      _proId = user.uid;
      _proPhotoUrl = photoUrl;
      _proSpecialty = proSnap.docs.isNotEmpty
          ? (proSnap.docs.first.data()['specialty'] as String? ?? '')
          : '';
      _bio = bio;
      _bioCtrl.text = bio;
      _bioEditMode = bio.isEmpty;
      _specialties = specs;
      _areas = areas;
      _available = available;
      _proAverageRating = avgRating;
      _googlePlaceId = gPlaceId;
      _googleRating = gRating;
      _googleRatingCount = gRatingCount;
      _googleMapsUrl = gMapsUrl;
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
      final path = _storagePathFromUrl(url);
      if (path != null) {
        return await FirebaseStorage.instance.ref(path).getData(5 * 1024 * 1024);
      }
    } catch (_) {}
    return null;
  }
// [GAP: LINE 4097 NOT CAPTURED]
// [GAP: LINE 4098 NOT CAPTURED]
// [GAP: LINE 4099 NOT CAPTURED]
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
          // ── Σήμερα Glance Card ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: StreamBuilder<QuerySnapshot>(
              stream: (_proId == null || _proId!.isEmpty) ? const Stream.empty()
                  : FirebaseFirestore.instance.collection('bookings')
                      .where('professionalId', isEqualTo: _proId).snapshots(),
              builder: (context, bookSnap) {
                return StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance.collection('requests')
                      .where('status', isEqualTo: 'active').limit(50).snapshots(),
                  builder: (context, reqSnap) {
                    return StreamBuilder<DocumentSnapshot>(
                      stream: (_proId == null || _proId!.isEmpty) ? const Stream.empty()
                          : FirebaseFirestore.instance.collection('users').doc(_proId).snapshots(),
                      builder: (context, userSnap) {
                        final bookings = bookSnap.data?.docs ?? [];
                        final pendingCount = bookings.where((d) => (d.data() as Map)['status'] == 'pending').length;
                        final acceptedCount = bookings.where((d) => (d.data() as Map)['status'] == 'accepted').length;
                        final reqCount = (reqSnap.data?.docs
                            .where((d) => _proMatchesRequest(d.data() as Map<String, dynamic>))
                            .length ?? 0) + _eventReqDocs.length;
                        final userData = userSnap.data?.data() as Map<String, dynamic>? ?? {};
                        final avg = ((userData['averageRating'] ?? 0.0) as num).toDouble();
                        final reviewCount = ((userData['reviewCount'] ?? 0) as num).toInt();

                        return Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            gradient: LinearGradient(
                              begin: Alignment.topLeft, end: Alignment.bottomRight,
                              colors: [
                                const Color(0xFF1A0E00),
                                kBg,
                                const Color(0xFF001A10).withValues(alpha: 0.6),
                              ],
                            ),
                            border: Border.all(color: kGold.withValues(alpha: 0.2)),
                            boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.06), blurRadius: 20)],
                          ),
                          child: Column(children: [
                            Row(children: [
                              Text('ΣΗΜΕΡΑ', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800,
                                  color: kGold.withValues(alpha: 0.6), letterSpacing: 1.5)),
                              const Spacer(),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  color: kGreen.withValues(alpha: 0.12),
                                  border: Border.all(color: kGreen.withValues(alpha: 0.3)),
                                ),
                                child: Row(mainAxisSize: MainAxisSize.min, children: [
                                  Container(width: 5, height: 5, decoration: const BoxDecoration(shape: BoxShape.circle, color: kGreen)),
    try {
      final proSnap = await FirebaseFirestore.instance
          .collection('professionals').where('userId', isEqualTo: user.uid).limit(1).get();
      for (final d in proSnap.docs) {
        await d.reference.update({
          'areas': areas,
          'area': areas.isNotEmpty ? areas.first : '',
        });
      }
      if (mounted) setState(() { _areas = areas; _savingAreas = false; });
    } catch (_) {
      if (mounted) setState(() => _savingAreas = false);
    }
  }

  Future<void> _saveGooglePlace(String placeId, double rating, int count, String mapsUrl) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    setState(() => _savingGooglePlace = true);
    try {

          const SizedBox(height: 10),

          // ── Availability toggle ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: _g(0.03),
                border: Border.all(color: _available
                    ? kGreen.withValues(alpha: 0.25)
                    : _g(0.07)),
              ),
              child: Row(children: [
                Container(
                  width: 32, height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: (_available ? kGreen : Colors.grey).withValues(alpha: 0.15),
                  ),
                  child: Icon(Icons.bolt, color: _available ? kGreen : Colors.grey, size: 18),
                ),
                const SizedBox(width: 12),
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
      for (final d in proSnap.docs) {
        await d.reference.update({'available': val});
      }
    } catch (_) {}
    if (mounted) setState(() => _savingAvailability = false);
  }

  void _showSpecialtiesSheet() {
    final selected = List<String>.from(_specialties);
    final searchCtrl = TextEditingController();
    String searchQuery = '';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setSheet) {
          final allPredefined = kSpecialtyCategories.values.expand((e) => e).toList();
          final filtered = searchQuery.isEmpty
              ? null
              : allPredefined.where((s) => s.toLowerCase().contains(searchQuery.toLowerCase())).toList();

          return Container(
            height: MediaQuery.of(context).size.height * 0.85,
            decoration: const BoxDecoration(
              color: Color(0xFF0F1123),
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(children: [
              // Handle
              Container(margin: const EdgeInsets.only(top: 12),
                  width: 40, height: 4,
                  decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
              // Title
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: Row(children: [
                  const Expanded(child: Text('Ειδικότητες', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800))),
                  GestureDetector(
                    onTap: () { Navigator.pop(ctx); _saveSpecialties(selected); },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        gradient: const LinearGradient(colors: [kGoldLight, kGold]),
                      ),
                      child: const Text('Αποθήκευση', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w700, fontSize: 13)),
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text('Επίλεξε από τη λίστα ή πρόσθεσε δική σου',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 12)),
              ),
              const SizedBox(height: 12),
              // Search bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: Colors.white.withValues(alpha: 0.06),
                    border: Border.all(color: kGold.withValues(alpha: 0.25)),
                  ),
                  child: TextField(
                    controller: searchCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    onChanged: (v) => setSheet(() => searchQuery = v),
                    decoration: InputDecoration(
                      hintText: 'Αναζήτηση ή νέα ειδικότητα...',
                      hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 13),
                      prefixIcon: Icon(Icons.search, color: Colors.white.withValues(alpha: 0.4), size: 18),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ),
              // "Add custom" button when search has text and no exact match
              if (searchQuery.isNotEmpty && !allPredefined.any((s) => s.toLowerCase() == searchQuery.toLowerCase()) && !selected.contains(searchQuery))
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                  child: GestureDetector(
                    onTap: () { setSheet(() { selected.add(searchQuery.trim()); searchCtrl.clear(); searchQuery = ''; }); },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: kGold.withValues(alpha: 0.1),
                        border: Border.all(color: kGold.withValues(alpha: 0.35)),
                      ),
                      child: Row(children: [
                        const Icon(Icons.add, color: kGold, size: 16),
                        const SizedBox(width: 8),
                        Expanded(child: Text('Πρόσθεσε "${searchQuery.trim()}"',
                            style: const TextStyle(color: kGold, fontSize: 13))),
                      ]),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              // Selected chips preview
              if (selected.isNotEmpty)
                Container(
                  margin: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: kGold.withValues(alpha: 0.06),
                    border: Border.all(color: kGold.withValues(alpha: 0.2)),
                  ),
                  child: Wrap(spacing: 6, runSpacing: 6, children: selected.map((s) => GestureDetector(
                    onTap: () => setSheet(() => selected.remove(s)),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        color: kGold.withValues(alpha: 0.15),
                        border: Border.all(color: kGold.withValues(alpha: 0.4)),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(s, style: const TextStyle(color: kGold, fontSize: 12, fontWeight: FontWeight.w600)),
                        const SizedBox(width: 4),
                        Icon(Icons.close, color: kGold.withValues(alpha: 0.7), size: 12),
                      ]),
                    ),
                  )).toList()),
                ),
              // List of specialties
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 30),
                  children: filtered != null
                      ? filtered.map((s) => _SpecialtyOption(
                          label: s,
                          selected: selected.contains(s),
                          onTap: () => setSheet(() {
                            if (selected.contains(s)) selected.remove(s); else selected.add(s);
                          }),
                        )).toList()
                      : kSpecialtyCategories.entries.expand((entry) => [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(0, 14, 0, 6),
                            child: Text(entry.key, style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.5),
                                fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
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
                        const SizedBox(width: 6),
                        _buildProTab('messages', '💬 Μηνύματα', badge: msgBadge),
                        const SizedBox(width: 6),
                        _buildProTab('minicv', '👤 Mini CV'),
                        const SizedBox(width: 6),
                        _buildProTab('portfolio', '📸 Portfolio'),
                        const SizedBox(width: 6),
                        _buildProTab('rejected', '❌ Απορριφθέντα'),
                        const SizedBox(width: 6),
                        _buildProTab('pending', '📅 Bookings', badge: pendBadge + accBadge),
                      ],
                    ),
                  );
                }, // end rSnap builder
              ); // end requests StreamBuilder
                }, // end chatSnap builder
              ); // end chats StreamBuilder
            },
          ),
          const SizedBox(height: 8),

          // Content list
          Expanded(
            child: _activeTab == 'requests'
                ? _buildRequestsList()
                : _activeTab == 'portfolio'
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
            .doc(proUserId)
            .collection('notifications')
            .add({
          'title': '🔔 Νέο αίτημα${profession.isNotEmpty ? " για $profession" : ""}!',
          'body': '$userName: ${description.length > 80 ? "${description.substring(0, 80)}..." : description}',
          'isRead': false,
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
            const SizedBox(height: 12),
            Text('Δεν υπάρχουν μηνύματα', style: TextStyle(color: _g(0.3), fontSize: 14)),
            const SizedBox(height: 6),
            Text('Όταν ένας χρήστης σου στείλει μήνυμα\nθα εμφανιστεί εδώ.',
                textAlign: TextAlign.center,
                style: TextStyle(color: _g(0.2), fontSize: 12, height: 1.5)),
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
                        side: BorderSide(color: Colors.red.withValues(alpha: 0.3))),
                    title: const Text('Διαγραφή συνομιλίας',
                        style: TextStyle(color: Colors.white, fontFamily: 'Raleway', fontSize: 16)),
                    content: Text('Θέλεις σίγουρα να διαγράψεις τη συνομιλία με $userName;',
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 13)),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dCtx, false),
                          child: const Text('Άκυρο', style: TextStyle(color: Colors.white54))),
                      TextButton(
                          onPressed: () => Navigator.pop(dCtx, true),
                          child: const Text('Διαγραφή', style: TextStyle(color: Colors.red))),
                    ],
                  ),
                ) ?? false;
              },
              onDismissed: (_) => deleteChat(),
              background: Container(
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
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
                            if (d['status'] == 'accepted') ...[
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
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
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
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          itemCount: docs.length,
          itemBuilder: (_, i) {
            final d = docs[i].data() as Map<String, dynamic>;
            final requestId = docs[i].id;
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
        await http.post(
          Uri.parse('$kBackendUrl/booking-response'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'bookingId': bookingId,
            'action': action,
            'proName': _proName ?? '',
            'userEmail': userEmail ?? '',
            'userName': userName ?? '',
            'userFcmToken': userFcmToken ?? '',
          }),
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
                    Row(children: [
                      Container(
                        width: 44, height: 44,
                        decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(13),
                borderRadius: BorderRadius.circular(20),
                color: const Color(0xFF0E0B04),
                border: Border.all(color: kGold.withValues(alpha: 0.2)),
                boxShadow: [BoxShadow(
                    color: kGold.withValues(alpha: 0.06), blurRadius: 16)],
              ),
              child: Column(children: [
                // Top accent line
          itemBuilder: (_, i) {
            // ── Event request card ──
            if (i < _eventReqDocs.length) {
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
      // Increment permanent booking counter on pro's document (admin analytics)
      if (action == 'accept' && _proId != null && _proId!.isNotEmpty) {
        FirebaseFirestore.instance
            .collection('professionals')
            .where('userId', isEqualTo: _proId)
            .limit(1)
            .get()
            .then((snap) {
          for (final d in snap.docs) {
            d.reference.update({'totalBookingsEver': FieldValue.increment(1)});
          }
        }).catchError((_) {});
      }

      String? userEmail;
      String? userName;
      String? userFcmToken;
      if (userId != null) {
        // Get user email + FCM token for the backend call
        try {
          final userDoc = await FirebaseFirestore.instance.collection('users').doc(userId).get();
          userEmail = userDoc.data()?['email'] as String?;
          userName = userDoc.data()?['name'] as String? ?? 'Χρήστης';
          userFcmToken = userDoc.data()?['fcmToken'] as String?;
        } catch (_) {}
      }

      // Backend handles BOTH the push notification AND the in-app Firestore
      // notification in one call — no duplicate writes from the client side.
      try {
        await http.post(
          Uri.parse('$kBackendUrl/booking-response'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'bookingId': bookingId,
            'action': action,
            'proName': _proName ?? '',
            'userEmail': userEmail ?? '',
            'userName': userName ?? '',
            'userFcmToken': userFcmToken ?? '',
          }),
        );
      } catch (_) {}

      if (mounted) {
                child: const Icon(Icons.delete_outline_rounded, color: Colors.red, size: 26),
              ),
              child: GestureDetector(
                onTap: () => Navigator.push(ctx, PageRouteBuilder(
                  pageBuilder: (_, __, ___) => ChatScreen(
                    chatId: chatId,
                    currentUserId: _proId!,
                    currentUserName: _proName ?? 'Επαγγελματίας',
                    otherName: userName,
                    isPro: true,
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
                    Container(width: 46, height: 46,
                      decoration: BoxDecoration(shape: BoxShape.circle,
                          color: kGold.withValues(alpha: 0.12),
                          border: Border.all(color: kGold.withValues(alpha: 0.25))),
                      child: Center(child: Text(
                          userName.isNotEmpty ? userName[0].toUpperCase() : '?',
  Widget _buildProTab(String value, String label, {int badge = 0}) {
    final active = _activeTab == value;
    return GestureDetector(
      onTap: () => setState(() => _activeTab = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: active ? kGold : Colors.transparent,
          border: active ? null : Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: TextStyle(
              fontSize: 12, fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? Colors.black : Colors.white.withValues(alpha: 0.5))),
          if (badge > 0) ...[
            const SizedBox(width: 5),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: active ? Colors.black.withValues(alpha: 0.25) : kGold,
              ),
              child: Text('$badge', style: TextStyle(
                  fontSize: 9, fontWeight: FontWeight.w800,
                  color: active ? Colors.white : Colors.black)),
            ),
          ],
        ]),
      ),
    );
  }

  @override
                                style: const TextStyle(color: Colors.black, fontSize: 17, fontWeight: FontWeight.w900)))),
                  ),
                  // Online dot
                  Positioned(bottom: 1, right: 1,
                    child: Container(width: 10, height: 10,
                        decoration: BoxDecoration(shape: BoxShape.circle,
                            color: _available ? kGreen : Colors.grey,
                            border: Border.all(color: kBg, width: 1.5)))),
                ]),
              ),
            ]),
          ),

          const SizedBox(height: 14),

          // ── Σήμερα Glance Card ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: StreamBuilder<QuerySnapshot>(
              stream: (_proId == null || _proId!.isEmpty) ? const Stream.empty()
                  : FirebaseFirestore.instance.collection('bookings')
                      .where('professionalId', isEqualTo: _proId).snapshots(),
              builder: (context, bookSnap) {
                return StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance.collection('requests')
                      .where('status', isEqualTo: 'active').limit(50).snapshots(),
                  builder: (context, reqSnap) {
                    return StreamBuilder<DocumentSnapshot>(
                      stream: (_proId == null || _proId!.isEmpty) ? const Stream.empty()
                          : FirebaseFirestore.instance.collection('users').doc(_proId).snapshots(),
                      builder: (context, userSnap) {
                        final bookings = bookSnap.data?.docs ?? [];
                        final pendingCount = bookings.where((d) => (d.data() as Map)['status'] == 'pending').length;
                        final acceptedCount = bookings.where((d) => (d.data() as Map)['status'] == 'accepted').length;
                        final reqCount = (reqSnap.data?.docs
                            .where((d) => _proMatchesRequest(d.data() as Map<String, dynamic>))
                            .length ?? 0) + _eventReqDocs.length;
                        final userData = userSnap.data?.data() as Map<String, dynamic>? ?? {};
                        final avg = ((userData['averageRating'] ?? 0.0) as num).toDouble();
                        final reviewCount = ((userData['reviewCount'] ?? 0) as num).toInt();

                        return Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            gradient: LinearGradient(
                              begin: Alignment.topLeft, end: Alignment.bottomRight,
                              colors: [
                                const Color(0xFF1A0E00),
                                kBg,
                                const Color(0xFF001A10).withValues(alpha: 0.6),
                              ],
                            ),
                            border: Border.all(color: kGold.withValues(alpha: 0.2)),
                            boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.06), blurRadius: 20)],
                          ),
                          child: Column(children: [
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
        // Only show requests matching the pro's specialties
        final docs = snap.data!.docs
            .where((d) => _proMatchesRequest(d.data() as Map<String, dynamic>))
            .toList();
        if (docs.isEmpty && _eventReqDocs.isEmpty) {
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

          const SizedBox(height: 10),

          // ══════════════════════════════════════
          // TABS — scrollable pill style
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
                        const SizedBox(width: 6),
                        _buildProTab('messages', '💬 Μηνύματα', badge: msgBadge),
                        const SizedBox(width: 6),
                        _buildProTab('minicv', '👤 Mini CV'),
                        const SizedBox(width: 6),
                        _buildProTab('portfolio', '📸 Portfolio'),
                        const SizedBox(width: 6),
                        _buildProTab('rejected', '❌ Απορριφθέντα'),
                        const SizedBox(width: 6),
                        _buildProTab('pending', '📅 Bookings', badge: pendBadge + accBadge),
                      ],
                    ),
                  );
                }, // end rSnap builder
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
                        const SizedBox(width: 6),
                        _buildProTab('messages', '💬 Μηνύματα', badge: msgBadge),
                        const SizedBox(width: 6),
                        _buildProTab('minicv', '👤 Mini CV'),
                        const SizedBox(width: 6),
                        _buildProTab('portfolio', '📸 Portfolio'),
                        const SizedBox(width: 6),
                        _buildProTab('rejected', '❌ Απορριφθέντα'),
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
    // Network error — fallback στη Firestore
    await _submitOfferFallback(requestId, price, message, available);
  }
}

                      .length ?? 0;
                  final pendingEvents = _eventReqDocs.where((doc) {
                    if (_submittedIds.contains(doc.id)) return false;
                    final ev = doc.data() as Map<String, dynamic>;
                    final subPros = List<String>.from(ev['submittedPros'] ?? []);
                    return !subPros.contains(_proId ?? '');
                  }).length;
                  final reqBadge = matchingReqs + pendingEvents;
                  return SizedBox(
                    height: 42,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        _buildProTab('requests', '📋 Αιτήματα', badge: reqBadge),
                        const SizedBox(width: 6),
                        _buildProTab('messages', '💬 Μηνύματα', badge: msgBadge),
                        const SizedBox(width: 6),
                        _buildProTab('minicv', '👤 Mini CV'),
                        const SizedBox(width: 6),
                        _buildProTab('portfolio', '📸 Portfolio'),
                        const SizedBox(width: 6),
                        _buildProTab('rejected', '❌ Απορριφθέντα'),
                        const SizedBox(width: 6),
                        _buildProTab('pending', '📅 Bookings', badge: pendBadge + accBadge),
                      ],
                    ),
                  );
                }, // end rSnap builder
              ); // end requests StreamBuilder
                }, // end chatSnap builder
              ); // end chats StreamBuilder
            },
                stream: FirebaseFirestore.instance.collection('requests')
                    .where('status', isEqualTo: 'active').limit(50).snapshots(),
                builder: (context, rSnap) {
                  final matchingReqs = rSnap.data?.docs
                      .where((doc) {
                        final d = doc.data() as Map<String, dynamic>;
                        if (!_proMatchesRequest(d)) return false;
                        // Exclude already-submitted requests
                        if (_submittedIds.contains(doc.id)) return false;
                        final subPros = List<String>.from(d['submittedPros'] ?? []);
                        if (subPros.contains(_proId ?? '')) return false;
                        return true;
                      })
                      .length ?? 0;
                  final pendingEvents = _eventReqDocs.where((doc) {
              // Status filtering done in-code to avoid Firestore composite index requirement
              stream: (_proId == null || _proId!.isEmpty)
                  ? const Stream.empty()
                  : FirebaseFirestore.instance
                      .collection('bookings')
                      .where('professionalId', isEqualTo: _proId)
                      .snapshots(),
              builder: (context, snap) {
                if (snap.hasError)
                        if (!_proMatchesRequest(d)) return false;
                        // Exclude already-submitted requests
                        if (_submittedIds.contains(doc.id)) return false;
                        final subPros = List<String>.from(d['submittedPros'] ?? []);
                        if (subPros.contains(_proId ?? '')) return false;
                        return true;
                      })
                      .length ?? 0;
                  final pendingEvents = _eventReqDocs.where((doc) {
                    if (_submittedIds.contains(doc.id)) return false;
                    final ev = doc.data() as Map<String, dynamic>;
                    final subPros = List<String>.from(ev['submittedPros'] ?? []);
                    return !subPros.contains(_proId ?? '');
                  }).length;
                  final reqBadge = matchingReqs + pendingEvents;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(children: [
                      Row(children: [
                        Expanded(child: _buildNavCard('requests', '📋', 'Αιτήματα',
                            reqBadge > 0 ? '$reqBadge νέα' : 'Ενεργά αιτήματα', badge: reqBadge)),
                        const SizedBox(width: 8),
                        Expanded(child: _buildNavCard('messages', '💬', 'Μηνύματα',
                            msgBadge > 0 ? '$msgBadge αδιάβαστα' : 'Συνομιλίες', badge: msgBadge)),
                      ]),
                      const SizedBox(height: 8),
                      Row(children: [
                        Expanded(child: _buildNavCard('minicv', '👤', 'Mini CV', 'Βιογραφικό')),
                        const SizedBox(width: 8),
                        Expanded(child: _buildNavCard('portfolio', '📸', 'Portfolio', 'Φωτογραφίες')),
                      ]),
                      const SizedBox(height: 8),
                      Row(children: [
                        Expanded(child: _buildNavCard('pending', '📅', 'Bookings',
                            (pendBadge + accBadge) > 0 ? '${pendBadge + accBadge} εκκρεμή' : 'Κρατήσεις',
                            badge: pendBadge + accBadge)),
                        const SizedBox(width: 8),
                        Expanded(child: _buildNavCard('rejected', '❌', 'Απορριφθέντα', 'Ιστορικό')),
                      ]),
                                fontWeight: FontWeight.w700, color: Colors.white)),
                        const SizedBox(height: 3),
                        Row(children: [
                          if (profession.isNotEmpty) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
            },
          ),
          const SizedBox(height: 8),

          // Content list
          Expanded(
            child: _activeTab == 'requests'
                ? _buildRequestsList()
                : _activeTab == 'portfolio'
                    ? ProPortfolioUploadScreen(proId: _proId ?? '', proName: _proName ?? '')
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
          return const Center(child: CircularProgressIndicator(color: kGold));
        }
        // Only show requests matching the pro's specialties
        final docs = snap.data!.docs
            .where((d) => _proMatchesRequest(d.data() as Map<String, dynamic>))
            .toList();
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
        // Combined list: event requests first (purple), then regular
        final totalItems = _eventReqDocs.length + docs.length;
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          itemCount: totalItems,
          itemBuilder: (_, i) {
            // ── Event request card ──
            if (i < _eventReqDocs.length) {
              final evDoc = _eventReqDocs[i];
              final ev = evDoc.data() as Map<String, dynamic>;
              final eventId = evDoc.id;
              final evAlreadySubmitted = _submittedIds.contains(eventId) ||
                  List<String>.from(ev['submittedPros'] ?? []).contains(_proId ?? '');
              final evOffersCount = ev['offersCount'] as int? ?? 0;
              String dateStr = '';
              try {
                if ((ev['date'] as String? ?? '').isNotEmpty) {
                  final d2 = DateTime.parse(ev['date'] as String);
                  dateStr = '${d2.day}/${d2.month}/${d2.year}';
                }
              } catch (_) {}
              return Container(
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: const Color(0xFF0A0814),
                  border: Border.all(color: const Color(0xFF7C3AED).withValues(alpha: 0.4)),
                  boxShadow: [BoxShadow(color: const Color(0xFF7C3AED).withValues(alpha: 0.1), blurRadius: 16)],
                ),
                child: Column(children: [
                  Container(height: 2,
                    decoration: BoxDecoration(
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                      gradient: LinearGradient(colors: [
                        const Color(0xFF7C3AED).withValues(alpha: 0.0),
                        const Color(0xFF7C3AED).withValues(alpha: 0.9),
                        const Color(0xFF7C3AED).withValues(alpha: 0.0),
                      ]),
                    ),
                  ),
                  Padding(
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
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.location_on_outlined, color: Colors.blueAccent.withValues(alpha: 0.7), size: 16),
                const SizedBox(width: 8),
                Text('Πρόσθεσε περιοχές εξυπηρέτησης',
                    style: TextStyle(color: Colors.blueAccent.withValues(alpha: 0.7), fontSize: 13)),
              ]),
            ),
          )
        else
          Wrap(spacing: 8, runSpacing: 8, children: _areas.map((a) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: Colors.blue.withValues(alpha: 0.08),
              border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.3)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.location_on, color: Colors.blueAccent.withValues(alpha: 0.8), size: 12),
              const SizedBox(width: 4),
              Text(a, style: TextStyle(color: Colors.blueAccent.withValues(alpha: 0.9), fontSize: 12, fontWeight: FontWeight.w600)),
            ]),
          )).toList()),

        const SizedBox(height: 22),

        // ── Εμπειρία placeholder ──────────────────────────
        const _MiniCvSection(label: 'ΕΜΠΕΙΡΙΑ'),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: _g(0.03),
            border: Border.all(color: _g(0.07)),
          ),
          child: Row(children: [
            Container(width: 36, height: 36,
                decoration: BoxDecoration(shape: BoxShape.circle, color: kGold.withValues(alpha: 0.1)),
                child: const Center(child: Text('💼', style: TextStyle(fontSize: 16)))),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Αυτόνομος Επαγγελματίας',
                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
              Text('2016 – σήμερα · Αθήνα', style: TextStyle(color: _g(0.4), fontSize: 11)),
            ])),
          ]),
        ),

      ]),
    );
  }

  // ── Helper chip for event details ──
  Widget _eventInfoChip(String icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: const Color(0xFF7C3AED).withValues(alpha: 0.1),
        border: Border.all(color: const Color(0xFF7C3AED).withValues(alpha: 0.2)),
      ),
      child: Text('$icon $label',
          style: const TextStyle(color: Color(0xFFBB86FC), fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }

  // ── Requests list για επαγγελματίες ──
  Widget _buildRequestsList() {
    if (_proName == null || _proName!.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: kGold));
    }
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
      'emoji': '🔧',
      if (_proPhotoUrl != null) 'profilePhotoUrl': _proPhotoUrl,
      'createdAt': FieldValue.serverTimestamp(),
    });

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
                              ? 'Instagram & TikTok συνδεδεμένα'
                              : 'Σύνδεσε Instagram & TikTok',
                          iconColor: const Color(0xFFE1306C)),
                    ]),
                  );
                }, // end rSnap builder
              ); // end requests StreamBuilder
                }, // end chatSnap builder
              ); // end chats StreamBuilder
            },
          ),
          const SizedBox(height: 8),

          // Content list — visible only when a section is open
          if (!_showGrid) ...[
            // Back button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: GestureDetector(
                onTap: () => setState(() { _showGrid = true; _activeTab = ''; }),
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
  // ── Premium Tab ──
  Widget _buildPremiumTab() {
    return StreamBuilder<DocumentSnapshot>(
      stream: (_proId == null || _proId!.isEmpty)
          ? const Stream.empty()
          : FirebaseFirestore.instance.collection('users').doc(_proId).snapshots(),
      builder: (ctx, snap) {
        bool isPremium = false;
        if (snap.hasData && snap.data!.exists) {
          final d = snap.data!.data() as Map<String, dynamic>?;
          isPremium = d?['isPremium'] == true || d?['isOwner'] == true;
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Status card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: isPremium
                    ? const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                        colors: [Color(0xFF3D2C00), Color(0xFF1A1200)])
                    : null,
                color: isPremium ? null : _g(0.04),
                border: Border.all(color: isPremium ? kGold.withValues(alpha: 0.6) : _g(0.1)),
        // ── Determine price tier ──
        final mainSpec = (_proSpecialty ?? '').toLowerCase();
        final allSpecs = [mainSpec, ..._specialties.map((s) => s.toLowerCase())];
        final isBusiness = allSpecs.any((s) => s.contains('συνεργείο'));
        final isEventPro = allSpecs.any((s) => _kEventSpecialties.contains(s));
        final isHighTier = isBusiness || isEventPro;
        final priceStr = isHighTier ? '59,99' : '19,99';
        final tierLabel = isHighTier ? 'Επαγγελματικό' : 'Βασικό';
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Status card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: isPremium
                    ? const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                        colors: [Color(0xFF3D2C00), Color(0xFF1A1200)])
                    : null,
                color: isPremium ? null : _g(0.04),
                border: Border.all(color: isPremium ? kGold.withValues(alpha: 0.6) : _g(0.1)),
                boxShadow: isPremium ? [BoxShadow(color: kGold.withValues(alpha: 0.15), blurRadius: 24)] : null,
              ),
              child: Column(children: [
                Text(isPremium ? '👑' : '💎', style: const TextStyle(fontSize: 40)),
                const SizedBox(height: 10),
                Text(isPremium ? 'Premium Επαγγελματίας' : 'Αναβάθμιση σε Premium',
                    style: TextStyle(
                        color: isPremium ? kGold : _gw,
                        fontSize: 18, fontWeight: FontWeight.w800,
                        fontFamily: 'Raleway')),
                const SizedBox(height: 8),
                Text(isPremium
                    ? 'Έχεις πρόσβαση σε όλα τα αιτήματα και προβολή κορυφαίας θέσης.'
                    : 'Πάρε περισσότερους πελάτες με προβολή κορυφαίας θέσης και απεριόριστα αιτήματα.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: _g(0.55), fontSize: 13, height: 1.5)),
              ]),
            ),
            const SizedBox(height: 20),
            // Features list
            ...([
              ('🔔', 'Απεριόριστα αιτήματα', 'Βλέπεις όλα τα ενεργά αιτήματα χρηστών'),
              ('📍', 'Κορυφαία θέση', 'Εμφανίζεσαι πρώτος στα αποτελέσματα'),
              ('📊', 'Αναλυτικά στατιστικά', 'Δες κλικ, views και ποσοστό μετατροπής'),
              ('⭐', 'Σήμα Premium', 'Διακριτικό verified badge στο προφίλ σου'),
              ('📩', 'Άμεση επικοινωνία', 'Οι πελάτες βλέπουν το τηλέφωνό σου απευθείας'),
            ].map((f) => Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: _g(0.04),
                border: Border.all(color: isPremium ? kGold.withValues(alpha: 0.2) : _g(0.08)),
              ),
              child: Row(children: [
                Text(f.$1, style: const TextStyle(fontSize: 20)),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(f.$2, style: TextStyle(color: _gw, fontSize: 13, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(f.$3, style: TextStyle(color: _g(0.45), fontSize: 11)),
                ])),
                if (isPremium)
                  Icon(Icons.check_circle_rounded, color: kGold, size: 18),
              ]),
            ))),
            const SizedBox(height: 24),
            if (!isPremium) ...[
              // Price card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: _g(0.04),
                  border: Border.all(color: kGold.withValues(alpha: 0.25)),
                ),
                child: Row(children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Πλάνο $tierLabel',
                        style: TextStyle(color: _g(0.5), fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
                    const SizedBox(height: 4),
                    Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text('€$priceStr',
                          style: const TextStyle(color: kGold, fontSize: 28,
                              fontWeight: FontWeight.w900, fontFamily: 'Raleway')),
                      const SizedBox(width: 4),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text('/μήνα', style: TextStyle(color: _g(0.45), fontSize: 12)),
                      ),
                    ]),
                  ])),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
          )
        else
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: _g(0.04),
              border: Border.all(color: kGold.withValues(alpha: 0.25)),
            ),
            child: TextField(
              controller: _bioCtrl,
              maxLines: 6,
              maxLength: 600,
              style: TextStyle(color: _g(0.85), fontSize: 13, height: 1.6),
              decoration: InputDecoration(
                hintText: 'Εμπειρία, περιοχές εξυπηρέτησης, τιμές, διαθεσιμότητα...',
                hintStyle: TextStyle(color: _g(0.3), fontSize: 12),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.all(14),
                counterStyle: TextStyle(color: _g(0.25), fontSize: 10),
              ),
            ),
          ),
        if (_bioEditMode || _bio.isEmpty) ...[
          const SizedBox(height: 10),
          GestureDetector(
            onTap: _savingBio ? null : _saveBio,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 13),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(13),
                gradient: _savingBio
                    ? LinearGradient(colors: [_g(0.1), _g(0.1)])
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
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.location_on_outlined, color: Colors.blueAccent.withValues(alpha: 0.7), size: 16),
                const SizedBox(width: 8),
                Text('Πρόσθεσε περιοχές εξυπηρέτησης',
                    style: TextStyle(color: Colors.blueAccent.withValues(alpha: 0.7), fontSize: 13)),
              ]),
            ),
          )
        else
  }) async {
    try {
      // Wait 5s so backend's Firestore trigger fires first — then we overwrite it
      await Future.delayed(const Duration(seconds: 5));

      // Query 1: new-style professionals (have 'specialties' array)
      // Query 2: old-style professionals (have only 'specialty' string)
      // Merge results, deduplicate by userId, then post-filter by area.
      final db = FirebaseFirestore.instance;
      final baseQ = db.collection('professionals').where('is_active', isEqualTo: true);

      QuerySnapshot<Map<String, dynamic>> snap1;
      QuerySnapshot<Map<String, dynamic>> snap2;
      if (profession.isNotEmpty) {
        // New pros: specialties arrayContains profession
        snap1 = await baseQ.where('specialties', arrayContains: profession).get();
        // Old pros: specialty == profession
        snap2 = await baseQ.where('specialty', isEqualTo: profession).get();
      } else {
        snap1 = await baseQ.get();
        snap2 = await baseQ.limit(0).get(); // empty
      }

      // Merge + deduplicate by document ID
      final allDocs = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
      for (final d in [...snap1.docs, ...snap2.docs]) { allDocs[d.id] = d; }

      // Post-filter by area (supports both 'area' string and 'areas' array)
      final filtered = allDocs.values.where((doc) {
        if (location.isEmpty || location == 'Κοντά μου') return true;
        final d = doc.data();
        final areas = d['areas'];
        if (areas is List && areas.contains(location)) return true;
        final area = d['area'] as String? ?? '';
        return area == location;
      }).toList();

      int notified = 0;
      final notifiedProIds = <String>[];
      for (final doc in filtered) {
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
                        final v = await showModalBottomSheet<String>(
                          context: context,
                          backgroundColor: Colors.transparent,
                          isScrollControlled: true,
                          builder: (_) => _SimpleListPicker(
                            title: '🔨 Είδος επαγγελματία',
                            items: const [
                              'Συνεργείο Ανακαίνισης', 'Συνεργείο Κατασκευών', 'Συνεργείο Βαφής & Διακόσμησης',
                              'Συνεργείο Ηλεκτρολόγων', 'Συνεργείο Υδραυλικών', 'Συνεργείο Κλιματισμού',
                              'Ηλεκτρολόγος', 'Υδραυλικός', 'Ψυκτικός', 'Ελαιοχρωματιστής',
                              'Μηχανικός', 'Κτίστης', 'Ξυλουργός', 'Υαλουργός',
                              'Τεχνικός Ανελκυστήρων', 'Αποφράξεις', 'Αλουμινάς', 'Πλακάς',
                              'Συντήρηση Κλιματιστικών', 'Εγκατάσταση Ηλιακών',
                              'Παθολόγος', 'Παιδίατρος', 'Οδοντίατρος', 'Φυσιοθεραπευτής',
                              'Ψυχολόγος', 'Διατροφολόγος', 'Καθαρίστρια', 'Κηπουρός',
                              'Baby Sitter', 'Μετακομίσεις', 'Καθηγητής Μαθηματικών',
                              'Καθηγητής Αγγλικών', 'Personal Trainer', 'Web Developer',
                              'Γραφίστας', 'Φωτογράφος', 'Τεχνικός Υπολογιστών',
                              'Μηχανικός Αυτοκινήτων', 'Λογιστής', 'Δικηγόρος', 'Αρχιτέκτονας',
                            ],
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
    if (_secondsLeft >= 3600) {
      final h = (_secondsLeft ~/ 3600).toString().padLeft(2, '0');
      final m = ((_secondsLeft % 3600) ~/ 60).toString().padLeft(2, '0');
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
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 500),
          pageBuilder: (_, __, ___) => OffersScreen(
              requestId: widget.requestId,
        ),

      ]),
    );
  }

  // ── Helper chip for event details ──
  Widget _eventInfoChip(String icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: const Color(0xFF7C3AED).withValues(alpha: 0.1),
        border: Border.all(color: const Color(0xFF7C3AED).withValues(alpha: 0.2)),
      ),
      child: Text('$icon $label',
          style: const TextStyle(color: Color(0xFFBB86FC), fontSize: 11, fontWeight: FontWeight.w600)),
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
        // Only show requests matching the pro's specialties
        final docs = snap.data!.docs
            .where((d) => _proMatchesRequest(d.data() as Map<String, dynamic>))
            .toList();
        if (docs.isEmpty && _eventReqDocs.isEmpty) {
                        boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.45), blurRadius: 20, spreadRadius: 2)],
                      ),
                      child: const Center(
                        child: Text('Δες τις Προσφορές →',
                            style: TextStyle(

  @override
  Widget build(BuildContext context) {
    // ── OFFERS READY — inline screen (no dialog, cannot be lost) ──
    if (_offersReady) {
      return PopScope(
        canPop: false,
        child: Scaffold(
          backgroundColor: kBg,
          body: SafeArea(
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: Row(children: [
              // Back button hidden when offers are ready
              if (!_offersReady && _secondsLeft > 0)
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
// OFFERS READY SCREEN — standalone, cannot be accidentally popped
// ════════════════════════════════════════════════
class OffersReadyScreen extends StatelessWidget {
  final String requestId;
  final String userId;
  final String description;
  final String criteria;
  final int offersCount;
  final String collection;
  const OffersReadyScreen({
    super.key,
    required this.requestId,
    required this.userId,
          },
        );
      },
    );
  }

  // ── Premium Tab ──
  Widget _buildPremiumTab() {
    return StreamBuilder<DocumentSnapshot>(
      stream: (_proId == null || _proId!.isEmpty)
          ? const Stream.empty()
          : FirebaseFirestore.instance.collection('users').doc(_proId).snapshots(),
      builder: (ctx, snap) {
        bool isPremium = false;
        if (snap.hasData && snap.data!.exists) {
          final d = snap.data!.data() as Map<String, dynamic>?;
          isPremium = d?['isPremium'] == true || d?['isOwner'] == true;
        }
        // ── Determine price tier ──
        final mainSpec = (_proSpecialty ?? '').toLowerCase();
        final allSpecs = [mainSpec, ..._specialties.map((s) => s.toLowerCase())];
        final isBusiness = allSpecs.any((s) => s.contains('συνεργείο'));
        final isEventPro = allSpecs.any((s) => _kEventSpecialties.contains(s));
        final isHighTier = isBusiness || isEventPro;
        final priceStr = isHighTier ? '59,99' : '19,99';
        final tierLabel = isHighTier ? 'Επαγγελματικό' : 'Βασικό';
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Status card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: isPremium
                    ? const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                        colors: [Color(0xFF3D2C00), Color(0xFF1A1200)])
                    : null,
                color: isPremium ? null : _g(0.04),
                border: Border.all(color: isPremium ? kGold.withValues(alpha: 0.6) : _g(0.1)),
                boxShadow: isPremium ? [BoxShadow(color: kGold.withValues(alpha: 0.15), blurRadius: 24)] : null,
              ),
              child: Column(children: [
                Text(isPremium ? '👑' : '💎', style: const TextStyle(fontSize: 40)),
                const SizedBox(height: 10),
                Text(isPremium ? 'Premium Επαγγελματίας' : 'Αναβάθμιση σε Premium',
                    style: TextStyle(
                        color: isPremium ? kGold : _gw,
                        fontSize: 18, fontWeight: FontWeight.w800,
                        fontFamily: 'Raleway')),
                const SizedBox(height: 8),
                Text(isPremium
                    ? 'Η μηνιαία σου συνδρομή είναι ενεργή.'
                    : 'Μηνιαία συνδρομή.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: _g(0.55), fontSize: 13, height: 1.5)),
              ]),
            ),
            const SizedBox(height: 24),
            if (!isPremium) ...[
              // Price card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: _g(0.04),
                  border: Border.all(color: kGold.withValues(alpha: 0.25)),
                ),
                child: Row(children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Πλάνο $tierLabel',
                        style: TextStyle(color: _g(0.5), fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
                    const SizedBox(height: 4),
                    Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text('€$priceStr',
                          style: const TextStyle(color: kGold, fontSize: 28,
                              fontWeight: FontWeight.w900, fontFamily: 'Raleway')),
                      const SizedBox(width: 4),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text('/μήνα', style: TextStyle(color: _g(0.45), fontSize: 12)),
                      ),
                    ]),
                  ])),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color: kGold.withValues(alpha: 0.1),
                      border: Border.all(color: kGold.withValues(alpha: 0.3)),
                    ),
                    child: Text(isHighTier ? '🏢 Επιχείρηση' : '👤 Μονάδα',
                        style: const TextStyle(color: kGold, fontSize: 11, fontWeight: FontWeight.w700)),
                  ),
                ]),
              ),
              const SizedBox(height: 12),
              GestureDetector(
                onTap: () => Navigator.push(context, PageRouteBuilder(
                  pageBuilder: (_, __, ___) => const ProfileScreen(),
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
                  child: Center(child: Text('💎 Γίνε Premium — €$priceStr/μήνα',
                      style: const TextStyle(color: Colors.black, fontSize: 15,
                          fontWeight: FontWeight.w800, fontFamily: 'Raleway'))),
                ),
              ),
            ]
            else
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: kGold.withValues(alpha: 0.08),
                  border: Border.all(color: kGold.withValues(alpha: 0.3)),
                ),
                child: const Center(child: Text('✅ Είσαι Premium Επαγγελματίας',
                    style: TextStyle(color: kGold, fontSize: 14, fontWeight: FontWeight.w700))),
              ),
          ]),
        );
      },
    );
  }

  // ── Social Media tab ──
  Widget _buildSocialTab() {
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: const Color(0xFF0A0814),
                  border: Border.all(color: const Color(0xFF7C3AED).withValues(alpha: 0.4)),
                  boxShadow: [BoxShadow(color: const Color(0xFF7C3AED).withValues(alpha: 0.1), blurRadius: 16)],
                ),
                child: Column(children: [
                  Container(height: 2,
                    decoration: BoxDecoration(
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                      gradient: LinearGradient(colors: [
                        const Color(0xFF7C3AED).withValues(alpha: 0.0),
                        const Color(0xFF7C3AED).withValues(alpha: 0.9),
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

                    // Images & Videos
                    if ((d['hasImages'] == true || (d['imageCount'] ?? 0) > 0)) ...[
                      const SizedBox(height: 10),
                      _RequestImageGallery(requestData: d, requestId: requestId),
                    ],
                    if (d['hasVideos'] == true) ...[
                      const SizedBox(height: 8),
                      if ((d['videoUrls'] as List?)?.isNotEmpty == true) ...[
                        // Clickable video links
                        ...((d['videoUrls'] as List).asMap().entries.map((e) =>
                          GestureDetector(
                            onTap: () => launchUrl(Uri.parse(e.value as String), mode: LaunchMode.externalApplication),
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 6),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                color: kGold.withValues(alpha: 0.08),
                                border: Border.all(color: kGold.withValues(alpha: 0.3)),
                              ),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                const Icon(Icons.play_circle_outline, color: kGold, size: 16),
                                const SizedBox(width: 6),
                                Text('▶ Βίντεο ${e.key + 1} — πάτα για προβολή',
                                    style: const TextStyle(color: kGold, fontSize: 11, fontWeight: FontWeight.w600)),
                              ]),
                            ),
                          )
                        )),
                      ] else ...[
                        Row(children: [
                          const Icon(Icons.videocam, color: kGold, size: 14),
                          const SizedBox(width: 4),
                          Text('Βίντεο (ανεβαίνει...)',
                              style: TextStyle(color: _g(0.5), fontSize: 11, fontStyle: FontStyle.italic)),
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
          SnackBar(content: Text('Σφάλμα επιλογής βίντεο: $e')));
    }
  }

  bool _submitLock = false;  // Guard κατά double submit

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
          .collection('requests')
          .where('userId', isEqualTo: user.uid)
          .where('status', isEqualTo: 'active')
          .get();
      if (existing.docs.length >= 2) {
              userId: widget.userId,
              description: _textCtrl.text.trim(),
              criteria: _selectedCriteria,
              profession: _selectedProfession ?? '',
            ),
            transitionsBuilder: (_, a, __, c) =>
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
          if (bytes.isNotEmpty) {
            videoData.add((name: vid.name, bytes: bytes, mime: vid.mimeType ?? 'video/mp4'));
          } else {
            debugPrint('Video readAsBytes() returned empty: ${vid.name}');
          }
        } catch (e) {
          debugPrint('Video readAsBytes() error: $e');
        }
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
          final videoUrls = <String>[];
          for (int i = 0; i < videoData.length; i++) {
            final v = videoData[i];
            try {
              if (v.bytes.isEmpty) continue;
              final ext = v.mime.contains('mp4') ? 'mp4'
                  : v.mime.contains('webm') ? 'webm'
                  : v.mime.contains('quicktime') ? 'mov' : 'mp4';
              final contentType = v.mime.isNotEmpty ? v.mime : 'video/mp4';
              final fileName = 'video_${i}_${DateTime.now().millisecondsSinceEpoch}.$ext';
              // Use firebase_storage SDK (handles CORS on web automatically)
              final storageRef = FirebaseStorage.instance
                  .ref('requests/$requestDocId/videos/$fileName');
              await storageRef.putData(
                v.bytes,
                SettableMetadata(contentType: contentType),
              );
              final url = await storageRef.getDownloadURL();
              videoUrls.add(url);
            } catch (e) {
              debugPrint('Video upload error [$i]: $e');
            }
          }
          if (videoUrls.isNotEmpty) {
            await FirebaseFirestore.instance
                .collection('requests')
  final int offersCount;
  final String collection;
  // Called when user closes without selecting (overlay mode).
  // When null, falls back to Navigator.pop() for any remaining push-based uses.
  final VoidCallback? onDismiss;
  const OffersReadyScreen({
    super.key,
    required this.requestId,
    required this.userId,
    required this.description,
    required this.criteria,
    required this.offersCount,
    this.collection = 'requests',
    this.onDismiss,
  });

  Future<void> _goToOffers(BuildContext context) async {
              for (int i = 0; i < 3; i++) {
                final reqSnap = await FirebaseFirestore.instance

  void _showOfferDialog(String requestId, Map<String, dynamic> requestData) {
    final priceCtrl = TextEditingController();
    final msgCtrl = TextEditingController();
    String available = 'Αύριο';
    showDialog(
      context: context,
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
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Μπορείς να έχεις μέχρι 2 ενεργά αιτήματα!')));
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
        'profession': _selectedProfession ?? '',
        'location': _selectedLocation ?? '',
        'status': 'active',
        'offersCount': 0,
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
      'specialty': _proSpecialty ?? '',
      'price': price,
      'message': message,
      'availableFrom': available,
      'rating': 4.8,
                if (i < 2) await Future.delayed(const Duration(seconds: 5));
              }
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
    try {
      final video = await _picker.pickVideo(source: source);
      if (video == null) return;
      // video.length() can throw on Flutter Web for blob URLs — skip check if it fails
      try {
        final size = await video.length();
        if (size > 100 * 1024 * 1024) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Το βίντεο είναι πολύ μεγάλο (max 100 MB)')));
          return;
        }
      } catch (_) { /* on web, length() may not be available — skip size check */ }
      if (mounted) setState(() => _videoFiles.add(video));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
      // Merge results, deduplicate by userId, then post-filter by area.
      final db = FirebaseFirestore.instance;
      final baseQ = db.collection('professionals').where('is_active', isEqualTo: true);

      QuerySnapshot<Map<String, dynamic>> snap1;
      QuerySnapshot<Map<String, dynamic>> snap2;
      if (profession.isNotEmpty) {
        // New pros: specialties arrayContains profession
        snap1 = await baseQ.where('specialties', arrayContains: profession).get();
        // Old pros: specialty == profession
        snap2 = await baseQ.where('specialty', isEqualTo: profession).get();
      } else {
        snap1 = await baseQ.get();
        snap2 = await baseQ.limit(0).get(); // empty
      }

      // Merge + deduplicate by document ID
      final allDocs = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
      for (final d in [...snap1.docs, ...snap2.docs]) { allDocs[d.id] = d; }

      // Post-filter by area AND availability
      final filtered = allDocs.values.where((doc) {
        final d = doc.data();
        // Skip pros who turned off availability
        if (d['available'] == false) return false;
        if (location.isEmpty || location == 'Κοντά μου') return true;
        final areas = d['areas'];
        if (areas is List && areas.contains(location)) return true;
        final area = d['area'] as String? ?? '';
        return area == location;
      }).toList();

      int notified = 0;
      final notifiedProIds = <String>[];
      for (final doc in filtered) {
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
          'hasVideos': hasVideos,
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
            return InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: Center(
                child: Image.network(url, fit: BoxFit.contain,
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
    int imageCount, {
    bool hasVideos = false,
  }) async {
    try {
      // Wait 5s so backend's Firestore trigger fires first — then we overwrite it
      await Future.delayed(const Duration(seconds: 5));

      // Query 1: new-style professionals (have 'specialties' array)
      // Query 2: old-style professionals (have only 'specialty' string)
      // Merge results, deduplicate by userId, then post-filter by area.
      final db = FirebaseFirestore.instance;
      final baseQ = db.collection('professionals').where('is_active', isEqualTo: true);

      QuerySnapshot<Map<String, dynamic>> snap1;
      QuerySnapshot<Map<String, dynamic>> snap2;
      if (profession.isNotEmpty) {
        // New pros: specialties arrayContains profession
        snap1 = await baseQ.where('specialties', arrayContains: profession).get();
        // Old pros: specialty == profession
        snap2 = await baseQ.where('specialty', isEqualTo: profession).get();
      } else {
        snap1 = await baseQ.get();
        snap2 = await baseQ.limit(0).get(); // empty
      }
        'availableFrom': available,
        'rating': 4.8,
        'emoji': '🔧',
        if (_proPhotoUrl != null) 'profilePhotoUrl': _proPhotoUrl,
        'specialty': _proSpecialty ?? '',
      }),
    ).timeout(const Duration(seconds: 8));
        final d = doc.data();
        // Skip pros who turned off availability
        if (d['available'] == false) return false;
        if (location.isEmpty || location == 'Κοντά μου') return true;
        final areas = d['areas'];
        if (areas is List && areas.contains(location)) return true;
        final area = d['area'] as String? ?? '';
        return area == location;
      }).toList();

      int notified = 0;
      final notifiedProIds = <String>[];
      for (final doc in filtered) {
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
          'hasVideos': hasVideos,
          'createdAt': FieldValue.serverTimestamp(),
        });
        // Also send FCM push notification to this pro
        try {
          final proUserDoc = await db.collection('users').doc(proUserId).get();
          final fcmToken = proUserDoc.data()?['fcmToken'] as String?;
          final proDisplayName = (doc.data()['displayName'] ?? doc.data()['name'] ?? '') as String;
          if (fcmToken != null && fcmToken.isNotEmpty) {
            await http.post(
              Uri.parse('$kBackendUrl/notify-new-request'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'fcmToken': fcmToken,
                'proName': proDisplayName,
                'userName': userName,
                'description': description,
                'profession': profession,
              }),
            );
          }
        } catch (e) {
          debugPrint('FCM push to pro $proUserId error: $e');
        }
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
    }
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
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
      }
    }
    if (mounted) setState(() => _uploading = false);
  }

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
    bool priceOnSite = false;
    showDialog(
      context: context,
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
              // Τιμή
              Opacity(
                opacity: priceOnSite ? 0.35 : 1.0,
                child: TextField(
                  controller: priceCtrl,
                  enabled: !priceOnSite,
                  keyboardType: TextInputType.number,
                  style: TextStyle(color: _gw, fontSize: 22, fontWeight: FontWeight.w800),
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    hintText: 'Π.χ. 120',
                    hintStyle: TextStyle(color: _g(0.2), fontSize: 16),
                    suffixText: '€',
                    suffixStyle: const TextStyle(color: kGold, fontSize: 18),
                    filled: true, fillColor: _g(0.05),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: kGold.withValues(alpha: 0.3))),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: kGold.withValues(alpha: 0.3))),
                    disabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: _g(0.1))),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: kGold)),
                    labelText: 'Τιμή σου',
                    labelStyle: const TextStyle(color: kGold, fontSize: 12),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              // Toggle switch "Θα δώσω τιμή μετά από αυτοψία"
              GestureDetector(
                onTap: () => setS(() {
                  priceOnSite = !priceOnSite;
                  if (priceOnSite) priceCtrl.clear();
                }),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: priceOnSite ? kGold.withValues(alpha: 0.1) : _g(0.04),
                    border: Border.all(
                        color: priceOnSite ? kGold.withValues(alpha: 0.4) : _g(0.1)),
                  ),
                  child: Row(children: [
                    Transform.scale(
                      scale: 0.85,
                      child: Switch(
                        value: priceOnSite,
                        onChanged: (v) => setS(() {
                          priceOnSite = v;
                          if (v) priceCtrl.clear();
                        }),
                        activeColor: kGold,
                        activeTrackColor: kGold.withValues(alpha: 0.3),
                        inactiveThumbColor: _g(0.4),
                        inactiveTrackColor: _g(0.1),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Θα δώσω τιμή μετά από αυτοψία',
                            style: TextStyle(
                                color: priceOnSite ? kGold : _gw,
                                fontSize: 12, fontWeight: FontWeight.w600)),
                        Text('Η προσφορά θα σταλεί χωρίς συγκεκριμένη τιμή',
                            style: TextStyle(color: _g(0.4), fontSize: 10)),
                      ],
                    )),
                  ]),
                ),
              ),
              const SizedBox(height: 12),
              // Διαθεσιμότητα
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Διαθέσιμος:', style: TextStyle(fontSize: 11, color: _g(0.5))),
                const SizedBox(height: 6),
                Row(children: [
                  // Σήμερα
                  ...['Σήμερα', 'Αύριο'].map((a) =>
                    GestureDetector(
                      onTap: () => setS(() => available = a),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        margin: const EdgeInsets.only(right: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                        decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            color: available == a
                                ? kGold.withValues(alpha: 0.2) : _g(0.05),
                            border: Border.all(
                                color: available == a ? kGold : _g(0.12))),
                        child: Text(a, style: TextStyle(
                            fontSize: 12,
                            color: available == a ? kGold : _g(0.4))),
                      ),
                    )
                  ),
                  // Επέλεξε ημερομηνία
                  Expanded(
                    child: GestureDetector(
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: ctx,
                          initialDate: DateTime.now().add(const Duration(days: 2)),
                          firstDate: DateTime.now(),
                          lastDate: DateTime.now().add(const Duration(days: 60)),
                          builder: (context, child) => Theme(
                            data: ThemeData.dark().copyWith(
                              colorScheme: const ColorScheme.dark(
                                primary: kGold, onPrimary: Colors.black,
                                surface: Color(0xFF1A1200), onSurface: Colors.white,
                              ),
                            ),
                            child: child!,
                          ),
                        );
                        if (picked != null) {
                          setS(() => available =
                              '${picked.day}/${picked.month}/${picked.year}');
                        }
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                        decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            color: !['Σήμερα', 'Αύριο'].contains(available)
                                ? kGold.withValues(alpha: 0.2) : _g(0.05),
                            border: Border.all(
                                color: !['Σήμερα', 'Αύριο'].contains(available)
                                    ? kGold : _g(0.12))),
                        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Icon(Icons.calendar_today,
                              size: 11,
                              color: !['Σήμερα', 'Αύριο'].contains(available)
                                  ? kGold : _g(0.4)),
                          const SizedBox(width: 4),
                          Text(
                            !['Σήμερα', 'Αύριο'].contains(available)
                                ? available : 'Ημερομηνία',
                            style: TextStyle(
                                fontSize: 12,
                                color: !['Σήμερα', 'Αύριο'].contains(available)
                                    ? kGold : _g(0.4)),
                          ),
                        ]),
                      ),
                    ),
                  ),
                ]),
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
                    final price = priceOnSite ? 0.0 : (double.tryParse(priceCtrl.text.trim()) ?? 0);
                    if (!priceOnSite && price <= 0) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Βάλε τιμή ή επέλεξε "Κατόπιν εκτίμησης"!')));
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
              child: const Icon(Icons.close, color: Colors.white70, size: 13)),
          ),
        ),
      ])),
      // Caption row
      GestureDetector(
    try {
      // Χρησιμοποιούμε πάντα το τρέχον auth uid (ασφαλέστερο από widget.userId)
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
        if (_instagram.isNotEmpty) 'instagram': _instagram,
        if (_tiktok.isNotEmpty) 'tiktok': _tiktok,
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
    // Έλεγξε αν υπάρχει ήδη προσφορά από τον ίδιο επαγγελματία
    // Network error — fallback στη Firestore
    await _submitOfferFallback(requestId, price, message, available);
  }
}
      // ── 1. Read ALL bytes before navigation (XFile blob URLs expire after widget disposal on web) ──
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
      'specialty': _proSpecialty ?? '',
      'price': price,
      'message': message,
      'availableFrom': available,
      'rating': 4.8,
      'emoji': '🔧',
      if (_proPhotoUrl != null) 'profilePhotoUrl': _proPhotoUrl,
      'createdAt': FieldValue.serverTimestamp(),
    });

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
// MARQUEE BANNER
// ═══════════════════════════════════════
class _MarqueeBanner extends StatefulWidget {
  final String text;
  const _MarqueeBanner({required this.text});
  @override
  State<_MarqueeBanner> createState() => _MarqueeBannerState();
}

class _MarqueeBannerState extends State<_MarqueeBanner>
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
Future<void> _notifyProsDirectly(
    String requestId,
    String description,
    String profession,
    String location,
    String userName,
    int imageCount, {
    bool hasVideos = false,
  }) async {
    try {
      // Query 1: new-style professionals (have 'specialties' array)
      // Query 2: old-style professionals (have only 'specialty' string)
      // Merge results, deduplicate by userId, then post-filter by area.
      final db = FirebaseFirestore.instance;
      final baseQ = db.collection('professionals').where('is_active', isEqualTo: true);

      QuerySnapshot<Map<String, dynamic>> snap1;
      QuerySnapshot<Map<String, dynamic>> snap2;
      if (profession.isNotEmpty) {
        // New pros: specialties arrayContains profession
        snap1 = await baseQ.where('specialties', arrayContains: profession).get();
        // Old pros: specialty == profession
        snap2 = await baseQ.where('specialty', isEqualTo: profession).get();
      } else {
        snap1 = await baseQ.get();
        snap2 = await baseQ.limit(0).get(); // empty
      }

      // Merge + deduplicate by document ID
      final allDocs = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
      for (final d in [...snap1.docs, ...snap2.docs]) { allDocs[d.id] = d; }

      // Post-filter by area AND availability
      final filtered = allDocs.values.where((doc) {
        final d = doc.data();
        // Skip pros who turned off availability
        if (d['available'] == false) return false;
        if (location.isEmpty || location == 'Κοντά μου') return true;
        final areas = d['areas'];
        if (areas is List && areas.contains(location)) return true;
        final area = d['area'] as String? ?? '';
        return area == location;
      }).toList();

      int notified = 0;
      final notifiedProIds = <String>[];
      for (final doc in filtered) {
        final proUserId = (doc.data()['userId'] as String? ?? '');
        if (proUserId.isEmpty) continue;
        // DELETE any existing notifications for this requestId (backend duplicates)
        try {
          final existing = await db
              .collection('users').doc(proUserId)
              .collection('notifications')
      for (final d in [...snap1.docs, ...snap2.docs]) { allDocs[d.id] = d; }

      // Post-filter by area, availability, photos
      final filtered = allDocs.values.where((doc) {
        final d = doc.data();
        // Skip pros who turned off availability
        if (d['available'] == false) return false;
        // If user wants photos, skip pros without a profile photo
        if (withPhotos) {
          final photoUrl = (d['profilePhotoUrl'] ?? '') as String;
          if (photoUrl.isEmpty) return false;
        }
        if (location.isEmpty || location == 'Κοντά μου') return true;
        final areas = d['areas'];
        if (areas is List && areas.contains(location)) return true;
        final area = d['area'] as String? ?? '';
        return area == location;
      }).toList();

      int notified = 0;
      final notifiedProIds = <String>[];
      for (final doc in filtered) {
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
          'hasVideos': hasVideos,
          'createdAt': FieldValue.serverTimestamp(),
        });
        // Also send FCM push notification to this pro
          'type': 'new_request',
          'hasImages': imageCount > 0,
          'imageCount': imageCount,
          'hasVideos': hasVideos,
          'createdAt': FieldValue.serverTimestamp(),
        });
        // Also send FCM push notification to this pro
        try {
          final fcmToken = proUserDoc.data()?['fcmToken'] as String?;
          final proDisplayName = (doc.data()['displayName'] ?? doc.data()['name'] ?? '') as String;
          if (fcmToken != null && fcmToken.isNotEmpty) {
            await http.post(
              Uri.parse('$kBackendUrl/notify-new-request'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'fcmToken': fcmToken,
                'proName': proDisplayName,
                'userName': userName,
                'description': description,
                'profession': profession,
              }),
            ).timeout(const Duration(seconds: 55));
          }
        } catch (e) {
          debugPrint('FCM push to pro $proUserId error: $e');
        }
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
    }
  }
  @override
  Widget build(BuildContext context) {
  }

  void _toggleLive(bool v) {
    setState(() => _live = v);
    if (v) {
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
// ── Nearby Pro Card — Premium Redesign ──
class _NearbyProCard extends StatefulWidget {
  final Map<String, dynamic> pro;
  const _NearbyProCard({super.key, required this.pro});
  @override
  State<_NearbyProCard> createState() => _NearbyProCardState();
}

class _NearbyProCardState extends State<_NearbyProCard>
    with SingleTickerProviderStateMixin {
  Uint8List? _photoBytes;
  bool _fetchedPhoto = false;
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseScale;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1300))
      ..repeat(reverse: true);
    _pulseScale = Tween<double>(begin: 1.0, end: 2.4)
        .animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_fetchedPhoto) {
      _fetchedPhoto = true;
      final url = (widget.pro['profilePhotoUrl'] ?? widget.pro['photo_url'] ?? '') as String;
      if (url.isNotEmpty) {
        http.get(Uri.parse(url)).timeout(const Duration(seconds: 10)).then((res) {
          if (res.statusCode == 200 && mounted) {
            setState(() => _photoBytes = res.bodyBytes);
          }
        }).catchError((_) {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pro = widget.pro;
    final name = (pro['name'] as String? ?? pro['displayName'] as String? ?? 'Επαγγελματίας');
    final specialty = (pro['specialty'] ?? pro['profession'] ?? '') as String;
    final isOnline = pro['is_active'] == true;
    final isVerified = pro['verified'] == true;
    final rating = ((pro['rating'] ?? pro['average_rating'] ?? 4.8) as num).toDouble();
    final jobs = ((pro['jobs_count'] ?? pro['completed_jobs'] ?? 0) as num).toInt();
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'Π';

    return Container(
        margin: const EdgeInsets.only(right: 0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.6), blurRadius: 18, offset: const Offset(0, 6))],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(fit: StackFit.expand, children: [
            // ── Full-bleed photo background ──
            _photoBytes != null
                ? Image.memory(_photoBytes!, fit: BoxFit.cover)
                : Container(
                    color: kGold.withValues(alpha: 0.08),
                    child: Center(child: Text(initial,
                        style: const TextStyle(color: kGold, fontSize: 40, fontWeight: FontWeight.w800))),
                  ),
            // Dark gradient: top for name, bottom for stats
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter, end: Alignment.bottomCenter,
  void dispose() {
    _fadeCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadOffers() async {
    // Πρώτα server endpoint για AI filtered
    try {
      final res = await http
          .get(Uri.parse('$kBackendUrl/get-offers/${widget.requestId}'))
                  width: double.infinity,
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
// [GAP: LINE 8257 NOT CAPTURED]
// [GAP: LINE 8258 NOT CAPTURED]
// [GAP: LINE 8259 NOT CAPTURED]
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
              ]),
            ),
          ]),
        ),
    );
  }

  Widget _chip(String emoji, String val) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(6),
      color: Colors.black.withValues(alpha: 0.55),
      border: Border.all(color: Colors.white.withValues(alpha: 0.15), width: 0.5),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Text(emoji, style: const TextStyle(fontSize: 9)),
      const SizedBox(width: 2),
      Text(val, style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w600)),
    ]),
  );

  Widget _letterBox(String initial) => Container(
    color: kGold.withValues(alpha: 0.06),
    child: Center(child: Text(initial, style: const TextStyle(color: kGold, fontSize: 40, fontWeight: FontWeight.w800))),
  );

  // CTA "Ζήτα Προσφορά" button → DirectRequestScreen (Premium gate TODO: re-enable)
  Future<void> _onRequestTap(BuildContext context) async {
    if (!context.mounted) return;
    Navigator.push(context, PageRouteBuilder(
      pageBuilder: (_, __, ___) => DirectRequestScreen(pro: widget.pro),
      transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
      transitionDuration: const Duration(milliseconds: 350),
    ));
  }

  void _showPremiumGate(BuildContext ctx, {VoidCallback? onSubscribed}) {
    showDialog(context: ctx, builder: (c) => Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
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
// ════════════════════════════════════════════════
// OFFERS READY SCREEN — standalone, cannot be accidentally popped
// ════════════════════════════════════════════════
// ── Overlay wrapper shown by HomeScreen instead of a Navigator push ──
// This completely avoids browser history changes and the popstate auto-back bug.
class _OffersReadyOverlay extends StatelessWidget {
  final _OffersReadyData data;
  final VoidCallback onDismiss;
  const _OffersReadyOverlay({required this.data, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return OffersReadyScreen(
                  if (isVerified) ...[
                    const SizedBox(width: 4),
                    const Icon(Icons.verified_rounded, color: kGold, size: 11),
                  ],
                ]),
                Text(specialty, maxLines: 1, overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: kGold, fontSize: 10, fontWeight: FontWeight.w600,
                        shadows: [Shadow(blurRadius: 3, color: Colors.black)])),
              ]),
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
// [GAP: LINE 8419 NOT CAPTURED]
// [GAP: LINE 8420 NOT CAPTURED]
// [GAP: LINE 8421 NOT CAPTURED]
// [GAP: LINE 8422 NOT CAPTURED]
// [GAP: LINE 8423 NOT CAPTURED]
// [GAP: LINE 8424 NOT CAPTURED]
// [GAP: LINE 8425 NOT CAPTURED]
// [GAP: LINE 8426 NOT CAPTURED]
// [GAP: LINE 8427 NOT CAPTURED]
// [GAP: LINE 8428 NOT CAPTURED]
// [GAP: LINE 8429 NOT CAPTURED]
// [GAP: LINE 8430 NOT CAPTURED]
// [GAP: LINE 8431 NOT CAPTURED]
// [GAP: LINE 8432 NOT CAPTURED]
// [GAP: LINE 8433 NOT CAPTURED]
// [GAP: LINE 8434 NOT CAPTURED]
// [GAP: LINE 8435 NOT CAPTURED]
// [GAP: LINE 8436 NOT CAPTURED]
// [GAP: LINE 8437 NOT CAPTURED]
// [GAP: LINE 8438 NOT CAPTURED]
// [GAP: LINE 8439 NOT CAPTURED]
// [GAP: LINE 8440 NOT CAPTURED]
// [GAP: LINE 8441 NOT CAPTURED]
// [GAP: LINE 8442 NOT CAPTURED]
// [GAP: LINE 8443 NOT CAPTURED]
// [GAP: LINE 8444 NOT CAPTURED]
// [GAP: LINE 8445 NOT CAPTURED]
// [GAP: LINE 8446 NOT CAPTURED]
// [GAP: LINE 8447 NOT CAPTURED]
// [GAP: LINE 8448 NOT CAPTURED]
// [GAP: LINE 8449 NOT CAPTURED]
// [GAP: LINE 8450 NOT CAPTURED]
// [GAP: LINE 8451 NOT CAPTURED]
// [GAP: LINE 8452 NOT CAPTURED]
// [GAP: LINE 8453 NOT CAPTURED]
// [GAP: LINE 8454 NOT CAPTURED]
// [GAP: LINE 8455 NOT CAPTURED]
// [GAP: LINE 8456 NOT CAPTURED]
// [GAP: LINE 8457 NOT CAPTURED]
                  ),
                ],
      Text(emoji, style: const TextStyle(fontSize: 9)),
      const SizedBox(width: 2),
      Text(val, style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w600)),
    ]),
  );

  Widget _letterBox(String initial) => Container(
    color: kGold.withValues(alpha: 0.06),
    child: Center(child: Text(initial, style: const TextStyle(color: kGold, fontSize: 40, fontWeight: FontWeight.w800))),
  );

  // CTA "Ζήτα Προσφορά" button → DirectRequestScreen (Premium gate)
  Future<void> _onRequestTap(BuildContext context) async {
    if (!context.mounted) return;
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
  bool _wantsImmediate = false;
  double? _minRating; // null = no filter, 4.0 or 4.5
  bool _wantsWithPhotos = false;
  final List<XFile> _images = [];
  final List<XFile> _videoFiles = [];
  final _picker = ImagePicker();
  bool _sending = false;
  bool _showTip = false;
  String? _selectedProfession;
  String? _selectedLocation;
  late AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1000))
      ..repeat(reverse: true);
    _textCtrl.addListener(() => setState(() {}));
    // Wake up Render backend early so push is ready when user submits
    Future(() async {
      try {
        await http.get(Uri.parse('$kBackendUrl/health'))
            .timeout(const Duration(seconds: 60));
      } catch (_) {}
    });
    _textCtrl.dispose();
    super.dispose();
  }
        await http.get(Uri.parse('$kBackendUrl/health'))
            .timeout(const Duration(seconds: 60));
      } catch (_) {}
    });
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
    super.dispose();
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
    // Show bottom sheet with media options
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          gradient: const LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [Color(0xFF2a2a2a), Color(0xFF1a1a1a)],
          ),
          border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.10))),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
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
          await Future.delayed(const Duration(milliseconds: 800));
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
    try {
      final video = await _picker.pickVideo(source: source);
      if (video == null) return;
      // video.length() can throw on Flutter Web for blob URLs — skip check if it fails
      try {
        final size = await video.length();
        if (size > 100 * 1024 * 1024) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Το βίντεο είναι πολύ μεγάλο (max 100 MB)')));
          return;
        }
      } catch (_) { /* on web, length() may not be available — skip size check */ }
      if (mounted) setState(() => _videoFiles.add(video));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Σφάλμα επιλογής βίντεο: $e')));
    }
  }

  bool _submitLock = false;  // Guard κατά double submit
      String proId = ((offer['professionalId'] as String?) ?? '').trim();
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
        'offersCount': 0,
      // ── Step 1: Resolve professionalId FIRST (may be missing from server response) ──
      String proId = ((offer['professionalId'] as String?) ?? '').trim();
      if (proId.isEmpty) {
        try {
        'imageCount': _images.length,
        if (_videoFiles.isNotEmpty) 'hasVideos': true,
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
          if (bytes.isNotEmpty) {
            videoData.add((name: vid.name, bytes: bytes, mime: vid.mimeType ?? 'video/mp4'));
          } else {
            debugPrint('Video readAsBytes() returned empty: ${vid.name}');
          }
        } catch (e) {
          debugPrint('Video readAsBytes() error: $e');
        }
      }

      // ── 2. Save images to Firestore ──
      if (imageBase64.isNotEmpty) {
        await FirebaseFirestore.instance
            .collection('requests')
            .doc(docRef.id)
            .update({'images': imageBase64, 'hasImages': true});
      }

      // Analytics
      _analytics.logEvent(name: 'submit_request', parameters: {
        'profession': _selectedProfession ?? '',
        'has_images': _images.isNotEmpty ? 'true' : 'false',
      });

      // ── 3. Notify pros in background (5s delay overwrites backend duplicates) ──
      final _notifRequestId = docRef.id;
      final _notifDesc = _textCtrl.text.trim();
      final _notifProf = _selectedProfession ?? '';
      final _notifLoc = _selectedLocation ?? '';
      final _notifUser = widget.userName;
        try { imageBase64.add(base64Encode(await img.readAsBytes())); } catch (_) {}
      }

      // Read video bytes NOW while XFile is still valid
      final List<({String name, Uint8List bytes, String mime})> videoData = [];
      for (final vid in _videoFiles) {
        try {
          final bytes = await vid.readAsBytes();
          if (bytes.isNotEmpty) {
            videoData.add((name: vid.name, bytes: bytes, mime: vid.mimeType ?? 'video/mp4'));
          } else {
            debugPrint('Video readAsBytes() returned empty: ${vid.name}');
          }
        } catch (e) {
          debugPrint('Video readAsBytes() error: $e');
        }
      }

      // ── 2. Save images to Firestore ──
      if (imageBase64.isNotEmpty) {
        await FirebaseFirestore.instance
            .collection('requests')
            .doc(docRef.id)
            .update({'images': imageBase64, 'hasImages': true});
      }

      // Analytics
      _analytics.logEvent(name: 'submit_request', parameters: {
        'profession': _selectedProfession ?? '',
        'has_images': _images.isNotEmpty ? 'true' : 'false',
      });

      // ── 3. Notify pros in background (5s delay overwrites backend duplicates) ──
      final _notifRequestId = docRef.id;
      final _notifDesc = _textCtrl.text.trim();
      final _notifProf = _selectedProfession ?? '';
      final _notifLoc = _selectedLocation ?? '';
      final _notifUser = widget.userName;
      final _notifImgCount = _images.length;
      final _notifImmediate = _wantsImmediate;
                  }
                }
              } catch (e) {
                debugPrint('Video upload error [$i]: $e');
              }
            }
            if (videoUrls.isNotEmpty) {
              await FirebaseFirestore.instance
                  .collection('requests')
                  .doc(requestDocId)
                  .update({'videoUrls': videoUrls, 'hasVideos': true});
              // Wait for _notifyProsDirectly to finish creating notification docs
              await Future.delayed(const Duration(seconds: 15));
              // Update each pro's notification doc with the actual video URLs
        final snap = await FirebaseFirestore.instance
            .collection('event_requests')
            .doc(widget.requestId)
            .collection('event_offers')
            .orderBy('price')
            .limit(10)
            .get();
        if (snap.docs.isNotEmpty && mounted) {
          setState(() {
            _offers = snap.docs.map((d) {
              final data = d.data();
              return {
                'name': data['professionalName'] ?? 'Επαγγελματίας',
                'professionalName': data['professionalName'] ?? '',
                'professionalId': data['professionalId'] ?? '',
                'specialty': data['specialty'] ?? '',
                'rating': data['rating'] ?? 4.8,
                'reviews': data['reviews'] ?? 0,
                'price': data['price'] ?? 0,
                'details': data['message'] ?? '',
                'available': '',
                'distance': '',
                'guarantee': false,
                'emoji': '🎉',
                'rank': snap.docs.indexOf(d) + 1,
                if (data['profilePhotoUrl'] != null)
                  'profilePhotoUrl': data['profilePhotoUrl'],
              };
            }).toList();
            _loading = false;
          });
          return;
        }
      } catch (_) {}
      // No offers yet for event
      if (mounted) setState(() { _offers = []; _loading = false; });
    String location,
    String userName,
    int imageCount, {
    bool hasVideos = false,
    bool immediate = false,
    bool withPhotos = false,
    double? minRating,
  }) async {
    try {
      // Query 1: new-style professionals (have 'specialties' array)
      // Query 2: old-style professionals (have only 'specialty' string)
      // Merge results, deduplicate by userId, then post-filter by area.
      final db = FirebaseFirestore.instance;
      final baseQ = db.collection('professionals').where('is_active', isEqualTo: true);

      QuerySnapshot<Map<String, dynamic>> snap1;
      QuerySnapshot<Map<String, dynamic>> snap2;
      if (profession.isNotEmpty) {
        // New pros: specialties arrayContains profession
        snap1 = await baseQ.where('specialties', arrayContains: profession).get();
        // Old pros: specialty == profession
        snap2 = await baseQ.where('specialty', isEqualTo: profession).get();
      } else {
        snap1 = await baseQ.get();
        snap2 = await baseQ.limit(0).get(); // empty
      }

      // Merge + deduplicate by document ID
      final allDocs = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
      for (final d in [...snap1.docs, ...snap2.docs]) { allDocs[d.id] = d; }

      // Post-filter by area, availability, photos
      final filtered = allDocs.values.where((doc) {
        final d = doc.data();
        // Skip pros who turned off availability
        if (d['available'] == false) return false;
        // If user wants photos, skip pros without a profile photo
        if (withPhotos) {
          final photoUrl = (d['profilePhotoUrl'] ?? '') as String;
          if (photoUrl.isEmpty) return false;
        }
        if (location.isEmpty || location == 'Κοντά μου') return true;
        final areas = d['areas'];
        if (areas is List && areas.contains(location)) return true;
        final area = d['area'] as String? ?? '';
        return area == location;
      }).toList();

      int notified = 0;
      final notifiedProIds = <String>[];
      for (final doc in filtered) {
        final proUserId = (doc.data()['userId'] as String? ?? '');
        if (proUserId.isEmpty) continue;
        // Fetch user doc early — needed for rating check AND FCM token
        final proUserDoc = await db.collection('users').doc(proUserId).get();
        // ── Rating filter ──
        if (minRating != null && minRating > 0) {
          final proRating = (proUserDoc.data()?['averageRating'] as num?)?.toDouble() ?? 0.0;
          if (proRating < minRating) continue;
        }
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
    await Future.delayed(const Duration(milliseconds: 800));

    // ── Event request: read from event_offers subcollection ──
    if (widget.isEvent) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection('event_requests')
            .doc(widget.requestId)
            .collection('event_offers')
            .orderBy('price')
            .limit(10)
            .get();
        if (snap.docs.isNotEmpty && mounted) {
          final loaded = snap.docs.map((d) {
            final data = d.data();
            return <String, dynamic>{
              'name': data['professionalName'] ?? 'Επαγγελματίας',
              'professionalName': data['professionalName'] ?? '',
              'professionalId': data['professionalId'] ?? '',
              'specialty': data['specialty'] ?? '',
              'rating': data['rating'] ?? 4.8,
              'reviews': data['reviews'] ?? 0,
              'price': data['price'] ?? 0,
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
                            items: const [
                              'Συνεργείο Ανακαίνισης', 'Συνεργείο Κατασκευών', 'Συνεργείο Βαφής & Διακόσμησης',
                              'Συνεργείο Ηλεκτρολόγων', 'Συνεργείο Υδραυλικών', 'Συνεργείο Κλιματισμού',
                              'Ηλεκτρολόγος', 'Υδραυλικός', 'Ψυκτικός', 'Ελαιοχρωματιστής',
                              'Μηχανικός', 'Κτίστης', 'Ξυλουργός', 'Υαλουργός',
                              'Τεχνικός Ανελκυστήρων', 'Αποφράξεις', 'Αλουμινάς', 'Πλακάς',
                              'Συντήρηση Κλιματιστικών', 'Εγκατάσταση Ηλιακών', 'Υπηρεσία Αποξήλωσης',
                              'Πόρτες Ασφαλείας', 'Τέντες', 'Μονώσεις', 'Σιδηρουργός', 'Μαρμαράς',
                              'Παθολόγος', 'Παιδίατρος', 'Οδοντίατρος', 'Φυσιοθεραπευτής',
                              'Ψυχολόγος', 'Διατροφολόγος', 'Καθαρίστρια', 'Κηπουρός',
                              'Baby Sitter', 'Μετακομίσεις',
                              'Καθηγητής Μαθηματικών', 'Καθηγητής Αγγλικών',
                              'Καθηγητής Γαλλικών', 'Καθηγητής Ιταλικών',
                              'Καθηγητής Γερμανικών', 'Καθηγητής Ισπανικών',
                              'Φιλόλογος', 'Καθηγητής Φυσικής', 'Καθηγητής Χημείας',
                              'Καθηγητής Πληροφορικής', 'Καθηγητής Βιολογίας',
                              'Personal Trainer',
                              'Tattoo Artist', 'Τεχνίτρια Νυχιών',
                              'Web Developer', 'Γραφίστας', 'Φωτογράφος', 'Τεχνικός Υπολογιστών',
                              'Μηχανικός Αυτοκινήτων', 'Λογιστής', 'Δικηγόρος', 'Αρχιτέκτονας',
                            ],
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
      final proId = (offer['professionalId'] ?? '').toString();
      String? photoUrl;

      if (proId.isNotEmpty) {
        try {
          // Check professionals collection by userId
          final snap = await FirebaseFirestore.instance
              .collection('professionals')
              .where('userId', isEqualTo: proId)
              .limit(1)
              .get();
          if (snap.docs.isNotEmpty) {
            photoUrl = snap.docs.first.data()['profilePhotoUrl'] as String?;
          }
          // Also try users collection
          if (photoUrl == null || photoUrl.isEmpty) {
            final userDoc = await FirebaseFirestore.instance
                .collection('users').doc(proId).get();
            photoUrl = userDoc.data()?['profilePhotoUrl'] as String?;
          }
        } catch (_) {}
      }

      if (photoUrl != null && photoUrl.isNotEmpty) {
        offer['profilePhotoUrl'] = photoUrl;
      }
    });
    await Future.wait(futures);
  }

  String _criteriaLabel() {
    if (widget.criteria == 'cheap') return 'χαμηλότερης τιμής';
    if (widget.criteria == 'value') return 'καλύτερου value for money';
    return 'ταχύτερης διαθεσιμότητας';
  }

  Future<void> _openGallery(BuildContext ctx, Map<String, dynamic> offer) async {
    if (!ctx.mounted) return;
    // Portfolio is free — premium only for direct messages
    final pro = {
      'id': offer['professionalId'] ?? '',
      'name': offer['name'] ?? offer['professionalName'] ?? 'Επαγγελματίας',
      'displayName': offer['name'] ?? offer['professionalName'] ?? 'Επαγγελματίας',
      'profilePhotoUrl': offer['profilePhotoUrl'] ?? '',
      'specialty': offer['specialty'] ?? '',
      'emoji': offer['emoji'] ?? '🔧',
    };
    Navigator.of(ctx).push(PageRouteBuilder(
      pageBuilder: (_, __, ___) => ProPortfolioScreen(pro: pro),
      transitionsBuilder: (_, a, __, c2) => FadeTransition(opacity: a, child: c2),
      transitionDuration: const Duration(milliseconds: 350),
    ));
  }

  Future<void> _selectOffer(Map<String, dynamic> offer) async {
    // Declare outside try so Step 7 (notification) can always access them
          'createdAt': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        debugPrint('Notification write error: \$e');
      }
      // FCM push — ξεχωριστό, με μεγαλύτερο timeout
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
          ).timeout(const Duration(seconds: 20));
        }
      } catch (_) {}
    }

    if (!mounted) return;
    // Safe name από offer map
    final proName = (offer['name'] ?? offer['professionalName'] ?? 'τον επαγγελματία').toString();
    final proEmoji = (offer['emoji'] ?? '🔧').toString();
                  const SizedBox(height: 12),
                  Text('Επέλεξες τον\n$proName!',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontFamily: 'Raleway',
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: Colors.white)),
                  const SizedBox(height: 8),
    final specialty = (pro['specialty'] ?? pro['profession'] ?? '') as String;
    final area = (pro['area'] ?? '') as String;
    final bio = (pro['bio'] ?? pro['description'] ?? '') as String;
    final isVerified = pro['verified'] == true;
    final isOnline = pro['is_active'] == true;
    final rating = ((pro['averageRating'] ?? pro['rating'] ?? pro['average_rating'] ?? 0.0) as num).toDouble();
    final reviewCount = ((pro['reviewCount'] ?? 0) as num).toInt();
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
class _OfferCard extends StatefulWidget {
  final Map<String, dynamic> offer;
  final bool isBest;
  final VoidCallback onSelect;
  final VoidCallback? onGallery;
  const _OfferCard(
      {required this.offer,
      required this.isBest,
      required this.onSelect,
                                _listening ? Icons.stop_rounded : Icons.mic_rounded,
                                color: _listening ? Colors.white : kGold,
                                size: 22,
                              )),
                            ),
                          ),
                          const SizedBox(width: 6),
                          // PHOTO BUTTON
                          GestureDetector(
                            onTap: _pickImage,
                        secondChild: const SizedBox.shrink(),
                      ),

                            )),
                          ]),
                        ),
                        secondChild: const SizedBox.shrink(),
                      ),

                      // Bottom bar: mic + send INSIDE the box
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: const BorderRadius.vertical(
                              bottom: Radius.circular(22)),
                          color: kGold.withValues(alpha: 0.06),
                        ),
                        padding: const EdgeInsets.all(6),
                        child: Column(children: [
                          // Audio preview row (shown when audio recorded)
                          if (_requestAudioUrl != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Row(children: [
                                Expanded(child: _AudioPlaybackWidget(url: _requestAudioUrl!)),
                                const SizedBox(width: 6),
                                GestureDetector(
                                  onTap: () => setState(() => _requestAudioUrl = null),
                                  child: Icon(Icons.close_rounded, color: _g(0.4), size: 18),
                                ),
                              ]),
                            ),
                          // Uploading indicator
                          if (_audioUploading)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Row(children: [
                                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: kGold)),
                                const SizedBox(width: 8),
                                Text('Αποθήκευση ηχητικού...', style: TextStyle(color: _g(0.5), fontSize: 11)),
                              ]),
                            ),
                          // Recording indicator
                          if (_audioRecording)
                            GestureDetector(
                              onTap: _stopVoice,
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: Colors.red.withValues(alpha: 0.1), border: Border.all(color: Colors.red.withValues(alpha: 0.4))),
                                  child: Row(children: [
                                    Container(width: 7, height: 7, decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle)),
                                    const SizedBox(width: 7),
                                    Text('🎙 ${_audioDur.inMinutes}:${(_audioDur.inSeconds % 60).toString().padLeft(2, '0')}',
                                      style: const TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.w600)),
                                    const Spacer(),
                                    const Text('⏹ Τέλος', style: TextStyle(color: Colors.red, fontSize: 11, fontWeight: FontWeight.w700)),
                                  ]),
                                ),
                              ),
                            ),
                          Row(children: [
                          // MIC BUTTON
                          GestureDetector(
                            onTap: _audioRecording ? _stopVoice : _startVoice,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              width: 46, height: 46,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                color: _audioRecording
                                    ? Colors.red
                                    : _requestAudioUrl != null
                                        ? kGreen.withValues(alpha: 0.15)
                                        : _g(0.08),
                                border: Border.all(
                                    color: _audioRecording
                                        ? Colors.red
                                        : _requestAudioUrl != null
                                            ? kGreen
                                            : kGold.withValues(alpha: 0.3)),
                              ),
                              child: Center(child: Icon(
                                _audioRecording ? Icons.stop_rounded : Icons.mic_rounded,
                                color: _audioRecording ? Colors.white : _requestAudioUrl != null ? kGreen : kGold,
                                size: 22,
                              )),
                            ),
                          ),
                          const SizedBox(width: 6),
                          // PHOTO BUTTON
                          GestureDetector(
                            onTap: _pickImage,
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
                              if (_images.isNotEmpty || _videoFiles.isNotEmpty) Positioned(
                                top: 2, right: 2,
                                child: Container(
                                  width: 16, height: 16,
                                  decoration: const BoxDecoration(color: kGreen, shape: BoxShape.circle),
                                  child: Center(child: Text('${_images.length + _videoFiles.length}',
                                      style: TextStyle(color: _gw, fontSize: 9, fontWeight: FontWeight.w700))),
                                ),
                              ),
                            ]),
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
                        ]),
                      ),
                    ]),
                  ),

                  const SizedBox(height: 14),

                  // AI Insights (conditional, outside card)
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 64,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          // Photo thumbnails
  }

  Future<void> _markAsRead() async {
    try {
      final field = widget.isPro ? 'unreadPro' : 'unreadUser';
      await FirebaseFirestore.instance
          .collection('chats').doc(widget.chatId)
          .set({field: 0}, SetOptions(merge: true));
    } catch (_) {}
  }

  Future<void> _sendMessage() async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    _msgCtrl.clear();
      final userDoc = user != null
          ? await FirebaseFirestore.instance.collection('users').doc(user.uid).get()
          : null;
      userName = (userDoc?.data()?['name'] as String?) ?? 'Χρήστης';
      userPhone = (userDoc?.data()?['phone'] as String?) ?? '';
      final proName = (offer['name'] ?? offer['professionalName'] ?? '').toString();

      // ── Step 3: Create booking with resolved proId ──
      final bookingRef = await FirebaseFirestore.instance.collection('bookings').add({
        'userId': user?.uid ?? '',
        'userName': userName,
        'userPhone': userPhone,
        'professionalName': proName,
        'professionalId': proId,
        'price': offer['price'] ?? 0,
        'requestId': widget.requestId,
        'status': 'pending',
        'isImmediate': true,
        'scheduledTime': 'Άμεσα',
        'createdAt': FieldValue.serverTimestamp(),
      });
      newBookingId = bookingRef.id;

      // ── Step 4: Admin analytics ──
      if (proName.isNotEmpty) {
        final proKey = proId.isNotEmpty ? proId : proName;
        await FirebaseFirestore.instance
            .collection('admin_analytics')
            .doc('pro_selections')
            .set({
          'clicks_$proKey': FieldValue.increment(1),
          'name_$proKey': proName,
          'lastUpdated': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }

      // ── Step 5: Save to user history ──
      if (user != null) {
        await FirebaseFirestore.instance
            .collection('users').doc(user.uid)
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
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Η προσφορά στάλθηκε!'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(backgroundColor: kBg,
        body: Center(child: CircularProgressIndicator(color: kGold)));
    if (_reqData == null) return const Scaffold(backgroundColor: kBg,
        body: Center(child: Text('Δεν βρέθηκε αίτημα', style: TextStyle(color: Colors.white))));
    final d = _reqData!;
    final userName = d['userName'] as String? ?? 'Χρήστης';
    final message = d['message'] as String? ?? '';
    final photoUrls = List<String>.from(d['photoUrls'] ?? []);

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
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Αίτημα από $userName',
                  style: const TextStyle(color: Colors.white, fontFamily: 'Raleway',
                      fontSize: 15, fontWeight: FontWeight.w800)),
              Text('Στείλε την προσφορά σου', style: TextStyle(color: _g(0.4), fontSize: 12)),
            ])),
          ]),
        ),
        Expanded(child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // User's message
            if (message.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
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
// MESSAGES SCREEN — User's direct request inbox
// ════════════════════════════════════════════════
class MessagesScreen extends StatelessWidget {
  final String userId;
  const MessagesScreen({super.key, required this.userId});

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
                fontFamily: 'Raleway', fontSize: 18, fontWeight: FontWeight.w800)),
          ]),
        ),
        const SizedBox(height: 16),
        Expanded(child: StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('chats')
              .where('userId', isEqualTo: userId)
              .snapshots(),
          builder: (context, snap) {
            if (snap.hasError)
              return Center(child: Text('Σφάλμα φόρτωσης', style: TextStyle(color: _g(0.3))));
            if (!snap.hasData)
              return const Center(child: CircularProgressIndicator(color: kGold));
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
                const SizedBox(height: 12),
                Text('Δεν υπάρχουν συνομιλίες', style: TextStyle(color: _g(0.3), fontSize: 14)),
                const SizedBox(height: 6),
                Text('Επέλεξε έναν επαγγελματία και πάτα\n"💬 Chat" για να ξεκινήσεις.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: _g(0.2), fontSize: 12, height: 1.5)),
              ]));
            }
            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              itemCount: docs.length,
              itemBuilder: (_, i) {
                final d = docs[i].data() as Map<String, dynamic>;
                final chatId = docs[i].id;
                final proName = d['proName'] as String? ?? 'Επαγγελματίας';
                final lastMsg = d['lastMessage'] as String? ?? '';
                final ts = d['lastMessageAt'] as Timestamp?;
                final unread = (d['unreadUser'] as int?) ?? 0;
                final timeStr = ts != null
                    ? '${ts.toDate().hour.toString().padLeft(2,'0')}:${ts.toDate().minute.toString().padLeft(2,'0')}'
                    : '';
                return GestureDetector(
                  onTap: () => Navigator.push(context, PageRouteBuilder(
                    pageBuilder: (_, __, ___) => ChatScreen(
                      chatId: chatId,
                      currentUserId: userId,
                      currentUserName: d['userName'] as String? ?? 'Χρήστης',
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
  }

  void _showAddProjectDialog() {
    final titleCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF0D0A04),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: kGold.withValues(alpha: 0.3))),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('➕ Νέο Project',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 6),
            Text('Δώσε έναν τίτλο για αυτό το project',
                style: TextStyle(color: _g(0.4), fontSize: 12)),
            const SizedBox(height: 16),
            TextField(
              controller: titleCtrl, autofocus: true,
              style: TextStyle(color: _gw, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'π.χ. "Ανακαίνιση σπιτιού Πεντέλη"',
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
                    child: const Center(child: Text('Άκυρο',
                        style: TextStyle(color: Colors.white54, fontSize: 13)))),
              )),
              const SizedBox(width: 10),
              Expanded(child: GestureDetector(
                onTap: () async {
                  final title = titleCtrl.text.trim();
                  if (title.isEmpty) return;
                  Navigator.pop(ctx);
                  final newProject = {
                    'id': '${DateTime.now().millisecondsSinceEpoch}',
                    'title': title,
                    'photos': <String>[],
                  };
                  final updated = [..._projects, newProject];
                  if (mounted) setState(() => _projects = List.from(updated));
                  await FirebaseFirestore.instance.collection('professionals').doc(_proDocId)
                      .update({'portfolioProjects': updated}).catchError((_) {});
                },
                child: Container(padding: const EdgeInsets.symmetric(vertical: 11),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(12),
                        gradient: const LinearGradient(colors: [kGoldLight, kGold])),
                    child: const Center(child: Text('Δημιουργία',
                        style: TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: 13)))),
              )),
            ]),
          ]),
        ),
      ),
    );
  }

  Future<void> _pickAndUploadToProject(String projectId) async {
    final picker = ImagePicker();
    final picked = await picker.pickMultiImage(imageQuality: 85);
    if (picked.isEmpty || !mounted) return;
    setState(() => _uploadingProjectId = projectId);
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
  Map<String, dynamic>? _reqData;
  bool _loading = true, _sending = false;

  @override
  void initState() {
    super.initState();
    _loadRequest();
  }

  @override
  void dispose() {
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
          ? const Center(child: CircularProgressIndicator(color: kGold))
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(children: [
                  ShaderMask(
                    shaderCallback: (b) => const LinearGradient(colors: [kGoldLight, kGold]).createShader(b),
                    child: const Text('📸 Portfolio μου',
                  if (mounted) setState(() => _projects = List.from(updated));
                  await FirebaseFirestore.instance.collection('professionals').doc(_proDocId)
                      .update({'portfolioProjects': updated}).catchError((_) {});
                },
                child: Container(padding: const EdgeInsets.symmetric(vertical: 11),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(12),
                        gradient: const LinearGradient(colors: [kGoldLight, kGold])),
                    child: const Center(child: Text('Δημιουργία',
                        style: TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: 13)))),
              )),
            ]),
          ]),
        ),
      ),
    );
  }

  void _renameProject(String projectId, String currentTitle) {
    final titleCtrl = TextEditingController(text: currentTitle);
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF0D0A04),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: kGold.withValues(alpha: 0.3))),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('✏️ Μετονομασία Project',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
                    ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Container(width: 80, height: 80,
                          decoration: BoxDecoration(shape: BoxShape.circle,
                            color: kGold.withValues(alpha: 0.08),
                            border: Border.all(color: kGold.withValues(alpha: 0.2))),
                          child: const Center(child: Text('📁', style: TextStyle(fontSize: 32)))),
                        const SizedBox(height: 16),
                        Text('Δεν υπάρχουν projects ακόμα',
                            style: TextStyle(color: _g(0.35), fontSize: 14)),
                        const SizedBox(height: 12),
                        GestureDetector(
                          onTap: _showAddProjectDialog,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12),
                                gradient: const LinearGradient(colors: [kGoldLight, kGold])),
                            child: const Text('➕ Δημιούργησε το πρώτο project',
                                style: TextStyle(color: Colors.black,
                                    fontWeight: FontWeight.w800, fontSize: 13)),
                          ),
                        ),
                      ]))
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                        itemCount: _projects.length,
                        itemBuilder: (_, i) {
                          final proj = _projects[i];
                          final projId = proj['id'] as String;
                          final title = proj['title'] as String? ?? '';
                          final photos = List<String>.from(proj['photos'] ?? []);
                          return _ProjectSection(
                            title: title,
      } catch (_) {}
    }

    if (!ctx.mounted) return;
    Navigator.of(ctx).push(PageRouteBuilder(
      pageBuilder: (_, __, ___) => ProPortfolioScreen(pro: pro),
      transitionsBuilder: (_, a, __, c2) => FadeTransition(opacity: a, child: c2),
      transitionDuration: const Duration(milliseconds: 350),
    ));
  }

  Future<void> _selectOffer(Map<String, dynamic> offer) async {
    // Declare outside try so Step 7 (notification) can always access them
    String proId = ((offer['professionalId'] as String?) ?? '').trim();
    String userName = 'Χρήστης';
    String userPhone = '';
    String newBookingId = '';

    try {
      // ── Step 1: Resolve professionalId FIRST (may be missing from server response) ──
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
      userName = (userDoc?.data()?['name'] as String?) ?? 'Χρήστης';
      userPhone = (userDoc?.data()?['phone'] as String?) ?? '';
      final proName = (offer['name'] ?? offer['professionalName'] ?? '').toString();

      // ── Step 3: Create booking with resolved proId ──
      final bookingRef = await FirebaseFirestore.instance.collection('bookings').add({
            const SizedBox(width: 10),
            Expanded(child: Text(title,
                style: const TextStyle(color: Colors.white, fontSize: 14,
                    fontWeight: FontWeight.w700))),
            // Add photos button
            isUploading
                ? const SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(color: kGold, strokeWidth: 2))
                : GestureDetector(
                    onTap: onAddPhotos,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: kGold.withValues(alpha: 0.12),
                        border: Border.all(color: kGold.withValues(alpha: 0.3)),
                      ),
                      child: const Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.add_photo_alternate_outlined, color: kGold, size: 13),
                        SizedBox(width: 4),
                        Text('Φωτογραφίες', style: TextStyle(color: kGold, fontSize: 11,
                            fontWeight: FontWeight.w700)),
                      ]),
                    ),
                  ),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: () => showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  backgroundColor: const Color(0xFF0D0A04),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16),
                      side: BorderSide(color: Colors.red.withValues(alpha: 0.4))),
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
// [GAP: LINE 9989 NOT CAPTURED]
// [GAP: LINE 9990 NOT CAPTURED]
// [GAP: LINE 9991 NOT CAPTURED]
// [GAP: LINE 9992 NOT CAPTURED]
// [GAP: LINE 9993 NOT CAPTURED]
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
          child: Container(
            height: 110,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: LinearGradient(colors: [kGold.withValues(alpha: 0.05), kGold.withValues(alpha: 0.02)]),
              border: Border.all(color: kGold.withValues(alpha: 0.15), width: 0.5),
            ),
            child: Center(child: Text('Δεν βρέθηκαν επαγγελματίες στην περιοχή σου',
                textAlign: TextAlign.center,
                style: TextStyle(color: _g(0.4), fontSize: 11))),
          ),
        )
      else
        SizedBox(
          height: 210,
          child: PageView.builder(
            controller: _pageCtrl,
            padEnds: false,
            itemCount: _pros.length,
            itemBuilder: (_, i) {
              final pro = _pros[i];
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => widget.onProTap(pro),
                child: Padding(
                  padding: EdgeInsets.only(left: i == 0 ? 20 : 8, right: 8),
                  child: _NearbyProCard(
                    key: ValueKey(pro['id'] ?? i.toString()),
                    pro: pro,
                  ),
                ),
              );
            },
          ),
        ),
    ]);
  }
}

// ── Nearby Pro Card — Premium Redesign ──
class _NearbyProCard extends StatefulWidget {
  final Map<String, dynamic> pro;
  const _NearbyProCard({super.key, required this.pro});
  @override
  State<_NearbyProCard> createState() => _NearbyProCardState();
}

class _NearbyProCardState extends State<_NearbyProCard>
    with SingleTickerProviderStateMixin {
  Uint8List? _photoBytes;
  bool _fetchedPhoto = false;
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseScale;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1300))
      ..repeat(reverse: true);
    _pulseScale = Tween<double>(begin: 1.0, end: 2.4)
        .animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_fetchedPhoto) {
      _fetchedPhoto = true;
      final url = (widget.pro['profilePhotoUrl'] ?? widget.pro['photo_url'] ?? '') as String;
      if (url.isNotEmpty) {
        http.get(Uri.parse(url)).timeout(const Duration(seconds: 10)).then((res) {
          if (res.statusCode == 200 && mounted) {
            setState(() => _photoBytes = res.bodyBytes);
          }
        }).catchError((_) {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pro = widget.pro;
    final name = (pro['name'] as String? ?? pro['displayName'] as String? ?? 'Επαγγελματίας');
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
          child: Container(
            height: 110,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: LinearGradient(colors: [kGold.withValues(alpha: 0.05), kGold.withValues(alpha: 0.02)]),
              border: Border.all(color: kGold.withValues(alpha: 0.15), width: 0.5),
            ),
          await _enrichWithPhotos(loaded);
          if (mounted) setState(() { _offers = loaded; _loading = false; });
          return;
        }
      }
    } catch (_) {}

    // Fallback: Firestore offers collection (χωρίς orderBy για να μην χρειάζεται composite index)
          child: PageView.builder(
            controller: _pageCtrl,
            padEnds: false,
            itemCount: _pros.length,
            itemBuilder: (_, i) {
              final pro = _pros[i];
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => widget.onProTap(pro),
                child: Padding(
                  padding: EdgeInsets.only(left: i == 0 ? 20 : 8, right: 8),
                  child: _NearbyProCard(
                    key: ValueKey(pro['id'] ?? i.toString()),
                    pro: pro,
                  ),
                ),
              );
            },
          ),
        ),
    ]);
  }
}

// ── Nearby Pro Card — Premium Redesign ──
class _NearbyProCard extends StatefulWidget {
  final Map<String, dynamic> pro;
  const _NearbyProCard({super.key, required this.pro});
  @override
  State<_NearbyProCard> createState() => _NearbyProCardState();
}

class _NearbyProCardState extends State<_NearbyProCard>
    with SingleTickerProviderStateMixin {
  Uint8List? _photoBytes;
  bool _fetchedPhoto = false;
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseScale;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1300))
      ..repeat(reverse: true);
    _pulseScale = Tween<double>(begin: 1.0, end: 2.4)
        .animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_fetchedPhoto) {
      _fetchedPhoto = true;
      final url = (widget.pro['profilePhotoUrl'] ?? widget.pro['photo_url'] ?? '') as String;
      if (url.isNotEmpty) {
        http.get(Uri.parse(url)).timeout(const Duration(seconds: 10)).then((res) {
          if (res.statusCode == 200 && mounted) {
            setState(() => _photoBytes = res.bodyBytes);
          }
        }).catchError((_) {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pro = widget.pro;
    final name = (pro['name'] as String? ?? pro['displayName'] as String? ?? 'Επαγγελματίας');
    final specialty = (pro['specialty'] ?? pro['profession'] ?? '') as String;
    final isOnline = pro['is_active'] == true;
    final isVerified = pro['verified'] == true;
    final rating = ((pro['rating'] ?? pro['average_rating'] ?? 4.8) as num).toDouble();
    final jobs = ((pro['jobs_count'] ?? pro['completed_jobs'] ?? 0) as num).toInt();
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'Π';

    return Container(
        margin: const EdgeInsets.only(right: 0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.6), blurRadius: 18, offset: const Offset(0, 6))],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(fit: StackFit.expand, children: [
            // ── Full-bleed photo background ──
            _photoBytes != null
                ? Image.memory(_photoBytes!, fit: BoxFit.cover)
                : Container(
                    color: kGold.withValues(alpha: 0.08),
                    child: Center(child: Text(initial,
                        style: const TextStyle(color: kGold, fontSize: 40, fontWeight: FontWeight.w800))),
                  ),
            // Dark gradient: top for name, bottom for stats
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter, end: Alignment.bottomCenter,
                  stops: [0.0, 0.45, 0.62, 1.0],
                  colors: [Color(0xCC000000), Colors.transparent, Colors.transparent, Color(0xDD000000)],
                ),
              ),
            ),
            // ── Name + specialty (top) ──
            Positioned(top: 10, left: 10, right: 10,
              child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 13,
                          fontWeight: FontWeight.w800,
                          shadows: [Shadow(blurRadius: 4, color: Colors.black)]))),
                  if (isVerified) ...[
                    const SizedBox(width: 4),
                    const Icon(Icons.verified_rounded, color: kGold, size: 11),
                  ],
                ]),
                Text(specialty, maxLines: 1, overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: kGold, fontSize: 10, fontWeight: FontWeight.w600,
                        shadows: [Shadow(blurRadius: 3, color: Colors.black)])),
              ]),
            ),
            // ── Online dot (top-right) ──
            if (isOnline)
              Positioned(top: 10, right: 10,
                child: AnimatedBuilder(
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
              ]),
            ),
          ]),
        ),
    );
  }

  Widget _chip(String emoji, String val) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(6),
      color: Colors.black.withValues(alpha: 0.55),
      border: Border.all(color: Colors.white.withValues(alpha: 0.15), width: 0.5),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Text(emoji, style: const TextStyle(fontSize: 9)),
      const SizedBox(width: 2),
      Text(val, style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w600)),
    ]),
  );

  Widget _letterBox(String initial) => Container(
    color: kGold.withValues(alpha: 0.06),
    child: Center(child: Text(initial, style: const TextStyle(color: kGold, fontSize: 40, fontWeight: FontWeight.w800))),
  );

  // CTA "Ζήτα Προσφορά" button → DirectRequestScreen (Premium gate)
  Future<void> _onRequestTap(BuildContext context) async {
    if (!context.mounted) return;
    final user = FirebaseAuth.instance.currentUser;
    bool isPremium = false;
    if (user != null) {
      try {
        final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
        isPremium = doc.data()?['isPremium'] == true || doc.data()?['isOwner'] == true;
      } catch (_) {}
    }
    if (!context.mounted) return;
    if (!isPremium) {
      _showPremiumGate(context, onSubscribed: () => _onRequestTap(context));
      return;
    }
    Navigator.push(context, PageRouteBuilder(
      pageBuilder: (_, __, ___) => DirectRequestScreen(pro: widget.pro),
      transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
      transitionDuration: const Duration(milliseconds: 350),
    ));
  }

    // ── Step 7: Notify professional — ΕΞΩΤΕΡΙΚΑ του κυρίου catch ──
    // Εκτελείται πάντα, ακόμα και αν προηγούμενο βήμα απέτυχε
    if (proId.isNotEmpty) {
      try {
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
          'bookingId': newBookingId,
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
                  child: const Center(child: Text('💬 Επικοινώνησε με τον Επαγγελματία',
                      style: TextStyle(color: Colors.black, fontSize: 14,
                          fontWeight: FontWeight.w900, letterSpacing: 0.3))),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statPill(String emoji, String value, String label) => Expanded(
              )),
          child: Stack(clipBehavior: Clip.none, children: [
            Container(
                width: 34,
                height: 34,
            ]),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _loadingNotifs
                ? const Center(child: CircularProgressIndicator(color: kGold))
                : _docs.isEmpty
                    ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.notifications_none, color: _g(0.15), size: 52),
                        const SizedBox(height: 12),
              debugPrint('Project video upload error: $e');
            }
          }
          if (urls.isNotEmpty) {
            await FirebaseFirestore.instance.collection('project_requests').doc(docId)
                .update({'videoUrls': urls, 'hasVideos': true});
          }
        });
      }

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 600),
          pageBuilder: (_, __, ___) => WaitingScreen(
            requestId: docRef.id,
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
          context: context,
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
    child: Center(child: Text(initial, style: const TextStyle(color: kGold, fontSize: 40, fontWeight: FontWeight.w800))),
  );

  // CTA "Ζήτα Προσφορά" button → DirectRequestScreen (Premium gate)
  Future<void> _onRequestTap(BuildContext context) async {
    if (!context.mounted) return;
    final user = FirebaseAuth.instance.currentUser;
    bool isPremium = false;
    if (user != null) {
      try {
        final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
        isPremium = kFreeForAll || doc.data()?['isPremium'] == true || doc.data()?['isOwner'] == true;
      } catch (_) {}
    }
    if (!context.mounted) return;
    if (!isPremium) {
      _showPremiumGate(context, onSubscribed: () => _onRequestTap(context));
      return;
    }
    Navigator.push(context, PageRouteBuilder(
      pageBuilder: (_, __, ___) => DirectRequestScreen(pro: widget.pro),
      transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
      transitionDuration: const Duration(milliseconds: 350),
    ));
  }

  void _showPremiumGate(BuildContext ctx, {VoidCallback? onSubscribed}) {
    showDialog(context: ctx, builder: (c) => Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
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
            ),
          ),
      ]),
    );
  }
}

// ════════════════════════════════════════════════
// PRO PORTFOLIO SCREEN — View a professional's profile & portfolio
// ════════════════════════════════════════════════
class ProPortfolioScreen extends StatefulWidget {
  final Map<String, dynamic> pro;
  const ProPortfolioScreen({super.key, required this.pro});
  @override
  State<ProPortfolioScreen> createState() => _ProPortfolioScreenState();
}

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
    final name = (pro['name'] ?? pro['displayName'] ?? 'Επαγγελματίας') as String;
    final specialty = (pro['specialty'] ?? pro['profession'] ?? '') as String;
    final area = (pro['area'] ?? '') as String;
    'Αθήνα Κέντρο', 'Κολωνάκι', 'Γλυφάδα', 'Βούλα', 'Βουλιαγμένη',
    'Καλλιθέα', 'Νέα Σμύρνη', 'Παλαιό Φάληρο', 'Άλιμος', 'Χαλάνδρι',
    'Μαρούσι', 'Κηφισιά', 'Εκάλη', 'Πεντέλη', 'Νέα Ιωνία',
    'Αγία Παρασκευή', 'Ζωγράφου', 'Βύρωνας', 'Ηλιούπολη',
    'Περιστέρι', 'Αιγάλεω', 'Πειραιάς', 'Κορωπί', 'Παιανία',
    'Θεσσαλονίκη Κέντρο', 'Καλαμαριά', 'Πυλαία', 'Θέρμη',
    'Πάτρα', 'Ηράκλειο Κρήτης', 'Χανιά', 'Ρέθυμνο',
    required this.isUploading, required this.onAddPhotos,
    required this.onDeletePhoto, required this.onDeleteProject,
    required this.onRenameProject, required this.onTapPhoto,
  });

  @override
  Widget build(BuildContext context) {
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
                        fontWeight: FontWeight.w700))),
                const SizedBox(width: 6),
                Icon(Icons.edit_outlined, color: kGold.withValues(alpha: 0.6), size: 14),
              ]),
            )),
            // Add photos button
// [GAP: LINE 10893 NOT CAPTURED]
// [GAP: LINE 10894 NOT CAPTURED]
// [GAP: LINE 10895 NOT CAPTURED]
// [GAP: LINE 10896 NOT CAPTURED]
// [GAP: LINE 10897 NOT CAPTURED]
// [GAP: LINE 10898 NOT CAPTURED]
// [GAP: LINE 10899 NOT CAPTURED]
// [GAP: LINE 10900 NOT CAPTURED]
// [GAP: LINE 10901 NOT CAPTURED]
// [GAP: LINE 10902 NOT CAPTURED]
// [GAP: LINE 10903 NOT CAPTURED]
// [GAP: LINE 10904 NOT CAPTURED]
// [GAP: LINE 10905 NOT CAPTURED]
// [GAP: LINE 10906 NOT CAPTURED]
// [GAP: LINE 10907 NOT CAPTURED]
// [GAP: LINE 10908 NOT CAPTURED]
// [GAP: LINE 10909 NOT CAPTURED]
// [GAP: LINE 10910 NOT CAPTURED]
// [GAP: LINE 10911 NOT CAPTURED]
// [GAP: LINE 10912 NOT CAPTURED]
// [GAP: LINE 10913 NOT CAPTURED]
// [GAP: LINE 10914 NOT CAPTURED]
// [GAP: LINE 10915 NOT CAPTURED]
// [GAP: LINE 10916 NOT CAPTURED]
// [GAP: LINE 10917 NOT CAPTURED]
// [GAP: LINE 10918 NOT CAPTURED]
// [GAP: LINE 10919 NOT CAPTURED]
// [GAP: LINE 10920 NOT CAPTURED]
// [GAP: LINE 10921 NOT CAPTURED]
// [GAP: LINE 10922 NOT CAPTURED]
// [GAP: LINE 10923 NOT CAPTURED]
// [GAP: LINE 10924 NOT CAPTURED]
// [GAP: LINE 10925 NOT CAPTURED]
// [GAP: LINE 10926 NOT CAPTURED]
// [GAP: LINE 10927 NOT CAPTURED]
// [GAP: LINE 10928 NOT CAPTURED]
// [GAP: LINE 10929 NOT CAPTURED]
// [GAP: LINE 10930 NOT CAPTURED]
// [GAP: LINE 10931 NOT CAPTURED]
// [GAP: LINE 10932 NOT CAPTURED]
// [GAP: LINE 10933 NOT CAPTURED]
// [GAP: LINE 10934 NOT CAPTURED]
// [GAP: LINE 10935 NOT CAPTURED]
// [GAP: LINE 10936 NOT CAPTURED]
// [GAP: LINE 10937 NOT CAPTURED]
// [GAP: LINE 10938 NOT CAPTURED]
// [GAP: LINE 10939 NOT CAPTURED]
// [GAP: LINE 10940 NOT CAPTURED]
// [GAP: LINE 10941 NOT CAPTURED]
// [GAP: LINE 10942 NOT CAPTURED]
// [GAP: LINE 10943 NOT CAPTURED]
// [GAP: LINE 10944 NOT CAPTURED]
// [GAP: LINE 10945 NOT CAPTURED]
// [GAP: LINE 10946 NOT CAPTURED]
// [GAP: LINE 10947 NOT CAPTURED]
// [GAP: LINE 10948 NOT CAPTURED]
// [GAP: LINE 10949 NOT CAPTURED]
// [GAP: LINE 10950 NOT CAPTURED]
// [GAP: LINE 10951 NOT CAPTURED]
// [GAP: LINE 10952 NOT CAPTURED]
// [GAP: LINE 10953 NOT CAPTURED]
// [GAP: LINE 10954 NOT CAPTURED]
      await FirebaseFirestore.instance
          .collection('direct_requests').doc(widget.directRequestId)
          .update({
        'status': 'replied',
        'offer': {'price': price, 'message': _msgCtrl.text.trim()},
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
            child: GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3, crossAxisSpacing: 6, mainAxisSpacing: 6,
                  childAspectRatio: 1.0),
              itemCount: photos.length,
              itemBuilder: (_, i) {
                final url = photos[i];
                final bytes = localCache[url];
                return GestureDetector(
                  onTap: () => onTapPhoto(i),
                  child: Stack(fit: StackFit.expand, children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: bytes != null
                          ? Image.memory(bytes, fit: BoxFit.cover)
                          : Image.network(url, fit: BoxFit.cover,
                              loadingBuilder: (_, child, p) => p == null ? child
                                  : Container(color: _g(0.06),
                                      child: const Center(child: CircularProgressIndicator(color: kGold, strokeWidth: 2))),
                              errorBuilder: (_, __, ___) => Container(color: _g(0.06),
                                  child: Icon(Icons.broken_image_outlined, color: _g(0.3)))),
                    ),
                    Positioned(top: 3, right: 3,
                      child: GestureDetector(
                        onTap: () => onDeletePhoto(url),
// [GAP: LINE 10990 NOT CAPTURED]
// [GAP: LINE 10991 NOT CAPTURED]
// [GAP: LINE 10992 NOT CAPTURED]
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
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: kGold.withValues(alpha: 0.08),
                        border: Border.all(
                            color: widget.isBest
                                ? kGold.withValues(alpha: 0.4)
                                : _g(0.12),
                            width: 1.5)),
                    child: ClipOval(
                      child: _photoUrl.isNotEmpty
                          ? Image.network(_photoUrl, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Center(child: Text(_emoji,
                                  style: const TextStyle(fontSize: 26))))
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
                          fontSize: 10)),
                  const SizedBox(height: 3),
                  Row(children: [
                    const Text('⭐',
                        style: TextStyle(fontSize: 10)),
                    const SizedBox(width: 2),
                    Text(
                        '$_rating · ${(widget.offer['reviews'] ?? 0)} κριτικές',
                        style: TextStyle(
                            color: _g(0.5),
                            fontSize: 10)),
                  ]),
                ])),
                // Gallery button
                GestureDetector(
                  onTap: widget.onGallery,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color: _g(0.06),
                      border: Border.all(color: _g(0.1)),
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Text('📸', style: TextStyle(fontSize: 14)),
                      const SizedBox(height: 2),
                      Text('Gallery',
                          style: TextStyle(
                              color: _g(0.55),
                              fontSize: 9,
                              fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ),
              ]),

              const SizedBox(height: 14),

              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(_price <= 0 ? 'Κατόπιν\nεκτίμησης' : '${_price.toInt()}€',
                    style: TextStyle(
                        fontFamily: 'Raleway',
                        fontSize: widget.isBest ? 32 : 26,
                        fontWeight: FontWeight.w900,
                        color: widget.isBest ? kGold : kGold.withValues(alpha: 0.7))),
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
                    text: '📍 ${(widget.offer['distance'] ?? '')}', green: false),
                if ((widget.offer['guarantee'] == true))
                  const _OfferTag(
                      text: '✅ Εγγύηση', green: true),
              ]),

              const SizedBox(height: 14),

              _PremiumButton(
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
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final doc = await FirebaseFirestore.instance
// [GAP: LINE 11209 NOT CAPTURED]
// [GAP: LINE 11210 NOT CAPTURED]
// [GAP: LINE 11211 NOT CAPTURED]
// [GAP: LINE 11212 NOT CAPTURED]
// [GAP: LINE 11213 NOT CAPTURED]
// [GAP: LINE 11214 NOT CAPTURED]
// [GAP: LINE 11215 NOT CAPTURED]
// [GAP: LINE 11216 NOT CAPTURED]
// [GAP: LINE 11217 NOT CAPTURED]
// [GAP: LINE 11218 NOT CAPTURED]
// [GAP: LINE 11219 NOT CAPTURED]
// [GAP: LINE 11220 NOT CAPTURED]
// [GAP: LINE 11221 NOT CAPTURED]
// [GAP: LINE 11222 NOT CAPTURED]
// [GAP: LINE 11223 NOT CAPTURED]
// [GAP: LINE 11224 NOT CAPTURED]
// [GAP: LINE 11225 NOT CAPTURED]
// [GAP: LINE 11226 NOT CAPTURED]
// [GAP: LINE 11227 NOT CAPTURED]
// [GAP: LINE 11228 NOT CAPTURED]
// [GAP: LINE 11229 NOT CAPTURED]
// [GAP: LINE 11230 NOT CAPTURED]
// [GAP: LINE 11231 NOT CAPTURED]
// [GAP: LINE 11232 NOT CAPTURED]
// [GAP: LINE 11233 NOT CAPTURED]
// [GAP: LINE 11234 NOT CAPTURED]
// [GAP: LINE 11235 NOT CAPTURED]
// [GAP: LINE 11236 NOT CAPTURED]
// [GAP: LINE 11237 NOT CAPTURED]
// [GAP: LINE 11238 NOT CAPTURED]
// [GAP: LINE 11239 NOT CAPTURED]
// [GAP: LINE 11240 NOT CAPTURED]
// [GAP: LINE 11241 NOT CAPTURED]
// [GAP: LINE 11242 NOT CAPTURED]
// [GAP: LINE 11243 NOT CAPTURED]
// [GAP: LINE 11244 NOT CAPTURED]
// [GAP: LINE 11245 NOT CAPTURED]
// [GAP: LINE 11246 NOT CAPTURED]
// [GAP: LINE 11247 NOT CAPTURED]
// [GAP: LINE 11248 NOT CAPTURED]
// [GAP: LINE 11249 NOT CAPTURED]
// [GAP: LINE 11250 NOT CAPTURED]
// [GAP: LINE 11251 NOT CAPTURED]
// [GAP: LINE 11252 NOT CAPTURED]
// [GAP: LINE 11253 NOT CAPTURED]
// [GAP: LINE 11254 NOT CAPTURED]
// [GAP: LINE 11255 NOT CAPTURED]
// [GAP: LINE 11256 NOT CAPTURED]
// [GAP: LINE 11257 NOT CAPTURED]
// [GAP: LINE 11258 NOT CAPTURED]
// [GAP: LINE 11259 NOT CAPTURED]
// [GAP: LINE 11260 NOT CAPTURED]
// [GAP: LINE 11261 NOT CAPTURED]
// [GAP: LINE 11262 NOT CAPTURED]
// [GAP: LINE 11263 NOT CAPTURED]
// [GAP: LINE 11264 NOT CAPTURED]
// [GAP: LINE 11265 NOT CAPTURED]
// [GAP: LINE 11266 NOT CAPTURED]
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

      // ── Step 5: Save to user history ──
      if (user != null) {
        await FirebaseFirestore.instance
            .collection('users').doc(user.uid)
            .collection('selectedProfessionals').add({
          'professionalName': proName,
          'professionalId': proId,
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

      // ── Step 6: Mark request as completed ──
                // Google rating badge (if linked)
                if (_googleRating != null && _googleRating! > 0) ...[
                  const SizedBox(height: 10),
                  GestureDetector(
                    onTap: _googleMapsUrl.isNotEmpty
                        ? () async {
                            try {
                              // ignore: deprecated_member_use
                              await launch(_googleMapsUrl);
                            } catch (_) {}
                          }
                        : null,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: const Color(0xFF4285F4).withValues(alpha: 0.07),
                        border: Border.all(color: const Color(0xFF4285F4).withValues(alpha: 0.25)),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Text('G', style: TextStyle(color: Color(0xFF4285F4),
                            fontSize: 15, fontWeight: FontWeight.w900)),
                        const SizedBox(width: 8),
                        const Icon(Icons.star, color: Color(0xFFFFC107), size: 14),
                        const SizedBox(width: 4),
                        Text(_googleRating!.toStringAsFixed(1),
                            style: const TextStyle(color: Colors.white,
                                fontSize: 14, fontWeight: FontWeight.w800)),
                        const SizedBox(width: 6),
                        Text('($_googleRatingCount κριτικές Google)',
                            style: TextStyle(color: _g(0.45), fontSize: 11)),
                        if (_googleMapsUrl.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.open_in_new, color: _g(0.3), size: 13),
                        ],
                      ]),
                    ),
                  ),
                ],
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
          chatId: chatId,
          currentUserId: user.uid,
          currentUserName: userName,
          otherName: proName,
          isPro: false,
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
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        decoration: BoxDecoration(borderRadius: BorderRadius.circular(14),
                            color: _g(0.04), border: Border.all(color: _g(0.08))),
                        child: Center(child: Text('Δεν υπάρχουν αξιολογήσεις ακόμα',
                            style: TextStyle(color: _g(0.3), fontSize: 12))),
                      );
                    }
                    final revDocs = revSnap.data!.docs;
                    if (revDocs.isEmpty) {
                      return Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 20),
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
                    return Column(mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: revDocs.map((rd) {
                      final rv = rd.data() as Map<String, dynamic>;
                      final rvRating = (rv['rating'] as int?) ?? 5;
                      final rvComment = (rv['comment'] as String?) ?? '';
                      final rvTs = rv['createdAt'] as Timestamp?;
                      final rvDate = rvTs != null ? rvTs.toDate() : DateTime.now();
                      final rvDateStr = '${rvDate.day}/${rvDate.month}/${rvDate.year}';
                      return Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          color: _g(0.04),
                          border: Border.all(color: kGold.withValues(alpha: 0.15)),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min, children: [
                          Row(children: [
                            Row(mainAxisSize: MainAxisSize.min,
                                children: List.generate(5, (si) => Icon(
                              si < rvRating ? Icons.star_rounded : Icons.star_outline_rounded,
                              color: si < rvRating ? kGold : _g(0.2), size: 15,
                            ))),
                            const Spacer(),
                            Text(rvDateStr, style: TextStyle(color: _g(0.3), fontSize: 10)),
                          ]),
                          if (rvComment.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(rvComment,
                                style: TextStyle(color: _g(0.65), fontSize: 12, height: 1.5)),
                          ],
                        ]),
                      );
                    }).toList());
                  },
                ),

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
                    ),
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 22),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.delete_outline_rounded, color: Colors.red, size: 22),
                      const SizedBox(height: 2),
                      Text('Διαγραφή', style: TextStyle(color: Colors.red.withValues(alpha: 0.8), fontSize: 10)),
                    ]),
                  ),
                  child: GestureDetector(
                    onTap: () => Navigator.push(context, PageRouteBuilder(
                      pageBuilder: (_, __, ___) => ChatScreen(
                        chatId: chatId,
                        currentUserId: widget.userId,
                        currentUserName: d['userName'] as String? ?? 'Χρήστης',
                        otherName: proName,
                        isPro: false,
                      ),
                      transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
                      transitionDuration: const Duration(milliseconds: 300),
                    )),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: unread > 0
                                ? kGold.withValues(alpha: 0.18)
                                : Colors.black.withValues(alpha: 0.35),
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
// [GAP: LINE 11553 NOT CAPTURED]
// [GAP: LINE 11554 NOT CAPTURED]
// [GAP: LINE 11555 NOT CAPTURED]
// [GAP: LINE 11556 NOT CAPTURED]
// [GAP: LINE 11557 NOT CAPTURED]
// [GAP: LINE 11558 NOT CAPTURED]
// [GAP: LINE 11559 NOT CAPTURED]
// [GAP: LINE 11560 NOT CAPTURED]
// [GAP: LINE 11561 NOT CAPTURED]
// [GAP: LINE 11562 NOT CAPTURED]
// [GAP: LINE 11563 NOT CAPTURED]
// [GAP: LINE 11564 NOT CAPTURED]
// [GAP: LINE 11565 NOT CAPTURED]
// [GAP: LINE 11566 NOT CAPTURED]
// [GAP: LINE 11567 NOT CAPTURED]
// [GAP: LINE 11568 NOT CAPTURED]
// [GAP: LINE 11569 NOT CAPTURED]
// [GAP: LINE 11570 NOT CAPTURED]
// [GAP: LINE 11571 NOT CAPTURED]
// [GAP: LINE 11572 NOT CAPTURED]
// [GAP: LINE 11573 NOT CAPTURED]
// [GAP: LINE 11574 NOT CAPTURED]
// [GAP: LINE 11575 NOT CAPTURED]
// [GAP: LINE 11576 NOT CAPTURED]
// [GAP: LINE 11577 NOT CAPTURED]
// [GAP: LINE 11578 NOT CAPTURED]
// [GAP: LINE 11579 NOT CAPTURED]
// [GAP: LINE 11580 NOT CAPTURED]
// [GAP: LINE 11581 NOT CAPTURED]
// [GAP: LINE 11582 NOT CAPTURED]
// [GAP: LINE 11583 NOT CAPTURED]
// [GAP: LINE 11584 NOT CAPTURED]
// [GAP: LINE 11585 NOT CAPTURED]
// [GAP: LINE 11586 NOT CAPTURED]
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
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: kGold.withValues(alpha: 0.08),
                        border: Border.all(
                            color: widget.isBest
                                ? kGold.withValues(alpha: 0.4)
                                : _g(0.12),
                            width: 1.5)),
                    child: ClipOval(
                      child: _photoUrl.isNotEmpty
                          ? Image.network(_photoUrl, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Center(child: Text(_emoji,
                                  style: const TextStyle(fontSize: 26))))
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
                          fontSize: 10)),
                  const SizedBox(height: 3),
                  Row(children: [
                    const Text('⭐',
                        style: TextStyle(fontSize: 10)),
                    const SizedBox(width: 2),
                    Text(
                        '$_rating · ${(widget.offer['reviews'] ?? 0)} κριτικές',
                        style: TextStyle(
                            color: _g(0.5),
                            fontSize: 10)),
                  ]),
                ])),
                // Gallery button
                GestureDetector(
                  onTap: widget.onGallery,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color: _g(0.06),
                      border: Border.all(color: _g(0.1)),
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Text('📸', style: TextStyle(fontSize: 14)),
                      const SizedBox(height: 2),
                      Text('Gallery',
                          style: TextStyle(
                              color: _g(0.55),
                              fontSize: 9,
        try {
          final ref = FirebaseStorage.instance
              .ref('chat_photos/${user.uid}/${DateTime.now().millisecondsSinceEpoch}_$i.jpg');
                ),
              ]),

              const SizedBox(height: 14),

              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(_price <= 0 ? 'Κατόπιν\nεκτίμησης' : '${_price.toInt()}€',
                    style: TextStyle(
                        fontFamily: 'Raleway',
                        fontSize: widget.isBest ? 32 : 26,
                        fontWeight: FontWeight.w900,
                        color: widget.isBest ? kGold : kGold.withValues(alpha: 0.7))),
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
                    text: '📍 ${(widget.offer['distance'] ?? '')}', green: false),
                if ((widget.offer['guarantee'] == true))
                  const _OfferTag(
                      text: '✅ Εγγύηση', green: true),
              ]),

              // Social media buttons
              Builder(builder: (ctx) {
                final ig = (widget.offer['instagram'] ?? '').toString();
                final tt = (widget.offer['tiktok'] ?? '').toString();
                if (ig.isEmpty && tt.isEmpty) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Row(children: [
                    if (ig.isNotEmpty)
                      GestureDetector(
                        onTap: () => launchUrl(
                            Uri.parse('https://www.instagram.com/$ig'),
                            mode: LaunchMode.externalApplication),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            gradient: const LinearGradient(
                              colors: [Color(0xFFF58529), Color(0xFFDD2A7B), Color(0xFF8134AF)],
                              begin: Alignment.topLeft, end: Alignment.bottomRight),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Text('📸', style: TextStyle(fontSize: 12)),
                            const SizedBox(width: 5),
                            Text('Instagram', style: const TextStyle(
                                color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                          ]),
                        ),
                      ),
                    if (ig.isNotEmpty && tt.isNotEmpty) const SizedBox(width: 8),
                    if (tt.isNotEmpty)
                      GestureDetector(
                        onTap: () => launchUrl(
                            Uri.parse('https://www.tiktok.com/@$tt'),
                            mode: LaunchMode.externalApplication),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            color: Colors.black,
                            border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Text('🎵', style: TextStyle(fontSize: 12)),
                            const SizedBox(width: 5),
                            const Text('TikTok', style: TextStyle(
                                color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                          ]),
                        ),
                      ),
                  ]),
                );
              }),

              const SizedBox(height: 14),

              _PremiumButton(
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
  }

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
              : (chatData['professionalId'] as String? ?? '');
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
// [GAP: LINE 11947 NOT CAPTURED]
// [GAP: LINE 11948 NOT CAPTURED]
// [GAP: LINE 11949 NOT CAPTURED]
// [GAP: LINE 11950 NOT CAPTURED]
// [GAP: LINE 11951 NOT CAPTURED]
// [GAP: LINE 11952 NOT CAPTURED]
// [GAP: LINE 11953 NOT CAPTURED]
// [GAP: LINE 11954 NOT CAPTURED]
// [GAP: LINE 11955 NOT CAPTURED]
// [GAP: LINE 11956 NOT CAPTURED]
// [GAP: LINE 11957 NOT CAPTURED]
// [GAP: LINE 11958 NOT CAPTURED]
// [GAP: LINE 11959 NOT CAPTURED]
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
              .collection('chats')
              .where('userId', isEqualTo: widget.userId)
              .snapshots(),
          builder: (context, snap) {
            if (snap.hasError)
              return Center(child: Text('Σφάλμα φόρτωσης', style: TextStyle(color: _g(0.3))));
            if (!snap.hasData)
              return const Center(child: CircularProgressIndicator(color: kGold));

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
                Container(width: 80, height: 80,
                  decoration: BoxDecoration(shape: BoxShape.circle,
                      color: kGold.withValues(alpha: 0.07),
                      border: Border.all(color: kGold.withValues(alpha: 0.15))),
                  child: const Center(child: Text('💬', style: TextStyle(fontSize: 34)))),
                const SizedBox(height: 18),
                const Text('Καμία συνομιλία ακόμα',
                    style: TextStyle(color: Colors.white, fontFamily: 'Raleway',
                        fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text('Επέλεξε επαγγελματία και πάτα\n"💬 Chat" για να ξεκινήσεις.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: _g(0.3), fontSize: 13, height: 1.5)),
              ]));
            }

            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              itemCount: docs.length,
              itemBuilder: (_, i) {
                final doc = docs[i];
                final d = doc.data() as Map<String, dynamic>;
                final chatId = doc.id;
                final proName = d['proName'] as String? ?? 'Επαγγελματίας';
                final proPhotoUrl = d['proPhotoUrl'] as String?;
                final lastMsg = d['lastMessage'] as String? ?? '';
                final ts = d['lastMessageAt'] as Timestamp?;
                final unread = (d['unreadUser'] as int?) ?? 0;

                // Smart time display
                String timeStr = '';
                if (ts != null) {
                  final now = DateTime.now();
                  final msgDate = ts.toDate();
                  if (now.difference(msgDate).inDays == 0) {
                    timeStr = '${msgDate.hour.toString().padLeft(2,'0')}:${msgDate.minute.toString().padLeft(2,'0')}';
                  } else if (now.difference(msgDate).inDays == 1) {
                    timeStr = 'Χθες';
                  } else {
                    timeStr = '${msgDate.day}/${msgDate.month}';
                  }
                }

class ProPortfolioScreen extends StatefulWidget {
  final Map<String, dynamic> pro;
  const ProPortfolioScreen({super.key, required this.pro});
  @override
  State<ProPortfolioScreen> createState() => _ProPortfolioScreenState();
}

class _ProPortfolioScreenState extends State<ProPortfolioScreen> {
  Uint8List? _photoBytes;
  double? _liveRating;
  int? _liveReviewCount;
  double? _googleRating;
  int _googleRatingCount = 0;
  String _googleMapsUrl = '';

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
    // Load Google rating from professionals collection
    final googlePlaceId = (widget.pro['googlePlaceId'] ?? '') as String;
    if (googlePlaceId.isNotEmpty) {
      // Try cached value first (already in pro map)
      final cached = (widget.pro['googleRating'] as num?)?.toDouble();
      final cachedCount = (widget.pro['googleRatingCount'] as num?)?.toInt() ?? 0;
      final cachedUrl = (widget.pro['googleMapsUrl'] as String?) ?? '';
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
          if (r != null && r > 0 && mounted) {
            setState(() { _googleRating = r; _googleRatingCount = c; _googleMapsUrl = mu; });
          }
        } catch (_) {}
      });
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
    // Prefer live rating fetched from users/{proId} (authoritative) over professionals map
    final rating = _liveRating ?? ((pro['averageRating'] ?? pro['rating'] ?? pro['average_rating'] ?? 0.0) as num).toDouble();
    final reviewCount = _liveReviewCount ?? ((pro['reviewCount'] ?? 0) as num).toInt();
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
                  _statPill('⭐', rating > 0 ? rating.toStringAsFixed(1) : '—',
                      reviewCount > 0 ? '$reviewCount κριτικές' : 'Βαθμολογία'),
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
                  fontFamily: 'Raleway', fontSize: 20, fontWeight: FontWeight.w800)),
// PRO PORTFOLIO SCREEN — View a professional's profile & portfolio
// ════════════════════════════════════════════════
class ProPortfolioScreen extends StatefulWidget {
  final Map<String, dynamic> pro;
  const ProPortfolioScreen({super.key, required this.pro});
  @override
  State<ProPortfolioScreen> createState() => _ProPortfolioScreenState();
}

class _ProPortfolioScreenState extends State<ProPortfolioScreen> {
  Uint8List? _photoBytes;
  double? _liveRating;
  int? _liveReviewCount;
  double? _googleRating;
  int _googleRatingCount = 0;
  String _googleMapsUrl = '';

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
    // Load Google rating from professionals collection
    final googlePlaceId = (widget.pro['googlePlaceId'] ?? '') as String;
    if (googlePlaceId.isNotEmpty) {
      // Try cached value first (already in pro map)
      final cached = (widget.pro['googleRating'] as num?)?.toDouble();
      final cachedCount = (widget.pro['googleRatingCount'] as num?)?.toInt() ?? 0;
      final cachedUrl = (widget.pro['googleMapsUrl'] as String?) ?? '';
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
          if (r != null && r > 0 && mounted) {
            setState(() { _googleRating = r; _googleRatingCount = c; _googleMapsUrl = mu; });
          }
        } catch (_) {}
      });
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
    // Prefer live rating fetched from users/{proId} (authoritative) over professionals map
    final rating = _liveRating ?? ((pro['averageRating'] ?? pro['rating'] ?? pro['average_rating'] ?? 0.0) as num).toDouble();
    final reviewCount = _liveReviewCount ?? ((pro['reviewCount'] ?? 0) as num).toInt();
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
                              TextButton(onPressed: () => Navigator.pop(context, true),
                                  child: const Text('Διαγραφή', style: TextStyle(color: Colors.redAccent))),
                            ],
                          ),
                        ) ?? false;
                      },
                      onDismissed: (_) => docs[i].reference.delete(),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 10),
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
                  _statPill('⭐', rating > 0 ? rating.toStringAsFixed(1) : '—',
                      reviewCount > 0 ? '$reviewCount κριτικές' : 'Βαθμολογία'),
                  const SizedBox(width: 8),
                  _statPill('🏆', jobs > 0 ? '$jobs' : 'Νέος', 'Έργα'),
                  const SizedBox(width: 8),
                  _statPill('⚡', '~30λ', 'Απόκριση'),
                ]),
      // Upload images first (fast — keep synchronous)
      final List<String> photoUrls = [];
      for (int i = 0; i < _selectedImages.length; i++) {
        try {
          final ref = FirebaseStorage.instance.ref(
              'chat_media/${widget.chatId}/${DateTime.now().millisecondsSinceEpoch}_img_$i.jpg');
          await ref.putData(_selectedImages[i], SettableMetadata(contentType: 'image/jpeg'));
          photoUrls.add(await ref.getDownloadURL());
        } catch (_) {}
      }

      // Capture pending videos BEFORE clearing state
      final List<dynamic> pendingVideos = List.from(_selectedVideoFiles);
      final bool hasVideos = pendingVideos.isNotEmpty;

      // Build preview text
      String previewText = text;
      if (photoUrls.isNotEmpty && text.isEmpty) previewText = '📷 ${photoUrls.length} φωτογραφία';
      if (hasVideos && text.isEmpty) previewText = '🎥 Βίντεο';

      final chatRef = FirebaseFirestore.instance.collection('chats').doc(widget.chatId);

      // Save message to Firestore immediately (videoUrls filled in later if needed)
      final msgRef = await chatRef.collection('messages').add({
        'text': text,
        'photoUrls': photoUrls,
        'videoUrls': <String>[],
        'senderId': widget.currentUserId,
        'senderName': widget.currentUserName,
        'createdAt': FieldValue.serverTimestamp(),
        if (hasVideos) 'videoUploading': true,
      });
      final unreadField = widget.isPro ? 'unreadUser' : 'unreadPro';
      await chatRef.set({
        'lastMessage': previewText,
        'lastMessageAt': FieldValue.serverTimestamp(),
        unreadField: FieldValue.increment(1),
        widget.isPro ? 'unreadPro' : 'unreadUser': 0,
      }, SetOptions(merge: true));

      // ── Unlock UI immediately ──
      if (mounted) setState(() {
        _selectedImages.clear();
        _selectedVideoFiles.clear();
        _selectedVideoNames.clear();
        _sending = false;
      });
      await Future.delayed(const Duration(milliseconds: 100));
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }

      // ── Upload videos in background, then update message doc ──
      if (hasVideos) {
        Future(() async {
          try {
            final List<String> videoUrls = [];
            for (int i = 0; i < pendingVideos.length; i++) {
              try {
                final xf = pendingVideos[i] as XFile;
                final bytes = await xf.readAsBytes();
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
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'fcmToken': fcmToken,
              'senderName': widget.currentUserName,
              'messagePreview': previewText,
            }),
          ).timeout(const Duration(seconds: 12));
// [GAP: LINE 12597 NOT CAPTURED]
// [GAP: LINE 12598 NOT CAPTURED]
// [GAP: LINE 12599 NOT CAPTURED]
// [GAP: LINE 12600 NOT CAPTURED]
// [GAP: LINE 12601 NOT CAPTURED]
// [GAP: LINE 12602 NOT CAPTURED]
// [GAP: LINE 12603 NOT CAPTURED]
// [GAP: LINE 12604 NOT CAPTURED]
// [GAP: LINE 12605 NOT CAPTURED]
// [GAP: LINE 12606 NOT CAPTURED]
// [GAP: LINE 12607 NOT CAPTURED]
// [GAP: LINE 12608 NOT CAPTURED]
// [GAP: LINE 12609 NOT CAPTURED]
// [GAP: LINE 12610 NOT CAPTURED]
// [GAP: LINE 12611 NOT CAPTURED]
// [GAP: LINE 12612 NOT CAPTURED]
// [GAP: LINE 12613 NOT CAPTURED]
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
// [GAP: LINE 12694 NOT CAPTURED]
// [GAP: LINE 12695 NOT CAPTURED]
// [GAP: LINE 12696 NOT CAPTURED]
// [GAP: LINE 12697 NOT CAPTURED]
// [GAP: LINE 12698 NOT CAPTURED]
// [GAP: LINE 12699 NOT CAPTURED]
// [GAP: LINE 12700 NOT CAPTURED]
// [GAP: LINE 12701 NOT CAPTURED]
// [GAP: LINE 12702 NOT CAPTURED]
// [GAP: LINE 12703 NOT CAPTURED]
// [GAP: LINE 12704 NOT CAPTURED]
// [GAP: LINE 12705 NOT CAPTURED]
// [GAP: LINE 12706 NOT CAPTURED]
// [GAP: LINE 12707 NOT CAPTURED]
// [GAP: LINE 12708 NOT CAPTURED]
// [GAP: LINE 12709 NOT CAPTURED]
// [GAP: LINE 12710 NOT CAPTURED]
// [GAP: LINE 12711 NOT CAPTURED]
// [GAP: LINE 12712 NOT CAPTURED]
// [GAP: LINE 12713 NOT CAPTURED]
// [GAP: LINE 12714 NOT CAPTURED]
// [GAP: LINE 12715 NOT CAPTURED]
// [GAP: LINE 12716 NOT CAPTURED]
// [GAP: LINE 12717 NOT CAPTURED]
// [GAP: LINE 12718 NOT CAPTURED]
// [GAP: LINE 12719 NOT CAPTURED]
// [GAP: LINE 12720 NOT CAPTURED]
// [GAP: LINE 12721 NOT CAPTURED]
// [GAP: LINE 12722 NOT CAPTURED]
// [GAP: LINE 12723 NOT CAPTURED]
// [GAP: LINE 12724 NOT CAPTURED]
// [GAP: LINE 12725 NOT CAPTURED]
// [GAP: LINE 12726 NOT CAPTURED]
// [GAP: LINE 12727 NOT CAPTURED]
// [GAP: LINE 12728 NOT CAPTURED]
// [GAP: LINE 12729 NOT CAPTURED]
// [GAP: LINE 12730 NOT CAPTURED]
// [GAP: LINE 12731 NOT CAPTURED]
// [GAP: LINE 12732 NOT CAPTURED]
// [GAP: LINE 12733 NOT CAPTURED]
// [GAP: LINE 12734 NOT CAPTURED]
// [GAP: LINE 12735 NOT CAPTURED]
// [GAP: LINE 12736 NOT CAPTURED]
// [GAP: LINE 12737 NOT CAPTURED]
// [GAP: LINE 12738 NOT CAPTURED]
// [GAP: LINE 12739 NOT CAPTURED]
// [GAP: LINE 12740 NOT CAPTURED]
// [GAP: LINE 12741 NOT CAPTURED]
// [GAP: LINE 12742 NOT CAPTURED]
// [GAP: LINE 12743 NOT CAPTURED]
// [GAP: LINE 12744 NOT CAPTURED]
// [GAP: LINE 12745 NOT CAPTURED]
// [GAP: LINE 12746 NOT CAPTURED]
// [GAP: LINE 12747 NOT CAPTURED]
// [GAP: LINE 12748 NOT CAPTURED]
// [GAP: LINE 12749 NOT CAPTURED]
// [GAP: LINE 12750 NOT CAPTURED]
// [GAP: LINE 12751 NOT CAPTURED]
// [GAP: LINE 12752 NOT CAPTURED]
// [GAP: LINE 12753 NOT CAPTURED]
// [GAP: LINE 12754 NOT CAPTURED]
// [GAP: LINE 12755 NOT CAPTURED]
// [GAP: LINE 12756 NOT CAPTURED]
// [GAP: LINE 12757 NOT CAPTURED]
// [GAP: LINE 12758 NOT CAPTURED]
// [GAP: LINE 12759 NOT CAPTURED]
// [GAP: LINE 12760 NOT CAPTURED]
// [GAP: LINE 12761 NOT CAPTURED]
// [GAP: LINE 12762 NOT CAPTURED]
// [GAP: LINE 12763 NOT CAPTURED]
// [GAP: LINE 12764 NOT CAPTURED]
// [GAP: LINE 12765 NOT CAPTURED]
// [GAP: LINE 12766 NOT CAPTURED]
// [GAP: LINE 12767 NOT CAPTURED]
// [GAP: LINE 12768 NOT CAPTURED]
// [GAP: LINE 12769 NOT CAPTURED]
                      label: 'Πολιτική απορρήτου',
                      value: '',
                      onTap: () async => launchUrl(
                          Uri.parse('https://gorealai.web.app/privacy'),
                          mode: LaunchMode.platformDefault)),
  Future<void> _sendMessage() async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty && _selectedImages.isEmpty && _selectedVideoFiles.isEmpty) return;
    if (_sending) return;
    _msgCtrl.clear();
    setState(() => _sending = true);

    try {
      // Upload images first (fast — keep synchronous)
      final List<String> photoUrls = [];
      for (int i = 0; i < _selectedImages.length; i++) {
        try {
          final ref = FirebaseStorage.instance.ref(
              'chat_media/${widget.chatId}/${DateTime.now().millisecondsSinceEpoch}_img_$i.jpg');
          await ref.putData(_selectedImages[i], SettableMetadata(contentType: 'image/jpeg'));
          photoUrls.add(await ref.getDownloadURL());
        } catch (_) {}
      }

      // Capture pending videos BEFORE clearing state
      final List<dynamic> pendingVideos = List.from(_selectedVideoFiles);
      final bool hasVideos = pendingVideos.isNotEmpty;

      // Build preview text
      String previewText = text;
      if (photoUrls.isNotEmpty && text.isEmpty) previewText = '📷 ${photoUrls.length} φωτογραφία';
      if (hasVideos && text.isEmpty) previewText = '🎥 Βίντεο';

      final chatRef = FirebaseFirestore.instance.collection('chats').doc(widget.chatId);

      // Save message to Firestore immediately (videoUrls filled in later if needed)
      final msgRef = await chatRef.collection('messages').add({
        'text': text,
        'photoUrls': photoUrls,
        'videoUrls': <String>[],
        'senderId': widget.currentUserId,
        'senderName': widget.currentUserName,
        'createdAt': FieldValue.serverTimestamp(),
        if (hasVideos) 'videoUploading': true,
      });
      final unreadField = widget.isPro ? 'unreadUser' : 'unreadPro';
      // Parse userId/proId from chatId (format: "userId_proId") so they are
      // always present on the doc — needed for the messages-list query.
      final chatParts = widget.chatId.split('_');
      final chatUserId = chatParts.isNotEmpty ? chatParts[0] : '';
      final chatProId  = chatParts.length > 1  ? chatParts[1] : '';
      await chatRef.set({
        'lastMessage': previewText,
        'lastMessageAt': FieldValue.serverTimestamp(),
        unreadField: FieldValue.increment(1),
        widget.isPro ? 'unreadPro' : 'unreadUser': 0,
        if (chatUserId.isNotEmpty) 'userId': chatUserId,
        if (chatProId.isNotEmpty)  'proId':  chatProId,
      }, SetOptions(merge: true));

      // ── Unlock UI immediately ──
      if (mounted) setState(() {
        _selectedImages.clear();
        _selectedVideoFiles.clear();
        _selectedVideoNames.clear();
        _sending = false;
      });
      await Future.delayed(const Duration(milliseconds: 100));
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }

      // ── Upload videos in background, then update message doc ──
      if (hasVideos) {
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
// [GAP: LINE 12908 NOT CAPTURED]
// [GAP: LINE 12909 NOT CAPTURED]
// [GAP: LINE 12910 NOT CAPTURED]
// [GAP: LINE 12911 NOT CAPTURED]
// [GAP: LINE 12912 NOT CAPTURED]
// [GAP: LINE 12913 NOT CAPTURED]
// [GAP: LINE 12914 NOT CAPTURED]
// [GAP: LINE 12915 NOT CAPTURED]
// [GAP: LINE 12916 NOT CAPTURED]
// [GAP: LINE 12917 NOT CAPTURED]
// [GAP: LINE 12918 NOT CAPTURED]
// [GAP: LINE 12919 NOT CAPTURED]
// [GAP: LINE 12920 NOT CAPTURED]
// [GAP: LINE 12921 NOT CAPTURED]
// [GAP: LINE 12922 NOT CAPTURED]
// [GAP: LINE 12923 NOT CAPTURED]
// [GAP: LINE 12924 NOT CAPTURED]
// [GAP: LINE 12925 NOT CAPTURED]
// [GAP: LINE 12926 NOT CAPTURED]
// [GAP: LINE 12927 NOT CAPTURED]
// [GAP: LINE 12928 NOT CAPTURED]
// [GAP: LINE 12929 NOT CAPTURED]
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
// [GAP: LINE 13030 NOT CAPTURED]
// [GAP: LINE 13031 NOT CAPTURED]
// [GAP: LINE 13032 NOT CAPTURED]
// [GAP: LINE 13033 NOT CAPTURED]
// [GAP: LINE 13034 NOT CAPTURED]
// [GAP: LINE 13035 NOT CAPTURED]
// [GAP: LINE 13036 NOT CAPTURED]
// [GAP: LINE 13037 NOT CAPTURED]
// [GAP: LINE 13038 NOT CAPTURED]
// [GAP: LINE 13039 NOT CAPTURED]
// [GAP: LINE 13040 NOT CAPTURED]
// [GAP: LINE 13041 NOT CAPTURED]
// [GAP: LINE 13042 NOT CAPTURED]
// [GAP: LINE 13043 NOT CAPTURED]
// [GAP: LINE 13044 NOT CAPTURED]
// [GAP: LINE 13045 NOT CAPTURED]
// [GAP: LINE 13046 NOT CAPTURED]
// [GAP: LINE 13047 NOT CAPTURED]
// [GAP: LINE 13048 NOT CAPTURED]
// [GAP: LINE 13049 NOT CAPTURED]
// [GAP: LINE 13050 NOT CAPTURED]
// [GAP: LINE 13051 NOT CAPTURED]
// [GAP: LINE 13052 NOT CAPTURED]
// [GAP: LINE 13053 NOT CAPTURED]
// [GAP: LINE 13054 NOT CAPTURED]
// [GAP: LINE 13055 NOT CAPTURED]
// [GAP: LINE 13056 NOT CAPTURED]
// [GAP: LINE 13057 NOT CAPTURED]
// [GAP: LINE 13058 NOT CAPTURED]
// [GAP: LINE 13059 NOT CAPTURED]
// [GAP: LINE 13060 NOT CAPTURED]
// [GAP: LINE 13061 NOT CAPTURED]
// [GAP: LINE 13062 NOT CAPTURED]
// [GAP: LINE 13063 NOT CAPTURED]
// [GAP: LINE 13064 NOT CAPTURED]
// [GAP: LINE 13065 NOT CAPTURED]
// [GAP: LINE 13066 NOT CAPTURED]
// [GAP: LINE 13067 NOT CAPTURED]
// [GAP: LINE 13068 NOT CAPTURED]
// [GAP: LINE 13069 NOT CAPTURED]
// [GAP: LINE 13070 NOT CAPTURED]
// [GAP: LINE 13071 NOT CAPTURED]
// [GAP: LINE 13072 NOT CAPTURED]
// [GAP: LINE 13073 NOT CAPTURED]
// [GAP: LINE 13074 NOT CAPTURED]
// [GAP: LINE 13075 NOT CAPTURED]
// [GAP: LINE 13076 NOT CAPTURED]
// [GAP: LINE 13077 NOT CAPTURED]
// [GAP: LINE 13078 NOT CAPTURED]
// [GAP: LINE 13079 NOT CAPTURED]
// [GAP: LINE 13080 NOT CAPTURED]
// [GAP: LINE 13081 NOT CAPTURED]
// [GAP: LINE 13082 NOT CAPTURED]
// [GAP: LINE 13083 NOT CAPTURED]
// [GAP: LINE 13084 NOT CAPTURED]
// [GAP: LINE 13085 NOT CAPTURED]
// [GAP: LINE 13086 NOT CAPTURED]
// [GAP: LINE 13087 NOT CAPTURED]
// [GAP: LINE 13088 NOT CAPTURED]
// [GAP: LINE 13089 NOT CAPTURED]
// [GAP: LINE 13090 NOT CAPTURED]
// [GAP: LINE 13091 NOT CAPTURED]
// [GAP: LINE 13092 NOT CAPTURED]
// [GAP: LINE 13093 NOT CAPTURED]
// [GAP: LINE 13094 NOT CAPTURED]
// [GAP: LINE 13095 NOT CAPTURED]
// [GAP: LINE 13096 NOT CAPTURED]
// [GAP: LINE 13097 NOT CAPTURED]
// [GAP: LINE 13098 NOT CAPTURED]
// [GAP: LINE 13099 NOT CAPTURED]
// [GAP: LINE 13100 NOT CAPTURED]
// [GAP: LINE 13101 NOT CAPTURED]
// [GAP: LINE 13102 NOT CAPTURED]
// [GAP: LINE 13103 NOT CAPTURED]
// [GAP: LINE 13104 NOT CAPTURED]
// [GAP: LINE 13105 NOT CAPTURED]
// [GAP: LINE 13106 NOT CAPTURED]
// [GAP: LINE 13107 NOT CAPTURED]
// [GAP: LINE 13108 NOT CAPTURED]
// [GAP: LINE 13109 NOT CAPTURED]
// [GAP: LINE 13110 NOT CAPTURED]
// [GAP: LINE 13111 NOT CAPTURED]
// [GAP: LINE 13112 NOT CAPTURED]
// [GAP: LINE 13113 NOT CAPTURED]
// [GAP: LINE 13114 NOT CAPTURED]
// [GAP: LINE 13115 NOT CAPTURED]
// [GAP: LINE 13116 NOT CAPTURED]
// [GAP: LINE 13117 NOT CAPTURED]
// [GAP: LINE 13118 NOT CAPTURED]
// [GAP: LINE 13119 NOT CAPTURED]
// [GAP: LINE 13120 NOT CAPTURED]
// [GAP: LINE 13121 NOT CAPTURED]
// [GAP: LINE 13122 NOT CAPTURED]
// [GAP: LINE 13123 NOT CAPTURED]
// [GAP: LINE 13124 NOT CAPTURED]
// [GAP: LINE 13125 NOT CAPTURED]
// [GAP: LINE 13126 NOT CAPTURED]
// [GAP: LINE 13127 NOT CAPTURED]
// [GAP: LINE 13128 NOT CAPTURED]
// [GAP: LINE 13129 NOT CAPTURED]
// [GAP: LINE 13130 NOT CAPTURED]
// [GAP: LINE 13131 NOT CAPTURED]
// [GAP: LINE 13132 NOT CAPTURED]
// [GAP: LINE 13133 NOT CAPTURED]
// [GAP: LINE 13134 NOT CAPTURED]
// [GAP: LINE 13135 NOT CAPTURED]
// [GAP: LINE 13136 NOT CAPTURED]
// [GAP: LINE 13137 NOT CAPTURED]
// [GAP: LINE 13138 NOT CAPTURED]
// [GAP: LINE 13139 NOT CAPTURED]
// [GAP: LINE 13140 NOT CAPTURED]
// [GAP: LINE 13141 NOT CAPTURED]
// [GAP: LINE 13142 NOT CAPTURED]
// [GAP: LINE 13143 NOT CAPTURED]
// [GAP: LINE 13144 NOT CAPTURED]
// [GAP: LINE 13145 NOT CAPTURED]
// [GAP: LINE 13146 NOT CAPTURED]
// [GAP: LINE 13147 NOT CAPTURED]
// [GAP: LINE 13148 NOT CAPTURED]
// [GAP: LINE 13149 NOT CAPTURED]
// [GAP: LINE 13150 NOT CAPTURED]
// [GAP: LINE 13151 NOT CAPTURED]
// [GAP: LINE 13152 NOT CAPTURED]
// [GAP: LINE 13153 NOT CAPTURED]
// [GAP: LINE 13154 NOT CAPTURED]
// [GAP: LINE 13155 NOT CAPTURED]
// [GAP: LINE 13156 NOT CAPTURED]
// [GAP: LINE 13157 NOT CAPTURED]
// [GAP: LINE 13158 NOT CAPTURED]
// [GAP: LINE 13159 NOT CAPTURED]
// [GAP: LINE 13160 NOT CAPTURED]
// [GAP: LINE 13161 NOT CAPTURED]
// [GAP: LINE 13162 NOT CAPTURED]
// [GAP: LINE 13163 NOT CAPTURED]
// [GAP: LINE 13164 NOT CAPTURED]
// [GAP: LINE 13165 NOT CAPTURED]
// [GAP: LINE 13166 NOT CAPTURED]
// [GAP: LINE 13167 NOT CAPTURED]
// [GAP: LINE 13168 NOT CAPTURED]
// [GAP: LINE 13169 NOT CAPTURED]
// [GAP: LINE 13170 NOT CAPTURED]
// [GAP: LINE 13171 NOT CAPTURED]
// [GAP: LINE 13172 NOT CAPTURED]
// [GAP: LINE 13173 NOT CAPTURED]
// [GAP: LINE 13174 NOT CAPTURED]
// [GAP: LINE 13175 NOT CAPTURED]
// [GAP: LINE 13176 NOT CAPTURED]
// [GAP: LINE 13177 NOT CAPTURED]
// [GAP: LINE 13178 NOT CAPTURED]
// [GAP: LINE 13179 NOT CAPTURED]
// [GAP: LINE 13180 NOT CAPTURED]
// [GAP: LINE 13181 NOT CAPTURED]
// [GAP: LINE 13182 NOT CAPTURED]
// [GAP: LINE 13183 NOT CAPTURED]
// [GAP: LINE 13184 NOT CAPTURED]
// [GAP: LINE 13185 NOT CAPTURED]
// [GAP: LINE 13186 NOT CAPTURED]
// [GAP: LINE 13187 NOT CAPTURED]
// [GAP: LINE 13188 NOT CAPTURED]
// [GAP: LINE 13189 NOT CAPTURED]
// [GAP: LINE 13190 NOT CAPTURED]
// [GAP: LINE 13191 NOT CAPTURED]
// [GAP: LINE 13192 NOT CAPTURED]
// [GAP: LINE 13193 NOT CAPTURED]
// [GAP: LINE 13194 NOT CAPTURED]
// [GAP: LINE 13195 NOT CAPTURED]
// [GAP: LINE 13196 NOT CAPTURED]
// [GAP: LINE 13197 NOT CAPTURED]
// [GAP: LINE 13198 NOT CAPTURED]
// [GAP: LINE 13199 NOT CAPTURED]
// [GAP: LINE 13200 NOT CAPTURED]
// [GAP: LINE 13201 NOT CAPTURED]
// [GAP: LINE 13202 NOT CAPTURED]
// [GAP: LINE 13203 NOT CAPTURED]
// [GAP: LINE 13204 NOT CAPTURED]
// [GAP: LINE 13205 NOT CAPTURED]
// [GAP: LINE 13206 NOT CAPTURED]
// [GAP: LINE 13207 NOT CAPTURED]
// [GAP: LINE 13208 NOT CAPTURED]
// [GAP: LINE 13209 NOT CAPTURED]
// [GAP: LINE 13210 NOT CAPTURED]
// [GAP: LINE 13211 NOT CAPTURED]
// [GAP: LINE 13212 NOT CAPTURED]
// [GAP: LINE 13213 NOT CAPTURED]
// [GAP: LINE 13214 NOT CAPTURED]
// [GAP: LINE 13215 NOT CAPTURED]
// [GAP: LINE 13216 NOT CAPTURED]
// [GAP: LINE 13217 NOT CAPTURED]
// [GAP: LINE 13218 NOT CAPTURED]
// [GAP: LINE 13219 NOT CAPTURED]
// [GAP: LINE 13220 NOT CAPTURED]
// [GAP: LINE 13221 NOT CAPTURED]
// [GAP: LINE 13222 NOT CAPTURED]
// [GAP: LINE 13223 NOT CAPTURED]
// [GAP: LINE 13224 NOT CAPTURED]
// [GAP: LINE 13225 NOT CAPTURED]
// [GAP: LINE 13226 NOT CAPTURED]
// [GAP: LINE 13227 NOT CAPTURED]
// [GAP: LINE 13228 NOT CAPTURED]
// [GAP: LINE 13229 NOT CAPTURED]
// [GAP: LINE 13230 NOT CAPTURED]
// [GAP: LINE 13231 NOT CAPTURED]
// [GAP: LINE 13232 NOT CAPTURED]
// [GAP: LINE 13233 NOT CAPTURED]
// [GAP: LINE 13234 NOT CAPTURED]
// [GAP: LINE 13235 NOT CAPTURED]
// [GAP: LINE 13236 NOT CAPTURED]
// [GAP: LINE 13237 NOT CAPTURED]
// [GAP: LINE 13238 NOT CAPTURED]
// [GAP: LINE 13239 NOT CAPTURED]
// [GAP: LINE 13240 NOT CAPTURED]
// [GAP: LINE 13241 NOT CAPTURED]
// [GAP: LINE 13242 NOT CAPTURED]
// [GAP: LINE 13243 NOT CAPTURED]
// [GAP: LINE 13244 NOT CAPTURED]
// [GAP: LINE 13245 NOT CAPTURED]
// [GAP: LINE 13246 NOT CAPTURED]
// [GAP: LINE 13247 NOT CAPTURED]
// [GAP: LINE 13248 NOT CAPTURED]
// [GAP: LINE 13249 NOT CAPTURED]
                : _docs.isEmpty
                    ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.notifications_none, color: _g(0.15), size: 52),
                        const SizedBox(height: 12),
class _ProfileScreenState extends State<ProfileScreen> {
  String? _name, _email, _city;
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
// [GAP: LINE 13454 NOT CAPTURED]
// [GAP: LINE 13455 NOT CAPTURED]
// [GAP: LINE 13456 NOT CAPTURED]
// [GAP: LINE 13457 NOT CAPTURED]
// [GAP: LINE 13458 NOT CAPTURED]
// [GAP: LINE 13459 NOT CAPTURED]
// [GAP: LINE 13460 NOT CAPTURED]
// [GAP: LINE 13461 NOT CAPTURED]
// [GAP: LINE 13462 NOT CAPTURED]
// [GAP: LINE 13463 NOT CAPTURED]
// [GAP: LINE 13464 NOT CAPTURED]
// [GAP: LINE 13465 NOT CAPTURED]
// [GAP: LINE 13466 NOT CAPTURED]
// [GAP: LINE 13467 NOT CAPTURED]
// [GAP: LINE 13468 NOT CAPTURED]
// [GAP: LINE 13469 NOT CAPTURED]
// [GAP: LINE 13470 NOT CAPTURED]
// [GAP: LINE 13471 NOT CAPTURED]
// [GAP: LINE 13472 NOT CAPTURED]
// [GAP: LINE 13473 NOT CAPTURED]
// [GAP: LINE 13474 NOT CAPTURED]
// [GAP: LINE 13475 NOT CAPTURED]
// [GAP: LINE 13476 NOT CAPTURED]
// [GAP: LINE 13477 NOT CAPTURED]
// [GAP: LINE 13478 NOT CAPTURED]
// [GAP: LINE 13479 NOT CAPTURED]
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
  String? _selectedArea;
  bool _submitting = false;

  static const _eventAreas = [
    'Αθήνα Κέντρο', 'Κολωνάκι', 'Εξάρχεια', 'Παγκράτι', 'Πετράλωνα', 'Κουκάκι', 'Νέος Κόσμος',
    'Γλυφάδα', 'Βούλα', 'Βουλιαγμένη', 'Καλλιθέα', 'Μοσχάτο', 'Ταύρος', 'Νέα Σμύρνη',
    'Παλαιό Φάληρο', 'Άλιμος', 'Αργυρούπολη', 'Ελληνικό', 'Χαλάνδρι', 'Μαρούσι', 'Κηφισιά',
    'Βριλήσσια', 'Νέα Ιωνία', 'Ηράκλειο Αττικής', 'Μεταμόρφωση', 'Αγία Παρασκευή', 'Παπάγου',
    'Χολαργός', 'Ζωγράφου', 'Βύρωνας', 'Καισαριανή', 'Ηλιούπολη', 'Άγιος Δημήτριος', 'Δάφνη',
    'Υμηττός', 'Περιστέρι', 'Αιγάλεω', 'Χαϊδάρι', 'Πετρούπολη', 'Ίλιον', 'Αγία Βαρβάρα',
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
      'pros': ['Εκδηλώσεις Γάμου', 'Φωτογράφος Γάμου', 'DJ / Μουσική Εκδηλώσεων',
               'Catering', 'Ανθοδέτης / Στολισμός', 'Αίθουσα Εκδηλώσεων'],
    },
    {
      'id': 'baptism',
      'emoji': '👶',
      'title': 'Βάφτιση',
      'subtitle': 'Φωτογράφος · Catering · Στολισμός · Μπομπονιέρες',
      'pros': ['Εκδηλώσεις Βάφτισης', 'Φωτογράφος Γάμου', 'Catering',
               'Ανθοδέτης / Στολισμός', 'Αίθουσα Εκδηλώσεων'],
    },
    {
      'id': 'party',
      'emoji': '🎉',
      'title': 'Πάρτυ',
      'subtitle': 'DJ · Catering · Στολισμός · Φωτογράφος',
      'pros': ['Διοργάνωση Πάρτυ', 'DJ / Μουσική Εκδηλώσεων', 'Catering',
               'Ανθοδέτης / Στολισμός', 'Αίθουσα Εκδηλώσεων', 'Φωτογράφος Γάμου'],
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
                style: TextStyle(fontFamily: 'Raleway', fontSize: 30,
                    fontWeight: FontWeight.w900, color: Colors.white)),
          ),
          const SizedBox(height: 6),
          Text('Επέλεξε κατηγορία και το AI σου βρίσκει\nτους καλύτερους επαγγελματίες.',
              style: TextStyle(color: _g(0.45), fontSize: 14, height: 1.5)),
        ]),
      ),
      const SizedBox(height: 32),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(children: _categories.map((cat) {
            return GestureDetector(
              onTap: () {
                // Reset form fields for fresh entry per category
                _locationCtrl.clear();
                _notesCtrl.clear();
                setState(() {
                  _categoryId = cat['id'] as String;
                  _categoryTitle = cat['title'] as String;
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
// [GAP: LINE 13729 NOT CAPTURED]
// [GAP: LINE 13730 NOT CAPTURED]
// [GAP: LINE 13731 NOT CAPTURED]
// [GAP: LINE 13732 NOT CAPTURED]
// [GAP: LINE 13733 NOT CAPTURED]
// [GAP: LINE 13734 NOT CAPTURED]
// [GAP: LINE 13735 NOT CAPTURED]
// [GAP: LINE 13736 NOT CAPTURED]
// [GAP: LINE 13737 NOT CAPTURED]
// [GAP: LINE 13738 NOT CAPTURED]
// [GAP: LINE 13739 NOT CAPTURED]
// [GAP: LINE 13740 NOT CAPTURED]
// [GAP: LINE 13741 NOT CAPTURED]
// [GAP: LINE 13742 NOT CAPTURED]
// [GAP: LINE 13743 NOT CAPTURED]
// [GAP: LINE 13744 NOT CAPTURED]
// [GAP: LINE 13745 NOT CAPTURED]
// [GAP: LINE 13746 NOT CAPTURED]
// [GAP: LINE 13747 NOT CAPTURED]
// [GAP: LINE 13748 NOT CAPTURED]
// [GAP: LINE 13749 NOT CAPTURED]
// [GAP: LINE 13750 NOT CAPTURED]
// [GAP: LINE 13751 NOT CAPTURED]
// [GAP: LINE 13752 NOT CAPTURED]
// [GAP: LINE 13753 NOT CAPTURED]
// [GAP: LINE 13754 NOT CAPTURED]
// [GAP: LINE 13755 NOT CAPTURED]
// [GAP: LINE 13756 NOT CAPTURED]
// [GAP: LINE 13757 NOT CAPTURED]
// [GAP: LINE 13758 NOT CAPTURED]
// [GAP: LINE 13759 NOT CAPTURED]
// [GAP: LINE 13760 NOT CAPTURED]
// [GAP: LINE 13761 NOT CAPTURED]
// [GAP: LINE 13762 NOT CAPTURED]
// [GAP: LINE 13763 NOT CAPTURED]
// [GAP: LINE 13764 NOT CAPTURED]
// [GAP: LINE 13765 NOT CAPTURED]
// [GAP: LINE 13766 NOT CAPTURED]
// [GAP: LINE 13767 NOT CAPTURED]
// [GAP: LINE 13768 NOT CAPTURED]
// [GAP: LINE 13769 NOT CAPTURED]
// [GAP: LINE 13770 NOT CAPTURED]
// [GAP: LINE 13771 NOT CAPTURED]
// [GAP: LINE 13772 NOT CAPTURED]
// [GAP: LINE 13773 NOT CAPTURED]
// [GAP: LINE 13774 NOT CAPTURED]
// [GAP: LINE 13775 NOT CAPTURED]
// [GAP: LINE 13776 NOT CAPTURED]
// [GAP: LINE 13777 NOT CAPTURED]
// [GAP: LINE 13778 NOT CAPTURED]
// [GAP: LINE 13779 NOT CAPTURED]
// [GAP: LINE 13780 NOT CAPTURED]
// [GAP: LINE 13781 NOT CAPTURED]
// [GAP: LINE 13782 NOT CAPTURED]
// [GAP: LINE 13783 NOT CAPTURED]
// [GAP: LINE 13784 NOT CAPTURED]
// [GAP: LINE 13785 NOT CAPTURED]
// [GAP: LINE 13786 NOT CAPTURED]
// [GAP: LINE 13787 NOT CAPTURED]
// [GAP: LINE 13788 NOT CAPTURED]
// [GAP: LINE 13789 NOT CAPTURED]
// [GAP: LINE 13790 NOT CAPTURED]
// [GAP: LINE 13791 NOT CAPTURED]
// [GAP: LINE 13792 NOT CAPTURED]
// [GAP: LINE 13793 NOT CAPTURED]
// [GAP: LINE 13794 NOT CAPTURED]
// [GAP: LINE 13795 NOT CAPTURED]
// [GAP: LINE 13796 NOT CAPTURED]
// [GAP: LINE 13797 NOT CAPTURED]
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
// [GAP: LINE 13833 NOT CAPTURED]
// [GAP: LINE 13834 NOT CAPTURED]
// [GAP: LINE 13835 NOT CAPTURED]
// [GAP: LINE 13836 NOT CAPTURED]
// [GAP: LINE 13837 NOT CAPTURED]
// [GAP: LINE 13838 NOT CAPTURED]
// [GAP: LINE 13839 NOT CAPTURED]
// [GAP: LINE 13840 NOT CAPTURED]
// [GAP: LINE 13841 NOT CAPTURED]
// [GAP: LINE 13842 NOT CAPTURED]
// [GAP: LINE 13843 NOT CAPTURED]
// [GAP: LINE 13844 NOT CAPTURED]
// [GAP: LINE 13845 NOT CAPTURED]
// [GAP: LINE 13846 NOT CAPTURED]
// [GAP: LINE 13847 NOT CAPTURED]
// [GAP: LINE 13848 NOT CAPTURED]
// [GAP: LINE 13849 NOT CAPTURED]
// [GAP: LINE 13850 NOT CAPTURED]
// [GAP: LINE 13851 NOT CAPTURED]
// [GAP: LINE 13852 NOT CAPTURED]
// [GAP: LINE 13853 NOT CAPTURED]
// [GAP: LINE 13854 NOT CAPTURED]
// [GAP: LINE 13855 NOT CAPTURED]
// [GAP: LINE 13856 NOT CAPTURED]
// [GAP: LINE 13857 NOT CAPTURED]
// [GAP: LINE 13858 NOT CAPTURED]
// [GAP: LINE 13859 NOT CAPTURED]
// [GAP: LINE 13860 NOT CAPTURED]
// [GAP: LINE 13861 NOT CAPTURED]
// [GAP: LINE 13862 NOT CAPTURED]
// [GAP: LINE 13863 NOT CAPTURED]
// [GAP: LINE 13864 NOT CAPTURED]
// [GAP: LINE 13865 NOT CAPTURED]
// [GAP: LINE 13866 NOT CAPTURED]
// [GAP: LINE 13867 NOT CAPTURED]
// [GAP: LINE 13868 NOT CAPTURED]
// [GAP: LINE 13869 NOT CAPTURED]
// [GAP: LINE 13870 NOT CAPTURED]
// [GAP: LINE 13871 NOT CAPTURED]
// [GAP: LINE 13872 NOT CAPTURED]
// [GAP: LINE 13873 NOT CAPTURED]
// [GAP: LINE 13874 NOT CAPTURED]
// [GAP: LINE 13875 NOT CAPTURED]
// [GAP: LINE 13876 NOT CAPTURED]
// [GAP: LINE 13877 NOT CAPTURED]
// [GAP: LINE 13878 NOT CAPTURED]
// [GAP: LINE 13879 NOT CAPTURED]
// [GAP: LINE 13880 NOT CAPTURED]
// [GAP: LINE 13881 NOT CAPTURED]
// [GAP: LINE 13882 NOT CAPTURED]
// [GAP: LINE 13883 NOT CAPTURED]
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
// [GAP: LINE 14004 NOT CAPTURED]
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
// [GAP: LINE 14065 NOT CAPTURED]
// [GAP: LINE 14066 NOT CAPTURED]
// [GAP: LINE 14067 NOT CAPTURED]
// [GAP: LINE 14068 NOT CAPTURED]
// [GAP: LINE 14069 NOT CAPTURED]
// [GAP: LINE 14070 NOT CAPTURED]
// [GAP: LINE 14071 NOT CAPTURED]
// [GAP: LINE 14072 NOT CAPTURED]
// [GAP: LINE 14073 NOT CAPTURED]
// [GAP: LINE 14074 NOT CAPTURED]
// [GAP: LINE 14075 NOT CAPTURED]
// [GAP: LINE 14076 NOT CAPTURED]
// [GAP: LINE 14077 NOT CAPTURED]
// [GAP: LINE 14078 NOT CAPTURED]
// [GAP: LINE 14079 NOT CAPTURED]
// [GAP: LINE 14080 NOT CAPTURED]
// [GAP: LINE 14081 NOT CAPTURED]
// [GAP: LINE 14082 NOT CAPTURED]
// [GAP: LINE 14083 NOT CAPTURED]
// [GAP: LINE 14084 NOT CAPTURED]
// [GAP: LINE 14085 NOT CAPTURED]
// [GAP: LINE 14086 NOT CAPTURED]
// [GAP: LINE 14087 NOT CAPTURED]
// [GAP: LINE 14088 NOT CAPTURED]
// [GAP: LINE 14089 NOT CAPTURED]
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
                            // Chat button (premium gate)
                            GestureDetector(
                            // Chat button (premium gate)
                            GestureDetector(
                              onTap: () async {
                                final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
                                final proId = d['professionalId'] as String? ?? '';
                                if (uid.isEmpty) return;

                                // Premium check
                                bool isPremium = false;
                                try {
                                  final userDoc = await FirebaseFirestore.instance
                                      .collection('users').doc(uid).get();
                                  isPremium = userDoc.data()?['isPremium'] == true || userDoc.data()?['isOwner'] == true;
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
                                    currentUserName: '',
                                    otherName: proName,
                                    isPro: false,
                                  ),
                                  transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
                                  transitionDuration: const Duration(milliseconds: 300),
                                ));
                                FirebaseFirestore.instance.collection('chats').doc(chatId)
                                    .set({
                                  'userId': uid, 'proId': proId,
                                  'userName': '', 'proName': proName,
                                  'lastMessageAt': FieldValue.serverTimestamp(),
                                }, SetOptions(merge: true)).catchError((_) {});
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(20),
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
  final List<XFile> _images = [];
  final List<XFile> _videoFiles = [];
  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1000))
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _cityCtrl.dispose();
    _oldPassCtrl.dispose();
    _newPassCtrl.dispose();
    super.dispose();
  }
    with TickerProviderStateMixin {
  final _textCtrl = TextEditingController();
  String? _selectedTeamType;
  String? _selectedLocation;
  String _selectedCriteria = 'cheap';
  bool _wantsImmediate = false;
  double? _minRating;
  bool _wantsWithPhotos = false;
  bool _sending = false;
  late AnimationController _pulseCtrl;
  final List<XFile> _images = [];
  final List<XFile> _videoFiles = [];
  final _picker = ImagePicker();

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

  Future<void> _pickMedia() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          gradient: const LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [Color(0xFF2a2a2a), Color(0xFF1a1a1a)],
          ),
          border: Border(top: BorderSide(color: Colors.white.withOpacity(0.10))),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
              height: 40,
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: kGold.withValues(alpha: 0.15),
// [GAP: LINE 14434 NOT CAPTURED]
// [GAP: LINE 14435 NOT CAPTURED]
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
// [GAP: LINE 14459 NOT CAPTURED]
// [GAP: LINE 14460 NOT CAPTURED]
// [GAP: LINE 14461 NOT CAPTURED]
// [GAP: LINE 14462 NOT CAPTURED]
// [GAP: LINE 14463 NOT CAPTURED]
// [GAP: LINE 14464 NOT CAPTURED]
// [GAP: LINE 14465 NOT CAPTURED]
// [GAP: LINE 14466 NOT CAPTURED]
// [GAP: LINE 14467 NOT CAPTURED]
// [GAP: LINE 14468 NOT CAPTURED]
// [GAP: LINE 14469 NOT CAPTURED]
// [GAP: LINE 14470 NOT CAPTURED]
// [GAP: LINE 14471 NOT CAPTURED]
// [GAP: LINE 14472 NOT CAPTURED]
// [GAP: LINE 14473 NOT CAPTURED]
// [GAP: LINE 14474 NOT CAPTURED]
// [GAP: LINE 14475 NOT CAPTURED]
// [GAP: LINE 14476 NOT CAPTURED]
// [GAP: LINE 14477 NOT CAPTURED]
// [GAP: LINE 14478 NOT CAPTURED]
// [GAP: LINE 14479 NOT CAPTURED]
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
              urls.add('https://firebasestorage.googleapis.com/v0/b/$bucket'
                  '/o/$encodedPath?alt=media&token=$token');
            } catch (e) {
              debugPrint('Project video upload error: $e');
            }
          }
          if (urls.isNotEmpty) {
            await FirebaseFirestore.instance.collection('project_requests').doc(docId)
                .update({'videoUrls': urls, 'hasVideos': true});
          }
        });
      }

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 600),
          pageBuilder: (_, __, ___) => WaitingScreen(
            requestId: docRef.id,
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
  const _MultiAreaPicker({required this.initial});
  @override
  State<_MultiAreaPicker> createState() => _MultiAreaPickerState();
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
      'Συντήρηση Κλιματιστικών', 'Εγκατάσταση Ηλιακών',
      'Υπηρεσία Αποξήλωσης'
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
// [GAP: LINE 14694 NOT CAPTURED]
// [GAP: LINE 14695 NOT CAPTURED]
// [GAP: LINE 14696 NOT CAPTURED]
// [GAP: LINE 14697 NOT CAPTURED]
// [GAP: LINE 14698 NOT CAPTURED]
// [GAP: LINE 14699 NOT CAPTURED]
// [GAP: LINE 14700 NOT CAPTURED]
// [GAP: LINE 14701 NOT CAPTURED]
// [GAP: LINE 14702 NOT CAPTURED]
// [GAP: LINE 14703 NOT CAPTURED]
// [GAP: LINE 14704 NOT CAPTURED]
// [GAP: LINE 14705 NOT CAPTURED]
// [GAP: LINE 14706 NOT CAPTURED]
// [GAP: LINE 14707 NOT CAPTURED]
// [GAP: LINE 14708 NOT CAPTURED]
// [GAP: LINE 14709 NOT CAPTURED]
// [GAP: LINE 14710 NOT CAPTURED]
// [GAP: LINE 14711 NOT CAPTURED]
// [GAP: LINE 14712 NOT CAPTURED]
// [GAP: LINE 14713 NOT CAPTURED]
// [GAP: LINE 14714 NOT CAPTURED]
// [GAP: LINE 14715 NOT CAPTURED]
// [GAP: LINE 14716 NOT CAPTURED]
// [GAP: LINE 14717 NOT CAPTURED]
// [GAP: LINE 14718 NOT CAPTURED]
// [GAP: LINE 14719 NOT CAPTURED]
// [GAP: LINE 14720 NOT CAPTURED]
// [GAP: LINE 14721 NOT CAPTURED]
// [GAP: LINE 14722 NOT CAPTURED]
// [GAP: LINE 14723 NOT CAPTURED]
// [GAP: LINE 14724 NOT CAPTURED]
// [GAP: LINE 14725 NOT CAPTURED]
// [GAP: LINE 14726 NOT CAPTURED]
// [GAP: LINE 14727 NOT CAPTURED]
// [GAP: LINE 14728 NOT CAPTURED]
// [GAP: LINE 14729 NOT CAPTURED]
// [GAP: LINE 14730 NOT CAPTURED]
// [GAP: LINE 14731 NOT CAPTURED]
// [GAP: LINE 14732 NOT CAPTURED]
// [GAP: LINE 14733 NOT CAPTURED]
// [GAP: LINE 14734 NOT CAPTURED]
// [GAP: LINE 14735 NOT CAPTURED]
// [GAP: LINE 14736 NOT CAPTURED]
// [GAP: LINE 14737 NOT CAPTURED]
// [GAP: LINE 14738 NOT CAPTURED]
// [GAP: LINE 14739 NOT CAPTURED]
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
// [GAP: LINE 14809 NOT CAPTURED]
// [GAP: LINE 14810 NOT CAPTURED]
// [GAP: LINE 14811 NOT CAPTURED]
// [GAP: LINE 14812 NOT CAPTURED]
// [GAP: LINE 14813 NOT CAPTURED]
// [GAP: LINE 14814 NOT CAPTURED]
// [GAP: LINE 14815 NOT CAPTURED]
// [GAP: LINE 14816 NOT CAPTURED]
// [GAP: LINE 14817 NOT CAPTURED]
// [GAP: LINE 14818 NOT CAPTURED]
// [GAP: LINE 14819 NOT CAPTURED]
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
                                  Text('💬', style: TextStyle(fontSize: 12)),
                                  SizedBox(width: 4),
                                  Text('Chat', style: TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.w800)),
                                ]),
                              ),
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
// [GAP: LINE 14955 NOT CAPTURED]
// [GAP: LINE 14956 NOT CAPTURED]
// [GAP: LINE 14957 NOT CAPTURED]
// [GAP: LINE 14958 NOT CAPTURED]
// [GAP: LINE 14959 NOT CAPTURED]
// [GAP: LINE 14960 NOT CAPTURED]
// [GAP: LINE 14961 NOT CAPTURED]
// [GAP: LINE 14962 NOT CAPTURED]
// [GAP: LINE 14963 NOT CAPTURED]
// [GAP: LINE 14964 NOT CAPTURED]
// [GAP: LINE 14965 NOT CAPTURED]
// [GAP: LINE 14966 NOT CAPTURED]
// [GAP: LINE 14967 NOT CAPTURED]
// [GAP: LINE 14968 NOT CAPTURED]
// [GAP: LINE 14969 NOT CAPTURED]
// [GAP: LINE 14970 NOT CAPTURED]
// [GAP: LINE 14971 NOT CAPTURED]
// [GAP: LINE 14972 NOT CAPTURED]
// [GAP: LINE 14973 NOT CAPTURED]
// [GAP: LINE 14974 NOT CAPTURED]
// [GAP: LINE 14975 NOT CAPTURED]
// [GAP: LINE 14976 NOT CAPTURED]
// [GAP: LINE 14977 NOT CAPTURED]
// [GAP: LINE 14978 NOT CAPTURED]
// [GAP: LINE 14979 NOT CAPTURED]
// [GAP: LINE 14980 NOT CAPTURED]
// [GAP: LINE 14981 NOT CAPTURED]
// [GAP: LINE 14982 NOT CAPTURED]
// [GAP: LINE 14983 NOT CAPTURED]
// [GAP: LINE 14984 NOT CAPTURED]
// [GAP: LINE 14985 NOT CAPTURED]
// [GAP: LINE 14986 NOT CAPTURED]
// [GAP: LINE 14987 NOT CAPTURED]
// [GAP: LINE 14988 NOT CAPTURED]
// [GAP: LINE 14989 NOT CAPTURED]
// [GAP: LINE 14990 NOT CAPTURED]
// [GAP: LINE 14991 NOT CAPTURED]
// [GAP: LINE 14992 NOT CAPTURED]
// [GAP: LINE 14993 NOT CAPTURED]
// [GAP: LINE 14994 NOT CAPTURED]
// [GAP: LINE 14995 NOT CAPTURED]
// [GAP: LINE 14996 NOT CAPTURED]
// [GAP: LINE 14997 NOT CAPTURED]
// [GAP: LINE 14998 NOT CAPTURED]
// [GAP: LINE 14999 NOT CAPTURED]
// [GAP: LINE 15000 NOT CAPTURED]
// [GAP: LINE 15001 NOT CAPTURED]
// [GAP: LINE 15002 NOT CAPTURED]
// [GAP: LINE 15003 NOT CAPTURED]
// [GAP: LINE 15004 NOT CAPTURED]
// [GAP: LINE 15005 NOT CAPTURED]
// [GAP: LINE 15006 NOT CAPTURED]
// [GAP: LINE 15007 NOT CAPTURED]
// [GAP: LINE 15008 NOT CAPTURED]
// [GAP: LINE 15009 NOT CAPTURED]
// [GAP: LINE 15010 NOT CAPTURED]
// [GAP: LINE 15011 NOT CAPTURED]
// [GAP: LINE 15012 NOT CAPTURED]
// [GAP: LINE 15013 NOT CAPTURED]
// [GAP: LINE 15014 NOT CAPTURED]
// [GAP: LINE 15015 NOT CAPTURED]
// [GAP: LINE 15016 NOT CAPTURED]
// [GAP: LINE 15017 NOT CAPTURED]
// [GAP: LINE 15018 NOT CAPTURED]
// [GAP: LINE 15019 NOT CAPTURED]
// [GAP: LINE 15020 NOT CAPTURED]
// [GAP: LINE 15021 NOT CAPTURED]
// [GAP: LINE 15022 NOT CAPTURED]
// [GAP: LINE 15023 NOT CAPTURED]
// [GAP: LINE 15024 NOT CAPTURED]
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
// [GAP: LINE 15055 NOT CAPTURED]
// [GAP: LINE 15056 NOT CAPTURED]
// [GAP: LINE 15057 NOT CAPTURED]
// [GAP: LINE 15058 NOT CAPTURED]
// [GAP: LINE 15059 NOT CAPTURED]
// [GAP: LINE 15060 NOT CAPTURED]
// [GAP: LINE 15061 NOT CAPTURED]
// [GAP: LINE 15062 NOT CAPTURED]
// [GAP: LINE 15063 NOT CAPTURED]
// [GAP: LINE 15064 NOT CAPTURED]
// [GAP: LINE 15065 NOT CAPTURED]
// [GAP: LINE 15066 NOT CAPTURED]
// [GAP: LINE 15067 NOT CAPTURED]
// [GAP: LINE 15068 NOT CAPTURED]
// [GAP: LINE 15069 NOT CAPTURED]
// [GAP: LINE 15070 NOT CAPTURED]
// [GAP: LINE 15071 NOT CAPTURED]
// [GAP: LINE 15072 NOT CAPTURED]
// [GAP: LINE 15073 NOT CAPTURED]
// [GAP: LINE 15074 NOT CAPTURED]
// [GAP: LINE 15075 NOT CAPTURED]
// [GAP: LINE 15076 NOT CAPTURED]
// [GAP: LINE 15077 NOT CAPTURED]
// [GAP: LINE 15078 NOT CAPTURED]
// [GAP: LINE 15079 NOT CAPTURED]
// [GAP: LINE 15080 NOT CAPTURED]
// [GAP: LINE 15081 NOT CAPTURED]
// [GAP: LINE 15082 NOT CAPTURED]
// [GAP: LINE 15083 NOT CAPTURED]
// [GAP: LINE 15084 NOT CAPTURED]
// [GAP: LINE 15085 NOT CAPTURED]
// [GAP: LINE 15086 NOT CAPTURED]
// [GAP: LINE 15087 NOT CAPTURED]
// [GAP: LINE 15088 NOT CAPTURED]
// [GAP: LINE 15089 NOT CAPTURED]
// [GAP: LINE 15090 NOT CAPTURED]
// [GAP: LINE 15091 NOT CAPTURED]
// [GAP: LINE 15092 NOT CAPTURED]
// [GAP: LINE 15093 NOT CAPTURED]
// [GAP: LINE 15094 NOT CAPTURED]
// [GAP: LINE 15095 NOT CAPTURED]
// [GAP: LINE 15096 NOT CAPTURED]
// [GAP: LINE 15097 NOT CAPTURED]
// [GAP: LINE 15098 NOT CAPTURED]
// [GAP: LINE 15099 NOT CAPTURED]
// [GAP: LINE 15100 NOT CAPTURED]
// [GAP: LINE 15101 NOT CAPTURED]
// [GAP: LINE 15102 NOT CAPTURED]
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
                  const SizedBox(height: 10),
                  _ProfileRow(
                    icon: Icons.delete_forever_outlined,
                    emoji: '🗑️',
                    label: 'Διαγραφή λογαριασμού',
                    value: '',
                    iconColor: Colors.red.shade300,
                    textColor: Colors.red.shade300,
                    borderColor: Colors.red.withValues(alpha: 0.1),
                    bgColor: Colors.red.withValues(alpha: 0.03),
                    onTap: () => _confirmDeleteAccount(context),
                  ),
                  const SizedBox(height: 40),
// [GAP: LINE 15142 NOT CAPTURED]
// [GAP: LINE 15143 NOT CAPTURED]
// [GAP: LINE 15144 NOT CAPTURED]
// [GAP: LINE 15145 NOT CAPTURED]
// [GAP: LINE 15146 NOT CAPTURED]
// [GAP: LINE 15147 NOT CAPTURED]
// [GAP: LINE 15148 NOT CAPTURED]
// [GAP: LINE 15149 NOT CAPTURED]
// [GAP: LINE 15150 NOT CAPTURED]
// [GAP: LINE 15151 NOT CAPTURED]
// [GAP: LINE 15152 NOT CAPTURED]
// [GAP: LINE 15153 NOT CAPTURED]
// [GAP: LINE 15154 NOT CAPTURED]
// [GAP: LINE 15155 NOT CAPTURED]
// [GAP: LINE 15156 NOT CAPTURED]
// [GAP: LINE 15157 NOT CAPTURED]
// [GAP: LINE 15158 NOT CAPTURED]
// [GAP: LINE 15159 NOT CAPTURED]
// [GAP: LINE 15160 NOT CAPTURED]
// [GAP: LINE 15161 NOT CAPTURED]
// [GAP: LINE 15162 NOT CAPTURED]
}

class _NotificationBell extends StatelessWidget {
  final String userId;
  const _NotificationBell({required this.userId});
  @override
  Widget build(BuildContext context) {
    if (userId.isEmpty) return const SizedBox(width: 34);
    return StreamBuilder<QuerySnapshot>(
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
// [GAP: LINE 15303 NOT CAPTURED]
// [GAP: LINE 15304 NOT CAPTURED]
// [GAP: LINE 15305 NOT CAPTURED]
// [GAP: LINE 15306 NOT CAPTURED]
// [GAP: LINE 15307 NOT CAPTURED]
// [GAP: LINE 15308 NOT CAPTURED]
// [GAP: LINE 15309 NOT CAPTURED]
// [GAP: LINE 15310 NOT CAPTURED]
// [GAP: LINE 15311 NOT CAPTURED]
// [GAP: LINE 15312 NOT CAPTURED]
// [GAP: LINE 15313 NOT CAPTURED]
// [GAP: LINE 15314 NOT CAPTURED]
// [GAP: LINE 15315 NOT CAPTURED]
// [GAP: LINE 15316 NOT CAPTURED]
// [GAP: LINE 15317 NOT CAPTURED]
// [GAP: LINE 15318 NOT CAPTURED]
// [GAP: LINE 15319 NOT CAPTURED]
// [GAP: LINE 15320 NOT CAPTURED]
// [GAP: LINE 15321 NOT CAPTURED]
// [GAP: LINE 15322 NOT CAPTURED]
// [GAP: LINE 15323 NOT CAPTURED]
// [GAP: LINE 15324 NOT CAPTURED]
// [GAP: LINE 15325 NOT CAPTURED]
// [GAP: LINE 15326 NOT CAPTURED]
// [GAP: LINE 15327 NOT CAPTURED]
// [GAP: LINE 15328 NOT CAPTURED]
// [GAP: LINE 15329 NOT CAPTURED]
// [GAP: LINE 15330 NOT CAPTURED]
// [GAP: LINE 15331 NOT CAPTURED]
// [GAP: LINE 15332 NOT CAPTURED]
// [GAP: LINE 15333 NOT CAPTURED]
// [GAP: LINE 15334 NOT CAPTURED]
// [GAP: LINE 15335 NOT CAPTURED]
// [GAP: LINE 15336 NOT CAPTURED]
// [GAP: LINE 15337 NOT CAPTURED]
// [GAP: LINE 15338 NOT CAPTURED]
// [GAP: LINE 15339 NOT CAPTURED]
// [GAP: LINE 15340 NOT CAPTURED]
// [GAP: LINE 15341 NOT CAPTURED]
// [GAP: LINE 15342 NOT CAPTURED]
// [GAP: LINE 15343 NOT CAPTURED]
// [GAP: LINE 15344 NOT CAPTURED]
// [GAP: LINE 15345 NOT CAPTURED]
// [GAP: LINE 15346 NOT CAPTURED]
// [GAP: LINE 15347 NOT CAPTURED]
// [GAP: LINE 15348 NOT CAPTURED]
// [GAP: LINE 15349 NOT CAPTURED]
// [GAP: LINE 15350 NOT CAPTURED]
// [GAP: LINE 15351 NOT CAPTURED]
// [GAP: LINE 15352 NOT CAPTURED]
// [GAP: LINE 15353 NOT CAPTURED]
// [GAP: LINE 15354 NOT CAPTURED]
// [GAP: LINE 15355 NOT CAPTURED]
// [GAP: LINE 15356 NOT CAPTURED]
// [GAP: LINE 15357 NOT CAPTURED]
// [GAP: LINE 15358 NOT CAPTURED]
// [GAP: LINE 15359 NOT CAPTURED]
// [GAP: LINE 15360 NOT CAPTURED]
// [GAP: LINE 15361 NOT CAPTURED]
// [GAP: LINE 15362 NOT CAPTURED]
// [GAP: LINE 15363 NOT CAPTURED]
// [GAP: LINE 15364 NOT CAPTURED]
// [GAP: LINE 15365 NOT CAPTURED]
// [GAP: LINE 15366 NOT CAPTURED]
// [GAP: LINE 15367 NOT CAPTURED]
// [GAP: LINE 15368 NOT CAPTURED]
// [GAP: LINE 15369 NOT CAPTURED]
// [GAP: LINE 15370 NOT CAPTURED]
// [GAP: LINE 15371 NOT CAPTURED]
// [GAP: LINE 15372 NOT CAPTURED]
// [GAP: LINE 15373 NOT CAPTURED]
// [GAP: LINE 15374 NOT CAPTURED]
// [GAP: LINE 15375 NOT CAPTURED]
// [GAP: LINE 15376 NOT CAPTURED]
// [GAP: LINE 15377 NOT CAPTURED]
// [GAP: LINE 15378 NOT CAPTURED]
// [GAP: LINE 15379 NOT CAPTURED]
// [GAP: LINE 15380 NOT CAPTURED]
// [GAP: LINE 15381 NOT CAPTURED]
// [GAP: LINE 15382 NOT CAPTURED]
// [GAP: LINE 15383 NOT CAPTURED]
// [GAP: LINE 15384 NOT CAPTURED]
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
    if (user == null) return;
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      setState(() => _uploadingPhoto = true);
      final ref = FirebaseStorage.instance.ref('profile_photos/${user.uid}/profile.jpg');
      await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
      final url = await ref.getDownloadURL();
      await FirebaseFirestore.instance.collection('users').doc(user.uid).update({'profilePhotoUrl': url});
      // Also update professionals collection if exists
      final proSnap = await FirebaseFirestore.instance
          .collection('professionals').where('userId', isEqualTo: user.uid).limit(1).get();
      for (final d in proSnap.docs) {
        await d.reference.update({'profilePhotoUrl': url});
      }
      if (!mounted) return;
      setState(() {
        _photoUrl = url;
        _photoBytes = bytes;
        _uploadingPhoto = false;
      });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('✅ Φωτογραφία ενημερώθηκε!'),
        backgroundColor: Color(0xFF00D4AA),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
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
    'category': 'Άλλα',
    'items': ['Μηχανικός Αυτοκινήτων', 'Λογιστής', 'Δικηγόρος', 'Αρχιτέκτονας']
                    child: Text(count > 9 ? '9+' : '$count',
                        style: const TextStyle(
                            color: Colors.white,
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
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  color: const Color(0xFF060E08),
                  border: Border.all(color: kGreen.withValues(alpha: 0.5)),
                  boxShadow: [BoxShadow(
                      color: kGreen.withValues(alpha: 0.2), blurRadius: 30)],
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(accepted ? '✅' : '🎉',
                      style: const TextStyle(fontSize: 52)),
                  const SizedBox(height: 12),
                  Text(
                    accepted
                        ? 'Η κράτηση επιβεβαιώθηκε!'
                        : 'Σε επέλεξαν!',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontFamily: 'Raleway',
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: Colors.white),
                  ),
                  const SizedBox(height: 8),
                  if (!accepted)
                    Text(
                      '$userName αποδέχτηκε την προσφορά σου',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 13),
                    ),
                  const SizedBox(height: 16),

                  // User info box
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
                        Text(userName,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w700)),
                      ]),
                      // Τηλέφωνο φαίνεται ΜΟΝΟ μετά την αποδοχή
                      if (accepted && userPhone.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        GestureDetector(
                          onTap: () =>
                              launchUrl(Uri.parse('tel:\$userPhone')),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                                vertical: 12, horizontal: 16),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              color: kGreen.withValues(alpha: 0.2),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.phone,
                                    color: kGreen, size: 22),
                                const SizedBox(width: 10),
                                Text(userPhone,
                                    style: const TextStyle(
                                        color: kGreen,
                                        fontSize: 20,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 2)),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ]),
                  ),

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
// [GAP: LINE 15833 NOT CAPTURED]
// [GAP: LINE 15834 NOT CAPTURED]
// [GAP: LINE 15835 NOT CAPTURED]
// [GAP: LINE 15836 NOT CAPTURED]
// [GAP: LINE 15837 NOT CAPTURED]
// [GAP: LINE 15838 NOT CAPTURED]
// [GAP: LINE 15839 NOT CAPTURED]
// [GAP: LINE 15840 NOT CAPTURED]
// [GAP: LINE 15841 NOT CAPTURED]
// [GAP: LINE 15842 NOT CAPTURED]
// [GAP: LINE 15843 NOT CAPTURED]
// [GAP: LINE 15844 NOT CAPTURED]
// [GAP: LINE 15845 NOT CAPTURED]
// [GAP: LINE 15846 NOT CAPTURED]
// [GAP: LINE 15847 NOT CAPTURED]
// [GAP: LINE 15848 NOT CAPTURED]
// [GAP: LINE 15849 NOT CAPTURED]
// [GAP: LINE 15850 NOT CAPTURED]
// [GAP: LINE 15851 NOT CAPTURED]
// [GAP: LINE 15852 NOT CAPTURED]
// [GAP: LINE 15853 NOT CAPTURED]
// [GAP: LINE 15854 NOT CAPTURED]
// [GAP: LINE 15855 NOT CAPTURED]
// [GAP: LINE 15856 NOT CAPTURED]
// [GAP: LINE 15857 NOT CAPTURED]
// [GAP: LINE 15858 NOT CAPTURED]
// [GAP: LINE 15859 NOT CAPTURED]
// [GAP: LINE 15860 NOT CAPTURED]
// [GAP: LINE 15861 NOT CAPTURED]
// [GAP: LINE 15862 NOT CAPTURED]
// [GAP: LINE 15863 NOT CAPTURED]
// [GAP: LINE 15864 NOT CAPTURED]
// [GAP: LINE 15865 NOT CAPTURED]
// [GAP: LINE 15866 NOT CAPTURED]
// [GAP: LINE 15867 NOT CAPTURED]
// [GAP: LINE 15868 NOT CAPTURED]
// [GAP: LINE 15869 NOT CAPTURED]
// [GAP: LINE 15870 NOT CAPTURED]
// [GAP: LINE 15871 NOT CAPTURED]
// [GAP: LINE 15872 NOT CAPTURED]
// [GAP: LINE 15873 NOT CAPTURED]
// [GAP: LINE 15874 NOT CAPTURED]
// [GAP: LINE 15875 NOT CAPTURED]
// [GAP: LINE 15876 NOT CAPTURED]
// [GAP: LINE 15877 NOT CAPTURED]
// [GAP: LINE 15878 NOT CAPTURED]
// [GAP: LINE 15879 NOT CAPTURED]
// [GAP: LINE 15880 NOT CAPTURED]
// [GAP: LINE 15881 NOT CAPTURED]
// [GAP: LINE 15882 NOT CAPTURED]
// [GAP: LINE 15883 NOT CAPTURED]
// [GAP: LINE 15884 NOT CAPTURED]
// [GAP: LINE 15885 NOT CAPTURED]
// [GAP: LINE 15886 NOT CAPTURED]
// [GAP: LINE 15887 NOT CAPTURED]
// [GAP: LINE 15888 NOT CAPTURED]
// [GAP: LINE 15889 NOT CAPTURED]
// [GAP: LINE 15890 NOT CAPTURED]
// [GAP: LINE 15891 NOT CAPTURED]
// [GAP: LINE 15892 NOT CAPTURED]
// [GAP: LINE 15893 NOT CAPTURED]
// [GAP: LINE 15894 NOT CAPTURED]
// [GAP: LINE 15895 NOT CAPTURED]
// [GAP: LINE 15896 NOT CAPTURED]
// [GAP: LINE 15897 NOT CAPTURED]
// [GAP: LINE 15898 NOT CAPTURED]
// [GAP: LINE 15899 NOT CAPTURED]
// [GAP: LINE 15900 NOT CAPTURED]
// [GAP: LINE 15901 NOT CAPTURED]
// [GAP: LINE 15902 NOT CAPTURED]
// [GAP: LINE 15903 NOT CAPTURED]
// [GAP: LINE 15904 NOT CAPTURED]
// [GAP: LINE 15905 NOT CAPTURED]
// [GAP: LINE 15906 NOT CAPTURED]
// [GAP: LINE 15907 NOT CAPTURED]
// [GAP: LINE 15908 NOT CAPTURED]
// [GAP: LINE 15909 NOT CAPTURED]
// [GAP: LINE 15910 NOT CAPTURED]
// [GAP: LINE 15911 NOT CAPTURED]
// [GAP: LINE 15912 NOT CAPTURED]
// [GAP: LINE 15913 NOT CAPTURED]
// [GAP: LINE 15914 NOT CAPTURED]
// [GAP: LINE 15915 NOT CAPTURED]
// [GAP: LINE 15916 NOT CAPTURED]
// [GAP: LINE 15917 NOT CAPTURED]
// [GAP: LINE 15918 NOT CAPTURED]
// [GAP: LINE 15919 NOT CAPTURED]
// [GAP: LINE 15920 NOT CAPTURED]
// [GAP: LINE 15921 NOT CAPTURED]
// [GAP: LINE 15922 NOT CAPTURED]
// [GAP: LINE 15923 NOT CAPTURED]
// [GAP: LINE 15924 NOT CAPTURED]
// [GAP: LINE 15925 NOT CAPTURED]
// [GAP: LINE 15926 NOT CAPTURED]
// [GAP: LINE 15927 NOT CAPTURED]
// [GAP: LINE 15928 NOT CAPTURED]
// [GAP: LINE 15929 NOT CAPTURED]
// [GAP: LINE 15930 NOT CAPTURED]
// [GAP: LINE 15931 NOT CAPTURED]
// [GAP: LINE 15932 NOT CAPTURED]
// [GAP: LINE 15933 NOT CAPTURED]
// [GAP: LINE 15934 NOT CAPTURED]
// [GAP: LINE 15935 NOT CAPTURED]
// [GAP: LINE 15936 NOT CAPTURED]
// [GAP: LINE 15937 NOT CAPTURED]
// [GAP: LINE 15938 NOT CAPTURED]
// [GAP: LINE 15939 NOT CAPTURED]
// [GAP: LINE 15940 NOT CAPTURED]
// [GAP: LINE 15941 NOT CAPTURED]
// [GAP: LINE 15942 NOT CAPTURED]
// [GAP: LINE 15943 NOT CAPTURED]
// [GAP: LINE 15944 NOT CAPTURED]
// [GAP: LINE 15945 NOT CAPTURED]
// [GAP: LINE 15946 NOT CAPTURED]
// [GAP: LINE 15947 NOT CAPTURED]
// [GAP: LINE 15948 NOT CAPTURED]
// [GAP: LINE 15949 NOT CAPTURED]
// [GAP: LINE 15950 NOT CAPTURED]
// [GAP: LINE 15951 NOT CAPTURED]
// [GAP: LINE 15952 NOT CAPTURED]
// [GAP: LINE 15953 NOT CAPTURED]
// [GAP: LINE 15954 NOT CAPTURED]
// [GAP: LINE 15955 NOT CAPTURED]
// [GAP: LINE 15956 NOT CAPTURED]
// [GAP: LINE 15957 NOT CAPTURED]
// [GAP: LINE 15958 NOT CAPTURED]
// [GAP: LINE 15959 NOT CAPTURED]
// [GAP: LINE 15960 NOT CAPTURED]
// [GAP: LINE 15961 NOT CAPTURED]
// [GAP: LINE 15962 NOT CAPTURED]
// [GAP: LINE 15963 NOT CAPTURED]
// [GAP: LINE 15964 NOT CAPTURED]
// [GAP: LINE 15965 NOT CAPTURED]
// [GAP: LINE 15966 NOT CAPTURED]
// [GAP: LINE 15967 NOT CAPTURED]
// [GAP: LINE 15968 NOT CAPTURED]
// [GAP: LINE 15969 NOT CAPTURED]
// [GAP: LINE 15970 NOT CAPTURED]
// [GAP: LINE 15971 NOT CAPTURED]
// [GAP: LINE 15972 NOT CAPTURED]
// [GAP: LINE 15973 NOT CAPTURED]
// [GAP: LINE 15974 NOT CAPTURED]
// [GAP: LINE 15975 NOT CAPTURED]
// [GAP: LINE 15976 NOT CAPTURED]
// [GAP: LINE 15977 NOT CAPTURED]
// [GAP: LINE 15978 NOT CAPTURED]
// [GAP: LINE 15979 NOT CAPTURED]
// [GAP: LINE 15980 NOT CAPTURED]
// [GAP: LINE 15981 NOT CAPTURED]
// [GAP: LINE 15982 NOT CAPTURED]
// [GAP: LINE 15983 NOT CAPTURED]
// [GAP: LINE 15984 NOT CAPTURED]
// [GAP: LINE 15985 NOT CAPTURED]
// [GAP: LINE 15986 NOT CAPTURED]
// [GAP: LINE 15987 NOT CAPTURED]
// [GAP: LINE 15988 NOT CAPTURED]
// [GAP: LINE 15989 NOT CAPTURED]
// [GAP: LINE 15990 NOT CAPTURED]
// [GAP: LINE 15991 NOT CAPTURED]
// [GAP: LINE 15992 NOT CAPTURED]
// [GAP: LINE 15993 NOT CAPTURED]
// [GAP: LINE 15994 NOT CAPTURED]
// [GAP: LINE 15995 NOT CAPTURED]
// [GAP: LINE 15996 NOT CAPTURED]
// [GAP: LINE 15997 NOT CAPTURED]
// [GAP: LINE 15998 NOT CAPTURED]
// [GAP: LINE 15999 NOT CAPTURED]
// [GAP: LINE 16000 NOT CAPTURED]
// [GAP: LINE 16001 NOT CAPTURED]
// [GAP: LINE 16002 NOT CAPTURED]
// [GAP: LINE 16003 NOT CAPTURED]
// [GAP: LINE 16004 NOT CAPTURED]
// [GAP: LINE 16005 NOT CAPTURED]
// [GAP: LINE 16006 NOT CAPTURED]
// [GAP: LINE 16007 NOT CAPTURED]
// [GAP: LINE 16008 NOT CAPTURED]
// [GAP: LINE 16009 NOT CAPTURED]
// [GAP: LINE 16010 NOT CAPTURED]
// [GAP: LINE 16011 NOT CAPTURED]
// [GAP: LINE 16012 NOT CAPTURED]
// [GAP: LINE 16013 NOT CAPTURED]
// [GAP: LINE 16014 NOT CAPTURED]
// [GAP: LINE 16015 NOT CAPTURED]
// [GAP: LINE 16016 NOT CAPTURED]
// [GAP: LINE 16017 NOT CAPTURED]
// [GAP: LINE 16018 NOT CAPTURED]
// [GAP: LINE 16019 NOT CAPTURED]
// [GAP: LINE 16020 NOT CAPTURED]
// [GAP: LINE 16021 NOT CAPTURED]
// [GAP: LINE 16022 NOT CAPTURED]
// [GAP: LINE 16023 NOT CAPTURED]
// [GAP: LINE 16024 NOT CAPTURED]
// [GAP: LINE 16025 NOT CAPTURED]
// [GAP: LINE 16026 NOT CAPTURED]
// [GAP: LINE 16027 NOT CAPTURED]
// [GAP: LINE 16028 NOT CAPTURED]
// [GAP: LINE 16029 NOT CAPTURED]
// [GAP: LINE 16030 NOT CAPTURED]
// [GAP: LINE 16031 NOT CAPTURED]
// [GAP: LINE 16032 NOT CAPTURED]
// [GAP: LINE 16033 NOT CAPTURED]
// [GAP: LINE 16034 NOT CAPTURED]
// [GAP: LINE 16035 NOT CAPTURED]
// [GAP: LINE 16036 NOT CAPTURED]
// [GAP: LINE 16037 NOT CAPTURED]
// [GAP: LINE 16038 NOT CAPTURED]
// [GAP: LINE 16039 NOT CAPTURED]
// [GAP: LINE 16040 NOT CAPTURED]
// [GAP: LINE 16041 NOT CAPTURED]
// [GAP: LINE 16042 NOT CAPTURED]
// [GAP: LINE 16043 NOT CAPTURED]
// [GAP: LINE 16044 NOT CAPTURED]
// [GAP: LINE 16045 NOT CAPTURED]
// [GAP: LINE 16046 NOT CAPTURED]
// [GAP: LINE 16047 NOT CAPTURED]
// [GAP: LINE 16048 NOT CAPTURED]
// [GAP: LINE 16049 NOT CAPTURED]
// [GAP: LINE 16050 NOT CAPTURED]
// [GAP: LINE 16051 NOT CAPTURED]
// [GAP: LINE 16052 NOT CAPTURED]
// [GAP: LINE 16053 NOT CAPTURED]
// [GAP: LINE 16054 NOT CAPTURED]
// [GAP: LINE 16055 NOT CAPTURED]
// [GAP: LINE 16056 NOT CAPTURED]
// [GAP: LINE 16057 NOT CAPTURED]
// [GAP: LINE 16058 NOT CAPTURED]
// [GAP: LINE 16059 NOT CAPTURED]
// [GAP: LINE 16060 NOT CAPTURED]
// [GAP: LINE 16061 NOT CAPTURED]
// [GAP: LINE 16062 NOT CAPTURED]
// [GAP: LINE 16063 NOT CAPTURED]
// [GAP: LINE 16064 NOT CAPTURED]
// [GAP: LINE 16065 NOT CAPTURED]
// [GAP: LINE 16066 NOT CAPTURED]
// [GAP: LINE 16067 NOT CAPTURED]
// [GAP: LINE 16068 NOT CAPTURED]
// [GAP: LINE 16069 NOT CAPTURED]
// [GAP: LINE 16070 NOT CAPTURED]
// [GAP: LINE 16071 NOT CAPTURED]
// [GAP: LINE 16072 NOT CAPTURED]
// [GAP: LINE 16073 NOT CAPTURED]
// [GAP: LINE 16074 NOT CAPTURED]
// [GAP: LINE 16075 NOT CAPTURED]
// [GAP: LINE 16076 NOT CAPTURED]
// [GAP: LINE 16077 NOT CAPTURED]
// [GAP: LINE 16078 NOT CAPTURED]
// [GAP: LINE 16079 NOT CAPTURED]
// [GAP: LINE 16080 NOT CAPTURED]
// [GAP: LINE 16081 NOT CAPTURED]
// [GAP: LINE 16082 NOT CAPTURED]
// [GAP: LINE 16083 NOT CAPTURED]
// [GAP: LINE 16084 NOT CAPTURED]
// [GAP: LINE 16085 NOT CAPTURED]
// [GAP: LINE 16086 NOT CAPTURED]
// [GAP: LINE 16087 NOT CAPTURED]
// [GAP: LINE 16088 NOT CAPTURED]
// [GAP: LINE 16089 NOT CAPTURED]
// [GAP: LINE 16090 NOT CAPTURED]
// [GAP: LINE 16091 NOT CAPTURED]
// [GAP: LINE 16092 NOT CAPTURED]
// [GAP: LINE 16093 NOT CAPTURED]
// [GAP: LINE 16094 NOT CAPTURED]
// [GAP: LINE 16095 NOT CAPTURED]
// [GAP: LINE 16096 NOT CAPTURED]
// [GAP: LINE 16097 NOT CAPTURED]
// [GAP: LINE 16098 NOT CAPTURED]
// [GAP: LINE 16099 NOT CAPTURED]
// [GAP: LINE 16100 NOT CAPTURED]
// [GAP: LINE 16101 NOT CAPTURED]
// [GAP: LINE 16102 NOT CAPTURED]
// [GAP: LINE 16103 NOT CAPTURED]
// [GAP: LINE 16104 NOT CAPTURED]
// [GAP: LINE 16105 NOT CAPTURED]
// [GAP: LINE 16106 NOT CAPTURED]
// [GAP: LINE 16107 NOT CAPTURED]
// [GAP: LINE 16108 NOT CAPTURED]
// [GAP: LINE 16109 NOT CAPTURED]
// [GAP: LINE 16110 NOT CAPTURED]
// [GAP: LINE 16111 NOT CAPTURED]
// [GAP: LINE 16112 NOT CAPTURED]
// [GAP: LINE 16113 NOT CAPTURED]
// [GAP: LINE 16114 NOT CAPTURED]

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
// [GAP: LINE 16145 NOT CAPTURED]
// [GAP: LINE 16146 NOT CAPTURED]
// [GAP: LINE 16147 NOT CAPTURED]
// [GAP: LINE 16148 NOT CAPTURED]
// [GAP: LINE 16149 NOT CAPTURED]
// [GAP: LINE 16150 NOT CAPTURED]
// [GAP: LINE 16151 NOT CAPTURED]
// [GAP: LINE 16152 NOT CAPTURED]
// [GAP: LINE 16153 NOT CAPTURED]
// [GAP: LINE 16154 NOT CAPTURED]
// [GAP: LINE 16155 NOT CAPTURED]
// [GAP: LINE 16156 NOT CAPTURED]
// [GAP: LINE 16157 NOT CAPTURED]
// [GAP: LINE 16158 NOT CAPTURED]
// [GAP: LINE 16159 NOT CAPTURED]
// [GAP: LINE 16160 NOT CAPTURED]
// [GAP: LINE 16161 NOT CAPTURED]
// [GAP: LINE 16162 NOT CAPTURED]
// [GAP: LINE 16163 NOT CAPTURED]
// [GAP: LINE 16164 NOT CAPTURED]
// [GAP: LINE 16165 NOT CAPTURED]
// [GAP: LINE 16166 NOT CAPTURED]
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
// ═══════════════════════════════════════
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

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
      _isPremium = doc.data()?['isPremium'] == true || doc.data()?['isOwner'] == true;
      _nameCtrl.text = _name ?? '';
      _cityCtrl.text = _city ?? '';
      _biometricOn = prefs.getBool('biometric_enabled') ?? true;
      _loading = false;
    });
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
// [GAP: LINE 16280 NOT CAPTURED]
// [GAP: LINE 16281 NOT CAPTURED]
// [GAP: LINE 16282 NOT CAPTURED]
// [GAP: LINE 16283 NOT CAPTURED]
// [GAP: LINE 16284 NOT CAPTURED]
// [GAP: LINE 16285 NOT CAPTURED]
// [GAP: LINE 16286 NOT CAPTURED]
// [GAP: LINE 16287 NOT CAPTURED]
// [GAP: LINE 16288 NOT CAPTURED]
// [GAP: LINE 16289 NOT CAPTURED]
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
  bool _matchesEvent(Map<String, dynamic> d) {
    final categoryPros = List<String>.from(d['categoryPros'] ?? []);
    // Old docs without categoryPros → only show to event-related pros
    if (categoryPros.isEmpty) {
      return _proSpecialties.any((sp) => sp.isNotEmpty && _isEventSpecBtn(sp.toLowerCase()));
    }
    for (final sp in _proSpecialties) {
      final spLow = sp.toLowerCase();
      // Direct match
      for (final cp in categoryPros) {
        final cpLow = cp.toLowerCase();
        if (spLow.contains(cpLow) || cpLow.contains(spLow)) return true;
      }
      // Broader event specialty match
      if (_isEventSpecBtn(spLow)) return true;
    }
    return false;
  }

  static bool _isEventSpecBtn(String sp) {
    return sp.contains('εκδηλώσ') || sp.contains('γάμ') || sp.contains('βάφτισ') ||
           sp.contains('πάρτ') || sp.contains('catering') || sp.contains('dj') ||
           sp.contains('ανθοδέτ') || sp.contains('αίθουσ') || sp.contains('στολισ') ||
           sp.contains('φωτογράφ');
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
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
// [GAP: LINE 16554 NOT CAPTURED]
// [GAP: LINE 16555 NOT CAPTURED]
// [GAP: LINE 16556 NOT CAPTURED]
// [GAP: LINE 16557 NOT CAPTURED]
// [GAP: LINE 16558 NOT CAPTURED]
// [GAP: LINE 16559 NOT CAPTURED]
// [GAP: LINE 16560 NOT CAPTURED]
// [GAP: LINE 16561 NOT CAPTURED]
// [GAP: LINE 16562 NOT CAPTURED]
// [GAP: LINE 16563 NOT CAPTURED]
// [GAP: LINE 16564 NOT CAPTURED]
// [GAP: LINE 16565 NOT CAPTURED]
// [GAP: LINE 16566 NOT CAPTURED]
// [GAP: LINE 16567 NOT CAPTURED]
// [GAP: LINE 16568 NOT CAPTURED]
// [GAP: LINE 16569 NOT CAPTURED]
// [GAP: LINE 16570 NOT CAPTURED]
// [GAP: LINE 16571 NOT CAPTURED]
// [GAP: LINE 16572 NOT CAPTURED]
// [GAP: LINE 16573 NOT CAPTURED]
// [GAP: LINE 16574 NOT CAPTURED]
// [GAP: LINE 16575 NOT CAPTURED]
// [GAP: LINE 16576 NOT CAPTURED]
// [GAP: LINE 16577 NOT CAPTURED]
// [GAP: LINE 16578 NOT CAPTURED]
// [GAP: LINE 16579 NOT CAPTURED]
// [GAP: LINE 16580 NOT CAPTURED]
// [GAP: LINE 16581 NOT CAPTURED]
// [GAP: LINE 16582 NOT CAPTURED]
// [GAP: LINE 16583 NOT CAPTURED]
// [GAP: LINE 16584 NOT CAPTURED]
// [GAP: LINE 16585 NOT CAPTURED]
// [GAP: LINE 16586 NOT CAPTURED]
// [GAP: LINE 16587 NOT CAPTURED]
// [GAP: LINE 16588 NOT CAPTURED]
// [GAP: LINE 16589 NOT CAPTURED]
// [GAP: LINE 16590 NOT CAPTURED]
// [GAP: LINE 16591 NOT CAPTURED]
// [GAP: LINE 16592 NOT CAPTURED]
// [GAP: LINE 16593 NOT CAPTURED]
// [GAP: LINE 16594 NOT CAPTURED]
// [GAP: LINE 16595 NOT CAPTURED]
// [GAP: LINE 16596 NOT CAPTURED]
// [GAP: LINE 16597 NOT CAPTURED]
// [GAP: LINE 16598 NOT CAPTURED]
// [GAP: LINE 16599 NOT CAPTURED]
// [GAP: LINE 16600 NOT CAPTURED]
// [GAP: LINE 16601 NOT CAPTURED]
// [GAP: LINE 16602 NOT CAPTURED]
// [GAP: LINE 16603 NOT CAPTURED]
// [GAP: LINE 16604 NOT CAPTURED]
// [GAP: LINE 16605 NOT CAPTURED]
// [GAP: LINE 16606 NOT CAPTURED]
// [GAP: LINE 16607 NOT CAPTURED]
// [GAP: LINE 16608 NOT CAPTURED]
// [GAP: LINE 16609 NOT CAPTURED]
// [GAP: LINE 16610 NOT CAPTURED]
// [GAP: LINE 16611 NOT CAPTURED]
// [GAP: LINE 16612 NOT CAPTURED]
// [GAP: LINE 16613 NOT CAPTURED]
// [GAP: LINE 16614 NOT CAPTURED]
// [GAP: LINE 16615 NOT CAPTURED]
// [GAP: LINE 16616 NOT CAPTURED]
// [GAP: LINE 16617 NOT CAPTURED]
// [GAP: LINE 16618 NOT CAPTURED]
// [GAP: LINE 16619 NOT CAPTURED]
// [GAP: LINE 16620 NOT CAPTURED]
// [GAP: LINE 16621 NOT CAPTURED]
// [GAP: LINE 16622 NOT CAPTURED]
// [GAP: LINE 16623 NOT CAPTURED]
// [GAP: LINE 16624 NOT CAPTURED]
// [GAP: LINE 16625 NOT CAPTURED]
// [GAP: LINE 16626 NOT CAPTURED]
// [GAP: LINE 16627 NOT CAPTURED]
// [GAP: LINE 16628 NOT CAPTURED]
// [GAP: LINE 16629 NOT CAPTURED]
// [GAP: LINE 16630 NOT CAPTURED]
// [GAP: LINE 16631 NOT CAPTURED]
// [GAP: LINE 16632 NOT CAPTURED]
// [GAP: LINE 16633 NOT CAPTURED]
// [GAP: LINE 16634 NOT CAPTURED]
// [GAP: LINE 16635 NOT CAPTURED]
// [GAP: LINE 16636 NOT CAPTURED]
// [GAP: LINE 16637 NOT CAPTURED]
// [GAP: LINE 16638 NOT CAPTURED]
// [GAP: LINE 16639 NOT CAPTURED]
// [GAP: LINE 16640 NOT CAPTURED]
// [GAP: LINE 16641 NOT CAPTURED]
// [GAP: LINE 16642 NOT CAPTURED]
// [GAP: LINE 16643 NOT CAPTURED]
// [GAP: LINE 16644 NOT CAPTURED]
// [GAP: LINE 16645 NOT CAPTURED]
// [GAP: LINE 16646 NOT CAPTURED]
// [GAP: LINE 16647 NOT CAPTURED]
// [GAP: LINE 16648 NOT CAPTURED]
// [GAP: LINE 16649 NOT CAPTURED]
// [GAP: LINE 16650 NOT CAPTURED]
// [GAP: LINE 16651 NOT CAPTURED]
// [GAP: LINE 16652 NOT CAPTURED]
// [GAP: LINE 16653 NOT CAPTURED]
// [GAP: LINE 16654 NOT CAPTURED]
// [GAP: LINE 16655 NOT CAPTURED]
// [GAP: LINE 16656 NOT CAPTURED]
// [GAP: LINE 16657 NOT CAPTURED]
// [GAP: LINE 16658 NOT CAPTURED]
// [GAP: LINE 16659 NOT CAPTURED]
// [GAP: LINE 16660 NOT CAPTURED]
// [GAP: LINE 16661 NOT CAPTURED]
// [GAP: LINE 16662 NOT CAPTURED]
// [GAP: LINE 16663 NOT CAPTURED]
// [GAP: LINE 16664 NOT CAPTURED]
// [GAP: LINE 16665 NOT CAPTURED]
// [GAP: LINE 16666 NOT CAPTURED]
// [GAP: LINE 16667 NOT CAPTURED]
// [GAP: LINE 16668 NOT CAPTURED]
// [GAP: LINE 16669 NOT CAPTURED]
// [GAP: LINE 16670 NOT CAPTURED]
// [GAP: LINE 16671 NOT CAPTURED]
// [GAP: LINE 16672 NOT CAPTURED]
// [GAP: LINE 16673 NOT CAPTURED]
// [GAP: LINE 16674 NOT CAPTURED]
// [GAP: LINE 16675 NOT CAPTURED]
// [GAP: LINE 16676 NOT CAPTURED]
// [GAP: LINE 16677 NOT CAPTURED]
// [GAP: LINE 16678 NOT CAPTURED]
// [GAP: LINE 16679 NOT CAPTURED]
// [GAP: LINE 16680 NOT CAPTURED]
// [GAP: LINE 16681 NOT CAPTURED]
// [GAP: LINE 16682 NOT CAPTURED]
// [GAP: LINE 16683 NOT CAPTURED]
// [GAP: LINE 16684 NOT CAPTURED]
// [GAP: LINE 16685 NOT CAPTURED]
// [GAP: LINE 16686 NOT CAPTURED]
// [GAP: LINE 16687 NOT CAPTURED]
// [GAP: LINE 16688 NOT CAPTURED]
// [GAP: LINE 16689 NOT CAPTURED]
// [GAP: LINE 16690 NOT CAPTURED]
// [GAP: LINE 16691 NOT CAPTURED]
// [GAP: LINE 16692 NOT CAPTURED]
// [GAP: LINE 16693 NOT CAPTURED]
// [GAP: LINE 16694 NOT CAPTURED]
// [GAP: LINE 16695 NOT CAPTURED]
// [GAP: LINE 16696 NOT CAPTURED]
// [GAP: LINE 16697 NOT CAPTURED]
// [GAP: LINE 16698 NOT CAPTURED]
// [GAP: LINE 16699 NOT CAPTURED]
// [GAP: LINE 16700 NOT CAPTURED]
// [GAP: LINE 16701 NOT CAPTURED]
// [GAP: LINE 16702 NOT CAPTURED]
// [GAP: LINE 16703 NOT CAPTURED]
// [GAP: LINE 16704 NOT CAPTURED]
// [GAP: LINE 16705 NOT CAPTURED]
// [GAP: LINE 16706 NOT CAPTURED]
// [GAP: LINE 16707 NOT CAPTURED]
// [GAP: LINE 16708 NOT CAPTURED]
// [GAP: LINE 16709 NOT CAPTURED]
// [GAP: LINE 16710 NOT CAPTURED]
// [GAP: LINE 16711 NOT CAPTURED]
// [GAP: LINE 16712 NOT CAPTURED]
// [GAP: LINE 16713 NOT CAPTURED]
// [GAP: LINE 16714 NOT CAPTURED]
// [GAP: LINE 16715 NOT CAPTURED]
// [GAP: LINE 16716 NOT CAPTURED]
// [GAP: LINE 16717 NOT CAPTURED]
// [GAP: LINE 16718 NOT CAPTURED]
// [GAP: LINE 16719 NOT CAPTURED]
// [GAP: LINE 16720 NOT CAPTURED]
// [GAP: LINE 16721 NOT CAPTURED]
// [GAP: LINE 16722 NOT CAPTURED]
// [GAP: LINE 16723 NOT CAPTURED]
// [GAP: LINE 16724 NOT CAPTURED]
// [GAP: LINE 16725 NOT CAPTURED]
// [GAP: LINE 16726 NOT CAPTURED]
// [GAP: LINE 16727 NOT CAPTURED]
// [GAP: LINE 16728 NOT CAPTURED]
// [GAP: LINE 16729 NOT CAPTURED]
// [GAP: LINE 16730 NOT CAPTURED]
// [GAP: LINE 16731 NOT CAPTURED]
// [GAP: LINE 16732 NOT CAPTURED]
// [GAP: LINE 16733 NOT CAPTURED]
// [GAP: LINE 16734 NOT CAPTURED]
// [GAP: LINE 16735 NOT CAPTURED]
// [GAP: LINE 16736 NOT CAPTURED]
// [GAP: LINE 16737 NOT CAPTURED]
// [GAP: LINE 16738 NOT CAPTURED]
// [GAP: LINE 16739 NOT CAPTURED]
// [GAP: LINE 16740 NOT CAPTURED]
// [GAP: LINE 16741 NOT CAPTURED]
// [GAP: LINE 16742 NOT CAPTURED]
// [GAP: LINE 16743 NOT CAPTURED]
// [GAP: LINE 16744 NOT CAPTURED]
// [GAP: LINE 16745 NOT CAPTURED]
// [GAP: LINE 16746 NOT CAPTURED]
// [GAP: LINE 16747 NOT CAPTURED]
// [GAP: LINE 16748 NOT CAPTURED]
// [GAP: LINE 16749 NOT CAPTURED]
// [GAP: LINE 16750 NOT CAPTURED]
// [GAP: LINE 16751 NOT CAPTURED]
// [GAP: LINE 16752 NOT CAPTURED]
// [GAP: LINE 16753 NOT CAPTURED]
// [GAP: LINE 16754 NOT CAPTURED]
// [GAP: LINE 16755 NOT CAPTURED]
// [GAP: LINE 16756 NOT CAPTURED]
// [GAP: LINE 16757 NOT CAPTURED]
// [GAP: LINE 16758 NOT CAPTURED]
// [GAP: LINE 16759 NOT CAPTURED]
// [GAP: LINE 16760 NOT CAPTURED]
// [GAP: LINE 16761 NOT CAPTURED]
// [GAP: LINE 16762 NOT CAPTURED]
// [GAP: LINE 16763 NOT CAPTURED]
// [GAP: LINE 16764 NOT CAPTURED]
// [GAP: LINE 16765 NOT CAPTURED]
// [GAP: LINE 16766 NOT CAPTURED]
// [GAP: LINE 16767 NOT CAPTURED]
// [GAP: LINE 16768 NOT CAPTURED]
// [GAP: LINE 16769 NOT CAPTURED]
// [GAP: LINE 16770 NOT CAPTURED]
// [GAP: LINE 16771 NOT CAPTURED]
// [GAP: LINE 16772 NOT CAPTURED]
// [GAP: LINE 16773 NOT CAPTURED]
// [GAP: LINE 16774 NOT CAPTURED]
// [GAP: LINE 16775 NOT CAPTURED]
// [GAP: LINE 16776 NOT CAPTURED]
// [GAP: LINE 16777 NOT CAPTURED]
// [GAP: LINE 16778 NOT CAPTURED]
// [GAP: LINE 16779 NOT CAPTURED]
// [GAP: LINE 16780 NOT CAPTURED]
// [GAP: LINE 16781 NOT CAPTURED]
// [GAP: LINE 16782 NOT CAPTURED]
// [GAP: LINE 16783 NOT CAPTURED]
// [GAP: LINE 16784 NOT CAPTURED]
// [GAP: LINE 16785 NOT CAPTURED]
// [GAP: LINE 16786 NOT CAPTURED]
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
                            Container(width: 44, height: 44,
                              decoration: BoxDecoration(shape: BoxShape.circle, color: kGold.withValues(alpha: 0.15), border: Border.all(color: kGold.withValues(alpha: 0.4))),
                              child: const Center(child: Text('⭐', style: TextStyle(fontSize: 22)))),
                            const SizedBox(width: 14),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              const Text('Premium Ενεργό', style: TextStyle(color: kGold, fontFamily: 'Raleway', fontWeight: FontWeight.w800, fontSize: 15)),
                              Text('Απεριόριστα αιτήματα & προτεραιότητα', style: TextStyle(color: _g(0.5), fontSize: 11)),
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
                              label: _stripeLoading ? 'Φόρτωση...' : '💳  Συνδρομή — 1,99€/μήνα',
                              gradient: const LinearGradient(colors: [kGoldLight, kGold, kGoldDark]),
                              textColor: Colors.black,
                              onTap: () { if (!_stripeLoading) _startStripeCheckout(); },
                            ),
                          ]),
                  ),

                  const SizedBox(height: 20),
                  _sectionHeader('ΑΣΦΑΛΕΙΑ'),
                  _buildToggleRow(
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
// [GAP: LINE 16866 NOT CAPTURED]
// [GAP: LINE 16867 NOT CAPTURED]
// [GAP: LINE 16868 NOT CAPTURED]
// [GAP: LINE 16869 NOT CAPTURED]
// [GAP: LINE 16870 NOT CAPTURED]
// [GAP: LINE 16871 NOT CAPTURED]
// [GAP: LINE 16872 NOT CAPTURED]
// [GAP: LINE 16873 NOT CAPTURED]
// [GAP: LINE 16874 NOT CAPTURED]
// [GAP: LINE 16875 NOT CAPTURED]
// [GAP: LINE 16876 NOT CAPTURED]
// [GAP: LINE 16877 NOT CAPTURED]
// [GAP: LINE 16878 NOT CAPTURED]
// [GAP: LINE 16879 NOT CAPTURED]
// [GAP: LINE 16880 NOT CAPTURED]
// [GAP: LINE 16881 NOT CAPTURED]
// [GAP: LINE 16882 NOT CAPTURED]
// [GAP: LINE 16883 NOT CAPTURED]
// [GAP: LINE 16884 NOT CAPTURED]
// [GAP: LINE 16885 NOT CAPTURED]
// [GAP: LINE 16886 NOT CAPTURED]
// [GAP: LINE 16887 NOT CAPTURED]
// [GAP: LINE 16888 NOT CAPTURED]
// [GAP: LINE 16889 NOT CAPTURED]
// [GAP: LINE 16890 NOT CAPTURED]
// [GAP: LINE 16891 NOT CAPTURED]
// [GAP: LINE 16892 NOT CAPTURED]
// [GAP: LINE 16893 NOT CAPTURED]
// [GAP: LINE 16894 NOT CAPTURED]
// [GAP: LINE 16895 NOT CAPTURED]
// [GAP: LINE 16896 NOT CAPTURED]
// [GAP: LINE 16897 NOT CAPTURED]
// [GAP: LINE 16898 NOT CAPTURED]
// [GAP: LINE 16899 NOT CAPTURED]
// [GAP: LINE 16900 NOT CAPTURED]
// [GAP: LINE 16901 NOT CAPTURED]
// [GAP: LINE 16902 NOT CAPTURED]
// [GAP: LINE 16903 NOT CAPTURED]
// [GAP: LINE 16904 NOT CAPTURED]
// [GAP: LINE 16905 NOT CAPTURED]
// [GAP: LINE 16906 NOT CAPTURED]
// [GAP: LINE 16907 NOT CAPTURED]
// [GAP: LINE 16908 NOT CAPTURED]
// [GAP: LINE 16909 NOT CAPTURED]
// [GAP: LINE 16910 NOT CAPTURED]
// [GAP: LINE 16911 NOT CAPTURED]
// [GAP: LINE 16912 NOT CAPTURED]
// [GAP: LINE 16913 NOT CAPTURED]
// [GAP: LINE 16914 NOT CAPTURED]
// [GAP: LINE 16915 NOT CAPTURED]
// [GAP: LINE 16916 NOT CAPTURED]
// [GAP: LINE 16917 NOT CAPTURED]
// [GAP: LINE 16918 NOT CAPTURED]
// [GAP: LINE 16919 NOT CAPTURED]
// [GAP: LINE 16920 NOT CAPTURED]
// [GAP: LINE 16921 NOT CAPTURED]
// [GAP: LINE 16922 NOT CAPTURED]
// [GAP: LINE 16923 NOT CAPTURED]
// [GAP: LINE 16924 NOT CAPTURED]
// [GAP: LINE 16925 NOT CAPTURED]
// [GAP: LINE 16926 NOT CAPTURED]
// [GAP: LINE 16927 NOT CAPTURED]
// [GAP: LINE 16928 NOT CAPTURED]
// [GAP: LINE 16929 NOT CAPTURED]
// [GAP: LINE 16930 NOT CAPTURED]
// [GAP: LINE 16931 NOT CAPTURED]
// [GAP: LINE 16932 NOT CAPTURED]
// [GAP: LINE 16933 NOT CAPTURED]
// [GAP: LINE 16934 NOT CAPTURED]
// [GAP: LINE 16935 NOT CAPTURED]
// [GAP: LINE 16936 NOT CAPTURED]
// [GAP: LINE 16937 NOT CAPTURED]
// [GAP: LINE 16938 NOT CAPTURED]
// [GAP: LINE 16939 NOT CAPTURED]
// [GAP: LINE 16940 NOT CAPTURED]
// [GAP: LINE 16941 NOT CAPTURED]
// [GAP: LINE 16942 NOT CAPTURED]
// [GAP: LINE 16943 NOT CAPTURED]
// [GAP: LINE 16944 NOT CAPTURED]
// [GAP: LINE 16945 NOT CAPTURED]
// [GAP: LINE 16946 NOT CAPTURED]
// [GAP: LINE 16947 NOT CAPTURED]
// [GAP: LINE 16948 NOT CAPTURED]
// [GAP: LINE 16949 NOT CAPTURED]
// [GAP: LINE 16950 NOT CAPTURED]
// [GAP: LINE 16951 NOT CAPTURED]
// [GAP: LINE 16952 NOT CAPTURED]
// [GAP: LINE 16953 NOT CAPTURED]
// [GAP: LINE 16954 NOT CAPTURED]
// [GAP: LINE 16955 NOT CAPTURED]
// [GAP: LINE 16956 NOT CAPTURED]
// [GAP: LINE 16957 NOT CAPTURED]
// [GAP: LINE 16958 NOT CAPTURED]
// [GAP: LINE 16959 NOT CAPTURED]
// [GAP: LINE 16960 NOT CAPTURED]
// [GAP: LINE 16961 NOT CAPTURED]
// [GAP: LINE 16962 NOT CAPTURED]
// [GAP: LINE 16963 NOT CAPTURED]
// [GAP: LINE 16964 NOT CAPTURED]
// [GAP: LINE 16965 NOT CAPTURED]
// [GAP: LINE 16966 NOT CAPTURED]
// [GAP: LINE 16967 NOT CAPTURED]
// [GAP: LINE 16968 NOT CAPTURED]
// [GAP: LINE 16969 NOT CAPTURED]
// [GAP: LINE 16970 NOT CAPTURED]
// [GAP: LINE 16971 NOT CAPTURED]
// [GAP: LINE 16972 NOT CAPTURED]
// [GAP: LINE 16973 NOT CAPTURED]
// [GAP: LINE 16974 NOT CAPTURED]
// [GAP: LINE 16975 NOT CAPTURED]
// [GAP: LINE 16976 NOT CAPTURED]
// [GAP: LINE 16977 NOT CAPTURED]
// [GAP: LINE 16978 NOT CAPTURED]
// [GAP: LINE 16979 NOT CAPTURED]
// [GAP: LINE 16980 NOT CAPTURED]
// [GAP: LINE 16981 NOT CAPTURED]
// [GAP: LINE 16982 NOT CAPTURED]
// [GAP: LINE 16983 NOT CAPTURED]
// [GAP: LINE 16984 NOT CAPTURED]
// [GAP: LINE 16985 NOT CAPTURED]
// [GAP: LINE 16986 NOT CAPTURED]
// [GAP: LINE 16987 NOT CAPTURED]
// [GAP: LINE 16988 NOT CAPTURED]
// [GAP: LINE 16989 NOT CAPTURED]
// [GAP: LINE 16990 NOT CAPTURED]
// [GAP: LINE 16991 NOT CAPTURED]
// [GAP: LINE 16992 NOT CAPTURED]
// [GAP: LINE 16993 NOT CAPTURED]
// [GAP: LINE 16994 NOT CAPTURED]
// [GAP: LINE 16995 NOT CAPTURED]
// [GAP: LINE 16996 NOT CAPTURED]
// [GAP: LINE 16997 NOT CAPTURED]
// [GAP: LINE 16998 NOT CAPTURED]
// [GAP: LINE 16999 NOT CAPTURED]
// [GAP: LINE 17000 NOT CAPTURED]
// [GAP: LINE 17001 NOT CAPTURED]
// [GAP: LINE 17002 NOT CAPTURED]
// [GAP: LINE 17003 NOT CAPTURED]
// [GAP: LINE 17004 NOT CAPTURED]
// [GAP: LINE 17005 NOT CAPTURED]
// [GAP: LINE 17006 NOT CAPTURED]
// [GAP: LINE 17007 NOT CAPTURED]
// [GAP: LINE 17008 NOT CAPTURED]
// [GAP: LINE 17009 NOT CAPTURED]
// [GAP: LINE 17010 NOT CAPTURED]
// [GAP: LINE 17011 NOT CAPTURED]
// [GAP: LINE 17012 NOT CAPTURED]
// [GAP: LINE 17013 NOT CAPTURED]
// [GAP: LINE 17014 NOT CAPTURED]
// [GAP: LINE 17015 NOT CAPTURED]
// [GAP: LINE 17016 NOT CAPTURED]
// [GAP: LINE 17017 NOT CAPTURED]
// [GAP: LINE 17018 NOT CAPTURED]
// [GAP: LINE 17019 NOT CAPTURED]
// [GAP: LINE 17020 NOT CAPTURED]
// [GAP: LINE 17021 NOT CAPTURED]
// [GAP: LINE 17022 NOT CAPTURED]
// [GAP: LINE 17023 NOT CAPTURED]
// [GAP: LINE 17024 NOT CAPTURED]
// [GAP: LINE 17025 NOT CAPTURED]
// [GAP: LINE 17026 NOT CAPTURED]
// [GAP: LINE 17027 NOT CAPTURED]
// [GAP: LINE 17028 NOT CAPTURED]
// [GAP: LINE 17029 NOT CAPTURED]
// [GAP: LINE 17030 NOT CAPTURED]
// [GAP: LINE 17031 NOT CAPTURED]
// [GAP: LINE 17032 NOT CAPTURED]
// [GAP: LINE 17033 NOT CAPTURED]
// [GAP: LINE 17034 NOT CAPTURED]
// [GAP: LINE 17035 NOT CAPTURED]
// [GAP: LINE 17036 NOT CAPTURED]
// [GAP: LINE 17037 NOT CAPTURED]
// [GAP: LINE 17038 NOT CAPTURED]
// [GAP: LINE 17039 NOT CAPTURED]
// [GAP: LINE 17040 NOT CAPTURED]
// [GAP: LINE 17041 NOT CAPTURED]
// [GAP: LINE 17042 NOT CAPTURED]
// [GAP: LINE 17043 NOT CAPTURED]
// [GAP: LINE 17044 NOT CAPTURED]
// [GAP: LINE 17045 NOT CAPTURED]
// [GAP: LINE 17046 NOT CAPTURED]
// [GAP: LINE 17047 NOT CAPTURED]
// [GAP: LINE 17048 NOT CAPTURED]
// [GAP: LINE 17049 NOT CAPTURED]
// [GAP: LINE 17050 NOT CAPTURED]
// [GAP: LINE 17051 NOT CAPTURED]
// [GAP: LINE 17052 NOT CAPTURED]
// [GAP: LINE 17053 NOT CAPTURED]
// [GAP: LINE 17054 NOT CAPTURED]
// [GAP: LINE 17055 NOT CAPTURED]
// [GAP: LINE 17056 NOT CAPTURED]
// [GAP: LINE 17057 NOT CAPTURED]
// [GAP: LINE 17058 NOT CAPTURED]
// [GAP: LINE 17059 NOT CAPTURED]
// [GAP: LINE 17060 NOT CAPTURED]
// [GAP: LINE 17061 NOT CAPTURED]
// [GAP: LINE 17062 NOT CAPTURED]
// [GAP: LINE 17063 NOT CAPTURED]
// [GAP: LINE 17064 NOT CAPTURED]
// [GAP: LINE 17065 NOT CAPTURED]
// [GAP: LINE 17066 NOT CAPTURED]
// [GAP: LINE 17067 NOT CAPTURED]
// [GAP: LINE 17068 NOT CAPTURED]
// [GAP: LINE 17069 NOT CAPTURED]
// [GAP: LINE 17070 NOT CAPTURED]
// [GAP: LINE 17071 NOT CAPTURED]
// [GAP: LINE 17072 NOT CAPTURED]
// [GAP: LINE 17073 NOT CAPTURED]
// [GAP: LINE 17074 NOT CAPTURED]
// [GAP: LINE 17075 NOT CAPTURED]
// [GAP: LINE 17076 NOT CAPTURED]
// [GAP: LINE 17077 NOT CAPTURED]
// [GAP: LINE 17078 NOT CAPTURED]
// [GAP: LINE 17079 NOT CAPTURED]
// [GAP: LINE 17080 NOT CAPTURED]
// [GAP: LINE 17081 NOT CAPTURED]
// [GAP: LINE 17082 NOT CAPTURED]
// [GAP: LINE 17083 NOT CAPTURED]
// [GAP: LINE 17084 NOT CAPTURED]
// [GAP: LINE 17085 NOT CAPTURED]
// [GAP: LINE 17086 NOT CAPTURED]
// [GAP: LINE 17087 NOT CAPTURED]
// [GAP: LINE 17088 NOT CAPTURED]
// [GAP: LINE 17089 NOT CAPTURED]
// [GAP: LINE 17090 NOT CAPTURED]
// [GAP: LINE 17091 NOT CAPTURED]
// [GAP: LINE 17092 NOT CAPTURED]
// [GAP: LINE 17093 NOT CAPTURED]
// [GAP: LINE 17094 NOT CAPTURED]
// [GAP: LINE 17095 NOT CAPTURED]
// [GAP: LINE 17096 NOT CAPTURED]
// [GAP: LINE 17097 NOT CAPTURED]
// [GAP: LINE 17098 NOT CAPTURED]
// [GAP: LINE 17099 NOT CAPTURED]

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
// [GAP: LINE 17173 NOT CAPTURED]
// [GAP: LINE 17174 NOT CAPTURED]
// [GAP: LINE 17175 NOT CAPTURED]
// [GAP: LINE 17176 NOT CAPTURED]
// [GAP: LINE 17177 NOT CAPTURED]
// [GAP: LINE 17178 NOT CAPTURED]
// [GAP: LINE 17179 NOT CAPTURED]
// [GAP: LINE 17180 NOT CAPTURED]
// [GAP: LINE 17181 NOT CAPTURED]
// [GAP: LINE 17182 NOT CAPTURED]
// [GAP: LINE 17183 NOT CAPTURED]
// [GAP: LINE 17184 NOT CAPTURED]
// [GAP: LINE 17185 NOT CAPTURED]
// [GAP: LINE 17186 NOT CAPTURED]
// [GAP: LINE 17187 NOT CAPTURED]
// [GAP: LINE 17188 NOT CAPTURED]
// [GAP: LINE 17189 NOT CAPTURED]
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
// [GAP: LINE 17311 NOT CAPTURED]
// [GAP: LINE 17312 NOT CAPTURED]
// [GAP: LINE 17313 NOT CAPTURED]
// [GAP: LINE 17314 NOT CAPTURED]
// [GAP: LINE 17315 NOT CAPTURED]
// [GAP: LINE 17316 NOT CAPTURED]
// [GAP: LINE 17317 NOT CAPTURED]
// [GAP: LINE 17318 NOT CAPTURED]
// [GAP: LINE 17319 NOT CAPTURED]
// [GAP: LINE 17320 NOT CAPTURED]
// [GAP: LINE 17321 NOT CAPTURED]
// [GAP: LINE 17322 NOT CAPTURED]
// [GAP: LINE 17323 NOT CAPTURED]
// [GAP: LINE 17324 NOT CAPTURED]
// [GAP: LINE 17325 NOT CAPTURED]
// [GAP: LINE 17326 NOT CAPTURED]
// [GAP: LINE 17327 NOT CAPTURED]
// [GAP: LINE 17328 NOT CAPTURED]
// [GAP: LINE 17329 NOT CAPTURED]
// [GAP: LINE 17330 NOT CAPTURED]
// [GAP: LINE 17331 NOT CAPTURED]
// [GAP: LINE 17332 NOT CAPTURED]
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

// ─── FULLSCREEN IMAGE VIEWER ─────────────────────────────────
class _FullscreenImage extends StatelessWidget {
  final String url;
  const _FullscreenImage({required this.url});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        onTap: () => Navigator.pop(context),
        child: Container(
          color: Colors.black87,
          child: Stack(children: [
            Center(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 5.0,
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Icon(
                    Icons.broken_image, color: Colors.white38, size: 64),
                ),
              ),
            ),
            // Close button
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              right: 16,
              child: GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black54,
                    border: Border.all(color: Colors.white24),
                  ),
                  child: const Icon(Icons.close, color: Colors.white, size: 18),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
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
// ═══════════════════════════════════════
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
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      gradient: _isPremium
                          ? LinearGradient(colors: [kGold.withValues(alpha: 0.15), kGold.withValues(alpha: 0.05)])
                          : LinearGradient(colors: [_g(0.05), _g(0.03)]),
                      border: Border.all(color: _isPremium ? kGold.withValues(alpha: 0.5) : _g(0.1)),
                    ),
                    child: _isPremium
                        ? Row(children: [
                            Container(width: 44, height: 44,
                              decoration: BoxDecoration(shape: BoxShape.circle, color: kGold.withValues(alpha: 0.15), border: Border.all(color: kGold.withValues(alpha: 0.4))),
                              child: const Center(child: Text('⭐', style: TextStyle(fontSize: 22)))),
                            const SizedBox(width: 14),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              const Text('Premium Ενεργό', style: TextStyle(color: kGold, fontFamily: 'Raleway', fontWeight: FontWeight.w800, fontSize: 15)),
                              Text('Απεριόριστα αιτήματα & προτεραιότητα', style: TextStyle(color: _g(0.5), fontSize: 11)),
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
                              label: _stripeLoading ? 'Φόρτωση...' : '💳  Συνδρομή — €$_subscriptionPrice/μήνα',
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
                      value: '2.0.0'),
                  _ProfileRow(
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
// [GAP: LINE 17795 NOT CAPTURED]
// [GAP: LINE 17796 NOT CAPTURED]
// [GAP: LINE 17797 NOT CAPTURED]
// [GAP: LINE 17798 NOT CAPTURED]
// [GAP: LINE 17799 NOT CAPTURED]
// [GAP: LINE 17800 NOT CAPTURED]
// [GAP: LINE 17801 NOT CAPTURED]
// [GAP: LINE 17802 NOT CAPTURED]
// [GAP: LINE 17803 NOT CAPTURED]
// [GAP: LINE 17804 NOT CAPTURED]
// [GAP: LINE 17805 NOT CAPTURED]
// [GAP: LINE 17806 NOT CAPTURED]
// [GAP: LINE 17807 NOT CAPTURED]
// [GAP: LINE 17808 NOT CAPTURED]
// [GAP: LINE 17809 NOT CAPTURED]
// [GAP: LINE 17810 NOT CAPTURED]
// [GAP: LINE 17811 NOT CAPTURED]
// [GAP: LINE 17812 NOT CAPTURED]
// [GAP: LINE 17813 NOT CAPTURED]
// [GAP: LINE 17814 NOT CAPTURED]
// [GAP: LINE 17815 NOT CAPTURED]
// [GAP: LINE 17816 NOT CAPTURED]
// [GAP: LINE 17817 NOT CAPTURED]
// [GAP: LINE 17818 NOT CAPTURED]
// [GAP: LINE 17819 NOT CAPTURED]
// [GAP: LINE 17820 NOT CAPTURED]
// [GAP: LINE 17821 NOT CAPTURED]
// [GAP: LINE 17822 NOT CAPTURED]
// [GAP: LINE 17823 NOT CAPTURED]
// [GAP: LINE 17824 NOT CAPTURED]
// [GAP: LINE 17825 NOT CAPTURED]
// [GAP: LINE 17826 NOT CAPTURED]
// [GAP: LINE 17827 NOT CAPTURED]
// [GAP: LINE 17828 NOT CAPTURED]
// [GAP: LINE 17829 NOT CAPTURED]
// [GAP: LINE 17830 NOT CAPTURED]
// [GAP: LINE 17831 NOT CAPTURED]
// [GAP: LINE 17832 NOT CAPTURED]
// [GAP: LINE 17833 NOT CAPTURED]
// [GAP: LINE 17834 NOT CAPTURED]
// [GAP: LINE 17835 NOT CAPTURED]
// [GAP: LINE 17836 NOT CAPTURED]
// [GAP: LINE 17837 NOT CAPTURED]
// [GAP: LINE 17838 NOT CAPTURED]
// [GAP: LINE 17839 NOT CAPTURED]
// [GAP: LINE 17840 NOT CAPTURED]
// [GAP: LINE 17841 NOT CAPTURED]
// [GAP: LINE 17842 NOT CAPTURED]
// [GAP: LINE 17843 NOT CAPTURED]
// [GAP: LINE 17844 NOT CAPTURED]
// [GAP: LINE 17845 NOT CAPTURED]
// [GAP: LINE 17846 NOT CAPTURED]
// [GAP: LINE 17847 NOT CAPTURED]
// [GAP: LINE 17848 NOT CAPTURED]
// [GAP: LINE 17849 NOT CAPTURED]
// [GAP: LINE 17850 NOT CAPTURED]
// [GAP: LINE 17851 NOT CAPTURED]
// [GAP: LINE 17852 NOT CAPTURED]
// [GAP: LINE 17853 NOT CAPTURED]
// [GAP: LINE 17854 NOT CAPTURED]
// [GAP: LINE 17855 NOT CAPTURED]
// [GAP: LINE 17856 NOT CAPTURED]
// [GAP: LINE 17857 NOT CAPTURED]
// [GAP: LINE 17858 NOT CAPTURED]
// [GAP: LINE 17859 NOT CAPTURED]
// [GAP: LINE 17860 NOT CAPTURED]
// [GAP: LINE 17861 NOT CAPTURED]
// [GAP: LINE 17862 NOT CAPTURED]
// [GAP: LINE 17863 NOT CAPTURED]
// [GAP: LINE 17864 NOT CAPTURED]
// [GAP: LINE 17865 NOT CAPTURED]
// [GAP: LINE 17866 NOT CAPTURED]
// [GAP: LINE 17867 NOT CAPTURED]
// [GAP: LINE 17868 NOT CAPTURED]
// [GAP: LINE 17869 NOT CAPTURED]
// [GAP: LINE 17870 NOT CAPTURED]
// [GAP: LINE 17871 NOT CAPTURED]
// [GAP: LINE 17872 NOT CAPTURED]
// [GAP: LINE 17873 NOT CAPTURED]
// [GAP: LINE 17874 NOT CAPTURED]
// [GAP: LINE 17875 NOT CAPTURED]
// [GAP: LINE 17876 NOT CAPTURED]
// [GAP: LINE 17877 NOT CAPTURED]
// [GAP: LINE 17878 NOT CAPTURED]
// [GAP: LINE 17879 NOT CAPTURED]
// [GAP: LINE 17880 NOT CAPTURED]
// [GAP: LINE 17881 NOT CAPTURED]
// [GAP: LINE 17882 NOT CAPTURED]
// [GAP: LINE 17883 NOT CAPTURED]
// [GAP: LINE 17884 NOT CAPTURED]
// [GAP: LINE 17885 NOT CAPTURED]
// [GAP: LINE 17886 NOT CAPTURED]
// [GAP: LINE 17887 NOT CAPTURED]
// [GAP: LINE 17888 NOT CAPTURED]
// [GAP: LINE 17889 NOT CAPTURED]
// [GAP: LINE 17890 NOT CAPTURED]
// [GAP: LINE 17891 NOT CAPTURED]
// [GAP: LINE 17892 NOT CAPTURED]
// [GAP: LINE 17893 NOT CAPTURED]
// [GAP: LINE 17894 NOT CAPTURED]
// [GAP: LINE 17895 NOT CAPTURED]
// [GAP: LINE 17896 NOT CAPTURED]
// [GAP: LINE 17897 NOT CAPTURED]
// [GAP: LINE 17898 NOT CAPTURED]
// [GAP: LINE 17899 NOT CAPTURED]
// [GAP: LINE 17900 NOT CAPTURED]
// [GAP: LINE 17901 NOT CAPTURED]
// [GAP: LINE 17902 NOT CAPTURED]
// [GAP: LINE 17903 NOT CAPTURED]
// [GAP: LINE 17904 NOT CAPTURED]
// [GAP: LINE 17905 NOT CAPTURED]
// [GAP: LINE 17906 NOT CAPTURED]
// [GAP: LINE 17907 NOT CAPTURED]
// [GAP: LINE 17908 NOT CAPTURED]
// [GAP: LINE 17909 NOT CAPTURED]
// [GAP: LINE 17910 NOT CAPTURED]
// [GAP: LINE 17911 NOT CAPTURED]
// [GAP: LINE 17912 NOT CAPTURED]
// [GAP: LINE 17913 NOT CAPTURED]
// [GAP: LINE 17914 NOT CAPTURED]
// [GAP: LINE 17915 NOT CAPTURED]
// [GAP: LINE 17916 NOT CAPTURED]
// [GAP: LINE 17917 NOT CAPTURED]
// [GAP: LINE 17918 NOT CAPTURED]
// [GAP: LINE 17919 NOT CAPTURED]
// [GAP: LINE 17920 NOT CAPTURED]
// [GAP: LINE 17921 NOT CAPTURED]
// [GAP: LINE 17922 NOT CAPTURED]
// [GAP: LINE 17923 NOT CAPTURED]
// [GAP: LINE 17924 NOT CAPTURED]
// [GAP: LINE 17925 NOT CAPTURED]
// [GAP: LINE 17926 NOT CAPTURED]
// [GAP: LINE 17927 NOT CAPTURED]
// [GAP: LINE 17928 NOT CAPTURED]
// [GAP: LINE 17929 NOT CAPTURED]
// [GAP: LINE 17930 NOT CAPTURED]
// [GAP: LINE 17931 NOT CAPTURED]
// [GAP: LINE 17932 NOT CAPTURED]
// [GAP: LINE 17933 NOT CAPTURED]
// [GAP: LINE 17934 NOT CAPTURED]
// [GAP: LINE 17935 NOT CAPTURED]
// [GAP: LINE 17936 NOT CAPTURED]
// [GAP: LINE 17937 NOT CAPTURED]
// [GAP: LINE 17938 NOT CAPTURED]
// [GAP: LINE 17939 NOT CAPTURED]
// [GAP: LINE 17940 NOT CAPTURED]
// [GAP: LINE 17941 NOT CAPTURED]
// [GAP: LINE 17942 NOT CAPTURED]
// [GAP: LINE 17943 NOT CAPTURED]
// [GAP: LINE 17944 NOT CAPTURED]
// [GAP: LINE 17945 NOT CAPTURED]
// [GAP: LINE 17946 NOT CAPTURED]
// [GAP: LINE 17947 NOT CAPTURED]
// [GAP: LINE 17948 NOT CAPTURED]
// [GAP: LINE 17949 NOT CAPTURED]
// [GAP: LINE 17950 NOT CAPTURED]
// [GAP: LINE 17951 NOT CAPTURED]
// [GAP: LINE 17952 NOT CAPTURED]
// [GAP: LINE 17953 NOT CAPTURED]
// [GAP: LINE 17954 NOT CAPTURED]
// [GAP: LINE 17955 NOT CAPTURED]
// [GAP: LINE 17956 NOT CAPTURED]
// [GAP: LINE 17957 NOT CAPTURED]
// [GAP: LINE 17958 NOT CAPTURED]
// [GAP: LINE 17959 NOT CAPTURED]
// [GAP: LINE 17960 NOT CAPTURED]
// [GAP: LINE 17961 NOT CAPTURED]
// [GAP: LINE 17962 NOT CAPTURED]
// [GAP: LINE 17963 NOT CAPTURED]
// [GAP: LINE 17964 NOT CAPTURED]
// [GAP: LINE 17965 NOT CAPTURED]
// [GAP: LINE 17966 NOT CAPTURED]
// [GAP: LINE 17967 NOT CAPTURED]
// [GAP: LINE 17968 NOT CAPTURED]
// [GAP: LINE 17969 NOT CAPTURED]
// [GAP: LINE 17970 NOT CAPTURED]
// [GAP: LINE 17971 NOT CAPTURED]
// [GAP: LINE 17972 NOT CAPTURED]
// [GAP: LINE 17973 NOT CAPTURED]
// [GAP: LINE 17974 NOT CAPTURED]
// [GAP: LINE 17975 NOT CAPTURED]
// [GAP: LINE 17976 NOT CAPTURED]
// [GAP: LINE 17977 NOT CAPTURED]
// [GAP: LINE 17978 NOT CAPTURED]
// [GAP: LINE 17979 NOT CAPTURED]
// [GAP: LINE 17980 NOT CAPTURED]
// [GAP: LINE 17981 NOT CAPTURED]
// [GAP: LINE 17982 NOT CAPTURED]
// [GAP: LINE 17983 NOT CAPTURED]
// [GAP: LINE 17984 NOT CAPTURED]
// [GAP: LINE 17985 NOT CAPTURED]
// [GAP: LINE 17986 NOT CAPTURED]
// [GAP: LINE 17987 NOT CAPTURED]
// [GAP: LINE 17988 NOT CAPTURED]
// [GAP: LINE 17989 NOT CAPTURED]
// [GAP: LINE 17990 NOT CAPTURED]
// [GAP: LINE 17991 NOT CAPTURED]
// [GAP: LINE 17992 NOT CAPTURED]
// [GAP: LINE 17993 NOT CAPTURED]
// [GAP: LINE 17994 NOT CAPTURED]
// [GAP: LINE 17995 NOT CAPTURED]
// [GAP: LINE 17996 NOT CAPTURED]
// [GAP: LINE 17997 NOT CAPTURED]
// [GAP: LINE 17998 NOT CAPTURED]
// [GAP: LINE 17999 NOT CAPTURED]
// [GAP: LINE 18000 NOT CAPTURED]
// [GAP: LINE 18001 NOT CAPTURED]
// [GAP: LINE 18002 NOT CAPTURED]
// [GAP: LINE 18003 NOT CAPTURED]
// [GAP: LINE 18004 NOT CAPTURED]
// [GAP: LINE 18005 NOT CAPTURED]
// [GAP: LINE 18006 NOT CAPTURED]
// [GAP: LINE 18007 NOT CAPTURED]
// [GAP: LINE 18008 NOT CAPTURED]
// [GAP: LINE 18009 NOT CAPTURED]
// [GAP: LINE 18010 NOT CAPTURED]
// [GAP: LINE 18011 NOT CAPTURED]
// [GAP: LINE 18012 NOT CAPTURED]
// [GAP: LINE 18013 NOT CAPTURED]
// [GAP: LINE 18014 NOT CAPTURED]
// [GAP: LINE 18015 NOT CAPTURED]
// [GAP: LINE 18016 NOT CAPTURED]
// [GAP: LINE 18017 NOT CAPTURED]
// [GAP: LINE 18018 NOT CAPTURED]
// [GAP: LINE 18019 NOT CAPTURED]
// [GAP: LINE 18020 NOT CAPTURED]
// [GAP: LINE 18021 NOT CAPTURED]
// [GAP: LINE 18022 NOT CAPTURED]
// [GAP: LINE 18023 NOT CAPTURED]
// [GAP: LINE 18024 NOT CAPTURED]
// [GAP: LINE 18025 NOT CAPTURED]
// [GAP: LINE 18026 NOT CAPTURED]
// [GAP: LINE 18027 NOT CAPTURED]
// [GAP: LINE 18028 NOT CAPTURED]
// [GAP: LINE 18029 NOT CAPTURED]
// [GAP: LINE 18030 NOT CAPTURED]
// [GAP: LINE 18031 NOT CAPTURED]
// [GAP: LINE 18032 NOT CAPTURED]
// [GAP: LINE 18033 NOT CAPTURED]
// [GAP: LINE 18034 NOT CAPTURED]
// [GAP: LINE 18035 NOT CAPTURED]
// [GAP: LINE 18036 NOT CAPTURED]
// [GAP: LINE 18037 NOT CAPTURED]
// [GAP: LINE 18038 NOT CAPTURED]
// [GAP: LINE 18039 NOT CAPTURED]
// [GAP: LINE 18040 NOT CAPTURED]
// [GAP: LINE 18041 NOT CAPTURED]
// [GAP: LINE 18042 NOT CAPTURED]
// [GAP: LINE 18043 NOT CAPTURED]
// [GAP: LINE 18044 NOT CAPTURED]
// [GAP: LINE 18045 NOT CAPTURED]
// [GAP: LINE 18046 NOT CAPTURED]
// [GAP: LINE 18047 NOT CAPTURED]
// [GAP: LINE 18048 NOT CAPTURED]
// [GAP: LINE 18049 NOT CAPTURED]
// [GAP: LINE 18050 NOT CAPTURED]
// [GAP: LINE 18051 NOT CAPTURED]
// [GAP: LINE 18052 NOT CAPTURED]
// [GAP: LINE 18053 NOT CAPTURED]
// [GAP: LINE 18054 NOT CAPTURED]
// [GAP: LINE 18055 NOT CAPTURED]
// [GAP: LINE 18056 NOT CAPTURED]
// [GAP: LINE 18057 NOT CAPTURED]
// [GAP: LINE 18058 NOT CAPTURED]
// [GAP: LINE 18059 NOT CAPTURED]
// [GAP: LINE 18060 NOT CAPTURED]
// [GAP: LINE 18061 NOT CAPTURED]
// [GAP: LINE 18062 NOT CAPTURED]
// [GAP: LINE 18063 NOT CAPTURED]
// [GAP: LINE 18064 NOT CAPTURED]
// [GAP: LINE 18065 NOT CAPTURED]
// [GAP: LINE 18066 NOT CAPTURED]
// [GAP: LINE 18067 NOT CAPTURED]
// [GAP: LINE 18068 NOT CAPTURED]
// [GAP: LINE 18069 NOT CAPTURED]
// [GAP: LINE 18070 NOT CAPTURED]
// [GAP: LINE 18071 NOT CAPTURED]
// [GAP: LINE 18072 NOT CAPTURED]
// [GAP: LINE 18073 NOT CAPTURED]
// [GAP: LINE 18074 NOT CAPTURED]
// [GAP: LINE 18075 NOT CAPTURED]
// [GAP: LINE 18076 NOT CAPTURED]
// [GAP: LINE 18077 NOT CAPTURED]
// [GAP: LINE 18078 NOT CAPTURED]
// [GAP: LINE 18079 NOT CAPTURED]
// [GAP: LINE 18080 NOT CAPTURED]
// [GAP: LINE 18081 NOT CAPTURED]
// [GAP: LINE 18082 NOT CAPTURED]
// [GAP: LINE 18083 NOT CAPTURED]
// [GAP: LINE 18084 NOT CAPTURED]
// [GAP: LINE 18085 NOT CAPTURED]
// [GAP: LINE 18086 NOT CAPTURED]
// [GAP: LINE 18087 NOT CAPTURED]
// [GAP: LINE 18088 NOT CAPTURED]
// [GAP: LINE 18089 NOT CAPTURED]
// [GAP: LINE 18090 NOT CAPTURED]
// [GAP: LINE 18091 NOT CAPTURED]
// [GAP: LINE 18092 NOT CAPTURED]
// [GAP: LINE 18093 NOT CAPTURED]
// [GAP: LINE 18094 NOT CAPTURED]
// [GAP: LINE 18095 NOT CAPTURED]
// [GAP: LINE 18096 NOT CAPTURED]
// [GAP: LINE 18097 NOT CAPTURED]
// [GAP: LINE 18098 NOT CAPTURED]
// [GAP: LINE 18099 NOT CAPTURED]
// [GAP: LINE 18100 NOT CAPTURED]
// [GAP: LINE 18101 NOT CAPTURED]
// [GAP: LINE 18102 NOT CAPTURED]
// [GAP: LINE 18103 NOT CAPTURED]
// [GAP: LINE 18104 NOT CAPTURED]
// [GAP: LINE 18105 NOT CAPTURED]
// [GAP: LINE 18106 NOT CAPTURED]
// [GAP: LINE 18107 NOT CAPTURED]
// [GAP: LINE 18108 NOT CAPTURED]
// [GAP: LINE 18109 NOT CAPTURED]
// [GAP: LINE 18110 NOT CAPTURED]
// [GAP: LINE 18111 NOT CAPTURED]
// [GAP: LINE 18112 NOT CAPTURED]
// [GAP: LINE 18113 NOT CAPTURED]
// [GAP: LINE 18114 NOT CAPTURED]
// [GAP: LINE 18115 NOT CAPTURED]
// [GAP: LINE 18116 NOT CAPTURED]
// [GAP: LINE 18117 NOT CAPTURED]
// [GAP: LINE 18118 NOT CAPTURED]
// [GAP: LINE 18119 NOT CAPTURED]
// [GAP: LINE 18120 NOT CAPTURED]
// [GAP: LINE 18121 NOT CAPTURED]
// [GAP: LINE 18122 NOT CAPTURED]
// [GAP: LINE 18123 NOT CAPTURED]
// [GAP: LINE 18124 NOT CAPTURED]
// [GAP: LINE 18125 NOT CAPTURED]
// [GAP: LINE 18126 NOT CAPTURED]
// [GAP: LINE 18127 NOT CAPTURED]
// [GAP: LINE 18128 NOT CAPTURED]
// [GAP: LINE 18129 NOT CAPTURED]
// [GAP: LINE 18130 NOT CAPTURED]
// [GAP: LINE 18131 NOT CAPTURED]
// [GAP: LINE 18132 NOT CAPTURED]
// [GAP: LINE 18133 NOT CAPTURED]
// [GAP: LINE 18134 NOT CAPTURED]
// [GAP: LINE 18135 NOT CAPTURED]
// [GAP: LINE 18136 NOT CAPTURED]
// [GAP: LINE 18137 NOT CAPTURED]
// [GAP: LINE 18138 NOT CAPTURED]
// [GAP: LINE 18139 NOT CAPTURED]
// [GAP: LINE 18140 NOT CAPTURED]
// [GAP: LINE 18141 NOT CAPTURED]
// [GAP: LINE 18142 NOT CAPTURED]
// [GAP: LINE 18143 NOT CAPTURED]
// [GAP: LINE 18144 NOT CAPTURED]
// [GAP: LINE 18145 NOT CAPTURED]
// [GAP: LINE 18146 NOT CAPTURED]
// [GAP: LINE 18147 NOT CAPTURED]
// [GAP: LINE 18148 NOT CAPTURED]
// [GAP: LINE 18149 NOT CAPTURED]
// [GAP: LINE 18150 NOT CAPTURED]
// [GAP: LINE 18151 NOT CAPTURED]
// [GAP: LINE 18152 NOT CAPTURED]
// [GAP: LINE 18153 NOT CAPTURED]
// [GAP: LINE 18154 NOT CAPTURED]
// [GAP: LINE 18155 NOT CAPTURED]
// [GAP: LINE 18156 NOT CAPTURED]
// [GAP: LINE 18157 NOT CAPTURED]
// [GAP: LINE 18158 NOT CAPTURED]
// [GAP: LINE 18159 NOT CAPTURED]
// [GAP: LINE 18160 NOT CAPTURED]
// [GAP: LINE 18161 NOT CAPTURED]
// [GAP: LINE 18162 NOT CAPTURED]
// [GAP: LINE 18163 NOT CAPTURED]
// [GAP: LINE 18164 NOT CAPTURED]
// [GAP: LINE 18165 NOT CAPTURED]
// [GAP: LINE 18166 NOT CAPTURED]
// [GAP: LINE 18167 NOT CAPTURED]
// [GAP: LINE 18168 NOT CAPTURED]
// [GAP: LINE 18169 NOT CAPTURED]
// [GAP: LINE 18170 NOT CAPTURED]
// [GAP: LINE 18171 NOT CAPTURED]
// [GAP: LINE 18172 NOT CAPTURED]
// [GAP: LINE 18173 NOT CAPTURED]
// [GAP: LINE 18174 NOT CAPTURED]
// [GAP: LINE 18175 NOT CAPTURED]
// [GAP: LINE 18176 NOT CAPTURED]
// [GAP: LINE 18177 NOT CAPTURED]
// [GAP: LINE 18178 NOT CAPTURED]
// [GAP: LINE 18179 NOT CAPTURED]
// [GAP: LINE 18180 NOT CAPTURED]
// [GAP: LINE 18181 NOT CAPTURED]
// [GAP: LINE 18182 NOT CAPTURED]
// [GAP: LINE 18183 NOT CAPTURED]
// [GAP: LINE 18184 NOT CAPTURED]
// [GAP: LINE 18185 NOT CAPTURED]
// [GAP: LINE 18186 NOT CAPTURED]
// [GAP: LINE 18187 NOT CAPTURED]
// [GAP: LINE 18188 NOT CAPTURED]
// [GAP: LINE 18189 NOT CAPTURED]
// [GAP: LINE 18190 NOT CAPTURED]
// [GAP: LINE 18191 NOT CAPTURED]
// [GAP: LINE 18192 NOT CAPTURED]
// [GAP: LINE 18193 NOT CAPTURED]
// [GAP: LINE 18194 NOT CAPTURED]
// [GAP: LINE 18195 NOT CAPTURED]
// [GAP: LINE 18196 NOT CAPTURED]
// [GAP: LINE 18197 NOT CAPTURED]
// [GAP: LINE 18198 NOT CAPTURED]
// [GAP: LINE 18199 NOT CAPTURED]
// [GAP: LINE 18200 NOT CAPTURED]
// [GAP: LINE 18201 NOT CAPTURED]
// [GAP: LINE 18202 NOT CAPTURED]
// [GAP: LINE 18203 NOT CAPTURED]
// [GAP: LINE 18204 NOT CAPTURED]
// [GAP: LINE 18205 NOT CAPTURED]
// [GAP: LINE 18206 NOT CAPTURED]
// [GAP: LINE 18207 NOT CAPTURED]
// [GAP: LINE 18208 NOT CAPTURED]
// [GAP: LINE 18209 NOT CAPTURED]
// [GAP: LINE 18210 NOT CAPTURED]
// [GAP: LINE 18211 NOT CAPTURED]
// [GAP: LINE 18212 NOT CAPTURED]
// [GAP: LINE 18213 NOT CAPTURED]
// [GAP: LINE 18214 NOT CAPTURED]
// [GAP: LINE 18215 NOT CAPTURED]
// [GAP: LINE 18216 NOT CAPTURED]
// [GAP: LINE 18217 NOT CAPTURED]
// [GAP: LINE 18218 NOT CAPTURED]
// [GAP: LINE 18219 NOT CAPTURED]
// [GAP: LINE 18220 NOT CAPTURED]
// [GAP: LINE 18221 NOT CAPTURED]
// [GAP: LINE 18222 NOT CAPTURED]
// [GAP: LINE 18223 NOT CAPTURED]
// [GAP: LINE 18224 NOT CAPTURED]
// [GAP: LINE 18225 NOT CAPTURED]
// [GAP: LINE 18226 NOT CAPTURED]
// [GAP: LINE 18227 NOT CAPTURED]
// [GAP: LINE 18228 NOT CAPTURED]
// [GAP: LINE 18229 NOT CAPTURED]
// [GAP: LINE 18230 NOT CAPTURED]
// [GAP: LINE 18231 NOT CAPTURED]
// [GAP: LINE 18232 NOT CAPTURED]
// [GAP: LINE 18233 NOT CAPTURED]
// [GAP: LINE 18234 NOT CAPTURED]
// [GAP: LINE 18235 NOT CAPTURED]
// [GAP: LINE 18236 NOT CAPTURED]
// [GAP: LINE 18237 NOT CAPTURED]
// [GAP: LINE 18238 NOT CAPTURED]
// [GAP: LINE 18239 NOT CAPTURED]
// [GAP: LINE 18240 NOT CAPTURED]
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
// [GAP: LINE 18276 NOT CAPTURED]
// [GAP: LINE 18277 NOT CAPTURED]
// [GAP: LINE 18278 NOT CAPTURED]
// [GAP: LINE 18279 NOT CAPTURED]
// [GAP: LINE 18280 NOT CAPTURED]
// [GAP: LINE 18281 NOT CAPTURED]
// [GAP: LINE 18282 NOT CAPTURED]
// [GAP: LINE 18283 NOT CAPTURED]
// [GAP: LINE 18284 NOT CAPTURED]
// [GAP: LINE 18285 NOT CAPTURED]
// [GAP: LINE 18286 NOT CAPTURED]
// [GAP: LINE 18287 NOT CAPTURED]
// [GAP: LINE 18288 NOT CAPTURED]
// [GAP: LINE 18289 NOT CAPTURED]
// [GAP: LINE 18290 NOT CAPTURED]
// [GAP: LINE 18291 NOT CAPTURED]
// [GAP: LINE 18292 NOT CAPTURED]
// [GAP: LINE 18293 NOT CAPTURED]
// [GAP: LINE 18294 NOT CAPTURED]
// [GAP: LINE 18295 NOT CAPTURED]
// [GAP: LINE 18296 NOT CAPTURED]
// [GAP: LINE 18297 NOT CAPTURED]
// [GAP: LINE 18298 NOT CAPTURED]
// [GAP: LINE 18299 NOT CAPTURED]
// [GAP: LINE 18300 NOT CAPTURED]
// [GAP: LINE 18301 NOT CAPTURED]
// [GAP: LINE 18302 NOT CAPTURED]
// [GAP: LINE 18303 NOT CAPTURED]
// [GAP: LINE 18304 NOT CAPTURED]
// [GAP: LINE 18305 NOT CAPTURED]
// [GAP: LINE 18306 NOT CAPTURED]
// [GAP: LINE 18307 NOT CAPTURED]
// [GAP: LINE 18308 NOT CAPTURED]
// [GAP: LINE 18309 NOT CAPTURED]
// [GAP: LINE 18310 NOT CAPTURED]
// [GAP: LINE 18311 NOT CAPTURED]
// [GAP: LINE 18312 NOT CAPTURED]
// [GAP: LINE 18313 NOT CAPTURED]
// [GAP: LINE 18314 NOT CAPTURED]
// [GAP: LINE 18315 NOT CAPTURED]
// [GAP: LINE 18316 NOT CAPTURED]
// [GAP: LINE 18317 NOT CAPTURED]
// [GAP: LINE 18318 NOT CAPTURED]
// [GAP: LINE 18319 NOT CAPTURED]
// [GAP: LINE 18320 NOT CAPTURED]
// [GAP: LINE 18321 NOT CAPTURED]
// [GAP: LINE 18322 NOT CAPTURED]
// [GAP: LINE 18323 NOT CAPTURED]
// [GAP: LINE 18324 NOT CAPTURED]
// [GAP: LINE 18325 NOT CAPTURED]
// [GAP: LINE 18326 NOT CAPTURED]
// [GAP: LINE 18327 NOT CAPTURED]
// [GAP: LINE 18328 NOT CAPTURED]
// [GAP: LINE 18329 NOT CAPTURED]
// [GAP: LINE 18330 NOT CAPTURED]
// [GAP: LINE 18331 NOT CAPTURED]
// [GAP: LINE 18332 NOT CAPTURED]
// [GAP: LINE 18333 NOT CAPTURED]
// [GAP: LINE 18334 NOT CAPTURED]
// [GAP: LINE 18335 NOT CAPTURED]
// [GAP: LINE 18336 NOT CAPTURED]
// [GAP: LINE 18337 NOT CAPTURED]
// [GAP: LINE 18338 NOT CAPTURED]
// [GAP: LINE 18339 NOT CAPTURED]
// [GAP: LINE 18340 NOT CAPTURED]
// [GAP: LINE 18341 NOT CAPTURED]
// [GAP: LINE 18342 NOT CAPTURED]
// [GAP: LINE 18343 NOT CAPTURED]
// [GAP: LINE 18344 NOT CAPTURED]
// [GAP: LINE 18345 NOT CAPTURED]
// [GAP: LINE 18346 NOT CAPTURED]
// [GAP: LINE 18347 NOT CAPTURED]
// [GAP: LINE 18348 NOT CAPTURED]
// [GAP: LINE 18349 NOT CAPTURED]
// [GAP: LINE 18350 NOT CAPTURED]
// [GAP: LINE 18351 NOT CAPTURED]
// [GAP: LINE 18352 NOT CAPTURED]
// [GAP: LINE 18353 NOT CAPTURED]
// [GAP: LINE 18354 NOT CAPTURED]
// [GAP: LINE 18355 NOT CAPTURED]
// [GAP: LINE 18356 NOT CAPTURED]
// [GAP: LINE 18357 NOT CAPTURED]
// [GAP: LINE 18358 NOT CAPTURED]
// [GAP: LINE 18359 NOT CAPTURED]
// [GAP: LINE 18360 NOT CAPTURED]
// [GAP: LINE 18361 NOT CAPTURED]
// [GAP: LINE 18362 NOT CAPTURED]
// [GAP: LINE 18363 NOT CAPTURED]
// [GAP: LINE 18364 NOT CAPTURED]
// [GAP: LINE 18365 NOT CAPTURED]
// [GAP: LINE 18366 NOT CAPTURED]
// [GAP: LINE 18367 NOT CAPTURED]
// [GAP: LINE 18368 NOT CAPTURED]
// [GAP: LINE 18369 NOT CAPTURED]
// [GAP: LINE 18370 NOT CAPTURED]
// [GAP: LINE 18371 NOT CAPTURED]
// [GAP: LINE 18372 NOT CAPTURED]
// [GAP: LINE 18373 NOT CAPTURED]
// [GAP: LINE 18374 NOT CAPTURED]
// [GAP: LINE 18375 NOT CAPTURED]
// [GAP: LINE 18376 NOT CAPTURED]
// [GAP: LINE 18377 NOT CAPTURED]
// [GAP: LINE 18378 NOT CAPTURED]
// [GAP: LINE 18379 NOT CAPTURED]
// [GAP: LINE 18380 NOT CAPTURED]
// [GAP: LINE 18381 NOT CAPTURED]
// [GAP: LINE 18382 NOT CAPTURED]
// [GAP: LINE 18383 NOT CAPTURED]
// [GAP: LINE 18384 NOT CAPTURED]
// [GAP: LINE 18385 NOT CAPTURED]
// [GAP: LINE 18386 NOT CAPTURED]
// [GAP: LINE 18387 NOT CAPTURED]
// [GAP: LINE 18388 NOT CAPTURED]
// [GAP: LINE 18389 NOT CAPTURED]
// [GAP: LINE 18390 NOT CAPTURED]
// [GAP: LINE 18391 NOT CAPTURED]
// [GAP: LINE 18392 NOT CAPTURED]
// [GAP: LINE 18393 NOT CAPTURED]
// [GAP: LINE 18394 NOT CAPTURED]
// [GAP: LINE 18395 NOT CAPTURED]
// [GAP: LINE 18396 NOT CAPTURED]
// [GAP: LINE 18397 NOT CAPTURED]
// [GAP: LINE 18398 NOT CAPTURED]
// [GAP: LINE 18399 NOT CAPTURED]
// [GAP: LINE 18400 NOT CAPTURED]
// [GAP: LINE 18401 NOT CAPTURED]
// [GAP: LINE 18402 NOT CAPTURED]
// [GAP: LINE 18403 NOT CAPTURED]
// [GAP: LINE 18404 NOT CAPTURED]
// [GAP: LINE 18405 NOT CAPTURED]
// [GAP: LINE 18406 NOT CAPTURED]
// [GAP: LINE 18407 NOT CAPTURED]
// [GAP: LINE 18408 NOT CAPTURED]
// [GAP: LINE 18409 NOT CAPTURED]
// [GAP: LINE 18410 NOT CAPTURED]
// [GAP: LINE 18411 NOT CAPTURED]
// [GAP: LINE 18412 NOT CAPTURED]
// [GAP: LINE 18413 NOT CAPTURED]
// [GAP: LINE 18414 NOT CAPTURED]
// [GAP: LINE 18415 NOT CAPTURED]
// [GAP: LINE 18416 NOT CAPTURED]
// [GAP: LINE 18417 NOT CAPTURED]
// [GAP: LINE 18418 NOT CAPTURED]
// [GAP: LINE 18419 NOT CAPTURED]
// [GAP: LINE 18420 NOT CAPTURED]
// [GAP: LINE 18421 NOT CAPTURED]
// [GAP: LINE 18422 NOT CAPTURED]
// [GAP: LINE 18423 NOT CAPTURED]
// [GAP: LINE 18424 NOT CAPTURED]
// [GAP: LINE 18425 NOT CAPTURED]
// [GAP: LINE 18426 NOT CAPTURED]
// [GAP: LINE 18427 NOT CAPTURED]
// [GAP: LINE 18428 NOT CAPTURED]
// [GAP: LINE 18429 NOT CAPTURED]
// [GAP: LINE 18430 NOT CAPTURED]
// [GAP: LINE 18431 NOT CAPTURED]
// [GAP: LINE 18432 NOT CAPTURED]
// [GAP: LINE 18433 NOT CAPTURED]
// [GAP: LINE 18434 NOT CAPTURED]
// [GAP: LINE 18435 NOT CAPTURED]
// [GAP: LINE 18436 NOT CAPTURED]
// [GAP: LINE 18437 NOT CAPTURED]
// [GAP: LINE 18438 NOT CAPTURED]
// [GAP: LINE 18439 NOT CAPTURED]
// [GAP: LINE 18440 NOT CAPTURED]
// [GAP: LINE 18441 NOT CAPTURED]
// [GAP: LINE 18442 NOT CAPTURED]
// [GAP: LINE 18443 NOT CAPTURED]
// [GAP: LINE 18444 NOT CAPTURED]
// [GAP: LINE 18445 NOT CAPTURED]
// [GAP: LINE 18446 NOT CAPTURED]
// [GAP: LINE 18447 NOT CAPTURED]
// [GAP: LINE 18448 NOT CAPTURED]
// [GAP: LINE 18449 NOT CAPTURED]
// [GAP: LINE 18450 NOT CAPTURED]
// [GAP: LINE 18451 NOT CAPTURED]
// [GAP: LINE 18452 NOT CAPTURED]
// [GAP: LINE 18453 NOT CAPTURED]
// [GAP: LINE 18454 NOT CAPTURED]
// [GAP: LINE 18455 NOT CAPTURED]
// [GAP: LINE 18456 NOT CAPTURED]
// [GAP: LINE 18457 NOT CAPTURED]
// [GAP: LINE 18458 NOT CAPTURED]
// [GAP: LINE 18459 NOT CAPTURED]
// [GAP: LINE 18460 NOT CAPTURED]
// [GAP: LINE 18461 NOT CAPTURED]
// [GAP: LINE 18462 NOT CAPTURED]
// [GAP: LINE 18463 NOT CAPTURED]
// [GAP: LINE 18464 NOT CAPTURED]
// [GAP: LINE 18465 NOT CAPTURED]
// [GAP: LINE 18466 NOT CAPTURED]
// [GAP: LINE 18467 NOT CAPTURED]
// [GAP: LINE 18468 NOT CAPTURED]
// [GAP: LINE 18469 NOT CAPTURED]
// [GAP: LINE 18470 NOT CAPTURED]
// [GAP: LINE 18471 NOT CAPTURED]
// [GAP: LINE 18472 NOT CAPTURED]
// [GAP: LINE 18473 NOT CAPTURED]
// [GAP: LINE 18474 NOT CAPTURED]
// [GAP: LINE 18475 NOT CAPTURED]
// [GAP: LINE 18476 NOT CAPTURED]
// [GAP: LINE 18477 NOT CAPTURED]
// [GAP: LINE 18478 NOT CAPTURED]
// [GAP: LINE 18479 NOT CAPTURED]
// [GAP: LINE 18480 NOT CAPTURED]
// [GAP: LINE 18481 NOT CAPTURED]
// [GAP: LINE 18482 NOT CAPTURED]
// [GAP: LINE 18483 NOT CAPTURED]
// [GAP: LINE 18484 NOT CAPTURED]
// [GAP: LINE 18485 NOT CAPTURED]
// [GAP: LINE 18486 NOT CAPTURED]
// [GAP: LINE 18487 NOT CAPTURED]
// [GAP: LINE 18488 NOT CAPTURED]
// [GAP: LINE 18489 NOT CAPTURED]
// [GAP: LINE 18490 NOT CAPTURED]
// [GAP: LINE 18491 NOT CAPTURED]
// [GAP: LINE 18492 NOT CAPTURED]
// [GAP: LINE 18493 NOT CAPTURED]
// [GAP: LINE 18494 NOT CAPTURED]
// [GAP: LINE 18495 NOT CAPTURED]
// [GAP: LINE 18496 NOT CAPTURED]
// [GAP: LINE 18497 NOT CAPTURED]
// [GAP: LINE 18498 NOT CAPTURED]
// [GAP: LINE 18499 NOT CAPTURED]
// [GAP: LINE 18500 NOT CAPTURED]
// [GAP: LINE 18501 NOT CAPTURED]
// [GAP: LINE 18502 NOT CAPTURED]
// [GAP: LINE 18503 NOT CAPTURED]
// [GAP: LINE 18504 NOT CAPTURED]
// [GAP: LINE 18505 NOT CAPTURED]
// [GAP: LINE 18506 NOT CAPTURED]
// [GAP: LINE 18507 NOT CAPTURED]
// [GAP: LINE 18508 NOT CAPTURED]
// [GAP: LINE 18509 NOT CAPTURED]
// [GAP: LINE 18510 NOT CAPTURED]
// [GAP: LINE 18511 NOT CAPTURED]
// [GAP: LINE 18512 NOT CAPTURED]
// [GAP: LINE 18513 NOT CAPTURED]

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

        if (!areaMatches) return false;
      }
    }
    return true;
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

  @override
  void initState() {
    super.initState();
    _loadSpecialties();
    _loadLastVisit();
  }

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
          .where('userId', isEqualTo: widget.userId)
          .limit(1)
          .get();
      if (proSnap.docs.isNotEmpty) {
        final pd = proSnap.docs.first.data();
        final main = pd['specialty'] as String? ?? '';
        if (main.isNotEmpty) allSpecs.add(main);
        final proSpecs = pd['specialties'];
        if (proSpecs is List) allSpecs.addAll(proSpecs.map((e) => e.toString()));
        // Load service areas
        final rawAreas = pd['areas'];
        List<String> areas = [];
        if (rawAreas is List) {
          areas = List<String>.from(rawAreas.map((e) => e.toString()));
        } else {
          final singleArea = pd['area'] as String?;
          if (singleArea != null && singleArea.isNotEmpty) areas = [singleArea];
        }
        if (mounted) setState(() => _proAreas = areas);
      }
      if (mounted) setState(() => _proSpecialties = allSpecs.toList());
    } catch (_) {}
  }

  bool _matchesRequest(Map<String, dynamic> d) {
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

// ════════════════════════════════════════════════
// CHAT SCREEN — Real-time bidirectional messaging
// ════════════════════════════════════════════════
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
}

class _ChatScreenState extends State<ChatScreen> {
  final _msgCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  bool _sending = false;
  final List<Uint8List> _selectedImages = [];
  final List<String> _selectedVideoNames = []; // display names only
  final List<dynamic> _selectedVideoFiles = []; // XFile list

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

  void _openImageFullscreen(BuildContext context, String url) {
    Navigator.push(context, PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black87,
      pageBuilder: (_, __, ___) => _FullscreenImage(url: url),
      transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
    ));
  }

  Future<void> _markAsRead() async {
    try {
      final field = widget.isPro ? 'unreadPro' : 'unreadUser';
      await FirebaseFirestore.instance
          .collection('chats').doc(widget.chatId)
          .update({field: 0});
    } catch (_) {}
  }

  Future<void> _sendMessage() async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty && _selectedImages.isEmpty && _selectedVideoFiles.isEmpty) return;
    setState(() => _sending = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final db = FirebaseFirestore.instance;
      final ref = db.collection('chats').doc(widget.chatId);

      // Upload images if any
      List<String> imageUrls = [];
      for (int i = 0; i < _selectedImages.length; i++) {
        final bytes = _selectedImages[i];
        final storageRef = FirebaseStorage.instance
            .ref('chats/${widget.chatId}/${DateTime.now().millisecondsSinceEpoch}_$i.jpg');
        await storageRef.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
        imageUrls.add(await storageRef.getDownloadURL());
      }

      await db.collection('chats').doc(widget.chatId).collection('messages').add({
        'text': text,
        'senderId': widget.currentUserId,
        'senderName': widget.currentUserName,
        'timestamp': FieldValue.serverTimestamp(),
        'imageUrls': imageUrls,
      });

      // Update chat metadata
      final unreadField = widget.isPro ? 'unreadUser' : 'unreadPro';
      await ref.set({
        'lastMessage': text.isNotEmpty ? text : '📷 Φωτογραφία',
        'lastMessageAt': FieldValue.serverTimestamp(),
        unreadField: FieldValue.increment(1),
      }, SetOptions(merge: true));

      _msgCtrl.clear();
      setState(() { _selectedImages.clear(); _selectedVideoFiles.clear(); _selectedVideoNames.clear(); });
    } catch (e) {
      debugPrint('Send error: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A1428),
        elevation: 0,
        leading: GestureDetector(
          onTap: () => Navigator.pop(context),
          child: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 18),
        ),
        title: Text(widget.otherName,
            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
      ),
      body: Column(children: [
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('chats').doc(widget.chatId)
                .collection('messages')
                .orderBy('timestamp', descending: false)
                .snapshots(),
            builder: (context, snap) {
              if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: kGold));
              final msgs = snap.data!.docs;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_scrollCtrl.hasClients) {
                  _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent,
                      duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
                }
              });
              return ListView.builder(
                controller: _scrollCtrl,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                itemCount: msgs.length,
                itemBuilder: (_, i) {
                  final d = msgs[i].data() as Map<String, dynamic>;
                  final isMe = d['senderId'] == widget.currentUserId;
                  final text = d['text'] as String? ?? '';
                  final images = (d['imageUrls'] as List<dynamic>?)?.cast<String>() ?? [];
                  final ts = d['timestamp'] as Timestamp?;
                  final timeStr = ts != null
                      ? '${ts.toDate().hour.toString().padLeft(2,'0')}:${ts.toDate().minute.toString().padLeft(2,'0')}'
                      : '';
                  return Align(
                    alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        color: isMe ? kGold.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.06),
                        border: Border.all(
                          color: isMe ? kGold.withValues(alpha: 0.4) : Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        if (images.isNotEmpty) ...images.map((url) => GestureDetector(
                          onTap: () => _openImageFullscreen(context, url),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(url, height: 180, fit: BoxFit.cover),
                          ),
                        )),
                        if (text.isNotEmpty) Text(text,
                            style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.4)),
                        const SizedBox(height: 4),
                        Text(timeStr, style: TextStyle(color: Colors.white.withValues(alpha: 0.35), fontSize: 10)),
                      ]),
                    ),
                  );
                },
              );
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
          color: const Color(0xFF0A1428),
          child: Row(children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  color: Colors.white.withValues(alpha: 0.06),
                  border: Border.all(color: kGold.withValues(alpha: 0.3)),
                ),
                child: TextField(
                  controller: _msgCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Γράψε μήνυμα...',
                    hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 14),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  ),
                  maxLines: null,
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _sending ? null : _sendMessage,
              child: Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(colors: [kGoldLight, kGold]),
                ),
                child: _sending
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2))
                    : const Icon(Icons.send_rounded, color: Colors.black, size: 20),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

