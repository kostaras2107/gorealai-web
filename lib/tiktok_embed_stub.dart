// Μη-web πλατφόρμες (Android/iOS) — κάνει embed το βίντεο TikTok μέσω ενός
// πραγματικού native WebView (webview_flutter) που φορτώνει τον επίσημο
// TikTok Embed Player, ώστε η προεπισκόπηση/fullscreen αναπαραγωγή να
// δουλεύει το ίδιο με το web (εκεί χρησιμοποιείται iframe — δες
// tiktok_embed_web.dart).
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

Widget buildTikTokEmbed(String videoId, {bool muted = true}) =>
    _TikTokWebViewEmbed(videoId: videoId, muted: muted);

// Στέλνεται στο ίδιο το window του player — μιμείται το επίσημο TikTok
// Player SDK postMessage API (developers.tiktok.com/doc/embed-player),
// για την περίπτωση που ο player ακούει events σε αυτό αντί για απευθείας
// χειρισμό του media element. Τρέχει ΚΑΙ τα δύο, επαναληπτικά, γιατί το
// element μπορεί να μπει στο DOM με καθυστέρηση ή ο player να το ξανα-κάνει
// muted μόνος του μετά το πρώτο unmute. Καλύπτει ΚΑΙ <video> (κανονικό
// βίντεο) ΚΑΙ <audio> (TikTok "photo mode" — carousel φωτογραφιών με
// μουσική· δεν έχει καθόλου <video> tag, μόνο <audio>).
const String _unmuteJs = '''
try {
  window.postMessage(JSON.stringify({type: "unMute", value: ""}), "*");
  window.postMessage(JSON.stringify({type: "play", value: ""}), "*");
} catch (e) {}
document.querySelectorAll("video, audio").forEach(function(v){
  v.muted = false;
  v.volume = 1;
  v.play().catch(function(){});
});
''';

class _TikTokWebViewEmbed extends StatefulWidget {
  final String videoId;
  final bool muted;
  const _TikTokWebViewEmbed({required this.videoId, required this.muted});
  @override
  State<_TikTokWebViewEmbed> createState() => _TikTokWebViewEmbedState();
}

class _TikTokWebViewEmbedState extends State<_TikTokWebViewEmbed> {
  late final WebViewController _controller;
  Timer? _unmuteRetryTimer;
  int _unmuteAttempts = 0;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black);
    // Στο Android το native WebView απαιτεί από προεπιλογή χειρονομία
    // χρήστη για να παίξει ήχος — το απενεργοποιούμε ώστε το ενεργό/κεντρικό
    // βίντεο να παίζει αυτόματα ΚΑΙ με ήχο, χωρίς tap.
    if (!widget.muted && defaultTargetPlatform == TargetPlatform.android) {
      (_controller.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false);
    }
    if (!widget.muted) {
      _controller.setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) => _startUnmuteRetries(),
      ));
    }
    _controller.loadRequest(Uri.parse(
        'https://www.tiktok.com/player/v1/${widget.videoId}?autoplay=1&muted=${widget.muted ? 1 : 0}'));
  }

  void _startUnmuteRetries() {
    _unmuteAttempts = 0;
    _unmuteRetryTimer?.cancel();
    _unmuteRetryTimer = Timer.periodic(const Duration(milliseconds: 600), (t) {
      _unmuteAttempts++;
      _controller.runJavaScript(_unmuteJs);
      if (_unmuteAttempts >= 10) t.cancel();
    });
  }

  @override
  void dispose() {
    _unmuteRetryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Ίδιο 9:16 κάθετο aspect ratio με την web έκδοση, ώστε να μην κόβεται
    // ποτέ το βίντεο ό,τι διαστάσεις κι αν έχει ο γονικός χώρος.
    return AspectRatio(
      aspectRatio: 9 / 16,
      child: WebViewWidget(controller: _controller),
    );
  }
}
