"""Manager reports and explicit unique-area programs. No historical backfill."""
import json
from datetime import date, timedelta
from decimal import Decimal
from uuid import UUID, uuid5
from fastapi import HTTPException
from pydantic import Field, model_validator
from .v2_models import Body, Name, Positive, NonNegative, InputBody, Money
from .v2_metrics import decimal_text, metric, ratio, stock_balance
from .refueling import is_fuel
from .harvest import report as harvest_report


class PlannedPlot(Body):
    cycle_id: UUID
    planned_ha: Positive
    assignee_id: str | None = Field(default=None, max_length=160)


class PlanBody(Body):
    id: UUID
    title: Name
    season_name: Name
    activity: Name
    starts_on: date | None = None
    due_on: date | None = None
    notes: str = Field(default='', max_length=2000)
    plots: list[PlannedPlot] = Field(min_length=1, max_length=100)

    @model_validator(mode='after')
    def valid(self):
        if self.starts_on and self.due_on and self.due_on < self.starts_on:
            raise ValueError('Período inválido.')
        if len({p.cycle_id for p in self.plots}) != len(self.plots):
            raise ValueError('Não repita o talhão/ciclo.')
        return self


class StockItemBody(InputBody):
    property_id: UUID
    quantity: NonNegative
    minimum_quantity: NonNegative
    value_cents: Money | None = None
    occurred_on: date

    @model_validator(mode='after')
    def valid(self):
        if self.product_type.casefold() == 'diesel' and self.unit != 'L':
            raise ValueError('Diesel deve ser registrado em litros.')
        if self.quantity == 0 and self.value_cents not in (None, 0):
            raise ValueError('Saldo zero não pode ter valor positivo.')
        return self


def plan_operation(db, user, body, api, *, persist=False):
    if body.plan_id is None:
        return
    row = db.execute('SELECT * FROM v2_plan_plots WHERE tenant_id=? AND plan_id=? AND cycle_id=?',
        (user['farmId'], str(body.plan_id), str(body.cycle_id))).fetchone()
    if row is None:
        raise HTTPException(404, 'Programação não encontrada para este ciclo.')
    if user['role'] != 'admin' and row['assignee_id'] not in (None, user['id']):
        raise HTTPException(403, 'Esta programação pertence a outro funcionário.')
    if row['version'] != body.plan_expected_version:
        raise HTTPException(409, 'O progresso mudou. Atualize a programação antes de salvar.')
    if row['activity'] != body.kind:
        raise HTTPException(422, 'A atividade da operação deve corresponder à programação.')
    if not Decimal(row['completed_ha']) <= body.coverage_total_ha <= Decimal(row['planned_ha']):
        raise HTTPException(422, 'Informe a área única acumulada entre o progresso anterior e a área programada.')
    if persist:
        db.execute('UPDATE v2_plan_plots SET completed_ha=?,version=version+1 WHERE tenant_id=? AND plan_id=? AND cycle_id=?',
            (decimal_text(body.coverage_total_ha), user['farmId'], str(body.plan_id), str(body.cycle_id)))
        db.execute('INSERT INTO v2_plan_events VALUES(?,?,?,?,?,?,?,?,?,?)',
            (user['farmId'], str(uuid5(body.id, 'coverage')), str(body.plan_id), str(body.cycle_id), str(body.id),
             row['completed_ha'], decimal_text(body.coverage_total_ha), user['id'], body.notes, api.utc_now()))


