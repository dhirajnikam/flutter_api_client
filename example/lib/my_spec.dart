import 'package:flutter_api_client/flutter_api_client.dart';

part 'my_spec.g.dart';

@ApiSpecEntry()
final mySpec =
    ApiSpec(
      title: 'Example API',
      version: '1.0.0',
      baseUrl: 'https://dummyjson.com',
    )..group('Users', (g) {
      g.endpoint(
        'GET /users',
        summary: 'List users',
        responses: [
          ResponseExample.ok({'users': [], 'total': 0}),
        ],
      );
      g.endpoint(
        'GET /users/{id}',
        pathParams: {'id': Schema.integer()},
        responses: [
          ResponseExample.ok({'id': 1, 'firstName': 'Alice'}),
        ],
      );
    });
