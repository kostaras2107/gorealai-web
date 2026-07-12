// Έκδοση για native πλατφόρμες (Android/iOS) — τα blob: URLs υπάρχουν
// μόνο σε browser context, άρα αυτές οι συναρτήσεις δεν καλούνται ποτέ εκεί
// (ο καλών κώδικας ελέγχει πάντα path.startsWith('blob:') πρώτα).
import 'dart:typed_data';
import 'package:firebase_storage/firebase_storage.dart';

Future<Uint8List> fetchArrayBuffer(String url) async {
  throw UnsupportedError('blob: URLs υποστηρίζονται μόνο στο web');
}

Future<void> uploadBlobUrl(String url, Reference ref, String contentType) async {
  throw UnsupportedError('blob: URLs υποστηρίζονται μόνο στο web');
}
