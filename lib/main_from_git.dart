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

// ═══════════════════════════════════════
// CONSTANTS
// ═══════════════════════════════════════
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
  Widget _buildNavCard(String value, String emoji, String title, String subtitle, {int badge = 0}) {
    final active = _activeTab == value;
    return GestureDetector(
      onTap: () => setState(() => _activeTab = value),
      child: Stack(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 62,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: active
                  ? kGold.withValues(alpha: 0.14)
                  : Colors.white.withValues(alpha: 0.04),
              border: Border.all(
                color: active ? kGold : Colors.white.withValues(alpha: 0.07),
                width: active ? 1.5 : 1.0,
              ),
            ),
            child: Row(children: [
              Text(emoji, style: const TextStyle(fontSize: 20)),
              const SizedBox(width: 8),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(title, style: TextStyle(
                      color: active ? kGold : Colors.white,
                      fontSize: 13, fontWeight: FontWeight.w700,
                      height: 1.2)),
                  Text(subtitle, style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.3),
                      fontSize: 10, height: 1.2),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              )),
            ]),
          ),
          if (badge > 0) Positioned(
            top: 7, right: 7,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: kGold, borderRadius: BorderRadius.circular(10)),
              child: Text('$badge', style: const TextStyle(
                  color: Colors.black, fontSize: 9, fontWeight: FontWeight.w900)),
            ),
          ),
        ],
      ),
    );
  }

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

// Incremented whenever a pro is selected — HomeScreen listens to clear stale requests
final ValueNotifier<int> offerSelectedNotifier = ValueNotifier<int>(0);

// ── OffersReady overlay data ──────────────────────────────────────────────
// Instead of navigating (which triggers browser popstate bugs on Flutter Web),
// WaitingScreen sets this notifier and HomeScreen shows OffersReadyScreen as
// an in-place overlay. No browser history is touched → no auto-back bug.
class _OffersReadyData {
  final String requestId, userId, description, criteria, collection;
  final int offersCount;
  const _OffersReadyData({
    required this.requestId,
    required this.userId,
    required this.description,
    required this.criteria,
    required this.collection,
    required this.offersCount,
  });
}
final ValueNotifier<_OffersReadyData?> offersReadyNotifier =
    ValueNotifier<_OffersReadyData?>(null);

// Legacy flag — kept for safety but no longer used (replaced by offersReadyNotifier).
// ignore: prefer_final_fields
bool _offersReadyPushedThisSession = false;

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
            // Professionals now land on HomeScreen too (they get a Pro button in the header)
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
  final _afm = TextEditingController();
  final _referrerPhone = TextEditingController();
  String? _referrerId;       // Firestore doc id of referrer
  String? _referrerName;     // null=δεν ψάχτηκε, ''=δεν βρέθηκε, 'name'=βρέθηκε
  bool _referrerLoading = false;
  List<String> _selectedSpecialties = [];
  List<String> _selectedAreas = [];
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
    _afm.dispose();
    _referrerPhone.dispose();
    super.dispose();
  }

  Future<void> _autoLoginWithBiometrics() async {
    final email = await AuthService.getUser();
    final password = await AuthService.getPassword();
    if (email == null || password == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Κάνε πρώτα είσοδο με email για να ενεργοποιηθεί το δακτυλικό αποτύπωμα'),
          duration: Duration(seconds: 3),
        ));
      }
      return;
    }
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
        final errStr = e.toString();
        if (errStr.contains('email-already-in-use')) {
          // Show a helpful dialog with options
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF111111),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                  side: BorderSide(color: kGold.withValues(alpha: 0.3))),
              title: const Text('Email χρησιμοποιείται ήδη',
                  style: TextStyle(color: Colors.white, fontFamily: 'Raleway', fontSize: 17)),
              content: Text(
                'Το email ${_email.text.trim()} ανήκει ήδη σε λογαριασμό.\n\n'
                'Αν ξέχασες τον κωδικό σου ή δεν επαληθεύτηκε το email σου, χρησιμοποίησε μία από τις παρακάτω επιλογές.',
                style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5)),
              actions: [
                // Option 1: Switch to login
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                        backgroundColor: kGold, foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                    onPressed: () {
                      Navigator.pop(ctx);
                      setState(() => _isLogin = true);
                    },
                    child: const Text('Σύνδεση με αυτό το email', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
                // Option 2: Send password reset
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

  // ── Role-selection screen ──────────────────────────────────────────────────
  Widget _buildRoleSelectScreen() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0a0a0a), Color(0xFF111111), Color(0xFF0a0a0a)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              children: [
                const Spacer(flex: 2),
                // Logo
                ShaderMask(
                  shaderCallback: (b) => const LinearGradient(
                      colors: [kGoldLight, kGold]).createShader(b),
                  child: const Text('GorealAI',
                      style: TextStyle(
                          fontSize: 38,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: 1)),
                ),
                const SizedBox(height: 8),
                Text('Καλώς ήρθες!',
                    style: TextStyle(
                        fontSize: 16,
                        color: _g(0.45),
                        letterSpacing: 0.3)),
                const Spacer(flex: 2),
                // Question
                Text('Εγγράφεσαι ως:',
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: _g(0.9))),
                const SizedBox(height: 32),
                // User button
                GestureDetector(
                  onTap: () => setState(() {
                    _role = 'user';
                    _showRoleSelect = false;
                    _isLogin = false;
                  }),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 22),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                          colors: [kGoldLight, kGold]),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                            color: kGold.withValues(alpha: 0.35),
                            blurRadius: 24,
                            offset: const Offset(0, 8)),
                      ],
                    ),
                    child: const Column(children: [
                      Text('👤', style: TextStyle(fontSize: 36)),
                      SizedBox(height: 8),
                      Text('Χρήστης',
                          style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: Colors.black)),
                      SizedBox(height: 4),
                      Text('Ψάχνω επαγγελματία',
                          style: TextStyle(
                              fontSize: 13,
                              color: Colors.black54,
                              fontWeight: FontWeight.w500)),
                    ]),
                  ),
                ),
                const SizedBox(height: 16),
                // Professional button
                GestureDetector(
                  onTap: () => setState(() {
                    _role = 'professional';
                    _showRoleSelect = false;
                    _isLogin = false;
                  }),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 22),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161616),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: kGold.withValues(alpha: 0.45), width: 1.5),
                      boxShadow: [
                        BoxShadow(
                            color: kGold.withValues(alpha: 0.12),
                            blurRadius: 20,
                            offset: const Offset(0, 6)),
                      ],
                    ),
                    child: Column(children: [
                      const Text('🔧', style: TextStyle(fontSize: 36)),
                      const SizedBox(height: 8),
                      ShaderMask(
                        shaderCallback: (b) => const LinearGradient(
                            colors: [kGoldLight, kGold]).createShader(b),
                        child: const Text('Επαγγελματίας',
                            style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                color: Colors.white)),
                      ),
                      const SizedBox(height: 4),
                      Text('Προσφέρω υπηρεσίες',
                          style: TextStyle(
                              fontSize: 13,
                              color: _g(0.45),
                              fontWeight: FontWeight.w500)),
                    ]),
                  ),
                ),
                const Spacer(flex: 2),
                // Back to login
                TextButton(
                  onPressed: () => setState(() {
                    _showRoleSelect = false;
                    _isLogin = true;
                  }),
                  child: Text('← Πίσω στη Σύνδεση',
                      style: TextStyle(color: _g(0.45), fontSize: 14)),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Show role-selection screen when user taps Sign up
    if (_showRoleSelect) return _buildRoleSelectScreen();

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

                      // Role indicator (read-only — set from role-selection screen)
                      if (!_isLogin) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            color: kGold.withValues(alpha: 0.1),
                            border: Border.all(color: kGold.withValues(alpha: 0.3)),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(_role == 'professional' ? '🔧' : '👤',
                                  style: const TextStyle(fontSize: 18)),
                              const SizedBox(width: 8),
                              Text(
                                _role == 'professional' ? 'Εγγραφή ως Επαγγελματίας' : 'Εγγραφή ως Χρήστης',
                                style: const TextStyle(
                                    color: kGold,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14),
                              ),
                              const Spacer(),
                              GestureDetector(
                                onTap: () => setState(() {
                                  _isLogin = true;
                                  _showRoleSelect = false;
                                  _role = 'user';
                                }),
                                child: Text('Αλλαγή',
                                    style: TextStyle(
                                        color: _g(0.4),
                                        fontSize: 12,
                                        decoration: TextDecoration.underline)),
                              ),
                            ],
                          ),
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

                      // Specialty multi-picker (professionals only)
                      if (!_isLogin && _role == 'professional') ...[
                        _MultiPickerField(
                          hint: 'Ειδικότητες εργασίας',
                          subtitle: 'Επίλεξε όσες δουλειές κάνεις',
                          icon: Icons.work_outline,
                          selected: _selectedSpecialties,
                          onTap: () async {
                            final r = await showModalBottomSheet<List<String>>(
                                context: context,
                                backgroundColor: Colors.transparent,
                                isScrollControlled: true,
                                builder: (ctx) => _MultiSpecialtyPicker(
                                    initial: _selectedSpecialties));
                            if (r != null) setState(() => _selectedSpecialties = r);
                          },
                          onRemove: (v) => setState(
                              () => _selectedSpecialties.remove(v)),
                        ),
                        const SizedBox(height: 12),
                      ],

                      // Area multi-picker
                      if (!_isLogin) ...[
                        _MultiPickerField(
                          hint: _role == 'professional'
                              ? 'Περιοχές εργασίας'
                              : 'Περιοχή',
                          subtitle: _role == 'professional'
                              ? 'Επίλεξε όλες τις περιοχές που εξυπηρετείς'
                              : 'Επίλεξε την περιοχή σου',
                          icon: Icons.location_on_outlined,
                          selected: _selectedAreas,
                          onTap: () async {
                            final r = await showModalBottomSheet<List<String>>(
                                context: context,
                                backgroundColor: Colors.transparent,
                                isScrollControlled: true,
                                builder: (ctx) => _MultiAreaPicker(
                                    initial: _selectedAreas));
                            if (r != null) setState(() => _selectedAreas = r);
                          },
                          onRemove: (v) =>
                              setState(() => _selectedAreas.remove(v)),
                        ),
                        const SizedBox(height: 12),
                        // ΑΦΜ field — optional, για verified badge
                        TextField(
                          controller: _afm,
                          keyboardType: TextInputType.number,
                          maxLength: 9,
                          decoration: InputDecoration(
                            labelText: 'ΑΦΜ (προαιρετικό)',
                            hintText: '9 ψηφία',
                            counterText: '',
                            prefixIcon: Padding(
                              padding: const EdgeInsets.all(12),
                              child: ShaderMask(
                                shaderCallback: (b) => const LinearGradient(
                                    colors: [kGoldLight, kGold]).createShader(b),
                                child: const Text('✓',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 18,
                                        fontWeight: FontWeight.w800)),
                              ),
                            ),
                            suffixIcon: Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: kGold.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(color: kGold.withValues(alpha: 0.3)),
                                  ),
                                  child: const Text('✓ Verified badge',
                                      style: TextStyle(
                                          color: kGold,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600)),
                                ),
                              ]),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        // ── Referral phone field ──
                        TextField(
                          controller: _referrerPhone,
                          keyboardType: TextInputType.phone,
                          onChanged: (v) => _lookupReferrer(v),
                          decoration: InputDecoration(
                            labelText: 'Σύσταση από επαγγελματία',
                            hintText: 'Κινητό αυτού που σε σύστησε',
                            prefixIcon: const Icon(Icons.people_outline, color: kGold, size: 20),
                            suffixIcon: _referrerLoading
                                ? const Padding(
                                    padding: EdgeInsets.all(14),
                                    child: SizedBox(width: 16, height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2, color: kGold)))
                                : _referrerName == null ? null
                                : _referrerName!.isEmpty
                                    ? const Icon(Icons.cancel_outlined, color: Colors.redAccent, size: 20)
                                    : const Icon(Icons.check_circle_outline, color: Colors.green, size: 20),
                          ),
                        ),
                        // Feedback under referral field
                        if (_referrerName != null && !_referrerLoading) ...[
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              color: _referrerName!.isEmpty
                                  ? Colors.red.withValues(alpha: 0.08)
                                  : Colors.green.withValues(alpha: 0.08),
                              border: Border.all(
                                color: _referrerName!.isEmpty
                                    ? Colors.red.withValues(alpha: 0.3)
                                    : Colors.green.withValues(alpha: 0.3),
                              ),
                            ),
                            child: Row(children: [
                              Text(
                                _referrerName!.isEmpty ? '❌' : '✅',
                                style: const TextStyle(fontSize: 14),
                              ),
                              const SizedBox(width: 8),
                              Expanded(child: Text(
                                _referrerName!.isEmpty
                                    ? 'Δεν βρέθηκε επαγγελματίας με αυτό το κινητό'
                                    : 'Επιβεβαίωση: $_referrerName',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: _referrerName!.isEmpty
                                      ? Colors.redAccent
                                      : Colors.green,
                                ),
                              )),
                            ]),
                          ),
                        ],
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
                          if (_isLogin) {
                            // Show role-selection screen instead of going straight to form
                            _showRoleSelect = true;
                          } else {
                            _isLogin = true;
                            _showRoleSelect = false;
                            _role = 'user';
                          }
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
  bool _isPro = false;
  int _navIndex = 0;
  // Ενεργά αιτήματα (για το G button — μέχρι 2)
  List<Map<String, dynamic>> _activeRequests = []; // list of {id, status, desc, criteria, expiresAt}

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
    offerSelectedNotifier.removeListener(_onOfferSelected);
    _unreadMsgSub?.cancel();
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
      _isPro = (doc.data()?['role'] ?? '') == 'professional';
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
          isEvent: req['isEvent'] == true,
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
    // Shown as an in-place widget instead of a Navigator push so that the
    // browser history is never touched (eliminates the popstate auto-back bug).
    return ValueListenableBuilder<_OffersReadyData?>(
      valueListenable: offersReadyNotifier,
      builder: (context, offersData, _) {
        if (offersData != null) {
          return _OffersReadyOverlay(
            data: offersData,
            onDismiss: () {
              offersReadyNotifier.value = null;
              // Also clear active requests so the G-button updates
              offerSelectedNotifier.value++;
            },
          );
        }
        return _buildHomeScaffold(context);
      },
    );
  }

  Widget _buildHomeScaffold(BuildContext context) {
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
                    // HIDDEN — θα εμφανιστεί όταν έχουμε περισσότερους χρήστες
                    // StreamBuilder presence/online count goes here
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

          // BOTTOM NAV
          _BottomNav(
            navIndex: _navIndex,
            userName: _userName,
            hasActiveRequest: _activeRequests.isNotEmpty,
            activeRequestId: _activeRequests.isNotEmpty ? _activeRequests.first['id'] as String? : null,
            unreadMessages: _unreadMessages,
            onHome: () => setState(() => _navIndex = 0),
            onFab: _activeRequests.isEmpty ? _openProjectRequest : _openMyOffers,
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
          child: Text('Επαγγελματίες κοντά σου',
              style: TextStyle(color: _g(0.8), fontSize: 16, fontWeight: FontWeight.w700)),
        ),
        SizedBox(
          height: 120,
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('professionals')
                .where('is_active', isEqualTo: true)
                .limit(10)
                .snapshots(),
            builder: (_, snap) {
              if (!snap.hasData || snap.data!.docs.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Container(
                    decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        color: _g(0.04)),
                    child: Center(child: Text('Δεν βρέθηκαν επαγγελματίες',
                        style: TextStyle(color: _g(0.3), fontSize: 12))),
                  ),
                );
              }
              return ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: snap.data!.docs.map((doc) {
                  final d = doc.data() as Map<String, dynamic>;
                  final name = d['name'] as String? ?? 'Επαγγελματίας';
                  final specialty = d['specialty'] as String? ?? '';
                  final area = d['area'] as String? ?? '';
                  return GestureDetector(
                    onTap: () => _openRequestWithProfession(specialty),
                    child: Container(
                      width: 88,
                      margin: const EdgeInsets.only(right: 12),
                      decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          color: _g(0.04),
                          border: Border.all(color: _g(0.07))),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Container(
                          width: 46, height: 46,
                          decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: kGold.withValues(alpha: 0.12),
                              border: Border.all(color: kGold.withValues(alpha: 0.35))),
                          child: Center(child: Text(
                              name.isNotEmpty ? name[0].toUpperCase() : '?',
                              style: const TextStyle(color: kGold,
                                  fontWeight: FontWeight.bold, fontSize: 18))),
                        ),
                        const SizedBox(height: 6),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Text(name.split(' ').first,
                              textAlign: TextAlign.center,
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 10,
                                  color: Colors.white, fontWeight: FontWeight.w600)),
                        ),
                        if (specialty.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Text(specialty,
                                textAlign: TextAlign.center,
                                maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 8, color: _g(0.4))),
                          ),
                        if (area.isNotEmpty)
                          Text('📍 $area',
                              textAlign: TextAlign.center,
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 7, color: _g(0.3))),
                      ]),
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ),

        const SizedBox(height: 28),

        // ΕΠΑΓΓΕΛΜΑΤΙΕΣ ΚΟΝΤΑ ΣΟΥ
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Text('Επαγγελματίες κοντά σου',
              style: TextStyle(
                  color: _g(0.8), fontSize: 16, fontWeight: FontWeight.w700)),
        ),
        SizedBox(
          height: 120,
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('professionals')
                .where('is_active', isEqualTo: true)
                .limit(10)
                .snapshots(),
            builder: (_, snap) {
              if (!snap.hasData || snap.data!.docs.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Container(
                      decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          color: _g(0.04)),
                      child: Center(
                          child: Text('Δεν βρέθηκαν επαγγελματίες',
                              style: TextStyle(
                                  color: _g(0.3), fontSize: 12)))),
                );
              }
              return ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: snap.data!.docs.map((doc) {
                  final d = doc.data() as Map<String, dynamic>;
                  final name = d['name'] as String? ?? 'Επαγγελματίας';
                  final specialty = d['specialty'] as String? ?? '';
                  final area = d['area'] as String? ?? '';
                  return GestureDetector(
                    onTap: () => _openRequestWithProfession(specialty),
                    child: Container(
                      width: 88,
                      margin: const EdgeInsets.only(right: 12),
                      decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          color: _g(0.04),
                          border: Border.all(color: _g(0.07))),
                      child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: kGold.withValues(alpha: 0.12),
                                  border: Border.all(
                                      color: kGold.withValues(alpha: 0.35))),
                              child: Center(
                                  child: Text(
                                      name.isNotEmpty
                                          ? name[0].toUpperCase()
                                          : '?',
                                      style: const TextStyle(
                                          color: kGold,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 18))),
                            ),
                            const SizedBox(height: 6),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 6),
                              child: Text(name.split(' ').first,
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 10,
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600)),
                            ),
                            if (specialty.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 4),
                                child: Text(specialty,
                                    textAlign: TextAlign.center,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 8, color: _g(0.4))),
                              ),
                            if (area.isNotEmpty)
                              Text('📍 $area',
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 7, color: _g(0.3))),
                          ]),
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ),

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

        // ΕΠΑΓΓΕΛΜΑΤΙΕΣ ΚΟΝΤΑ ΣΟΥ
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Text('Επαγγελματίες κοντά σου',
              style: TextStyle(
                  color: _g(0.8),
                  fontSize: 16,
                  fontWeight: FontWeight.w700)),
        ),
        const _NearbyProsSection(),

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
    _audioTimer?.cancel();
    _audioRec.dispose();
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

