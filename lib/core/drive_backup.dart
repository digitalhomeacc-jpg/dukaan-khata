import 'dart:convert';

import 'package:http/http.dart' as http;

/// Result of the Drive backup script (tool/drive_backup.gs, deployed as a web app).
class DriveBackupResult {
  final String file;
  final int rows;
  final Map<String, int> tables; // rows per table in the backup
  DriveBackupResult(this.file, this.rows, this.tables);
}

/// Asks the shop's Google script to take a backup now and say what it saved.
Future<DriveBackupResult> runDriveBackup(String url) async {
  final r = await http.get(Uri.parse(url)).timeout(const Duration(minutes: 3));
  if (r.statusCode != 200) throw Exception('Drive backup: HTTP ${r.statusCode}');
  final Map<String, dynamic> j;
  try {
    j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  } on FormatException {
    // usually a Google sign-in page: the web app's access isn't "Anyone"
    throw Exception('Drive backup: the link did not answer like the backup script. Check that the script is deployed as a web app with access "Anyone".');
  }
  if (j['ok'] != true) throw Exception('Drive backup: ${j['error']}');
  final shop = (j['shops'] as List).first as Map<String, dynamic>;
  return DriveBackupResult(
    shop['file'] as String,
    (shop['rows'] as num).toInt(),
    {for (final e in (shop['tables'] as Map<String, dynamic>).entries) e.key: (e.value as num).toInt()},
  );
}
