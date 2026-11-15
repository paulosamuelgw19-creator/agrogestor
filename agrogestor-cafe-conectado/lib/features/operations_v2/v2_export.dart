import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'v2_store.dart';

const metricNames = {
  'consumed_fuel': 'Combustível efetivamente consumido (medido)',
  'registered_area': 'Área total das fazendas ativas',
  'registered_plot_area': 'Área atual dos talhões selecionados',
  'registered_cost': 'Custo registrado',
  'machine_cost': 'Custo de máquinas',
  'input_cost': 'Custo de insumos',
  'fuel_cost': 'Custo de combustível',
  'labor_cost': 'Custo de mão de obra',
  'external_refueling_cost': 'Custo de abastecimentos em posto',
  'refueled_liters': 'Litros abastecidos (não é consumo medido)',
  'refueling_cost': 'Custo de abastecimentos (estoque já incluído nos insumos)',
  'cost_per_cycle_ha': 'Custo por hectare do ciclo',
  'worked_area_passes': 'Área de passadas',
  'machine_hours': 'Horas de máquinas',
  'labor_hours': 'Horas de mão de obra',
};

String metricStatus(Object? status) => switch (status) {
      'complete_registered' => 'Completo dos registros',
      'no_data' => 'Sem dados',
      'incomplete' => 'Incompleto',
      _ => 'Indisponível',
    };

String subtotalLabel(Map value) => displayMetric(
    {...Map<String, dynamic>.from(value), 'value': value['known_subtotal']});

String displayMetric(Json value) {
  if (value['value'] == null) {
    return value['status'] == 'no_data' ? 'Sem dados' : 'Informação incompleta';
  }
  final raw = value['value'].toString();
  final unit = value['unit'].toString();
  if (unit.startsWith('BRL_cent')) {
    // Display conversion only; monetary calculations are performed on the server.
    return 'R\$ ${(num.parse(raw) / 100).toStringAsFixed(2).replaceAll('.', ',')}${unit.endsWith('/ha') ? '/ha' : ''}';
  }
  return '${raw.replaceAll('.', ',')} ${unit == 'ha_passes' ? 'ha de passadas' : unit}';
}

