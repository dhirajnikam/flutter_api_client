import 'schema.dart';

/// Example request payload for an endpoint.
class RequestExample {
  /// Creates a request example.
  const RequestExample({
    this.body,
    this.schema,
    this.headers = const {},
    this.description,
  });

  /// Example body value (typically a JSON-encodable [Map]).
  final Object? body;

  /// Schema the request body is validated against by the mock adapter.
  final Schema? schema;

  /// Example request headers.
  final Map<String, String> headers;

  /// Optional prose description.
  final String? description;
}

/// Example response for an endpoint.
class ResponseExample {
  /// Creates a response example for [statusCode]. See the named factories
  /// ([ok], [created], [noContent], [error]) for common cases.
  const ResponseExample({
    required this.statusCode,
    this.body,
    this.schema,
    this.headers = const {'content-type': 'application/json'},
    this.description,
  });

  /// HTTP status code of this example response.
  final int statusCode;

  /// Example body value (typically a JSON-encodable [Map]).
  final Object? body;

  /// Schema describing the response body.
  final Schema? schema;

  /// Response headers; defaults to `application/json`.
  final Map<String, String> headers;

  /// Optional prose description.
  final String? description;

  /// Whether [statusCode] is in the 2xx range.
  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  /// A `200 OK` response carrying [body].
  factory ResponseExample.ok(
    Object? body, {
    Schema? schema,
    String? description,
  }) =>
      ResponseExample(
        statusCode: 200,
        body: body,
        schema: schema,
        description: description,
      );

  /// A `201 Created` response carrying [body].
  factory ResponseExample.created(
    Object? body, {
    Schema? schema,
    String? description,
  }) =>
      ResponseExample(
        statusCode: 201,
        body: body,
        schema: schema,
        description: description,
      );

  /// A `204 No Content` response with no body.
  factory ResponseExample.noContent({String? description}) =>
      ResponseExample(statusCode: 204, description: description);

  /// An error response with the given [statusCode] and [body].
  factory ResponseExample.error(
    int statusCode,
    Object body, {
    Schema? schema,
    String? description,
  }) =>
      ResponseExample(
        statusCode: statusCode,
        body: body,
        schema: schema,
        description: description,
      );
}
