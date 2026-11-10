"""Commercial rights are independent from account permissions and license leases."""
import json
import os
import urllib.request
from urllib.parse import urlsplit
from datetime import datetime, timezone
from uuid import NAMESPACE_URL, uuid5

from fastapi import HTTPException
from pydantic import BaseModel, Field

RESOURCES = ('properties', 'machines', 'users', 'devices', 'implements')
MODULES = {'properties': [], 'fleet': ['properties'], 'operations': ['properties','fleet','inventory'],
           'inventory': ['properties'], 'fuel': ['inventory','fleet'], 'workshop': ['fleet','inventory'],
           'tasks': ['properties','operations'], 'reports': ['properties']}
STATEMENTS = [
    '''CREATE TABLE IF NOT EXISTS commercial_entitlements (
       farm_id TEXT PRIMARY KEY,revision INTEGER NOT NULL,config_json TEXT NOT NULL,
       confirmed_at TEXT NOT NULL,last_attempt_at TEXT,last_error TEXT)''',
    '''CREATE TABLE IF NOT EXISTS commercial_audit (
       seq INTEGER PRIMARY KEY AUTOINCREMENT,farm_id TEXT NOT NULL,actor_id TEXT NOT NULL,
       action TEXT NOT NULL,entity_id TEXT NOT NULL,details TEXT NOT NULL,created_at TEXT NOT NULL)''',
]
TENTH_STATEMENTS = [
    'ALTER TABLE v2_machines ADD COLUMN archived INTEGER NOT NULL DEFAULT 0 CHECK(archived IN (0,1))',
    'ALTER TABLE v2_machines ADD COLUMN version INTEGER NOT NULL DEFAULT 1',
]


class CommercialError(HTTPException):
    def __init__(self, code, message, resource=None):
        super().__init__(409, message)
        self.code, self.resource = code, resource


def initialize(db):
    for statement in STATEMENTS:
        db.execute(statement)


def config(db, tenant):
    row = db.execute('SELECT * FROM commercial_entitlements WHERE farm_id=?', (tenant,)).fetchone()
    return (json.loads(row['config_json']), row) if row else (
        {'plan_name': 'Compatibilidade', 'status': 'active', 'limits': dict.fromkeys(RESOURCES), 'modules': list(MODULES)}, None)


def table(db, name):
    return db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone() is not None


def _calculate_usage(db, tenant):
    counts = dict.fromkeys(RESOURCES, 0)
    # V2 + legacy deterministic import IDs form one identity set. Never fuzzy-match names.
    machines, properties = {}, {}
    if table(db, 'v2_properties'):
        properties = {r['id']: not r['archived'] for r in db.execute('SELECT id,archived FROM v2_properties WHERE tenant_id=?', (tenant,))}
        machines = {r['id']: not r['archived'] for r in db.execute('SELECT id,archived FROM v2_machines WHERE tenant_id=?', (tenant,))}
    for row in db.execute("SELECT module,record_id,payload FROM records WHERE farm_id=? AND deleted=0 AND module IN ('machines','clients','implements')", (tenant,)):
        data = json.loads(row['payload'] or '{}')
        if row['module'] == 'machines':
            mapped = str(uuid5(NAMESPACE_URL, f'agrogestor-v2/{tenant}/machine/{row["record_id"]}'))
            if row['record_id'] not in machines and mapped not in machines:
                machines['legacy:'+row['record_id']] = not data.get('archived', False)
        elif row['module'] == 'clients':
            for prop in data.get('properties', []):
                if not prop.get('id'):
                    raise CommercialError('USAGE_REVIEW_REQUIRED', 'Há propriedades antigas sem identificador. Solicite a conferência dos cadastros.')
                mapped = str(uuid5(NAMESPACE_URL, f'agrogestor-v2/{tenant}/property/{row["record_id"]}/{prop["id"]}'))
                if str(prop['id']) not in properties and mapped not in properties:
                    properties['legacy:'+row['record_id']+'/'+str(prop['id'])] = not prop.get('archived', False)
        else:
            counts['implements'] += not data.get('archived', False)
    counts['properties'], counts['machines'] = sum(properties.values()), sum(machines.values())
    counts['users'] = db.execute('SELECT COUNT(*) FROM users WHERE farm_id=? AND disabled=0', (tenant,)).fetchone()[0]
    counts['devices'] = db.execute('SELECT COUNT(*) FROM devices WHERE farm_id=? AND revoked_at IS NULL', (tenant,)).fetchone()[0]
    counts['reserved_users'] = db.execute('''SELECT COUNT(DISTINCT lower(email)) FROM invitations
      WHERE farm_id=? AND used_at IS NULL AND julianday(expires_at)>julianday('now')''', (tenant,)).fetchone()[0]
    return counts


def usage(db, tenant):
    try:
        return _calculate_usage(db, tenant)
    except (ValueError, TypeError, AttributeError, KeyError) as error:
        raise CommercialError('USAGE_REVIEW_REQUIRED', 'Uso indisponível: confira os identificadores e dados dos cadastros antigos. Os históricos permanecem guardados.') from error