List<List<String>> reportRows(Json report) {
  if (report['report_type'] != null) {
    final rows = <List<String>>[
      [
        'AgroGestor — relatório administrativo',
        managementField('${report['report_type']}')
      ],
      ['Gerado em (UTC)', '${report['generated_at']}'],
      [
        'Fazendas no relatório',
        items(report, 'properties').map((p) => '${p['name']}').join(', ')
      ],
      ['Escopo', '${report['scope']}'],
    ];
    void walk(Object? value, String path) {
      if (value is Map) {
        if (value.containsKey('unit') &&
            value.containsKey('status') &&
            value.containsKey('value')) {
          rows.add([path, managementDetails(value)]);
          return;
        }
        for (final e in value.entries) {
          if (_managementHidden.contains(e.key)) continue;
          final label = '$path / ${managementField('${e.key}')}';
          if ('${e.key}'.endsWith('_cents') && e.value != null) {
            rows.add([
              label,
              displayMetric({'value': '${e.value}', 'unit': 'BRL_cent'})
            ]);
          } else if (path == managementField('filters') && e.value == null) {
            rows.add([label, 'Todos / sem filtro']);
          } else {
            walk(e.value, label);
          }
        }
      } else if (value is List) {
        if (value.isEmpty) rows.add([path, 'Nenhum registro']);
        for (var i = 0; i < value.length; i++) {
          walk(value[i], '$path [${i + 1}]');
        }
      } else {
        rows.add([path, managementDetails(value)]);
      }
    }

    for (final e in report.entries
        .where((e) => !['generated_at', 'scope'].contains(e.key))) {
      walk(e.value, managementField(e.key));
    }
    return rows;
  }
  final rows = <List<String>>[
    ['AgroGestor — relatório operacional'],
    ['Gerado em (UTC)', '${report['generated_at']}'],
    [
      'Propriedade',
      '${(report['property'] as Map)['name']}',
      '${(report['property'] as Map)['id']}'
    ],
    ['Talhão', '${(report['plot'] as Map)['name']}'],
    ['Cultura', '${(report['crop'] as Map)['name']}'],
    ['Safra/ciclo', '${(report['cycle'] as Map)['name']}'],
    [
      'Área do ciclo (ha)',
      '${(report['cycle'] as Map)['area_ha'] ?? 'Não informada'}'
    ],
    ['Filtros', jsonEncode(report['filters'])],
    ['Escopo', '${report['scope']}'],
    [
      'Pendente no aparelho',
      '${report['pending_count'] ?? 0} lançamento(s) não incluído(s)'
    ],
    [
      'Indicador',
      'Valor',
      'Estado',
      'Subtotal conhecido',
      'Unidade',
      'Registros sem informação'
    ],
  ];
  (report['metrics'] as Map? ?? {}).forEach((key, raw) {
    final value = Map<String, dynamic>.from(raw as Map);
    rows.add([
      metricNames[key] ?? '$key',
      displayMetric(value),
      '${value['status']}',
      '${value['known_subtotal'] ?? ''}',
      '${value['unit']}',
      '${value['missing'] ?? ''}'
    ]);
  });
  rows.add([
    'Operação / origem',
    'Data',
    'Tipo',
    'Área (ha)',
    'Autor',
    'Observações'
  ]);
  for (final operation in items(report, 'operations')) {
    rows.add([
      '${operation['id']}',
      '${operation['performed_on']}',
      '${operation['kind']}',
      '${operation['area_ha'] ?? 'Não informada'}',
      '${operation['actor_id']}',
      '${operation['notes']}'
    ]);
    rows.add([
      'Máquina ID',
      'Horímetro inicial',
      'Horímetro final',
      'Horas',
      'Tarifa (centavos/h)',
      'Custo (centavos)'
    ]);
    for (final m in items(operation, 'machines')) {
      rows.add([
        '${m['machine_id']}',
        '${m['start_meter']}',
        '${m['end_meter']}',
        '${m['hours']}',
        '${m['hourly_cost_cents'] ?? 'Não informado'}',
        '${m['cost_cents'] ?? 'Não informado'}'
      ]);
    }
    if (items(operation, 'refuelings').isNotEmpty) {
      rows.add([
        'Abastecimento ID',
        'Máquina',
        'Data',
        'Litros',
        'Horímetro',
        'Origem',
        'Valor (centavos; estoque já incluído nos insumos)',
        'Local',
        'Autor'
      ]);
      for (final fuel in items(operation, 'refuelings')) {
        rows.add([
          '${fuel['id']}',
          '${fuel['machine_name']}',
          '${fuel['occurred_on']}',
          '${fuel['liters']}',
          '${fuel['hour_meter']}',
          fuel['source'] == 'stock' ? 'Estoque da propriedade' : 'Posto',
          '${fuel['total_cost_cents'] ?? 'Não informado'}',
          '${fuel['location']}',
          '${fuel['actor_name']}'
        ]);
      }
    }
    rows.add(['Movimento ID', 'Insumo ID', 'Quantidade', 'Custo (centavos)']);
    for (final i in items(operation, 'inputs')) {
      rows.add([
        '${i['id']}',
        '${i['input_id']}',
        '${i['quantity']} ${i['unit'] ?? ''}',
        '${i['value_cents'] ?? 'Não informado'}'
      ]);
    }
  }
  return rows;
}

