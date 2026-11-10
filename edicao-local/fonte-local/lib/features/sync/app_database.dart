import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class LocalRecord {
  const LocalRecord({required this.values});
  final Map<String, Object?> values;
  String get farmId => values['farm_id']! as String;
  String get module => values['module']! as String;
  String get recordId => values['record_id']! as String;
  String get payload => values['payload']! as String;
  int get serverVersion => values['server_version']! as int;
  bool get isDeleted => dbBool(values['is_deleted']);
  bool get remoteDeleted => dbBool(values['remote_deleted']);
  String? get remotePayload => values['remote_payload'] as String?;
}

class SyncOutboxEntry {
  const SyncOutboxEntry({required this.values});
  final Map<String, Object?> values;
  String get eventId => values['event_id']! as String;
  String get farmId => values['farm_id']! as String;
  String get module => values['module']! as String;
  String get recordId => values['record_id']! as String;
  String get operation => values['operation']! as String;
  String? get payload => values['payload'] as String?;
  int get baseVersion => values['base_version']! as int;
  int get attempts => values['attempts']! as int;
  String get state => values['state']! as String;
  String? get lastError => values['last_error'] as String?;
}

class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();
  Database? _database;
  Future<Database>? _opening;

  Future<Database> get database async {
    if (_database != null) return _database!;
    final pending = _opening ??= _open();
    try {
      return await pending;
    } catch (_) {
      if (identical(_opening, pending)) _opening = null;
      rethrow;
    }
  }

  Future<Database> _open() async {
    if (kIsWeb) {
      throw UnsupportedError(
          'A fila SQLite do AgroGestor está disponível no Android e Windows.');
    }
    if (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final directory = await getApplicationSupportDirectory();
    final path =
        '${directory.path}${defaultTargetPlatform == TargetPlatform.windows ? r'\' : '/'}agrogestor_offline.sqlite3';
    final opened = await openPath(path);
    _database = opened;
    return opened;
  }

  Future<void> close() async {
    final opened = _database;
    _database = null;
    _opening = null;
    await opened?.close();
  }

  static Future<Database> openPath(String path) => openDatabase(
        path,
        // Each Flutter engine owns a native connection. Sharing the native handle
        // lets sqflite's hot-restart recovery ROLLBACK another engine's transaction.
        singleInstance: false,
        version: 1,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
          await db.rawQuery('PRAGMA busy_timeout = 15000');
          // journal_mode returns a result row, so it must use rawQuery rather
          // than execute. Using execute makes sqflite abort database opening.
          await db.rawQuery('PRAGMA journal_mode = WAL');
        },
        onOpen: (db) async {
          await db.execute('''CREATE TABLE IF NOT EXISTS local_audit (
            id TEXT PRIMARY KEY, actor_id TEXT NOT NULL, changed_at TEXT NOT NULL,
            module TEXT NOT NULL, record_id TEXT NOT NULL, operation TEXT NOT NULL,
            previous_payload TEXT, payload TEXT)''');
        },
        onCreate: (db, version) async {
          await db.execute('''CREATE TABLE local_records (
          farm_id TEXT NOT NULL,
          module TEXT NOT NULL,
          record_id TEXT NOT NULL,
          payload TEXT NOT NULL,
          server_version INTEGER NOT NULL DEFAULT 0,
          sync_state TEXT NOT NULL DEFAULT 'synced',
          sync_error TEXT,
          remote_payload TEXT,
          remote_deleted INTEGER NOT NULL DEFAULT 0,
          is_deleted INTEGER NOT NULL DEFAULT 0,
          changed_at TEXT NOT NULL,
          PRIMARY KEY (farm_id,module,record_id)
        )''');
          await db.execute('''CREATE TABLE sync_outbox (
          event_id TEXT PRIMARY KEY,
          farm_id TEXT NOT NULL,
          module TEXT NOT NULL,
          record_id TEXT NOT NULL,
          operation TEXT NOT NULL,
          payload TEXT,
          base_version INTEGER NOT NULL,
          created_at TEXT NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0,
          state TEXT NOT NULL DEFAULT 'pending',
          last_error TEXT
        )''');
          await db.execute(
              'CREATE INDEX sync_outbox_order_idx ON sync_outbox(farm_id,state,created_at)');
          await db.execute('''CREATE TABLE sync_metadata (
          farm_id TEXT NOT NULL,
          key TEXT NOT NULL,
          value TEXT NOT NULL,
          PRIMARY KEY (farm_id,key)
        )''');
        },
      );
}

final appDatabase = AppDatabase.instance;

DateTime? parseDbDate(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;
bool dbBool(Object? value) => value == true || value == 1;
