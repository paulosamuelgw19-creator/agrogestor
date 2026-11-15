import hashlib
import sqlite3
import sys
import tempfile
import unittest
import zipfile
from contextlib import closing
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tool"))
from manutencao_servidor import DATABASE, compact, create, restore


class MaintenanceTests(unittest.TestCase):
    def test_compact_pc_restore_and_reject_wrong_client_or_zip_member(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            data = root / "pc"
            data.mkdir()
            document = b"synthetic attachment" * 100
            attachment = data / "attachments/fake-org/notebook-test-photo"
            attachment.parent.mkdir(parents=True)
            attachment.write_bytes(document)
            database = data / DATABASE["pc-a"]
            with closing(sqlite3.connect(database)) as db:
                db.executescript("""
                    CREATE TABLE farm(singleton integer, farm_id text);
                    INSERT INTO farm VALUES (1,'fake-org');
                    CREATE TABLE records(module text,record_id text,payload text);
                    CREATE TABLE changes(module text,payload text);
                    INSERT INTO records VALUES ('plotNotebook','note','{}');
                    CREATE TABLE attachments(farm_id text,attachment_id text,size_bytes integer,sha256 text);
                    CREATE TABLE unused(data blob);
                    INSERT INTO unused VALUES (zeroblob(1000000));
                    DELETE FROM unused;
                """)
                db.execute("INSERT INTO attachments VALUES(?,?,?,?)",
                    ("fake-org", attachment.name, len(document), hashlib.sha256(document).hexdigest()))
                db.commit()
            archive = root / "backup.zip"
            with patch("manutencao_servidor.socket.socket") as listener:
                listener.return_value.__enter__.return_value.connect_ex.return_value = 0
                with self.assertRaisesRegex(ValueError, "Pare o servidor"):
                    compact(data, "pc-a", "fake-org", archive)
                listener.return_value.__enter__.return_value.connect_ex.return_value = 10061
                before, after = compact(data, "pc-a", "fake-org", archive)
            self.assertLess(after, before)
            recovered = root / "restore"
            restore(archive, recovered, "pc-a", "fake-org")
            self.assertEqual((recovered / attachment.relative_to(data)).read_bytes(), document)
            with closing(sqlite3.connect(recovered / database.name)) as db:
                self.assertEqual(db.execute("SELECT * FROM records").fetchall(), [("plotNotebook", "note", "{}")])
            with self.assertRaisesRegex(ValueError, "outro serviço ou cliente"):
                restore(archive, root / "wrong", "pc-a", "wrong")
            self.assertFalse((root / "wrong").exists())
            with zipfile.ZipFile(archive, "a") as bad:
                bad.writestr("../outside", b"test")
            with self.assertRaises(ValueError):
                restore(archive, root / "bad", "pc-a", "fake-org")
            self.assertFalse((root / "bad").exists())
            attachment.write_bytes(b"corrupted")
            with self.assertRaisesRegex(ValueError, "Anexo ausente ou alterado"):
                create(data, "pc-a", "fake-org", root / "incomplete.zip")
            self.assertFalse((root / "incomplete.zip").exists())

    def test_central_snapshot_and_restore_preserve_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            data = root / "central"
            data.mkdir()
            database = data / DATABASE["central"]
            with closing(sqlite3.connect(database)) as db:
                db.executescript("""
                    CREATE TABLE admins(username text);
                    CREATE TABLE commercial_contracts(farm_id text, contract text);
                    INSERT INTO admins VALUES ('test');
                    INSERT INTO commercial_contracts VALUES ('fake-org','valid');
                """)
            archive = root / "central.zip"
            create(data, "central", None, archive)
            restore(archive, root / "copy", "central", None)
            with closing(sqlite3.connect(root / "copy" / database.name)) as db:
                self.assertEqual(db.execute("SELECT * FROM commercial_contracts").fetchall(), [("fake-org", "valid")])
