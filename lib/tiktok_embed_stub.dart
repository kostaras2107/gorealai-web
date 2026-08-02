// Μη-web πλατφόρμες (Android/iOS) — κάνει embed το βίντεο TikTok μέσω ενός
// πραγματικού native WebView (webview_flutter) που φορτώνει τον επίσημο
// TikTok Embed Player, ώστε η προεπισκόπηση/fullscreen αναπαραγωγή να
// δουλεύει το ίδιο με το web (εκεί χρησιμοποιείται iframe — δες
// tiktok_embed_web.dart).
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

Widget buildTikTokEmbed(String videoId, {bool muted = true}) =>
    _TikTokWebViewEmbed(videoId: videoId, muted: muted);

class _TikTokWebViewEmbed extends StatefulWidget {
  final String videoId;
  final bool muted;
  const _TikTokWebViewEmbed({required this.videoId, required this.muted});
  @override
  State<_TikTokWebViewEmbed> createState() => _TikTokWebViewEmbedState();
}

class _TikTokWebViewEmbedState extends State<_TikTokWebViewEmbed> {
  late final WebViewController _controller;

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
    _controller.loadRequest(Uri.parse(
        'https://www.tiktok.com/player/v1/${widget.videoId}?autoplay=1&muted=${widget.muted ? 1 : 0}'));
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
