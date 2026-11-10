from __future__ import annotations

import hashlib
import json
import os
import secrets
import sqlite3
import uuid
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Annotated, Literal

import jwt
from dotenv import load_dotenv
from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import FileResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field
from pwdlib import PasswordHash

from .login_throttle import LoginThrottle

ROOT = Path(__file__).resolve().parents[1]
load_dotenv(ROOT / ".env")
DATA_DIR = Path(os.getenv("AGROGESTOR_LICENSE_DATA_DIR", "./data")).expanduser()
if not DATA_DIR.is_absolute():
    DATA_DIR = (ROOT / DATA_DIR).resolve()
DB_PATH = DATA_DIR / "central-licenses.sqlite3"
JWT_SECRET = os.getenv("AGROGESTOR_LICENSE_JWT_SECRET", "")
SERVER_API_KEY = os.getenv("AGROGESTOR_LICENSE_SERVER_API_KEY", "")
ADMIN_TOKEN_HOURS = 8
password_hash = PasswordHash.recommended()
_login_dummy_hash = password_hash.hash(secrets.token_urlsafe(32))
bearer = HTTPBearer(auto_error=False)
login_throttle = LoginThrottle()
FARM_ID_CHARS = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-") | {"-"}
PLAN_DAYS = {"monthly": 30, "quarterly": 90, "annual": 365, "lifetime": None}


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def iso(value: datetime | None) -> str | None:
    return value.astimezone(timezone.utc).isoformat(timespec="seconds") if value else None


def parse_time(value: object) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed.replace(tzinfo=timezone.utc) if parsed.tzinfo is None else parsed.astimezone(timezone.utc)
    except ValueError:
        return None


@contextmanager
def connect():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(DB_PATH, timeout=20)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    try:
        yield db
        db.commit()
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()


def initialize_database() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    with connect() as db:
        db.executescript("""
          CREATE TABLE IF NOT EXISTS admins (
            username TEXT PRIMARY KEY COLLATE NOCASE,
            password_hash TEXT NOT NULL,
            created_at TEXT NOT NULL
          );
          CREATE TABLE IF NOT EXISTS farms (
            farm_id TEXT PRIMARY KEY,
            farm_name TEXT NOT NULL,
            first_seen_at TEXT NOT NULL,
            last_seen_at TEXT NOT NULL,
            trial_started_at TEXT NOT NULL,
            trial_ends_at TEXT NOT NULL
          );
          CREATE TABLE IF NOT EXISTS licenses (
            license_id TEXT PRIMARY KEY,
            key_hash TEXT UNIQUE,
            plan TEXT NOT NULL,
            status TEXT NOT NULL CHECK(status IN ('issued','active','suspended','revoked','expired')),
            activated_farm_id TEXT,
            issued_at TEXT NOT NULL,
            activated_at TEXT,
            expires_at TEXT,
            note TEXT NOT NULL DEFAULT '',
            changed_at TEXT NOT NULL
          );
          CREATE INDEX IF NOT EXISTS licenses_farm_idx ON licenses(activated_farm_id,status);
          CREATE TABLE IF NOT EXISTS license_events (
            event_id TEXT PRIMARY KEY,
            license_id TEXT NOT NULL,
            action TEXT NOT NULL,
            farm_id TEXT,
            details TEXT NOT NULL DEFAULT '',
            by_admin TEXT NOT NULL DEFAULT 'server',
            created_at TEXT NOT NULL
          );
        """)

    from .contracts import initialize
    with connect() as db:
        initialize(db)


@contextmanager
def transaction():
    with connect() as db:
        db.execute("BEGIN IMMEDIATE")
        yield db


def require_config() -> None:
    if len(JWT_SECRET) < 32 or JWT_SECRET.startswith("REPLACE_WITH_"):
        raise HTTPException(status_code=503, detail="Configure o segredo JWT privado do painel central.")
    if len(SERVER_API_KEY) < 32 or SERVER_API_KEY.startswith("REPLACE_WITH_"):
        raise HTTPException(status_code=503, detail="Configure a chave privada compartilhada com os servidores das fazendas.")


def require_server_key(value: Annotated[str | None, Header(alias="X-Agrogestor-License-Key")] = None) -> None:
    require_config()
    if not value or not secrets.compare_digest(value, SERVER_API_KEY):
        raise HTTPException(status_code=401, detail="Servidor de fazenda não autenticado.")


