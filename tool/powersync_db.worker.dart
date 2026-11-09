// Compiles the PowerSync web worker against this app's exact package versions:
//   dart compile js -O4 -o web/powersync_db.worker.js tool/powersync_db.worker.dart
export 'package:powersync/web_worker.dart' show main;