Future<Uint8List> reportPdf(Json report) async {
  final doc = pw.Document();
  final regular =
      pw.Font.ttf(await rootBundle.load('assets/fonts/NotoSans-Regular.ttf'));
  final bold =
      pw.Font.ttf(await rootBundle.load('assets/fonts/NotoSans-Bold.ttf'));
  if (report['report_type'] != null) {
    final rows = reportRows(report);
    // Individual blocks can break between records instead of one oversized row.
    doc.addPage(pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        maxPages: 1000,
        theme: pw.ThemeData.withFont(base: regular, bold: bold),
        footer: (context) => pw.Text(
            'AgroGestor · ${context.pageNumber}/${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 8)),
        build: (_) => [
              for (final row in rows)
                pw.Padding(
                    padding: const pw.EdgeInsets.only(bottom: 5),
                    child: pw.Text('${row.first}\n${row.skip(1).join(' · ')}',
                        style: const pw.TextStyle(fontSize: 8)))
            ]));
    return doc.save();
  }
  pw.Widget table(List<List<String>> rows) => pw.TableHelper.fromTextArray(
        data: rows,
        headerCount: 1,
        cellStyle: const pw.TextStyle(fontSize: 8),
        headerStyle: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
        headerDecoration: const pw.BoxDecoration(color: PdfColors.green50),
        cellAlignment: pw.Alignment.topLeft,
        columnWidths: {
          for (var i = 0; i < rows.first.length; i++)
            i: const pw.FlexColumnWidth()
        },
      );
  pw.Widget text(String value) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 3),
      child: pw.Text(value, style: const pw.TextStyle(fontSize: 9)));
  doc.addPage(pw.MultiPage(
      theme: pw.ThemeData.withFont(base: regular, bold: bold),
      pageFormat: PdfPageFormat.a4.landscape,
      maxPages: 500,
      margin: const pw.EdgeInsets.all(24),
      header: (_) => pw.Text(
          'AgroGestor | ${(report['property'] as Map)['name']}',
          style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
      footer: (ctx) => pw.Text(
          'Gerado: ${report['generated_at']} | ${ctx.pageNumber}/${ctx.pagesCount}',
          style: const pw.TextStyle(fontSize: 8)),
      build: (_) => [
            pw.Header(level: 1, text: 'Relatório operacional'),
            text(
                'Propriedade: ${report['property']['name']} | ID: ${report['property']['id']}'),
            text(
                'Talhão: ${report['plot']['name']} | Cultura: ${report['crop']['name']} | Safra/ciclo: ${report['cycle']['name']}'),
            text(
                'Área do ciclo: ${report['cycle']['area_ha'] ?? 'não informada'} ha | Período: ${report['filters']['starts_on'] ?? 'início do ciclo'} até ${report['filters']['ends_on'] ?? 'fim do ciclo'}'),
            text('${report['scope']}'),
            text(
                '${report['pending_count'] ?? 0} lançamento(s) pendente(s) neste aparelho não incluído(s).'),
            pw.SizedBox(height: 8),
            table([
              [
                'Indicador',
                'Valor',
                'Qualidade dos dados',
                'Registros sem informação'
              ],
              for (final entry in (report['metrics'] as Map).entries)
                [
                  metricNames[entry.key] ?? '${entry.key}',
                  displayMetric(Map<String, dynamic>.from(entry.value as Map)),
                  entry.value['status'] == 'complete_registered'
                      ? 'Completo dos registros'
                      : entry.value['status'] == 'no_data'
                          ? 'Sem dados'
                          : 'Incompleto',
                  '${entry.value['missing'] ?? '-'}'
                ],
            ]),
            pw.SizedBox(height: 8),
            pw.Header(level: 1, text: 'Lançamentos de origem'),
            for (final operation in items(report, 'operations')) ...[
              text(
                  'Operação: ${operation['id']} | Data: ${operation['performed_on']} | Tipo: ${operation['kind']}'),
              text(
                  'Área: ${operation['area_ha'] ?? 'não informada'} ha | Autor: ${operation['actor_id']} | Observações: ${operation['notes']}'),
              if (items(operation, 'machines').isNotEmpty)
                table([
                  [
                    'Máquina ID',
                    'Horímetro inicial/final',
                    'Horas',
                    'Tarifa (centavos/h)',
                    'Custo (centavos)'
                  ],
                  for (final m in items(operation, 'machines'))
                    [
                      '${m['name'] ?? ''}\n${m['machine_id']}',
                      '${m['start_meter']} / ${m['end_meter']}',
                      '${m['hours']}',
                      '${m['hourly_cost_cents'] ?? 'Não informado'}',
                      '${m['cost_cents'] ?? 'Não informado'}'
                    ],
                ]),
              if (items(operation, 'inputs').isNotEmpty)
                table([
                  [
                    'Movimento de estoque ID',
                    'Insumo ID',
                    'Quantidade (unidade cadastrada)',
                    'Custo (centavos)'
                  ],
                  for (final i in items(operation, 'inputs'))
                    [
                      '${i['id']}',
                      '${i['name'] ?? ''}\n${i['input_id']}',
                      '${i['quantity']} ${i['unit'] ?? ''}',
                      '${i['value_cents'] ?? 'Não informado'}'
                    ],
                ]),
              if (items(operation, 'refuelings').isNotEmpty) ...[
                text(
                    'Abastecimentos: litros abastecidos não medem consumo no serviço. Valor do estoque já incluído nos insumos.'),
                table([
                  [
                    'Máquina / data',
                    'Litros / combustível',
                    'Horímetro',
                    'Origem / local',
                    'Valor (centavos) / autor'
                  ],
                  for (final fuel in items(operation, 'refuelings'))
                    [
                      '${fuel['machine_name']} / ${fuel['occurred_on']}',
                      '${fuel['liters']} L / ${fuel['fuel_name']}',
                      '${fuel['hour_meter']} h',
                      '${fuel['source'] == 'stock' ? 'Estoque' : 'Posto'} / ${fuel['location']}',
                      '${fuel['total_cost_cents'] ?? 'Não informado'} / ${fuel['actor_name']}'
                    ]
                ])
              ],
              pw.SizedBox(height: 10),
            ],
          ]));
  return doc.save();
}

