// Έκδοση για Flutter Web — κάνει embed ένα βίντεο TikTok μέσα σε iframe,
// χρησιμοποιώντας τον επίσημο TikTok Embed Player
// (https://developers.tiktok.com/doc/embed-player), όχι το παλιό ανεπίσημο
// /embed/v2/{id} που δεν κρατούσε σωστά την αναλογία διαστάσεων του βίντεο
// (έκοβε το πλάνο). Δεν χρειάζεται OAuth ή έγκριση, μόνο το βίντεο public.
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';

final Set<String> _registeredViewTypes = {};

Widget buildTikTokEmbed(String videoId) {
  final viewType = 'tiktok-embed-$videoId';
  if (!_registeredViewTypes.contains(viewType)) {
    _registeredViewTypes.add(viewType);
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int viewId) {
      final iframe = html.IFrameElement()
        ..src = 'https://www.tiktok.com/player/v1/$videoId'
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%'
        ..allowFullscreen = true;
      iframe.setAttribute('allow', 'fullscreen');
      return iframe;
    });
  }
  // Το TikTok player είναι σχεδιασμένο για κάθετη αναλογία ~9:16 — το
  // τυλίγουμε σε AspectRatio ώστε να μην κόβεται ποτέ το βίντεο, ό,τι
  // διαστάσεις κι αν έχει ο γονικός χώρος.
  return AspectRatio(
    aspectRatio: 9 / 16,
    child: HtmlElementView(viewType: viewType),
  );
}
