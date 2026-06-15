#!/usr/bin/env python3
"""
Fix main.dart structural issues:
1. Remove firebase_crashlytics import
2. Remove duplicate kBackendUrl
3. Fix orphaned NotificationService class header
4. Fix InAppNotifOverlay (add class declarations)
5. Add ChatScreen class
"""
import sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

MAIN = r"C:\shoppilot\lib\main.dart"
OUT = r"C:\shoppilot\lib\main_fixed.dart"

with open(MAIN, encoding='utf-8', errors='replace') as f:
    content = f.read()

original_len = len(content.split('\n'))
print(f"Original file: {original_len} lines")

# ── Fix 1: Remove firebase_crashlytics import ──
content = content.replace(
    "import 'package:firebase_crashlytics/firebase_crashlytics.dart';\n",
    ""
)

# ── Fix 2: Remove duplicate kBackendUrl ──
# Original has:
# const String kBackendUrl = 'https://ai-backend-kkt7.onrender.com';
# // Replace with your actual Stripe monthly subscription price ID from dashboard.stripe.com
# const String kBackendUrl = 'https://ai-backend-kkt7.onrender.com';
# // Replace with your actual Stripe monthly subscription price ID from dashboard.stripe.com
content = content.replace(
    "const String kBackendUrl = 'https://ai-backend-kkt7.onrender.com';\n// Replace with your actual Stripe monthly subscription price ID from dashboard.stripe.com\n" * 2,
    "const String kBackendUrl = 'https://ai-backend-kkt7.onrender.com';\n"
)

# ── Fix 3: Fix orphaned NotificationService class header ──
# Current:
# // ═══════════════════════════════════════
# class NotificationService {
# // ═══════════════════════════════════════
# class NotificationService {
content = content.replace(
    "// ═══════════════════════════════════════\nclass NotificationService {\n// ═══════════════════════════════════════\nclass NotificationService {",
    "// ═══════════════════════════════════════\n// FCM PUSH NOTIFICATION SERVICE\n// ═══════════════════════════════════════\nclass NotificationService {"
)

# ── Fix 4: Fix InAppNotifOverlay section ──
# Current broken content after comment header:
old_notif_broken = """// ═══════════════════════════════════════
// IN-APP PUSH NOTIFICATION OVERLAY
// ═══════════════════════════════════════
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
}"""

new_notif_fixed = """// ═══════════════════════════════════════
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
}"""

if old_notif_broken in content:
    content = content.replace(old_notif_broken, new_notif_fixed)
    print("✓ Fixed InAppNotifOverlay section")
else:
    print("⚠ Could not find broken InAppNotifOverlay section - checking alternative...")
    # Try to find just the broken part
    if "IN-APP PUSH NOTIFICATION OVERLAY" in content:
        idx = content.index("IN-APP PUSH NOTIFICATION OVERLAY")
        print(f"  Found at char {idx}")
        print(f"  Context: {content[idx-50:idx+200]}")

# ── Fix 5: Add ChatScreen class at end of file (before last few lines) ──
chatscreen_code = '''
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
'''

# Add ChatScreen before the end of file if not present
if 'class ChatScreen' not in content:
    # Find a good insertion point - after MessagesScreen ends
    # Look for ReminderService or another anchor
    # For now, append at the end (before any trailing content)
    if content.endswith('\n'):
        content = content.rstrip('\n') + '\n' + chatscreen_code + '\n'
    else:
        content = content + '\n' + chatscreen_code + '\n'
    print("✓ Added ChatScreen class")
else:
    print("! ChatScreen already exists")

# Count fixes
new_len = len(content.split('\n'))
print(f"\nFixed file: {new_len} lines (was {original_len})")

# Write output
with open(OUT, 'w', encoding='utf-8') as f:
    f.write(content)

print(f"Written to: {OUT}")

# Verify fixes
print("\n=== Verification ===")
checks = [
    ("firebase_crashlytics", "crashlytics import removed"),
    ("kBackendUrl = 'https://ai-backend-kkt7.onrender.com';\nconst String kBackendUrl", "duplicate kBackendUrl STILL exists"),
]
for check, label in checks:
    if check in content:
        print(f"  ✗ ISSUE: {label}")
    else:
        print(f"  ✓ OK: {label}")

# Count remaining class ChatScreen references
import re
occurrences = [m.start() for m in re.finditer(r'class ChatScreen\b', content)]
print(f"  class ChatScreen occurrences: {len(occurrences)}")
occurrences_notif = [m.start() for m in re.finditer(r'class InAppNotifOverlay\b', content)]
print(f"  class InAppNotifOverlay occurrences: {len(occurrences_notif)}")
