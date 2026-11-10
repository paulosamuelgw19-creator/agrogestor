"""Opt-in, online pilot for fleet, inputs and field operations."""
from . import commercial
from . import geography, harvest, implement_usage
import json
import sqlite3
from contextlib import contextmanager
from datetime import date, datetime
from decimal import Decimal, localcontext
from uuid import UUID, uuid5, NAMESPACE_URL
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Request
from .logistics_access import is_driver_account
from .management_schema import property_record, set_responsible
from .management_api import install_management_routes, plan_operation, undo_plan_operation

from .refueling import validate_refuelings, store_refuelings, read_refuelings, is_fuel
from .v2_models import (ClientBody, PropertyBody, PlotBody, CropBody, CycleBody,
                       GrantBody, MachineBody, InputBody, InputUpdateBody, ReceiptBody, OperationBody, StockCorrectionBody, VoidBody, MachineUpdateBody)
from .v2_metrics import decimal_text, money_round, stock_balance, consumption_value, metric, ratio
from .v2_catalog import ensure_active, validate_area, record_revision, install_catalog_routes
from .work_api import (install_work_routes,reserved,ensure_available,machine_blocked,
                       check_task_operation,finish_task_operation)


def json_text(value):
    if hasattr(value, 'model_dump'):
        value = value.model_dump()
    def encode(item):
        if hasattr(item,'model_dump'):
            return item.model_dump()
        if isinstance(item, Decimal):
            return decimal_text(item)
        if isinstance(item, (UUID, date, datetime)):
            return str(item)
        raise TypeError(type(item).__name__)
    return json.dumps(value, default=encode, sort_keys=True, separators=(',', ':'), ensure_ascii=False)