def current_admin(credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)]) -> str:
    require_config()
    if credentials is None:
        raise HTTPException(status_code=401, detail="Entre no painel central.")
    try:
        claims = jwt.decode(credentials.credentials, JWT_SECRET, algorithms=["HS256"], options={"require": ["exp", "sub", "role"]})
        if claims.get("role") != "admin" or not isinstance(claims.get("sub"), str):
            raise ValueError("invalid admin claim")
        with connect() as db:
            exists = db.execute("SELECT 1 FROM admins WHERE username=? COLLATE NOCASE", (claims["sub"],)).fetchone()
        if exists is None:
            raise ValueError("admin removed")
        return claims["sub"]
    except (jwt.InvalidTokenError, ValueError) as error:
        raise HTTPException(status_code=401, detail="Sessão do painel inválida ou expirada.") from error


def validate_farm_id(value: object) -> str:
    if not isinstance(value, str) or not (1 <= len(value) <= 160) or any(ch not in FARM_ID_CHARS for ch in value):
        raise HTTPException(status_code=400, detail="ID da fazenda inválido.")
    return value


def farm_payload(db: sqlite3.Connection, farm: sqlite3.Row) -> dict:
    license_row = db.execute(
        "SELECT * FROM licenses WHERE activated_farm_id=? ORDER BY issued_at DESC LIMIT 1", (farm["farm_id"],)
    ).fetchone()
    status = license_row["status"] if license_row else ("trial" if now_utc() < parse_time(farm["trial_ends_at"]) else "expired")
    if license_row and status == "active" and license_row["expires_at"] and now_utc() >= parse_time(license_row["expires_at"]):
        status = "expired"
    contract = db.execute("SELECT managed_mode FROM commercial_contracts WHERE farm_id=?",(farm["farm_id"],)).fetchone()
    return {
        "contractManaged": bool(contract and contract["managed_mode"] == "custom"),
        "farmId": farm["farm_id"], "farmName": farm["farm_name"], "firstSeenAt": farm["first_seen_at"],
        "lastSeenAt": farm["last_seen_at"], "trialStartedAt": farm["trial_started_at"],
        "trialEndsAt": farm["trial_ends_at"], "licenseId": license_row["license_id"] if license_row else None,
        "plan": license_row["plan"] if license_row else None, "licenseStatus": status,
        "expiresAt": license_row["expires_at"] if license_row else None,
    }


def event(db: sqlite3.Connection, license_id: str, action: str, farm_id: str | None, details: str, admin: str) -> None:
    db.execute("INSERT INTO license_events VALUES(?,?,?,?,?,?,?)",
               (str(uuid.uuid4()), license_id, action, farm_id, details[:300], admin, iso(now_utc())))


app = FastAPI(title="AgroGestor Central License Server", docs_url=None, redoc_url=None, openapi_url=None)


@app.on_event("startup")
def startup() -> None:
    initialize_database()


@app.get("/api/v1/health")
def health():
    initialize_database()
    with connect() as db:
        admin_ready = db.execute("SELECT 1 FROM admins LIMIT 1").fetchone() is not None
    return {"status": "ok", "adminReady": admin_ready, "provider": "windows"}


@app.get("/")
def home():
    return FileResponse(ROOT / "public" / "index.html")


class AdminLogin(BaseModel):
    username: str = Field(min_length=3, max_length=120)
    password: str = Field(min_length=1, max_length=256)


@app.post("/api/v1/admin/login")
def admin_login(body: AdminLogin):
    require_config()
    identity = body.username.strip().lower()
    login_throttle.reserve(identity)
    with connect() as db:
        admin = db.execute("SELECT * FROM admins WHERE username=? COLLATE NOCASE", (body.username.strip(),)).fetchone()
    verified = password_hash.verify(body.password, admin["password_hash"] if admin is not None else _login_dummy_hash)
    if admin is None or not verified:
        raise HTTPException(status_code=401, detail="Usuário ou senha incorretos.")
    login_throttle.clear(identity)
    issued = now_utc()
    token = jwt.encode({"sub": admin["username"], "role": "admin", "iat": issued, "exp": issued + timedelta(hours=ADMIN_TOKEN_HOURS)}, JWT_SECRET, algorithm="HS256")
    return {"token": token, "expiresAt": iso(issued + timedelta(hours=ADMIN_TOKEN_HOURS)), "username": admin["username"]}


@app.get("/api/v1/admin/me")
def admin_me(admin: Annotated[str, Depends(current_admin)]):
    return {"username": admin}


