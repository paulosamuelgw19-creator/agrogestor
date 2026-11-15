class SyncConflictWriteBlocked implements Exception {
  const SyncConflictWriteBlocked(this.message);
  final String message;

  @override
  String toString() => message;
}
