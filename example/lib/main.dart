import 'package:flutter/material.dart';
import 'package:flutter_api_client/flutter_api_client.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter API Client Example',
      theme: ThemeData(useMaterial3: true),
      home: const ExamplePage(),
    );
  }
}

class ExamplePage extends StatefulWidget {
  const ExamplePage({super.key});

  @override
  State<ExamplePage> createState() => _ExamplePageState();
}

class _ExamplePageState extends State<ExamplePage> {
  String _status = 'Ready';
  String _response = '';

  late final ApiClient _apiClient;

  @override
  void initState() {
    super.initState();
    final config = ApiClientConfig(
      baseUrl: 'https://jsonplaceholder.typicode.com',
      getAccessToken: () async => null,
    );
    _apiClient = ApiClient(config);
  }

  Future<void> _fetchData() async {
    setState(() => _status = 'Loading...');
    try {
      final response = await _apiClient.get('posts/1');
      setState(() {
        _status = response.isSuccess ? 'Success' : 'Error';
        _response = response.isSuccess
            ? response.data.toString()
            : (response.errorMessage ?? 'Unknown error');
      });
    } catch (e) {
      setState(() {
        _status = 'Error';
        _response = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flutter API Client Example'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Status: $_status',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _fetchData,
              child: const Text('GET /posts/1'),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(
                  _response.isEmpty ? 'Tap the button to fetch data.' : _response,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
