import 'package:flutter_test/flutter_test.dart';
import 'package:agrogestao/features/fuel/fuel_record.dart';
import 'package:agrogestao/features/machines/machine.dart';
import 'package:agrogestao/features/maintenance/maintenance_record.dart';
import 'package:agrogestao/features/services/farm_service.dart';

void main() {
  group('cálculos de operação', () {
    test('calcula horas trabalhadas usando a diferença dos horímetros', () {
      final service = FarmService(
        id: 'service-1',
        machineId: 'machine-1',
        machineName: 'Trator',
        operatorName: 'João',
        customer: '',
        property: '',
        jobType: 'Plantio',
        startedAt: DateTime(2026, 10, 7, 8),
        startMeter: 1284.5,
      ).finishWith(
        endMeter: 1287.0,
        fuelLiters: 30,
        areaHectares: 12,
        notes: '',
      );

      expect(service.isFinished, isTrue);
      expect(service.workedHours, 2.5);
      expect(service.fuelLiters, 30);
      expect(service.areaHectares, 12);
    });

    test('calcula custo do abastecimento', () {
      final record = FuelRecord(
        id: 'fuel-1',
        machineId: 'machine-1',
        machineName: 'Trator',
        operatorName: 'João',
        date: DateTime(2026, 10, 7),
        hourMeter: 1284.5,
        liters: 75,
        pricePerLiter: 6.2,
        location: 'Fazenda',
      );

      expect(record.totalCost, closeTo(465, 0.001));
    });

    test('calcula o horímetro da próxima manutenção', () {
      final record = MaintenanceRecord(
        id: 'maintenance-1',
        machineId: 'machine-1',
        machineName: 'Trator',
        date: DateTime(2026, 10, 7),
        hourMeter: 1000,
        type: 'Troca de óleo',
        description: '',
        parts: '',
        cost: 250,
        intervalHours: 250,
      );

      expect(record.nextDueMeter, 1250);
    });
  });

  test('preserva os dados da máquina ao atualizar horímetro e status', () {
    const machine = Machine(
      id: 'machine-1',
      name: 'Trator principal',
      brand: 'Marca',
      model: 'Modelo',
      year: 2024,
      hourMeter: 100,
      fuelType: 'Diesel',
      status: MachineStatus.disponivel,
      serialNumber: 'SN-42',
    );

    final updated = machine.copyWith(
      hourMeter: 101.5,
      status: MachineStatus.emOperacao,
    );

    expect(updated.hourMeter, 101.5);
    expect(updated.status, MachineStatus.emOperacao);
    expect(updated.serialNumber, 'SN-42');
    expect(updated.id, machine.id);
  });
}
