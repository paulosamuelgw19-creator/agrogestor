"""Organization-scoped tasks and workshop; append-only evidence and costs."""
import hashlib
from . import commercial
import json
import os
import tempfile
from datetime import date
from decimal import Decimal
from pathlib import Path
from uuid import UUID, uuid5, NAMESPACE_URL
from fastapi import File, UploadFile, HTTPException
from fastapi.responses import FileResponse
from .work_models import (TaskBody,TaskProgress,OrderBody,OrderAssign,ProgressBody,ReserveBody,ChecklistBody,LimitBody)
from .v2_metrics import stock_balance, consumption_value, decimal_text, metric
from .logistics_access import is_driver_account

def reserved(db, tenant, property_id, input_id, excluding=None):
    rows=db.execute('''SELECT r.quantity FROM v2_reservations r JOIN v2_work_orders o
      ON o.tenant_id=r.tenant_id AND o.id=r.order_id WHERE r.tenant_id=? AND o.property_id=?
      AND r.input_id=? AND (? IS NULL OR r.order_id!=?)''',
      (tenant,str(property_id),str(input_id),excluding,excluding)).fetchall()
    return sum((Decimal(r['quantity']) for r in rows),Decimal(0))

def ensure_available(db,tenant,property_id,input_id,balance,quantity,excluding=None):
    if not balance['known'] or quantity > balance['quantity']-reserved(db,tenant,property_id,input_id,excluding):
        raise HTTPException(409,'Estoque disponível insuficiente. Confira também as peças reservadas para manutenção.')

def machine_blocked(db,tenant,machine_id):
    return db.execute("SELECT 1 FROM v2_work_orders WHERE tenant_id=? AND machine_id=? AND machine_released=0 AND status!='cancelled' LIMIT 1",(tenant,str(machine_id))).fetchone() is not None

def check_task_operation(db,user,body,property_id):
    if body.task_id is None: return
    row=db.execute('SELECT * FROM v2_tasks WHERE tenant_id=? AND id=?',(user['farmId'],str(body.task_id))).fetchone()
    if row is None or row['property_id']!=property_id or row['cycle_id']!=str(body.cycle_id):
        raise HTTPException(404,'Tarefa não encontrada para este talhão e safra.')
    if user['role']!='admin' and row['assignee_id']!=user['id']:
        raise HTTPException(403,'A tarefa pertence a outro operador.')
    if row['status'] not in ('assigned','in_progress','blocked') or row['version']!=body.task_expected_version:
        raise HTTPException(409,'A tarefa mudou ou já foi encerrada. Atualize antes de concluir.')

def finish_task_operation(db,user,body,api,audit):
    if body.task_id is None: return
    before=dict(db.execute('SELECT * FROM v2_tasks WHERE tenant_id=? AND id=?',(user['farmId'],str(body.task_id))).fetchone())
    db.execute("UPDATE v2_tasks SET status='completed',operation_id=?,version=version+1 WHERE tenant_id=? AND id=?",(str(body.id),user['farmId'],str(body.task_id)))
    audit(db,user,'complete-with-operation','task',body.task_id,{'operation_id':str(body.id)},before['property_id'],before)

