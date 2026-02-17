import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'splash_screen.dart';


Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const GorealAiApp());
}

/* ---------------- APP ---------------- */

class GorealAiApp extends StatelessWidget {
  const GorealAiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: "GorealAI",
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        fontFamily: "SF Pro Display",
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          elevation: 0,
          centerTitle: true,
        ),
      ),
      home: const SplashScreen(),
    );
  }
}

/* ---------------- AUTH GATE ---------------- */

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  bool isDemoMode() {
    try {
      final uri = Uri.base;

      if (uri.queryParameters["demo"] == "1") return true;
      if (uri.fragment.contains("demo=1")) return true;

      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isDemoMode()) {
      return const HomeScreen();
    }

    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const LoginScreen();
        return const HomeScreen();
      },
    );
  }
}

/* ---------------- LOGIN SCREEN ---------------- */

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final email = TextEditingController();
  final pass = TextEditingController();
  final name = TextEditingController();
  final city = TextEditingController();

  bool loading = false;
  bool isLogin = true;

  late AnimationController fadeController;
  late Animation<double> fade;

  @override
  void initState() {
    super.initState();

    fadeController =
        AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
    fade = CurvedAnimation(parent: fadeController, curve: Curves.easeOut);

    fadeController.forward();
  }

  Future<void> submit() async {
    setState(() => loading = true);

    try {
      if (isLogin) {
  final cred = await FirebaseAuth.instance.signInWithEmailAndPassword(
    email: email.text.trim(),
    password: pass.text.trim(),
  );

  final doc = await FirebaseFirestore.instance
      .collection("users")
      .doc(cred.user!.uid)
      .get();

  // Αν δεν υπάρχει profile → δημιουργία αυτόματα
  if (!doc.exists) {
    await FirebaseFirestore.instance
        .collection("users")
        .doc(cred.user!.uid)
        .set({
      "name": cred.user!.displayName ?? "User",
      "city": "",
      "createdAt": FieldValue.serverTimestamp(),
    });
  }
}
      else {
        final cred =
            await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: email.text.trim(),
          password: pass.text.trim(),
        );

        await cred.user!.updateDisplayName(name.text.trim());

        await FirebaseFirestore.instance
            .collection("users")
            .doc(cred.user!.uid)
            .set({
          "name": name.text.trim(),
          "city": city.text.trim(),
        });
      }

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Σφάλμα: $e")),
      );
    }

    setState(() => loading = false);
  }

  @override
  void dispose() {
    fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FadeTransition(
          opacity: fade,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(30),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                width: 360,
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(color: Colors.white12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      "GorealAI",
                      style:
                          TextStyle(fontSize: 36, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 26),

                    if (!isLogin)
                      TextField(
                        controller: name,
                        decoration: const InputDecoration(labelText: "Όνομα"),
                      ),

                    if (!isLogin)
                      const SizedBox(height: 14),

                    if (!isLogin)
                      TextField(
                        controller: city,
                        decoration: const InputDecoration(labelText: "Πόλη"),
                      ),

                    if (!isLogin)
                      const SizedBox(height: 14),

                    TextField(
                      controller: email,
                      decoration: const InputDecoration(labelText: "Email"),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: pass,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: "Password"),
                    ),
                    const SizedBox(height: 26),

                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        onPressed: loading ? null : submit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                        child: loading
                            ? const CircularProgressIndicator()
                            : Text(isLogin ? "Login" : "Create account"),
                      ),
                    ),

                    const SizedBox(height: 10),

                    TextButton(
                      onPressed: () => setState(() => isLogin = !isLogin),
                      child: Text(
                        isLogin
                            ? "Δεν έχεις λογαριασμό; Sign up"
                            : "Έχεις λογαριασμό; Login",
                        style: const TextStyle(color: Colors.white70),
                      ),
                    )
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final nameController = TextEditingController();
  final locationController = TextEditingController();
  bool loading = false;

  Future<void> saveProfile() async {
    setState(() => loading = true);

    final user = FirebaseAuth.instance.currentUser!;

    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .set({
          'name': nameController.text.trim(),
          'location': locationController.text.trim(),
          'createdAt': FieldValue.serverTimestamp(),
});
    

    setState(() => loading = false);

    if (!mounted) return;

    Navigator.pushReplacementNamed(context, "/home");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Container(
          width: 380,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "Καλώς ήρθες 👋",
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 24),

              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: "Όνομα"),
              ),

              const SizedBox(height: 14),

              TextField(
                controller: locationController,
                decoration: const InputDecoration(labelText: "Περιοχή"),
              ),

              const SizedBox(height: 26),

              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: loading ? null : saveProfile,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  child: loading
                      ? const CircularProgressIndicator()
                      : const Text("Συνέχεια"),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }
}

