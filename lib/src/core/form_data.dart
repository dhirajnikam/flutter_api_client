import 'package:http/http.dart' as http;

/// Lightweight helper for building multipart form data.
class FormData {
  FormData._(this.fields, this.files);

  final Map<String, String> fields;
  final List<http.MultipartFile> files;

  /// Builds [FormData] from a flat map.
  ///
  /// Values that are [http.MultipartFile] (or `List<http.MultipartFile>`)
  /// are sent as file parts. Everything else is `toString()`-ed.
  factory FormData.fromMap(Map<String, dynamic> map) {
    final fields = <String, String>{};
    final files = <http.MultipartFile>[];
    map.forEach((key, value) {
      if (value == null) return;
      if (value is http.MultipartFile) {
        files.add(value);
      } else if (value is List<http.MultipartFile>) {
        files.addAll(value);
      } else if (value is List) {
        for (var i = 0; i < value.length; i++) {
          fields['$key[$i]'] = '${value[i]}';
        }
      } else {
        fields[key] = '$value';
      }
    });
    return FormData._(fields, files);
  }

  bool get isEmpty => fields.isEmpty && files.isEmpty;
  bool get isNotEmpty => !isEmpty;
}
