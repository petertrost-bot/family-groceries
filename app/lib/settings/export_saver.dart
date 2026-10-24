import 'package:family_groceries/settings/export_saver_io.dart'
    if (dart.library.js_interop) 'package:family_groceries/settings/export_saver_web.dart'
    as platform;
import 'package:flutter/widgets.dart' show Rect;

/// Hands [json] to the user as [fileName]: a download on the web, the share
/// sheet on iOS and Android, a file in Downloads on desktop. Returns the
/// file's path when there is one to show.
typedef ExportSaver = Future<String?> Function(
  String fileName,
  String json, {
  Rect? origin,
});

const ExportSaver platformSaveExport = platform.saveExport;

/// `einkauf-daten-2026-10-24.json`.
String exportFileName(DateTime now) =>
    'einkauf-daten-${now.year}-${_two(now.month)}-${_two(now.day)}.json';

String _two(int n) => n.toString().padLeft(2, '0');