def build_router(api):
    router = APIRouter(prefix='/api/v2', tags=['v2-pilot'])

    def authenticated(request: Request, user: Annotated[dict, Depends(api.current_user)]):
        if not api.V2_ENABLED:
            raise HTTPException(503, 'O piloto v2 não está habilitado nesta instalação.')
        if user['role'] == 'driver' and request.url.path != '/api/v2/capabilities' and not request.url.path.startswith('/api/v2/logistics/'):
            raise HTTPException(403, 'O caminhoneiro utiliza somente as viagens atribuídas na área de logística.')
        if request.method in ('POST','PUT'):
            path = request.url.path.removeprefix('/api/v2')
            module = {'/inputs':'inventory','/work/tasks':'tasks',
                      '/work/orders':'workshop','/activity-plans':'operations','/admin/stock-items':'inventory',
                      '/plots':'properties','/crops':'operations','/cycles':'operations'}.get(path)
            user = {**user, '_commercial_module': module}
            if module:
                with api.connect() as db:
                    commercial.write_access(db,user['farmId'],module)
        return user

    User = Annotated[dict, Depends(authenticated)]

    @contextmanager
    def write(user):
        api.require_active_license(user['farmId'])
        try:
            with api.connect() as db, localcontext() as arithmetic:
                arithmetic.prec = 50
                db.execute('BEGIN IMMEDIATE')
                commercial.write_access(db,user['farmId'],user.get('_commercial_module'))
                yield db
        except sqlite3.IntegrityError as error:
            raise HTTPException(409, 'Identificador repetido ou vínculo inválido. Atualize os dados.') from error

    def admin(user):
        if user['role'] != 'admin':
            raise HTTPException(403, 'Ação exclusiva do administrador da organização.')

    def catalog_creator(user):
        if user['role'] not in ('admin', 'operator'):
            raise HTTPException(403, 'O gerente ou operador pode criar este cadastro.')

    def visible_clients(db, user):
        if user['role'] == 'admin':
            return [dict(r) for r in db.execute('SELECT * FROM v2_clients WHERE tenant_id=? ORDER BY name', (user['farmId'],))]
        # An operator may reuse a responsible party from an authorized property,
        # or one they created themselves. Names alone never grant property access.
        return [dict(r) for r in db.execute('''SELECT c.* FROM v2_clients c WHERE c.tenant_id=? AND (
          EXISTS (SELECT 1 FROM v2_properties p JOIN v2_access a ON a.tenant_id=p.tenant_id AND a.property_id=p.id
            WHERE p.tenant_id=c.tenant_id AND p.client_id=c.id AND a.user_id=?) OR
          EXISTS (SELECT 1 FROM v2_audit e WHERE e.tenant_id=c.tenant_id AND e.entity_type='client'
            AND e.entity_id=c.id AND e.actor_id=? AND e.action='create')) ORDER BY c.name''',
          (user['farmId'], user['id'], user['id']))]

    def get(db, table, tenant, identity):
        # table is always a constant selected by server code, never user input.
        row = db.execute(f'SELECT * FROM {table} WHERE tenant_id=? AND id=?', (tenant, str(identity))).fetchone()
        if row is None:
            raise HTTPException(404, 'Registro não encontrado.')
        return property_record(db, tenant, row) if table == 'v2_properties' else row

    def access(db, user, property_id, action='read'):
        prop = get(db, 'v2_properties', user['farmId'], property_id)
        if user['role'] == 'admin':
            role = 'administrator'
        else:
            row = db.execute('SELECT role FROM v2_access WHERE tenant_id=? AND user_id=? AND property_id=?',
                             (user['farmId'], user['id'], str(property_id))).fetchone()
            if row is None:
                raise HTTPException(404, 'Propriedade não encontrada.')
            role = row['role']
        if action in ('stock', 'finance', 'audit') and user['role'] != 'admin':
            raise HTTPException(403, 'Ação administrativa exclusiva do gestor.')
        allowed = {
            'read': {'administrator', 'owner', 'manager', 'employee', 'consultant'},
            'operate': {'administrator', 'owner', 'manager', 'employee'},
            'stock': {'administrator', 'owner', 'manager'},
            'finance': {'administrator', 'owner', 'manager', 'consultant'},
            'audit': {'administrator', 'owner', 'manager'},
        }
        if role not in allowed[action]:
            raise HTTPException(403, 'Seu vínculo não permite esta ação.')
        return role

    def cycle_context(db, tenant, cycle_id):
        cycle = get(db, 'v2_cycles', tenant, cycle_id)
        plot = get(db, 'v2_plots', tenant, cycle['plot_id'])
        prop = get(db, 'v2_properties', tenant, plot['property_id'])
        crop = get(db, 'v2_crops', tenant, cycle['crop_id'])
        return cycle, plot, prop, crop

    def audit(db, user, action, entity, identity, after, property_id=None, before=None):
        db.execute('''INSERT INTO v2_audit
          (tenant_id,property_id,actor_id,action,entity_type,entity_id,before_json,after_json,created_at)
          VALUES(?,?,?,?,?,?,?,?,?)''', (user['farmId'], str(property_id) if property_id else None,
            user['id'], action, entity, str(identity), json_text(before) if before is not None else None,
            json_text(after), api.utc_now()))

    def replay(db, user, entity, body):
        previous = db.execute('SELECT request_json FROM v2_requests WHERE tenant_id=? AND entity_type=? AND entity_id=?',
                              (user['farmId'], entity, str(body.id))).fetchone()
        previous_json = previous['request_json'] if previous else None
        # Old input requests predate the optional classification fields.
        if previous and entity == 'input':
            previous_json = json_text(InputBody.model_validate_json(previous_json))
        if previous and entity in {'property', 'plot'}:
            model = PropertyBody if entity == 'property' else PlotBody
            previous_json = json_text(model.model_validate_json(previous_json))
        if previous and entity=='operation':
            previous_json=json_text(OperationBody.model_validate_json(previous_json))
        if previous and entity.startswith('property-update:'):
            previous_json=json_text(type(body).model_validate_json(previous_json))
        if previous and previous_json != json_text(body):
            raise HTTPException(409, 'Este identificador já foi usado com outros dados.')
        return previous is not None

    def remember(db, user, entity, body):
        db.execute('INSERT INTO v2_requests VALUES(?,?,?,?)',
                   (user['farmId'], entity, str(body.id), json_text(body)))

    def insert_named(db, user, table, body, fields):
        values = json.loads(json_text(body))
        columns = ['tenant_id'] + fields
        db.execute(f"INSERT INTO {table} ({','.join(columns)}) VALUES({','.join('?' for _ in columns)})",
                   [user['farmId']] + [values.get(field) for field in fields])

    @router.get('/capabilities')
    def capabilities(user: User):
        return {'pilot': True, 'onlineOnly': False, 'schemaVersion': 11, 'refueling': True,
                'geographicBoundaries': True, 'harvestOutput': True,
                'logistics': False, 'logisticsStage': 'foundation',
                'workflows': True,
                'offlineCatalog': True,
                'propertyCatalog': True,
                'operatorCatalogCreation': True, 'farmBundles': True, 'managementReports': True,
                'unifiedProducts': True,
                'scope': 'fleet-inputs-operations', 'legacyRole': user['role'],
                'exports': [], 'aiEnabled': False}

    @router.get('/workspace')
    def workspace(user: User, property_id: UUID | None = None):
        """One authoritative, permission-filtered mobile snapshot; no legacy JSON."""
        with api.connect() as db:
            tenant = user['farmId']
            if user['role'] == 'admin':
                properties = [dict(r) | {'access_role': 'administrator'} for r in db.execute(
                    'SELECT * FROM v2_properties WHERE tenant_id=? AND archived=0 ORDER BY name', (tenant,))]
            else:
                properties = [dict(r) for r in db.execute('''SELECT p.*,a.role AS access_role
                  FROM v2_properties p JOIN v2_access a ON a.tenant_id=p.tenant_id AND a.property_id=p.id
                  WHERE p.tenant_id=? AND a.user_id=? AND p.archived=0 ORDER BY p.name''', (tenant, user['id']))]
            properties = [property_record(db, tenant, p) for p in properties]
            result = {'generated_at': api.utc_now(), 'organization_id': tenant, 'properties': properties,
                      'administrator': user['role'] == 'admin', 'plots': [], 'cycles': [],
                      'can_create_catalog': user['role'] in ('admin', 'operator'),
                      'crops': [], 'machines': [], 'inputs': [], 'inventory': [], 'operations': []}
            result['clients'] = visible_clients(db, user)
            result['implements'] = implement_usage.catalog(db,tenant) if user['role'] in ('admin','operator') else []
            result['responsibles'] = [dict(r) for r in db.execute('SELECT user_id AS id,display_name AS name,role FROM users WHERE farm_id=? AND disabled=0 ORDER BY display_name',(tenant,))] if user['role'] in ('admin','operator') else []
            if user['role'] == 'admin':
                result['clients'] = [dict(r) for r in db.execute('SELECT * FROM v2_clients WHERE tenant_id=? ORDER BY name', (tenant,))]
                result['crops'] = [dict(r) for r in db.execute('SELECT * FROM v2_crops WHERE tenant_id=? ORDER BY name', (tenant,))]
                result['inputs'] = [dict(r) for r in db.execute('SELECT * FROM v2_inputs WHERE tenant_id=? ORDER BY name', (tenant,))]
            if property_id is None:
                return result
            role = access(db, user, property_id)
            result['plots'] = [dict(r) for r in db.execute('SELECT * FROM v2_plots WHERE tenant_id=? AND property_id=? AND archived=0 ORDER BY name', (tenant, str(property_id)))]
            result['cycles'] = [dict(r) for r in db.execute('''SELECT c.*,p.property_id FROM v2_cycles c JOIN v2_plots p
              ON p.tenant_id=c.tenant_id AND p.id=c.plot_id WHERE c.tenant_id=? AND p.property_id=? AND p.archived=0 ORDER BY c.starts_on DESC''', (tenant, str(property_id)))]
            if user['role'] != 'admin':
                crop_ids = {c['crop_id'] for c in result['cycles']}
                result['crops'] = [dict(get(db, 'v2_crops', tenant, key)) for key in sorted(crop_ids)]
                result['inputs'] = [dict(r) for r in db.execute('''SELECT DISTINCT i.* FROM v2_inputs i JOIN v2_inventory m
                  ON m.tenant_id=i.tenant_id AND m.input_id=i.id WHERE i.tenant_id=? AND m.property_id=? ORDER BY i.name''', (tenant, str(property_id)))]
            result['machines'] = list_machines(property_id, user)['items']
            for item in result['inputs']:
                rows = stock_rows(db, tenant, property_id, item['id'])
                balance = stock_balance(rows)
                stock = {'input_id': item['id'], 'initialized': balance['known'], 'quantity': decimal_text(balance['quantity'])}
                stock['reserved_quantity']=decimal_text(reserved(db,tenant,property_id,item['id']))
                stock['available_quantity']=None if not balance['known'] else decimal_text(balance['quantity']-reserved(db,tenant,property_id,item['id']))
                if user['role'] == 'admin':
                    stock['value_cents'] = balance['value_cents']
                    stock['last_movement_id'] = rows[-1]['id'] if rows else None
                result['inventory'].append(stock)
            rows = db.execute('''SELECT o.id FROM v2_operations o JOIN v2_cycles c ON c.tenant_id=o.tenant_id AND c.id=o.cycle_id
              JOIN v2_plots p ON p.tenant_id=c.tenant_id AND p.id=c.plot_id
              WHERE o.tenant_id=? AND p.property_id=? AND (? = 'admin' OR o.actor_id=?)
              ORDER BY o.performed_on DESC,o.created_at DESC,o.id LIMIT 201''', (tenant, str(property_id), user['role'], user['id'])).fetchall()
            result['operations_truncated'] = len(rows) > 200
            result['operations'] = [operation_detail(db, user, r['id']) for r in rows[:200]]
            return result

    @router.post('/clients')
    def create_client(body: ClientBody, user: User):
        catalog_creator(user)
        with write(user) as db:
            if user['role'] != 'admin' and db.execute('SELECT 1 FROM v2_clients WHERE tenant_id=? AND id=?', (user['farmId'], str(body.id))).fetchone():
                if not any(c['id'] == str(body.id) for c in visible_clients(db, user)):
                    raise HTTPException(404, 'Responsável não disponível para esta conta.')
            if not replay(db, user, 'client', body):
                db.execute('INSERT INTO v2_clients VALUES(?,?,?,?)',
                           (user['farmId'], str(body.id), body.name, api.utc_now()))
                remember(db, user, 'client', body)
                audit(db, user, 'create', 'client', body.id, body)
            return dict(get(db, 'v2_clients', user['farmId'], body.id))

    @router.get('/clients')
    def list_clients(user: User):
        catalog_creator(user)
        with api.connect() as db:
            return {'items': visible_clients(db, user)}

    @router.post('/properties')
    def create_property(body: PropertyBody, user: User):
        catalog_creator(user)
        with write(user) as db:
            client_id = body.client_id or uuid5(NAMESPACE_URL, 'agrogestor:organization-client:' + user['farmId'])
            if body.client_id is None:
                db.execute('INSERT OR IGNORE INTO v2_clients VALUES(?,?,?,?)', (user['farmId'], str(client_id), 'Organização', api.utc_now()))
            else:
                get(db, 'v2_clients', user['farmId'], client_id)
            if user['role'] != 'admin':
                if body.share_with_operators:
                    raise HTTPException(403, 'Somente o gerente compartilha propriedades com outros operadores.')
                if body.client_id is not None and not any(c['id'] == str(body.client_id) for c in visible_clients(db, user)):
                    raise HTTPException(404, 'Responsável não disponível para esta conta.')
                if db.execute('SELECT 1 FROM v2_properties WHERE tenant_id=? AND id=?', (user['farmId'], str(body.id))).fetchone():
                    access(db, user, body.id, 'operate')
            if not replay(db, user, 'property', body):
                commercial.write_access(db,user['farmId'],'properties')
                commercial.ensure_slot(db,user['farmId'],'properties',commercial.identity_increase(db,user['farmId'],'properties',body.id))
                db.execute('INSERT INTO v2_properties (tenant_id,id,client_id,name,area_ha,created_at,location,notes,shared_operators) VALUES(?,?,?,?,?,?,?,?,?)',
                           (user['farmId'], str(body.id), str(client_id), body.name, decimal_text(body.area_ha), api.utc_now(), body.location, body.notes, int(body.share_with_operators)))
                if user['role'] == 'operator':
                    db.execute('INSERT INTO v2_access VALUES(?,?,?,?)', (user['farmId'], user['id'], str(body.id), 'employee'))
                    audit(db, user, 'grant-created', 'access', user['id'], {'role': 'employee', 'reason': 'property-creator'}, body.id)
                if body.share_with_operators:
                    for operator in db.execute("""SELECT u.user_id FROM users u WHERE u.farm_id=? AND u.role='operator' AND u.disabled=0
                      AND NOT EXISTS (SELECT 1 FROM v2_driver_accounts d WHERE d.tenant_id=u.farm_id AND d.user_id=u.user_id)
                      AND NOT EXISTS (SELECT 1 FROM v2_access a WHERE a.tenant_id=u.farm_id AND a.user_id=u.user_id AND a.role!='employee')""", (user['farmId'],)).fetchall():
                        db.execute('INSERT INTO v2_access VALUES(?,?,?,?)', (user['farmId'], operator['user_id'], str(body.id), 'employee'))
                        audit(db, user, 'grant-shared', 'access', operator['user_id'],
                              {'role':'employee', 'reason':'shared-by-manager'}, body.id)
                set_responsible(db, user, body.id, body.responsible_user_id)
                if len({str(p.id) for p in body.plots}) != len(body.plots):
                    raise HTTPException(422, 'Não repita o identificador do talhão.')
                for plot in body.plots:
                    db.execute('INSERT INTO v2_plots (tenant_id,id,property_id,name,area_ha,created_at,notes) VALUES(?,?,?,?,?,?,?)',
                        (user['farmId'], str(plot.id), str(body.id), plot.name, decimal_text(plot.area_ha), api.utc_now(), plot.notes))
                    record_revision(db, api, user, 'plot', get(db, 'v2_plots', user['farmId'], plot.id), 'create-with-property')
                    audit(db, user, 'create', 'plot', plot.id, plot, body.id)
                validate_area(db, user['farmId'], body.id, body.area_ha, property_edit=True)
                record_revision(db, api, user, 'property', get(db, 'v2_properties', user['farmId'], body.id), 'create')
                remember(db, user, 'property', body)
                audit(db, user, 'create', 'property', body.id, body, body.id)
            return dict(get(db, 'v2_properties', user['farmId'], body.id))

    @router.get('/properties')
    def list_properties(user: User, include_archived: bool = False):
        with api.connect() as db:
            if user['role'] == 'admin':
                rows = db.execute('SELECT * FROM v2_properties WHERE tenant_id=? AND (? OR archived=0) ORDER BY name', (user['farmId'], include_archived))
            else:
                rows = db.execute('''SELECT p.* FROM v2_properties p JOIN v2_access a
                  ON a.tenant_id=p.tenant_id AND a.property_id=p.id
                  WHERE p.tenant_id=? AND a.user_id=? AND (? OR p.archived=0) ORDER BY p.name''', (user['farmId'], user['id'], include_archived))
            return {'items': [property_record(db, user['farmId'], row) for row in rows]}

    @router.get('/catalog/responsibles')
    def responsibles(user: User):
        catalog_creator(user)
        with api.connect() as db:
            return {'items': [dict(r) for r in db.execute('SELECT user_id AS id,display_name AS name,role FROM users WHERE farm_id=? AND disabled=0 ORDER BY display_name', (user['farmId'],))]}

    @router.post('/plots')
    def create_plot(body: PlotBody, user: User):
        catalog_creator(user)
        with write(user) as db:
            access(db, user, body.property_id, 'operate')
            prop = get(db, 'v2_properties', user['farmId'], body.property_id)
            if body.area_ha is not None and prop['area_ha'] is not None and body.area_ha > Decimal(prop['area_ha']):
                raise HTTPException(422, 'A área do talhão excede a área conhecida da propriedade.')
            if not replay(db, user, 'plot', body):
                ensure_active(prop)
                if body.area_ha is not None and prop['area_ha'] is not None:
                    existing = db.execute('SELECT area_ha FROM v2_plots WHERE tenant_id=? AND property_id=? AND archived=0', (user['farmId'], str(body.property_id))).fetchall()
                    known_area = sum((Decimal(row['area_ha']) for row in existing if row['area_ha'] is not None), Decimal(0))
                    if known_area + body.area_ha > Decimal(prop['area_ha']):
                        raise HTTPException(422, 'A soma das áreas conhecidas dos talhões excede a propriedade.')
                db.execute('INSERT INTO v2_plots (tenant_id,id,property_id,name,area_ha,created_at,notes) VALUES(?,?,?,?,?,?,?)',
                           (user['farmId'], str(body.id), str(body.property_id), body.name, decimal_text(body.area_ha), api.utc_now(), body.notes))
                record_revision(db, api, user, 'plot', get(db, 'v2_plots', user['farmId'], body.id), 'create')
                remember(db, user, 'plot', body)
                audit(db, user, 'create', 'plot', body.id, body, body.property_id)
            return dict(get(db, 'v2_plots', user['farmId'], body.id))

    @router.get('/properties/{property_id}/plots')
    def list_plots(property_id: UUID, user: User, include_archived: bool = False):
        with api.connect() as db:
            access(db, user, property_id)
            return {'items': [dict(row) for row in db.execute('SELECT * FROM v2_plots WHERE tenant_id=? AND property_id=? AND (? OR archived=0)', (user['farmId'], str(property_id), include_archived))]}

    @router.post('/crops')
    def create_crop(body: CropBody, user: User):
        admin(user)
        with write(user) as db:
            if not replay(db, user, 'crop', body):
                insert_named(db, user, 'v2_crops', body, ['id', 'name', 'kind'])
                remember(db, user, 'crop', body)
                audit(db, user, 'create', 'crop', body.id, body)
            return dict(get(db, 'v2_crops', user['farmId'], body.id))

    @router.post('/cycles')
    def create_cycle(body: CycleBody, user: User):
        admin(user)
        with write(user) as db:
            plot = get(db, 'v2_plots', user['farmId'], body.plot_id)
            get(db, 'v2_crops', user['farmId'], body.crop_id)
            if body.area_ha is not None and plot['area_ha'] is not None and body.area_ha > Decimal(plot['area_ha']):
                raise HTTPException(422, 'Área cultivada maior que a área conhecida do talhão.')
            if not replay(db, user, 'cycle', body):
                ensure_active(get(db, 'v2_properties', user['farmId'], plot['property_id']), plot)
                insert_named(db, user, 'v2_cycles', body, ['id', 'plot_id', 'crop_id', 'name', 'area_ha', 'starts_on', 'ends_on'])
                remember(db, user, 'cycle', body)
                audit(db, user, 'create', 'cycle', body.id, body, plot['property_id'])
            return dict(get(db, 'v2_cycles', user['farmId'], body.id))

    @router.get('/properties/{property_id}/cycles')
    def list_cycles(property_id: UUID, user: User):
        with api.connect() as db:
            access(db, user, property_id)
            rows = db.execute('''SELECT c.*,crop.name AS crop_name FROM v2_cycles c JOIN v2_plots p
              ON p.tenant_id=c.tenant_id AND p.id=c.plot_id JOIN v2_crops crop
              ON crop.tenant_id=c.tenant_id AND crop.id=c.crop_id WHERE c.tenant_id=? AND p.property_id=?''',
              (user['farmId'], str(property_id)))
            return {'items': [dict(row) for row in rows]}

    @router.put('/properties/{property_id}/access')
    def grant(property_id: UUID, body: GrantBody, user: User):
        admin(user)
        with write(user) as db:
            access(db, user, property_id)
            target = db.execute('SELECT 1 FROM users WHERE farm_id=? AND user_id=? AND disabled=0', (user['farmId'], body.user_id)).fetchone()
            if target is None:
                raise HTTPException(404, 'Conta ativa não encontrada nesta organização.')
            if body.role is not None and is_driver_account(db, user['farmId'], body.user_id):
                raise HTTPException(422, 'Caminhoneiros recebem acesso por atribuição de viagem, sem permissão geral nas propriedades.')
            before = db.execute('SELECT role FROM v2_access WHERE tenant_id=? AND user_id=? AND property_id=?', (user['farmId'], body.user_id, str(property_id))).fetchone()
            if body.role is None:
                db.execute('DELETE FROM v2_access WHERE tenant_id=? AND user_id=? AND property_id=?', (user['farmId'], body.user_id, str(property_id)))
            else:
                db.execute('''INSERT INTO v2_access VALUES(?,?,?,?) ON CONFLICT(tenant_id,user_id,property_id)
                  DO UPDATE SET role=excluded.role''', (user['farmId'], body.user_id, str(property_id), body.role))
            audit(db, user, 'set_access', 'access', body.user_id, body, property_id, dict(before) if before else None)
            return {'user_id': body.user_id, 'role': body.role}

    @router.post('/machines')
    def create_machine(body: MachineBody, user: User):
        catalog_creator(user)
        if user['role'] != 'admin' and body.hourly_cost_cents is not None:
            raise HTTPException(403, 'Somente o gerente define a tarifa da máquina.')
        with write(user) as db:
            for identity in body.property_ids:
                access(db, user, identity, 'operate')
                ensure_active(get(db, 'v2_properties', user['farmId'], identity))
            if not replay(db, user, 'machine', body):
                commercial.write_access(db,user['farmId'],'fleet')
                commercial.ensure_slot(db,user['farmId'],'machines',commercial.identity_increase(db,user['farmId'],'machines',body.id))
                insert_named(db, user, 'v2_machines', body, ['id', 'name', 'hour_meter', 'hourly_cost_cents'])
                for identity in set(body.property_ids):
                    db.execute('INSERT INTO v2_machine_properties VALUES(?,?,?)', (user['farmId'], str(body.id), str(identity)))
                remember(db, user, 'machine', body)
                audit(db, user, 'create', 'machine', body.id, body)
            result = dict(get(db, 'v2_machines', user['farmId'], body.id))
            if user['role'] != 'admin':
                result.pop('hourly_cost_cents', None)
            return result

    @router.get('/properties/{property_id}/machines')
    def list_machines(property_id: UUID, user: User):
        with api.connect() as db:
            role = access(db, user, property_id)
            rows = db.execute('''SELECT m.* FROM v2_machines m JOIN v2_machine_properties a
              ON a.tenant_id=m.tenant_id AND a.machine_id=m.id WHERE m.tenant_id=? AND a.property_id=?''', (user['farmId'], str(property_id)))
            items = [dict(row) for row in rows]
            for item in items:
                if user['role'] != 'admin':
                    item.pop('hourly_cost_cents', None)
                if user['role'] == 'admin':
                    item['property_ids'] = [r[0] for r in db.execute('SELECT property_id FROM v2_machine_properties WHERE tenant_id=? AND machine_id=? ORDER BY property_id', (user['farmId'], item['id']))]
            return {'items': items}

    @router.patch('/machines/{machine_id}')
    def update_machine(machine_id: UUID, body: MachineUpdateBody, user: User):
        admin(user)
        with write(user) as db:
            tenant = user['farmId']
            current = get(db, 'v2_machines', tenant, machine_id)
            if replay(db, user, 'machine-update:' + str(machine_id), body):
                return dict(current)
            properties = {r[0] for r in db.execute('SELECT property_id FROM v2_machine_properties WHERE tenant_id=? AND machine_id=?', (tenant, str(machine_id)))}
            if (current['name'] != body.expected_name or Decimal(current['hour_meter']) != body.expected_hour_meter
                or current['hourly_cost_cents'] != body.expected_hourly_cost_cents
                or properties != {str(p) for p in body.expected_property_ids}):
                raise HTTPException(409, 'A máquina mudou desde a consulta. Atualize antes de editar.')
            for property_id in body.property_ids:
                get(db, 'v2_properties', tenant, property_id)
            db.execute('UPDATE v2_machines SET name=?,hourly_cost_cents=? WHERE tenant_id=? AND id=?',
                       (body.name, body.hourly_cost_cents, tenant, str(machine_id)))
            db.execute('DELETE FROM v2_machine_properties WHERE tenant_id=? AND machine_id=?', (tenant, str(machine_id)))
            for property_id in set(body.property_ids):
                db.execute('INSERT INTO v2_machine_properties VALUES(?,?,?)', (tenant, str(machine_id), str(property_id)))
            remember(db, user, 'machine-update:' + str(machine_id), body)
            for property_id in properties | {str(p) for p in body.property_ids}:
                audit(db, user, 'update', 'machine', machine_id, body, property_id, dict(current))
            return dict(get(db, 'v2_machines', tenant, machine_id))

    @router.post('/inputs')
    def create_input(body: InputBody, user: User):
        admin(user)
        with write(user) as db:
            if not replay(db, user, 'input', body):
                insert_named(db, user, 'v2_inputs', body, ['id', 'name', 'unit', 'category', 'product_type', 'notes'])
                remember(db, user, 'input', body)
                audit(db, user, 'create', 'input', body.id, body)
            return dict(get(db, 'v2_inputs', user['farmId'], body.id))

    @router.patch('/inputs/{input_id}')
    def update_input(input_id: UUID, body: InputUpdateBody, user: User):
        admin(user)
        with write(user) as db:
            current = get(db, 'v2_inputs', user['farmId'], input_id)
            if replay(db, user, 'input-update:' + str(input_id), body):
                return dict(current)
            if (current['name'], current['category'], current['product_type']) != (
                    body.expected_name, body.expected_category, body.expected_product_type):
                raise HTTPException(409, 'O produto mudou desde a consulta. Atualize antes de editar.')
            db.execute('UPDATE v2_inputs SET name=?,category=?,product_type=? WHERE tenant_id=? AND id=?',
                       (body.name, body.category, body.product_type, user['farmId'], str(input_id)))
            remember(db, user, 'input-update:' + str(input_id), body)
            audit(db, user, 'update', 'input', input_id, body, before=dict(current))
            return dict(get(db, 'v2_inputs', user['farmId'], input_id))

    def stock_rows(db, tenant, property_id, input_id):
        return db.execute('SELECT * FROM v2_inventory WHERE tenant_id=? AND property_id=? AND input_id=? ORDER BY seq',
                          (tenant, str(property_id), str(input_id))).fetchall()

    @router.post('/properties/{property_id}/inventory')
    def receive(property_id: UUID, body: ReceiptBody, user: User):
        with write(user) as db:
            access(db, user, property_id, 'stock')
            get(db, 'v2_inputs', user['farmId'], body.input_id)
            if replay(db, user, 'inventory', body):
                prior = get_inventory(db, user, body.id)
                if prior['property_id'] != str(property_id):
                    raise HTTPException(409, 'Este movimento pertence a outra propriedade.')
                return prior
            ensure_active(get(db, 'v2_properties', user['farmId'], property_id))
            rows = stock_rows(db, user['farmId'], property_id, body.input_id)
            if body.kind == 'opening' and rows:
                raise HTTPException(409, 'Inventário inicial já registrado. Uma correção exige ajuste auditado.')
            if body.kind == 'receipt' and not rows:
                raise HTTPException(409, 'Registre primeiro o inventário inicial conferido.')
            if rows and body.occurred_on.isoformat() < rows[-1]['occurred_on']:
                raise HTTPException(409, 'Entrada retroativa exige reconciliação do estoque; não altere o custo histórico.')
            db.execute('''INSERT INTO v2_inventory
              (tenant_id,id,property_id,input_id,operation_id,kind,quantity,value_cents,actor_id,occurred_on,created_at,request_json)
              VALUES(?,?,?,?,NULL,?,?,?,?,?,?,?)''', (user['farmId'], str(body.id), str(property_id), str(body.input_id),
                body.kind, decimal_text(body.quantity), body.value_cents, user['id'], body.occurred_on.isoformat(), api.utc_now(), json_text(body)))
            remember(db, user, 'inventory', body)
            audit(db, user, 'create', 'inventory', body.id, body, property_id)
            return get_inventory(db, user, body.id)

    def get_inventory(db, user, identity):
        row = db.execute('SELECT * FROM v2_inventory WHERE tenant_id=? AND id=?', (user['farmId'], str(identity))).fetchone()
        if row is None:
            raise HTTPException(404, 'Movimento não encontrado.')
        return dict(row)

    @router.get('/properties/{property_id}/inventory/{input_id}')
    def inventory(property_id: UUID, input_id: UUID, user: User):
        with api.connect() as db:
            role = access(db, user, property_id)
            item = get(db, 'v2_inputs', user['farmId'], input_id)
            rows = stock_rows(db, user['farmId'], property_id, input_id)
            balance = stock_balance(rows)
            result = {'input_id': str(input_id), 'unit': item['unit'], 'initialized': balance['known'],
                      'quantity': decimal_text(balance['quantity'])}
            if user['role'] == 'admin':
                result.update(value_cents=balance['value_cents'], movement_ids=[row['id'] for row in rows])
            return result

    def operation_detail(db, user, identity, *, authorized_report=False, authorized_task=False):
        operation = dict(get(db, 'v2_operations', user['farmId'], identity))
        _, _, prop, _ = cycle_context(db, user['farmId'], operation['cycle_id'])
        role = access(db, user, prop['id'])
        if user['role'] != 'admin' and operation['actor_id'] != user['id'] and not (authorized_report or authorized_task):
            raise HTTPException(404, 'Operação não encontrada.')
        operation.pop('request_json')
        output = db.execute('SELECT quantity,unit,kg_per_unit FROM v2_harvest_outputs WHERE tenant_id=? AND operation_id=?', (user['farmId'],str(identity))).fetchone()
        operation['harvest_output'] = dict(output) if output else None
        operation['implements'] = implement_usage.read(db,user['farmId'],identity)
        context = db.execute('SELECT snapshot_json FROM v2_operation_context WHERE tenant_id=? AND operation_id=?',
                             (user['farmId'], str(identity))).fetchone()
        operation['context'] = json.loads(context[0]) if context else None
        operation['context_status'] = 'recorded_at_operation' if context else 'not_recorded_before_upgrade'
        void = db.execute('SELECT reason,actor_id,created_at FROM v2_voids WHERE tenant_id=? AND operation_id=?',
                          (user['farmId'], str(identity))).fetchone()
        operation['void'] = dict(void) if void else None
        measurements = db.execute('SELECT started_at,ended_at,consumed_fuel_liters,labor_cost_cents FROM v2_operation_measurements WHERE tenant_id=? AND operation_id=?', (user['farmId'],str(identity))).fetchone()
        operation['measurements'] = dict(measurements) if measurements else {'started_at':None,'ended_at':None,'consumed_fuel_liters':None}
        operation['machines'] = [dict(row) for row in db.execute(
            'SELECT * FROM v2_machine_usage WHERE tenant_id=? AND operation_id=?', (user['farmId'], str(identity)))]
        operation['inputs'] = [dict(row) for row in db.execute(
            "SELECT * FROM v2_inventory WHERE tenant_id=? AND operation_id=? AND kind='consume' ORDER BY seq", (user['farmId'], str(identity)))]
        for movement in operation['inputs']:
            movement.pop('request_json')
            item = get(db, 'v2_inputs', user['farmId'], movement['input_id'])
            movement['unit'] = item['unit']
            movement['name'] = item['name']
        for usage in operation['machines']:
            usage['name'] = get(db, 'v2_machines', user['farmId'], usage['machine_id'])['name']
        operation['refuelings'] = read_refuelings(db, user, identity, role if user['role']=='admin' else 'employee')
        if user['role'] != 'admin':
            operation['measurements'].pop('labor_cost_cents',None)
            for item in operation['machines']:
                item.pop('hourly_cost_cents')
                item.pop('cost_cents')
            for item in operation['inputs']:
                item.pop('value_cents')
        return operation

    @router.post('/operations')
    def post_operation(body: OperationBody, user: User):
        with write(user) as db:
            tenant = user['farmId']
            cycle, plot, prop, crop = cycle_context(db, tenant, body.cycle_id)
            access(db, user, prop['id'], 'operate')
            if replay(db, user, 'operation', body):
                return operation_detail(db, user, body.id)
            ensure_active(prop, plot)
            if body.refuelings or any(is_fuel(get(db,'v2_inputs',tenant,line.input_id)) for line in body.inputs):
                commercial.write_access(db,tenant,'fuel')
            check_task_operation(db,user,body,prop['id'])
            if body.task_id is None and body.plan_id is None:
                commercial.write_access(db,tenant,'operations')
            if body.labor_cost_cents is not None:
                admin(user)
            plan_operation(db,user,body,api)
            day = body.performed_on.isoformat()
            if day < cycle['starts_on'] or (cycle['ends_on'] and day > cycle['ends_on']):
                raise HTTPException(422, 'A operação deve ocorrer dentro do ciclo informado.')
            if body.area_ha is not None and cycle['area_ha'] is not None and body.area_ha > Decimal(cycle['area_ha']):
                raise HTTPException(422, 'Área trabalhada maior que a área do ciclo.')
            if body.area_ha is not None and plot['area_ha'] is not None and body.area_ha > Decimal(plot['area_ha']):
                raise HTTPException(422, 'Área trabalhada maior que a área atual do talhão.')
            db.execute('''INSERT INTO v2_operations VALUES(?,?,?,?,?,?,?,?,?,?,?)''',
                       (tenant, str(body.id), str(body.cycle_id), body.kind, day, decimal_text(body.area_ha),
                        body.notes, decimal_text(body.labor_hours), user['id'], api.utc_now(), json_text(body)))
            db.execute('INSERT INTO v2_operation_context VALUES(?,?,?)', (tenant, str(body.id),
                json_text({'property': dict(prop), 'plot': dict(plot), 'cycle': dict(cycle), 'crop': dict(crop)})))
            for use in body.machines:
                machine = get(db, 'v2_machines', tenant, use.machine_id)
                if machine['archived']:
                    raise HTTPException(409,'Máquina arquivada. Solicite a reativação ao gestor.')
                if machine_blocked(db,tenant,use.machine_id):
                    raise HTTPException(409,'Máquina parada para manutenção. Aguarde a liberação da oficina.')
                assigned = db.execute('SELECT 1 FROM v2_machine_properties WHERE tenant_id=? AND machine_id=? AND property_id=?',
                                      (tenant, str(use.machine_id), prop['id'])).fetchone()
                if not assigned:
                    raise HTTPException(404, 'Máquina não vinculada a esta propriedade.')
                latest = db.execute('''SELECT MAX(o.performed_on) FROM v2_machine_usage u JOIN v2_operations o
                  ON o.tenant_id=u.tenant_id AND o.id=u.operation_id WHERE u.tenant_id=? AND u.machine_id=?''',
                                    (tenant, str(use.machine_id))).fetchone()[0]
                if latest and day < latest:
                    raise HTTPException(409, 'Uso retroativo de máquina exige reconciliação do horímetro.')
                gap = use.start_meter - Decimal(machine['hour_meter'])
                if gap < 0:
                    raise HTTPException(409, 'Horímetro inicial anterior ao último horímetro registrado.')
                hours = use.end_meter - use.start_meter
                cost = None if machine['hourly_cost_cents'] is None else money_round(hours * machine['hourly_cost_cents'])
                db.execute('INSERT INTO v2_machine_usage VALUES(?,?,?,?,?,?,?,?,?)',
                           (tenant, str(body.id), str(use.machine_id), decimal_text(use.start_meter), decimal_text(use.end_meter),
                            decimal_text(hours), decimal_text(gap), machine['hourly_cost_cents'], cost))
                db.execute('UPDATE v2_machines SET hour_meter=? WHERE tenant_id=? AND id=?',
                           (decimal_text(use.end_meter), tenant, str(use.machine_id)))
            validate_refuelings(db, tenant, prop['id'], body, get, machine_blocked)
            # Aggregate repeated input lines before valuation, avoiding rounding per line.
            quantities = {}
            for use in body.inputs:
                key = str(use.input_id)
                quantities[key] = quantities.get(key, Decimal(0)) + use.quantity
            for fueling in body.refuelings:
                if fueling.source == 'stock':
                    key = str(fueling.input_id)
                    quantities[key] = quantities.get(key, Decimal(0)) + fueling.liters
            for input_id, quantity in quantities.items():
                get(db, 'v2_inputs', tenant, input_id)
                rows = stock_rows(db, tenant, prop['id'], input_id)
                if rows and day < rows[-1]['occurred_on']:
                    raise HTTPException(409, 'Consumo retroativo exige reconciliação do estoque.')
                try:
                    ensure_available(db,tenant,prop['id'],input_id,stock_balance(rows),quantity)
                    value = consumption_value(stock_balance(rows), quantity)
                except ValueError as error:
                    raise HTTPException(409, str(error)) from error
                movement_id = str(uuid5(body.id, input_id))
                db.execute('''INSERT INTO v2_inventory
                  (tenant_id,id,property_id,input_id,operation_id,kind,quantity,value_cents,actor_id,occurred_on,created_at,request_json)
                  VALUES(?,?,?,?,?,'consume',?,?,?,?,?,?)''',
                           (tenant, movement_id, prop['id'], input_id, str(body.id), decimal_text(quantity), value,
                            user['id'], day, api.utc_now(), json_text(body)))
            store_refuelings(db, user, body, api)
            db.execute('INSERT INTO v2_operation_measurements VALUES(?,?,?,?,?,?)', (tenant,str(body.id),
                body.started_at.isoformat() if body.started_at else None, body.ended_at.isoformat() if body.ended_at else None,
                decimal_text(body.consumed_fuel_liters),body.labor_cost_cents))
            plan_operation(db,user,body,api,persist=True)
            harvest.persist(db,tenant,body.id,body.harvest_output)
            implement_usage.persist(db,user,body)
            remember(db, user, 'operation', body)
            audit(db, user, 'post', 'operation', body.id, body, prop['id'])
            finish_task_operation(db,user,body,api,audit)
            return operation_detail(db, user, body.id)

    @router.get('/operations/{operation_id}')
    def read_operation(operation_id: UUID, user: User):
        with api.connect() as db:
            return operation_detail(db, user, operation_id)

    @router.post('/properties/{property_id}/inventory-corrections')
    def correct_stock(property_id: UUID, body: StockCorrectionBody, user: User):
        with write(user) as db:
            access(db, user, property_id, 'stock')
            tenant = user['farmId']
            get(db, 'v2_inputs', tenant, body.input_id)
            if replay(db, user, 'correction', body):
                previous = get_inventory(db, user, body.id)
                if previous['property_id'] != str(property_id):
                    raise HTTPException(409, 'Ajuste pertence a outra propriedade.')
                return previous
            rows = stock_rows(db, tenant, property_id, body.input_id)
            if not rows or rows[-1]['id'] != str(body.expected_movement_id):
                raise HTTPException(409, 'O estoque mudou. Atualize e confira o saldo novamente.')
            if body.occurred_on.isoformat() < rows[-1]['occurred_on']:
                raise HTTPException(409, 'Ajuste retroativo exige reconciliação.')
            balance = stock_balance(rows)
            if body.quantity<reserved(db,tenant,property_id,body.input_id):
                raise HTTPException(409,'A correção reduziria o estoque abaixo das reservas. Confira as ordens de manutenção.')
            for key, kind, quantity, value in [
                (str(uuid5(body.id, 'reverse')), 'consume', balance['quantity'], balance['value_cents']),
                (str(body.id), 'receipt', body.quantity, body.value_cents)]:
                db.execute('''INSERT INTO v2_inventory
                  (tenant_id,id,property_id,input_id,kind,quantity,value_cents,actor_id,occurred_on,created_at,request_json)
                  VALUES(?,?,?,?,?,?,?,?,?,?,?)''', (tenant, key, str(property_id), str(body.input_id), kind,
                    decimal_text(quantity), value, user['id'], body.occurred_on.isoformat(), api.utc_now(), json_text(body)))
            remember(db, user, 'correction', body)
            audit(db, user, 'correct_stock', 'inventory', body.id, body, property_id,
                  {'quantity': decimal_text(balance['quantity']), 'value_cents': balance['value_cents']})
            return get_inventory(db, user, body.id)

    @router.post('/operations/{operation_id}/void')
    def void_operation(operation_id: UUID, body: VoidBody, user: User):
        with write(user) as db:
            tenant = user['farmId']
            operation = get(db, 'v2_operations', tenant, operation_id)
            _, _, prop, _ = cycle_context(db, tenant, operation['cycle_id'])
            access(db, user, prop['id'], 'stock')
            previous = db.execute('SELECT * FROM v2_voids WHERE tenant_id=? AND operation_id=?', (tenant, str(operation_id))).fetchone()
            if previous:
                if previous['request_json'] != json_text(body):
                    raise HTTPException(409, 'Operação já estornada com outro pedido.')
                return operation_detail(db, user, operation_id)
            day = body.occurred_on.isoformat()
            if day < operation['performed_on']:
                raise HTTPException(422, 'Estorno não pode ser anterior à operação.')
            undo_plan_operation(db,tenant,operation_id)
            uses = db.execute('SELECT * FROM v2_machine_usage WHERE tenant_id=? AND operation_id=?', (tenant, str(operation_id))).fetchall()
            for use in uses:
                latest = db.execute('''SELECT u.operation_id FROM v2_machine_usage u
                  WHERE u.tenant_id=? AND u.machine_id=? AND NOT EXISTS
                  (SELECT 1 FROM v2_voids v WHERE v.tenant_id=u.tenant_id AND v.operation_id=u.operation_id)
                  ORDER BY u.rowid DESC LIMIT 1''', (tenant, use['machine_id'])).fetchone()
                if latest['operation_id'] != str(operation_id):
                    raise HTTPException(409, 'Há operações posteriores desta máquina. Reconcilie antes de estornar.')
            movements = db.execute("SELECT * FROM v2_inventory WHERE tenant_id=? AND operation_id=? AND kind='consume' ORDER BY seq", (tenant, str(operation_id))).fetchall()
            for movement in movements:
                rows = stock_rows(db, tenant, prop['id'], movement['input_id'])
                if rows[-1]['id'] != movement['id'] or day < rows[-1]['occurred_on']:
                    raise HTTPException(409, 'Há movimentos posteriores do insumo. Reconcilie antes de estornar.')
            for use in uses:
                previous_meter = Decimal(use['start_meter']) - Decimal(use['meter_gap_hours'])
                db.execute('UPDATE v2_machines SET hour_meter=? WHERE tenant_id=? AND id=?',
                           (decimal_text(previous_meter), tenant, use['machine_id']))
            for movement in movements:
                db.execute('''INSERT INTO v2_inventory
                  (tenant_id,id,property_id,input_id,operation_id,kind,quantity,value_cents,actor_id,occurred_on,created_at,request_json)
                  VALUES(?,?,?,?,?,'receipt',?,?,?,?,?,?)''', (tenant, str(uuid5(body.id, movement['input_id'])), prop['id'],
                    movement['input_id'], str(operation_id), movement['quantity'], movement['value_cents'],
                    user['id'], day, api.utc_now(), json_text(body)))
            db.execute('INSERT INTO v2_voids VALUES(?,?,?,?,?,?,?)',
                       (tenant, str(operation_id), str(body.id), body.reason, user['id'], api.utc_now(), json_text(body)))
            audit(db, user, 'void', 'operation', operation_id, body, prop['id'])
            return operation_detail(db, user, operation_id)

    @router.get('/cycles/{cycle_id}/report')
    def report(cycle_id: UUID, user: User, starts_on: date | None = None, ends_on: date | None = None):
        admin(user)
        if starts_on and ends_on and starts_on > ends_on:
            raise HTTPException(422, 'Período inválido.')
        with api.connect() as db:
            cycle, plot, prop, crop = cycle_context(db, user['farmId'], cycle_id)
            access(db, user, prop['id'], 'finance')
            rows = db.execute('''SELECT id FROM v2_operations o WHERE tenant_id=? AND cycle_id=?
              AND NOT EXISTS (SELECT 1 FROM v2_voids v WHERE v.tenant_id=o.tenant_id AND v.operation_id=o.id)
              AND (? IS NULL OR performed_on>=?) AND (? IS NULL OR performed_on<=?) ORDER BY performed_on,id''',
                              (user['farmId'], str(cycle_id), str(starts_on) if starts_on else None,
                               str(starts_on) if starts_on else None, str(ends_on) if ends_on else None,
                               str(ends_on) if ends_on else None)).fetchall()
            # The report endpoint has already verified the explicit finance grant.
            # This does not broaden the operator's normal history/detail endpoints.
            operations = [operation_detail(db, user, row['id'], authorized_report=True) for row in rows]
            machine_values, input_values, fuel_values = [], [], []
            by_machine, by_input = {}, {}
            for operation in operations:
                for item in operation['machines']:
                    machine_values.append(item['cost_cents'])
                    by_machine.setdefault(item['machine_id'], []).append(item)
                for item in operation['inputs']:
                    if is_fuel(get(db,'v2_inputs',user['farmId'],item['input_id'])):
                        fuel_values.append(item['value_cents'])
                    else:
                        input_values.append(item['value_cents'])
                    by_input.setdefault(item['input_id'], []).append(item)
            # Include the known part of an incompletely priced operation in the
            # subtotal while keeping the total unavailable until all lines are priced.
            external_values = [r['total_cost_cents'] for o in operations for r in o['refuelings'] if r['source'] == 'external']
            labor_values = [o['measurements'].get('labor_cost_cents') for o in operations if o['labor_hours'] is not None or o['measurements'].get('labor_cost_cents') is not None]
            total = metric(machine_values + input_values + fuel_values + external_values + labor_values + [None for o in operations if not o['machines'] and not o['inputs'] and not o['refuelings'] and o['labor_hours'] is None and o['measurements'].get('labor_cost_cents') is None], 'BRL_cent')
            return {'generated_at': api.utc_now(), 'property': dict(prop), 'plot': dict(plot), 'crop': dict(crop),
                    'cycle': dict(cycle), 'filters': {'starts_on': str(starts_on) if starts_on else None,
                                                   'ends_on': str(ends_on) if ends_on else None},
                    'scope': 'Custos registrados de máquinas (sem combustível, manutenção e mão de obra na tarifa), insumos, combustível e mão de obra informada. Abastecimentos do estoque já estão representados nas baixas; compras em posto são adicionadas uma única vez. Litros abastecidos não medem consumo real no serviço. Não representa custo total da cultura.',
                    'metrics': {'registered_cost': total, 'machine_cost': metric(machine_values, 'BRL_cent'),
                                'input_cost': metric(input_values, 'BRL_cent'),
                                'fuel_cost': metric(fuel_values + external_values, 'BRL_cent'),
                                'labor_cost': metric(labor_values, 'BRL_cent'),
                                'external_refueling_cost': metric(external_values, 'BRL_cent'),
                                'refueled_liters': metric([r['liters'] for o in operations for r in o['refuelings']], 'L'),
                                'refueling_cost': metric([r['total_cost_cents'] for o in operations for r in o['refuelings']], 'BRL_cent'),
                                'cost_per_cycle_ha': ratio(total, cycle['area_ha'], 'BRL_cent/ha'),
                                'worked_area_passes': metric([o['area_ha'] for o in operations], 'ha_passes'),
                                'machine_hours': metric([m['hours'] for o in operations for m in o['machines']], 'h'),
                                'labor_hours': metric([o['labor_hours'] for o in operations], 'h')},
                    'machines': [{'machine_id': key, 'hours': metric([i['hours'] for i in items], 'h'),
                                  'cost': metric([i['cost_cents'] for i in items], 'BRL_cent')}
                                 for key, items in by_machine.items()],
                    'inputs': [{'input_id': key, 'unit': get(db, 'v2_inputs', user['farmId'], key)['unit'],
                                'quantity': metric([i['quantity'] for i in items], get(db, 'v2_inputs', user['farmId'], key)['unit']),
                                'cost': metric([i['value_cents'] for i in items], 'BRL_cent')}
                               for key, items in by_input.items()],
                    'operations': operations}

    @router.get('/properties/{property_id}/audit')
    def read_audit(property_id: UUID, user: User, after: int = 0, limit: int = 100):
        if after < 0 or limit < 1 or limit > 500:
            raise HTTPException(422, 'Paginação inválida.')
        with api.connect() as db:
            access(db, user, property_id, 'audit')
            rows = db.execute('''SELECT * FROM v2_audit WHERE tenant_id=? AND property_id=? AND seq>?
              ORDER BY seq LIMIT ?''', (user['farmId'], str(property_id), after, limit)).fetchall()
            return {'items': [dict(row) for row in rows]}

    install_catalog_routes(router, api, User, get=get, access=access, admin=admin,
                           write=write, replay=replay, remember=remember, audit=audit)
    install_work_routes(router,api,User,get=get,access=access,admin=admin,write=write,
      replay=replay,remember=remember,audit=audit,json_text=json_text,
      cycle_context=cycle_context,operation_detail=operation_detail)
    install_management_routes(router,api,User,admin=admin,get=get,access=access,write=write,
      replay=replay,remember=remember,audit=audit,cycle_context=cycle_context,operation_detail=operation_detail)
    geography.install(router,api,User,get=get,access=access,write=write,replay=replay,
      remember=remember,audit=audit,operation_detail=operation_detail)
    return router