// ── Nearby Professionals Section ──
class _NearbyProsSection extends StatefulWidget {
  const _NearbyProsSection();
  @override
  State<_NearbyProsSection> createState() => _NearbyProsSectionState();
}

class _NearbyProsSectionState extends State<_NearbyProsSection> {
  final PageController _pageCtrl = PageController(viewportFraction: 0.75);
  int _current = 0;
  Timer? _autoTimer;

  @override
  void initState() {
    super.initState();
    _autoTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      _pageCtrl.nextPage(
          duration: const Duration(milliseconds: 600), curve: Curves.easeInOut);
    });
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 210,
      child: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .where('role', isEqualTo: 'professional')
            .limit(20)
            .snapshots(),
        builder: (_, snap) {
          final docs = snap.hasData ? snap.data!.docs : <QueryDocumentSnapshot>[];
          if (docs.isEmpty) {
            return Center(
              child: Text('Δεν βρέθηκαν επαγγελματίες',
                  style: TextStyle(color: _g(0.3), fontSize: 13)),
            );
          }
          return PageView.builder(
            controller: _pageCtrl,
            itemCount: 99999,
            onPageChanged: (i) => setState(() => _current = i),
            itemBuilder: (_, i) {
              final doc = docs[i % docs.length];
              final d = doc.data() as Map<String, dynamic>;
              final name = d['name'] as String? ?? 'Επαγγελματίας';
              final specialty = d['specialty'] as String? ??
                  d['profession'] as String? ?? '';
              final rating = (d['rating'] as num?)?.toDouble() ?? 0.0;
              final photoUrl = d['photoUrl'] as String?;
              final isNew = (d['rating'] as num?)?.toDouble() == null ||
                  rating < 1.0;

              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      kGold.withValues(alpha: 0.12),
                      kBg.withValues(alpha: 0.95),
                    ],
                  ),
                  border: Border.all(color: kGold.withValues(alpha: 0.25)),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.4),
                        blurRadius: 20,
                        offset: const Offset(0, 8)),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: Stack(children: [
                    // Background photo
                    if (photoUrl != null && photoUrl.isNotEmpty)
                      Positioned.fill(
                        child: Image.network(photoUrl, fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const SizedBox()),
                      ),
                    // Gradient overlay
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.75),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // Content
                    Positioned(
                      left: 14, right: 14, bottom: 14,
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                        if (specialty.isNotEmpty)
                          Container(
                            margin: const EdgeInsets.only(bottom: 6),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(6),
                              color: kGold.withValues(alpha: 0.85),
                            ),
                            child: Text(specialty,
                                style: const TextStyle(
                                    color: Colors.black,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700)),
                          ),
                        Text(name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Row(children: [
                          if (isNew)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(5),
                                color: kGreen.withValues(alpha: 0.2),
                                border: Border.all(
                                    color: kGreen.withValues(alpha: 0.5)),
                              ),
                              child: const Text('Νέος',
                                  style: TextStyle(
                                      color: kGreen,
                                      fontSize: 9,
                                      fontWeight: FontWeight.w700)),
                            )
                          else
                            Row(children: [
                              const Icon(Icons.star_rounded,
                                  color: kGold, size: 13),
                              const SizedBox(width: 2),
                              Text(rating.toStringAsFixed(1),
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600)),
                            ]),
                          const SizedBox(width: 8),
                          Text('+${(docs.length * 10).clamp(10, 99)}λ',
                              style: TextStyle(
                                  color: _g(0.55), fontSize: 10)),
                        ]),
                      ]),
                    ),
                    // Avatar fallback (top center when no photo)
                    if (photoUrl == null || photoUrl.isEmpty)
                      Positioned(
                        top: 20,
                        left: 0, right: 0,
                        child: Center(
                          child: Container(
                            width: 80, height: 80,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: kGold.withValues(alpha: 0.15),
                              border: Border.all(color: kGold, width: 2),
                            ),
                            child: Center(
                              child: Text(
                                name.isNotEmpty ? name[0].toUpperCase() : 'P',
                                style: const TextStyle(
                                    color: kGold,
                                    fontSize: 32,
                                    fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ]),
                ),
              );
            },
          );
        },
      ),
    );
  }
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
    if (secs >= 3600) {
      final h = (secs ~/ 3600).toString().padLeft(2, '0');
      final m = ((secs % 3600) ~/ 60).toString().padLeft(2, '0');
      final s = (secs % 60).toString().padLeft(2, '0');
      return '$h:$m:$s';
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
                              criteria: d['criteria'] ?? 'cheap',
                              profession: d['profession'] ?? ''),
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
            color: const Color(0xFF080808),
            boxShadow: [BoxShadow(
                color: Colors.black.withValues(alpha: 0.5), blurRadius: 20)],
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
                _HNavItem(icon: Icons.chat_bubble_rounded, label: 'Μηνύματα',
                    active: navIndex == 3, onTap: onMessages),
                // Avatar
                GestureDetector(
                  onTap: onProfile,
                  child: Container(
                    width: 38, height: 38,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: navIndex == 4
                          ? kGold.withValues(alpha: 0.2)
                          : kGold.withValues(alpha: 0.08),
                      border: Border.all(color: kGold,
                          width: navIndex == 4 ? 1.5 : 0.5),
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

// ─── Glance metric widget ───────────────
class _GlanceMetric extends StatelessWidget {
  final String value, label;
  final Color color;
  final bool last;
  final VoidCallback? onTap;
  const _GlanceMetric({required this.value, required this.label, required this.color, this.last = false, this.onTap});
  @override
  Widget build(BuildContext context) => Expanded(child: GestureDetector(
    onTap: onTap,
    child: Container(
      decoration: last ? null : BoxDecoration(
          border: Border(right: BorderSide(color: Colors.white.withValues(alpha: 0.06)))),
      child: Column(children: [
        Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: color, height: 1)),
        const SizedBox(height: 3),
        Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: TextStyle(fontSize: 9, color: Colors.white.withValues(alpha: 0.4), fontWeight: FontWeight.w600)),
          if (onTap != null) ...[
            const SizedBox(width: 2),
            Icon(Icons.touch_app, size: 8, color: Colors.white.withValues(alpha: 0.25)),
          ],
        ]),
      ]),
    ),
  ));
}

