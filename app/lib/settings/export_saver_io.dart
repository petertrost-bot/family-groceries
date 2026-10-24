import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Rect;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

Future<String?> saveExport(String fileName, String json, {Rect? origin}) async {
  final bytes = Uint8List.fromList(utf8.encode(json));
  if (Platform.isIOS || Platform.isAndroid) {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(bytes, mimeType: 'application/json')],
        fileNameOverrides: [fileName],
        // iPad anchors the share popover here.
        sharePositionOrigin: origin,
      ),
    );
    return null;
  }
  final dir = await getDownloadsDirectory() ?? await getTemporaryDirectory();
  final file = File('${dir.path}${Platform.pathSeparator}$fileName');
  await file.writeAsBytes(bytes);
  return file.path;
}