@app.get("/api/v1/admin/farms")
def list_farms(_: Annotated[str, Depends(current_admin)]):
    with connect() as db:
        farms = db.execute("SELECT * FROM farms ORDER BY farm_name COLLATE NOCASE").fetchall()
        return {"farms": [farm_payload(db, farm) for farm in farms]}


@app.get("/api/v1/admin/licenses")
def list_licenses(_: Annotated[str, Depends(current_admin)]):
    with connect() as db:
        rows = db.execute("SELECT l.*, f.farm_name FROM licenses l LEFT JOIN farms f ON f.farm_id=l.activated_farm_id ORDER BY l.issued_at DESC").fetchall()
    return {"licenses": [{"licenseId": row["license_id"], "plan": row["plan"], "status": row["status"],
                           "activatedFarmId": row["activated_farm_id"], "farmName": row["farm_name"],
                           "issuedAt": row["issued_at"], "activatedAt": row["activated_at"],
                           "expiresAt": row["expires_at"], "note": row["note"]} for row in rows]}


class IssueLicense(BaseModel):
    plan: Literal["monthly", "quarterly", "annual", "lifetime"] = "monthly"
    note: str = Field(default="", max_length=300)


@app.post("/api/v1/admin/licenses")
def issue_license(body: IssueLicense, admin: Annotated[str, Depends(current_admin)]):
    key = "AGRO-" + secrets.token_urlsafe(32)
    license_id = str(uuid.uuid4())
    now = iso(now_utc())
    with transaction() as db:
        db.execute("INSERT INTO licenses(license_id,key_hash,plan,status,issued_at,note,changed_at) VALUES(?,?,?,'issued',?,?,?)",
                   (license_id, hashlib.sha256(key.encode()).hexdigest(), body.plan, now, body.note.strip(), now))
        event(db, license_id, "issued", None, body.plan, admin)
    return {"licenseId": license_id, "licenseKey": key, "status": "issued", "plan": body.plan}


class FarmLicenseChange(BaseModel):
    action: Literal["activate", "renew", "suspend", "revoke"]
    plan: Literal["monthly", "quarterly", "annual", "lifetime"] = "monthly"
    note: str = Field(default="", max_length=300)


@app.post("/api/v1/admin/farms/{farm_id}/license")
def change_farm_license(farm_id: str, body: FarmLicenseChange, admin: Annotated[str, Depends(current_admin)]):
    farm_id = validate_farm_id(farm_id)
    now = now_utc()
    with transaction() as db:
        farm = db.execute("SELECT * FROM farms WHERE farm_id=?", (farm_id,)).fetchone()
        if farm is None:
            raise HTTPException(status_code=404, detail="A fazenda ainda não se conectou a este servidor central.")
        contract = db.execute("SELECT managed_mode FROM commercial_contracts WHERE farm_id=?",(farm_id,)).fetchone()
        if contract and contract["managed_mode"] == "custom":
            raise HTTPException(409, "Edite a validade e a situação na contratação personalizada deste cliente.")
        license_row = db.execute("SELECT * FROM licenses WHERE activated_farm_id=? ORDER BY issued_at DESC LIMIT 1", (farm_id,)).fetchone()
        if body.action == "activate" and license_row and license_row["status"] not in ("issued", "expired", "suspended", "active"):
            raise HTTPException(status_code=409, detail="Esta licença foi revogada. Emita uma licença nova para liberar a fazenda.")
        if body.action == "renew" and license_row is None:
            raise HTTPException(status_code=409, detail="Ative uma licença antes de renová-la.")
        if body.action in ("activate", "renew"):
            plan = body.plan if body.action == "activate" else license_row["plan"]
            current_expiry = parse_time(license_row["expires_at"]) if license_row else None
            base = max(now, current_expiry) if body.action == "renew" and current_expiry else now
            days = PLAN_DAYS[plan]
            expires = iso(base + timedelta(days=days)) if days is not None else None
            if license_row:
                if license_row["status"] == "revoked":
                    raise HTTPException(status_code=409, detail="Licença revogada não pode ser reativada; emita outra licença.")
                db.execute("UPDATE licenses SET plan=?,status='active',activated_farm_id=?,activated_at=COALESCE(activated_at,?),expires_at=?,note=?,changed_at=? WHERE license_id=?",
                           (plan, farm_id, iso(now), expires, body.note.strip() or license_row["note"], iso(now), license_row["license_id"]))
                license_id = license_row["license_id"]
            else:
                license_id = str(uuid.uuid4())
                db.execute("INSERT INTO licenses(license_id,plan,status,activated_farm_id,issued_at,activated_at,expires_at,note,changed_at) VALUES(?,?,'active',?,?,?,?,?,?)",
                           (license_id, plan, farm_id, iso(now), iso(now), expires, body.note.strip(), iso(now)))
            event(db, license_id, body.action, farm_id, f"{plan}; expira={expires or 'nunca'}", admin)
        else:
            if license_row is None:
                raise HTTPException(status_code=409, detail="Esta fazenda não tem licença paga vinculada.")
            if body.action == "suspend":
                db.execute("UPDATE licenses SET status='suspended',note=?,changed_at=? WHERE license_id=?",
                           (body.note.strip() or license_row["note"], iso(now), license_row["license_id"]))
            else:
                db.execute("UPDATE licenses SET status='revoked',note=?,changed_at=? WHERE license_id=?",
                           (body.note.strip() or license_row["note"], iso(now), license_row["license_id"]))
            license_id = license_row["license_id"]
            event(db, license_id, body.action, farm_id, body.note.strip(), admin)
        from .contracts import sync_legacy
        sync_legacy(__import__(__name__,fromlist=["app"]),db,farm_id,admin)
        return farm_payload(db, db.execute("SELECT * FROM farms WHERE farm_id=?", (farm_id,)).fetchone())