// ─── Mini CV section label ───────────────
class _MiniCvSection extends StatelessWidget {
  final String label;
  const _MiniCvSection({required this.label});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Text(label, style: TextStyle(
        fontSize: 10, fontWeight: FontWeight.w800,
        color: Colors.white.withValues(alpha: 0.4), letterSpacing: 1.2)),
  );
}

// ─── Specialty option row ────────────────
class _SpecialtyOption extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _SpecialtyOption({required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
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
const Set<String> _kEventSpecialties = {
  'εκδηλώσεις γάμου', 'εκδηλώσεις βάφτισης', 'διοργάνωση πάρτυ',
  'φωτογράφος γάμου', 'dj / μουσική εκδηλώσεων', 'catering',
  'ανθοδέτης / στολισμός', 'αίθουσα εκδηλώσεων',
};

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
  String _activeTab = '';
  bool _showGrid = true;
  final Set<String> _submittedIds = {};

  @override
  void initState() {
    super.initState();
    _proId = FirebaseAuth.instance.currentUser?.uid;
    _loadProfile().then((_) => _listenEventRequests());
  }

  bool _proMatchesEvent(Map<String, dynamic> eventData) {
    // ── 1. Specialty check ──
    final categoryPros = List<String>.from(eventData['categoryPros'] ?? []);
    final mainSpec = (_proSpecialty ?? '').toLowerCase();
    final allSpecs = [mainSpec, ..._specialties.map((s) => s.toLowerCase())];
    bool specMatches;
    // Old docs without categoryPros → only event-category professionals
    if (categoryPros.isEmpty) {
      specMatches = allSpecs.any(
          (sp) => sp.isNotEmpty && _kEventSpecialties.contains(sp));
    } else {
      final cpLowList = categoryPros.map((cp) => cp.toLowerCase()).toList();
      specMatches = allSpecs.any((sp) {
        if (sp.isEmpty) return false;
        return cpLowList.any((cpLow) => sp.contains(cpLow));
      });
    }
    if (!specMatches) return false;

    // ── 2. Location check ──
    final eventLocation = (eventData['location'] as String? ?? '').toLowerCase().trim();
    if (eventLocation.isNotEmpty) {
      if (_areas.isNotEmpty) {
        final areaMatches = _areas.any((a) =>
            a.toLowerCase().contains(eventLocation) ||
            eventLocation.contains(a.toLowerCase()));
        if (!areaMatches) return false;
      }
    }

    return true;
  }

  bool _proMatchesRequest(Map<String, dynamic> reqData) {
    // ── 1. Specialty check ──
    final profession = (reqData['profession'] as String? ?? '').toLowerCase().trim();
    if (profession.isNotEmpty) {
      final mainSpec = (_proSpecialty ?? '').toLowerCase();
      final allSpecs = [mainSpec, ..._specialties.map((s) => s.toLowerCase())];
      final specMatches = allSpecs.any((sp) =>
          sp.isNotEmpty && (sp.contains(profession) || profession.contains(sp)));
      if (!specMatches) return false;
    }

    // ── 2. Location check ──
    final reqLocation = (reqData['location'] as String? ?? '').toLowerCase().trim();
    if (reqLocation.isNotEmpty && reqLocation != 'κοντά μου') {
      if (_areas.isNotEmpty) {
        final areaMatches = _areas.any((a) =>
            a.toLowerCase().contains(reqLocation) ||
            reqLocation.contains(a.toLowerCase()));
        if (!areaMatches) return false;
      }
    }

    // ── 3. Immediate check ──
    final wantsImmediate = reqData['immediate'] as bool? ?? false;
    if (wantsImmediate && !_available) return false;

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

  void _listenEventRequests() {
    _eventReqSub = FirebaseFirestore.instance
        .collection('event_requests')
        .where('status', isEqualTo: 'active')
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final now = DateTime.now();
      final active = snap.docs.where((doc) {
        final data = doc.data();
        final exp = data['expiresAt'] as Timestamp?;
        if (exp == null || !exp.toDate().isAfter(now)) return false;
        return _proMatchesEvent(data);
      }).toList()
        ..sort((a, b) {
          final aTs = a.data()['createdAt'] as Timestamp?;
          final bTs = b.data()['createdAt'] as Timestamp?;
          if (aTs == null) return 1;
          if (bTs == null) return -1;
          return bTs.compareTo(aTs);
        });
      setState(() => _eventReqDocs = active);
    }, onError: (e) {
      // log error silently
    });
  }

  @override
  void dispose() {
    _eventReqSub?.cancel();
    super.dispose();
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
    });
  }

  // ── Bookings bottom sheet ──────────────────────────────────────────────────
  void _showBookingsSheet(BuildContext context, List<QueryDocumentSnapshot> allDocs) {
    final bookings = allDocs
        .where((d) {
          final s = (d.data() as Map)['status'] as String? ?? '';
          return s == 'pending' || s == 'accepted';
        })
        .toList()
      ..sort((a, b) {
        final aTs = (a.data() as Map)['createdAt'] as Timestamp?;
        final bTs = (b.data() as Map)['createdAt'] as Timestamp?;
        if (aTs == null) return 1;
        if (bTs == null) return -1;
        return bTs.compareTo(aTs);
      });

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        height: MediaQuery.of(context).size.height * 0.65,
        decoration: BoxDecoration(
          color: const Color(0xFF0D0A04),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: kGold.withValues(alpha: 0.25)),
        ),
        child: Column(children: [
          // Handle bar
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40, height: 4,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(2),
                color: Colors.white.withValues(alpha: 0.2)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
            child: Row(children: [
              const Text('📅', style: TextStyle(fontSize: 20)),
              const SizedBox(width: 8),
              Text('Κρατήσεις (${bookings.length})',
                  style: const TextStyle(color: Colors.white, fontSize: 16,
                      fontWeight: FontWeight.w800, fontFamily: 'Raleway')),
            ]),
          ),
          if (bookings.isEmpty)
            Expanded(child: Center(child: Text('Δεν υπάρχουν κρατήσεις',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.4)))))
          else
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                itemCount: bookings.length,
                itemBuilder: (_, i) {
                  final d = bookings[i].data() as Map<String, dynamic>;
                  final status = d['status'] as String? ?? 'pending';
                  final userName = d['userName'] as String? ?? 'Χρήστης';
                  final userPhone = d['userPhone'] as String? ?? '';
                  final createdAt = d['createdAt'] as Timestamp?;
                  final date = createdAt?.toDate();
                  final dateStr = date != null
                      ? '${date.day}/${date.month}/${date.year}  ${date.hour.toString().padLeft(2,'0')}:${date.minute.toString().padLeft(2,'0')}'
                      : '—';
                  final isAccepted = status == 'accepted';

                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      color: isAccepted
                          ? kGreen.withValues(alpha: 0.07)
                          : kGold.withValues(alpha: 0.05),
                      border: Border.all(
                        color: isAccepted
                            ? kGreen.withValues(alpha: 0.35)
                            : kGold.withValues(alpha: 0.2),
                      ),
                    ),
                    child: Row(children: [
                      Container(
                        width: 40, height: 40,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isAccepted
                              ? kGreen.withValues(alpha: 0.15)
                              : kGold.withValues(alpha: 0.1),
                        ),
                        child: Center(child: Text(isAccepted ? '✅' : '⏳',
                            style: const TextStyle(fontSize: 18))),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(userName, style: const TextStyle(color: Colors.white,
                            fontWeight: FontWeight.w700, fontSize: 14)),
                        const SizedBox(height: 3),
                        Text(dateStr, style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.4), fontSize: 11)),
                        if (userPhone.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          GestureDetector(
                            onTap: () => launchUrl(Uri.parse('tel:$userPhone')),
                            child: Text(userPhone, style: const TextStyle(
                                color: kGold, fontSize: 12, fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ])),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: isAccepted
                              ? kGreen.withValues(alpha: 0.15)
                              : Colors.orange.withValues(alpha: 0.15),
                        ),
                        child: Text(isAccepted ? 'Επιβεβαιωμένη' : 'Εκκρεμής',
                            style: TextStyle(
                              color: isAccepted ? kGreen : Colors.orange,
                              fontSize: 10, fontWeight: FontWeight.w700)),
                      ),
                    ]),
                  );
                },
              ),
            ),
        ]),
      ),
    );
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

  // helper
  Color _g(double a) => Colors.white.withValues(alpha: a);

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

  Widget _buildNavCard(String value, String emoji, String title, String subtitle,
      {int badge = 0, Color iconColor = kGold}) {
    return GestureDetector(
      onTap: () => setState(() {
        _activeTab = value;
        _showGrid = false;
      }),
      child: Stack(children: [
        Container(
          height: 72,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: const Color(0xFF141414),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06), width: 1.0),
            boxShadow: [
              BoxShadow(
                color: iconColor.withValues(alpha: 0.10),
                blurRadius: 14, offset: const Offset(0, 4)),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 8, offset: const Offset(0, 3)),
            ],
          ),
          child: Row(children: [
            Container(
              width: 42, height: 42,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: iconColor.withValues(alpha: 0.18),
              ),
              child: Center(child: Text(emoji, style: const TextStyle(fontSize: 21))),
            ),
            const SizedBox(width: 10),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(title, style: const TextStyle(
                    color: Colors.white, fontSize: 13,
                    fontWeight: FontWeight.w700, height: 1.2)),
                Text(subtitle, style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35),
                    fontSize: 10, height: 1.3),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            )),
            Icon(Icons.arrow_forward_ios,
                size: 11, color: Colors.white.withValues(alpha: 0.15)),
          ]),
        ),
        if (badge > 0) Positioned(
          top: 8, right: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
                color: iconColor, borderRadius: BorderRadius.circular(10)),
            child: Text('$badge', style: const TextStyle(
                color: Colors.black, fontSize: 9, fontWeight: FontWeight.w900)),
          ),
        ),
      ]),
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

              // Stats row — scrollable so chips never overflow
              StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('requests')
                    .where('status', isEqualTo: 'active')
                    .snapshots(),
                builder: (context, snap) {
                  final activeCount = snap.hasData ? snap.data!.docs.length : 0;
                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [
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
                      const SizedBox(width: 8),
                      StreamBuilder<DocumentSnapshot>(
                        stream: (_proId == null || _proId!.isEmpty)
                            ? const Stream.empty()
                            : FirebaseFirestore.instance
                                .collection('users').doc(_proId).snapshots(),
                        builder: (ctx4, snap4) {
                          if (!snap4.hasData) return const SizedBox.shrink();
                          final data = snap4.data!.data() as Map<String, dynamic>? ?? {};
                          final avg = ((data['averageRating'] ?? 0.0) as num).toDouble();
                          final cnt = ((data['reviewCount'] ?? 0) as num).toInt();
                          if (cnt == 0) return _ProStatChip(icon: '⭐', label: '—', sub: 'Αξιολογήσεις');
                          return _ProStatChip(icon: '⭐', label: avg.toStringAsFixed(1), sub: '$cnt κριτικές');
                        },
                      ),
                    ]),
                  );
                },
              ),
            ]),
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
                final docs = snap.data!.docs.toList()
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
                            if (d['status'] == 'pending') ...[
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
                                        style: TextStyle(color: Colors.black,
                                            fontWeight: FontWeight.bold, fontSize: 13)),
                                  ]),
                                ),
                              ),
                            ],
                            if (d['status'] != 'pending') ...[
                              const SizedBox(height: 10),
                              GestureDetector(
                                onTap: () async {
                                  await FirebaseFirestore.instance
                                      .collection('bookings')
                                      .doc(bookingId)
                                      .update({'proHidden': true});
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
              }),
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
                  borderRadius: BorderRadius.circular(16),
                  color: Colors.red.withValues(alpha: 0.15),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                ),
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 20),
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
                          style: const TextStyle(color: kGold, fontSize: 18, fontWeight: FontWeight.w800)))),
                    const SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(userName, style: TextStyle(color: _gw, fontSize: 14,
                          fontWeight: unread > 0 ? FontWeight.w800 : FontWeight.w600)),
                      const SizedBox(height: 3),
                      Text(lastMsg.isNotEmpty ? lastMsg : 'Νέο μήνυμα...',
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: _g(unread > 0 ? 0.65 : 0.4), fontSize: 12)),
                    ])),
                    Column(mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text(timeStr, style: TextStyle(color: _g(0.3), fontSize: 10)),
                      if (unread > 0) ...[
                        const SizedBox(height: 4),
                        Container(width: 20, height: 20,
                          decoration: const BoxDecoration(shape: BoxShape.circle, color: kGold),
                          child: Center(child: Text('$unread',
                              style: const TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.w800)))),
                      ],
                    ]),
                  ]),
                ),
              ),
            );
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
    final igCtrl = TextEditingController(text: _instagram);
    final ttCtrl = TextEditingController(text: _tiktok);
    bool saving = false;

    Future<void> save(StateSetter setS) async {
      setS(() => saving = true);
      final ig = igCtrl.text.trim().replaceAll('@', '');
      final tt = ttCtrl.text.trim().replaceAll('@', '');
      try {
        final proSnap = await FirebaseFirestore.instance
            .collection('professionals')
            .where('userId', isEqualTo: _proId)
            .limit(1).get();
        for (final d in proSnap.docs) {
          await d.reference.update({'instagram': ig, 'tiktok': tt});
        }
        if (mounted) setState(() { _instagram = ig; _tiktok = tt; });
      } catch (_) {}
      setS(() => saving = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Αποθηκεύτηκε!')));
    }

    return StatefulBuilder(builder: (ctx, setS) =>
      SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('📱 Social Media',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text('Σύνδεσε τα social media σου. Οι χρήστες θα μπορούν να τα επισκεφτούν από την κάρτα σου.',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 12)),
          const SizedBox(height: 28),

          // Instagram
          Row(children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                gradient: const LinearGradient(
                  colors: [Color(0xFFF58529), Color(0xFFDD2A7B), Color(0xFF8134AF)],
                  begin: Alignment.topLeft, end: Alignment.bottomRight),
              ),
              child: const Center(child: Text('📸', style: TextStyle(fontSize: 18))),
            ),
            const SizedBox(width: 12),
            Expanded(child: TextField(
              controller: igCtrl,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'username (χωρίς @)',
                hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.25), fontSize: 13),
                labelText: 'Instagram',
                labelStyle: const TextStyle(color: Color(0xFFDD2A7B), fontSize: 12),
                prefixText: '@',
                prefixStyle: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 14),
                filled: true, fillColor: Colors.white.withValues(alpha: 0.04),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1))),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFFDD2A7B))),
              ),
            )),
          ]),

          const SizedBox(height: 16),

          // TikTok
          Row(children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: Colors.black,
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
              child: const Center(child: Text('🎵', style: TextStyle(fontSize: 18))),
            ),
            const SizedBox(width: 12),
            Expanded(child: TextField(
              controller: ttCtrl,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'username (χωρίς @)',
                hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.25), fontSize: 13),
                labelText: 'TikTok',
                labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12),
                prefixText: '@',
                prefixStyle: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 14),
                filled: true, fillColor: Colors.white.withValues(alpha: 0.04),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1))),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Colors.white)),
              ),
            )),
          ]),

          const SizedBox(height: 28),

          GestureDetector(
            onTap: saving ? null : () => save(setS),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: const LinearGradient(colors: [kGoldLight, kGold]),
              ),
              child: Center(child: Text(
                saving ? 'Αποθήκευση...' : '💾 Αποθήκευση',
                style: const TextStyle(color: Colors.black, fontSize: 14, fontWeight: FontWeight.w800),
              )),
            ),
          ),

          if (_instagram.isNotEmpty || _tiktok.isNotEmpty) ...[
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: Colors.white.withValues(alpha: 0.04),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('✅ Συνδεδεμένα', style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6), fontSize: 11,
                    fontWeight: FontWeight.w600, letterSpacing: .5)),
                const SizedBox(height: 8),
                if (_instagram.isNotEmpty) Text('📸 instagram.com/$_instagram',
                    style: const TextStyle(color: Color(0xFFDD2A7B), fontSize: 12)),
                if (_tiktok.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text('🎵 tiktok.com/@$_tiktok',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12)),
                ],
              ]),
            ),
          ],
        ]),
      ),
    );
  }

  // ── Mini CV editor ──
  Widget _buildMiniCvEditor() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // ── Header ──────────────────────────────────────────
        Row(children: [
          const Text('👤', style: TextStyle(fontSize: 20)),
          const SizedBox(width: 8),
          const Expanded(child: Text('Mini CV',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800))),
          if (!_bioEditMode && _bio.isNotEmpty)
            GestureDetector(
              onTap: () => setState(() => _bioEditMode = true),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: kGold.withValues(alpha: 0.35)),
                  color: kGold.withValues(alpha: 0.08),
                ),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.edit_outlined, color: kGold, size: 13),
                  SizedBox(width: 5),
                  Text('Επεξεργασία', style: TextStyle(color: kGold, fontSize: 12, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          if (_bioEditMode && _bio.isNotEmpty) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => setState(() { _bioCtrl.text = _bio; _bioEditMode = false; }),
              child: Icon(Icons.close, color: _g(0.4), size: 20),
            ),
          ],
        ]),
        const SizedBox(height: 4),
        Text('Αυτό βλέπουν οι πελάτες στο προφίλ σου.',
            style: TextStyle(color: _g(0.35), fontSize: 12)),

        const SizedBox(height: 18),

        // ── Βιογραφικό ────────────────────────────────────
        _MiniCvSection(label: 'ΒΙΟΓΡΑΦΙΚΟ'),
        const SizedBox(height: 8),
        if (!_bioEditMode && _bio.isNotEmpty)
          GestureDetector(
            onTap: () => setState(() => _bioEditMode = true),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: _g(0.04),
                border: Border.all(color: kGold.withValues(alpha: 0.15)),
              ),
              child: Text(_bio, style: TextStyle(color: _g(0.8), fontSize: 13, height: 1.65)),
            ),
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

        // ── Κύριο Επάγγελμα ────────────────────────────────
        Row(children: [
          const Expanded(child: _MiniCvSection(label: 'ΚΥΡΙΟ ΕΠΑΓΓΕΛΜΑ')),
          GestureDetector(
            onTap: () async {
              final selected = await showModalBottomSheet<String>(
                context: context,
                backgroundColor: Colors.transparent,
                isScrollControlled: true,
                builder: (ctx) => DraggableScrollableSheet(
                  initialChildSize: 0.75,
                  maxChildSize: 0.92,
                  minChildSize: 0.4,
                  builder: (_, sc) => Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF121212),
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                      border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
                    ),
                    child: Column(children: [
                      const SizedBox(height: 8),
                      Container(width: 36, height: 4,
                          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(2))),
                      const SizedBox(height: 16),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 20),
                        child: Text('Επίλεξε κύριο επάγγελμα',
                            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: ListView(controller: sc, padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                          children: _specialtyCategories.map((cat) {
                            final category = cat['category'] as String;
                            final items = cat['items'] as List<String>;
                            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
                                child: Text(category.toUpperCase(),
                                    style: TextStyle(color: _g(0.35), fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
                              ),
                              Wrap(spacing: 8, runSpacing: 8, children: items.map((item) {
                                final isSelected = item == _proSpecialty;
                                return GestureDetector(
                                  onTap: () => Navigator.pop(ctx, item),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(20),
                                      color: isSelected ? kGold.withValues(alpha: 0.2) : _g(0.05),
                                      border: Border.all(color: isSelected ? kGold : _g(0.12)),
                                    ),
                                    child: Text(item, style: TextStyle(
                                        color: isSelected ? kGold : _g(0.75),
                                        fontSize: 13, fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500)),
                                  ),
                                );
                              }).toList()),
                            ]);
                          }).toList(),
                        ),
                      ),
                    ]),
                  ),
                ),
              );
              if (selected != null && selected != _proSpecialty) {
                await _saveMainSpecialty(selected);
              }
            },
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
                const Text('Αλλαγή', style: TextStyle(color: kGold, fontSize: 11, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        if (_savingMainSpecialty)
          const Padding(padding: EdgeInsets.all(8), child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: kGold, strokeWidth: 2))))
        else
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: kGold.withValues(alpha: 0.06),
              border: Border.all(color: kGold.withValues(alpha: 0.2)),
            ),
            child: Text(
              _proSpecialty?.isNotEmpty == true ? _proSpecialty! : 'Δεν έχει οριστεί επάγγελμα',
              style: TextStyle(color: _proSpecialty?.isNotEmpty == true ? Colors.white : _g(0.35),
                  fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),

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

        // ── Google Reviews ────────────────────────────────
        Row(children: [
          const Expanded(child: _MiniCvSection(label: 'GOOGLE REVIEWS')),
          GestureDetector(
            onTap: _showGooglePlacesSheet,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: kGold.withValues(alpha: 0.08),
                border: Border.all(color: kGold.withValues(alpha: 0.2)),
              ),
              child: Text(_googlePlaceId == null ? '+ Σύνδεση' : 'Αλλαγή',
                  style: const TextStyle(color: kGold, fontSize: 11, fontWeight: FontWeight.w700)),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        if (_savingGooglePlace)
          const Padding(padding: EdgeInsets.all(8),
              child: Center(child: SizedBox(width: 18, height: 18,
                  child: CircularProgressIndicator(color: kGold, strokeWidth: 2))))
        else if (_googlePlaceId == null)
          GestureDetector(
            onTap: _showGooglePlacesSheet,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF4285F4).withValues(alpha: 0.3)),
                color: const Color(0xFF4285F4).withValues(alpha: 0.04),
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Text('G', style: TextStyle(color: Color(0xFF4285F4),
                    fontSize: 16, fontWeight: FontWeight.w900)),
                const SizedBox(width: 8),
                Text('Σύνδεσε τα Google Reviews σου',
                    style: TextStyle(color: const Color(0xFF4285F4).withValues(alpha: 0.8), fontSize: 13)),
              ]),
            ),
          )
        else
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: const Color(0xFF4285F4).withValues(alpha: 0.05),
              border: Border.all(color: const Color(0xFF4285F4).withValues(alpha: 0.2)),
            ),
            child: Row(children: [
              Container(width: 38, height: 38,
                  decoration: BoxDecoration(shape: BoxShape.circle,
                      color: const Color(0xFF4285F4).withValues(alpha: 0.12)),
                  child: const Center(child: Text('G', style: TextStyle(color: Color(0xFF4285F4),
                      fontSize: 18, fontWeight: FontWeight.w900)))),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Icon(Icons.star, color: Color(0xFFFFC107), size: 14),
                  const SizedBox(width: 4),
                  Text(
                    _googleRating != null ? _googleRating!.toStringAsFixed(1) : '—',
                    style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(width: 6),
                  Text('($_googleRatingCount κριτικές Google)',
                      style: TextStyle(color: _g(0.4), fontSize: 11)),
                ]),
                const SizedBox(height: 2),
                const Text('Google Reviews', style: TextStyle(color: Color(0xFF4285F4), fontSize: 11)),
              ])),
              Row(mainAxisSize: MainAxisSize.min, children: [
                GestureDetector(
                  onTap: _showGooglePlacesSheet,
                  child: Icon(Icons.edit_outlined, color: _g(0.3), size: 18),
                ),
                const SizedBox(width: 10),
                GestureDetector(
                  onTap: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        backgroundColor: const Color(0xFF1A1A1A),
                        title: const Text('Διαγραφή Google Reviews',
                            style: TextStyle(color: Colors.white, fontSize: 16)),
                        content: Text('Θέλεις να αφαιρέσεις τη σύνδεση με το Google Business;',
                            style: TextStyle(color: _g(0.6), fontSize: 13)),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: Text('Άκυρο', style: TextStyle(color: _g(0.5))),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Διαγραφή', style: TextStyle(color: Colors.red)),
                          ),
                        ],
                      ),
                    );
                    if (confirm != true) return;
                    setState(() => _savingGooglePlace = true);
                    try {
                      final uid = FirebaseAuth.instance.currentUser?.uid;
                      if (uid != null) {
                        final proSnap = await FirebaseFirestore.instance
                            .collection('professionals')
                            .where('userId', isEqualTo: uid)
                            .limit(1).get();
                        for (final d in proSnap.docs) {
                          await d.reference.update({
                            'googlePlaceId': FieldValue.delete(),
                            'googleRating': FieldValue.delete(),
                            'googleRatingCount': FieldValue.delete(),
                            'googleMapsUrl': FieldValue.delete(),
                          });
                        }
                      }
                      if (mounted) setState(() {
                        _googlePlaceId = null;
                        _googleRating = null;
                        _googleRatingCount = 0;
                        _googleMapsUrl = '';
                        _savingGooglePlace = false;
                      });
                    } catch (e) {
                      if (mounted) setState(() => _savingGooglePlace = false);
                    }
                  },
                  child: const Icon(Icons.delete_outline, color: Colors.red, size: 18),
                ),
              ]),
            ]),
          ),

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
    bool priceOnSite = false;
    String? offerAudioUrl;
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
              // Μήνυμα κειμένου
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
              const SizedBox(height: 8),
              // Ηχητικό μήνυμα
              _VoiceMessageWidget(
                storagePath: 'offers/$requestId/${_proId ?? 'pro'}_${DateTime.now().millisecondsSinceEpoch}',
                onChanged: (url) => offerAudioUrl = url,
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

// ── Event Offer Dialog ──
void _showEventOfferDialog(String eventId, Map<String, dynamic> eventData) {
  final priceCtrl = TextEditingController();
  final msgCtrl = TextEditingController();
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
            Text('${eventData['categoryEmoji'] ?? '🎉'} Προσφορά για ${eventData['categoryTitle'] ?? 'Event'}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontFamily: 'Raleway', fontSize: 16,
                    fontWeight: FontWeight.w800, color: Colors.white)),
            const SizedBox(height: 4),
            Text('📍 ${eventData['location'] ?? ''} · 👥 ${eventData['guests'] ?? ''} άτομα',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: _g(0.4))),
            if ((eventData['date'] as String? ?? '').isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(() {
                try {
                  final d = DateTime.parse(eventData['date'] as String);
                  return '📅 ${d.day}/${d.month}/${d.year}';
                } catch (_) { return ''; }
              }(), style: TextStyle(fontSize: 11, color: _g(0.4))),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: priceCtrl,
              keyboardType: TextInputType.number,
              style: TextStyle(color: _gw, fontSize: 22, fontWeight: FontWeight.w800),
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
      'message': message,
      'rating': 4.8,
      if (_proPhotoUrl != null) 'profilePhotoUrl': _proPhotoUrl,
      'createdAt': FieldValue.serverTimestamp(),
    });
    // Update event doc: increment offersCount, add to submittedPros
    await FirebaseFirestore.instance.collection('event_requests').doc(eventId).update({
      'offersCount': FieldValue.increment(1),
      'submittedPros': FieldValue.arrayUnion([_proId ?? '']),
    });
    if (mounted) {
      setState(() => _submittedIds.add(eventId));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('✅ Η προσφορά στάλθηκε!'),
        backgroundColor: kGreen.withValues(alpha: 0.9),
        behavior: SnackBarBehavior.floating,
      ));
    }
  } catch (e) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Σφάλμα: $e')));
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
    'Πόρτες Ασφαλείας', 'Τέντες', 'Μονώσεις', 'Σιδηρουργός', 'Μαρμαράς',
    'Παθολόγος', 'Παιδίατρος', 'Οδοντίατρος', 'Φυσιοθεραπευτής',
    'Ψυχολόγος', 'Διατροφολόγος',
    'Καθαρίστρια', 'Κηπουρός', 'Baby Sitter', 'Μετακομίσεις',
    'Καθηγητής Μαθηματικών', 'Καθηγητής Αγγλικών',
    'Καθηγητής Γαλλικών', 'Καθηγητής Ιταλικών',
    'Καθηγητής Γερμανικών', 'Καθηγητής Ισπανικών',
    'Φιλόλογος', 'Καθηγητής Φυσικής', 'Καθηγητής Χημείας',
    'Καθηγητής Πληροφορικής', 'Καθηγητής Βιολογίας',
    'Personal Trainer',
    'Υπηρεσία Αποξήλωσης', 'Tattoo Artist', 'Τεχνίτρια Νυχιών',
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
    // Wake up Render backend early so push is ready when user submits
    Future(() async {
      try {
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
    _audioTimer?.cancel();
    _audioRec.dispose();
    _pulseCtrl.dispose();
    _textCtrl.dispose();
    super.dispose();
  }

  Future<void> _startVoice() async {
    if (!await _audioRec.hasPermission()) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Δώσε άδεια μικροφώνου. Δοκίμασε Chrome.')));
      return;
    }
    await _audioRec.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 16000, bitRate: 32000),
      path: 'req_voice_${DateTime.now().millisecondsSinceEpoch}',
    );
    setState(() { _audioRecording = true; _audioDur = Duration.zero; _requestAudioUrl = null; });
    _audioTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _audioDur += const Duration(seconds: 1));
    });
  }

  Future<void> _stopVoice() async {
    _audioTimer?.cancel();
    final path = await _audioRec.stop();
    if (!mounted) return;
    setState(() { _audioRecording = false; _audioUploading = true; });
    if (path == null) { setState(() => _audioUploading = false); return; }
    try {
      final Uint8List bytes;
      if (kIsWeb) {
        final res = await http.get(Uri.parse(path));
        bytes = res.bodyBytes;
      } else {
        bytes = await XFile(path).readAsBytes();
      }
      final uid = FirebaseAuth.instance.currentUser?.uid ?? 'anon';
      final ext = kIsWeb ? 'webm' : 'aac';
      final ct = kIsWeb ? 'audio/webm' : 'audio/aac';
      final ref = FirebaseStorage.instance.ref('requests/audio/${uid}_${DateTime.now().millisecondsSinceEpoch}.$ext');
      await ref.putData(bytes, SettableMetadata(contentType: ct));
      final url = await ref.getDownloadURL();
      if (mounted) setState(() { _requestAudioUrl = url; _audioUploading = false; });
    } catch (e) {
      if (mounted) { setState(() => _audioUploading = false); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Σφάλμα: $e'))); }
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
        'createdAt': FieldValue.serverTimestamp(),
        'expiresAt': Timestamp.fromDate(
            DateTime.now().add(const Duration(minutes: 15))),
        'imageCount': _images.length,
        if (_videoFiles.isNotEmpty) 'hasVideos': true,
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
    int imageCount, {
    bool hasVideos = false,
    bool immediate = false,
    bool withPhotos = false,
    double? minRating,
  }) async {
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
          'hasVideos': hasVideos,
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
                        selected: _wantsImmediate,
                        onTap: () => setState(() => _wantsImmediate = !_wantsImmediate)),
                  ]),
                  const SizedBox(height: 8),
                  Row(children: [
                    _CriteriaChip(emoji: '📸', label: 'Με φωτογραφίες',
                        selected: _wantsWithPhotos,
                        onTap: () => setState(() => _wantsWithPhotos = !_wantsWithPhotos)),
                    const SizedBox(width: 8),
                    _CriteriaChip(emoji: '4★+', label: 'Βαθμολογία 4+',
                        selected: _minRating == 4.0,
                        onTap: () => setState(() => _minRating = _minRating == 4.0 ? null : 4.0)),
                    const SizedBox(width: 8),
                    _CriteriaChip(emoji: '4.5★', label: 'Βαθμολογία 4.5+',
                        selected: _minRating == 4.5,
                        onTap: () => setState(() => _minRating = _minRating == 4.5 ? null : 4.5)),
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
    if (_secondsLeft >= 3600) {
      final h = (_secondsLeft ~/ 3600).toString().padLeft(2, '0');
      final m = ((_secondsLeft % 3600) ~/ 60).toString().padLeft(2, '0');
      final s = (_secondsLeft % 60).toString().padLeft(2, '0');
      return '$h:$m:$s';
    }
    final m = (_secondsLeft ~/ 60).toString().padLeft(2, '0');
    final s = (_secondsLeft % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  double get _progress => _secondsLeft / _totalSecs;

  @override
  Widget build(BuildContext context) {
    final offersReady = _secondsLeft <= 0;
    return PopScope(
      // Prevent accidental back when offers are ready (dialog is showing)
      canPop: !offersReady,
      child: Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: Row(children: [
              // Hide back button once offers are ready
              if (!offersReady)
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
                ...[
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
                ],
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
    )); // PopScope
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
                Text('${widget.name} πληκτρολογεί...',
                    style: const TextStyle(color: kGreen, fontSize: 10)),
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

// ── Shared portfolio premium gate (used by HomeScreen + OffersScreen) ──
void _showPortfolioPremiumGateDialog(BuildContext ctx, Map<String, dynamic> pro) {
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
            if (!ctx.mounted) return;
            final user = FirebaseAuth.instance.currentUser;
            if (user == null) return;
            try {
              final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
              if ((kFreeForAll || doc.data()?['isPremium'] == true || doc.data()?['isOwner'] == true) && ctx.mounted) {
                Navigator.of(ctx).push(PageRouteBuilder(
                  pageBuilder: (_, __, ___) => ProPortfolioScreen(pro: pro),
                  transitionsBuilder: (_, a, __, c2) => FadeTransition(opacity: a, child: c2),
                  transitionDuration: const Duration(milliseconds: 350),
                ));
              }
            } catch (_) {}
          },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: const LinearGradient(colors: [kGoldLight, kGold, kGoldDark]),
            ),
            child: const Center(child: Text('💎 Αναβάθμιση από 19,99€/μήνα',
                style: TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: 14))),
          ),
        ),
        const SizedBox(height: 8),
        TextButton(onPressed: () => Navigator.pop(c),
            child: Text('Ίσως αργότερα', style: TextStyle(color: Colors.white.withValues(alpha: 0.35), fontSize: 12))),
      ]),
    ),
  ));
}

