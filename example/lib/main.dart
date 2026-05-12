import 'package:flutter/material.dart';
import 'package:flutter_api_client/flutter_api_client.dart';

// ---------------------------------------------------------------------------
// Clients — one per base URL so interceptors are scoped correctly.
// ---------------------------------------------------------------------------

/// DummyJSON — supports auth (POST /auth/login returns a real JWT).
final _dummyClient = ApiClient(
  ApiClientConfig(
    baseUrl: 'https://dummyjson.com',
    interceptors: [
      PrettyLogger(useColors: false),
      RetryInterceptor(
        policy: RetryPolicy.exponential(
          maxAttempts: 3,
          baseDelay: const Duration(milliseconds: 300),
        ),
      ),
      CacheInterceptor(
        store: MemoryCacheStore(),
        defaultPolicy: CachePolicy.staleWhileRevalidate(
          const Duration(minutes: 2),
        ),
      ),
    ],
  ),
);

/// JSONPlaceholder — classic fake REST, no auth.
final _jsonPlaceholderClient = ApiClient(
  ApiClientConfig(
    baseUrl: 'https://jsonplaceholder.typicode.com',
    interceptors: [
      PrettyLogger(useColors: false),
      DedupInterceptor(),
      CacheInterceptor(
        store: MemoryCacheStore(),
        defaultPolicy: CachePolicy.cacheFirst(ttl: const Duration(minutes: 5)),
      ),
    ],
  ),
);

/// Dog CEO — great for showing caching/dedup on repeated identical requests.
final _dogClient = ApiClient(
  ApiClientConfig(
    baseUrl: 'https://dog.ceo',
    interceptors: [
      PrettyLogger(useColors: false),
      DedupInterceptor(),
      CacheInterceptor(
        store: MemoryCacheStore(),
        defaultPolicy: CachePolicy.networkFirst(),
      ),
    ],
  ),
);

/// Open Trivia DB — shows query-parameter building and response parsing.
final _triviaClient = ApiClient(
  ApiClientConfig(
    baseUrl: 'https://opentdb.com',
    interceptors: [
      PrettyLogger(useColors: false),
      RetryInterceptor(policy: RetryPolicy.exponential(maxAttempts: 2)),
    ],
  ),
);

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'flutter_api_client demo',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const _HomePage(),
    );
  }
}

class _HomePage extends StatelessWidget {
  const _HomePage();

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('flutter_api_client live demo'),
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'DummyJSON'),
              Tab(text: 'JSONPlaceholder'),
              Tab(text: 'Dog CEO'),
              Tab(text: 'Trivia'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _DummyJsonTab(),
            _JsonPlaceholderTab(),
            _DogTab(),
            _TriviaTab(),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

class _ResultCard extends StatelessWidget {
  const _ResultCard(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SelectableText(
          text,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
        ),
      ),
    );
  }
}

Widget _btn(String label, VoidCallback onPressed) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 4),
  child: ElevatedButton(onPressed: onPressed, child: Text(label)),
);

// ---------------------------------------------------------------------------
// DummyJSON tab — auth flow + products
// ---------------------------------------------------------------------------

class _DummyJsonTab extends StatefulWidget {
  const _DummyJsonTab();
  @override
  State<_DummyJsonTab> createState() => _DummyJsonTabState();
}

class _DummyJsonTabState extends State<_DummyJsonTab> {
  String _out = 'Tap a button';
  bool _loading = false;

  Future<void> _run(Future<String> Function() fn) async {
    setState(() {
      _loading = true;
      _out = 'Loading…';
    });
    final result = await fn().catchError((e) => 'Exception: $e');
    setState(() {
      _out = result;
      _loading = false;
    });
  }

  Future<void> _login() => _run(() async {
    final res = await _dummyClient.post<Map<String, dynamic>>(
      'auth/login',
      const {
        'username': 'emilys',
        'password': 'emilyspass',
        'expiresInMins': 30,
      },
    );
    if (res.isSuccess) {
      final token =
          (res.data?['accessToken'] ?? res.data?['token'] ?? '(none)')
              .toString();
      final short =
          token.length > 40 ? '${token.substring(0, 40)}…' : token;
      return 'Login OK [${res.statusCode}]\ntoken: $short';
    }
    return 'Login failed [${res.statusCode}]: ${res.errorMessage}';
  });

