/// Light JSON Schema-like model used by [ApiSpec].
class Schema {
  const Schema({
    required this.type,
    this.format,
    this.required = false,
    this.minLength,
    this.maxLength,
    this.minimum,
    this.maximum,
    this.enumValues,
    this.example,
    this.description,
    this.items,
    this.properties,
  });

  final String type;
  final String? format;
  final bool required;
  final int? minLength;
  final int? maxLength;
  final num? minimum;
  final num? maximum;
  final List<Object?>? enumValues;
  final Object? example;
  final String? description;
  final Schema? items;
  final Map<String, Schema>? properties;

  static Schema string({
    String? format,
    bool required = false,
    int? minLength,
    int? maxLength,
    List<String>? enumValues,
    String? example,
    String? description,
  }) =>
      Schema(
        type: 'string',
        format: format,
        required: required,
        minLength: minLength,
        maxLength: maxLength,
        enumValues: enumValues,
        example: example,
        description: description,
      );

  static Schema integer({
    bool required = false,
    int? minimum,
    int? maximum,
    int? example,
    String? description,
  }) =>
      Schema(
        type: 'integer',
        required: required,
        minimum: minimum,
        maximum: maximum,
        example: example,
        description: description,
      );

  static Schema number({
    bool required = false,
    num? minimum,
    num? maximum,
    num? example,
    String? description,
  }) =>
      Schema(
        type: 'number',
        required: required,
        minimum: minimum,
        maximum: maximum,
        example: example,
        description: description,
      );

  static Schema boolean({
    bool required = false,
    bool? example,
    String? description,
  }) =>
      Schema(
        type: 'boolean',
        required: required,
        example: example,
        description: description,
      );

  static Schema object(
    Map<String, Schema> properties, {
    bool required = false,
    String? description,
  }) =>
      Schema(
        type: 'object',
        required: required,
        properties: properties,
        description: description,
      );

  static Schema array(
    Schema items, {
    bool required = false,
    String? description,
  }) =>
      Schema(
        type: 'array',
        required: required,
        items: items,
        description: description,
      );

  Map<String, Object?> toOpenApi() {
    final out = <String, Object?>{'type': type};
    if (format != null) out['format'] = format;
    if (minLength != null) out['minLength'] = minLength;
    if (maxLength != null) out['maxLength'] = maxLength;
    if (minimum != null) out['minimum'] = minimum;
    if (maximum != null) out['maximum'] = maximum;
    if (enumValues != null) out['enum'] = enumValues;
    if (example != null) out['example'] = example;
    if (description != null) out['description'] = description;
    if (items != null) out['items'] = items!.toOpenApi();
    if (properties != null) {
      out['properties'] = {
        for (final e in properties!.entries) e.key: e.value.toOpenApi(),
      };
      final req = properties!.entries
          .where((e) => e.value.required)
          .map((e) => e.key)
          .toList();
      if (req.isNotEmpty) out['required'] = req;
    }
    return out;
  }

  /// Returns a list of human-readable validation error strings, empty if
  /// [value] satisfies this schema.
  List<String> validate(Object? value, [String path = '']) {
    final errors = <String>[];
    if (value == null) {
      if (required) errors.add('${path.isEmpty ? '<root>' : path} is required');
      return errors;
    }
    switch (type) {
      case 'string':
        if (value is! String) {
          errors.add('$path: expected string');
        } else {
          if (minLength != null && value.length < minLength!) {
            errors.add('$path: minLength $minLength');
          }
          if (maxLength != null && value.length > maxLength!) {
            errors.add('$path: maxLength $maxLength');
          }
          if (enumValues != null && !enumValues!.contains(value)) {
            errors.add('$path: not in enum $enumValues');
          }
        }
        break;
      case 'integer':
        if (value is! int) {
          errors.add('$path: expected integer');
        } else {
          if (minimum != null && value < minimum!) {
            errors.add('$path: minimum $minimum');
          }
          if (maximum != null && value > maximum!) {
            errors.add('$path: maximum $maximum');
          }
        }
        break;
      case 'number':
        if (value is! num) {
          errors.add('$path: expected number');
        } else {
          if (minimum != null && value < minimum!) {
            errors.add('$path: minimum $minimum');
          }
          if (maximum != null && value > maximum!) {
            errors.add('$path: maximum $maximum');
          }
        }
        break;
      case 'boolean':
        if (value is! bool) errors.add('$path: expected boolean');
        break;
      case 'object':
        if (value is! Map) {
          errors.add('$path: expected object');
        } else if (properties != null) {
          properties!.forEach((k, s) {
            final v = value[k];
            errors.addAll(s.validate(v, path.isEmpty ? k : '$path.$k'));
          });
        }
        break;
      case 'array':
        if (value is! List) {
          errors.add('$path: expected array');
        } else if (items != null) {
          for (var i = 0; i < value.length; i++) {
            errors.addAll(items!.validate(value[i], '$path[$i]'));
          }
        }
        break;
    }
    return errors;
  }
}
