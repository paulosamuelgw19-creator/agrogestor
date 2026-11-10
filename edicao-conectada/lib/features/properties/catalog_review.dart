import 'dart:convert';
import 'package:flutter/material.dart';
import 'catalog_store.dart';

/// User-driven retry only: rejected drafts never return to the automatic queue.
Future<void> reviewCatalogDrafts(BuildContext context) async {
  final store = await CatalogStore.open();
  final rows = await store.pending();
  if (!context.mounted) return;
  await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
            title: const Text('Conferir cadastros salvos'),
            content: SizedBox(
                width: 500,
                child: SingleChildScrollView(
                    child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                        'Os rascunhos permanecem neste aparelho. Confira os dados e solicite ao gestor a regularização do plano antes de tentar novamente.'),
                    if (rows.isEmpty)
                      const Text('Nenhum cadastro aguardando confirmação.'),
                    for (final row in rows)
                      ListTile(
                        title: Text(
                            '${(jsonDecode(row['payload'] as String) as Map)['name'] ?? 'Cadastro'}'),
                        subtitle: Text(row['error'] as String? ??
                            'Aguardando confirmação do PC gestor.'),
                      ),
                  ],
                ))),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Manter salvo')),
              if (rows.any((r) => r['state'] == 'conflict'))
                FilledButton(
                    onPressed: () async {
                      await store.retryReviewedDrafts();
                      if (dialogContext.mounted) Navigator.pop(dialogContext);
                      await store.sync();
                    },
                    child: const Text('Conferi · solicitar nova validação')),
            ],
          ));
}