class CheckLicenseBody(BaseModel):
    farmId: str = Field(min_length=1, max_length=160)
    farmName: str = Field(default="Fazenda sem nome", max_length=160)
    licenseId: str | None = Field(default=None, max_length=80)


class ActivateLicenseBody(CheckLicenseBody):
    licenseKey: str = Field(min_length=20, max_length=100)


class LicenseReferenceBody(BaseModel):
    licenseId: str = Field(min_length=1, max_length=80)


class TransferLicenseBody(LicenseReferenceBody):
    newFarmId: str = Field(min_length=1, max_length=160)


@app.post("/checkLicense")
async def check_license(body: CheckLicenseBody, _: Annotated[None, Depends(require_server_key)]):
    # The Firebase-compatible HTTP contract lets a farm choose this Windows server
    # by changing only AGROGESTOR_LICENSE_API_BASE in its private .env.
    payload = body.model_dump()
    farm_id = validate_farm_id(payload.get("farmId"))
    farm_name = str(payload.get("farmName") or "Fazenda sem nome").strip()[:160] or "Fazenda sem nome"
    now = now_utc()
    now_text = iso(now)
    with transaction() as db:
        row = db.execute("SELECT * FROM farms WHERE farm_id=?", (farm_id,)).fetchone()
        if row is None:
            end = now + timedelta(days=30)
            db.execute("INSERT INTO farms VALUES(?,?,?,?,?,?)", (farm_id, farm_name, now_text, now_text, now_text, iso(end)))
        else:
            db.execute("UPDATE farms SET farm_name=?,last_seen_at=? WHERE farm_id=?", (farm_name, now_text, farm_id))
        license_row = db.execute("SELECT * FROM licenses WHERE activated_farm_id=? ORDER BY issued_at DESC LIMIT 1", (farm_id,)).fetchone()
        trial = db.execute("SELECT trial_started_at,trial_ends_at FROM farms WHERE farm_id=?", (farm_id,)).fetchone()
        if license_row:
            expires = parse_time(license_row["expires_at"])
            if license_row["status"] == "active" and (expires is None or now < expires):
                return {"status": "active", "licenseId": license_row["license_id"], "checkedAt": now_text, "expiresAt": license_row["expires_at"]}
            return {"status": "inactive", "checkedAt": now_text, "licenseStatus": license_row["status"], "expiresAt": license_row["expires_at"]}
        end = parse_time(trial["trial_ends_at"])
        status = "trial" if end and now < end else "expired"
        return {"status": status, "trialStartedAt": trial["trial_started_at"], "trialEndsAt": trial["trial_ends_at"], "checkedAt": now_text}


