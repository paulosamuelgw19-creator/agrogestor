import 'package:flutter/material.dart';
import 'sync_service.dart';

/// Only actionable synchronization states need a persistent warning banner.
class SyncNotice extends StatelessWidget {
  const SyncNotice({super.key, required this.state, this.message});
  final SyncState state;
  final String? message;

  @override
  Widget build(BuildContext context) {
    if (message == null ||
        state == SyncState.idle ||
        state == SyncState.syncing) {
      return const SizedBox.shrink();
    }
    return Material(
        color: Colors.orange.shade50,
        child: ListTile(
            dense: true,
            leading: Icon(
                state == SyncState.pending
                    ? Icons.cloud_upload_outlined
                    : Icons.sync_problem_outlined,
                color: Colors.deepOrange),
            title: Text(message!, style: const TextStyle(fontSize: 13))));
  }
}
