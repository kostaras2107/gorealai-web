// Έκδοση για Flutter Web — κάνει embed ένα βίντεο TikTok μέσα σε iframe,
// χρησιμοποιώντας τον επίσημο TikTok Embed Player
// (https://developers.tiktok.com/doc/embed-player), όχι το παλιό ανεπίσημο
// /embed/v2/{id} που δεν κρατούσε σωστά την αναλογία διαστάσεων του βίντεο
// (έκοβε το πλάνο). Δεν χρειάζεται OAuth ή έγκριση, μόνο το βίντεο public.
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';

final Set<String> _registeredViewTypes = {};

Widget buildTikTokEmbed(String videoId, {bool muted = true}) {
  // Το muted μπαίνει στο viewType key γιατί το registerViewFactory γίνεται
  // ΜΙΑ φορά ανά viewType (η επόμενη κλήση με το ίδιο key αγνοείται) — αν
  // δεν το ξεχώριζε, η πρώτη τιμή muted που φτιάχτηκε θα "κολλούσε" για
  // πάντα σε αυτό το videoId.
  final viewType = 'tiktok-embed-$videoId-$muted';
  if (!_registeredViewTypes.contains(viewType)) {
    _registeredViewTypes.add(viewType);
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int viewId) {
      // autoplay=1 πάντα· muted μόνο όταν ζητηθεί ρητά (π.χ. background
      // preview) — το ενεργό/κεντρικό βίντεο παίζει με ήχο.
      final iframe = html.IFrameElement()
        ..src = 'https://www.tiktok.com/player/v1/$videoId?autoplay=1&muted=${muted ? 1 : 0}'
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%'
        ..allowFullscreen = true;
      iframe.setAttribute('allow', 'fullscreen; autoplay');
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
