import 'dart:convert';

import '../core/api_client.dart';
import '../core/api_exception.dart';
import '../core/request_options.dart';
import 'graphql_error.dart';
import 'graphql_response.dart';

/// Decoder applied to the top-level `data` field.
typedef GraphQLDecoder<T> = T Function(Object data);

/// GraphQL client built on top of [ApiClient].
///
/// Issues operations as `POST {endpoint}` with the standard GraphQL
/// payload `{query, variables, operationName}`. Parses the standard
/// response envelope `{data, errors, extensions}` and exposes it as a
/// typed [GraphQLResponse].
///
/// Persisted queries (APQ) are supported via [usePersistedQueries]. When
/// enabled the client first sends just `{extensions: {persistedQuery: ...}}`
/// and falls back to a full request on `PersistedQueryNotFound`.
class GraphQLClient {
  GraphQLClient(
    this.client, {
    this.endpoint = '/graphql',
    this.usePersistedQueries = false,
    this.hashQuery,
  });

  /// Underlying HTTP client.
  final ApiClient client;

  /// Path appended to the client's base URL. Defaults to `/graphql`.
  final String endpoint;

  /// Enable Automatic Persisted Queries.
  final bool usePersistedQueries;

  /// Hashes a query document for APQ. Defaults to a simple length+codepoint
  /// hash — replace with SHA-256 in user-land for real persisted queries.
  final String Function(String document)? hashQuery;

  Future<GraphQLResponse<T>> query<T>(
    String document, {
    Map<String, dynamic>? variables,
    String? operationName,
    GraphQLDecoder<T>? decoder,
    RequestOptions? options,
    bool includeToken = true,
  }) =>
      _execute<T>(
        document: document,
        variables: variables,
        operationName: operationName,
        decoder: decoder,
        options: options,
        includeToken: includeToken,
      );

  Future<GraphQLResponse<T>> mutation<T>(
    String document, {
    Map<String, dynamic>? variables,
    String? operationName,
    GraphQLDecoder<T>? decoder,
    RequestOptions? options,
    bool includeToken = true,
  }) =>
      _execute<T>(
        document: document,
        variables: variables,
        operationName: operationName,
        decoder: decoder,
        options: options,
        includeToken: includeToken,
      );

  Future<GraphQLResponse<T>> _execute<T>({
    required String document,
    Map<String, dynamic>? variables,
    String? operationName,
    GraphQLDecoder<T>? decoder,
    RequestOptions? options,
    required bool includeToken,
  }) async {
    if (usePersistedQueries) {
      final hashed = await _tryPersisted<T>(
        document: document,
        variables: variables,
        operationName: operationName,
        decoder: decoder,
        options: options,
        includeToken: includeToken,
      );
      if (hashed != null) return hashed;
    }
    return _post<T>(
      payload: _buildPayload(
        document: document,
        variables: variables,
        operationName: operationName,
      ),
      decoder: decoder,
      options: options,
      includeToken: includeToken,
    );
  }

  Future<GraphQLResponse<T>?> _tryPersisted<T>({
    required String document,
    Map<String, dynamic>? variables,
    String? operationName,
    GraphQLDecoder<T>? decoder,
    RequestOptions? options,
    required bool includeToken,
  }) async {
    final hash = (hashQuery ?? _defaultHash)(document);
    final firstAttempt = await _post<T>(
      payload: {
        if (operationName != null) 'operationName': operationName,
        if (variables != null) 'variables': variables,
        'extensions': {
          'persistedQuery': {'version': 1, 'sha256Hash': hash},
        },
      },
      decoder: decoder,
      options: options,
      includeToken: includeToken,
    );
    final needFull = firstAttempt.errors.any(
      (e) => e.message == 'PersistedQueryNotFound',
    );
    return needFull ? null : firstAttempt;
  }

  Map<String, Object?> _buildPayload({
    required String document,
    Map<String, dynamic>? variables,
    String? operationName,
  }) =>
      {
        'query': document,
        if (variables != null) 'variables': variables,
        if (operationName != null) 'operationName': operationName,
      };

  Future<GraphQLResponse<T>> _post<T>({
    required Map<String, Object?> payload,
    GraphQLDecoder<T>? decoder,
    RequestOptions? options,
    required bool includeToken,
  }) async {
    final raw = await client.post<Map<String, dynamic>>(
      endpoint,
      payload,
      includeToken: includeToken,
      options: options,
    );
    if (!raw.isSuccess && (raw.statusCode ?? 0) == 0) {
      return GraphQLResponse<T>(
        statusCode: 0,
        data: null,
        errors: const [],
        isSuccess: false,
        networkError: NetworkError(raw.errorMessage ?? 'transport error'),
      );
    }
    // For non-2xx HTTP responses, body lives in HttpError.body.
    final body = raw.data ??
        (raw.error is HttpError
            ? (raw.error as HttpError).body as Map<String, dynamic>?
            : null);
    if (body == null) {
      return GraphQLResponse<T>(
        statusCode: raw.statusCode ?? 0,
        data: null,
        errors: const [],
        isSuccess: raw.isSuccess,
      );
    }
    final errorsRaw = body['errors'];
    final errors = errorsRaw is List
        ? errorsRaw
            .whereType<Map>()
            .map((m) => GraphQLError.fromJson(m.cast<String, Object?>()))
            .toList()
        : <GraphQLError>[];

    final dataRaw = body['data'];
    T? data;
    if (dataRaw != null) {
      if (decoder != null) {
        try {
          data = decoder(dataRaw as Object);
        } catch (e, st) {
          return GraphQLResponse<T>(
            statusCode: raw.statusCode ?? 0,
            data: null,
            errors: errors,
            isSuccess: false,
            networkError: ParseError(
              'GraphQL decoder failed: $e',
              cause: e,
              stackTrace: st,
            ),
          );
        }
      } else {
        data = dataRaw as T?;
      }
    }

    final extensions = (body['extensions'] as Map?)?.cast<String, Object?>();
    return GraphQLResponse<T>(
      statusCode: raw.statusCode ?? 0,
      data: data,
      errors: errors,
      isSuccess: raw.isSuccess && errors.isEmpty,
      extensions: extensions,
    );
  }
}

/// Default (non-cryptographic) hash. Replace with SHA-256 for production.
String _defaultHash(String document) {
  var h = 0;
  for (final code in utf8.encode(document)) {
    h = (h * 31 + code) & 0xFFFFFFFF;
  }
  return h.toRadixString(16).padLeft(8, '0');
}
