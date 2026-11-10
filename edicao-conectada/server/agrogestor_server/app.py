from __future__ import annotations

import hashlib
import json
import math
import os
import re
import secrets
import shutil
import sqlite3
import tempfile
import urllib.error
import urllib.request
import uuid
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Annotated, Literal

import jwt
from dotenv import load_dotenv
from fastapi import Depends, FastAPI, File, HTTPException, Query, UploadFile
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field
from pwdlib import PasswordHash

from .login_throttle import LoginThrottle
from .logistics_access import effective_role
from . import commercial


load_dotenv(Path(__file__).resolve().parents[1] / ".env")

DATA_DIR = Path(os.getenv("AGROGESTOR_DATA_DIR", "./data")).expanduser().resolve()
DB_PATH = DATA_DIR / "agrogestor.sqlite3"
V2_ENABLED = os.getenv("AGROGESTOR_V2_ENABLED", "false").strip().lower() == "true"
ATTACHMENTS_DIR = DATA_DIR / "attachments"
JWT_SECRET = os.getenv("AGROGESTOR_JWT_SECRET", "")
LICENSE_API_BASE = os.getenv("AGROGESTOR_LICENSE_API_BASE", "").rstrip("/")
LICENSE_API_KEY = os.getenv("AGROGESTOR_LICENSE_API_KEY", "")
LICENSE_PROVIDER = os.getenv("AGROGESTOR_LICENSE_PROVIDER", "auto").strip().lower()
if LICENSE_PROVIDER == "auto":
    LICENSE_PROVIDER = "firebase" if LICENSE_API_BASE and "cloudfunctions.net" in LICENSE_API_BASE else ("windows" if LICENSE_API_BASE else "local")
if LICENSE_PROVIDER not in {"local", "firebase", "windows"}:
    raise RuntimeError("AGROGESTOR_LICENSE_PROVIDER deve ser local, firebase ou windows.")
if LICENSE_PROVIDER == "local":
    LICENSE_API_BASE = ""
    LICENSE_API_KEY = ""
TOKEN_HOURS = max(1, min(int(os.getenv("AGROGESTOR_TOKEN_HOURS", "168")), 720))
MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024
MAX_EVENT_PAYLOAD_BYTES = 1024 * 1024
password_hash = PasswordHash.recommended()
_login_dummy_hash = password_hash.hash(secrets.token_urlsafe(32))
bearer = HTTPBearer(auto_error=False)
login_throttle = LoginThrottle()

READ_MODULES = {
    "admin": {"machines", "services", "maintenance", "fuel", "operators", "implements", "clients", "products", "productUsage"},
    "operator": {"machines", "services", "implements", "fuel", "products", "productUsage"},
    "mechanic": {"machines", "maintenance"},
    "driver": set(),
}
WRITE_MODULES = {
    "admin": READ_MODULES["admin"],
    "operator": {"machines", "services", "implements", "fuel", "products", "productUsage"},
    "mechanic": {"machines", "maintenance"},
    "driver": set(),
}
ROLES = {"admin", "operator", "mechanic"}
ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,160}$")
ATTACHMENT_RE = re.compile(r"^[A-Za-z0-9_-]{16,80}$")


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def parse_instant(value: object) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed.replace(tzinfo=timezone.utc) if parsed.tzinfo is None else parsed.astimezone(timezone.utc)
    except ValueError:
        return None


