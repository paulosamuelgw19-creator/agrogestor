import 'dart:convert';

import 'package:agrogestao/features/sync/legacy_farm_data_import.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('leitura dos cadastros antigos', () {
    test('normaliza registros conhecidos e aceita identificadores UUID', () {
      final rows = LegacyFarmDataImport.parseLegacyRecords(
        jsonEncode([
          {
            'id': 'c1e01d2a-34f1-4a17-914a-f998c3986137',
            'name': 'Trator',
            'brand': 'Marca',
            'model': 'Modelo',
            'year': 2020,
            'hourMeter': 100,
            'fuelType': 'Diesel',
            'status': 'disponivel',
          },
        ]),
        'machines',
      );

      expect(rows, hasLength(1));
      expect(rows.single['id'], 'c1e01d2a-34f1-4a17-914a-f998c3986137');
      expect(rows.single['photoAttachmentId'], isNull);
    });

    test('recusa identificadores ausentes, inválidos ou repetidos', () {
      expect(
        () => LegacyFarmDataImport.parseLegacyRecords('[{"name":"Sem ID"}]', 'machines'),
        throwsFormatException,
      );
      expect(
        () => LegacyFarmDataImport.parseLegacyRecords('[{"id":"id ruim"}]', 'machines'),
        throwsFormatException,
      );
      expect(
        () => LegacyFarmDataImport.parseLegacyRecords('[{"id":"repetido"},{"id":"repetido"}]', 'machines'),
        throwsFormatException,
      );
    });

    test('não importa um módulo com formato incompatível', () {
      expect(
        () => LegacyFarmDataImport.parseLegacyRecords('[{"id":"maquina-1","name":"Trator"}]', 'machines'),
        throwsFormatException,
      );
    });
  });
}
