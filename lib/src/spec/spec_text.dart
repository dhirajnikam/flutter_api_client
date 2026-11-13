import 'dart:convert';

import 'api_spec.dart';
import 'examples.dart';

/// Standard reason phrases for the status codes the generators describe.
const reasonPhrases = <int, String>{
  200: 'OK',
  201: 'Created',
  204: 'No Content',
  400: 'Bad Request',
  401: 'Unauthorized',
  403: 'Forbidden',
  404: 'Not Found',
  422: 'Unprocessable Entity',
  500: 'Internal Server Error',
};

const _noContent = [ResponseExample(statusCode: 204)];

/// The responses [ep] declares, or a lone `204 No Content` when it declares
/// none — the mock, the OpenAPI document and the backend guide must all agree
/// on what an endpoint without responses returns.
List<ResponseExample> responsesOrNoContent(EndpointSpec ep) =>
    ep.responses.isEmpty ? _noContent : ep.responses;

const _indented = JsonEncoder.withIndent('  ');

/// Encodes [value] as two-space-indented JSON.
String prettyJson(Object? value) => _indented.convert(value);

/// Groups the endpoints of [spec] by tag in declaration order; untagged
/// endpoints fall under `General`.
Map<String, List<EndpointSpec>> endpointsByTag(ApiSpec spec) {
  final byTag = <String, List<EndpointSpec>>{};
  for (final ep in spec.endpoints) {
    byTag.putIfAbsent(ep.tag ?? 'General', () => []).add(ep);
  }
  return byTag;
}
