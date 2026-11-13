import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Schema.validate — unknown type', () {
    test('an unknown schema type fails validation instead of passing', () {
      final errors = const Schema(type: 'bogus').validate('anything');
      expect(errors, isNotEmpty);
      expect(errors.first, contains('unknown schema type'));
    });
  });

  group('Schema validation contract (spec subsystem)', () {
    test('nested object + array validation returns precise error paths', () {
      final schema = Schema.object({
        'user': Schema.object({
          'name': Schema.string(required: true, minLength: 2),
          'tags': Schema.array(Schema.string()),
        }),
      });
      final errors = schema.validate({
        'user': {
          'name': 'a', // too short
          'tags': ['ok', 123], // wrong element type
        },
      });
      expect(errors, isNotEmpty);
      expect(errors.any((e) => e.contains('minLength')), isTrue);
      expect(errors.any((e) => e.contains('tags[1]')), isTrue);
    });
  });

  group('Schema numeric bounds', () {
    test('integer minimum is enforced', () {
      final schema = Schema.integer(minimum: 1);
      expect(schema.validate(0), isNotEmpty);
      expect(schema.validate(1), isEmpty);
      expect(schema.validate(5), isEmpty);
    });

    test('integer maximum is enforced', () {
      final schema = Schema.integer(maximum: 10);
      expect(schema.validate(11), isNotEmpty);
      expect(schema.validate(10), isEmpty);
    });

    test('number minimum/maximum are enforced', () {
      final schema = Schema.number(minimum: 0.5, maximum: 2.5);
      expect(schema.validate(0.4), isNotEmpty);
      expect(schema.validate(2.6), isNotEmpty);
      expect(schema.validate(1.5), isEmpty);
    });

    test('bounds nested inside an object schema report a path', () {
      final schema = Schema.object({'age': Schema.integer(minimum: 0)});
      final errors = schema.validate({'age': -1});
      expect(errors, isNotEmpty);
      expect(errors.first, contains('age'));
    });

    test('type errors still take precedence over bound checks', () {
      final schema = Schema.integer(minimum: 0);
      expect(schema.validate('not-an-int'), [contains('expected integer')]);
    });
  });

  group('Schema enumValues', () {
    test('integer enum is enforced', () {
      const s = Schema(type: 'integer', enumValues: [1, 2, 3]);
      expect(s.validate(2), isEmpty);
      expect(s.validate(9), isNotEmpty);
    });

    test('number enum is enforced', () {
      const s = Schema(type: 'number', enumValues: [0.5, 1.5]);
      expect(s.validate(1.5), isEmpty);
      expect(s.validate(2.5), isNotEmpty);
    });

    test('boolean enum is enforced', () {
      const s = Schema(type: 'boolean', enumValues: [true]);
      expect(s.validate(true), isEmpty);
      expect(s.validate(false), isNotEmpty);
    });

    test('string enum still enforced', () {
      const s = Schema(type: 'string', enumValues: ['a', 'b']);
      expect(s.validate('a'), isEmpty);
      expect(s.validate('c'), isNotEmpty);
    });
  });

  group('Schema validation', () {
    test('object required', () {
      final s = Schema.object({
        'email': Schema.string(required: true),
        'age': Schema.integer(),
      });
      expect(s.validate({'email': 'a@b.com'}), isEmpty);
      expect(s.validate({'age': 5}), isNotEmpty);
    });
    test('type mismatch', () {
      final s = Schema.integer(required: true);
      expect(s.validate('hello'), isNotEmpty);
    });
  });
}