// ═══════════════════════════════════════
// OFFERS SCREEN — Βήμα 3
// ═══════════════════════════════════════
class OffersScreen extends StatefulWidget {
  final String requestId, userId, description, criteria;
  final bool isEvent;
  const OffersScreen(
      {required this.requestId,
      required this.userId,
      required this.description,
      required this.criteria,
      this.isEvent = false,
      super.key});
  @override
  State<OffersScreen> createState() => _OffersScreenState();
}

class _OffersScreenState extends State<OffersScreen>
    with TickerProviderStateMixin {
  List<Map<String, dynamic>> _offers = [];
  bool _loading = true;
  late AnimationController _fadeCtrl;

  // _demoOffers αφαιρέθηκαν — ποτέ fake data σε πραγματικούς χρήστες

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
          await _enrichWithPhotos(loaded);
          if (mounted) setState(() { _offers = loaded; _loading = false; });
          return;
        }
      } catch (_) {}
      // No offers yet for event
      if (mounted) setState(() { _offers = []; _loading = false; });
      return;
    }

    // ── Regular request: try backend then Firestore ──
    try {
      final res = await http
          .get(Uri.parse('$kBackendUrl/get-offers/${widget.requestId}'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final offers = (data['offers'] as List?) ?? [];
        if (offers.isNotEmpty && mounted) {
          final loaded = offers.cast<Map<String, dynamic>>().toList();
          await _enrichWithPhotos(loaded);
          if (mounted) setState(() { _offers = loaded; _loading = false; });
          return;
        }
      }
    } catch (_) {}

    // Fallback: Firestore offers collection (χωρίς orderBy για να μην χρειάζεται composite index)
    try {
      final snap = await FirebaseFirestore.instance
          .collection('offers')
          .where('requestId', isEqualTo: widget.requestId)
          .limit(10)
          .get();
      if (snap.docs.isNotEmpty && mounted) {
        final loaded = snap.docs.map((d) => Map<String, dynamic>.from(d.data())).toList();
        // Ταξινόμηση κατά τιμή σε memory
        loaded.sort((a, b) => ((a['price'] ?? 0) as num).compareTo((b['price'] ?? 0) as num));
        await _enrichWithPhotos(loaded);
        if (mounted) setState(() { _offers = loaded; _loading = false; });
        return;
      }
    } catch (e) {
      debugPrint('Offers Firestore error: $e');
    }

    // Δεν υπάρχουν προσφορές — ΜΗΝ δείχνεις demo data
    if (mounted) setState(() { _offers = []; _loading = false; });
  }

  /// Fetches profilePhotoUrl for each offer from the professionals collection
  /// (only for offers that don't already have one).
  Future<void> _enrichWithPhotos(List<Map<String, dynamic>> offers) async {
    final futures = offers.map((offer) async {
      // Already has a photo — skip
      final existing = (offer['profilePhotoUrl'] ?? '').toString();
      if (existing.isNotEmpty) return;

      // Try professionalId first, then name lookup
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
    final professionalId = (offer['professionalId'] ?? '') as String;

    // Base info from offer (fallback)
    Map<String, dynamic> pro = {
      'id': professionalId,
      'name': offer['name'] ?? offer['professionalName'] ?? 'Επαγγελματίας',
      'displayName': offer['name'] ?? offer['professionalName'] ?? 'Επαγγελματίας',
      'profilePhotoUrl': offer['profilePhotoUrl'] ?? '',
      'specialty': offer['specialty'] ?? '',
      'emoji': offer['emoji'] ?? '🔧',
    };

    // Φόρτωσε πλήρες portfolio (portfolioProjects, portfolioPhotos κλπ) από Firestore
    if (professionalId.isNotEmpty) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection('professionals')
            .where('userId', isEqualTo: professionalId)
            .limit(1)
            .get();
        if (snap.docs.isNotEmpty) {
          final data = Map<String, dynamic>.from(snap.docs.first.data());
          // Firestore data overrides sparse offer fields; id always = professionalId
          pro = {...pro, ...data, 'id': professionalId};
        }
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
      // If professionalId is missing (server response), look it up from Firestore offers
      String? proId = (offer['professionalId'] as String?)?.isNotEmpty == true
          ? offer['professionalId'] as String
          : null;
      if (proId == null || proId.isEmpty) {
        try {
          final offerSnap = await FirebaseFirestore.instance
              .collection('offers')
              .where('requestId', isEqualTo: widget.requestId)
              .where('professionalName', isEqualTo:
                  (offer['name'] ?? offer['professionalName'] ?? '').toString())
              .limit(1)
              .get();
          if (offerSnap.docs.isNotEmpty) {
            proId = offerSnap.docs.first.data()['professionalId'] as String? ?? '';
          }
        } catch (_) {}
      }
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
          'bookingId': newBookingId,
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
  }

  @override
  Widget build(BuildContext context) {
    final offersReady = _secondsLeft <= 0;
    return PopScope(
      canPop: !offersReady,
      child: Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: Row(children: [
              // Hide back button once offers are ready
              if (!offersReady)
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
                              onSelect: () => _selectOffer(e.value),
                              onGallery: () => _openGallery(context, e.value),
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
                Text(_price <= 0 ? 'Κατόπιν\nεκτίμησης' : '${_price.toInt()}€',
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
  void dispose() { _player.dispose(); super.dispose(); }
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
          width: 30, height: 30,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: kGold.withValues(alpha: 0.15),
          ),
          child: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: kGold, size: 18),
        ),
        const SizedBox(width: 8),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Ηχητικό μήνυμα',
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
          Text(_playing ? 'Αναπαραγωγή...' : 'Πάτα για ακρόαση',
              style: TextStyle(color: _g(0.4), fontSize: 10)),
        ])),
        Icon(_playing ? Icons.pause_circle_outline : Icons.play_circle_outline,
            color: kGold.withValues(alpha: 0.6), size: 20),
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
  bool _wantsImmediate = false;
  double? _minRating;
  bool _wantsWithPhotos = false;
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
              }),
          ),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════
