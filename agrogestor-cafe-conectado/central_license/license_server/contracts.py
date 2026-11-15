"""Individual contracts. Operational telemetry contains counts only, never business records."""
import hashlib
import json
import secrets
import uuid
from datetime import datetime, timezone
from datetime import timedelta
from typing import Annotated, Literal

from fastapi import Depends, Header, HTTPException
from pydantic import BaseModel, ConfigDict, Field, model_validator

RESOURCES = ('properties', 'machines', 'users', 'devices', 'implements')
MODULES = {'properties': [], 'fleet': ['properties'], 'operations': ['properties', 'fleet', 'inventory'],
           'inventory': ['properties'], 'fuel': ['inventory', 'fleet'], 'workshop': ['fleet', 'inventory'],
           'tasks': ['properties','operations'], 'reports': ['properties']}


class Limits(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    properties: int | None = Field(default=None, ge=0, le=1000000)
    machines: int | None = Field(default=None, ge=0, le=1000000)
    users: int | None = Field(default=None, ge=0, le=1000000)
    devices: int | None = Field(default=None, ge=0, le=1000000)
    implements: int | None = Field(default=None, ge=0, le=1000000)


class Contract(BaseModel):
    model_config = ConfigDict(extra='forbid')
    customer_name: str = Field(min_length=1, max_length=160)
    plan_name: str = Field(min_length=1, max_length=100)
    price_cents: int = Field(default=0, ge=0, le=1000000000000, strict=True)
    periodicity: Literal['monthly', 'quarterly', 'annual', 'one_time', 'custom'] = 'monthly'
    starts_at: datetime
    expires_at: datetime | None = None
    courtesy_until: datetime | None = None
    status: Literal['active', 'trial', 'suspended', 'expired'] = 'active'
    limits: Limits = Field(default_factory=Limits)
    modules: list[str] = Field(default_factory=lambda: list(MODULES))
    deployment: str = Field(default='', max_length=2000)
    training: str = Field(default='', max_length=2000)
    support: str = Field(default='', max_length=2000)
    notes: str = Field(default='', max_length=4000)

    @model_validator(mode='after')
    def validate_contract(self):
        for key in ('starts_at', 'expires_at', 'courtesy_until'):
            value = getattr(self, key)
            if value is not None:
                if value.tzinfo is None:
                    raise ValueError('Informe datas com fuso horário.')
                setattr(self, key, value.astimezone(timezone.utc))
        if self.expires_at is not None and self.expires_at <= self.starts_at:
            raise ValueError('A validade deve ser posterior ao início.')
        if len(set(self.modules)) != len(self.modules) or set(self.modules) - MODULES.keys():
            raise ValueError('Módulo desconhecido ou repetido.')
        for module in self.modules:
            missing = set(MODULES[module]) - set(self.modules)
            if missing:
                raise ValueError(f'{module} exige: {", ".join(sorted(missing))}.')
        return self


class Change(BaseModel):
    model_config = ConfigDict(extra='forbid')
    contract: Contract
    expected_revision: int = Field(ge=0)
    reason: str = Field(min_length=3, max_length=1000)
    confirm_reduction: bool = False


class Usage(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    properties: int = Field(ge=0)
    machines: int = Field(ge=0)
    users: int = Field(ge=0)
    devices: int = Field(ge=0)
    implements: int = Field(ge=0)
    reserved_users: int = Field(default=0, ge=0)


class Exchange(BaseModel):
    model_config = ConfigDict(extra='forbid')
    farm_id: str = Field(min_length=1, max_length=160)
    applied_revision: int = Field(ge=0)
    measured_at: datetime
    usage: Usage
    server_version: str = Field(max_length=80)


class Register(BaseModel):
    model_config = ConfigDict(extra='forbid')
    farm_id: str = Field(min_length=1, max_length=160)
    customer_name: str = Field(min_length=1, max_length=160)


def initialize(db):
    # Separate additive migration; old licensing tables and their semantics remain intact.
    db.execute('''CREATE TABLE IF NOT EXISTS commercial_contracts (
      farm_id TEXT PRIMARY KEY,revision INTEGER NOT NULL,config_json TEXT NOT NULL,
      changed_at TEXT NOT NULL,integration_hash TEXT,managed_mode TEXT NOT NULL DEFAULT 'compatibility')''')
    if 'managed_mode' not in {r[1] for r in db.execute('PRAGMA table_info(commercial_contracts)')}:
        db.execute("ALTER TABLE commercial_contracts ADD COLUMN managed_mode TEXT NOT NULL DEFAULT 'compatibility'")
    db.execute('''CREATE TABLE IF NOT EXISTS commercial_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,farm_id TEXT NOT NULL,revision INTEGER NOT NULL,
      admin TEXT NOT NULL,reason TEXT NOT NULL,before_json TEXT,after_json TEXT NOT NULL,created_at TEXT NOT NULL)''')
    db.execute('''CREATE TABLE IF NOT EXISTS commercial_usage (
      farm_id TEXT PRIMARY KEY,applied_revision INTEGER NOT NULL,usage_json TEXT NOT NULL,
      measured_at TEXT NOT NULL,received_at TEXT NOT NULL,server_version TEXT NOT NULL)''')
    db.execute('''CREATE TABLE IF NOT EXISTS commercial_templates (
      name TEXT PRIMARY KEY,revision INTEGER NOT NULL,config_json TEXT NOT NULL,changed_at TEXT NOT NULL)''')


def compatibility(api, db, farm):
    row = db.execute('SELECT * FROM commercial_contracts WHERE farm_id=?', (farm['farm_id'],)).fetchone()
    if row:
        return row
    old = api.farm_payload(db, farm)
    config = Contract(customer_name=farm['farm_name'], plan_name='Compatibilidade',
                      starts_at=api.parse_time(farm['first_seen_at']),
                      status=('trial' if old['licenseStatus']=='trial' else 'active' if old['licenseStatus']=='active' else 'suspended' if old['licenseStatus'] in ('suspended','revoked') else 'expired'),
                      expires_at=api.parse_time(old['expiresAt'] or (farm['trial_ends_at'] if not old['licenseId'] else None)),
                      courtesy_until=api.parse_time(farm['trial_ends_at']) if not old['licenseId'] else None).model_dump(mode='json')
    # Commercial status never substitutes or extends the existing license policy.
    db.execute('INSERT INTO commercial_contracts(farm_id,revision,config_json,changed_at,integration_hash) VALUES(?,1,?,?,NULL)',
               (farm['farm_id'], json.dumps(config), api.iso(api.now_utc())))
    db.execute('''INSERT INTO commercial_events(farm_id,revision,admin,reason,after_json,created_at)
      VALUES(?,1,'migration','Compatibilidade sem alteração de validade',?,?)''',
               (farm['farm_id'], json.dumps(config), api.iso(api.now_utc())))
    return db.execute('SELECT * FROM commercial_contracts WHERE farm_id=?', (farm['farm_id'],)).fetchone()


def payload(api, db, row):
    usage = db.execute('SELECT * FROM commercial_usage WHERE farm_id=?', (row['farm_id'],)).fetchone()
    config = json.loads(row['config_json'])
    counts = json.loads(usage['usage_json']) if usage else None
    totals = {}
    for key in RESOURCES:
        used = counts[key] if counts else None
        reserved = counts.get('reserved_users', 0) if counts and key == 'users' else 0
        limit = config['limits'][key]
        totals[key] = {'limit': limit, 'used': used, 'reserved': reserved,
                       'available': max(0, limit-used-reserved) if limit is not None and used is not None else None,
                       'overage': max(0, used+reserved-limit) if limit is not None and used is not None else None}
    return {'farm_id': row['farm_id'], 'revision': row['revision'], 'contract': config,
            'usage': totals, 'measured_at': usage['measured_at'] if usage else None,
            'last_communication': usage['received_at'] if usage else None,
            'stale': not usage or (api.now_utc()-api.parse_time(usage['received_at'])).total_seconds() > 86400,
            'applied_revision': usage['applied_revision'] if usage else None,
            'pending': not usage or usage['applied_revision'] != row['revision']}


def sync_legacy(api, db, farm_id, admin):
    row = db.execute('SELECT * FROM commercial_contracts WHERE farm_id=?',(farm_id,)).fetchone()
    if not row or row['managed_mode'] != 'compatibility':
        return
    farm = db.execute('SELECT * FROM farms WHERE farm_id=?',(farm_id,)).fetchone()
    old = api.farm_payload(db, farm)
    config = json.loads(row['config_json'])
    config['status'] = ('trial' if old['licenseStatus']=='trial' else 'active' if old['licenseStatus']=='active' else 'suspended' if old['licenseStatus'] in ('suspended','revoked') else 'expired')
    config['expires_at'] = old['expiresAt'] or (farm['trial_ends_at'] if not old['licenseId'] else None)
    config['courtesy_until'] = farm['trial_ends_at'] if not old['licenseId'] else None
    encoded = json.dumps(config);stamp = api.iso(api.now_utc());revision=row['revision']+1
    db.execute('UPDATE commercial_contracts SET revision=?,config_json=?,changed_at=? WHERE farm_id=?',(revision,encoded,stamp,farm_id))
    db.execute('INSERT INTO commercial_events(farm_id,revision,admin,reason,before_json,after_json,created_at) VALUES(?,?,?,?,?,?,?)',
               (farm_id,revision,admin,'Validade/situação atualizadas pelo controle de licença existente',row['config_json'],encoded,stamp))


def install(api):
    app = api.app
    Admin = Annotated[str, Depends(api.current_admin)]

    @app.post('/api/v1/admin/contracts')
    def register(body: Register, admin: Admin):
        identity = api.validate_farm_id(body.farm_id)
        stamp = api.iso(api.now_utc())
        with api.transaction() as db:
            if db.execute('SELECT 1 FROM farms WHERE farm_id=?',(identity,)).fetchone():
                raise HTTPException(409, 'Organização já cadastrada. Abra a ficha existente.')
            db.execute('INSERT INTO farms VALUES(?,?,?,?,?,?)',
                       (identity,body.customer_name,stamp,stamp,stamp,api.iso(api.now_utc()+timedelta(days=30))))
            result = compatibility(api,db,db.execute('SELECT * FROM farms WHERE farm_id=?',(identity,)).fetchone())
            db.execute("UPDATE commercial_events SET admin=?,reason='Cadastro administrativo da organização' WHERE farm_id=? AND revision=1",(admin,identity))
            return payload(api,db,result)

    @app.get('/api/v1/admin/contract-templates')
    def templates(admin: Admin):
        with api.connect() as db:
            return {'items':[{'name':r['name'],'revision':r['revision'],'contract':json.loads(r['config_json'])}
                             for r in db.execute('SELECT * FROM commercial_templates ORDER BY name')]}

    @app.put('/api/v1/admin/contract-templates/{name}')
    def save_template(name: str, body: Change, admin: Admin):
        api.validate_farm_id(name)
        with api.transaction() as db:
            old=db.execute('SELECT * FROM commercial_templates WHERE name=?',(name,)).fetchone()
            revision=old['revision'] if old else 0
            if revision != body.expected_revision:
                raise HTTPException(409,'O modelo mudou. Atualize antes de salvar.')
            encoded=json.dumps(body.contract.model_dump(mode='json'));stamp=api.iso(api.now_utc())
            db.execute('INSERT INTO commercial_templates VALUES(?,?,?,?) ON CONFLICT(name) DO UPDATE SET revision=excluded.revision,config_json=excluded.config_json,changed_at=excluded.changed_at',
                       (name,revision+1,encoded,stamp))
            db.execute('INSERT INTO commercial_events(farm_id,revision,admin,reason,before_json,after_json,created_at) VALUES(?,?,?,?,?,?,?)',
                       ('@template:'+name,revision+1,admin,body.reason,old['config_json'] if old else None,encoded,stamp))
            return {'name':name,'revision':revision+1}

    def find(db, identity):
        api.validate_farm_id(identity)
        farm = db.execute('SELECT * FROM farms WHERE farm_id=?', (identity,)).fetchone()
        if not farm:
            raise HTTPException(404, 'Cliente ainda não conectado ao painel central.')
        return compatibility(api, db, farm)

    @app.get('/api/v1/admin/contracts')
    def contracts(admin: Admin):
        with api.transaction() as db:
            return {'items': [payload(api, db, compatibility(api, db, f)) for f in db.execute('SELECT * FROM farms').fetchall()],
                    'modules': MODULES}

    @app.get('/api/v1/admin/contracts/{farm_id}')
    def get_contract(farm_id: str, admin: Admin):
        with api.transaction() as db:
            row = find(db, farm_id)
            result = payload(api, db, row)
            result['audit'] = [dict(r) for r in db.execute('SELECT * FROM commercial_events WHERE farm_id=? ORDER BY id DESC LIMIT 50', (farm_id,))]
            return result

    @app.post('/api/v1/admin/contracts/{farm_id}/preview')
    def preview(farm_id: str, body: Change, admin: Admin):
        with api.transaction() as db:
            row = find(db, farm_id)
            result = payload(api, db, row)
            limits = body.contract.limits.model_dump()
            old = result['contract']['limits']
            return {'revision': row['revision'], 'stale': result['stale'],
                    'reductions': [k for k in RESOURCES if limits[k] is not None and (old[k] is None or limits[k] < old[k])],
                    'impact': {k: {'used': v['used'], 'reserved': v['reserved'], 'new_limit': limits[k],
                                  'overage': max(0, v['used']+v['reserved']-limits[k]) if v['used'] is not None and limits[k] is not None else None}
                               for k,v in result['usage'].items()}}

    @app.put('/api/v1/admin/contracts/{farm_id}')
    def save(farm_id: str, body: Change, admin: Admin):
        with api.transaction() as db:
            row = find(db, farm_id)
            if row['revision'] != body.expected_revision:
                raise HTTPException(409, 'A contratação mudou. Atualize antes de salvar.')
            old = json.loads(row['config_json'])
            new = body.contract.model_dump(mode='json')
            reductions = [k for k in RESOURCES if new['limits'][k] is not None and
                          (old['limits'][k] is None or new['limits'][k] < old['limits'][k])]
            if (reductions or set(old['modules'])-set(new['modules'])) and not body.confirm_reduction:
                raise HTTPException(409, 'Confira a prévia e confirme a redução de limites ou recursos.')
            revision, stamp = row['revision']+1, api.iso(api.now_utc())
            # An explicit commercial save applies the chosen license validity too.
            # Compatibility is copied from the existing expiry, never renewed on migration.
            license_row = db.execute('SELECT * FROM licenses WHERE activated_farm_id=? ORDER BY issued_at DESC LIMIT 1',(farm_id,)).fetchone()
            license_id = license_row['license_id'] if license_row and license_row['status'] != 'revoked' else str(uuid.uuid4())
            expiry = new['expires_at']
            if new['status'] == 'trial' and new['courtesy_until']:
                expiry = min(expiry,new['courtesy_until']) if expiry else new['courtesy_until']
            license_status = 'active' if new['status'] in ('active','trial') else new['status']
            legacy_plan = license_row['plan'] if license_row else ('monthly' if expiry else 'lifetime')
            db.execute('''INSERT INTO licenses(license_id,plan,status,activated_farm_id,issued_at,activated_at,expires_at,note,changed_at)
              VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(license_id) DO UPDATE SET status=excluded.status,
              expires_at=excluded.expires_at,note=excluded.note,changed_at=excluded.changed_at''',
              (license_id,legacy_plan,license_status,farm_id,stamp,stamp,expiry,'Contratação personalizada',stamp))
            api.event(db,license_id,'contract-updated',farm_id,'Revisão '+str(revision),admin)
            db.execute("UPDATE commercial_contracts SET revision=?,config_json=?,changed_at=?,managed_mode='custom' WHERE farm_id=?",
                       (revision, json.dumps(new), stamp, farm_id))
            db.execute('''INSERT INTO commercial_events(farm_id,revision,admin,reason,before_json,after_json,created_at)
              VALUES(?,?,?,?,?,?,?)''', (farm_id, revision, admin, body.reason, row['config_json'], json.dumps(new), stamp))
            return payload(api, db, find(db, farm_id))

    @app.post('/api/v1/admin/contracts/{farm_id}/integration-key')
    def integration_key(farm_id: str, admin: Admin):
        key = secrets.token_urlsafe(40)
        with api.transaction() as db:
            row = find(db, farm_id)
            db.execute('UPDATE commercial_contracts SET integration_hash=? WHERE farm_id=?', (hashlib.sha256(key.encode()).hexdigest(), farm_id))
            db.execute('''INSERT INTO commercial_events(farm_id,revision,admin,reason,after_json,created_at)
              VALUES(?,?,?,?,?,?)''', (farm_id, row['revision'], admin, 'Rotação da credencial de integração', '{}', api.iso(api.now_utc())))
        return {'key': key, 'message': 'Guarde no .env privado do PC gestor. Exibida somente agora.'}

    @app.post('/api/v1/contracts/exchange')
    def exchange(body: Exchange, key: Annotated[str | None, Header(alias='X-Agrogestor-Organization-Key')] = None):
        with api.transaction() as db:
            row = db.execute('SELECT * FROM commercial_contracts WHERE farm_id=?', (body.farm_id,)).fetchone()
            if not row or not row['integration_hash'] or not key or not secrets.compare_digest(row['integration_hash'], hashlib.sha256(key.encode()).hexdigest()):
                raise HTTPException(401, 'Integração não autenticada para esta organização.')
            measured = body.measured_at
            if measured.tzinfo is None or abs((api.now_utc()-measured).total_seconds()) > 600 or body.applied_revision > row['revision']:
                raise HTTPException(422, 'Medição ou revisão inválida.')
            previous = db.execute('SELECT * FROM commercial_usage WHERE farm_id=?', (body.farm_id,)).fetchone()
            if previous and (body.applied_revision < previous['applied_revision'] or measured < api.parse_time(previous['measured_at'])):
                raise HTTPException(409, 'Medição antiga. Refaça a leitura no PC gestor.')
            db.execute('''INSERT INTO commercial_usage VALUES(?,?,?,?,?,?) ON CONFLICT(farm_id) DO UPDATE SET
              applied_revision=excluded.applied_revision,usage_json=excluded.usage_json,measured_at=excluded.measured_at,
              received_at=excluded.received_at,server_version=excluded.server_version''',
                       (body.farm_id, body.applied_revision, json.dumps(body.usage.model_dump()), api.iso(measured), api.iso(api.now_utc()), body.server_version))
            return {'farm_id': body.farm_id, 'revision': row['revision'], 'contract': json.loads(row['config_json']), 'confirmed_at': api.iso(api.now_utc())}
