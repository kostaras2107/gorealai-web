import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

void main() {
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
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

/* ---------------- HOME SCREEN ---------------- */

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Widget bigButton(
      BuildContext context, String text, Color color, Widget screen) {
    return SizedBox(
      width: double.infinity,
      height: 65,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.black,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => screen),
          );
        },
        child: Text(
          text,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
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
            child: IgnorePointer(
              child: Container(color: Colors.black.withOpacity(0.25)),
            ),
          ),
          Positioned(
            bottom: 70,
            left: 25,
            right: 25,
            child: Column(
              children: [
                const SizedBox(height: 40),
                bigButton(
                  context,
                  "🛒 Αγορές",
                  Colors.amber,
                  const ChatScreen(mode: "shopping"),
                ),
                const SizedBox(height: 18),
                bigButton(
                  context,
                  "✈️ Διακοπές",
                  Colors.orange,
                  const ChatScreen(mode: "travel"),
                ),
                const SizedBox(height: 18),
                bigButton(
                  context,
                  "🧑‍🔧👨‍⚕️ Βρες επαγγελματία...",
                  Colors.greenAccent,
                  const ChatScreen(mode: "services"),
                ),
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
  const ChatScreen({super.key, required this.mode});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController controller = TextEditingController();
  final ScrollController scrollController = ScrollController();

  List<Map<String, dynamic>> messages = [];
  bool showUserButton = false;

  void scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (scrollController.hasClients) {
        scrollController.animateTo(
          scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> sendMessage(String text) async {
    setState(() {
      messages.add({"text": text, "isUser": true});
    });

    scrollToBottom();

    final response = await http.post(
      Uri.parse("https://ai-backend-kkt7.onrender.com/chat"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "mode": widget.mode,
        "history": messages,
      }),
    );

    final data = jsonDecode(response.body);

    setState(() {
      messages.add({
        "text": data["reply"],
        "links": data["links"],
        "isUser": false,
      });

      // 🔹 ΔΥΝΑΜΙΚΟ ΚΟΥΜΠΙ από server
      showUserButton = data["showButton"] == true;
    });

    scrollToBottom();
  }

  Future<void> sendRecommend() async {
    final response = await http.post(
      Uri.parse("https://ai-backend-kkt7.onrender.com/chat"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "mode": widget.mode,
        "history": messages,
        "askOptions": true,
      }),
    );

    final data = jsonDecode(response.body);

    setState(() {
      messages.add({
        "text": data["reply"],
        "links": data["links"],
        "isUser": false,
      });

      // 🔹 παραμένει δυναμικό
      showUserButton = data["showButton"] == true;
    });

    scrollToBottom();
  }

  void openLink(String url) async {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  void copyText(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Αντιγράφηκε")),
    );
  }

  String getTitle() {
    if (widget.mode == "shopping") return "Αγορές";
    if (widget.mode == "travel") return "Διακοπές";
    if (widget.mode == "services") return "Επαγγελματίες";
    return "GorealAI";
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
              itemCount: messages.length,
              itemBuilder: (_, i) {
                final msg = messages[i];
                final isUser = msg["isUser"] == true;

                if (msg["links"] != null) {
                  return Column(
                    children: (msg["links"] as List).map((link) {
                      return Card(
                        color: Colors.grey[900],
                        margin: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        child: ListTile(
                          title: Text(link["title"]),
                          trailing: const Icon(Icons.open_in_new,
                              color: Colors.amber),
                          onTap: () => openLink(link["url"]),
                        ),
                      );
                    }).toList(),
                  );
                }

                return GestureDetector(
                  onLongPress: () => copyText(msg["text"] ?? ""),
                  child: Align(
                    alignment:
                        isUser ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.all(10),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: isUser ? Colors.green : Colors.grey[850],
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        msg["text"] ?? "",
                        style: const TextStyle(
                            color: Colors.white, fontSize: 16),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

          if (showUserButton)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: sendRecommend,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amber,
                    foregroundColor: Colors.black,
                  ),
                  child: const Text("Βρες το καλύτερο για μένα"),
                ),
              ),
            ),

          Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    onSubmitted: (text) {
                      final t = text.trim();
                      if (t.isEmpty) return;
                      sendMessage(t);
                      controller.clear();
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send, color: Colors.green),
                  onPressed: () {
                    final text = controller.text.trim();
                    if (text.isEmpty) return;
                    sendMessage(text);
                    controller.clear();
                  },
                )
              ],
            ),
          )
        ],
      ),
    );
  }
}