// RATING DIALOG
// ═══════════════════════════════════════
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
                style: TextStyle(color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 13, height: 1.5)),
            const SizedBox(height: 20),
            Row(children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => Navigator.pop(c),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      color: _g(0.07),
                      border: Border.all(color: _g(0.1)),
                    ),
                    child: const Center(child: Text('Άκυρο',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600))),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GestureDetector(
                  onTap: () async {
                    Navigator.pop(c);
                    await _deleteAccount(ctx);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      color: Colors.red.withValues(alpha: 0.15),
                      border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
                    ),
                    child: const Center(child: Text('Διαγραφή',
                        style: TextStyle(color: Colors.redAccent,
                            fontWeight: FontWeight.w800))),
                  ),
                ),
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  Future<void> _deleteAccount(BuildContext ctx) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final uid = user.uid;

    // Show loading
    if (ctx.mounted) {
      showDialog(
        context: ctx,
        barrierDismissible: false,
        builder: (_) => const Center(
          child: CircularProgressIndicator(color: kGold),
        ),
      );
    }

    try {
      final db = FirebaseFirestore.instance;

      // 1. Delete user subcollections
      for (final sub in ['notifications', 'selectedProfessionals']) {
        final snap = await db.collection('users').doc(uid).collection(sub).get();
        for (final d in snap.docs) { await d.reference.delete(); }
      }

      // 2. Delete user document
      await db.collection('users').doc(uid).delete();

      // 3. Delete user's requests
      final reqs = await db.collection('requests').where('userId', isEqualTo: uid).get();
      for (final d in reqs.docs) { await d.reference.delete(); }

      // 4. Delete user's bookings
      final bkgs = await db.collection('bookings').where('userId', isEqualTo: uid).get();
      for (final d in bkgs.docs) { await d.reference.delete(); }

      // 5. Delete user's ai_memory / reminders
      final mems = await db.collection('ai_memory').where('userId', isEqualTo: uid).get();
      for (final d in mems.docs) { await d.reference.delete(); }
      final rems = await db.collection('reminders').where('userId', isEqualTo: uid).get();
      for (final d in rems.docs) { await d.reference.delete(); }

      // 6. Delete chats where user is participant
      final chats = await db.collection('chats').where('userId', isEqualTo: uid).get();
      for (final chat in chats.docs) {
        final msgs = await chat.reference.collection('messages').get();
        for (final m in msgs.docs) { await m.reference.delete(); }
        await chat.reference.delete();
      }

      // 7. Delete professional profile if exists
      final pros = await db.collection('professionals').where('userId', isEqualTo: uid).get();
      for (final d in pros.docs) { await d.reference.delete(); }

      // 8. Delete Firebase Auth user (must be last)
      await user.delete();

      // 9. Clear local prefs
      await AuthService.logout();

    } catch (e) {
      // If re-auth is needed (Firebase requires recent login for delete)
      if (ctx.mounted) Navigator.of(ctx).pop(); // close loader
      if (ctx.mounted) {
        showDialog(
          context: ctx,
          builder: (_) => AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            title: const Text('Απαιτείται επανασύνδεση',
                style: TextStyle(color: Colors.white, fontSize: 16)),
            content: const Text(
                'Για λόγους ασφαλείας, αποσυνδέσου και ξανασύνδεσου πριν τη διαγραφή.',
                style: TextStyle(color: Colors.white54, fontSize: 13)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK', style: TextStyle(color: kGold)),
              ),
            ],
          ),
        );
      }
      return;
    }

    // Navigate to root after successful deletion
    if (ctx.mounted) {
      Navigator.of(ctx).popUntil((r) => r.isFirst);
    }
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

  Future<void> _changePhoto() async {
    final user = FirebaseAuth.instance.currentUser;
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
      if (mounted) {
        setState(() => _uploadingPhoto = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Σφάλμα: $e')));
      }
    }
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
                      GestureDetector(
                        onTap: _changePhoto,
                        child: Stack(clipBehavior: Clip.none, children: [
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
                          Uri.parse('https://gorealai.web.app/privacy.html'),
                          mode: LaunchMode.platformDefault)),
                  _ProfileRow(
                      icon: Icons.gavel_outlined,
                      emoji: '📋',
                      label: 'Όροι Χρήσης',
                      value: '',
                      onTap: () async => launchUrl(
                          Uri.parse('https://gorealai.web.app/terms.html'),
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
  // Βήμα 1: Δείχνει "σε επέλεξαν" + κουμπί Αποδοχή
  // Βήμα 2: Μετά την αποδοχή δείχνει το τηλέφωνο του χρήστη
  static void _showBookingAcceptedDialog(
      BuildContext context, Map<String, dynamic> notifData, String proId) {
    final userName = notifData['userName'] as String? ?? 'Χρήστης';
    final userPhone = notifData['userPhone'] as String? ?? '';
    final bookingId = notifData['bookingId'] as String? ?? '';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          bool accepted = false;
          bool loading = false;

          return StatefulBuilder(
            builder: (ctx2, setS2) => Dialog(
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
            child: _loadingNotifs
                ? const Center(child: CircularProgressIndicator(color: kGold))
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
                            _showOfferDialogFromNotif(
                                context, requestId, reqDoc.data()!, userId);
                          }
                        }
                        // Αν είναι offer_accepted → εμφάνισε στοιχεία χρήστη
                        if (isOfferAccepted) {
                          _showBookingAcceptedDialog(context, d, userId);
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
                            // Fetch pro's display name from chat doc
                            String proDisplayName = '';
                            try {
                              final chatDoc = await FirebaseFirestore.instance
                                  .collection('chats').doc(chatId).get();
                              proDisplayName = (chatDoc.data()?['proName'] as String?) ?? '';
                              if (proDisplayName.isEmpty) {
                                final uDoc = await FirebaseFirestore.instance
                                    .collection('users').doc(userId).get();
                                proDisplayName = (uDoc.data()?['name'] as String?) ?? '';
                              }
                            } catch (_) {}
                            if (context.mounted) Navigator.push(context, PageRouteBuilder(
                              pageBuilder: (_, __, ___) => ChatScreen(
                                chatId: chatId,
                                currentUserId: userId,
                                currentUserName: proDisplayName,
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
                              if (isDirectRequest && !isRead) ...[
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(10),
                                      gradient: const LinearGradient(
                                          colors: [kGoldLight, kGold])),
                                  child: const Text('📩 Απάντησε με προσφορά →',
                                      style: TextStyle(color: Colors.black,
                                          fontSize: 11, fontWeight: FontWeight.w800)),
                                ),
                              ],
                              if (isDirectOffer) ...[
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(10),
                                      color: const Color(0xFF1A1A6E).withValues(alpha: 0.4),
                                      border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.4))),
                                  child: const Text('💬 Δες την προσφορά στα Μηνύματα',
                                      style: TextStyle(color: Colors.lightBlueAccent,
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
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      GestureDetector(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: selected.isNotEmpty
                ? kGold.withValues(alpha: 0.08)
                : _g(0.05),
            border: Border.all(
                color: selected.isNotEmpty
                    ? kGold.withValues(alpha: 0.5)
                    : _g(0.12)),
          ),
          child: Row(children: [
            Icon(icon, color: kGold.withValues(alpha: 0.7), size: 18),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min, children: [
              Text(hint, style: TextStyle(
                  color: selected.isNotEmpty ? kGold : Colors.white.withValues(alpha: 0.5),
                  fontSize: 13, fontWeight: FontWeight.w600)),
              Text(subtitle, style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.28), fontSize: 10)),
            ])),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: kGold.withValues(alpha: 0.12)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.add, color: kGold, size: 14),
                const SizedBox(width: 4),
                Text(selected.isEmpty ? 'Επίλεξε' : '+Προσθήκη',
                    style: const TextStyle(color: kGold, fontSize: 11, fontWeight: FontWeight.w700)),
              ]),
            ),
          ]),
        ),
      ),
      if (selected.isNotEmpty) ...[
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: selected.map((v) => GestureDetector(
          onTap: () => onRemove(v),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: kGold.withValues(alpha: 0.12),
              border: Border.all(color: kGold.withValues(alpha: 0.4)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(v, style: const TextStyle(color: kGold, fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(width: 5),
              Icon(Icons.close, color: kGold.withValues(alpha: 0.6), size: 13),
            ]),
          ),
        )).toList()),
      ],
    ]);
  }
}

