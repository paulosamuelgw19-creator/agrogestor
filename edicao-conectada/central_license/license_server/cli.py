from __future__ import annotations

import getpass
import re
import sys
from datetime import datetime, timezone

from .app import connect, initialize_database, iso, now_utc, password_hash


def create_admin() -> None:
    initialize_database()
    with connect() as db:
        if db.execute("SELECT 1 FROM admins LIMIT 1").fetchone():
            print("O painel central já tem um administrador configurado.")
            return
    username = input("Usuário do painel central: ").strip()
    if not re.fullmatch(r"[A-Za-z0-9_.@-]{3,120}", username):
        raise SystemExit("Use de 3 a 120 letras, números, ponto, hífen, sublinhado ou @.")
    password = getpass.getpass("Senha (mínimo 14 caracteres): ")
    repeated = getpass.getpass("Confirme a senha: ")
    if len(password) < 14 or password != repeated:
        raise SystemExit("As senhas precisam coincidir e ter pelo menos 14 caracteres.")
    with connect() as db:
        db.execute("INSERT INTO admins(username,password_hash,created_at) VALUES(?,?,?)",
                   (username, password_hash.hash(password), iso(now_utc())))
    print("Administrador central criado. Guarde as credenciais em local privado.")


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] != "init-admin":
        raise SystemExit("Uso: python -m license_server.cli init-admin")
    create_admin()