def initialize_database() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    ATTACHMENTS_DIR.mkdir(parents=True, exist_ok=True)
    with connect() as connection:
        connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS farm (
                singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                farm_id TEXT NOT NULL UNIQUE,
                name TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS farm_license (
                farm_id TEXT PRIMARY KEY,
                trial_started_at TEXT,
                paid_license_id TEXT,
                paid_activated_at TEXT,
                revoked_at TEXT,
                last_cloud_checked_at TEXT,
                last_cloud_status TEXT,
                paid_expires_at TEXT
            );
            CREATE TABLE IF NOT EXISTS devices (
                farm_id TEXT NOT NULL,
                device_id TEXT NOT NULL,
                device_name TEXT NOT NULL,
                activated_by TEXT NOT NULL,
                activated_at TEXT NOT NULL,
                last_seen_at TEXT NOT NULL,
                revoked_at TEXT,
                token_version INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(farm_id,device_id)
            );
            CREATE TABLE IF NOT EXISTS users (
                user_id TEXT PRIMARY KEY,
                farm_id TEXT NOT NULL,
                email TEXT NOT NULL COLLATE NOCASE,
                display_name TEXT NOT NULL,
                role TEXT NOT NULL CHECK(role IN ('admin','operator','mechanic')),
                password_hash TEXT NOT NULL,
                disabled INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL,
                UNIQUE(farm_id,email)
            );
            CREATE TABLE IF NOT EXISTS invitations (
                invite_id TEXT PRIMARY KEY,
                farm_id TEXT NOT NULL,
                email TEXT NOT NULL COLLATE NOCASE,
                role TEXT NOT NULL CHECK(role IN ('operator','mechanic')),
                code_hash TEXT NOT NULL UNIQUE,
                expires_at TEXT NOT NULL,
                used_at TEXT,
                created_by TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS records (
                farm_id TEXT NOT NULL,
                module TEXT NOT NULL,
                record_id TEXT NOT NULL,
                payload TEXT,
                version INTEGER NOT NULL,
                deleted INTEGER NOT NULL DEFAULT 0,
                updated_at TEXT NOT NULL,
                PRIMARY KEY(farm_id,module,record_id)
            );
            CREATE TABLE IF NOT EXISTS changes (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                event_id TEXT NOT NULL UNIQUE,
                farm_id TEXT NOT NULL,
                module TEXT NOT NULL,
                record_id TEXT NOT NULL,
                version INTEGER NOT NULL,
                payload TEXT,
                deleted INTEGER NOT NULL DEFAULT 0,
                updated_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS changes_pull_idx ON changes(farm_id,seq);
            CREATE TABLE IF NOT EXISTS attachments (
                attachment_id TEXT PRIMARY KEY,
                farm_id TEXT NOT NULL,
                sha256 TEXT NOT NULL,
                size_bytes INTEGER NOT NULL,
                created_at TEXT NOT NULL
            );
            """
        )
        device_columns = {row["name"] for row in connection.execute("PRAGMA table_info(devices)")}
        if "token_version" not in device_columns:
            connection.execute("ALTER TABLE devices ADD COLUMN token_version INTEGER NOT NULL DEFAULT 0")
        columns = {row["name"] for row in connection.execute("PRAGMA table_info(farm_license)")}
        if "last_cloud_checked_at" not in columns:
            connection.execute("ALTER TABLE farm_license ADD COLUMN last_cloud_checked_at TEXT")
        if "last_cloud_status" not in columns:
            connection.execute("ALTER TABLE farm_license ADD COLUMN last_cloud_status TEXT")
        if "paid_expires_at" not in columns:
            connection.execute("ALTER TABLE farm_license ADD COLUMN paid_expires_at TEXT")
    with connect() as connection:
        commercial.initialize(connection)
    if V2_ENABLED:
        from .v2_schema import migrate
        with connect() as connection:
            migrate(connection)


@contextmanager
def connect():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(DB_PATH, timeout=20)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys = ON")
    connection.execute("PRAGMA journal_mode = WAL")
    try:
        yield connection
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


def farm_row(connection: sqlite3.Connection) -> sqlite3.Row:
    row = connection.execute("SELECT farm_id,name FROM farm WHERE singleton=1").fetchone()
    if row is None:
        raise HTTPException(status_code=503, detail="O PC gestor ainda não foi configurado.")
    return row


def public_user(row: sqlite3.Row) -> dict[str, str]:
    with connect() as db:
        role = effective_role(db, row)
    return {"id": row["user_id"], "email": row["email"], "displayName": row["display_name"], "role": role, "farmId": row["farm_id"]}


def make_token(user_id: str, farm_id: str, device_id: str) -> str:
    if len(JWT_SECRET) < 32 or "REPLACE_WITH" in JWT_SECRET:
        raise HTTPException(status_code=503, detail="Configure uma chave JWT privada no arquivo .env do PC gestor.")
    expires = datetime.now(timezone.utc) + timedelta(hours=TOKEN_HOURS)
    with connect() as connection:
        device = connection.execute("SELECT token_version FROM devices WHERE farm_id=? AND device_id=?", (farm_id, device_id)).fetchone()
    if device is None:
        raise HTTPException(status_code=401, detail="Aparelho não autorizado.")
    return jwt.encode({"sub": user_id, "farm_id": farm_id, "device_id": device_id, "device_version": device["token_version"], "exp": expires}, JWT_SECRET, algorithm="HS256")


def current_user(credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)]) -> dict[str, str]:
    if credentials is None or not JWT_SECRET or len(JWT_SECRET) < 32:
        raise HTTPException(status_code=401, detail="Entre novamente para continuar.", headers={"WWW-Authenticate": "Bearer"})
    try:
        claims = jwt.decode(credentials.credentials, JWT_SECRET, algorithms=["HS256"], options={"require": ["exp", "sub", "farm_id", "device_id"]})
        user_id = claims.get("sub")
    except jwt.InvalidTokenError as error:
        raise HTTPException(status_code=401, detail="Sessão inválida ou expirada.", headers={"WWW-Authenticate": "Bearer"}) from error
    with connect() as connection:
        row = connection.execute("SELECT * FROM users WHERE user_id=? AND disabled=0", (user_id,)).fetchone()
        farm = farm_row(connection)
        device = connection.execute(
            "SELECT token_version FROM devices WHERE farm_id=? AND device_id=? AND revoked_at IS NULL",
            (farm["farm_id"], claims.get("device_id")),
        ).fetchone()
        if device is not None:
            connection.execute("UPDATE devices SET last_seen_at=? WHERE farm_id=? AND device_id=?", (utc_now(), farm["farm_id"], claims["device_id"]))
    if row is None or device is None or claims.get("device_version", 0) != device["token_version"] or row["farm_id"] != farm["farm_id"] or claims.get("farm_id") != farm["farm_id"]:
        raise HTTPException(status_code=401, detail="Esta conta não tem acesso a esta fazenda.", headers={"WWW-Authenticate": "Bearer"})
    return {**public_user(row), "deviceId": claims["device_id"]}


def require_active_license(farm_id: str) -> None:
    entitlement = entitlement_status(farm_id)
    if not entitlement["writeAllowed"]:
        detail = (
            "O teste terminou ou a licença não está ativa. Você pode consultar os dados, mas precisa de uma licença para alterar registros."
            if entitlement["status"] == "expired"
            else "A validação online venceu. Conecte este PC à internet para validar o teste/licença antes de alterar registros."
        )
        raise HTTPException(
            status_code=402,
            detail=detail,
        )


def require_role(user: dict[str, str], *roles: str) -> None:
    if user["role"] not in roles:
        raise HTTPException(status_code=403, detail="Seu perfil não tem permissão para esta ação.")


def require_legacy_access(user):
    # v1 JSON has no property ACL. Never expose an organization's legacy data
    # through this alternative route to v2 property-scoped accounts, even after
    # their last property grant has been revoked.
    if V2_ENABLED and user['role'] != 'admin':
        raise HTTPException(403, 'No v2, esta conta utiliza somente as propriedades autorizadas na nova área de operações.')


class LoginRequest(BaseModel):
    email: str = Field(min_length=3, max_length=254)
    password: str = Field(min_length=1, max_length=256)
    deviceId: str = Field(min_length=16, max_length=80)
    deviceName: str = Field(default="Android", min_length=1, max_length=80)


class InvitationRequest(BaseModel):
    email: str = Field(min_length=3, max_length=254)
    role: Literal["operator", "mechanic"]


class UserAccessRequest(BaseModel):
    active: bool


class AcceptInvitationRequest(BaseModel):
    email: str = Field(min_length=3, max_length=254)
    code: str = Field(min_length=20, max_length=100)
    displayName: str = Field(min_length=2, max_length=100)
    password: str = Field(min_length=12, max_length=256)


class LicenseActivationRequest(BaseModel):
    licenseKey: str = Field(min_length=20, max_length=100)


class PushEvent(BaseModel):
    eventId: str = Field(min_length=16, max_length=80)
    module: str = Field(min_length=1, max_length=40)
    recordId: str = Field(min_length=1, max_length=160)
    operation: Literal["upsert", "delete"]
    payload: dict | None
    baseVersion: int = Field(ge=0)


class PushRequest(BaseModel):
    events: list[PushEvent] = Field(max_length=100)


class CloudLicenseError(Exception):
    def __init__(self, status_code: int, message: str):
        super().__init__(message)
        self.status_code = status_code
        self.message = message


def cloud_post(function_name: str, payload: dict) -> dict:
    if not LICENSE_API_BASE or not LICENSE_API_KEY or LICENSE_API_KEY.startswith("REPLACE_WITH_"):
        raise ValueError("Serviço central de licenças e chave privada não configurados")
    request = urllib.request.Request(
        f"{LICENSE_API_BASE}/{function_name}",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "X-Agrogestor-License-Key": LICENSE_API_KEY,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            result = json.loads(response.read(64 * 1024))
    except urllib.error.HTTPError as error:
        try:
            detail = json.loads(error.read(8 * 1024)).get("detail", "A solicitação foi recusada.")
        except (ValueError, AttributeError):
            detail = "A solicitação foi recusada pelo serviço central de licenças."
        raise CloudLicenseError(error.code, str(detail)) from error
    if not isinstance(result, dict):
        raise ValueError("Resposta inválida do serviço central de licenças")
    return result


app = FastAPI(title="AgroGestor Farm API", docs_url=None, redoc_url=None, openapi_url=None)


@app.on_event("startup")
def startup() -> None:
    initialize_database()
    if LICENSE_PROVIDER in {"firebase", "windows"} and (not LICENSE_API_BASE or not LICENSE_API_KEY):
        raise RuntimeError("Configure URL e chave do serviço central de licenças no server/.env.")


@app.get("/api/v1/health")
def health():
    initialize_database()
    with connect() as connection:
        configured = connection.execute("SELECT 1 FROM farm WHERE singleton=1").fetchone() is not None
    return {"status": "ok", "farmConfigured": configured, "licenseProvider": LICENSE_PROVIDER}


@app.post("/api/v1/auth/login")
def login(body: LoginRequest):
    initialize_database()
    email = body.email.strip().lower()
    login_throttle.reserve(email)
    with connect() as connection:
        farm = farm_row(connection)
        row = connection.execute("SELECT * FROM users WHERE farm_id=? AND email=?", (farm["farm_id"], email)).fetchone()
    verified = password_hash.verify(body.password, row["password_hash"] if row is not None else _login_dummy_hash)
    if row is None or row["disabled"] or not verified:
        raise HTTPException(status_code=401, detail="E-mail ou senha incorretos.")
    login_throttle.clear(email)
    if not ID_RE.fullmatch(body.deviceId):
        raise HTTPException(status_code=400, detail="Identificador deste aparelho inválido.")
    with connect() as connection:
        connection.execute("BEGIN IMMEDIATE")
        farm = farm_row(connection)
        device = connection.execute("SELECT revoked_at FROM devices WHERE farm_id=? AND device_id=?", (farm["farm_id"], body.deviceId)).fetchone()
        if device is None or device["revoked_at"] is not None:
            commercial.write_access(connection, farm["farm_id"])
            commercial.ensure_slot(connection, farm["farm_id"], "devices")
            now = utc_now()
            if device is None:
                connection.execute(
                    "INSERT INTO devices(farm_id,device_id,device_name,activated_by,activated_at,last_seen_at) VALUES(?,?,?,?,?,?)",
                    (farm["farm_id"], body.deviceId, body.deviceName[:80], row["user_id"], now, now),
                )
            else:
                connection.execute(
                    "UPDATE devices SET revoked_at=NULL,device_name=?,activated_by=?,activated_at=?,last_seen_at=? WHERE farm_id=? AND device_id=?",
                    (body.deviceName[:80], row["user_id"], now, now, farm["farm_id"], body.deviceId),
                )
        else:
            connection.execute("UPDATE devices SET device_name=?,last_seen_at=? WHERE farm_id=? AND device_id=?", (body.deviceName[:80], utc_now(), farm["farm_id"], body.deviceId))
        license_row = connection.execute("SELECT * FROM farm_license WHERE farm_id=?", (farm["farm_id"],)).fetchone()
        if license_row is None:
            connection.execute("INSERT INTO farm_license(farm_id,trial_started_at) VALUES(?,?)", (farm["farm_id"], utc_now()))
    entitlement = entitlement_status(row["farm_id"])
    return {"token": make_token(row["user_id"], row["farm_id"], body.deviceId), "user": public_user(row), "entitlement": entitlement}


@app.get("/api/v1/auth/users")
def list_users(user: Annotated[dict[str, str], Depends(current_user)]):
    require_role(user, "admin")
    with connect() as connection:
        rows = connection.execute(
            "SELECT farm_id,user_id,email,display_name,role,disabled,created_at FROM users WHERE farm_id=? ORDER BY display_name COLLATE NOCASE,email COLLATE NOCASE",
            (user["farmId"],),
        ).fetchall()
        rows = [dict(row) | {'role': effective_role(connection, row)} for row in rows]
    return {"users": [
        {
            "id": row["user_id"],
            "email": row["email"],
            "displayName": row["display_name"],
            "role": row["role"],
            "active": not bool(row["disabled"]),
            "createdAt": row["created_at"],
        }
        for row in rows
    ]}


@app.patch("/api/v1/auth/users/{user_id}/access")
def set_user_access(
    user_id: str,
    body: UserAccessRequest,
    user: Annotated[dict[str, str], Depends(current_user)],
):
    require_role(user, "admin")
    with connect() as connection:
        connection.execute("BEGIN IMMEDIATE")
        target = connection.execute(
            "SELECT user_id,role,disabled FROM users WHERE user_id=? AND farm_id=?",
            (user_id, user["farmId"]),
        ).fetchone()
        if target is None:
            raise HTTPException(status_code=404, detail="Usuário não encontrado nesta fazenda.")
        if target["role"] == "admin" and not body.active and not target["disabled"]:
            active_admins = connection.execute(
                "SELECT COUNT(*) FROM users WHERE farm_id=? AND role='admin' AND disabled=0",
                (user["farmId"],),
            ).fetchone()[0]
            if active_admins <= 1:
                raise HTTPException(status_code=409, detail="A fazenda precisa manter ao menos um administrador ativo.")
        if body.active and target["disabled"]:
            commercial.write_access(connection, user["farmId"])
            commercial.ensure_slot(connection, user["farmId"], "users")
        commercial.audit(connection, __import__(__name__, fromlist=["app"]), user, "user-access", user_id, {"active":body.active})
        connection.execute(
            "UPDATE users SET disabled=? WHERE user_id=? AND farm_id=?",
            (0 if body.active else 1, user_id, user["farmId"]),
        )
    return {"id": user_id, "active": body.active}


def entitlement_status(farm_id: str) -> dict:
    now = datetime.now(timezone.utc)
    with connect() as connection:
        state = connection.execute("SELECT * FROM farm_license WHERE farm_id=?", (farm_id,)).fetchone()
        device_count = connection.execute("SELECT COUNT(*) FROM devices WHERE farm_id=? AND revoked_at IS NULL", (farm_id,)).fetchone()[0]
    if state is None:
        with connect() as connection:
            connection.execute("INSERT OR IGNORE INTO farm_license(farm_id,trial_started_at) VALUES(?,?)", (farm_id, now.isoformat()))
        started_at = now
        paid_id = None
        revoked = False
        cloud_checked_at = None
        last_cloud_status = None
        paid_expires_at = None
    else:
        started_at = parse_instant(state["trial_started_at"]) or parse_instant(state["paid_activated_at"]) or now
        paid_id = state["paid_license_id"]
        revoked = state["revoked_at"] is not None
        cloud_checked_at = parse_instant(state["last_cloud_checked_at"])
        last_cloud_status = state["last_cloud_status"]
        paid_expires_at = parse_instant(state["paid_expires_at"])
    trial_end = started_at + timedelta(days=30)
    cloud_status = None
    if LICENSE_API_BASE:
        with connect() as connection:
            farm_name = farm_row(connection)["name"]
        request_data = {"farmId": farm_id, "farmName": farm_name}
        if paid_id:
            request_data["licenseId"] = paid_id
        try:
            cloud_status = cloud_post("checkLicense", request_data)
        except (urllib.error.URLError, TimeoutError, ValueError, CloudLicenseError):
            cloud_status = None
    if cloud_status is not None:
        cloud_checked_at = parse_instant(cloud_status.get("checkedAt")) or now
        last_cloud_status = cloud_status.get("status")
        remote_license_id = cloud_status.get("licenseId")
        paid_expires_at = parse_instant(cloud_status.get("expiresAt"))
        remote_start = parse_instant(cloud_status.get("trialStartedAt"))
        remote_end = parse_instant(cloud_status.get("trialEndsAt"))
        if remote_start:
            started_at = remote_start
        if remote_end:
            trial_end = remote_end
        with connect() as connection:
            connection.execute(
                "UPDATE farm_license SET trial_started_at=?,last_cloud_checked_at=?,last_cloud_status=?,paid_license_id=COALESCE(?,paid_license_id),paid_expires_at=?,revoked_at=CASE WHEN ?='active' THEN NULL ELSE revoked_at END WHERE farm_id=?",
                (started_at.isoformat(), cloud_checked_at.isoformat(), last_cloud_status,
                 remote_license_id if isinstance(remote_license_id, str) else None,
                 paid_expires_at.isoformat() if paid_expires_at else None, last_cloud_status, farm_id),
            )
    if cloud_status is not None:
        commercial.refresh(__import__(__name__, fromlist=["app"]), farm_id)
    paid = cloud_status is not None and cloud_status.get("status") == "active"
    cloud_denied = cloud_status is not None and cloud_status.get("status") in {"inactive", "suspended", "revoked"}
    offline_until = now + timedelta(days=7)
    if paid:
        status = "licensed"
        write_allowed = True
        offline_until = min(now + timedelta(days=7), cloud_checked_at + timedelta(days=7)) if cloud_checked_at else offline_until
    elif cloud_status is not None and cloud_status.get("status") == "trial" and now < trial_end:
        status = "trial"
        write_allowed = True
        offline_until = min(now + timedelta(days=7), trial_end, cloud_checked_at + timedelta(days=7))
    elif cloud_denied or (cloud_status is not None and cloud_status.get("status") == "expired"):
        status = "expired"
        write_allowed = False
    elif LICENSE_API_BASE and cloud_checked_at is not None and now < cloud_checked_at + timedelta(days=7):
        if last_cloud_status in {"inactive", "suspended", "revoked", "expired"}:
            status = "expired"
            write_allowed = False
        elif paid_id and not revoked and last_cloud_status in {None, "active"}:
            status = "licensed"
            write_allowed = True
            offline_until = cloud_checked_at + timedelta(days=7)
        elif now < trial_end:
            status = "trial"
            write_allowed = True
            offline_until = min(trial_end, cloud_checked_at + timedelta(days=7))
        else:
            status = "expired"
            write_allowed = False
    elif LICENSE_API_BASE:
        status = "validation_required"
        write_allowed = False
    elif paid_id and not revoked and cloud_checked_at and now < cloud_checked_at + timedelta(days=7):
        status = "licensed"
        write_allowed = True
        offline_until = cloud_checked_at + timedelta(days=7)
    elif not paid_id and not revoked and now < trial_end:
        # Local-only trial is useful while developing; deployed farms use the Firebase timestamp above.
        status = "trial"
        write_allowed = True
        offline_until = min(now + timedelta(days=7), trial_end)
    elif cloud_denied:
        status = "expired"
        write_allowed = False
    elif paid_id and not revoked:
        status = "validation_required"
        write_allowed = False
    else:
        status = "expired"
        write_allowed = False
        offline_until = now + timedelta(days=7)
    if paid_expires_at is not None and (paid_id or status == "licensed"):
        offline_until = min(offline_until, paid_expires_at)
        if now >= paid_expires_at:
            status = "expired"
            write_allowed = False
    return {
        "farmId": farm_id,
        "status": status,
        "writeAllowed": write_allowed,
        "trialEndsAt": trial_end.isoformat(),
        "licenseExpiresAt": paid_expires_at.isoformat() if paid_expires_at else None,
        "checkedAt": now.isoformat(),
        "offlineUntil": offline_until.isoformat(),
        "daysRemaining": max(0, (trial_end.date() - now.date()).days) if status == "trial" else None,
        "activeDevices": device_count,
        "deviceLimit": -1,
    }


@app.get("/api/v1/licensing/status")
def licensing_status(user: Annotated[dict[str, str], Depends(current_user)]):
    return entitlement_status(user["farmId"])


@app.post("/api/v1/licensing/activate")
def activate_license(body: LicenseActivationRequest, user: Annotated[dict[str, str], Depends(current_user)]):
    require_role(user, "admin")
    if not LICENSE_API_BASE or not LICENSE_API_KEY or LICENSE_API_KEY.startswith("REPLACE_WITH_"):
        raise HTTPException(status_code=503, detail="A emissão de licenças depende da configuração do serviço central e da chave privada do servidor.")
    with connect() as connection:
        farm = farm_row(connection)
    try:
        result = cloud_post("activateLicense", {"licenseKey": body.licenseKey.strip(), "farmId": farm["farm_id"], "farmName": farm["name"]})
    except CloudLicenseError as error:
        raise HTTPException(status_code=error.status_code, detail=error.message) from error
    except (urllib.error.URLError, TimeoutError, ValueError) as error:
        raise HTTPException(status_code=503, detail="Não foi possível validar a chave no serviço central. Confira a conexão e tente novamente.") from error
    license_id = result.get("licenseId")
    if result.get("status") != "active" or not isinstance(license_id, str) or len(license_id) > 100:
        raise HTTPException(status_code=400, detail="O serviço central não confirmou uma licença válida para esta fazenda.")
    now = utc_now()
    with connect() as connection:
        connection.execute(
            "INSERT INTO farm_license(farm_id,trial_started_at,paid_license_id,paid_activated_at,revoked_at,last_cloud_checked_at,last_cloud_status,paid_expires_at) "
            "VALUES(?,?,?,?,NULL,?,'active',?) ON CONFLICT(farm_id) DO UPDATE SET paid_license_id=excluded.paid_license_id,paid_activated_at=excluded.paid_activated_at,revoked_at=NULL,last_cloud_checked_at=excluded.last_cloud_checked_at,last_cloud_status='active',paid_expires_at=excluded.paid_expires_at",
            (farm["farm_id"], None, license_id, now, now, parse_instant(result.get("expiresAt")).isoformat() if parse_instant(result.get("expiresAt")) else None),
        )
    return entitlement_status(farm["farm_id"])


@app.get("/api/v1/licensing/devices")
def list_devices(user: Annotated[dict[str, str], Depends(current_user)]):
    require_role(user, "admin")
    with connect() as connection:
        rows = connection.execute("SELECT device_id,device_name,activated_at,last_seen_at,revoked_at FROM devices WHERE farm_id=? ORDER BY activated_at", (user["farmId"],)).fetchall()
    return {"devices": [{
        "deviceId": row["device_id"], "name": row["device_name"], "activatedAt": row["activated_at"],
        "lastSeenAt": row["last_seen_at"], "active": row["revoked_at"] is None,
    } for row in rows]}


@app.delete("/api/v1/licensing/devices/{device_id}")
def revoke_device(device_id: str, user: Annotated[dict[str, str], Depends(current_user)]):
    require_role(user, "admin")
    if not ID_RE.fullmatch(device_id):
        raise HTTPException(status_code=400, detail="Identificador de aparelho inválido.")
    with connect() as connection:
        changed = connection.execute("UPDATE devices SET revoked_at=?,token_version=token_version+1 WHERE farm_id=? AND device_id=? AND revoked_at IS NULL", (utc_now(), user["farmId"], device_id)).rowcount
    if not changed:
        raise HTTPException(status_code=404, detail="Aparelho ativo não encontrado nesta fazenda.")
    return {"revoked": True}


@app.post("/api/v1/auth/invitations")
def create_invitation(body: InvitationRequest, user: Annotated[dict[str, str], Depends(current_user)]):
    require_role(user, "admin")
    require_active_license(user["farmId"])
    email = body.email.strip().lower()
    code = secrets.token_urlsafe(32)
    now = datetime.now(timezone.utc)
    with connect() as connection:
        connection.execute("BEGIN IMMEDIATE")
        farm = farm_row(connection)
        existing = connection.execute("SELECT 1 FROM users WHERE farm_id=? AND email=?", (farm["farm_id"], email)).fetchone()
        if existing:
            raise HTTPException(status_code=409, detail="Já existe uma conta com esse e-mail nesta fazenda.")
        connection.execute("UPDATE invitations SET used_at=? WHERE farm_id=? AND email=? AND used_at IS NULL", (now.isoformat(), farm["farm_id"], email))
        commercial.write_access(connection, farm["farm_id"])
        commercial.ensure_slot(connection, farm["farm_id"], "users")
        connection.execute(
            "INSERT INTO invitations(invite_id,farm_id,email,role,code_hash,expires_at,created_by) VALUES(?,?,?,?,?,?,?)",
            (str(uuid.uuid4()), farm["farm_id"], email, body.role, hashlib.sha256(code.encode()).hexdigest(), (now + timedelta(days=7)).isoformat(), user["id"]),
        )
    return {"code": code, "expiresAt": (now + timedelta(days=7)).isoformat()}


@app.post("/api/v1/auth/accept-invitation")
def accept_invitation(body: AcceptInvitationRequest):
    email = body.email.strip().lower()
    code_hash = hashlib.sha256(body.code.encode()).hexdigest()
    with connect() as read_db:
        tenant = farm_row(read_db)["farm_id"]
    require_active_license(tenant)
    with connect() as connection:
        connection.execute("BEGIN IMMEDIATE")
        farm = farm_row(connection)
        invitation = connection.execute(
            "SELECT * FROM invitations WHERE farm_id=? AND email=? AND code_hash=? AND used_at IS NULL",
            (farm["farm_id"], email, code_hash),
        ).fetchone()
        if invitation is None or datetime.fromisoformat(invitation["expires_at"]) < datetime.now(timezone.utc):
            raise HTTPException(status_code=400, detail="Convite inválido ou expirado.")
        if connection.execute("SELECT 1 FROM users WHERE farm_id=? AND email=?", (farm["farm_id"], email)).fetchone():
            raise HTTPException(status_code=409, detail="Já existe uma conta com esse e-mail nesta fazenda.")
        commercial.write_access(connection, farm["farm_id"])
        commercial.ensure_slot(connection, farm["farm_id"], "users", reserved_credit=1)
        invited_user_id = str(uuid.uuid4())
        connection.execute(
            "INSERT INTO users(user_id,farm_id,email,display_name,role,password_hash,created_at) VALUES(?,?,?,?,?,?,?)",
            (invited_user_id, farm["farm_id"], email, body.displayName.strip(), invitation["role"], password_hash.hash(body.password), utc_now()),
        )
        if V2_ENABLED and invitation['role'] == 'operator':
            for prop in connection.execute('SELECT id FROM v2_properties WHERE tenant_id=? AND shared_operators=1 AND archived=0', (farm['farm_id'],)).fetchall():
                connection.execute('INSERT INTO v2_access VALUES(?,?,?,?)', (farm['farm_id'], invited_user_id, prop['id'], 'employee'))
                connection.execute('''INSERT INTO v2_audit (tenant_id,property_id,actor_id,action,entity_type,entity_id,after_json,created_at)
                  VALUES(?,?,?,?,?,?,?,?)''', (farm['farm_id'], prop['id'], invited_user_id,
                  'grant-invitation', 'access', invited_user_id, json.dumps({'role':'employee','source':'accepted-invitation'}), utc_now()))
        connection.execute("UPDATE invitations SET used_at=? WHERE invite_id=?", (utc_now(), invitation["invite_id"]))
    return {"created": True}


@app.post("/api/v1/sync/push")
def push(body: PushRequest, user: Annotated[dict[str, str], Depends(current_user)]):
    require_legacy_access(user)
    require_active_license(user["farmId"])
    allowed = WRITE_MODULES[user["role"]]
    acknowledged: list[dict] = []
    conflicts: list[dict] = []
    rejected: list[dict] = []
    with connect() as connection:
        connection.execute("BEGIN IMMEDIATE")
        farm = farm_row(connection)
        for event in body.events:
            if not ID_RE.fullmatch(event.recordId) or not ID_RE.fullmatch(event.eventId):
                rejected.append({"eventId": event.eventId, "message": "Identificador de registro inválido."})
                continue
            if event.module not in READ_MODULES["admin"]:
                rejected.append({"eventId": event.eventId, "message": "Módulo desconhecido."})
                continue
            if event.module not in allowed:
                rejected.append({"eventId": event.eventId, "message": "Seu perfil não pode alterar este módulo."})
                continue
            if (event.operation == "upsert") != (event.payload is not None):
                rejected.append({"eventId": event.eventId, "message": "Dados do evento incompletos."})
                continue
            payload_json = json.dumps(event.payload, ensure_ascii=False, separators=(",", ":")) if event.payload is not None else None
            if payload_json is not None and len(payload_json.encode("utf-8")) > MAX_EVENT_PAYLOAD_BYTES:
                rejected.append({"eventId": event.eventId, "message": "Registro muito grande; remova anexos incorporados e tente novamente."})
                continue
            prior_event = connection.execute("SELECT farm_id,module,record_id,version FROM changes WHERE event_id=?", (event.eventId,)).fetchone()
            if prior_event is not None:
                if (prior_event["farm_id"], prior_event["module"], prior_event["record_id"]) == (farm["farm_id"], event.module, event.recordId):
                    acknowledged.append({"eventId": event.eventId, "version": prior_event["version"]})
                else:
                    rejected.append({"eventId": event.eventId, "message": "Identificador de evento já utilizado."})
                continue
            if V2_ENABLED and event.module in {'products', 'productUsage'}:
                rejected.append({"eventId": event.eventId, "message": "Produtos e insumos usam o estoque por propriedade no v2. Confira a migração dos registros antigos; use o cadastro unificado e as operações."})
                continue
            if event.module == "machines" and event.payload and event.payload.get("photoAttachmentId"):
                attachment_id = str(event.payload["photoAttachmentId"])
                attached = connection.execute("SELECT 1 FROM attachments WHERE attachment_id=? AND farm_id=?", (attachment_id, farm["farm_id"])).fetchone()
                if not ATTACHMENT_RE.fullmatch(attachment_id) or attached is None:
                    rejected.append({"eventId": event.eventId, "message": "A foto da máquina ainda não chegou ao PC gestor."})
                    continue
            current = connection.execute(
                "SELECT version,payload,deleted FROM records WHERE farm_id=? AND module=? AND record_id=?",
                (farm["farm_id"], event.module, event.recordId),
            ).fetchone()
            current_version = current["version"] if current else 0
            if user["role"] == "operator" and event.module == "products":
                if event.operation != "upsert" or current is None or current["deleted"]:
                    rejected.append({"eventId": event.eventId, "message": "O operador só pode baixar o estoque de um produto existente."})
                    continue
                old_product = json.loads(current["payload"] or "{}")
                new_product = event.payload
                immutable_fields = ("id", "name", "category", "productType", "unit", "lot")
                old_quantity = old_product.get("quantity")
                new_quantity = new_product.get("quantity") if isinstance(new_product, dict) else None
                quantities_valid = (
                    isinstance(old_quantity, (int, float)) and not isinstance(old_quantity, bool)
                    and isinstance(new_quantity, (int, float)) and not isinstance(new_quantity, bool)
                    and math.isfinite(float(old_quantity)) and math.isfinite(float(new_quantity))
                    and 0 <= float(new_quantity) < float(old_quantity)
                )
                catalog_unchanged = isinstance(new_product, dict) and all(
                    old_product.get(field) == new_product.get(field) for field in immutable_fields
                ) and new_product.get("id") == event.recordId
                if not quantities_valid or not catalog_unchanged:
                    rejected.append({"eventId": event.eventId, "message": "O operador só pode registrar consumo e reduzir a quantidade em estoque; os dados do produto ficam sob gestão do administrador."})
                    continue
            if user["role"] == "operator" and event.module == "productUsage":
                usage = event.payload
                quantity = usage.get("quantity") if isinstance(usage, dict) else None
                product_id = usage.get("productId") if isinstance(usage, dict) else None
                valid_quantity = (
                    isinstance(quantity, (int, float)) and not isinstance(quantity, bool)
                    and math.isfinite(float(quantity)) and float(quantity) > 0
                )
                product = connection.execute(
                    "SELECT 1 FROM records WHERE farm_id=? AND module='products' AND record_id=? AND deleted=0",
                    (farm["farm_id"], product_id),
                ).fetchone() if isinstance(product_id, str) else None
                if event.operation != "upsert" or current is not None or not valid_quantity or product is None or usage.get("id") != event.recordId:
                    rejected.append({"eventId": event.eventId, "message": "O operador só pode criar um lançamento de consumo válido ligado a um produto existente."})
                    continue
            if event.baseVersion != current_version:
                conflicts.append({
                    "eventId": event.eventId, "module": event.module, "recordId": event.recordId,
                    "serverVersion": current_version, "serverPayload": json.loads(current["payload"]) if current and current["payload"] else None,
                    "serverDeleted": bool(current["deleted"]) if current else False,
                })
                continue
            try:
                module = {'machines':'fleet','clients':'properties','implements':'fleet','fuel':'fuel','products':'inventory','productUsage':'operations','maintenance':'workshop','services':'tasks'}.get(event.module)
                commercial.write_access(connection, farm['farm_id'], module if current is None or current['deleted'] else None)
                resource = {'machines':'machines','implements':'implements'}.get(event.module)
                if event.operation == 'upsert' and resource:
                    was_active = current is not None and not current['deleted'] and not json.loads(current['payload'] or '{}').get('archived',False)
                    if not was_active and not event.payload.get('archived',False):
                        commercial.ensure_slot(connection,farm['farm_id'],resource)
                if event.operation == 'upsert' and event.module == 'clients':
                    old = json.loads(current['payload'] or '{}') if current and not current['deleted'] else {}
                    old_ids = {str(p.get('id')) for p in old.get('properties',[]) if not p.get('archived',False)}
                    new_ids = {str(p.get('id')) for p in event.payload.get('properties',[]) if not p.get('archived',False)}
                    commercial.ensure_slot(connection,farm['farm_id'],'properties',len(new_ids-old_ids))
            except commercial.CommercialError as error:
                rejected.append({'eventId':event.eventId,'message':error.detail,'code':error.code})
                continue
            version = current_version + 1
            deleted = event.operation == "delete"
            updated_at = utc_now()
            connection.execute(
                "INSERT INTO records(farm_id,module,record_id,payload,version,deleted,updated_at) VALUES(?,?,?,?,?,?,?) "
                "ON CONFLICT(farm_id,module,record_id) DO UPDATE SET payload=excluded.payload,version=excluded.version,deleted=excluded.deleted,updated_at=excluded.updated_at",
                (farm["farm_id"], event.module, event.recordId, payload_json, version, int(deleted), updated_at),
            )
            connection.execute(
                "INSERT INTO changes(event_id,farm_id,module,record_id,version,payload,deleted,updated_at) VALUES(?,?,?,?,?,?,?,?)",
                (event.eventId, farm["farm_id"], event.module, event.recordId, version, payload_json, int(deleted), updated_at),
            )
            acknowledged.append({"eventId": event.eventId, "version": version})
    return {"acknowledged": acknowledged, "conflicts": conflicts, "rejected": rejected}


@app.get("/api/v1/sync/pull")
def pull(
    cursor: Annotated[int, Query(ge=0)] = 0,
    limit: Annotated[int, Query(ge=1, le=500)] = 500,
    user: Annotated[dict[str, str], Depends(current_user)] = None,
):
    require_legacy_access(user)
    modules = READ_MODULES[user["role"]]
    marks = ",".join("?" for _ in modules)
    with connect() as connection:
        rows = connection.execute(
            f"SELECT seq,module,record_id,version,payload,deleted,updated_at FROM changes WHERE farm_id=? AND seq>? AND module IN ({marks}) ORDER BY seq LIMIT ?",
            (user["farmId"], cursor, *sorted(modules), limit),
        ).fetchall()
        next_cursor = rows[-1]["seq"] if rows else cursor
        has_more = False
        if rows:
            has_more = connection.execute(
                f"SELECT 1 FROM changes WHERE farm_id=? AND seq>? AND module IN ({marks}) LIMIT 1",
                (user["farmId"], next_cursor, *sorted(modules)),
            ).fetchone() is not None
    changes = [{
        "cursor": row["seq"], "module": row["module"], "recordId": row["record_id"],
        "version": row["version"], "payload": json.loads(row["payload"]) if row["payload"] else None,
        "deleted": bool(row["deleted"]), "updatedAt": row["updated_at"],
    } for row in rows]
    return {"changes": changes, "nextCursor": next_cursor, "hasMore": has_more}


@app.put("/api/v1/attachments/{attachment_id}")
async def put_attachment(
    attachment_id: str,
    user: Annotated[dict[str, str], Depends(current_user)],
    file: Annotated[UploadFile, File()],
):
    require_legacy_access(user)
    require_role(user, "admin", "operator", "mechanic")
    require_active_license(user["farmId"])
    if not ATTACHMENT_RE.fullmatch(attachment_id):
        raise HTTPException(status_code=400, detail="Identificador de anexo inválido.")
    farm_id = user["farmId"]
    farm_dir = ATTACHMENTS_DIR / farm_id
    farm_dir.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix="upload-", dir=farm_dir)
    total = 0
    digest = hashlib.sha256()
    try:
        with os.fdopen(descriptor, "wb") as output:
            while chunk := await file.read(64 * 1024):
                total += len(chunk)
                if total > MAX_ATTACHMENT_BYTES:
                    raise HTTPException(status_code=413, detail="A foto excede o limite de 10 MB.")
                digest.update(chunk)
                output.write(chunk)
        if total == 0:
            raise HTTPException(status_code=400, detail="O arquivo está vazio.")
        final_path = farm_dir / attachment_id
        with connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            prior = connection.execute("SELECT farm_id,sha256 FROM attachments WHERE attachment_id=?", (attachment_id,)).fetchone()
            if prior is not None and (prior["farm_id"] != farm_id or prior["sha256"] != digest.hexdigest()):
                raise HTTPException(status_code=409, detail="Um anexo existente não pode ser substituído. Envie a nova foto com outro identificador.")
            os.replace(temporary_name, final_path)
            connection.execute(
                "INSERT INTO attachments(attachment_id,farm_id,sha256,size_bytes,created_at) VALUES(?,?,?,?,?) "
                "ON CONFLICT(attachment_id) DO UPDATE SET farm_id=excluded.farm_id,sha256=excluded.sha256,size_bytes=excluded.size_bytes,created_at=excluded.created_at",
                (attachment_id, farm_id, digest.hexdigest(), total, utc_now()),
            )
        return {"attachmentId": attachment_id, "sha256": digest.hexdigest(), "size": total}
    except Exception:
        Path(temporary_name).unlink(missing_ok=True)
        raise
    finally:
        await file.close()


@app.get("/api/v1/attachments/{attachment_id}")
def get_attachment(attachment_id: str, user: Annotated[dict[str, str], Depends(current_user)]):
    require_legacy_access(user)
    if not ATTACHMENT_RE.fullmatch(attachment_id):
        raise HTTPException(status_code=400, detail="Identificador de anexo inválido.")
    with connect() as connection:
        row = connection.execute("SELECT size_bytes FROM attachments WHERE attachment_id=? AND farm_id=?", (attachment_id, user["farmId"])).fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="Anexo não encontrado nesta fazenda.")
    path = ATTACHMENTS_DIR / user["farmId"] / attachment_id
    if not path.is_file():
        raise HTTPException(status_code=404, detail="Arquivo do anexo não encontrado no PC gestor.")
    from fastapi.responses import FileResponse

    return FileResponse(path, media_type="application/octet-stream", filename=f"{attachment_id}.bin", headers={"Cache-Control": "private, no-store"})


# Separate opt-in schema and endpoints; no legacy records are imported automatically.
import sys
from .v2_api import build_router
app.include_router(build_router(sys.modules[__name__]))


commercial.install(__import__(__name__, fromlist=["app"]))
