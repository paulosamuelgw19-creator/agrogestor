import 'package:flutter/material.dart';

import '../clients/client_repository.dart';
import '../fuel/fuel_repository.dart';
import '../implements/implement_repository.dart';
import '../machines/machine_repository.dart';
import '../maintenance/maintenance_repository.dart';
import '../operators/operator_repository.dart';
import '../products/product_repository.dart';
import '../services/service_repository.dart';

class SearchHit {
  const SearchHit({
    required this.title,
    required this.detail,
    required this.searchableText,
    required this.destination,
  });

  final String title;
  final String detail;
  final String searchableText;
  final int destination;
}

class GlobalSearchDelegate extends SearchDelegate<SearchHit?> {
  GlobalSearchDelegate({this.allowsDestination, this.entitlementChanges});

  final bool Function(int)? allowsDestination;
  final Listenable? entitlementChanges;
  late final Future<List<SearchHit>> _hits = _loadHits();
  bool _allows(int destination) => allowsDestination?.call(destination) ?? true;
  @override
  String get searchFieldLabel => 'Buscar nos registros';

  @override
  List<Widget> buildActions(BuildContext context) => [
        if (query.isNotEmpty)
          IconButton(
            tooltip: 'Limpar busca',
            onPressed: () => query = '',
            icon: const Icon(Icons.clear),
          ),
      ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
        tooltip: 'Voltar',
        onPressed: () => close(context, null),
        icon: const Icon(Icons.arrow_back),
      );

  @override
  Widget buildSuggestions(BuildContext context) => _results();

  @override
  Widget buildResults(BuildContext context) => _results();

  Widget _results() {
    final changes = entitlementChanges;
    return changes == null
        ? _resultsFromHits()
        : ListenableBuilder(
            listenable: changes, builder: (context, _) => _resultsFromHits());
  }

  Widget _resultsFromHits() => FutureBuilder<List<SearchHit>>(
        future: _hits,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(
                child: Text('Não foi possível carregar a busca.'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final term = query.trim().toLowerCase();
          final hits = snapshot.data!.where((hit) {
            return _allows(hit.destination) &&
                (term.isEmpty ||
                    hit.searchableText.toLowerCase().contains(term));
          }).toList();
          if (hits.isEmpty) {
            return const Center(child: Text('Nenhum resultado encontrado.'));
          }
          return ListView.builder(
            itemCount: hits.length,
            itemBuilder: (context, index) {
              final hit = hits[index];
              return ListTile(
                leading: const Icon(Icons.search),
                title: Text(hit.title),
                subtitle: Text(hit.detail),
                onTap: () {
                  if (_allows(hit.destination)) close(context, hit);
                },
              );
            },
          );
        },
      );

  Future<List<SearchHit>> _loadHits() async {
    final hits = <SearchHit>[];
    for (final item
        in _allows(1) ? await MachineRepository().getAll() : const []) {
      hits.add(
        SearchHit(
          title: item.name,
          detail: 'Máquina · ${item.brand} ${item.model}',
          searchableText:
              '${item.name} ${item.brand} ${item.model} ${item.plate} ${item.serialNumber}',
          destination: 1,
        ),
      );
    }
    for (final item
        in _allows(4) ? await OperatorRepository().getAll() : const []) {
      hits.add(
        SearchHit(
          title: item.name,
          detail: 'Operador · ${item.role}',
          searchableText: '${item.name} ${item.phone} ${item.role}',
          destination: 4,
        ),
      );
    }
    for (final item
        in _allows(5) ? await ImplementRepository().getAll() : const []) {
      hits.add(
        SearchHit(
          title: item.name,
          detail: 'Implemento · ${item.type}',
          searchableText:
              '${item.name} ${item.type} ${item.brand} ${item.model}',
          destination: 5,
        ),
      );
    }
    for (final item
        in _allows(2) ? await ServiceRepository().getAll() : const []) {
      hits.add(
        SearchHit(
          title: item.jobType,
          detail: 'Serviço · ${item.machineName} · ${item.customer}',
          searchableText:
              '${item.jobType} ${item.machineName} ${item.operatorName} ${item.customer} ${item.property} ${item.fieldName}',
          destination: 2,
        ),
      );
    }
    for (final item
        in _allows(3) ? await MaintenanceRepository().getAll() : const []) {
      hits.add(
        SearchHit(
          title: item.type,
          detail: 'Manutenção · ${item.machineName}',
          searchableText:
              '${item.type} ${item.machineName} ${item.description} ${item.parts}',
          destination: 3,
        ),
      );
    }
    for (final item
        in _allows(6) ? await FuelRepository().getAll() : const []) {
      hits.add(
        SearchHit(
          title: 'Abastecimento · ${item.machineName}',
          detail: '${item.liters.toStringAsFixed(1)} L · ${item.operatorName}',
          searchableText:
              '${item.machineName} ${item.operatorName} ${item.location}',
          destination: 6,
        ),
      );
    }
    for (final item
        in _allows(7) ? await ProductRepository().getProducts() : const []) {
      hits.add(
        SearchHit(
          title: item.name,
          detail: 'Produto · ${item.category}',
          searchableText: '${item.name} ${item.category} ${item.lot}',
          destination: 7,
        ),
      );
    }
    for (final item
        in _allows(8) ? await ClientRepository().getAll() : const []) {
      hits.add(
        SearchHit(
          title: item.name,
          detail: 'Cliente · ${item.phone}',
          searchableText:
              '${item.name} ${item.document} ${item.phone} ${item.address} ${item.properties.map((p) => p.name).join(' ')} ${item.properties.expand((p) => p.fields.map((f) => f.name)).join(' ')}',
          destination: 8,
        ),
      );
    }
    return hits;
  }
}