String _xml(String value) => value
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// Real OOXML workbook. All user-supplied strings are inline strings, including
/// leading '=' or '+', so names/notes cannot become spreadsheet formulas.
Uint8List reportXlsx(Json report) {
  final archive = Archive();
  void add(String path, String value) {
    final bytes = utf8.encode(value);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  add('[Content_Types].xml',
      '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>');
  add('_rels/.rels',
      '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>');
  add('xl/workbook.xml',
      '<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Relatório operacional" sheetId="1" r:id="rId1"/><sheet name="Indicadores numericos" sheetId="2" r:id="rId2"/></sheets></workbook>');
  add('xl/_rels/workbook.xml.rels',
      '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/></Relationships>');
  final rows = reportRows(report);
  final body = StringBuffer();
  for (var r = 0; r < rows.length; r++) {
    body.write('<row r="${r + 1}">');
    for (var c = 0; c < rows[r].length; c++) {
      body.write(
          '<c r="${String.fromCharCode(65 + c)}${r + 1}" t="inlineStr"><is><t xml:space="preserve">${_xml(rows[r][c])}</t></is></c>');
    }
    body.write('</row>');
  }
  add('xl/worksheets/sheet1.xml',
      '<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><cols><col min="1" max="6" width="30" customWidth="1"/></cols><sheetData>$body</sheetData></worksheet>');
  final numeric = StringBuffer('<row r="1">');
  final headers = [
    'Indicador',
    'Valor (unidade da coluna C)',
    'Unidade',
    'Estado',
    'Subtotal conhecido',
    'Registros sem informação'
  ];
  for (var c = 0; c < headers.length; c++) {
    numeric.write(
        '<c r="${String.fromCharCode(65 + c)}1" t="inlineStr"><is><t>${_xml(headers[c])}</t></is></c>');
  }
  numeric.write('</row>');
  var r = 2;
  (report['metrics'] as Map? ?? {}).forEach((key, raw) {
    final m = Map<String, dynamic>.from(raw as Map);
    numeric.write('<row r="$r">');
    final cells = [
      metricNames[key] ?? '$key',
      m['value'],
      m['unit'],
      m['status'],
      m['known_subtotal'],
      m['missing']
    ];
    for (var c = 0; c < cells.length; c++) {
      final value = cells[c];
      if (value == null) continue;
      final cell = '${String.fromCharCode(65 + c)}$r';
      numeric.write([1, 4, 5].contains(c)
          ? '<c r="$cell" t="n"><v>$value</v></c>'
          : '<c r="$cell" t="inlineStr"><is><t>${_xml('$value')}</t></is></c>');
    }
    numeric.write('</row>');
    r++;
  });
  add('xl/worksheets/sheet2.xml',
      '<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><cols><col min="1" max="6" width="30" customWidth="1"/></cols><sheetData>$numeric</sheetData></worksheet>');
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

const _managementLabels = {
  'archived': 'Arquivada',
  'location': 'Localização',
  'recorded_by': 'Registrado por',
  'machine_released': 'Máquina liberada',
  'priority': 'Prioridade',
  'hourly_cost_cents': 'Tarifa por hora (centavos)',
  'meter_gap_hours': 'Intervalo sem apontamento (h)',
  'hour_meter': 'Horímetro atual (h)',
  'by_machine': 'Por máquina',
  'ha_per_hour': 'Área de passadas por hora',
  'worked_area': 'Área trabalhada registrada',
  'stoppages': 'Períodos de parada registrados',
  'assigned_task': 'Tarefa vinculada',
  'history': 'Histórico de alterações',
  'responsible_name': 'Responsável pela fazenda',
  'remaining_ha': 'Área restante (ha)',
  'properties': 'Fazendas',
  'plots': 'Talhões',
  'operations': 'Operações',
  'maintenance': 'Manutenções',
  'stock': 'Estoque',
  'ledger': 'Origens dos custos',
  'programs': 'Programações da safra',
  'filters': 'Filtros aplicados',
  'metrics': 'Indicadores',
  'counts': 'Contagens',
  'property_id': 'Identificador da fazenda',
  'property_name': 'Fazenda',
  'plot_id': 'Identificador do talhão',
  'plot_name': 'Talhão',
  'cycle_id': 'Identificador do ciclo',
  'cycle_name': 'Safra / ciclo',
  'machine_id': 'Identificador da máquina',
  'machine_name': 'Máquina',
  'operator_id': 'Identificador do operador',
  'operator_name': 'Operador',
  'mechanic_id': 'Identificador do mecânico',
  'mechanic_name': 'Mecânico',
  'name': 'Nome',
  'id': 'Identificador',
  'title': 'Título',
  'description': 'Descrição',
  'notes': 'Observações',
  'status': 'Situação',
  'created_at': 'Data do registro',
  'performed_on': 'Data da operação',
  'starts_on': 'Data inicial',
  'ends_on': 'Data final',
  'due_on': 'Previsão de término',
  'area_ha': 'Área (ha)',
  'planned_ha': 'Área programada (ha)',
  'completed_ha': 'Área única concluída (ha)',
  'percent': 'Percentual concluído',
  'machines': 'Máquinas',
  'inputs': 'Insumos',
  'refuelings': 'Abastecimentos',
  'measurements': 'Medições',
  'started_at': 'Horário de início',
  'ended_at': 'Horário de término',
  'consumed_fuel_liters': 'Consumo medido (L)',
  'hours': 'Horas',
  'labor_hours': 'Horas de mão de obra',
  'start_meter': 'Horímetro inicial',
  'end_meter': 'Horímetro final',
  'cost_cents': r'Custo (R$)',
  'amount_cents': r'Valor (R$)',
  'value_cents': r'Valor (R$)',
  'total_cost_cents': r'Valor do abastecimento (R$)',
  'quantity': 'Quantidade',
  'harvest': 'Produção e produtividade agrícola',
  'harvest_output': 'Produção colhida informada',
  'production_kg': 'Produção registrada (kg)',
  'production_per_registered_ha': 'Produção registrada / área do ciclo (kg/ha)',
  'registered_cycle_area_ha': 'Área cadastrada do ciclo (ha)',
  'kg_per_unit': 'Peso por unidade (kg)',
  'quantities_by_unit': 'Quantidades nas unidades originais',
  'missing_outputs': 'Colheitas sem quantidade informada',
  'implements': 'Implementos utilizados',
  'unit': 'Unidade',
  'liters': 'Litros abastecidos',
  'category': 'Categoria',
  'cost_per_ha': 'Custo por hectare atual',
  'general_expenses': 'Despesas gerais sem rateio para talhões',
  'stock_value': 'Valor do estoque atual',
  'productivity': 'Produtividade registrada',
  'daily_worked_passes': 'Área de passadas por dia',
  'by_operator': 'Por operador responsável',
  'forecast': 'Estimativa de término',
  'completion_date': 'Data estimada de conclusão',
  'assumption': 'Premissas da estimativa',
  'daily_unique_ha': 'Média de área única (ha/dia)',
  'labor_cost_cents': 'Custo de mão de obra (centavos)',
  'parts': 'Peças utilizadas',
  'progress': 'Andamento registrado',
  'available_quantity': 'Saldo atual',
  'minimum_quantity': 'Estoque mínimo',
  'low_stock': 'Alerta de estoque',
  'movements': 'Movimentações',
  'activity': 'Atividade',
  'season_name': 'Safra',
  'completed_operations': 'Operações concluídas',
  'programs_pending': 'Talhões programados pendentes',
  'programs_in_progress': 'Talhões programados em andamento',
  'programs_completed': 'Talhões programados concluídos',
  'machines_in_maintenance': 'Máquinas em manutenção',
  'context': 'Identificação na data da operação',
  'void': 'Estorno',
  'property': 'Fazenda',
  'plot': 'Talhão',
  'cycle': 'Ciclo',
  'crop': 'Cultura',
  'kind': 'Tipo',
  'actor_id': 'Autor',
  'date': 'Data',
  'operation_id': 'Operação de origem',
  'order_id': 'Ordem de origem',
  'report_type': 'Tipo de relatório',
  'production': 'Produção e produtividade agrícola',
  'overview': 'Visão geral',
  'costs': 'Custos por categoria',
  'categories': 'Custos por categoria',
  'scope': 'Escopo e limitações',
  'operation_ids': 'Operações de origem',
  'registered_cost': 'Custo registrado',
};
String managementField(String key) =>
    _managementLabels[key] ?? metricNames[key] ?? key;
const _managementHidden = {
  'tenant_id',
  'request_json',
  'photos_json',
  'version',
  'shared_operators',
  'client_id',
  'context_status'
};
String managementDetails(Object? value, [String prefix = '']) {
  if (value == null) return 'Não informado';
  if (value is Map) {
    if (value.containsKey('unit') &&
        value.containsKey('status') &&
        value.containsKey('value')) {
      final m = Map<String, dynamic>.from(value);
      return '${displayMetric(m)} · ${metricStatus(m['status'])}${m['known_subtotal'] != null && m['value'] == null ? ' · subtotal conhecido ${subtotalLabel(m)}' : ''}';
    }
    return value.entries
        .where((e) => !_managementHidden.contains(e.key))
        .map((e) =>
            '$prefix${managementField("${e.key}")}: ${'${e.key}'.endsWith('_cents') && e.value != null ? displayMetric({
                    'value': '${e.value}',
                    'unit': 'BRL_cent'
                  }) : managementDetails(e.value, "$prefix  ")}')
        .join('\n');
  }
  if (value is List) {
    return value.isEmpty
        ? 'Nenhum registro'
        : value.map((e) => managementDetails(e, prefix)).join('\n\n');
  }
  if (value is bool) return value ? 'Sim' : 'Não';
  const words = {
    'production': 'Produção e produtividade agrícola',
    'costs': 'Custos por categoria',
    'overview': 'Visão geral',
    'operations': 'Operações agrícolas',
    'machines': 'Histórico de máquinas',
    'plots': 'Histórico dos talhões',
    'season': 'Acompanhamento da safra',
    'implements': 'Histórico dos implementos',
    'maintenance': 'Oficina e manutenção',
    'pending': 'Pendente',
    'in_progress': 'Em andamento',
    'completed': 'Concluída',
    'cancelled': 'Cancelada',
    'reported': 'Ocorrência relatada',
    'analysis': 'Em análise',
    'waiting_parts': 'Aguardando peças',
    'testing': 'Em testes',
    'ongoing': 'Em aberto',
    'planting': 'Plantio',
    'application': 'Aplicação',
    'management': 'Manejo',
    'harvest': 'Colheita',
    'transport': 'Transporte',
    'other': 'Outras',
    'stock': 'Estoque da fazenda',
    'external': 'Compra em posto',
    'opening': 'Saldo inicial',
    'receipt': 'Entrada',
    'consume': 'Saída',
    'estimate': 'Estimativa'
  };
  if (value is String && words.containsKey(value)) return words[value]!;
  return '$value';
}

String managementTime(Object? raw) {
  final value = DateTime.tryParse('$raw')?.toLocal();
  if (value == null) return 'Não informado';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(value.day)}/${two(value.month)}/${value.year} ${two(value.hour)}:${two(value.minute)}';
}
