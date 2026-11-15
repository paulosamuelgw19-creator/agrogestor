"""Compact SQLite and archive server data for the Café Conectado pilot."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import socket
import sqlite3
import tempfile
import zipfile
from contextlib import closing
from pathlib import Path

from piloto_conectado import CONFIG, SERVICES, STATE, configuration

DATABASE = {"central": "central-licenses.sqlite3", "pc-a": "agrogestor.sqlite3",
            "pc-b": "agrogestor.sqlite3"}
LIMIT = 20 * 1024**3
BUFFER = 1024**2


def hash_file(path: Path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(BUFFER), b""):
            digest.update(block)
    return digest.hexdigest()


def files_for(root: Path, name: str, identity: str | None, *, attachment_root: Path | None = None):
    media_root = attachment_root or root
    database = root / DATABASE[name]
    if not database.is_file() or database.is_symlink():
        raise ValueError("Banco de dados ausente ou inválido.")
    files = {DATABASE[name]: database}
    with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)) as db:
        db.execute("PRAGMA trusted_schema=OFF")
        if db.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
            raise ValueError("Falha de integridade no SQLite.")
        if db.execute("PRAGMA foreign_key_check").fetchone() is not None:
            raise ValueError("Há vínculos inválidos no SQLite.")
        if name == "central":
            db.execute("SELECT username FROM admins LIMIT 1").fetchall()
            db.execute("SELECT farm_id FROM commercial_contracts LIMIT 1").fetchall()
        else:
            if db.execute("SELECT farm_id FROM farm WHERE singleton=1").fetchall() != [(identity,)]:
                raise ValueError("O banco pertence a outro cliente.")
            db.execute("SELECT module,record_id FROM records LIMIT 1").fetchall()
            for farm, attachment, size, digest in db.execute(
                    "SELECT farm_id,attachment_id,size_bytes,sha256 FROM attachments"):
                if (farm != identity or not re.fullmatch(r"[A-Za-z0-9_-]{16,80}", attachment)
                        or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,160}", farm)
                        or farm in {".", ".."} or not 0 < size <= 10 * BUFFER):
                    raise ValueError("Metadados de anexo inválidos.")
                key = f"attachments/{farm}/{attachment}"
                file = media_root / key
                if (file.resolve().parent != (media_root / "attachments" / farm)
                        or file.is_symlink() or not file.is_file()
                        or file.stat().st_size != size or hash_file(file) != digest):
                    raise ValueError(f"Anexo ausente ou alterado: {attachment}")
                files[key] = file
            for table in ("records", "changes"):
                for (payload,) in db.execute(
                        f"SELECT payload FROM {table} WHERE module IN ('machines', 'plotNotebook') AND payload IS NOT NULL"):
                    document = json.loads(payload)
                    attachment = document.get("photoAttachmentId")
                    if attachment is not None and f"attachments/{identity}/{attachment}" not in files:
                        raise ValueError("Uma foto referenciada não está cadastrada no backup.")
    return files


def create(root: Path, name: str, identity: str | None, output: Path):
    root = root.resolve()
    output = output.resolve()
    if output.exists() or output.is_relative_to(root):
        raise ValueError("Escolha um arquivo novo, fora da pasta de dados.")
    # Registered attachments are immutable. A missing member aborts publication.
    dbpath = root / DATABASE[name]
    if dbpath.is_symlink() or not dbpath.is_file():
        raise ValueError("Banco de dados ausente ou inválido.")
    with tempfile.TemporaryDirectory(dir=output.parent) as temp:
        staging = Path(temp)
        snapshot = staging / DATABASE[name]
        with closing(sqlite3.connect(dbpath.as_uri() + "?mode=ro", uri=True)) as source:
            # VACUUM INTO includes committed WAL data and omits SQLite free pages.
            source.execute("VACUUM INTO ?", (str(snapshot),))
        # Validate against the snapshot and use the source only for immutable files.
        files = files_for(staging, name, identity, attachment_root=root)
        entries = {}
        candidate = staging / "archive.zip"
        with zipfile.ZipFile(candidate, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for key, path in files.items():
                entries[key] = {"size": path.stat().st_size, "sha256": hash_file(path)}
                archive.write(path, key)
            archive.writestr("manifest.json", json.dumps({
                "format": 1, "service": name, "organization": identity, "files": entries,
            }))
        restore(candidate, staging / "validated", name, identity)
        os.rename(candidate, output)
        return sum(entry["size"] for entry in entries.values()), output.stat().st_size


def restore(archive_path: Path, dest: Path, name: str, identity: str | None):
    if dest.exists():
        raise ValueError("O destino precisa ser uma pasta nova.")
    with tempfile.TemporaryDirectory(dir=dest.parent) as temp:
        staging = Path(temp) / "restored"
        staging.mkdir()
        with zipfile.ZipFile(archive_path) as archive:
            members = archive.infolist()
            names = {item.filename for item in members}
            if len(names) != len(members) or "manifest.json" not in names:
                raise ValueError("ZIP com entradas duplicadas ou sem manifesto.")
            if (len(members) > 200000 or sum(item.file_size for item in members) > LIMIT
                    or archive.getinfo("manifest.json").file_size > 32 * BUFFER):
                raise ValueError("Limite de restauração excedido.")
            manifest = json.loads(archive.read("manifest.json"))
            if (manifest["format"], manifest["service"], manifest["organization"]) != (1, name, identity):
                raise ValueError("O backup pertence a outro serviço ou cliente.")
            entries = manifest["files"]
            if set(entries) != names - {"manifest.json"} or DATABASE[name] not in entries:
                raise ValueError("O conteúdo não corresponde ao manifesto.")
            allowed = re.compile(r"attachments/" + re.escape(identity or "") + r"/[A-Za-z0-9_-]{16,80}")
            for key, expected in entries.items():
                if key != DATABASE[name] and (name == "central" or not allowed.fullmatch(key)):
                    raise ValueError("Caminho inválido no backup.")
                size = archive.getinfo(key).file_size
                if size != expected["size"]:
                    raise ValueError("Tamanho divergente no backup.")
                path = staging / key
                path.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(key) as member, path.open("xb") as target:
                    remaining = size
                    for block in iter(lambda: member.read(BUFFER), b""):
                        remaining -= len(block)
                        if remaining < 0:
                            raise ValueError("Tamanho descompactado acima do declarado.")
                        target.write(block)
                if remaining or hash_file(path) != expected["sha256"]:
                    raise ValueError("Arquivo incompleto ou alterado.")
            if set(files_for(staging, name, identity)) != set(entries):
                raise ValueError("O backup contém anexos sem vínculo.")
        os.rename(staging, dest)


def compact(root: Path, name: str, identity: str | None, output: Path):
    with socket.socket() as sock:
        sock.settimeout(1)
        if sock.connect_ex(("127.0.0.1", SERVICES[name])) == 0:
            raise ValueError("Pare o servidor antes de compactar o banco em uso.")
    database = files_for(root, name, identity)[DATABASE[name]]
    before = database.stat().st_size
    create(root, name, identity, output)
    with closing(sqlite3.connect(database.as_uri() + "?mode=rw", uri=True, timeout=0)) as db:
        db.execute("VACUUM")
        if db.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()[0]:
            raise ValueError("A compactação foi feita, mas o WAL continua ocupado.")
    files_for(root, name, identity)
    return before, database.stat().st_size


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("backup", "restaurar", "compactar"))
    parser.add_argument("service", choices=SERVICES)
    parser.add_argument("path", type=Path, help="ZIP ou banco restaurado em pasta nova")
    parser.add_argument("destination", type=Path, nargs="?")
    args = parser.parse_args()
    if not CONFIG.is_file():
        parser.error("Ambiente piloto ausente.")
    identity = None if args.service == "central" else configuration()[args.service]["id"]
    root = (STATE / args.service).resolve()
    try:
        path = args.path.resolve()
        if args.action == "backup":
            source, packed = create(root, args.service, identity, path)
            print(f"Backup criado: {source} bytes antes do ZIP, {packed} bytes compactados.")
        elif args.action == "restaurar":
            if args.destination is None:
                parser.error("Informe a pasta nova de destino.")
            restore(path, args.destination.resolve(), args.service, identity)
            print("Cópia restaurada e verificada. Banco em uso preservado.")
        else:
            if path.is_relative_to(root) or path.suffix.lower() != ".zip":
                parser.error("Informe um ZIP de segurança fora da pasta de dados.")
            before, after = compact(root, args.service, identity, path)
            print(f"SQLite: {before} bytes antes, {after} bytes depois.")
    except (OSError, ValueError, KeyError, TypeError, sqlite3.Error, zipfile.BadZipFile) as error:
        parser.exit(1, f"Operação interrompida: {error}\n")


if __name__ == "__main__":
    main()