// ── Multi-select specialty picker (registration) ──────────────────────
class _MultiSpecialtyPicker extends StatefulWidget {
  final List<String> initial;
  const _MultiSpecialtyPicker({required this.initial});
  @override
  State<_MultiSpecialtyPicker> createState() => _MultiSpecialtyPickerState();
}

class _MultiSpecialtyPickerState extends State<_MultiSpecialtyPicker> {
  late List<String> _selected;
  @override
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
                          color: isSel ? kGold : Colors.white, fontSize: 14,
                          fontWeight: isSel ? FontWeight.w600 : FontWeight.w400)),
                    ]),
                  ),
                );
              }),
            ]);
          },
        ),
      );
}

// ── Keep old single-select picker (used in ProfessionalHomeScreen profile editing) ──
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
        onOk: _selected != null ? () => Navigator.pop(context, _selected) : null,
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
                final isSel = _selected == item;
                return GestureDetector(
                  onTap: () => setState(() => _selected = item),
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
                              shape: BoxShape.circle,
                              border: Border.all(color: isSel ? kGold : _g(0.25),
                                  width: isSel ? 6 : 1.5))),
                      const SizedBox(width: 12),
                      Text(item, style: TextStyle(
                          color: isSel ? kGold : Colors.white, fontSize: 14,
                          fontWeight: isSel ? FontWeight.w600 : FontWeight.w400)),
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

// ── Multi-select area picker (registration) ──────────────────────────
class _MultiAreaPicker extends StatefulWidget {
  final List<String> initial;
  const _MultiAreaPicker({required this.initial});
  @override
  State<_MultiAreaPicker> createState() => _MultiAreaPickerState();
}

class _MultiAreaPickerState extends State<_MultiAreaPicker> {
  late List<String> _selected;
  @override
  void initState() {
    super.initState();
    _selected = List<String>.from(widget.initial);
  }
  @override
  Widget build(BuildContext context) => _PickerContainer(
        title: 'Περιοχές — επίλεξε όσες θέλεις',
        onOk: _selected.isNotEmpty
            ? () => Navigator.pop(context, _selected)
            : null,
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          itemCount: _greekAreas.length,
          itemBuilder: (_, i) {
            final area = _greekAreas[i];
            final isSel = _selected.contains(area);
            return GestureDetector(
              onTap: () => setState(() {
                isSel ? _selected.remove(area) : _selected.add(area);
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
                  Text(area, style: TextStyle(
                      color: isSel ? kGold : Colors.white, fontSize: 14,
                      fontWeight: isSel ? FontWeight.w600 : FontWeight.w400)),
                ]),
              ),
            );
          },
        ),
      );
}

// ── Keep old single-select area picker (for backwards compat usage elsewhere) ──
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
        onOk: _selected != null ? () => Navigator.pop(context, _selected) : null,
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
                          shape: BoxShape.circle,
                          border: Border.all(color: isSel ? kGold : _g(0.25), width: isSel ? 6 : 1.5))),
                  const SizedBox(width: 12),
                  Text(area, style: TextStyle(
                      color: isSel ? kGold : Colors.white, fontSize: 14,
                      fontWeight: isSel ? FontWeight.w600 : FontWeight.w400)),
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
  List<String> _proAreas = [];
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
    // Also mark all unread offer_accepted notifications as read
    try {
      final notifSnap = await FirebaseFirestore.instance
          .collection('users').doc(widget.userId)
          .collection('notifications')
          .where('isRead', isEqualTo: false)
          .where('type', isEqualTo: 'offer_accepted')
          .get();
      for (final doc in notifSnap.docs) {
        doc.reference.update({'isRead': true});
      }
    } catch (_) {}
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
                  // Skip if pro already submitted offer
                  final subPros = List<String>.from(data['submittedPros'] ?? []);
                  if (subPros.contains(widget.userId)) continue;
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
                        // Skip if pro already submitted offer
                        final subPros = List<String>.from(data['submittedPros'] ?? []);
                        if (subPros.contains(widget.userId)) continue;
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

