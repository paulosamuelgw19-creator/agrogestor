import 'package:flutter/material.dart';
import 'sync_service.dart';

class SyncStatusLabel extends StatelessWidget {
  const SyncStatusLabel(
      {super.key, required this.module, required this.recordId});
  final String module;
  final String recordId;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: SyncService(),
        builder: (context, _) => FutureBuilder<String?>(
          future: SyncService().recordState(module, recordId),
          builder: (context, snapshot) {
            final state = snapshot.data;
            if (state == null) return const SizedBox.shrink();
            final (label, icon, color) = switch (state) {
              'synced' => (
                  'Sincronizado',
                  Icons.cloud_done_outlined,
                  Colors.green.shade700
                ),
              'pending' || 'sending' => (
                  'Pendente',
                  Icons.schedule,
                  Colors.orange.shade800
                ),
              'conflict' => ('Conflito', Icons.sync_problem, Colors.deepOrange),
              'error' => (
                  'Erro de envio',
                  Icons.error_outline,
                  Colors.red.shade700
                ),
              _ => ('Pendente', Icons.schedule, Colors.orange.shade800),
            };
            return Tooltip(
              message: label,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 3),
                Text(label,
                    style: TextStyle(
                        fontSize: 10,
                        color: color,
                        fontWeight: FontWeight.w600)),
              ]),
            );
          },
        ),
      );
}
