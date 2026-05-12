# Contributing to flutter_api_client

Thank you for your interest in contributing! This document provides guidelines and instructions for contributing to the project.

## Table of Contents

1. [Code of Conduct](#code-of-conduct)
2. [Getting Started](#getting-started)
3. [Development Workflow](#development-workflow)
4. [Testing](#testing)
5. [Code Style](#code-style)
6. [Commit Messages](#commit-messages)
7. [Pull Request Process](#pull-request-process)
8. [Reporting Issues](#reporting-issues)

## Code of Conduct

- Be respectful and inclusive
- Focus on constructive feedback
- Help create a welcoming environment for all contributors

## Getting Started

### Prerequisites

- Flutter SDK 3.0.0 or later
- Dart SDK 3.0.0 or later
- Git

### Fork and Clone

1. Fork the repository on GitHub
2. Clone your fork locally:

```bash
git clone https://github.com/YOUR_USERNAME/flutter_api_client.git
cd flutter_api_client
```

3. Add upstream remote:

```bash
git remote add upstream https://github.com/dhirajnikam/flutter_api_client.git
```

### Install Dependencies

```bash
flutter pub get
cd example && flutter pub get && cd ..
```

## Development Workflow

### 1. Create a Branch

Always create a feature branch from `main`:

```bash
git checkout -b feature/your-feature-name
# or
git checkout -b fix/your-bug-fix
```

### 2. Make Changes

- Write clear, maintainable code
- Follow the existing code style
- Add tests for new features
- Update documentation as needed

### 3. Keep Your Branch Updated

```bash
git fetch upstream
git rebase upstream/main
```

## Testing

### Running Tests

Run all tests:

```bash
flutter test
```

Run with coverage:

```bash
flutter test --coverage
genhtml coverage/lcov.info -o coverage/html
open coverage/html/index.html
```

Run specific test file:

```bash
flutter test test/api_result_test.dart
```

Run with concurrency:

```bash
flutter test --concurrency=8
```

### Test Requirements

- All new features **must** include tests
- Bug fixes **should** include regression tests
- Aim for >90% code coverage
- Tests must pass before submitting PR

### Test Structure

```dart
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FeatureName', () {
    test('should handle happy path', () async {
      // Arrange
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: MockAdapter()..stub('GET', '/endpoint', body: {}),
      ));

      // Act
      final result = await client.get<dynamic>('/endpoint');

      // Assert
      expect(result.isSuccess, true);
    });

    test('should handle error case', () async {
      // Test error scenarios
    });
  });
}
```

## Code Style

### Dart Style

Follow [Effective Dart](https://dart.dev/guides/language/effective-dart) guidelines:

```bash
# Format code
dart format .

# Analyze code
dart analyze
```

### Code Conventions

1. **Naming**
   - Classes: `PascalCase` (e.g., `ApiClient`, `CacheInterceptor`)
   - Variables/functions: `camelCase` (e.g., `getAccessToken`, `baseUrl`)
   - Constants: `camelCase` with `final` or `const` (e.g., `defaultTimeout`)
   - Private members: prefix with `_` (e.g., `_executeRequest`)

2. **Comments**
   - Use `///` for public API documentation
   - Use `//` for implementation comments
   - Explain "why", not "what"
   - Keep comments up-to-date

3. **Documentation**
   - All public APIs must have dartdoc comments
   - Include examples for complex features
   - Document parameters and return types

Example:

```dart
/// Executes an HTTP request with retry logic and caching.
///
/// The [method] specifies the HTTP verb (GET, POST, etc.).
/// [endpoint] is the path relative to [ApiClientConfig.baseUrl].
///
/// Returns an [ApiResult<T>] containing either the decoded response
/// or a typed error.
///
/// Example:
/// ```dart
/// final result = await client.request<User>(
///   'GET',
///   'users/me',
///   decoder: User.fromJson,
/// );
/// ```
Future<ApiResult<T>> request<T>(
  String method,
  String endpoint, {
  Decoder<T>? decoder,
}) async {
  // Implementation
}
```

4. **Imports**
   - Group imports: dart, flutter, package, relative
   - Sort alphabetically within groups
   - No unused imports

```dart
// Dart imports
import 'dart:async';
import 'dart:convert';

// Package imports
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

// Relative imports
import '../core/api_exception.dart';
```

## Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <subject>

<body>

<footer>
```

### Types

- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `style`: Code style changes (formatting, no logic change)
- `refactor`: Code refactoring
- `test`: Adding or updating tests
- `chore`: Maintenance tasks

### Examples

```
feat(cache): add staleWhileRevalidate cache policy

Implements a new cache strategy that returns stale data immediately
while revalidating in the background.

Closes #42
```

```
fix(retry): respect Retry-After header with date format

The retry logic now correctly parses both delay-seconds and HTTP-date
formats for the Retry-After header per RFC 7231.

Fixes #38
```

```
docs(readme): add GraphQL examples
```

## Pull Request Process

### Before Submitting

1. ✅ Tests pass: `flutter test`
2. ✅ Code is formatted: `dart format .`
3. ✅ No analysis issues: `dart analyze`
4. ✅ Documentation is updated
5. ✅ CHANGELOG.md is updated (for features/fixes)
6. ✅ Examples are added/updated if needed

### Submitting PR

1. Push your branch to your fork
2. Open a PR against `main` branch
3. Fill out the PR template completely
4. Link related issues using keywords:
   - `Fixes #123`
   - `Closes #456`
   - `Resolves #789`

### PR Template

```markdown
## Description
Brief description of changes

## Type of Change
- [ ] Bug fix (non-breaking change which fixes an issue)
- [ ] New feature (non-breaking change which adds functionality)
- [ ] Breaking change (fix or feature that causes existing functionality to change)
- [ ] Documentation update

## Testing
Describe testing done

## Checklist
- [ ] Tests added/updated
- [ ] Documentation updated
- [ ] CHANGELOG.md updated
- [ ] All tests pass
- [ ] Code formatted and analyzed
```

### Review Process

- Maintainers will review your PR
- Address feedback by pushing new commits
- Once approved, a maintainer will merge

## Reporting Issues

### Bug Reports

Include:

1. **Description**: Clear description of the bug
2. **Steps to Reproduce**:
   ```
   1. Create ApiClient with...
   2. Call client.get(...)
   3. See error
   ```
3. **Expected Behavior**: What should happen
4. **Actual Behavior**: What actually happens
5. **Environment**:
   - flutter_api_client version
   - Flutter version (`flutter --version`)
   - Dart version
   - Platform (iOS, Android, Web, etc.)
6. **Code Sample**: Minimal reproduction code
7. **Logs**: Relevant error messages or stack traces

### Feature Requests

Include:

1. **Use Case**: Describe the problem you're trying to solve
2. **Proposed Solution**: How you envision the feature
3. **Alternatives**: Other solutions you've considered
4. **Additional Context**: Screenshots, mockups, etc.

## Project Structure

```
flutter_api_client/
├── lib/
│   ├── flutter_api_client.dart     # Main export file
│   └── src/
│       ├── auth/                    # Authentication & token storage
│       ├── core/                    # Core client & types
│       ├── gen/                     # Build runner & code generation
│       ├── graphql/                 # GraphQL client
│       ├── http/                    # HTTP adapters
│       ├── interceptors/            # All interceptors
│       ├── response/                # Response handlers
│       └── spec/                    # API spec & generators
├── test/                            # Tests mirror lib/ structure
├── example/                         # Demo app
├── bin/gen.dart                     # CLI for doc generation
└── docs/                            # Documentation
```

## Areas for Contribution

Looking for ideas? Consider:

- 🐛 **Bug fixes**: Check [open issues](https://github.com/dhirajnikam/flutter_api_client/issues)
- 📚 **Documentation**: Improve guides, add examples
- ✨ **New features**: Propose and implement enhancements
- 🧪 **Tests**: Increase coverage, add edge cases
- 🚀 **Performance**: Optimize hot paths
- 🎨 **Examples**: Add more real-world examples

## Questions?

- Open a [GitHub Discussion](https://github.com/dhirajnikam/flutter_api_client/discussions)
- Check existing [issues](https://github.com/dhirajnikam/flutter_api_client/issues)

Thank you for contributing! 🎉
