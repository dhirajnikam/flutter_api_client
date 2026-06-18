import 'dart:convert';

import 'package:crypto/crypto.dart';

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

  /// Hashes a query document for APQ. Defaults to the SHA-256 hex digest the
  /// APQ protocol requires, so the persisted-query fast path can actually
  /// match a server-registered document. Override only for a custom registry.
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
      if (!firstAttempt.errors.any(_isPersistedQueryMiss)) return firstAttempt;
      // APQ cache miss: resend the full document AND the hash so the server
      // registers it for future requests. Sending the document without the
      // hash would defeat APQ entirely — every subsequent call would miss and
      // pay the round-trip again.
      return _post<T>(
        payload: {
          ..._buildPayload(
            document: document,
            variables: variables,
            operationName: operationName,
          ),
          'extensions': {
            'persistedQuery': {'version': 1, 'sha256Hash': hash},
          },
        },
        decoder: decoder,
        options: options,
        includeToken: includeToken,
      );
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

  /// True when a GraphQL error signals an APQ cache miss that must be retried
  /// with the full document. Per the APQ protocol the canonical signal lives in
  /// `extensions.code` (`PERSISTED_QUERY_NOT_FOUND` /
  /// `PERSISTED_QUERY_NOT_SUPPORTED`); many servers also echo it in the message
  /// (`PersistedQueryNotFound` / `PersistedQueryNotSupported`). Accept both so
  /// the fast path falls back instead of surfacing a spurious failure.
  static bool _isPersistedQueryMiss(GraphQLError e) {
    final code = e.extensions?['code']?.toString();
    if (code == 'PERSISTED_QUERY_NOT_FOUND' ||
        code == 'PERSISTED_QUERY_NOT_SUPPORTED') {
      return true;
    }
    final msg = e.message;
    return msg == 'PersistedQueryNotFound' ||
        msg == 'PersistedQueryNotSupported';
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
    // For non-2xx HTTP responses, body lives in HttpError.body. Guard the cast:
    // a non-object error body (List/scalar/text) is not a GraphQL envelope, so
    // treat it as "no envelope" rather than throwing a TypeError out of _post.
    final errorBody =
        raw.error is HttpError ? (raw.error as HttpError).body : null;
    final body =
        raw.data ?? (errorBody is Map<String, dynamic> ? errorBody : null);
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
        try {
          data = dataRaw as T?;
        } on TypeError catch (e, st) {
          // No decoder supplied and the raw `data` field does not match the
          // requested `T`. Surface a typed ParseError instead of letting a
          // TypeError escape `query`/`mutation`, which would violate their
          // contract of always returning a GraphQLResponse.
          return GraphQLResponse<T>(
            statusCode: raw.statusCode ?? 0,
            data: null,
            errors: errors,
            isSuccess: false,
            networkError: ParseError(
              'GraphQL `data` could not be cast to the expected type. '
              'Supply a `decoder` for non-primitive types.',
              cause: e,
              stackTrace: st,
            ),
          );
        }
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

/// SHA-256 hex digest of the query document — the hash APQ servers key their
/// document registry by, so the persisted-query fast path can match.
String _defaultHash(String document) =>
    sha256.convert(utf8.encode(document)).toString();