def install_work_routes(router,api,User,*,get,access,admin,write,replay,remember,audit,json_text,cycle_context,operation_detail):
    def rows_stock(db,tenant,prop,item):
        return db.execute('SELECT * FROM v2_inventory WHERE tenant_id=? AND property_id=? AND input_id=? ORDER BY seq',(tenant,str(prop),str(item))).fetchall()
    def account(db,tenant,id,role):
        row=db.execute('SELECT * FROM users WHERE farm_id=? AND user_id=? AND role=? AND disabled=0',(tenant,id,role)).fetchone()
        if row is None or is_driver_account(db,tenant,id): raise HTTPException(422,'Selecione uma conta ativa deste cliente com o perfil correto.')
        return row
    def machine_in_property(db,tenant,machine,prop):
        row=get(db,'v2_machines',tenant,machine)
        if row['archived']:
            raise HTTPException(409,'Máquina arquivada. Reative antes de atribuir um novo trabalho.')
        if not db.execute('SELECT 1 FROM v2_machine_properties WHERE tenant_id=? AND machine_id=? AND property_id=?',(tenant,str(machine),str(prop))).fetchone():
            raise HTTPException(404,'Máquina não vinculada a esta propriedade.')
        return row
    def version(row,expected):
        if row['version']!=expected: raise HTTPException(409,'O registro mudou. Atualize e confira antes de enviar novamente.')
    def order_access(db,user,key,edit=False):
        row=get(db,'v2_work_orders',user['farmId'],key)
        if user['role']=='admin': return row
        if user['role']=='mechanic' and row['mechanic_id']==user['id']: return row
        if user['role']=='operator' and row['actor_id']==user['id'] and not edit:
            access(db,user,row['property_id'],'operate'); return row
        raise HTTPException(404,'Ordem não disponível para este usuário.')
    def task_access(db,user,key):
        row=get(db,'v2_tasks',user['farmId'],key)
        if user['role']!='admin' and (user['role']!='operator' or row['assignee_id']!=user['id']):
            raise HTTPException(404,'Tarefa não disponível para este usuário.')
        access(db,user,row['property_id'],'operate')
        return row
    def photos(db,user,kind,key):
        return [dict(r) for r in db.execute('SELECT id,mime_type,actor_id,created_at FROM v2_work_photos WHERE tenant_id=? AND target_kind=? AND target_id=? ORDER BY created_at,id',(user['farmId'],kind,str(key)))]
    def order_detail(db,user,key):
        row=dict(order_access(db,user,key)); tenant=user['farmId']
        row['machine_name']=get(db,'v2_machines',tenant,row['machine_id'])['name']
        row['machine_blocked']=machine_blocked(db,tenant,row['machine_id'])
        row['property_name']=get(db,'v2_properties',tenant,row['property_id'])['name']
        row['mechanic_name']=None if row['mechanic_id'] is None else db.execute('SELECT display_name FROM users WHERE farm_id=? AND user_id=?',(tenant,row['mechanic_id'])).fetchone()[0]
        progress=[dict(r) for r in db.execute('SELECT * FROM v2_work_progress WHERE tenant_id=? AND order_id=? ORDER BY created_at,rowid',(tenant,str(key)))]
        costs=[]
        for p in progress:
            p['actor_name']=db.execute('SELECT display_name FROM users WHERE farm_id=? AND user_id=?',(tenant,p['actor_id'])).fetchone()[0]
            p['photos']=json.loads(p.pop('photos_json'))
            p['parts']=[dict(r) for r in db.execute('''SELECT i.input_id,i.quantity,i.value_cents,x.name,x.unit FROM v2_work_parts w
              JOIN v2_inventory i ON i.tenant_id=w.tenant_id AND i.id=w.inventory_id
              JOIN v2_inputs x ON x.tenant_id=i.tenant_id AND x.id=i.input_id WHERE w.tenant_id=? AND w.progress_id=?''',(tenant,p['id']))]
            costs += [item['value_cents'] for item in p['parts']]
            if p['labor_hours'] is not None or p['labor_cost_cents'] is not None: costs.append(p['labor_cost_cents'])
            if p['service_cost_cents'] is not None: costs.append(p['service_cost_cents'])
            if user['role']!='admin':
                p.pop('labor_cost_cents');p.pop('service_cost_cents')
                for item in p['parts']: item.pop('value_cents')
        row['progress']=progress
        row['reservations']=[dict(r) for r in db.execute('''SELECT r.input_id,r.quantity,x.name,x.unit FROM v2_reservations r
          JOIN v2_inputs x ON x.tenant_id=r.tenant_id AND x.id=r.input_id WHERE r.tenant_id=? AND r.order_id=?''',(tenant,str(key)))]
        row['photos']=photos(db,user,'order',key)
        if user['role']=='admin': row['registered_cost']=metric(costs,'BRL_cent')
        return row
    def task_detail(db,user,key):
        row=dict(task_access(db,user,key))
        cycle,plot,prop,crop=cycle_context(db,user['farmId'],row['cycle_id'])
        row.update(property_name=prop['name'],plot_name=plot['name'],crop_name=crop['name'],cycle_name=cycle['name'])
        row['assignee_name']=db.execute('SELECT display_name FROM users WHERE farm_id=? AND user_id=?',(user['farmId'],row['assignee_id'])).fetchone()[0]
        row['planned_inputs']=json.loads(row.pop('planned_inputs_json'))
        row['history']=[{'id':json.loads(r['after_json']).get('id'),'description':json.loads(r['after_json']).get('description','Conclusão vinculada à operação'),
          'actor_id':r['actor_id'],'created_at':r['created_at']} for r in db.execute("SELECT actor_id,created_at,after_json FROM v2_audit WHERE tenant_id=? AND entity_type='task' AND entity_id=? AND action IN ('progress','complete-with-operation') ORDER BY seq",(user['farmId'],str(key)))]
        if user['role']!='admin': row.pop('planned_cost_cents')
        if row['operation_id']:
            actual=operation_detail(db,user,row['operation_id'],authorized_task=True)
            row['actual']={'operation_id':actual['id'],'area_ha':actual['area_ha'],'labor_hours':actual['labor_hours'],
              'machine_hours':decimal_text(sum((Decimal(m['hours']) for m in actual['machines']),Decimal(0))) if actual['machines'] else None,
              'inputs':[{'input_id':i['input_id'],'name':i['name'],'quantity':i['quantity'],'unit':i['unit']} for i in actual['inputs']],
              'voided':actual['void'] is not None,'refuelings':actual['refuelings']}
            if user['role']=='admin':
                row['actual']['registered_cost']=metric([m['cost_cents'] for m in actual['machines']]+[i['value_cents'] for i in actual['inputs']]+[r['total_cost_cents'] for r in actual['refuelings'] if r['source']=='external']+([actual['measurements'].get('labor_cost_cents')] if actual['labor_hours'] is not None or actual['measurements'].get('labor_cost_cents') is not None else []),'BRL_cent')
        return row

    @router.get('/work/workspace')
    def workspace(user:User):
        tenant=user['farmId']; today=date.today().isoformat()
        with api.connect() as db:
            result={'generated_at':api.utc_now(),'role':user['role'],'user_id':user['id'],'tasks':[],'orders':[],
              'properties':[],'cycles':[],'machines':[],'inputs':[],'users':[],'stock':[],'checklists':[],'alerts':[]}
            props=[dict(r) for r in db.execute('SELECT * FROM v2_properties WHERE tenant_id=? AND archived=0 ORDER BY name',(tenant,))] if user['role']=='admin' else [dict(r) for r in db.execute('''SELECT p.* FROM v2_properties p JOIN v2_access a ON a.tenant_id=p.tenant_id AND a.property_id=p.id
              WHERE p.tenant_id=? AND a.user_id=? AND a.role IN ('employee','owner','manager') AND p.archived=0''',(tenant,user['id']))] if user['role']=='operator' else []
            for r in db.execute('SELECT id FROM v2_tasks WHERE tenant_id=? AND (?=\'admin\' OR assignee_id=?) ORDER BY due_on,id',(tenant,user['role'],user['id'])):
                try:result['tasks'].append(task_detail(db,user,r['id']))
                except HTTPException as error:
                    if error.status_code not in (403,404):raise
            for r in db.execute('SELECT id FROM v2_work_orders WHERE tenant_id=? AND (?=\'admin\' OR mechanic_id=? OR actor_id=?) ORDER BY created_at DESC,id',(tenant,user['role'],user['id'],user['id'])):
                try:result['orders'].append(order_detail(db,user,r['id']))
                except HTTPException as error:
                    if error.status_code not in (403,404):raise
            result['properties']=props
            if user['role']=='admin':
                result['users']=[dict(r) for r in db.execute("SELECT user_id AS id,display_name AS name,role FROM users u WHERE farm_id=? AND disabled=0 AND role IN ('operator','mechanic') AND NOT EXISTS (SELECT 1 FROM v2_driver_accounts d WHERE d.tenant_id=u.farm_id AND d.user_id=u.user_id) ORDER BY display_name",(tenant,))]
            machine_ids={o['machine_id'] for o in result['orders']}
            property_ids={p['id'] for p in props} | {o['property_id'] for o in result['orders'] if user['role']=='mechanic'}
            for prop in props:
                result['cycles'] += [dict(r) for r in db.execute('''SELECT c.*,p.property_id,p.name AS plot_name,x.name AS crop_name FROM v2_cycles c JOIN v2_plots p
                  ON p.tenant_id=c.tenant_id AND p.id=c.plot_id JOIN v2_crops x ON x.tenant_id=c.tenant_id AND x.id=c.crop_id
                  WHERE p.tenant_id=? AND p.property_id=? AND p.archived=0''',(tenant,prop['id']))]
                machine_ids |= {r['machine_id'] for r in db.execute('SELECT machine_id FROM v2_machine_properties WHERE tenant_id=? AND property_id=?',(tenant,prop['id']))}
            for key in sorted(machine_ids):
                row=dict(get(db,'v2_machines',tenant,key)); row['blocked']=machine_blocked(db,tenant,key)
                row['property_ids']=[r[0] for r in db.execute('SELECT property_id FROM v2_machine_properties WHERE tenant_id=? AND machine_id=?',(tenant,key)) if r[0] in property_ids]
                if user['role']!='admin':row.pop('hourly_cost_cents')
                result['machines'].append(row)
            input_ids=set()
            for prop_id in property_ids:
                for r in db.execute('SELECT DISTINCT input_id FROM v2_inventory WHERE tenant_id=? AND property_id=?',(tenant,prop_id)):
                    key=r['input_id'];input_ids.add(key); bal=stock_balance(rows_stock(db,tenant,prop_id,key)); amount=reserved(db,tenant,prop_id,key)
                    stock={'property_id':prop_id,'input_id':key,'known':bal['known'],'quantity':decimal_text(bal['quantity']),
                      'reserved_quantity':decimal_text(amount),'available_quantity':None if not bal['known'] else decimal_text(bal['quantity']-amount)}
                    if user['role']=='admin':
                        stock['value_cents']=bal['value_cents']
                        limit=db.execute('SELECT minimum_quantity FROM v2_stock_limits WHERE tenant_id=? AND property_id=? AND input_id=?',(tenant,prop_id,key)).fetchone()
                        stock['minimum_quantity']=limit[0] if limit else None
                    result['stock'].append(stock)
            result['inputs']=[dict(r) for r in db.execute('SELECT * FROM v2_inputs WHERE tenant_id=? ORDER BY name',(tenant,))] if user['role']=='admin' else [dict(get(db,'v2_inputs',tenant,k)) for k in sorted(input_ids)]
            for row in db.execute('SELECT * FROM v2_checklists WHERE tenant_id=? AND (?=\'admin\' OR actor_id=?) ORDER BY created_at DESC LIMIT 200',(tenant,user['role'],user['id'])):
                if row['property_id'] not in property_ids:continue
                item=dict(row);item['items']=json.loads(item.pop('items_json'));item['photos']=photos(db,user,'checklist',item['id']);result['checklists'].append(item)
            for task in result['tasks']:
                if task['status'] not in ('completed','cancelled') and task['due_on']<today:
                    result['alerts'].append({'kind':'late_task','title':task['title'],'entity_id':task['id']})
            for order in result['orders']:
                if order['status'] not in ('completed','cancelled') and order['due_on'] and order['due_on']<today:
                    result['alerts'].append({'kind':'late_order','title':order['title'],'entity_id':order['id']})
                machine=get(db,'v2_machines',tenant,order['machine_id'])
                if order['status']=='completed' and ((order['next_due_on'] and order['next_due_on']<=today) or
                  (order['next_due_meter'] is not None and Decimal(machine['hour_meter'])>=Decimal(order['next_due_meter']))):
                    # A newer order suppresses a superseded preventive schedule.
                    newer=db.execute("SELECT 1 FROM v2_work_orders WHERE tenant_id=? AND machine_id=? AND status='completed' AND (next_due_on IS NOT NULL OR next_due_meter IS NOT NULL) AND rowid>(SELECT rowid FROM v2_work_orders WHERE tenant_id=? AND id=?) LIMIT 1",(tenant,order['machine_id'],tenant,order['id'])).fetchone()
                    if not newer:result['alerts'].append({'kind':'preventive_due','title':machine['name'],'entity_id':order['id']})
            if user['role']=='admin':
                for limit in db.execute('SELECT * FROM v2_stock_limits WHERE tenant_id=?',(tenant,)):
                    bal=stock_balance(rows_stock(db,tenant,limit['property_id'],limit['input_id']))
                    if bal['known'] and bal['quantity']-reserved(db,tenant,limit['property_id'],limit['input_id'])<=Decimal(limit['minimum_quantity']):
                        result['alerts'].append({'kind':'low_stock','title':get(db,'v2_inputs',tenant,limit['input_id'])['name'],
                          'property_id':limit['property_id'],'available_quantity':decimal_text(bal['quantity']-reserved(db,tenant,limit['property_id'],limit['input_id'])),'minimum_quantity':limit['minimum_quantity']})
            return result

    @router.post('/work/tasks')
    def create_task(body:TaskBody,user:User):
        admin(user)
        with write(user) as db:
            if replay(db,user,'task',body):return task_detail(db,user,body.id)
            cycle,plot,prop,_=cycle_context(db,user['farmId'],body.cycle_id)
            if prop['archived'] or plot['archived']:raise HTTPException(409,'Selecione propriedade e talhão ativos.')
            assigned=account(db,user['farmId'],body.assignee_id,'operator')
            access(db,{'farmId':user['farmId'],'id':assigned['user_id'],'role':assigned['role']},prop['id'],'operate')
            if body.machine_id:
                machine_in_property(db,user['farmId'],body.machine_id,prop['id'])
                if machine_blocked(db,user['farmId'],body.machine_id):raise HTTPException(409,'A máquina está parada para manutenção.')
            if body.planned_area_ha is not None and cycle['area_ha'] is not None and body.planned_area_ha>Decimal(cycle['area_ha']):
                raise HTTPException(422,'Área planejada excede a safra.')
            if body.due_on.isoformat()<cycle['starts_on'] or cycle['ends_on'] and body.due_on.isoformat()>cycle['ends_on']:
                raise HTTPException(422,'A data prevista deve estar dentro da safra.')
            for item in body.planned_inputs:get(db,'v2_inputs',user['farmId'],item.input_id)
            db.execute('INSERT INTO v2_tasks VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
              (user['farmId'],str(body.id),prop['id'],str(body.cycle_id),str(body.machine_id) if body.machine_id else None,body.assignee_id,
               body.title,body.kind,body.due_on.isoformat(),body.priority,decimal_text(body.planned_area_ha),decimal_text(body.planned_hours),
               body.planned_cost_cents,json_text(body.planned_inputs),body.notes,'assigned',1,None,user['id'],api.utc_now()))
            remember(db,user,'task',body);audit(db,user,'create','task',body.id,body,prop['id'])
            return task_detail(db,user,body.id)

    @router.post('/work/tasks/{task_id}/progress')
    def progress_task(task_id:UUID,body:TaskProgress,user:User):
        with write(user) as db:
            row=task_access(db,user,task_id)
            if replay(db,user,'task-progress:'+str(task_id),body):return task_detail(db,user,task_id)
            version(row,body.expected_version)
            if row['status'] in ('completed','cancelled'):raise HTTPException(409,'Tarefa já encerrada.')
            if body.status=='cancelled':admin(user)
            db.execute('UPDATE v2_tasks SET status=?,version=version+1 WHERE tenant_id=? AND id=?',(body.status,user['farmId'],str(task_id)))
            remember(db,user,'task-progress:'+str(task_id),body);audit(db,user,'progress','task',task_id,body,row['property_id'],dict(row))
            return task_detail(db,user,task_id)

    @router.post('/work/orders')
    def create_order(body:OrderBody,user:User):
        with write(user) as db:
            if user['role'] not in ('admin','operator'):raise HTTPException(403,'O gestor ou operador abre a ocorrência.')
            access(db,user,body.property_id,'operate')
            if replay(db,user,'work-order',body):return order_detail(db,user,body.id)
            if get(db,'v2_properties',user['farmId'],body.property_id)['archived']:raise HTTPException(409,'Propriedade arquivada.')
            machine_in_property(db,user['farmId'],body.machine_id,body.property_id)
            if user['role']!='admin' and (body.mechanic_id or body.due_on):raise HTTPException(403,'O gestor define o mecânico e o prazo.')
            if body.mechanic_id:account(db,user['farmId'],body.mechanic_id,'mechanic')
            db.execute('INSERT INTO v2_work_orders VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
              (user['farmId'],str(body.id),str(body.property_id),str(body.machine_id),body.mechanic_id,body.title,body.description,body.priority,
               body.due_on.isoformat() if body.due_on else None,None,None,'analysis' if body.mechanic_id else 'reported',1,int(not body.stop_machine),user['id'],api.utc_now()))
            remember(db,user,'work-order',body);audit(db,user,'create','work-order',body.id,body,body.property_id)
            return order_detail(db,user,body.id)

    @router.get('/work/orders/{order_id}')
    def read_order(order_id:UUID,user:User):
        with api.connect() as db:return order_detail(db,user,order_id)

    @router.post('/work/orders/{order_id}/assign')
    def assign_order(order_id:UUID,body:OrderAssign,user:User):
        admin(user)
        with write(user) as db:
            row=order_access(db,user,order_id,True)
            if replay(db,user,'order-assign:'+str(order_id),body):return order_detail(db,user,order_id)
            version(row,body.expected_version);account(db,user['farmId'],body.mechanic_id,'mechanic')
            if row['status'] in ('completed','cancelled'):raise HTTPException(409,'Ordem já encerrada.')
            db.execute("UPDATE v2_work_orders SET mechanic_id=?,priority=?,due_on=?,status=CASE WHEN status='reported' THEN 'analysis' ELSE status END,version=version+1 WHERE tenant_id=? AND id=?",
              (body.mechanic_id,body.priority,str(body.due_on) if body.due_on else None,user['farmId'],str(order_id)))
            remember(db,user,'order-assign:'+str(order_id),body);audit(db,user,'assign','work-order',order_id,body,row['property_id'],dict(row))
            return order_detail(db,user,order_id)

    @router.post('/work/orders/{order_id}/reserve')
    def reserve(order_id:UUID,body:ReserveBody,user:User):
        admin(user)
        with write(user) as db:
            row=order_access(db,user,order_id,True)
            if replay(db,user,'order-reserve:'+str(order_id),body):return order_detail(db,user,order_id)
            version(row,body.expected_version)
            if row['status'] in ('completed','cancelled'):raise HTTPException(409,'Ordem já encerrada.')
            get(db,'v2_inputs',user['farmId'],body.input_id)
            bal=stock_balance(rows_stock(db,user['farmId'],row['property_id'],body.input_id))
            if body.quantity:ensure_available(db,user['farmId'],row['property_id'],body.input_id,bal,body.quantity,str(order_id))
            db.execute('INSERT INTO v2_reservations VALUES(?,?,?,?) ON CONFLICT(tenant_id,order_id,input_id) DO UPDATE SET quantity=excluded.quantity',
              (user['farmId'],str(order_id),str(body.input_id),decimal_text(body.quantity)))
            db.execute('UPDATE v2_work_orders SET version=version+1 WHERE tenant_id=? AND id=?',(user['farmId'],str(order_id)))
            remember(db,user,'order-reserve:'+str(order_id),body);audit(db,user,'reserve','work-order',order_id,body,row['property_id'])
            return order_detail(db,user,order_id)

    @router.post('/work/orders/{order_id}/progress')
    def progress_order(order_id:UUID,body:ProgressBody,user:User):
        with write(user) as db:
            tenant=user['farmId'];row=order_access(db,user,order_id,True)
            if replay(db,user,'order-progress:'+str(order_id),body):return order_detail(db,user,order_id)
            version(row,body.expected_version)
            transitions={'reported':{'analysis','cancelled'},'analysis':{'analysis','in_progress','waiting_parts','cancelled'},
              'in_progress':{'in_progress','waiting_parts','testing','completed','cancelled'},'waiting_parts':{'waiting_parts','in_progress','cancelled'},
              'testing':{'testing','in_progress','completed'},'completed':{'completed'},'cancelled':set()}
            if body.status not in transitions[row['status']]:raise HTTPException(409,'Mudança de situação inválida. Confira a ordem.')
            if body.status=='cancelled':admin(user)
            if row['status']=='completed' and (body.parts or body.labor_hours is not None or body.labor_cost_cents is not None or body.service_cost_cents is not None):
                raise HTTPException(409,'Custos de ordem encerrada exigem conferência pelo gestor; não duplique lançamentos.')
            if body.next_due_meter is not None and body.next_due_meter<Decimal(get(db,'v2_machines',tenant,row['machine_id'])['hour_meter']):
                raise HTTPException(422,'Próxima revisão não pode ser anterior ao horímetro atual.')
            if body.next_due_on is not None and body.next_due_on<date.today():raise HTTPException(422,'Informe uma data futura para a revisão.')
            for key in body.photos:
                photo=db.execute("SELECT 1 FROM v2_work_photos WHERE tenant_id=? AND id=? AND target_kind='order' AND target_id=? AND actor_id=?",(tenant,str(key),str(order_id),user['id'])).fetchone()
                if not photo:raise HTTPException(404,'Foto não disponível para esta atualização.')
            db.execute('INSERT INTO v2_work_progress VALUES(?,?,?,?,?,?,?,?,?,?,?)',
              (tenant,str(body.id),str(order_id),body.description,body.status,decimal_text(body.labor_hours),body.labor_cost_cents,body.service_cost_cents,json_text(body.photos),user['id'],api.utc_now()))
            quantities={}
            for item in body.parts:quantities[str(item.input_id)]=quantities.get(str(item.input_id),Decimal(0))+item.quantity
            for key,quantity in quantities.items():
                get(db,'v2_inputs',tenant,key);stock_rows=rows_stock(db,tenant,row['property_id'],key);bal=stock_balance(stock_rows)
                ensure_available(db,tenant,row['property_id'],key,bal,quantity,str(order_id))
                day=date.today().isoformat()
                if stock_rows and day<stock_rows[-1]['occurred_on']:raise HTTPException(409,'Movimento anterior ao último estoque. Confira as datas.')
                value=consumption_value(bal,quantity);inventory_id=str(uuid5(body.id,key))
                db.execute('''INSERT INTO v2_inventory(tenant_id,id,property_id,input_id,kind,quantity,value_cents,actor_id,occurred_on,created_at,request_json)
                  VALUES(?,?,?,?,'consume',?,?,?,?,?,?)''',(tenant,inventory_id,row['property_id'],key,decimal_text(quantity),value,user['id'],day,api.utc_now(),json_text(body)))
                db.execute('INSERT INTO v2_work_parts VALUES(?,?,?,?)',(tenant,str(body.id),key,inventory_id))
                prior=db.execute('SELECT quantity FROM v2_reservations WHERE tenant_id=? AND order_id=? AND input_id=?',(tenant,str(order_id),key)).fetchone()
                if prior:db.execute('UPDATE v2_reservations SET quantity=? WHERE tenant_id=? AND order_id=? AND input_id=?',(decimal_text(max(Decimal(0),Decimal(prior['quantity'])-quantity)),tenant,str(order_id),key))
            if body.status in ('completed','cancelled'):db.execute('DELETE FROM v2_reservations WHERE tenant_id=? AND order_id=?',(tenant,str(order_id)))
            release=int(body.machine_released) if body.machine_released is not None else row['machine_released']
            if body.status in ('in_progress','waiting_parts','testing'):release=0
            if body.status=='cancelled':release=1
            db.execute('''UPDATE v2_work_orders SET status=?,version=version+1,machine_released=?,
              next_due_on=COALESCE(?,next_due_on),next_due_meter=COALESCE(?,next_due_meter) WHERE tenant_id=? AND id=?''',
              (body.status,release,str(body.next_due_on) if body.next_due_on else None,decimal_text(body.next_due_meter),tenant,str(order_id)))
            remember(db,user,'order-progress:'+str(order_id),body);audit(db,user,'progress','work-order',order_id,body,row['property_id'],dict(row))
            return order_detail(db,user,order_id)

    @router.post('/work/checklists')
    def checklist(body:ChecklistBody,user:User):
        with write(user) as db:
            if user['role']=='mechanic':
                assigned=db.execute("SELECT 1 FROM v2_work_orders WHERE tenant_id=? AND mechanic_id=? AND machine_id=? AND property_id=? AND status!='cancelled'",(user['farmId'],user['id'],str(body.machine_id),str(body.property_id))).fetchone()
                if not assigned:raise HTTPException(404,'Máquina não disponível para este mecânico.')
            else:access(db,user,body.property_id,'operate')
            machine_in_property(db,user['farmId'],body.machine_id,body.property_id)
            if replay(db,user,'checklist',body):return {'id':str(body.id)}
            db.execute('INSERT INTO v2_checklists VALUES(?,?,?,?,?,?,?,?,?)',(user['farmId'],str(body.id),str(body.property_id),str(body.machine_id),body.phase,json_text(body.items),body.notes,user['id'],api.utc_now()))
            remember(db,user,'checklist',body);audit(db,user,'create','checklist',body.id,body,body.property_id)
            return {'id':str(body.id)}

    @router.post('/work/stock-limits')
    def limit(body:LimitBody,user:User):
        admin(user)
        with write(user) as db:
            access(db,user,body.property_id,'stock');get(db,'v2_inputs',user['farmId'],body.input_id)
            if replay(db,user,'stock-limit',body):return {'saved':True}
            db.execute('INSERT INTO v2_stock_limits VALUES(?,?,?,?) ON CONFLICT(tenant_id,property_id,input_id) DO UPDATE SET minimum_quantity=excluded.minimum_quantity',
              (user['farmId'],str(body.property_id),str(body.input_id),decimal_text(body.minimum_quantity)))
            remember(db,user,'stock-limit',body);audit(db,user,'set-minimum','input',body.input_id,body,body.property_id)
            return {'saved':True}

    def photo_access(db,user,kind,target_id,edit=False):
        if kind in ('machine','implement'):
            if edit and user['role'] not in ('admin','operator'):
                raise HTTPException(403,'Somente gestor e operador podem anexar fotos ao cadastro.')
            if edit: commercial.write_access(db,user['farmId'],'fleet')
            if kind == 'implement':
                row = db.execute("SELECT record_id FROM records WHERE farm_id=? AND module='implements' AND record_id=? AND deleted=0",(user['farmId'],str(target_id))).fetchone()
                if not row or user['role'] not in ('admin','operator'):
                    raise HTTPException(404,'Implemento não encontrado.')
                return {'property_id':None}
            get(db,'v2_machines',user['farmId'],target_id)
            links = db.execute('SELECT property_id FROM v2_machine_properties WHERE tenant_id=? AND machine_id=?',(user['farmId'],str(target_id))).fetchall()
            for link in links:
                try:
                    access(db,user,link['property_id'],'operate' if edit else 'read')
                    return {'property_id':link['property_id']}
                except HTTPException as error:
                    if error.status_code not in (403,404):raise
            raise HTTPException(404,'Máquina não encontrada para esta conta.')
        if kind=='order':
            return order_access(db,user,target_id,edit and user['role']!='operator')
        if kind!='checklist':raise HTTPException(404,'Registro não encontrado.')
        row=get(db,'v2_checklists',user['farmId'],target_id)
        if user['role']=='admin':return row
        if row['actor_id']!=user['id']:raise HTTPException(404,'Checklist não disponível.')
        if user['role']=='mechanic':
            if not db.execute("SELECT 1 FROM v2_work_orders WHERE tenant_id=? AND mechanic_id=? AND machine_id=? AND property_id=? AND status!='cancelled'",(user['farmId'],user['id'],row['machine_id'],row['property_id'])).fetchone():
                raise HTTPException(404,'Checklist não disponível.')
        else:access(db,user,row['property_id'],'operate')
        return row

    @router.get('/work/receipts/{event_id}')
    def receipt(event_id:UUID,user:User):
        with api.connect() as db:
            rows=db.execute('SELECT entity_type,request_json FROM v2_requests WHERE tenant_id=? AND entity_id=?',(user['farmId'],str(event_id))).fetchall()
            authored=db.execute("SELECT 1 FROM v2_audit WHERE tenant_id=? AND actor_id=? AND json_extract(after_json,'$.id')=? LIMIT 1",(user['farmId'],user['id'],str(event_id))).fetchone()
            if not authored:raise HTTPException(404,'Lançamento não confirmado para esta conta.')
            for row in rows:
                kind=row['entity_type']
                if kind=='task':task_access(db,user,event_id)
                elif kind=='work-order':order_access(db,user,event_id)
                elif kind.startswith('task-progress:'):task_access(db,user,kind.split(':',1)[1])
                elif kind.startswith(('order-progress:','order-assign:','order-reserve:')):order_access(db,user,kind.split(':',1)[1])
                elif kind=='checklist':photo_access(db,user,'checklist',event_id)
                elif kind=='stock-limit':admin(user)
                else:continue
                return {'confirmed':True}
            raise HTTPException(404,'Lançamento não confirmado para esta conta.')
    def photo_path(tenant,key):
        return api.ATTACHMENTS_DIR/'work'/str(uuid5(NAMESPACE_URL,tenant))/str(key)

    @router.get('/work/{target_kind}/{target_id}/photos')
    def list_photos(target_kind:str,target_id:UUID,user:User):
        with api.connect() as db:
            photo_access(db,user,target_kind,target_id)
            can_edit = user['role'] in ('admin','operator')
            if can_edit:
                try: photo_access(db,user,target_kind,target_id,True)
                except HTTPException: can_edit = False
            return {'can_edit':can_edit,
                    'items':[dict(r) for r in db.execute('SELECT id,mime_type,size_bytes,actor_id,created_at FROM v2_work_photos WHERE tenant_id=? AND target_kind=? AND target_id=? ORDER BY created_at,id',(user['farmId'],target_kind,str(target_id)))]}

    @router.put('/work/{target_kind}/{target_id}/photos/{photo_id}')
    async def upload_photo(target_kind:str,target_id:UUID,photo_id:UUID,user:User,file:UploadFile=File(...)):
        api.require_active_license(user['farmId'])
        with api.connect() as db:photo_access(db,user,target_kind,target_id,True)
        folder=photo_path(user['farmId'],photo_id).parent;folder.mkdir(parents=True,exist_ok=True)
        handle,temp=tempfile.mkstemp(prefix='photo-',dir=folder);total=0;digest=hashlib.sha256();header=b''
        try:
            with os.fdopen(handle,'wb') as out:
                while chunk:=await file.read(65536):
                    total+=len(chunk)
                    if total>8*1024*1024:raise HTTPException(413,'Foto maior que 8 MB.')
                    if not header:header=chunk[:16]
                    out.write(chunk);digest.update(chunk)
            mime='image/png' if header.startswith(b'\x89PNG\r\n\x1a\n') else 'image/jpeg' if header.startswith(b'\xff\xd8\xff') else None
            if not mime:raise HTTPException(422,'Selecione uma foto JPEG ou PNG.')
            with write(user) as db:
                photo_access(db,user,target_kind,target_id,True)
                prior=db.execute('SELECT * FROM v2_work_photos WHERE tenant_id=? AND id=?',(user['farmId'],str(photo_id))).fetchone()
                if prior:
                    if (prior['target_kind'],prior['target_id'],prior['sha256'],prior['actor_id'])!=(target_kind,str(target_id),digest.hexdigest(),user['id']):raise HTTPException(409,'A foto já foi usada com outros dados.')
                    return {'id':str(photo_id)}
                db.execute('INSERT INTO v2_work_photos VALUES(?,?,?,?,?,?,?,?,?)',(user['farmId'],str(photo_id),target_kind,str(target_id),digest.hexdigest(),total,mime,user['id'],api.utc_now()))
                os.replace(temp,photo_path(user['farmId'],photo_id))
                audit(db,user,'photo','work-'+target_kind,target_id,{'photo_id':str(photo_id)},photo_access(db,user,target_kind,target_id)['property_id'])
            return {'id':str(photo_id)}
        finally:
            Path(temp).unlink(missing_ok=True);await file.close()

    @router.get('/work/{target_kind}/{target_id}/photos/{photo_id}')
    def read_photo(target_kind:str,target_id:UUID,photo_id:UUID,user:User):
        with api.connect() as db:
            photo_access(db,user,target_kind,target_id)
            row=db.execute('SELECT * FROM v2_work_photos WHERE tenant_id=? AND id=? AND target_kind=? AND target_id=?',(user['farmId'],str(photo_id),target_kind,str(target_id))).fetchone()
            path=photo_path(user['farmId'],photo_id)
            if not row or not path.is_file():raise HTTPException(404,'Foto não encontrada.')
            return FileResponse(path,media_type=row['mime_type'],headers={'Cache-Control':'private, no-store','X-Content-Type-Options':'nosniff'})