def undo_plan_operation(db, tenant, operation_id):
    event = db.execute('SELECT * FROM v2_plan_events WHERE tenant_id=? AND operation_id=?', (tenant, str(operation_id))).fetchone()
    if event is None:
        return
    latest = db.execute('''SELECT id FROM v2_plan_events e WHERE tenant_id=? AND plan_id=? AND cycle_id=?
      AND operation_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM v2_voids v WHERE v.tenant_id=e.tenant_id AND v.operation_id=e.operation_id)
      ORDER BY rowid DESC LIMIT 1''',
        (tenant, event['plan_id'], event['cycle_id'])).fetchone()
    if latest['id'] != event['id']:
        raise HTTPException(409, 'Há atualizações posteriores do progresso. Estorne primeiro os lançamentos mais recentes.')
    db.execute('UPDATE v2_plan_plots SET completed_ha=?,version=version+1 WHERE tenant_id=? AND plan_id=? AND cycle_id=?',
        (event['previous_ha'], tenant, event['plan_id'], event['cycle_id']))
    # Preserve the original event. A compensating event keeps the audit trail.
    db.execute('INSERT INTO v2_plan_events VALUES(?,?,?,?,?,?,?,?,?,?)',
        (tenant, str(uuid5(UUID(str(operation_id)), 'coverage-void')), event['plan_id'], event['cycle_id'], None,
         event['completed_ha'], event['previous_ha'], event['actor_id'], 'Estorno da operação ' + str(operation_id), event['created_at']))


