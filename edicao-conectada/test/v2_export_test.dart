import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agrogestao/features/operations_v2/v2_export.dart';
import 'package:agrogestao/features/operations_v2/operations_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('moeda é convertida em centavos sem arredondamento binário', () {
    expect(centsFromInput('0,29'), 29);
    expect(centsFromInput('120.50'), 12050);
    expect(() => centsFromInput('1.234,56'), throwsFormatException);
    expect(() => centsFromInput('-1'), throwsFormatException);
    expect(decimalError('0'), isNotNull);
    expect(decimalError('', optional: true), isNull);
  });
  test('PDF e XLSX usam o mesmo retrato confirmado e preservam origens',
      () async {
    final fixture = jsonDecode(
        File('test/fixtures/relatorio_operacional_ficticio.json')
            .readAsStringSync()) as Map;
    final report = Map<String, dynamic>.from(fixture['report'] as Map);
    final rows = reportRows(report);
    expect(rows.any((r) => r.contains('R\$ 1374,00')), isTrue);
    expect(rows.any((r) => r.contains('R\$ 137,40/ha')), isTrue);
    final operationId = (report['operations'] as List).first['id'];
    expect(rows.any((r) => r.contains(operationId)), isTrue);
    final propertyName = (report['property'] as Map)['name'];
    (report['property'] as Map)['name'] = '=HYPERLINK("malicious") & Café';
    final xlsx = reportXlsx(report);
    final zip = ZipDecoder().decodeBytes(xlsx);
    final xml = utf8
        .decode(zip.findFile('xl/worksheets/sheet1.xml')!.content as List<int>);
    expect(xml, contains('&amp; Café'));
    expect(xml, contains('t="inlineStr"'));
    expect(xml, isNot(contains('<f>')));
    (report['property'] as Map)['name'] = propertyName;
    final pdf = await reportPdf(report);
    expect(ascii.decode(pdf.take(4).toList()), '%PDF');
    final output = Platform.environment['AGRO_V2_SAMPLE_DIR'];
    if (output != null) {
      final dir = Directory(output)..createSync(recursive: true);
      File('${dir.path}/Relatorio-FICTICIO.pdf').writeAsBytesSync(pdf);
      File('${dir.path}/Relatorio-FICTICIO.xlsx')
          .writeAsBytesSync(reportXlsx(report));
    }
  });
}
