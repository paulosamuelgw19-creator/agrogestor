"""Back up SQLite and rehearse the additive commercial migration before deployment.

Usage: python tool/commercial_backup.py SOURCE_DB NEW_BACKUP_DIRECTORY
No existing backup is overwritten. Live application data is never migrated here.
"""
import hashlib
import json
import shutil
import sqlite3
import sys
from contextlib import closing
from pathlib import Path


def snapshot(db, columns=None):
    tables = columns or {r[0]: [c[1] for c in db.execute('PRAGMA table_info("'+r[0]+'")')]
                         for r in db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT IN ('sqlite_sequence','v2_migrations')")}
    result = {}
    for table, fields in tables.items():
        rows = sorted(json.dumps(list(r), default=str) for r in db.execute(
            'SELECT '+','.join('"'+f+'"' for f in fields)+' FROM "'+table+'"'))
        result[table] = {'columns': fields, 'rows': len(rows),
                         'sha256': hashlib.sha256('\n'.join(rows).encode()).hexdigest()}
    return result


def main():
    source, folder = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
    if not source.is_file():
        raise FileNotFoundError('Banco de origem ausente; nenhum banco novo foi criado.')
    folder.mkdir(parents=True, exist_ok=False)
    with closing(sqlite3.connect(source.as_uri()+'?mode=ro',uri=True)) as original, closing(sqlite3.connect(folder/'before.sqlite3')) as backup:
        original.backup(backup)
    restored = folder/'restored-rehearsal.sqlite3'
    shutil.copy2(folder/'before.sqlite3', restored)
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'server'))
    from agrogestor_server import commercial, v2_schema
    with closing(sqlite3.connect(restored)) as db:
        db.row_factory = sqlite3.Row
        assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
        before = snapshot(db)
        commercial.initialize(db); db.commit()
        if commercial.table(db, 'v2_migrations'):
            v2_schema.migrate(db); db.commit()
            v2_schema.migrate(db); db.commit()
        after = snapshot(db, {t: v['columns'] for t,v in before.items()})
        assert before == after
        assert not db.execute('PRAGMA foreign_key_check').fetchall()
        assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
    (folder/'validation.json').write_text(json.dumps({'before': before, 'restored': True,
        'old_rows_equal': True, 'integrity': 'ok', 'foreign_key_errors': 0}, indent=2), encoding='utf-8')
    print('Backup e ensaio de restauração/migração aprovados. Registros anteriores preservados.')


if __name__ == '__main__':
    main()
