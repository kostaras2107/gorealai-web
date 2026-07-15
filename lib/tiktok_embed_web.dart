// Έκδοση για Flutter Web — κάνει embed ένα βίντεο TikTok μέσα σε iframe,
// χρησιμοποιώντας το επίσημο, δημόσιο https://www.tiktok.com/embed/v2/{id}
// (δεν χρειάζεται OAuth ή έγκριση από το TikTok, μόνο το βίντεο να είναι public).
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';

final Set<String> _registeredViewTypes = {};

Widget buildTikTokEmbed(String videoId) {
  final viewType = 'tiktok-embed-$videoId';
  if (!_registeredViewTypes.contains(viewType)) {
    _registeredViewTypes.add(viewType);
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int viewId) {
      return html.IFrameElement()
        ..src = 'https://www.tiktok.com/embed/v2/$videoId'
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%'
        ..allowFullscreen = true;
    });
  }
  return HtmlElementView(viewType: viewType);
}
