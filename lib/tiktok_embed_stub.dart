// Μη-web πλατφόρμες (Android/iOS) — κάνει embed το βίντεο TikTok μέσω ενός
// πραγματικού native WebView (webview_flutter) που φορτώνει τον επίσημο
// TikTok Embed Player, ώστε η προεπισκόπηση/fullscreen αναπαραγωγή να
// δουλεύει το ίδιο με το web (εκεί χρησιμοποιείται iframe — δες
// tiktok_embed_web.dart).
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

Widget buildTikTokEmbed(String videoId) => _TikTokWebViewEmbed(videoId: videoId);

class _TikTokWebViewEmbed extends StatefulWidget {
  final String videoId;
  const _TikTokWebViewEmbed({required this.videoId});
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
      ..setBackgroundColor(Colors.black)
      // autoplay=1&muted=1 — παίζει αυτόματα σαν "ζωντανή" προεπισκόπηση·
      // muted είναι υποχρεωτικό ώστε να επιτρέπεται το autoplay.
      ..loadRequest(Uri.parse(
          'https://www.tiktok.com/player/v1/${widget.videoId}?autoplay=1&muted=1'));
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
