"""Provision and run loopback-only test instances of Café Conectado."""
from __future__ import annotations

import argparse
import json
import os
import secrets
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / "piloto-local"
CONFIG = STATE / "credenciais.json"
SERVICES = {"central": 8870, "pc-a": 8865, "pc-b": 8866}


def configuration():
    if CONFIG.exists():
        return json.loads(CONFIG.read_text(encoding="utf-8"))
    STATE.mkdir(exist_ok=True)
    config = {
        "central": {
            "username": "gestor-painel-teste",
            "password": secrets.token_urlsafe(18),
            "jwt": secrets.token_urlsafe(48),
            "api_key": secrets.token_urlsafe(48),
        },
        **{
            name: {
                "farm": f"Cliente de teste {suffix.upper()}",
                "email": f"gestor-{suffix}@example.test",
                "password": secrets.token_urlsafe(18),
                "jwt": secrets.token_urlsafe(48),
            }
            for name, suffix in [("pc-a", "a"), ("pc-b", "b")]
        },
    }
    with CONFIG.open("x", encoding="utf-8") as stream:
        json.dump(config, stream, ensure_ascii=False, indent=2)
    return config


def save_configuration(config):
    temporary = CONFIG.with_suffix(".tmp")
    temporary.write_text(json.dumps(config, ensure_ascii=False, indent=2),
                         encoding="utf-8")
    temporary.replace(CONFIG)


def settings(name, config):
    # Discard any live service settings inherited from another PowerShell.
    env = {key: value for key, value in os.environ.items()
           if not key.upper().startswith("AGROGESTOR_")}
    env.update(PYTHONUTF8="1", PYTHONDONTWRITEBYTECODE="1")
    data = config[name]
    if name == "central":
        env.update(
            AGROGESTOR_LICENSE_DATA_DIR=str(STATE / name),
            AGROGESTOR_LICENSE_REQUIRE_ORGANIZATION_KEY="true",
            AGROGESTOR_LICENSE_JWT_SECRET=data["jwt"],
            AGROGESTOR_LICENSE_SERVER_API_KEY=data["api_key"],
        )
        return ROOT / "central_license", "license_server.app:app", env
    central = f"http://127.0.0.1:{SERVICES['central']}"
    env.update(
        AGROGESTOR_DATA_DIR=str(STATE / name),
        AGROGESTOR_V2_ENABLED="true",
        AGROGESTOR_JWT_SECRET=data["jwt"],
        AGROGESTOR_LICENSE_PROVIDER="windows",
        AGROGESTOR_LICENSE_API_BASE=central,
        AGROGESTOR_LICENSE_API_KEY=config["central"]["api_key"],
        AGROGESTOR_CONTRACT_ORGANIZATION_KEY=data.get("contract_key", ""),
    )
    return ROOT / "server", "agrogestor_server.app:app", env


def launch_args(name, config):
    folder, app, env = settings(name, config)
    args = [sys.executable, "-m", "uvicorn", app, "--host", "127.0.0.1",
            "--port", str(SERVICES[name]), "--no-access-log"]
    return args, folder, env


def request(method, path, body=None, token=None):
    data = None if body is None else json.dumps(body).encode()
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(
        f"http://127.0.0.1:{SERVICES['central']}{path}",
        data=data, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=8) as response:
        return json.load(response)


def wait_for_central(process):
    for _ in range(60):
        if process.poll() is not None:
            raise RuntimeError("A Central de teste encerrou. Confira o log em piloto-local.")
        try:
            request("GET", "/api/v1/health")
            return
        except OSError:
            time.sleep(0.25)
    raise RuntimeError("A Central de teste não respondeu.")


def initialize(name, config):
    folder, _, env = settings(name, config)
    data = config[name]
    if name == "central":
        entrypoint = "from license_server.cli import create_admin; create_admin()"
        answers = [data["username"], data["password"], data["password"]]
    else:
        entrypoint = "from agrogestor_server.cli import init_admin; init_admin()"
        answers = [data["farm"], data["email"], "Gestor de teste",
                   data["password"], data["password"]]
    bootstrap = "import getpass; getpass.getpass = lambda prompt: input(prompt); "
    result = subprocess.run([sys.executable, "-c", bootstrap + entrypoint],
                            input="\n".join(answers) + "\n", encoding="utf-8",
                            cwd=folder, env=env, capture_output=True, timeout=25)
    if result.returncode != 0:
        raise RuntimeError(f"Falha ao preparar {name}. Confira as dependências Python e a pasta piloto-local.")
    if name != "central":
        for line in result.stdout.splitlines():
            marker = "ID local: "
            if marker in line:
                return line.split(marker, 1)[1].strip()
        raise RuntimeError(f"O PC gestor {name} não retornou o ID do cliente.")
    return None


def prepare():
    config = configuration()
    with socket.socket() as check:
        if check.connect_ex(("127.0.0.1", SERVICES["central"])) == 0:
            raise RuntimeError("Pare a Central de teste na porta 8870 antes de preparar o ambiente.")
    initialize("central", config)
    args, cwd, env = launch_args("central", config)
    with (STATE / "preparo-central.log").open("a", encoding="utf-8") as log:
        process = subprocess.Popen(args, cwd=cwd, env=env, stdout=log, stderr=log)
        try:
            wait_for_central(process)
            central = config["central"]
            token = request("POST", "/api/v1/admin/login", {
                "username": central["username"], "password": central["password"],
            })["token"]
            for name in ("pc-a", "pc-b"):
                data = config[name]
                if "id" not in data:
                    data["id"] = initialize(name, config)
                    save_configuration(config)
                identity = data["id"]
                path = f"/api/v1/admin/contracts/{identity}"
                try:
                    registered = request("GET", path, token=token)
                except urllib.error.HTTPError as error:
                    if error.code != 404:
                        raise
                    registered = request("POST", "/api/v1/admin/contracts",
                                         {"farm_id": identity, "customer_name": data["farm"]}, token)
                if "contract_key" not in data:
                    request("POST", f"/api/v1/admin/farms/{identity}/license",
                            {"action": "activate", "plan": "monthly", "note": "Cliente fictício do piloto"}, token)
                    registered = request("GET", path, token=token)
                    contract = registered["contract"]
                    contract["plan_name"] = "Piloto Café Conectado"
                    contract["limits"] = {"properties": 3, "machines": 5, "users": 5,
                                          "devices": 3, "implements": 10}
                    request("PUT", path, {
                        "contract": contract, "expected_revision": registered["revision"],
                        "reason": "Limites de teste do piloto", "confirm_reduction": True,
                    }, token)
                    data["contract_key"] = request(
                        "POST", path + "/integration-key", token=token)["key"]
                    save_configuration(config)
        finally:
            process.terminate()
            process.wait(timeout=10)
    print("Dois clientes fictícios preparados. Credenciais privadas em piloto-local/credenciais.json.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    commands.add_parser("preparar", help="cria dois clientes fictícios com contas e contratos")
    serve = commands.add_parser("iniciar", help="inicia um servidor de teste em primeiro plano")
    serve.add_argument("service", choices=SERVICES)
    arguments = parser.parse_args()
    if arguments.action == "preparar":
        prepare()
        return
    if not CONFIG.exists():
        parser.error("Execute preparar primeiro.")
    config = configuration()
    if "contract_key" not in config.get("pc-a", {}) or "contract_key" not in config.get("pc-b", {}):
        parser.error("Preparação incompleta. Execute preparar primeiro.")
    args, cwd, env = launch_args(arguments.service, config)
    raise SystemExit(subprocess.call(args, cwd=cwd, env=env))


if __name__ == "__main__":
    main()