  Future<void> _fetchProducts() => _run(() async {
    final res = await _dummyClient.get<Map<String, dynamic>>(
      'products',
      options: const RequestOptions(queryParameters: {'limit': '5'}),
    );
    if (res.isSuccess) {
      final items = (res.data?['products'] as List?)
              ?.map((p) => '  • ${p['title']}  \$${p['price']}')
              .join('\n') ??
          '(none)';
      return 'Products [${res.statusCode}]:\n$items';
    }
    return 'Error [${res.statusCode}]: ${res.errorMessage}';
  });

  Future<void> _fetchProduct() => _run(() async {
    final res = await _dummyClient.get<Map<String, dynamic>>('products/1');
    if (res.isSuccess) {
      final d = res.data!;
      return 'Product 1 [${res.statusCode}]:\n'
          '  title: ${d['title']}\n'
          '  brand: ${d['brand']}\n'
          '  price: \$${d['price']}';
    }
    return 'Error [${res.statusCode}]: ${res.errorMessage}';
  });

  Future<void> _fetchUserResult() => _run(() async {
    final result = await _dummyClient.get<Map<String, dynamic>>(
      'users/1',
    );
    return result.when(
      success: (data) =>
          'ApiResult.Success [${(result as Success).statusCode}]:\n'
          '  name: ${data['firstName']} ${data['lastName']}\n'
          '  email: ${data['email']}',
      failure: (err) => 'ApiResult.Failure: $err',
    );
  });