@app.post("/activateLicense")
async def activate_license(body: ActivateLicenseBody, _: Annotated[None, Depends(require_server_key)]):
    payload = body.model_dump()
    key = str(payload.get("licenseKey") or "").strip()
    farm_id = validate_farm_id(payload.get("farmId"))
    farm_name = str(payload.get("farmName") or "Fazenda sem nome").strip()[:160] or "Fazenda sem nome"
    if not (20 <= len(key) <= 100):
        raise HTTPException(status_code=400, detail="Chave de licença inválida.")
    key_hash = hashlib.sha256(key.encode()).hexdigest()
    now = now_utc()
    with transaction() as db:
        license_row = db.execute("SELECT * FROM licenses WHERE key_hash=?", (key_hash,)).fetchone()
        if license_row is None:
            raise HTTPException(status_code=404, detail="Chave de licença inválida.")
        if license_row["status"] in ("suspended", "revoked", "expired"):
            raise HTTPException(status_code=409, detail="Esta licença está suspensa, expirada ou revogada.")
        if license_row["activated_farm_id"] and license_row["activated_farm_id"] != farm_id:
            raise HTTPException(status_code=409, detail="Esta licença já está vinculada a outra fazenda.")
        if license_row["activated_farm_id"] == farm_id:
            expiry = parse_time(license_row["expires_at"])
            if expiry is not None and now >= expiry:
                raise HTTPException(status_code=409, detail="Esta licença expirou. Solicite a renovação ao administrador central.")
            return {"licenseId": license_row["license_id"], "status": "active", "expiresAt": license_row["expires_at"]}
        if db.execute("SELECT 1 FROM farms WHERE farm_id=?", (farm_id,)).fetchone() is None:
            db.execute("INSERT INTO farms VALUES(?,?,?,?,?,?)", (farm_id, farm_name, iso(now), iso(now), iso(now), iso(now + timedelta(days=30))))
        expires = iso(now + timedelta(days=PLAN_DAYS[license_row["plan"]])) if PLAN_DAYS[license_row["plan"]] else None
        db.execute("UPDATE licenses SET status='active',activated_farm_id=?,activated_at=COALESCE(activated_at,?),expires_at=?,changed_at=? WHERE license_id=?",
                   (farm_id, iso(now), expires, iso(now), license_row["license_id"]))
        db.execute("UPDATE farms SET farm_name=?,last_seen_at=? WHERE farm_id=?", (farm_name, iso(now), farm_id))
        event(db, license_row["license_id"], "activated", farm_id, license_row["plan"], "server")
    return {"licenseId": license_row["license_id"], "status": "active", "expiresAt": expires}


@app.post("/revokeLicense")
async def revoke_license(body: LicenseReferenceBody, admin: Annotated[str, Depends(current_admin)]):
    payload = body.model_dump()
    license_id = str(payload.get("licenseId") or "")
    with transaction() as db:
        row = db.execute("SELECT * FROM licenses WHERE license_id=?", (license_id,)).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="Licença não encontrada.")
        db.execute("UPDATE licenses SET status='revoked',changed_at=? WHERE license_id=?", (iso(now_utc()), license_id))
        event(db, license_id, "revoked", row["activated_farm_id"], "", admin)
    return {"revoked": True}


@app.post("/transferLicense")
async def transfer_license(body: TransferLicenseBody, admin: Annotated[str, Depends(current_admin)]):
    payload = body.model_dump()
    license_id = str(payload.get("licenseId") or "")
    new_farm_id = validate_farm_id(payload.get("newFarmId"))
    now = iso(now_utc())
    with transaction() as db:
        row = db.execute("SELECT * FROM licenses WHERE license_id=?", (license_id,)).fetchone()
        if row is None or row["status"] != "active":
            raise HTTPException(status_code=409, detail="Somente licenças ativas podem ser transferidas.")
        expiry = parse_time(row["expires_at"])
        if expiry is not None and now_utc() >= expiry:
            raise HTTPException(status_code=409, detail="Licença expirada não pode ser transferida.")
        if db.execute("SELECT 1 FROM farms WHERE farm_id=?", (new_farm_id,)).fetchone() is None:
            raise HTTPException(status_code=404, detail="A fazenda de destino precisa se conectar primeiro.")
        old_farm_id = row["activated_farm_id"]
        if new_farm_id == old_farm_id:
            raise HTTPException(status_code=409, detail="A licença já está nesta fazenda.")
        db.execute("UPDATE licenses SET activated_farm_id=?,changed_at=? WHERE license_id=?", (new_farm_id, now, license_id))
        event(db, license_id, "transferred", new_farm_id, f"origem={old_farm_id}", admin)
    return {"transferred": True}


from . import contracts as commercial_contracts
import sys as _sys
commercial_contracts.install(_sys.modules[__name__])


@app.get("/contracts.js")
def contracts_script():
    return FileResponse(ROOT / "public" / "contracts.js", media_type="text/javascript")