def identity_increase(db, tenant, resource, identity):
    if resource == 'machines':
        for row in db.execute("SELECT record_id,payload FROM records WHERE farm_id=? AND module='machines' AND deleted=0", (tenant,)):
            mapped = str(uuid5(NAMESPACE_URL, f'agrogestor-v2/{tenant}/machine/{row["record_id"]}'))
            if str(identity) in (mapped,row['record_id']) and not json.loads(row['payload'] or '{}').get('archived',False):
                return 0
    if resource == 'properties':
        for row in db.execute("SELECT record_id,payload FROM records WHERE farm_id=? AND module='clients' AND deleted=0", (tenant,)):
            for prop in json.loads(row['payload'] or '{}').get('properties',[]):
                mapped = str(uuid5(NAMESPACE_URL, f'agrogestor-v2/{tenant}/property/{row["record_id"]}/{prop.get("id")}'))
                if str(identity) in (mapped,str(prop.get('id'))) and not prop.get('archived',False):
                    return 0
    return 1


def ensure_slot(db, tenant, resource, increase=1, reserved_credit=0):
    if increase <= 0:
        return
    rights, _ = config(db, tenant)
    limit = rights['limits'][resource]
    if limit is None:
        return
    counts = usage(db, tenant)
    used = counts[resource] + (counts['reserved_users']-reserved_credit if resource == 'users' else 0)
    if used + increase > limit:
        label = {'properties':'fazendas','machines':'máquinas','users':'usuários','devices':'aparelhos','implements':'implementos'}[resource]
        code = 'CONTRACT_OVERAGE' if used > limit else 'QUOTA_EXCEEDED'
        raise CommercialError(code, f'O limite de {label} contratado foi atingido. O rascunho continua salvo no aparelho, quando cadastrado offline. Solicite ao gestor a conferência do plano.', resource)


def write_access(db, tenant, module=None):
    rights, row = config(db, tenant)
    if row:
        now = datetime.now(timezone.utc)
        if rights['status'] == 'suspended':
            raise CommercialError('CONTRACT_SUSPENDED', 'Contratação suspensa. Consulte o gestor. Os históricos permanecem disponíveis.')
        def instant(key):
            raw = rights.get(key)
            return datetime.fromisoformat(raw.replace('Z','+00:00')) if raw else None
        start, end = instant('starts_at'), instant('expires_at')
        courtesy = instant('courtesy_until')
        if rights['status'] == 'trial' and courtesy:
            end = min(end,courtesy) if end else courtesy
        if rights['status'] == 'expired' or (end and now >= end) or (start and now < start):
            raise CommercialError('CONTRACT_EXPIRED', 'Contratação fora da validade. Consulte o gestor; seus dados permanecem guardados.')
    if module and module not in rights['modules']:
        raise CommercialError('MODULE_DISABLED', 'Este recurso não está habilitado na contratação. O histórico continua disponível aos usuários autorizados.', module)


def audit(db, api, user, action, identity, details):
    db.execute('INSERT INTO commercial_audit(farm_id,actor_id,action,entity_id,details,created_at) VALUES(?,?,?,?,?,?)',
               (user['farmId'], user['id'], action, identity, json.dumps(details), api.utc_now()))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def open_remote(req):
    return urllib.request.build_opener(NoRedirect).open(req, timeout=10)


def refresh(api, tenant):
    """Only the operational server holds the per-organization credential. Never extend license leases."""
    key = os.getenv('AGROGESTOR_CONTRACT_ORGANIZATION_KEY', '')
    base = (os.getenv('AGROGESTOR_CONTRACT_API_BASE') or api.LICENSE_API_BASE).rstrip('/')
    if not base or not key:
        return False
    target = urlsplit(base)
    if target.username or target.password or target.query or target.fragment or target.scheme not in ('https','http') or (target.scheme == 'http' and target.hostname not in ('127.0.0.1','localhost')):
        return False
    stamp = api.utc_now()
    with api.connect() as db:
        rights, row = config(db, tenant)
        try:
            counts = usage(db, tenant)
        except CommercialError as error:
            db.execute('UPDATE commercial_entitlements SET last_attempt_at=?,last_error=? WHERE farm_id=?',(stamp,error.detail,tenant))
            return False
        request = {'farm_id': tenant, 'applied_revision': row['revision'] if row else 0,
                   'usage': counts, 'measured_at': stamp, 'server_version': '2.1.6'}
    req = urllib.request.Request(base+'/api/v1/contracts/exchange', data=json.dumps(request).encode(),
                                 headers={'Content-Type':'application/json','X-Agrogestor-Organization-Key':key})
    try:
        with open_remote(req) as response:
            raw = json.loads(response.read(65537))
        value = raw['contract']
        if raw['farm_id'] != tenant or not isinstance(raw['revision'], int) or raw['revision'] <= 0:
            raise ValueError('organization/revision')
        limits = value['limits']
        if set(limits) != set(RESOURCES) or any(v is not None and (type(v) is not int or v < 0) for v in limits.values()):
            raise ValueError('limits')
        if set(value['modules'])-MODULES.keys() or any(set(MODULES[m])-set(value['modules']) for m in value['modules']):
            raise ValueError('modules')
        if value['status'] not in ('active','trial','suspended','expired'):
            raise ValueError('status')
        for date in ('starts_at','expires_at','courtesy_until'):
            if value.get(date) and datetime.fromisoformat(value[date].replace('Z','+00:00')).tzinfo is None:
                raise ValueError('timezone')
        with api.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            current = config(db, tenant)[1]
            if current and raw['revision'] < current['revision']:
                raise ValueError('revision rollback')
            if current and raw['revision'] == current['revision'] and json.loads(current['config_json']) != value:
                raise ValueError('changed revision')
            db.execute('''INSERT INTO commercial_entitlements VALUES(?,?,?,?,?,NULL) ON CONFLICT(farm_id) DO UPDATE SET
              revision=excluded.revision,config_json=excluded.config_json,confirmed_at=excluded.confirmed_at,
              last_attempt_at=excluded.last_attempt_at,last_error=NULL''', (tenant, raw['revision'], json.dumps(value), stamp, stamp))
        return True
    except (OSError, ValueError, KeyError, TypeError):
        with api.connect() as db:
            db.execute('UPDATE commercial_entitlements SET last_attempt_at=?,last_error=? WHERE farm_id=?',
                       (stamp, 'Não foi possível confirmar a contratação. A última confirmação foi preservada.', tenant))
        return False


