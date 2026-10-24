import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/widgets.dart' show Rect;
import 'package:web/web.dart' as web;

Future<String?> saveExport(String fileName, String json, {Rect? origin}) async {
  final blob = web.Blob(
    [json.toJS].toJS,
    web.BlobPropertyBag(type: 'application/json'),
  );
  final url = web.URL.createObjectURL(blob);
  web.HTMLAnchorElement()
    ..href = url
    ..download = fileName
    ..click();
  // Revoking right after the click can cancel the download in some browsers.
  Timer(const Duration(minutes: 1), () => web.URL.revokeObjectURL(url));
  return null;
}