// ═══════════════════════════════════════
// PRIVACY POLICY SCREEN
// ═══════════════════════════════════════
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Row(children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _g(0.05),
                        border: Border.all(color: kGold.withValues(alpha: 0.2))),
                    child: const Icon(Icons.arrow_back_ios_new, color: kGold, size: 16)),
              ),
              const SizedBox(width: 14),
              const Text('Πολιτική Απορρήτου',
                  style: TextStyle(fontFamily: 'Raleway', fontSize: 20,
                      fontWeight: FontWeight.bold, color: Colors.white)),
            ]),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _legalSection('Τελευταία ενημέρωση: Ιούνιος 2026', isDate: true),
                _legalSection('1. Εισαγωγή',
                    body: 'Η εφαρμογή GorealAI (gorealai.web.app) σέβεται την ιδιωτικότητά σας. Η παρούσα Πολιτική Απορρήτου εξηγεί πώς συλλέγουμε, χρησιμοποιούμε και προστατεύουμε τα προσωπικά σας δεδομένα.'),
                _legalSection('2. Δεδομένα που συλλέγουμε',
                    body: '• Ονοματεπώνυμο και email κατά την εγγραφή\n• Τοποθεσία (πόλη) για σύνδεση με κοντινούς επαγγελματίες\n• Ιστορικό αιτημάτων και προσφορών\n• Φωτογραφίες και βίντεο που ανεβάζετε οικειοθελώς\n• FCM token για ειδοποιήσεις push'),
                _legalSection('3. Χρήση δεδομένων',
                    body: 'Τα δεδομένα σας χρησιμοποιούνται αποκλειστικά για:\n• Σύνδεση χρηστών με επαγγελματίες\n• Αποστολή push ειδοποιήσεων για νέες προσφορές\n• Βελτίωση της εμπειρίας χρήσης μέσω AI ανάλυσης\n• Εξυπηρέτηση πελατών'),
                _legalSection('4. Αποθήκευση & Ασφάλεια',
                    body: 'Τα δεδομένα αποθηκεύονται με κρυπτογράφηση στους διακομιστές Firebase (Google). Δεν πωλούμε ποτέ τα δεδομένα σας σε τρίτους.'),
                _legalSection('5. Cookies & Analytics',
                    body: 'Χρησιμοποιούμε Firebase Analytics για ανώνυμη στατιστική ανάλυση χρήσης. Δεν χρησιμοποιούμε cookies τρίτων για διαφήμιση.'),
                _legalSection('6. Διαγραφή λογαριασμού',
                    body: 'Μπορείτε να ζητήσετε τη διαγραφή των δεδομένων σας στέλνοντας email στο: support@gorealai.web.app\nΗ διαγραφή ολοκληρώνεται εντός 30 ημερών.'),
                _legalSection('7. Ανήλικοι',
                    body: 'Η εφαρμογή δεν απευθύνεται σε άτομα κάτω των 18 ετών. Δεν συλλέγουμε εκούσια δεδομένα ανηλίκων.'),
                _legalSection('8. Αλλαγές',
                    body: 'Διατηρούμε το δικαίωμα να ενημερώνουμε την παρούσα πολιτική. Σας ειδοποιούμε για σημαντικές αλλαγές μέσω push notification ή email.'),
                _legalSection('9. Επικοινωνία',
                    body: 'Για οποιαδήποτε ερώτηση σχετικά με την ιδιωτικότητά σας:\nEmail: support@gorealai.web.app'),
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
// TERMS OF SERVICE SCREEN
// ═══════════════════════════════════════
class TermsOfServiceScreen extends StatelessWidget {
  const TermsOfServiceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Row(children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _g(0.05),
                        border: Border.all(color: kGold.withValues(alpha: 0.2))),
                    child: const Icon(Icons.arrow_back_ios_new, color: kGold, size: 16)),
              ),
              const SizedBox(width: 14),
              const Text('Όροι Χρήσης',
                  style: TextStyle(fontFamily: 'Raleway', fontSize: 20,
                      fontWeight: FontWeight.bold, color: Colors.white)),
            ]),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _legalSection('Τελευταία ενημέρωση: Ιούνιος 2026', isDate: true),
                _legalSection('1. Αποδοχή Όρων',
                    body: 'Χρησιμοποιώντας την εφαρμογή GorealAI αποδέχεστε πλήρως τους παρόντες Όρους Χρήσης. Αν διαφωνείτε, παρακαλούμε να μην χρησιμοποιείτε την εφαρμογή.'),
                _legalSection('2. Περιγραφή Υπηρεσίας',
                    body: 'Το GorealAI είναι πλατφόρμα reverse auction που συνδέει χρήστες με επαγγελματίες. Δεν είμαστε εργοδότης ή εκπρόσωπος κανενός επαγγελματία. Λειτουργούμε ως διαμεσολαβητής.'),
                _legalSection('3. Εγγραφή & Λογαριασμός',
                    body: '• Πρέπει να είστε τουλάχιστον 18 ετών\n• Παρέχετε ακριβή στοιχεία κατά την εγγραφή\n• Είστε υπεύθυνοι για την ασφάλεια του κωδικού σας\n• Δεν επιτρέπεται η δημιουργία πολλαπλών λογαριασμών'),
                _legalSection('4. Κανόνες Χρήσης',
                    body: 'Απαγορεύεται:\n• Η ανάρτηση ψευδών πληροφοριών\n• Η παρενόχληση άλλων χρηστών\n• Η χρήση για παράνομες δραστηριότητες\n• Η αποστολή spam ή διαφημιστικού περιεχομένου\n• Η παράκαμψη του συστήματος αξιολόγησης'),
                _legalSection('5. Επαγγελματίες',
                    body: 'Οι επαγγελματίες που εγγράφονται στην πλατφόρμα:\n• Βεβαιώνουν ότι κατέχουν τις νόμιμες άδειες\n• Αναλαμβάνουν πλήρη ευθύνη για τις παρεχόμενες υπηρεσίες\n• Υποχρεούνται να τηρούν τις δεσμεύσεις τους'),
                _legalSection('6. Πληρωμές & Συνδρομές',
                    body: 'Η βασική χρήση της εφαρμογής είναι δωρεάν. Premium συνδρομές χρεώνονται μηνιαία ή ετήσια. Δεν υπάρχει επιστροφή χρημάτων για μερικώς χρησιμοποιημένες περιόδους.'),
                _legalSection('7. Ευθύνη',
                    body: 'Η GorealAI δεν φέρει ευθύνη για:\n• Τη ποιότητα των παρεχόμενων υπηρεσιών\n• Διαφορές μεταξύ χρηστών και επαγγελματιών\n• Ζημίες που προκύπτουν από τη χρήση της πλατφόρμας'),
                _legalSection('8. Πνευματικά Δικαιώματα',
                    body: 'Όλο το περιεχόμενο της εφαρμογής (λογότυπο, κείμενα, γραφικά) ανήκει στη GorealAI και προστατεύεται από την ελληνική και ευρωπαϊκή νομοθεσία.'),
                _legalSection('9. Διακοπή Υπηρεσίας',
                    body: 'Διατηρούμε το δικαίωμα να αναστείλουμε ή τερματίσουμε λογαριασμούς που παραβιάζουν τους παρόντες όρους, χωρίς προειδοποίηση.'),
                _legalSection('10. Εφαρμοστέο Δίκαιο',
                    body: 'Οι παρόντες όροι διέπονται από το ελληνικό δίκαιο. Αρμόδια δικαστήρια είναι τα Δικαστήρια Αθηνών.'),
                _legalSection('11. Επικοινωνία',
                    body: 'Email: support@gorealai.web.app'),
                const SizedBox(height: 40),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

Widget _legalSection(String title, {String? body, bool isDate = false}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title,
          style: TextStyle(
              color: isDate ? _g(0.4) : kGold,
              fontSize: isDate ? 11 : 14,
              fontWeight: isDate ? FontWeight.w400 : FontWeight.w700)),
      if (body != null) ...[
        const SizedBox(height: 6),
        Text(body,
            style: TextStyle(
                color: _g(0.65), fontSize: 13, height: 1.6)),
      ],
    ]),
  );
}

// ═══════════════════════════════════════
// MESSAGES SCREEN
// ═══════════════════════════════════════
class _MessagesScreen extends StatelessWidget {
  final String userId;
  const _MessagesScreen({required this.userId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(children: [
          _TopBar(label: '💬 Μηνύματα'),
          Expanded(
            child: userId.isEmpty
                ? Center(
                    child: Text('Συνδέσου για να δεις τα μηνύματά σου',
                        style: TextStyle(color: _g(0.4), fontSize: 14)))
                : StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('bookings')
                        .where('userId', isEqualTo: userId)
                        .orderBy('createdAt', descending: true)
                        .snapshots(),
                    builder: (_, snap) {
                      if (snap.connectionState == ConnectionState.waiting) {
                        return const Center(
                            child: CircularProgressIndicator(color: kGold));
                      }
                      final docs = snap.data?.docs ?? [];
                      if (docs.isEmpty) {
                        return Center(
                          child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('💬',
                                    style: TextStyle(fontSize: 52)),
                                const SizedBox(height: 14),
                                const Text('Δεν έχεις ακόμα μηνύματα',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600)),
                                const SizedBox(height: 6),
                                Text(
                                    'Όταν επιλέξεις επαγγελματία\nθα εμφανιστεί εδώ',
                                    textAlign: TextAlign.center,
                                    style:
                                        TextStyle(color: _g(0.4), fontSize: 13)),
                              ]),
                        );
                      }
                      return ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                        itemCount: docs.length,
                        itemBuilder: (_, i) {
                          final d = docs[i].data() as Map<String, dynamic>;
                          final bookingId = docs[i].id;
                          final proName = d['professionalName'] as String? ??
                              'Επαγγελματίας';
                          final status = d['status'] as String? ?? 'pending';
                          final statusEmoji = status == 'accepted'
                              ? '✅'
                              : status == 'rejected'
                                  ? '❌'
                                  : '⏳';
                          final statusLabel = status == 'accepted'
                              ? 'Αποδεκτό'
                              : status == 'rejected'
                                  ? 'Απορρίφθηκε'
                                  : 'Αναμένεται';
                          return GestureDetector(
                            onTap: () => Navigator.push(
                                context,
                                PageRouteBuilder(
                                  transitionDuration:
                                      const Duration(milliseconds: 300),
                                  pageBuilder: (_, __, ___) => _ChatScreen(
                                      bookingId: bookingId,
                                      userId: userId,
                                      proName: proName),
                                  transitionsBuilder: (_, a, __, c) =>
                                      FadeTransition(opacity: a, child: c),
                                )),
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(16),
                                  color: _g(0.04),
                                  border: Border.all(color: _g(0.07))),
                              child: Row(children: [
                                Container(
                                  width: 48,
                                  height: 48,
                                  decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: kGold.withValues(alpha: 0.12),
                                      border: Border.all(
                                          color: kGold.withValues(alpha: 0.35))),
                                  child: Center(
                                      child: Text(
                                          proName.isNotEmpty
                                              ? proName[0].toUpperCase()
                                              : 'P',
                                          style: const TextStyle(
                                              color: kGold,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 18))),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                      Text(proName,
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w700,
                                              fontSize: 15)),
                                      const SizedBox(height: 3),
                                      Text('$statusEmoji $statusLabel',
                                          style: TextStyle(
                                              fontSize: 12,
                                              color: status == 'accepted'
                                                  ? kGreen
                                                  : status == 'rejected'
                                                      ? Colors.red
                                                      : _g(0.45))),
                                    ])),
                                Icon(Icons.chevron_right_rounded,
                                    color: _g(0.25)),
                              ]),
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
// CHAT SCREEN
// ═══════════════════════════════════════
class _ChatScreen extends StatefulWidget {
  final String bookingId, userId, proName;
  const _ChatScreen(
      {required this.bookingId, required this.userId, required this.proName});
  @override
  State<_ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<_ChatScreen> {
  final _msgCtrl = TextEditingController();
  final _scroll = ScrollController();
  final _audioRec = AudioRecorder();
  bool _audioRecording = false;
  bool _audioUploading = false;

  CollectionReference get _msgs => FirebaseFirestore.instance
      .collection('bookings')
      .doc(widget.bookingId)
      .collection('messages');

  @override
  void dispose() {
    _msgCtrl.dispose();
    _scroll.dispose();
    _audioRec.dispose();
    super.dispose();
  }

  Future<void> _send({String? audioUrl}) async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty && audioUrl == null) return;
    _msgCtrl.clear();
    await _msgs.add({
      'senderId': widget.userId,
      'text': text,
      if (audioUrl != null) 'audioUrl': audioUrl,
      'createdAt': FieldValue.serverTimestamp(),
    });
    await Future.delayed(const Duration(milliseconds: 200));
    if (_scroll.hasClients) {
      _scroll.animateTo(_scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  Future<void> _startAudio() async {
    final ok = await _audioRec.hasPermission();
    if (!ok) return;
    await _audioRec.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: '');
    if (mounted) setState(() => _audioRecording = true);
  }

  Future<void> _stopAudio() async {
    final path = await _audioRec.stop();
    if (!mounted) return;
    setState(() { _audioRecording = false; _audioUploading = true; });
    try {
      if (path != null) {
        final resp = await http.get(Uri.parse(path));
        final ref = FirebaseStorage.instance.ref(
            'chat_audio/${widget.bookingId}/${DateTime.now().millisecondsSinceEpoch}.webm');
        await ref.putData(resp.bodyBytes, SettableMetadata(contentType: 'audio/webm'));
        final url = await ref.getDownloadURL();
        if (mounted) { setState(() => _audioUploading = false); await _send(audioUrl: url); }
      } else {
        if (mounted) setState(() => _audioUploading = false);
      }
    } catch (e) {
      if (mounted) setState(() => _audioUploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: _g(0.05)),
                    child: const Icon(Icons.arrow_back_ios_new,
                        color: Colors.white, size: 16)),
              ),
              const SizedBox(width: 12),
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: kGold.withValues(alpha: 0.12),
                    border: Border.all(color: kGold.withValues(alpha: 0.4))),
                child: Center(child: Text(
                    widget.proName.isNotEmpty ? widget.proName[0].toUpperCase() : 'P',
                    style: const TextStyle(color: kGold, fontWeight: FontWeight.bold))),
              ),
              const SizedBox(width: 10),
              Text(widget.proName,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
            ]),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: _msgs.orderBy('createdAt').snapshots(),
              builder: (_, snap) {
                final docs = snap.data?.docs ?? [];
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_scroll.hasClients && docs.isNotEmpty) {
                    _scroll.jumpTo(_scroll.position.maxScrollExtent);
                  }
                });
                if (docs.isEmpty) {
                  return Center(child: Text('Ξεκίνα τη συνομιλία!',
                      style: TextStyle(color: _g(0.35), fontSize: 14)));
                }
                return ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  itemCount: docs.length,
                  itemBuilder: (_, i) {
                    final d = docs[i].data() as Map<String, dynamic>;
                    final isMe = d['senderId'] == widget.userId;
                    final text = d['text'] as String? ?? '';
                    final audioUrl = d['audioUrl'] as String?;
                    return Align(
                      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width * 0.72),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          color: isMe ? kGold.withValues(alpha: 0.15) : _g(0.07),
                          border: Border.all(
                              color: isMe ? kGold.withValues(alpha: 0.3) : _g(0.1)),
                        ),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (text.isNotEmpty)
                                Text(text,
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 14)),
                              if (audioUrl != null) ...[
                                if (text.isNotEmpty) const SizedBox(height: 6),
                                _AudioPlayWidget(url: audioUrl),
                              ],
                            ]),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            decoration: BoxDecoration(
                color: _g(0.04),
                border: Border(top: BorderSide(color: _g(0.08)))),
            child: Row(children: [
              GestureDetector(
                onTap: _audioRecording ? _stopAudio : _startAudio,
                child: Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _audioRecording
                          ? Colors.red.withValues(alpha: 0.15)
                          : _g(0.07),
                      border: Border.all(
                          color: _audioRecording
                              ? Colors.red.withValues(alpha: 0.5)
                              : _g(0.1))),
                  child: _audioUploading
                      ? const Padding(
                          padding: EdgeInsets.all(10),
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: kGold))
                      : Icon(
                          _audioRecording ? Icons.stop_rounded : Icons.mic_rounded,
                          color: _audioRecording ? Colors.red : kGold,
                          size: 20),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _msgCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Μήνυμα...',
                    hintStyle: TextStyle(color: _g(0.3), fontSize: 14),
                    filled: true,
                    fillColor: _g(0.05),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none),
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => _send(),
                child: Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                          colors: [kGoldLight, kGold])),
                  child: const Icon(Icons.send_rounded,
                      color: Colors.black, size: 18),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════
