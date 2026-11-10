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
  late final Future<List<SearchHit>> _hits = _loadHits();
  @override
  String get searchFieldLabel => 'Máquina, serviço, cliente...';

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

  Widget _results() => FutureBuilder<List<SearchHit>>(
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
            return term.isEmpty ||
                hit.searchableText.toLowerCase().contains(term);
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
                onTap: () => close(context, hit),
              );
            },
          );
        },
      );

  Future<List<SearchHit>> _loadHits() async {
    final hits = <SearchHit>[];
    for (final item in await MachineRepository().getAll()) {
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
    for (final item in await OperatorRepository().getAll()) {
      hits.add(
        SearchHit(
          title: item.name,
          detail: 'Operador · ${item.role}',
          searchableText: '${item.name} ${item.phone} ${item.role}',
          destination: 4,
        ),
      );
    }
    for (final item in await ImplementRepository().getAll()) {
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
    for (final item in await ServiceRepository().getAll()) {
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
    for (final item in await MaintenanceRepository().getAll()) {
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
    for (final item in await FuelRepository().getAll()) {
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
    for (final item in await ProductRepository().getProducts()) {
      hits.add(
        SearchHit(
          title: item.name,
          detail: 'Produto · ${item.category}',
          searchableText: '${item.name} ${item.category} ${item.lot}',
          destination: 7,
        ),
      );
    }
    for (final item in await ClientRepository().getAll()) {
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
