/// Matches a `{placeholder}` token in an endpoint path; group 1 is its name.
final RegExp pathPlaceholder = RegExp(r'\{([^}]+)\}');