// MESSAGES SCREEN
// ═══════════════════════════════════════
class _MessagesScreen extends StatelessWidget {
  final String userId;
  const _MessagesScreen({required this.userId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(children: [
          _TopBar(label: '💬 Μηνύματα'),
          Expanded(
            child: userId.isEmpty
                ? Center(child: Text('Συνδέσου για να δεις τα μηνύματά σου',
                    style: TextStyle(color: _g(0.4), fontSize: 14)))
                : StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('bookings')
                        .where('userId', isEqualTo: userId)
                        .orderBy('createdAt', descending: true)
                        .snapshots(),
                    builder: (_, snap) {
                      if (snap.connectionState == ConnectionState.waiting) {
                        return const Center(
                            child: CircularProgressIndicator(color: kGold));
                      }
                      final docs = snap.data?.docs ?? [];
                      if (docs.isEmpty) {
                        return Center(
                          child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('💬',
                                    style: TextStyle(fontSize: 52)),
                                const SizedBox(height: 14),
                                const Text('Δεν έχεις ακόμα μηνύματα',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600)),
                                const SizedBox(height: 6),
                                Text(
                                    'Όταν επιλέξεις επαγγελματία\nθα εμφανιστεί εδώ',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        color: _g(0.4), fontSize: 13)),
                              ]),
                        );
                      }
                      return ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                        itemCount: docs.length,
                        itemBuilder: (_, i) {
                          final d =
                              docs[i].data() as Map<String, dynamic>;
                          final bookingId = docs[i].id;
                          final proName = d['professionalName'] as String? ??
                              'Επαγγελματίας';
                          final status = d['status'] as String? ?? 'pending';
                          final statusEmoji = status == 'accepted'
                              ? '✅'
                              : status == 'rejected'
                                  ? '❌'
                                  : '⏳';
                          final statusLabel = status == 'accepted'
                              ? 'Αποδεκτό'
                              : status == 'rejected'
                                  ? 'Απορρίφθηκε'
                                  : 'Αναμένεται';
                          return GestureDetector(
                            onTap: () => Navigator.push(
                                context,
                                PageRouteBuilder(
                                  transitionDuration:
                                      const Duration(milliseconds: 300),
                                  pageBuilder: (_, __, ___) => _ChatScreen(
                                      bookingId: bookingId,
                                      userId: userId,
                                      proName: proName),
                                  transitionsBuilder: (_, a, __, c) =>
                                      FadeTransition(opacity: a, child: c),
                                )),
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(16),
                                  color: _g(0.04),
                                  border: Border.all(color: _g(0.07))),
                              child: Row(children: [
                                Container(
                                  width: 48,
                                  height: 48,
                                  decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: kGold.withValues(alpha: 0.12),
                                      border: Border.all(
                                          color:
                                              kGold.withValues(alpha: 0.35))),
                                  child: Center(
                                      child: Text(
                                          proName.isNotEmpty
                                              ? proName[0].toUpperCase()
                                              : 'P',
                                          style: const TextStyle(
                                              color: kGold,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 18))),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                      Text(proName,
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w700,
                                              fontSize: 15)),
                                      const SizedBox(height: 3),
                                      Text('$statusEmoji $statusLabel',
                                          style: TextStyle(
                                              fontSize: 12,
                                              color: status == 'accepted'
                                                  ? kGreen
                                                  : status == 'rejected'
                                                      ? Colors.red
                                                      : _g(0.45))),
                                    ])),
                                Icon(Icons.chevron_right_rounded,
                                    color: _g(0.25)),
                              ]),
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
// CHAT SCREEN
// ═══════════════════════════════════════
class _ChatScreen extends StatefulWidget {
  final String bookingId, userId, proName;
  const _ChatScreen(
      {required this.bookingId,
      required this.userId,
      required this.proName});
  @override
  State<_ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<_ChatScreen> {
  final _msgCtrl = TextEditingController();
  final _scroll = ScrollController();
  final _audioRec = AudioRecorder();
  bool _audioRecording = false;
  bool _audioUploading = false;
  String? _pendingAudioUrl;

  CollectionReference get _msgs => FirebaseFirestore.instance
      .collection('bookings')
      .doc(widget.bookingId)
      .collection('messages');

  @override
  void dispose() {
    _msgCtrl.dispose();
    _scroll.dispose();
    _audioRec.dispose();
    super.dispose();
  }

  Future<void> _send({String? audioUrl}) async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty && audioUrl == null) return;
    _msgCtrl.clear();
    await _msgs.add({
      'senderId': widget.userId,
      'text': text,
      if (audioUrl != null) 'audioUrl': audioUrl,
      'createdAt': FieldValue.serverTimestamp(),
    });
    await Future.delayed(const Duration(milliseconds: 200));
    if (_scroll.hasClients) {
      _scroll.animateTo(_scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  Future<void> _startAudio() async {
    final ok = await _audioRec.hasPermission();
    if (!ok) return;
    await _audioRec.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: '');
    if (mounted) setState(() => _audioRecording = true);
  }

  Future<void> _stopAudio() async {
    final path = await _audioRec.stop();
    if (!mounted) return;
    setState(() { _audioRecording = false; _audioUploading = true; });
    try {
      String? url;
      if (path != null) {
        final resp = await http.get(Uri.parse(path));
        final bytes = resp.bodyBytes;
        final ct = 'audio/webm';
        final ref = FirebaseStorage.instance.ref(
            'chat_audio/${widget.bookingId}/${DateTime.now().millisecondsSinceEpoch}.webm');
        await ref.putData(bytes, SettableMetadata(contentType: ct));
        url = await ref.getDownloadURL();
      }
      if (mounted) setState(() => _audioUploading = false);
      if (url != null) await _send(audioUrl: url);
    } catch (e) {
      if (mounted) setState(() => _audioUploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Row(children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle, color: _g(0.05)),
                    child: const Icon(Icons.arrow_back_ios_new,
                        color: Colors.white, size: 16)),
              ),
              const SizedBox(width: 12),
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: kGold.withValues(alpha: 0.12),
                    border: Border.all(color: kGold.withValues(alpha: 0.4))),
                child: Center(child: Text(
                    widget.proName.isNotEmpty
                        ? widget.proName[0].toUpperCase()
                        : 'P',
                    style: const TextStyle(
                        color: kGold, fontWeight: FontWeight.bold))),
              ),
              const SizedBox(width: 10),
              Text(widget.proName,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 16)),
            ]),
          ),
          const SizedBox(height: 10),
          // Messages
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: _msgs.orderBy('createdAt').snapshots(),
              builder: (_, snap) {
                final docs = snap.data?.docs ?? [];
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_scroll.hasClients && docs.isNotEmpty) {
                    _scroll.jumpTo(_scroll.position.maxScrollExtent);
                  }
                });
                if (docs.isEmpty) {
                  return Center(
                      child: Text('Ξεκίνα τη συνομιλία!',
                          style: TextStyle(color: _g(0.35), fontSize: 14)));
                }
                return ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  itemCount: docs.length,
                  itemBuilder: (_, i) {
                    final d = docs[i].data() as Map<String, dynamic>;
                    final isMe = d['senderId'] == widget.userId;
                    final text = d['text'] as String? ?? '';
                    final audioUrl = d['audioUrl'] as String?;
                    return Align(
                      alignment:
                          isMe ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        constraints: BoxConstraints(
                            maxWidth:
                                MediaQuery.of(context).size.width * 0.72),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          color: isMe
                              ? kGold.withValues(alpha: 0.15)
                              : _g(0.07),
                          border: Border.all(
                              color: isMe
                                  ? kGold.withValues(alpha: 0.3)
                                  : _g(0.1)),
                        ),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (text.isNotEmpty)
                                Text(text,
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 14)),
                              if (audioUrl != null) ...[
                                if (text.isNotEmpty) const SizedBox(height: 6),
                                _AudioPlayWidget(url: audioUrl),
                              ],
                            ]),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          // Input bar
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            decoration: BoxDecoration(
                color: _g(0.04),
                border: Border(top: BorderSide(color: _g(0.08)))),
            child: Row(children: [
              // Mic button
              GestureDetector(
                onTap: _audioRecording ? _stopAudio : _startAudio,
                child: Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _audioRecording
                          ? Colors.red.withValues(alpha: 0.15)
                          : _g(0.07),
                      border: Border.all(
                          color: _audioRecording
                              ? Colors.red.withValues(alpha: 0.5)
                              : _g(0.1))),
                  child: _audioUploading
                      ? const Padding(
                          padding: EdgeInsets.all(10),
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: kGold))
                      : Icon(
                          _audioRecording ? Icons.stop_rounded : Icons.mic_rounded,
                          color: _audioRecording ? Colors.red : kGold,
                          size: 20),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _msgCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Μήνυμα...',
                    hintStyle: TextStyle(color: _g(0.3), fontSize: 14),
                    filled: true,
                    fillColor: _g(0.05),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none),
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => _send(),
                child: Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                          colors: [kGoldLight, kGold])),
                  child: const Icon(Icons.send_rounded,
                      color: Colors.black, size: 18),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
