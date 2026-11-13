import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../client/api_client.dart';
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

  final ApiClient client;

  /// Path appended to the client's base URL. Defaults to `/graphql`.
  final String endpoint;

  /// Enable Automatic Persisted Queries.
  final bool usePersistedQueries;

  /// Hashes a query document for APQ. Defaults to the SHA-256 hex digest the
  /// APQ protocol requires, so the persisted-query fast path can actually
  /// match a server-registered document. Override only for a custom registry.
  final String Function(String document)? hashQuery;

  /// Executes a GraphQL query [document].
  ///
  /// Pass [variables] for the operation, [operationName] when the document
  /// declares more than one operation, and a [decoder] to map the top-level
  /// `data` field to [T] (without one, `data` is cast to [T] directly).
  /// Always completes with a [GraphQLResponse]; transport and decode failures
  /// are reported via [GraphQLResponse.networkError] rather than thrown.
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

  /// Executes a GraphQL mutation [document].
  ///
  /// Behaves exactly like [query] — same parameters, same response contract —
  /// and exists as a separate method only to make call sites read as
  /// mutations.
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
    Future<GraphQLResponse<T>> post({String? document, String? hash}) =>
        _post<T>(
          payload: {
            if (document != null) 'query': document,
            if (variables != null) 'variables': variables,
            if (operationName != null) 'operationName': operationName,
            if (hash != null)
              'extensions': {
                'persistedQuery': {'version': 1, 'sha256Hash': hash},
              },
          },
          decoder: decoder,
          options: options,
          includeToken: includeToken,
        );

    if (!usePersistedQueries) return post(document: document);
    final hash = (hashQuery ?? _defaultHash)(document);
    final hashOnly = await post(hash: hash);
    if (!hashOnly.errors.any(_isPersistedQueryMiss)) return hashOnly;
    // APQ cache miss: resend the full document AND the hash so the server
    // registers it for future requests. Sending the document without the
    // hash would defeat APQ entirely — every subsequent call would miss and
    // pay the round-trip again.
    return post(document: document, hash: hash);
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
    final statusCode = raw.statusCode ?? 0;
    GraphQLResponse<T> failed(
      ApiException error, [
      List<GraphQLError> errors = const [],
    ]) =>
        GraphQLResponse<T>(
          statusCode: statusCode,
          data: null,
          errors: errors,
          isSuccess: false,
          networkError: error,
        );

    if (!raw.isSuccess && statusCode == 0) {
      return failed(raw.error ?? const NetworkError('transport error'));
    }
    // For non-2xx HTTP responses, body lives in HttpError.body. Guard the cast:
    // a non-object error body (List/scalar/text) is not a GraphQL envelope, so
    // treat it as "no envelope" rather than throwing a TypeError out of _post.
    final errorBody =
        raw.error is HttpError ? (raw.error as HttpError).body : null;
    final body =
        raw.data ?? (errorBody is Map<String, dynamic> ? errorBody : null);
    if (body == null) {
      // No GraphQL envelope to parse. If the transport layer produced an
      // error (e.g. a ParseError from a non-JSON body, or an HttpError whose
      // body was not a JSON object), surface it so callers have something to
      // log instead of an empty response that silently drops the cause.
      return GraphQLResponse<T>(
        statusCode: statusCode,
        data: null,
        errors: const [],
        isSuccess: raw.isSuccess,
        networkError: raw.error,
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
      try {
        data = decoder != null ? decoder(dataRaw as Object) : dataRaw as T?;
      } catch (e, st) {
        // Reported rather than thrown: `query`/`mutation` always return a
        // GraphQLResponse.
        return failed(
          ParseError(
            decoder != null
                ? 'GraphQL decoder failed: $e'
                : 'GraphQL `data` could not be cast to the expected type. '
                    'Supply a `decoder` for non-primitive types.',
            cause: e,
            stackTrace: st,
          ),
          errors,
        );
      }
    }

    final extensions = (body['extensions'] as Map?)?.cast<String, Object?>();
    return GraphQLResponse<T>(
      statusCode: statusCode,
      data: data,
      errors: errors,
      isSuccess: raw.isSuccess && errors.isEmpty,
      extensions: extensions,
    );
  }
}

String _defaultHash(String document) =>
    sha256.convert(utf8.encode(document)).toString();