  @override
  Widget build(BuildContext context) {
    return _TabLayout(
      description:
          'DummyJSON (dummyjson.com)\n'
          'Auth flow · stale-while-revalidate cache · retry · ApiResult sealed.',
      loading: _loading,
      output: _out,
      buttons: [
        _btn('POST /auth/login', _login),
        _btn('GET /products?limit=5  (cached SWR)', _fetchProducts),
        _btn('GET /products/1', _fetchProduct),
        _btn('GET /users/1  →  ApiResult sealed', _fetchUserResult),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// JSONPlaceholder tab — CRUD + dedup demo
// ---------------------------------------------------------------------------

class _JsonPlaceholderTab extends StatefulWidget {
  const _JsonPlaceholderTab();
  @override
  State<_JsonPlaceholderTab> createState() => _JsonPlaceholderTabState();
}

class _JsonPlaceholderTabState extends State<_JsonPlaceholderTab> {
  String _out = 'Tap a button';
  bool _loading = false;

  Future<void> _run(Future<String> Function() fn) async {
    setState(() {
      _loading = true;
      _out = 'Loading…';
    });
    final result = await fn().catchError((e) => 'Exception: $e');
    setState(() {
      _out = result;
      _loading = false;
    });
  }

  Future<void> _listPosts() => _run(() async {
    final res = await _jsonPlaceholderClient.get<List<dynamic>>(
      'posts',
      options: const RequestOptions(queryParameters: {'_limit': '5'}),
    );
    if (res.isSuccess) {
      final cacheHit =
          res.headers['x-fac-cache-hit'] == 'hit' ? ' (CACHE HIT)' : '';
      final titles =
          (res.data ?? [])
              .map((p) => '  • [${p['id']}] ${p['title']}')
              .join('\n');
      return 'Posts [${res.statusCode}]$cacheHit:\n$titles';
    }
    return 'Error [${res.statusCode}]';
  });

  Future<void> _getUser() => _run(() async {
    final res =
        await _jsonPlaceholderClient.get<Map<String, dynamic>>('users/1');
    if (res.isSuccess) {
      final d = res.data!;
      return 'User 1 [${res.statusCode}]:\n'
          '  name: ${d['name']}\n'
          '  email: ${d['email']}\n'
          '  phone: ${d['phone']}';
    }
    return 'Error [${res.statusCode}]';
  });

  Future<void> _createPost() => _run(() async {
    final res = await _jsonPlaceholderClient.post<Map<String, dynamic>>(
      'posts',
      const {
        'title': 'flutter_api_client test',
        'body': 'Hello world!',
        'userId': 1,
      },
    );
    if (res.isSuccess) {
      return 'Created [${res.statusCode}]:\n'
          '  id: ${res.data?['id']}\n'
          '  title: ${res.data?['title']}';
    }
    return 'Error [${res.statusCode}]: ${res.errorMessage}';
  });

  Future<void> _updatePost() => _run(() async {
    final res = await _jsonPlaceholderClient.put<Map<String, dynamic>>(
      'posts/1',
      const {
        'id': 1,
        'title': 'Updated title',
        'body': 'Updated body',
        'userId': 1,
      },
    );
    if (res.isSuccess) {
      return 'Updated [${res.statusCode}]:\n  title: ${res.data?['title']}';
    }
    return 'Error [${res.statusCode}]';
  });

  Future<void> _deletePost() => _run(() async {
    final res =
        await _jsonPlaceholderClient.delete<Map<String, dynamic>>('posts/1');
    return 'DELETE /posts/1 → ${res.statusCode} '
        '${res.isSuccess ? '(success)' : '(error)'}';
  });

  Future<void> _dedupDemo() => _run(() async {
    // Fire 3 identical requests simultaneously — DedupInterceptor collapses them.
    final results = await Future.wait([
      _jsonPlaceholderClient.get<Map<String, dynamic>>('posts/2'),
      _jsonPlaceholderClient.get<Map<String, dynamic>>('posts/2'),
      _jsonPlaceholderClient.get<Map<String, dynamic>>('posts/2'),
    ]);
    final statuses = results.map((r) => r.statusCode).join(', ');
    return 'DedupInterceptor:\n'
        'Fired 3 concurrent GET /posts/2\n'
        'All resolved with status: $statuses\n'
        '(only 1 real network call made)';
  });

  @override
  Widget build(BuildContext context) {
    return _TabLayout(
      description:
          'JSONPlaceholder (jsonplaceholder.typicode.com)\n'
          'Full CRUD · cacheFirst · DedupInterceptor (concurrent collapse demo).',
      loading: _loading,
      output: _out,
      buttons: [
        _btn('GET /posts?_limit=5  (cacheFirst — tap twice)', _listPosts),
        _btn('GET /users/1', _getUser),
        _btn('POST /posts  (create)', _createPost),
        _btn('PUT /posts/1  (update)', _updatePost),
        _btn('DELETE /posts/1', _deletePost),
        _btn('3× GET /posts/2 in parallel  (dedup)', _dedupDemo),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Dog CEO tab — image display + cancel token demo
// ---------------------------------------------------------------------------

class _DogTab extends StatefulWidget {
  const _DogTab();
  @override
  State<_DogTab> createState() => _DogTabState();
}

class _DogTabState extends State<_DogTab> {
  String _out = 'Tap a button';
  bool _loading = false;
  String? _imageUrl;

  Future<void> _run(Future<String> Function() fn) async {
    setState(() {
      _loading = true;
      _out = 'Loading…';
      _imageUrl = null;
    });
    final result = await fn().catchError((e) => 'Exception: $e');
    setState(() {
      _out = result;
      _loading = false;
    });
  }

  Future<void> _randomDog() => _run(() async {
    final res =
        await _dogClient.get<Map<String, dynamic>>('api/breeds/image/random');
    if (res.isSuccess) {
      final url = res.data?['message'] as String?;
      if (url != null) setState(() => _imageUrl = url);
      final hit =
          res.headers['x-fac-cache-hit'] == 'hit'
              ? ' (CACHE HIT)'
              : ' (network)';
      return 'Random dog$hit:\n$url';
    }
    return 'Error [${res.statusCode}]';
  });

  Future<void> _listBreeds() => _run(() async {
    final res =
        await _dogClient.get<Map<String, dynamic>>('api/breeds/list/all');
    if (res.isSuccess) {
      final breeds =
          (res.data?['message'] as Map?)?.keys.take(10).join(', ') ?? '(none)';
      final hit =
          res.headers['x-fac-cache-hit'] == 'hit'
              ? ' (CACHE HIT)'
              : ' (network)';
      return 'First 10 breeds$hit:\n$breeds';
    }
    return 'Error [${res.statusCode}]';
  });

  Future<void> _cancelDemo() async {
    setState(() {
      _loading = true;
      _out = 'Firing request then cancelling…';
      _imageUrl = null;
    });
    final token = CancelToken();
    final future = _dogClient.get<Map<String, dynamic>>(
      'api/breeds/image/random',
      options: RequestOptions(cancelToken: token),
    );
    token.cancel('user cancelled');
    final res = await future;
    setState(() {
      _loading = false;
      _out =
          res.isSuccess
              ? 'Completed before cancel [${res.statusCode}]:\n${res.data?['message']}'
              : 'Cancelled/error [${res.statusCode}]: ${res.errorMessage}';
    });
  }

  @override
  Widget build(BuildContext context) {
    return _TabLayout(
      description:
          'Dog CEO (dog.ceo)\n'
          'networkFirst cache · DedupInterceptor · CancelToken demo · Image display.',
      loading: _loading,
      output: _out,
      extra:
          _imageUrl != null
              ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    _imageUrl!,
                    height: 200,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        const Text('(image load failed)'),
                  ),
                ),
              )
              : null,
      buttons: [
        _btn('GET random dog image', _randomDog),
        _btn('GET /breeds/list/all  (tap twice for cache hit)', _listBreeds),
        _btn('GET + cancel immediately  (CancelToken)', _cancelDemo),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Open Trivia DB tab — query params + ApiResult pattern
// ---------------------------------------------------------------------------

class _TriviaTab extends StatefulWidget {
  const _TriviaTab();
  @override
  State<_TriviaTab> createState() => _TriviaTabState();
}

class _TriviaTabState extends State<_TriviaTab> {
  String _out = 'Tap a button';
  bool _loading = false;

  Future<void> _run(Future<String> Function() fn) async {
    setState(() {
      _loading = true;
      _out = 'Loading…';
    });
    final result = await fn().catchError((e) => 'Exception: $e');
    setState(() {
      _out = result;
      _loading = false;
    });
  }

  Future<void> _fetchQuestions({
    String type = 'multiple',
    int amount = 3,
  }) => _run(() async {
    final res = await _triviaClient.get<Map<String, dynamic>>(
      'api.php',
      options: RequestOptions(
        queryParameters: {
          'amount': '$amount',
          'type': type,
          'encode': 'url3986',
        },
      ),
    );
    if (res.isSuccess) {
      final questions = (res.data?['results'] as List?) ?? [];
      if (questions.isEmpty) return 'No questions returned.';
      final lines = questions.asMap().entries.map((e) {
        final q = e.value as Map;
        final text = Uri.decodeComponent(q['question'] as String? ?? '?');
        return '${e.key + 1}. $text';
      }).join('\n\n');
      return 'Trivia (${type.toUpperCase()}):\n\n$lines';
    }
    return 'Error [${res.statusCode}]: ${res.errorMessage}';
  });

  Future<void> _resultPattern() => _run(() async {
    final result = await _triviaClient.get<Map<String, dynamic>>(
      'api.php',
      options: const RequestOptions(
        queryParameters: {
          'amount': '1',
          'category': '9',
          'difficulty': 'easy',
          'encode': 'url3986',
        },
      ),
    );
    return result.when(
      success: (data) {
        final q = (data['results'] as List?)?.first as Map?;
        if (q == null) return 'No results.';
        return 'ApiResult.Success [${(result as Success).statusCode}]:\n'
            '  category: ${q['category']}\n'
            '  difficulty: ${q['difficulty']}\n'
            '  question: ${Uri.decodeComponent(q['question'] as String)}';
      },
      failure: (err) => 'ApiResult.Failure: ${err.runtimeType}\n$err',
    );
  });

  @override
  Widget build(BuildContext context) {
    return _TabLayout(
      description:
          'Open Trivia DB (opentdb.com)\n'
          'Query parameters via RequestOptions · retry · ApiResult sealed pattern.',
      loading: _loading,
      output: _out,
      buttons: [
        _btn('GET 3 multiple-choice questions', () => _fetchQuestions()),
        _btn(
          'GET 5 true/false questions',
          () => _fetchQuestions(type: 'boolean', amount: 5),
        ),
        _btn('GET easy question  →  ApiResult', _resultPattern),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Shared tab layout widget
// ---------------------------------------------------------------------------

class _TabLayout extends StatelessWidget {
  const _TabLayout({
    required this.description,
    required this.loading,
    required this.output,
    required this.buttons,
    this.extra,
  });

  final String description;
  final bool loading;
  final String output;
  final List<Widget> buttons;
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                description,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          const SizedBox(height: 12),
          ...buttons,
          if (extra != null) extra!,
          if (loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(),
            ),
          _ResultCard(output),
        ],
      ),
    );
  }
}
