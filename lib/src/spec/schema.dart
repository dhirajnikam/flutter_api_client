/// Light JSON Schema-like model used by `ApiSpec`.
///
/// Prefer the typed factories ([string], [integer], [number], [boolean],
/// [object], [array]) over the raw constructor — they keep [type] consistent
/// with the constraints that apply to it.
class Schema {
  /// Creates a schema of the given [type]. Prefer the typed factories.
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

  /// JSON Schema type: `string`, `integer`, `number`, `boolean`, `object`, or
  /// `array`.
  final String type;

  /// Optional format hint (e.g. `email`, `date-time`).
  final String? format;

  /// Whether the value is required. For object properties, drives the
  /// emitted `required` list.
  final bool required;

  /// Minimum string length (string type only).
  final int? minLength;

  /// Maximum string length (string type only).
  final int? maxLength;

  /// Minimum numeric value (integer/number types only).
  final num? minimum;

  /// Maximum numeric value (integer/number types only).
  final num? maximum;

  /// Allowed values, if the schema is an enumeration.
  final List<Object?>? enumValues;

  /// Example value emitted into docs and OpenAPI.
  final Object? example;

  /// Human-readable description.
  final String? description;

  /// Element schema for `array` types.
  final Schema? items;

  /// Property schemas for `object` types, keyed by property name.
  final Map<String, Schema>? properties;

  /// A `string` schema with optional string constraints.
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

  /// An `integer` schema with optional numeric bounds.
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

  /// A `number` schema with optional numeric bounds.
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

  /// A `boolean` schema.
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

  /// An `object` schema with the given [properties]. A property's own
  /// `required` flag drives the emitted `required` list.
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

  /// An `array` schema whose elements match [items].
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

  /// Converts this schema to its OpenAPI 3.1 schema-object representation.
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
          if (enumValues != null && !enumValues!.contains(value)) {
            errors.add('$path: not in enum $enumValues');
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
          if (enumValues != null && !enumValues!.contains(value)) {
            errors.add('$path: not in enum $enumValues');
          }
        }
        break;
      case 'boolean':
        if (value is! bool) {
          errors.add('$path: expected boolean');
        } else if (enumValues != null && !enumValues!.contains(value)) {
          errors.add('$path: not in enum $enumValues');
        }
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
      default:
        // An unknown type silently passing validation is worse than a clear
        // error: it would let a typo'd schema accept anything.
        errors.add('$path: unknown schema type "$type"');
    }
    return errors;
  }
}
