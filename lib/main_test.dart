import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:math';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'firebase_options.dart';
import 'splash_screen.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

// ═══════════════════════════════════════
const String kBackendUrl = 'https://ai-backend-kkt7.onrender.com';
const String kStripeMonthlyPriceId = 'price_REPLACE_WITH_YOUR_STRIPE_PRICE_ID';
// Όλοι οι χρήστες έχουν δωρεάν πρόσβαση
const bool kFreeForAll = true;
final _analytics = FirebaseAnalytics.instance;
const Color kGold = Color(0xFFFFB340);
const Color kGoldLight = Color(0xFFFFD47A);
const Color kGoldDark = Color(0xFFCC8800);
const Color kBg = Color(0xFF060D1E);
// ═══════════════════════════════════════
// FCM PUSH NOTIFICATION SERVICE

void main() {}