class ArchiveMachine(BaseModel):
    archived: bool
    expected_version: int = Field(ge=1)


def install(api):
    from typing import Annotated
    from fastapi import Depends
    from fastapi.responses import JSONResponse
    User = Annotated[dict, Depends(api.current_user)]
    import threading
    stop = threading.Event()

    @api.app.on_event('startup')
    def start_contract_refresh():
        if not os.getenv('AGROGESTOR_CONTRACT_ORGANIZATION_KEY'):
            return
        stop.clear()
        def poll():
            while not stop.is_set():
                try:
                    with api.connect() as db:
                        farm = db.execute('SELECT farm_id FROM farm WHERE singleton=1').fetchone()
                    if farm:
                        refresh(api, farm['farm_id'])
                except (OSError, ValueError, KeyError):
                    pass
                stop.wait(300)
        threading.Thread(target=poll, name='commercial-refresh', daemon=True).start()

    @api.app.on_event('shutdown')
    def stop_contract_refresh():
        stop.set()


    @api.app.exception_handler(CommercialError)
    async def commercial_error(request, error):
        return JSONResponse(status_code=error.status_code, content={'detail':error.detail, 'code':error.code, 'resource':error.resource})

    @api.app.get('/api/v1/licensing/plan')
    def plan(user: User):
        api.require_role(user, 'admin')
        license_state = api.entitlement_status(user['farmId'])
        refresh(api, user['farmId'])
        with api.connect() as db:
            rights, row = config(db, user['farmId'])
            usage_error = None
            try:
                counts = usage(db, user['farmId'])
            except CommercialError as error:
                counts = dict.fromkeys((*RESOURCES,'reserved_users'))
                usage_error = error.detail
            return {'farm_id':user['farmId'], 'contract':rights, 'usage':counts, 'license':license_state,
                    'revision':row['revision'] if row else 0, 'confirmed_at':row['confirmed_at'] if row else None,
                    'communication_error':usage_error or (row['last_error'] if row else None),
                    'compatibility':row is None,
                    'message':'Alterações comerciais são solicitadas ao administrador do licenciamento. A sincronização confirma revisões; sem comunicação não é possível saber se há alterações no painel central.'}

    @api.app.get('/api/v1/licensing/features')
    def features(user: User):
        with api.connect() as db:
            rights, row = config(db, user['farmId'])
            return {'farm_id':user['farmId'], 'revision':row['revision'] if row else 0,
                    'modules':rights['modules'], 'limits':rights['limits'], 'confirmed_at':row['confirmed_at'] if row else None}

    @api.app.patch('/api/v1/licensing/machines/{machine_id}/archive')
    def archive_machine(machine_id: str, body: ArchiveMachine, user: User):
        api.require_role(user, 'admin')
        api.require_active_license(user['farmId'])
        with api.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            current = db.execute('SELECT * FROM v2_machines WHERE tenant_id=? AND id=?', (user['farmId'],machine_id)).fetchone()
            if not current:
                raise HTTPException(404, 'Máquina não encontrada.')
            if bool(current['archived']) == body.archived and current['version'] == body.expected_version+1:
                return dict(current)
            if current['version'] != body.expected_version:
                raise HTTPException(409, 'Máquina alterada. Atualize antes de salvar.')
            if current['archived'] and not body.archived:
                write_access(db,user['farmId'],'fleet')
                ensure_slot(db,user['farmId'],'machines')
            db.execute('UPDATE v2_machines SET archived=?,version=version+1 WHERE tenant_id=? AND id=?', (int(body.archived),user['farmId'],machine_id))
            audit(db,api,user,'archive-machine' if body.archived else 'reactivate-machine',machine_id,body.model_dump())
            return dict(db.execute('SELECT * FROM v2_machines WHERE tenant_id=? AND id=?', (user['farmId'],machine_id)).fetchone())
