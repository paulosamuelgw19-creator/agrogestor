from __future__ import annotations

import argparse
import getpass
import os
import secrets
import shutil
import sqlite3
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

from dotenv import load_dotenv

from . import app as api


def init_admin() -> None:
    api.initialize_database()
    with api.connect() as connection:
        exists = connection.execute("SELECT 1 FROM farm WHERE singleton=1").fetchone()
        if exists:
            print("Esta pasta já tem uma fazenda configurada. Para proteger os dados, o assistente não cria outra.")
            raise SystemExit(2)
    farm_name = input("Nome da fazenda: ").strip()
    email = input("E-mail do administrador: ").strip().lower()
    display_name = input("Nome do administrador: ").strip()
    while True:
        password = getpass.getpass("Senha (mínimo 12 caracteres): ")
        confirm = getpass.getpass("Confirme a senha: ")
        if password != confirm:
            print("As senhas não conferem.")
        elif len(password) < 12:
            print("A senha precisa ter ao menos 12 caracteres.")
        else:
            break
    if not farm_name or not display_name or "@" not in email:
        raise SystemExit("Informe nome da fazenda, nome e e-mail válidos.")
    farm_id = str(uuid.uuid4())
    with api.connect() as connection:
        connection.execute("INSERT INTO farm(singleton,farm_id,name) VALUES(1,?,?)", (farm_id, farm_name))
        connection.execute(
            "INSERT INTO users(user_id,farm_id,email,display_name,role,password_hash,created_at) VALUES(?,?,?,?,?,?,?)",
            (str(uuid.uuid4()), farm_id, email, display_name, "admin", api.password_hash.hash(password), api.utc_now()),
        )
    print(f"Fazenda configurada. ID local: {farm_id}")
    print("Guarde o backup da pasta de dados em local separado e protegido.")


def backup(destination: Path) -> None:
    api.initialize_database()
    destination = destination.resolve()
    if destination.exists():
        raise SystemExit(f"O destino já existe: {destination}")
    destination.mkdir(parents=True)
    source = sqlite3.connect(api.DB_PATH)
    target = sqlite3.connect(destination / "agrogestor.sqlite3")
    try:
        source.backup(target)
    finally:
        target.close()
        source.close()
    if api.ATTACHMENTS_DIR.exists():
        shutil.copytree(api.ATTACHMENTS_DIR, destination / "attachments", dirs_exist_ok=True)
    print(f"Backup criado em: {destination}")
    print("O SQLite foi copiado com sua rotina de backup. Para máxima consistência das fotos, faça o backup com o serviço parado.")


def restore(source: Path) -> None:
    api.initialize_database()
    source = source.resolve()
    backup_db = source / "agrogestor.sqlite3"
    if not backup_db.is_file():
        raise SystemExit(f"Banco de backup não encontrado: {backup_db}")
    validation = sqlite3.connect(backup_db)
    try:
        ok = validation.execute("PRAGMA integrity_check").fetchone()
        if not ok or ok[0] != "ok":
            raise SystemExit("O backup não passou pela verificação de integridade.")
    finally:
        validation.close()
    src = sqlite3.connect(backup_db)
    dst = sqlite3.connect(api.DB_PATH)
    try:
        src.backup(dst)
    finally:
        dst.close()
        src.close()
    restored_attachments = source / "attachments"
    if api.ATTACHMENTS_DIR.exists():
        shutil.rmtree(api.ATTACHMENTS_DIR)
    if restored_attachments.exists():
        shutil.copytree(restored_attachments, api.ATTACHMENTS_DIR)
    print("Backup restaurado. Inicie o serviço para conferir o estado da fazenda.")


def list_devices() -> None:
    api.initialize_database()
    with api.connect() as connection:
        farm = connection.execute("SELECT farm_id FROM farm WHERE singleton=1").fetchone()
        if farm is None:
            raise SystemExit("Configure primeiro o administrador da fazenda.")
        rows = connection.execute("SELECT device_id,device_name,activated_at,last_seen_at,revoked_at FROM devices WHERE farm_id=? ORDER BY activated_at", (farm["farm_id"],)).fetchall()
    if not rows:
        print("Nenhum aparelho ativado.")
        return
    for row in rows:
        status = "ativo" if row["revoked_at"] is None else f"liberado em {row['revoked_at']}"
        print(f"{row['device_id']} | {row['device_name']} | {status} | último acesso: {row['last_seen_at']}")


def revoke_device(device_id: str) -> None:
    api.initialize_database()
    with api.connect() as connection:
        farm = connection.execute("SELECT farm_id FROM farm WHERE singleton=1").fetchone()
        if farm is None:
            raise SystemExit("Configure primeiro o administrador da fazenda.")
        changed = connection.execute("UPDATE devices SET revoked_at=?,token_version=token_version+1 WHERE farm_id=? AND device_id=? AND revoked_at IS NULL", (api.utc_now(), farm["farm_id"], device_id)).rowcount
    if not changed:
        raise SystemExit("Aparelho ativo não encontrado.")
    print("Aparelho liberado. Um novo celular poderá ocupar a vaga.")


def main() -> None:
    load_dotenv(Path(__file__).resolve().parents[1] / ".env")
    parser = argparse.ArgumentParser(prog="agrogestor-server")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("init-admin", help="cria a fazenda local e o primeiro administrador")
    backup_parser = commands.add_parser("backup", help="cria cópia do banco e dos anexos")
    backup_parser.add_argument("destination", type=Path)
    restore_parser = commands.add_parser("restore", help="restaura banco e anexos; pare o servidor primeiro")
    restore_parser.add_argument("source", type=Path)
    commands.add_parser("devices", help="lista aparelhos desta fazenda")
    revoke_parser = commands.add_parser("revoke-device", help="libera a vaga de um aparelho")
    revoke_parser.add_argument("device_id")
    args = parser.parse_args()
    if args.command == "init-admin":
        init_admin()
    elif args.command == "backup":
        backup(args.destination)
    elif args.command == "restore":
        restore(args.source)
    elif args.command == "devices":
        list_devices()
    elif args.command == "revoke-device":
        revoke_device(args.device_id)


if __name__ == "__main__":
    main()
