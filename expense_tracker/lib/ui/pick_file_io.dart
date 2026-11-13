import 'package:file_picker/file_picker.dart';

import 'pick_file.dart';

/// Android / iOS app: the system file picker.
Future<PickedFile?> pickFile() async {
  final files = await FilePicker.pickFiles(type: FileType.any);
  if (files.isEmpty) return null;
  final f = files.first;
  return (name: f.name, bytes: await f.readAsBytes());
}