def install_management_routes(router, api, User, *, admin, get, access, write, replay, remember, audit, cycle_context, operation_detail):
    @router.post('/activity-plans')
    def create_plan(body: PlanBody, user: User):
        admin(user)
        with write(user) as db:
            if not replay(db, user, 'activity-plan', body):
                db.execute('INSERT INTO v2_activity_plans VALUES(?,?,?,?,?,?,?,?,?,?)',
                    (user['farmId'], str(body.id), body.title, body.season_name, body.activity,
                     str(body.starts_on) if body.starts_on else None, str(body.due_on) if body.due_on else None,
                     body.notes, user['id'], api.utc_now()))
                for p in body.plots:
                    cycle, plot, prop, _ = cycle_context(db, user['farmId'], p.cycle_id)
                    if prop['archived'] or plot['archived']:
                        raise HTTPException(422, 'Selecione um talhão ativo.')
                    maximum = cycle['area_ha'] or plot['area_ha']
                    duplicate = db.execute('''SELECT 1 FROM v2_plan_plots pp JOIN v2_cycles c ON c.tenant_id=pp.tenant_id AND c.id=pp.cycle_id
                      WHERE pp.tenant_id=? AND c.plot_id=? AND pp.activity=? AND pp.season_name=?''',
                      (user['farmId'],plot['id'],body.activity,body.season_name)).fetchone()
                    if duplicate:
                        raise HTTPException(409, 'Este talhão já está programado para a mesma atividade e safra.')
                    if maximum is not None and p.planned_ha > Decimal(maximum):
                        raise HTTPException(422, 'Área programada maior que a área do ciclo/talhão.')
                    if p.assignee_id is not None:
                        person = db.execute("SELECT 1 FROM users WHERE farm_id=? AND user_id=? AND disabled=0 AND role='operator'", (user['farmId'], p.assignee_id)).fetchone()
                        grant = db.execute('SELECT 1 FROM v2_access WHERE tenant_id=? AND user_id=? AND property_id=?', (user['farmId'], p.assignee_id, prop['id'])).fetchone()
                        if not person or not grant:
                            raise HTTPException(422, 'Selecione um operador autorizado nesta fazenda.')
                    db.execute('INSERT INTO v2_plan_plots VALUES(?,?,?,?,?,?,?,1,?)',
                        (user['farmId'], str(body.id), str(p.cycle_id), body.activity, body.season_name, decimal_text(p.planned_ha), '0', p.assignee_id))
                remember(db, user, 'activity-plan', body)
                audit(db, user, 'create', 'activity-plan', body.id, body)
            return {'id': str(body.id)}

    def plans(db, user):
        rows = db.execute('''SELECT pp.*,p.title,p.starts_on,p.due_on,p.notes,c.name AS cycle_name,
          pl.id AS plot_id,pl.name AS plot_name,pr.id AS property_id,pr.name AS property_name
          FROM v2_plan_plots pp JOIN v2_activity_plans p ON p.tenant_id=pp.tenant_id AND p.id=pp.plan_id
          JOIN v2_cycles c ON c.tenant_id=pp.tenant_id AND c.id=pp.cycle_id
          JOIN v2_plots pl ON pl.tenant_id=c.tenant_id AND pl.id=c.plot_id
          JOIN v2_properties pr ON pr.tenant_id=pl.tenant_id AND pr.id=pl.property_id WHERE pp.tenant_id=?''', (user['farmId'],)).fetchall()
        result = []
        for row in rows:
            value = dict(row)
            if user['role'] != 'admin':
                if row['assignee_id'] not in (None, user['id']):
                    continue
                try:
                    access(db, user, row['property_id'], 'operate')
                except HTTPException:
                    continue
            value['remaining_ha'] = decimal_text(Decimal(row['planned_ha']) - Decimal(row['completed_ha']))
            value['percent'] = decimal_text(Decimal(row['completed_ha']) / Decimal(row['planned_ha']) * 100)
            value['status'] = 'completed' if Decimal(row['completed_ha']) == Decimal(row['planned_ha']) else 'in_progress' if Decimal(row['completed_ha']) else 'pending'
            result.append(value)
        return result

    @router.get('/activity-plans')
    def list_plans(user: User):
        if user['role'] not in ('admin', 'operator'):
            raise HTTPException(403, 'Sem acesso às programações agrícolas.')
        with api.connect() as db:
            return {'items': plans(db, user)}

    @router.post('/admin/stock-items')
    def create_stock_item(body: StockItemBody, user: User):
        admin(user)
        with write(user) as db:
            get(db, 'v2_properties', user['farmId'], body.property_id)
            if not replay(db, user, 'stock-item', body):
                db.execute('INSERT INTO v2_inputs(tenant_id,id,name,unit,category,product_type,notes) VALUES(?,?,?,?,?,?,?)',
                    (user['farmId'], str(body.id), body.name, body.unit, body.category, body.product_type, body.notes))
                db.execute('''INSERT INTO v2_inventory(tenant_id,id,property_id,input_id,kind,quantity,value_cents,actor_id,occurred_on,created_at,request_json)
                  VALUES(?,?,?,?,'opening',?,?,?,?,?,?)''', (user['farmId'], str(uuid5(body.id, 'opening')), str(body.property_id), str(body.id),
                    decimal_text(body.quantity), body.value_cents, user['id'], str(body.occurred_on), api.utc_now(), body.model_dump_json()))
                db.execute('INSERT INTO v2_stock_limits VALUES(?,?,?,?)', (user['farmId'], str(body.property_id), str(body.id), decimal_text(body.minimum_quantity)))
                remember(db, user, 'stock-item', body)
                audit(db, user, 'create-stock-item', 'input', body.id, body, body.property_id)
            return dict(get(db, 'v2_inputs', user['farmId'], body.id))

    @router.get('/admin/reports/options')
    def options(user: User):
        admin(user)
        with api.connect() as db:
            result = {kind: [dict(r) for r in db.execute(f'SELECT * FROM {table} WHERE tenant_id=?', (user['farmId'],))]
                for kind, table in [('properties','v2_properties'),('plots','v2_plots'),('cycles','v2_cycles'),('machines','v2_machines')]}
            result['users'] = [dict(r) for r in db.execute('SELECT user_id AS id,display_name AS name,role FROM users WHERE farm_id=? AND disabled=0', (user['farmId'],))]
            return result

    @router.get('/admin/reports/{report_type}')
    def report(report_type: str, user: User, property_id: UUID | None = None, plot_id: UUID | None = None,
               cycle_id: UUID | None = None, machine_id: UUID | None = None, operator_id: str | None = None,
               mechanic_id: str | None = None, kind: str | None = None, status: str | None = None,
               starts_on: date | None = None, ends_on: date | None = None):
        admin(user)
        if report_type not in ('overview','operations','plots','machines','maintenance','stock','season','costs','production','implements'):
            raise HTTPException(404, 'Relatório não encontrado.')
        if starts_on and ends_on and starts_on > ends_on:
            raise HTTPException(422, 'Período inválido.')
        filters = {k: str(v) if v is not None else None for k,v in locals().copy().items()
            if k in ('property_id','plot_id','cycle_id','machine_id','operator_id','mechanic_id','kind','status','starts_on','ends_on')}
        unsupported = {'stock':('plot_id','cycle_id','machine_id','operator_id','mechanic_id','kind','status'),
            'maintenance':('plot_id','cycle_id','operator_id','kind'),
            'season':('machine_id','mechanic_id')}.get(report_type,())
        if any(filters[k] is not None for k in unsupported):
            raise HTTPException(422,'Este filtro não se aplica aos vínculos deste relatório. Limpe os filtros e selecione os campos disponíveis.')
        with api.connect() as db:
            tenant = user['farmId']
            for value,table in [(property_id,'v2_properties'),(plot_id,'v2_plots'),(cycle_id,'v2_cycles'),(machine_id,'v2_machines')]:
                if value is not None: get(db,table,tenant,value)
            def rows(table):
                return [dict(r) for r in db.execute(f'SELECT * FROM {table} WHERE tenant_id=?', (tenant,))]
            properties, plots_, cycles, machines_, inputs = [rows(t) for t in ('v2_properties','v2_plots','v2_cycles','v2_machines','v2_inputs')]
            byprop, byplot, bycycle, bymachine, byinput = [{r['id']: r for r in records} for records in (properties,plots_,cycles,machines_,inputs)]
            names = {r['user_id']: r['display_name'] for r in db.execute('SELECT user_id,display_name FROM users WHERE farm_id=?', (tenant,))}
            def within(day):
                return bool(day) and (not starts_on or day[:10] >= str(starts_on)) and (not ends_on or day[:10] <= str(ends_on))
            def matches(record, *, operation=False):
                for key in ('property_id','plot_id','cycle_id','machine_id','operator_id','mechanic_id','kind','status'):
                    value = filters[key]
                    if value is None:
                        continue
                    if key == 'machine_id' and operation:
                        if not any(m['machine_id'] == value for m in record['machines']): return False
                    elif record.get(key) != value:
                        return False
                return True
            operations = []
            ledger = {}
            def charge(identity, category, amount, source):
                if identity not in ledger:
                    ledger[identity] = {'id': identity, 'category': category, 'amount_cents': amount, **source}
            voided = {r['operation_id'] for r in rows('v2_voids')}
            for row in rows('v2_operations'):
                if row['id'] in voided or not within(row['performed_on']): continue
                cycle = bycycle[row['cycle_id']]; plot = byplot[cycle['plot_id']]; prop = byprop[plot['property_id']]
                value = operation_detail(db, user, row['id'])
                value['recorded_by']=names.get(row['actor_id'])
                value['history'] = [dict(r) for r in db.execute('SELECT actor_id,action,created_at FROM v2_audit WHERE tenant_id=? AND entity_id=? ORDER BY seq',(tenant,row['id']))]
                task = db.execute('SELECT title,due_on,assignee_id,planned_area_ha,planned_hours FROM v2_tasks WHERE tenant_id=? AND operation_id=?',(tenant,row['id'])).fetchone()
                value['assigned_task'] = dict(task) if task else None
                value.update(property_id=prop['id'],property_name=prop['name'],plot_id=plot['id'],plot_name=plot['name'],
                    cycle_name=cycle['name'],operator_id=task['assignee_id'] if task else row['actor_id'],
                    operator_name=names.get(task['assignee_id'] if task else row['actor_id']),status='completed')
                if not matches(value, operation=True): continue
                operations.append(value)
                source = {'operation_id': row['id'],'property_id': prop['id'],'plot_id': plot['id'],'date': row['performed_on']}
                for use in value['machines']:
                    if machine_id and use['machine_id'] != str(machine_id): continue
                    charge('machine:'+row['id']+':'+use['machine_id'], 'Máquinas', use['cost_cents'], {**source,'machine_id':use['machine_id'],'description':use['name']})
                # Shared inputs are not attributed to one machine without an allocation.
                if not machine_id:
                    for movement in value['inputs']:
                        charge('inventory:'+movement['id'], 'Combustível' if is_fuel(byinput[movement['input_id']]) else 'Insumos', movement['value_cents'], {**source,'description':movement['name']})
                    labor_cost = value['measurements'].get('labor_cost_cents')
                    if row['labor_hours'] is not None or labor_cost is not None:
                        charge('labor:'+row['id'], 'Mão de obra', labor_cost, {**source,'description':'Mão de obra da operação'})
                for fueling in value['refuelings']:
                    if fueling['source'] == 'external' and (not machine_id or fueling['machine_id'] == str(machine_id)):
                        charge('refueling:'+fueling['id'], 'Combustível', fueling['total_cost_cents'], {**source,'machine_id':fueling['machine_id'],'description':fueling['fuel_name']})
                    elif machine_id and fueling['source']=='stock' and fueling['machine_id']==str(machine_id):
                        # This scoped view replaces the shared inventory line with
                        # its existing allocation; it never adds both representations.
                        charge('stock-allocation:'+fueling['id'],'Combustível',fueling['total_cost_cents'],{**source,'machine_id':fueling['machine_id'],'description':fueling['fuel_name']})
            orders = []
            for order in rows('v2_work_orders'):
                value = {**order,'property_name':byprop[order['property_id']]['name'], 'machine_name':bymachine[order['machine_id']]['name'], 'mechanic_name':names.get(order['mechanic_id'])}
                if not matches(value) or operator_id or kind or plot_id or cycle_id: continue
                progress = [r for r in rows('v2_work_progress') if r['order_id'] == order['id'] and within(r['created_at'])]
                if (starts_on or ends_on) and not progress and not within(order['created_at']): continue
                value['progress'] = progress
                value['parts'] = []
                value['stoppages'] = []
                stopped_at = None
                for event in db.execute("SELECT * FROM v2_audit WHERE tenant_id=? AND entity_type='work-order' AND entity_id=? ORDER BY seq",(tenant,order['id'])):
                    after=json.loads(event['after_json'])
                    if event['action']=='create':
                        if after.get('stop_machine',True): stopped_at=event['created_at']
                    elif event['action']=='progress':
                        release = True if after.get('status')=='cancelled' else after.get('machine_released')
                        if after.get('status') in ('in_progress','waiting_parts','testing'): release=False
                        if release is False and stopped_at is None: stopped_at=event['created_at']
                        if release is True and stopped_at is not None:
                            value['stoppages'].append({'started_at':stopped_at,'ended_at':event['created_at'],'source':'audit'})
                            stopped_at=None
                if stopped_at is not None:
                    value['stoppages'].append({'started_at':stopped_at,'ended_at':None,'source':'audit','status':'ongoing'})
                for p in progress:
                    source = {'order_id': order['id'], 'property_id':order['property_id'],'plot_id':None,'machine_id':order['machine_id'],'date':p['created_at'][:10]}
                    if p['labor_hours'] is not None or p['labor_cost_cents'] is not None:
                        charge('work-labor:'+p['id'], 'Mão de obra', p['labor_cost_cents'], {**source,'description':p['description']})
                    if p['service_cost_cents'] is not None:
                        charge('work-service:'+p['id'], 'Manutenção', p['service_cost_cents'], {**source,'description':p['description']})
                    for part in db.execute('''SELECT i.*,n.name,n.unit FROM v2_work_parts wp JOIN v2_inventory i ON i.tenant_id=wp.tenant_id AND i.id=wp.inventory_id
                      JOIN v2_inputs n ON n.tenant_id=i.tenant_id AND n.id=i.input_id WHERE wp.tenant_id=? AND wp.progress_id=?''', (tenant,p['id'])):
                        part = dict(part); part.pop('request_json',None); value['parts'].append(part)
                        charge('inventory:'+part['id'], 'Manutenção', part['value_cents'], {**source,'description':part['name']})
                orders.append(value)
            # Area reports show agricultural costs; workshop costs remain general-property expenses.
            if report_type == 'implements':
                operations=[o for o in operations if o['implements']]
                linked={o['id'] for o in operations}
                ledger={k:v for k,v in ledger.items() if v.get('operation_id') in linked}
            if report_type in ('operations','plots','season','production','implements'):
                ledger = {k:v for k,v in ledger.items() if v.get('operation_id') is not None}
            elif report_type == 'maintenance':
                ledger = {k:v for k,v in ledger.items() if v.get('order_id') is not None}
            categories = {category: metric([v['amount_cents'] for v in ledger.values() if v['category']==category], 'BRL_cent')
                for category in ('Máquinas','Combustível','Insumos','Manutenção','Mão de obra','Outras despesas')}
            total = metric([v['amount_cents'] for v in ledger.values()], 'BRL_cent')
            stock = []
            for prop in properties:
                if property_id and prop['id'] != str(property_id): continue
                for item in inputs:
                    movements = [dict(r) for r in db.execute('SELECT * FROM v2_inventory WHERE tenant_id=? AND property_id=? AND input_id=? ORDER BY seq', (tenant,prop['id'],item['id']))]
                    if not movements: continue
                    balance = stock_balance(movements)
                    from .work_api import reserved
                    held = reserved(db,tenant,prop['id'],item['id'])
                    available = balance['quantity']-held if balance['known'] else None
                    limit = db.execute('SELECT minimum_quantity FROM v2_stock_limits WHERE tenant_id=? AND property_id=? AND input_id=?', (tenant,prop['id'],item['id'])).fetchone()
                    stock.append({'id':prop['id']+':'+item['id'],'property_name':prop['name'],'name':item['name'],'unit':item['unit'],
                        'quantity':decimal_text(balance['quantity']), 'available_quantity':decimal_text(available), 'value_cents':balance['value_cents'], 'minimum_quantity':limit[0] if limit else None,
                        'notes':f"Saldo físico: {decimal_text(balance['quantity'])} {item['unit']}; reservado: {decimal_text(held)} {item['unit']}. O disponível desconta as reservas existentes.",
                        'low_stock':bool(limit and available is not None and available <= Decimal(limit[0])),
                        'movements':[{k:v for k,v in m.items() if k!='request_json'} for m in movements if within(m['occurred_on'])]})
            programming = [p for p in plans(db,user) if all(filters[k] is None or p.get(k)==filters[k] for k in ('property_id','plot_id','cycle_id','status'))
                           and (not operator_id or p['assignee_id']==operator_id) and (not kind or p['activity']==kind)]
            groups = {}
            for p in programming:
                key = (p['season_name'],p['activity'])
                group = groups.setdefault(key, {'season_name':key[0],'activity':key[1],'planned_ha':Decimal(0),'completed_ha':Decimal(0),'plots':[]})
                group['planned_ha'] += Decimal(p['planned_ha']); group['completed_ha'] += Decimal(p['completed_ha']); group['plots'].append(p)
            for g in groups.values():
                g['percent'] = decimal_text(g['completed_ha']/g['planned_ha']*100)
                g['remaining_ha'] = decimal_text(g['planned_ha']-g['completed_ha'])
                g['completed_plots'] = sum(p['status']=='completed' for p in g['plots'])
                g['pending_plots'] = len(g['plots'])-g['completed_plots']
                daily_coverage = {}
                for p in g['plots']:
                    for event in db.execute('''SELECT e.previous_ha,e.completed_ha,o.performed_on FROM v2_plan_events e
                      JOIN v2_operations o ON o.tenant_id=e.tenant_id AND o.id=e.operation_id
                      WHERE e.tenant_id=? AND e.plan_id=? AND e.cycle_id=? AND NOT EXISTS
                      (SELECT 1 FROM v2_voids v WHERE v.tenant_id=e.tenant_id AND v.operation_id=e.operation_id)''',(tenant,p['plan_id'],p['cycle_id'])):
                        delta = Decimal(event['completed_ha'])-Decimal(event['previous_ha'])
                        if delta>0: daily_coverage[event['performed_on']]=daily_coverage.get(event['performed_on'],Decimal(0))+delta
                days=sorted(daily_coverage)
                g['forecast'] = None
                if len(days)>=2 and Decimal(g['remaining_ha'])>0:
                    elapsed=(date.fromisoformat(days[-1])-date.fromisoformat(days[0])).days+1
                    rate=sum(daily_coverage.values(),Decimal(0))/elapsed
                    needed=int((Decimal(g['remaining_ha'])/rate).to_integral_value(rounding='ROUND_CEILING'))
                    g['forecast']={'type':'estimate','as_of':days[-1],'daily_unique_ha':decimal_text(rate),
                        'completion_date':str(date.fromisoformat(days[-1])+timedelta(days=needed)),
                        'assumption':'Estimativa pela média de área única por dia corrido entre o primeiro e o último avanço registrado. Pressupõe a continuidade desse ritmo.'}
                g['planned_ha'] = decimal_text(g['planned_ha']);g['completed_ha']=decimal_text(g['completed_ha'])
            selected_plots = [p for p in plots_ if (not property_id or p['property_id']==str(property_id)) and (not plot_id or p['id']==str(plot_id))
                and (not cycle_id or p['id']==bycycle[str(cycle_id)]['plot_id'])]
            area_values = [bycycle[str(cycle_id)]['area_ha']] if cycle_id else [p['area_ha'] for p in selected_plots]
            area_metric = metric(area_values,'ha')
            selected_farms = {p['property_id'] for p in selected_plots}
            farm_area = metric([p['area_ha'] for p in properties if not p['archived'] and (not property_id or p['id']==str(property_id))
                and (not (plot_id or cycle_id) or p['id'] in selected_farms)],'ha')
            fuel_measurements = [o.get('measurements',{}).get('consumed_fuel_liters') for o in operations]
            result = {'report_type':report_type,'generated_at':api.utc_now(),'filters':filters,
                'scope':'Custos conhecidos dos registros selecionados. Valores ausentes não são zero. Abastecimento não equivale a consumo. Manutenção sem talhão fica como despesa geral. Área de passadas não representa área única. Estoque e progresso programado são posições atuais; o período filtra os lançamentos. Custos compartilhados sem rateio não são atribuídos a uma máquina específica. Dados anteriores ao módulo integrado continuam nos relatórios anteriores. Não representa lucro ou custo integral da cultura.',
                'categories':categories,'metrics':{'registered_cost':total,'machine_hours':metric([m['hours'] for o in operations for m in o['machines'] if not machine_id or m['machine_id']==str(machine_id)],'h'),
                    'worked_area_passes':metric([o['area_ha'] for o in operations],'ha_passes'),
                    'consumed_fuel':metric(fuel_measurements,'L'),'registered_area':farm_area,'registered_plot_area':area_metric,'cost_per_cycle_ha':ratio(total,area_metric['value'],'BRL_cent/ha')},
                'ledger':list(ledger.values()),'operations':operations,'maintenance':orders,'stock':stock,'programs':list(groups.values()),
                'properties':[p for p in properties if not property_id or p['id']==str(property_id)],
                'plots':[p for p in plots_ if (not property_id or p['property_id']==str(property_id)) and (not plot_id or p['id']==str(plot_id))]}
            result['machines'] = [m for m in machines_ if (not machine_id or m['id']==str(machine_id)) and
                (not property_id or db.execute('SELECT 1 FROM v2_machine_properties WHERE tenant_id=? AND property_id=? AND machine_id=?',(tenant,str(property_id),m['id'])).fetchone())]
            for plot in result['plots']:
                charges=[line['amount_cents'] for line in ledger.values() if line.get('plot_id')==plot['id']]
                plot['registered_cost']=metric(charges,'BRL_cent')
                plot['cost_per_ha']=ratio(plot['registered_cost'],plot['area_ha'],'BRL_cent/ha')
            for prop in result['properties']:
                charges=[line['amount_cents'] for line in ledger.values() if line['property_id']==prop['id']]
                general=[line['amount_cents'] for line in ledger.values() if line['property_id']==prop['id'] and line.get('plot_id') is None]
                prop['registered_cost']=metric(charges,'BRL_cent');prop['general_expenses']=metric(general,'BRL_cent')
            if cycle_id:
                result['plots']=[p for p in result['plots'] if p['id']==bycycle[str(cycle_id)]['plot_id']]
            if plot_id or cycle_id:
                relevant={p['property_id'] for p in result['plots']}
                result['properties']=[p for p in result['properties'] if p['id'] in relevant]
            # Passes measure effort, not unique field coverage. Missing measurements stay unknown.
            daily = {}
            for o in operations:
                daily.setdefault(o['performed_on'],[]).append(o['area_ha'])
            result['productivity'] = {
                'daily_worked_passes':[{'date':day,'area':metric(values,'ha_passes')} for day,values in sorted(daily.items())],
                'by_operator':[{'operator_id':person,'operator_name':names.get(person),
                    'area':metric([o['area_ha'] for o in operations if o['operator_id']==person],'ha_passes'),
                    'machine_hours':metric([m['hours'] for o in operations if o['operator_id']==person for m in o['machines'] if not machine_id or m['machine_id']==str(machine_id)],'h')}
                    for person in sorted({o['operator_id'] for o in operations})]}
            result['productivity']['by_machine']=[]
            for machine in result['machines']:
                uses=[m for o in operations for m in o['machines'] if m['machine_id']==machine['id']]
                relevant=[o for o in operations if any(m['machine_id']==machine['id'] for m in o['machines'])]
                hours=metric([m['hours'] for m in uses],'h')
                area=metric([o['area_ha'] if len(o['machines'])==1 else None for o in relevant],'ha_passes')
                result['productivity']['by_machine'].append({'machine_name':machine['name'],'hours':hours,'worked_area':area,
                    'ha_per_hour':ratio(area,hours['value'],'ha_passes/h'),
                    'scope':'Área atribuída somente quando a operação usa uma única máquina; não há rateio automático entre máquinas.'})
            entities={r['id'] for r in result['properties']+result['plots']+operations+orders}
            result['history'] = [dict(r) for r in db.execute('SELECT entity_type,entity_id,actor_id,action,created_at FROM v2_audit WHERE tenant_id=? ORDER BY seq',(tenant,))
                if r['entity_id'] in entities and within(r['created_at'])]
            result['counts'] = {'properties':len(result['properties']),'plots':len(result['plots']),'completed_operations':len(operations),
                'programs_pending':sum(p['status']=='pending' for p in programming),'programs_in_progress':sum(p['status']=='in_progress' for p in programming),
                'programs_completed':sum(p['status']=='completed' for p in programming),'low_stock':sum(p['low_stock'] for p in stock),
                'machines_in_maintenance':len({o['machine_id'] for o in orders if not o['machine_released']})}
            if report_type != 'overview':
                # Do not export unrelated modules as hidden, unfiltered extras.
                if report_type != 'stock': result.pop('stock',None)
                if report_type not in ('machines','maintenance','costs'): result.pop('maintenance',None)
                if report_type != 'season': result.pop('programs',None)
                if report_type not in ('machines',): result.pop('machines',None)
                if report_type in ('stock','maintenance'): result.pop('operations',None)
            if report_type == 'stock':
                result['metrics']={'stock_value':metric([s['value_cents'] for s in stock],'BRL_cent')}
                result['categories']={};result['ledger']=[];result.pop('productivity',None)
            result['harvest'] = harvest_report(operations,cycles,byplot) if report_type in ('overview','plots','season','production') else []
            if report_type == 'implements':
                result['implements']=[{'id':identity,'name':next(i.get('name') for o in operations for i in o['implements'] if i['id']==identity),
                  'operation_ids':[o['id'] for o in operations if any(i['id']==identity for i in o['implements'])],
                  'operations':[o for o in operations if any(i['id']==identity for i in o['implements'])],
                  'scope':'Vínculos registrados a partir desta atualização. Horas e custos da operação não são cobrados novamente para cada implemento.'}
                  for identity in sorted({i['id'] for o in operations for i in o['implements']})]
            return result
