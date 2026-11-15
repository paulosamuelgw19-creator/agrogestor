import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../auth/farm_access_policy.dart';
import '../operations_v2/v2_store.dart' show Json;
import '../properties/catalog_store.dart';
import 'coffee_analysis_screen.dart';

class CoffeeAnalysisCatalogScreen extends StatefulWidget {
  const CoffeeAnalysisCatalogScreen({super.key});

  @override
  State<CoffeeAnalysisCatalogScreen> createState() =>
      _CoffeeAnalysisCatalogScreenState();
}

class _CoffeeAnalysisCatalogScreenState
    extends State<CoffeeAnalysisCatalogScreen> {
  late Future<({List<Json> farms, List<Json> plots})> _catalog = _load();

  Future<({List<Json> farms, List<Json> plots})> _load() async {
    FarmAccessPolicy.requireCoffeeManager();
    final store = await CatalogStore.open();
    return (
      farms: await store.records('properties'),
      plots: await store.records('plots'),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
        future: _catalog,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: TextButton(
                onPressed: () => setState(() {
                  _catalog = _load();
                }),
                child: const Text('Tentar abrir Análises novamente'),
              ),
            );
          }
          final catalog = snapshot.data;
          if (catalog == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 700),
              child: ListView(
                padding: AppTheme.pagePadding(context),
                children: [
                  Text(
                    'Análises de solo e folha',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    catalog.plots.isEmpty
                        ? 'Cadastre um talhão em Propriedades.'
                        : 'Escolha o talhão para consultar os laudos.',
                  ),
                  for (final farm in catalog.farms)
                    for (final plot in catalog.plots.where(
                      (plot) => plot['property_id'] == farm['id'],
                    ))
                      Card(
                        child: ListTile(
                          title: Text('${plot['name']}'),
                          subtitle: Text(
                            '${farm['name']}${plot['archived'] == 1 || farm['archived'] == 1 ? ' · Arquivado' : ''}',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context).push<void>(
                            MaterialPageRoute(
                              builder: (_) => CoffeeAnalysisScreen(
                                property: farm,
                                plot: plot,
                              ),
                            ),
                          ),
                        ),
                      ),
                ],
              ),
            ),
          );
        },
      );
}
