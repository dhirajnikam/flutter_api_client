/// Marks a top-level [ApiSpec] variable for discovery by `dart run flutter_api_client:gen`.
///
/// Usage:
/// ```dart
/// import 'package:flutter_api_client/flutter_api_client.dart';
///
/// @ApiSpecEntry()
/// final mySpec = ApiSpec(
///   title: 'My API',
///   version: '1.0.0',
///   baseUrl: 'https://api.example.com',
/// );
/// ```
class ApiSpecEntry {
  const ApiSpecEntry();
}
