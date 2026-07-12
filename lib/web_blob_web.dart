// Έκδοση για Flutter Web — χρησιμοποιεί dart:html για ανάγνωση blob: URLs.
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:firebase_storage/firebase_storage.dart';

Future<Uint8List> fetchArrayBuffer(String url) async {
  final req = await html.HttpRequest.request(url, responseType: 'arraybuffer');
  return (req.response as ByteBuffer).asUint8List();
}

Future<void> uploadBlobUrl(String url, Reference ref, String contentType) async {
  final req = await html.HttpRequest.request(url, responseType: 'blob');
  await ref.putBlob(req.response, SettableMetadata(contentType: contentType));
}