/* ---------------- HOME SCREEN ---------------- */

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController controller;
  late Animation<double> fade;
  late Animation<double> slide;

  String? userName;

  @override
  void initState() {
    super.initState();

    loadUserProfile();

    Future<void> logout() async {
  await FirebaseAuth.instance.signOut();
}

    controller =
        AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

    fade = CurvedAnimation(parent: controller, curve: Curves.easeOut);

    slide = Tween<double>(begin: 40, end: 0).animate(
      CurvedAnimation(parent: controller, curve: Curves.easeOut),
    );

    controller.forward();
  }

  Future<void> loadUserProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final doc = await FirebaseFirestore.instance
        .collection("users")
        .doc(user.uid)
        .get();

    if (!mounted) return;

    setState(() {
      userName = doc.data()?["name"];
    });
  }

  Future<void> logout() async {
    await FirebaseAuth.instance.signOut();

    if (!mounted) return;

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Widget bigButton(String text, Color color, Widget screen) {
    return FadeTransition(
      opacity: fade,
      child: AnimatedBuilder(
        animation: slide,
        builder: (_, __) {
          return Transform.translate(
            offset: Offset(0, slide.value),
            child: SizedBox(
              width: double.infinity,
              height: 70,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: color.withOpacity(0.9),
                  foregroundColor: Colors.black,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
                onPressed: () {
                  Navigator.push(
                    context,
                    PageRouteBuilder(
                      transitionDuration: const Duration(milliseconds: 400),
                      pageBuilder: (_, __, ___) => screen,
                      transitionsBuilder: (_, anim, __, child) {
                        return FadeTransition(opacity: anim, child: child);
                      },
                    ),
                  );
                },
                child: Text(
                  text,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
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
      body: Stack(
        children: [
          Positioned.fill(
            child: Image.asset(
              "assets/images/background.png",
              fit: BoxFit.cover,
            ),
          ),
          Positioned.fill(
            child: Container(color: Colors.black.withOpacity(0.45)),
          ),

          /// 🔹 Greeting + Logout
          
          if (userName != null)
            Positioned(
              top: 60,
              left: 20,
              child: WelcomeGlowText(name: userName!),
            ),
            Positioned(
              top: 60,
              right: 24,
              child: IconButton(
              icon: const Icon(Icons.logout, color: Colors.white),
              onPressed: logout,
              ),
            ),

          /// 🔹 Buttons
          Positioned(
            bottom: 70,
            left: 24,
            right: 24,
            child: Column(
              children: [
                bigButton("🛒 Αγορές", Colors.amber,
                    ChatScreen(mode: "shopping", userName: userName)),
                const SizedBox(height: 16),
                bigButton("✈️ Διακοπές", Colors.orange,
                    ChatScreen(mode: "travel", userName: userName)),
                const SizedBox(height: 16),
                bigButton("🧑‍🔧 Επαγγελματίες", Colors.greenAccent,
                    ChatScreen(mode: "services", userName: userName)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
/* ---------------- CHAT SCREEN ---------------- */

class ChatScreen extends StatefulWidget {
  final String mode;
  final String? userName;

  const ChatScreen({super.key, required this.mode, this.userName,});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final controller = TextEditingController();
  final scrollController = ScrollController();

  List<Map<String, dynamic>> messages = [];
  bool showUserButton = false;
  bool typing = false;

  late String mode;
  
  List<Map<String, dynamic>> history = [];

    @override
  void initState() {
    super.initState();

    mode = widget.mode;
    

    WidgetsBinding.instance.addPostFrameCallback((_) => loadWelcome());
  }

  /// ✅ FIXED WELCOME
  Future<void> loadWelcome() async {
  setState(() => typing = true);

  final user =FirebaseAuth.instance.currentUser;
  final res = await http.post(
  Uri.parse("https://ai-backend-kkt7.onrender.com/chat"),
  headers: {"Content-Type": "application/json"},
  body: jsonEncode({
    "history": messages,
    "mode": mode,
    "username": widget.userName, 
    "userId": user?.uid,  // 👈 ΤΟ ΚΡΙΣΙΜΟ ΣΗΜΕΙΟ
  }),
);

  final data = jsonDecode(res.body);

  setState(() {
    typing = false;

    messages.add({
      "text": data["reply"],
      "links": data["links"],
      "isUser": false,
    });

    /// στο welcome δεν θέλουμε κουμπί εκτός αν το δώσει ο server
    showUserButton = data["showButton"] == true;
  });

  scrollToBottom();

  }

  void scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 120), () {
      if (scrollController.hasClients) {
        scrollController.animateTo(
          scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOut,
        );
      }
    });
  }/// ✅ SEND MESSAGE με LOOP counter
 Future<void> sendMessage(String text) async {
  setState(() {
    messages.add({"text": text, "isUser": true});
    showUserButton = false;
    typing = true;
  });

  final res = await http.post(
    Uri.parse("https://ai-backend-kkt7.onrender.com/chat"),
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({"mode": widget.mode, "history": messages, "userName": widget.userName,}),
  );

  final data = jsonDecode(res.body);

  setState(() {
    typing = false;

    messages.add({
      "text": data["reply"],
      "links": data["links"],
      "isUser": false,
    });

    /// 👉 ΜΟΝΟ ο server αποφασίζει
    showUserButton = data["showButton"] == true;
  });

  scrollToBottom();
  }

  /// ✅ SEND RECOMMEND + μήνυμα συνέχισης
  Future<void> sendRecommend() async {
  setState(() {
    showUserButton = false;
    typing = true;

  });

  final res = await http.post(
    Uri.parse("https://ai-backend-kkt7.onrender.com/chat"),
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({
  "mode": widget.mode,
  "history": messages,
  "askOptions": true,
  "username": widget.userName ?? ""
}),
  );

  final data = jsonDecode(res.body);

  setState(() {
    typing = false;

    messages.add({
      "text": data["reply"],
      "links": data["links"],
      "isUser": false,
    });

    messages.add({
      "text":
          "Αν δεν βρήκες ακριβώς αυτό που θέλεις, πες μου λίγες λεπτομέρειες ακόμη και συνεχίζουμε μαζί μέχρι να βρούμε το ιδανικό 👌",
      "isUser": false,
    });
  });

  scrollToBottom();

  }

  void openLink(String url) async {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  String getTitle() {
    if (widget.mode == "shopping") return "Αγορές";
    if (widget.mode == "travel") return "Διακοπές";
    if (widget.mode == "services") return "Επαγγελματίες";
    return "GorealAI";
  }

  Widget buildBubble(Map<String, dynamic> msg) {
    final isUser = msg["isUser"] == true;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: BoxDecoration(
          color: isUser ? Colors.green : Colors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white10),
        ),
        child: Text(
          msg["text"] ?? "",
          style: const TextStyle(fontSize: 15, height: 1.35),
        ),
      ),
    );
  }

  Widget buildTyping() {
    return const Padding(
      padding: EdgeInsets.all(12),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 10),
          Text("Γράφει...", style: TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }

  Widget buildLinks(List links) {
  return Column(
    children: links.map<Widget>((l) {
      return _AnimatedLinkCard(
        title: l["title"],
        url: l["url"],
        onTap: () => openLink(l["url"]),
      );
    }).toList(),
  );
}

  Widget buildInputBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.9),
        border: const Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              style: const TextStyle(fontSize: 15),
              decoration: InputDecoration(
                hintText: "Γράψε μήνυμα…",
                filled: true,
                fillColor: Colors.white.withOpacity(0.06),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (t) {
                if (t.trim().isEmpty) return;
                sendMessage(t.trim());
                controller.clear();
              },
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () {
              final t = controller.text.trim();
              if (t.isEmpty) return;
              sendMessage(t);
              controller.clear();
            },
            child: Container(
              width: 46,
              height: 46,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.arrow_upward, color: Colors.black),
            ),
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(getTitle())),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: scrollController,
              itemCount: messages.length + (typing ? 1 : 0),
              itemBuilder: (_, i) {
                if (i >= messages.length) return buildTyping();

                final msg = messages[i];

                if (msg["links"] != null) {
                  return buildLinks(msg["links"]);
                }

                return buildBubble(msg);
              },
            ),
          ),

          if (showUserButton)
            Padding(
              padding: const EdgeInsets.all(12),
              child: ElevatedButton(
                onPressed: sendRecommend,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text("Δείξε επιλογές"),
              ),
            ),
            buildInputBar(),
        ],
      ),
    );
  }
}
class _AnimatedLinkCard extends StatefulWidget {
  final String title;
  final String url;
  final VoidCallback onTap;

  const _AnimatedLinkCard({
    required this.title,
    required this.url,
    required this.onTap,
  });

  @override
  State<_AnimatedLinkCard> createState() => _AnimatedLinkCardState();
}

class _AnimatedLinkCardState extends State<_AnimatedLinkCard> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        transform: Matrix4.identity()
          ..scale(hover ? 1.03 : 1.0)
          ..translate(0.0, hover ? -2.0 : 0.0),

        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: LinearGradient(
            colors: hover
                ? [
                    Colors.white.withOpacity(0.12),
                    Colors.white.withOpacity(0.05),
                  ]
                : [
                    Colors.white.withOpacity(0.06),
                    Colors.white.withOpacity(0.02),
                  ],
          ),
          boxShadow: hover
              ? [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.35),
                    blurRadius: 18,
                    offset: const Offset(0, 10),
                  ),
                ]
              : [],
        ),

        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.open_in_new,
                    color: Colors.amber,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
class WelcomeGlowText extends StatefulWidget {
  final String name;

  const WelcomeGlowText({super.key, required this.name});

  @override
  State<WelcomeGlowText> createState() => _WelcomeGlowTextState();
}

class _WelcomeGlowTextState extends State<WelcomeGlowText>
    with SingleTickerProviderStateMixin {
  late AnimationController controller;
  late Animation<double> glow;

  @override
  void initState() {
    super.initState();

    controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    glow = Tween<double>(begin: 0.2, end: 1.0).animate(
      CurvedAnimation(parent: controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: glow,
      builder: (_, __) {
        return Padding(
  padding: const EdgeInsets.only(left: 24),
  child: Text(
    "Welcome back, ${widget.name}",
    textAlign: TextAlign.left,
    style: TextStyle(
      fontSize: 34,
      fontWeight: FontWeight.w700,
      color: Colors.white,
      shadows: [
        Shadow(
          blurRadius: 20 * glow.value,
          color: Colors.orangeAccent.withOpacity(glow.value),
        ),
        Shadow(
          blurRadius: 40 * glow.value,
          color: Colors.deepOrange.withOpacity(glow.value * 0.7),
        ),
      ],
    ),
  ),
);
      },
    );
  }
}