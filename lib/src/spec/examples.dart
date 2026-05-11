import 'schema.dart';

/// Example request payload for an endpoint.
class RequestExample {
  const RequestExample({
    this.body,
    this.schema,
    this.headers = const {},
    this.description,
  });

  final Object? body;
  final Schema? schema;
  final Map<String, String> headers;
  final String? description;
}

/// Example response for an endpoint.
class ResponseExample {
  const ResponseExample({
    required this.statusCode,
    this.body,
    this.schema,
    this.headers = const {'content-type': 'application/json'},
    this.description,
  });

  final int statusCode;
  final Object? body;
  final Schema? schema;
  final Map<String, String> headers;
  final String? description;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  factory ResponseExample.ok(
    Object? body, {
    Schema? schema,
    String? description,
  }) => ResponseExample(
    statusCode: 200,
    body: body,
    schema: schema,
    description: description,
  );

  factory ResponseExample.created(
    Object? body, {
    Schema? schema,
    String? description,
  }) => ResponseExample(
    statusCode: 201,
    body: body,
    schema: schema,
    description: description,
  );

  factory ResponseExample.noContent({String? description}) =>
      ResponseExample(statusCode: 204, description: description);

  factory ResponseExample.error(
    int statusCode,
    Object body, {
    Schema? schema,
    String? description,
  }) => ResponseExample(
    statusCode: statusCode,
    body: body,
    schema: schema,
    description: description,
  );
}
