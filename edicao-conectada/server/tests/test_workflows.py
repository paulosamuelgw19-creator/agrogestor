import json
import unittest
from datetime import date
from uuid import uuid4
import test_v2_pilot as pilot
api=pilot.api

class WorkTests(unittest.TestCase):
    def setUp(self):
        self.p=pilot.PilotTests();self.p.setUp();self.p.grant('worker','employee')
        with api.connect() as db:
            for key in ['mechanic','other-mechanic']:
                db.execute('INSERT INTO users(user_id,farm_id,email,display_name,role,password_hash,created_at) VALUES(?,?,?,?,?,?,?)',
                    (key,'org-a',key+'@example.invalid',key,'mechanic','unused',api.utc_now()))
                db.execute('INSERT INTO devices(farm_id,device_id,device_name,activated_by,activated_at,last_seen_at) VALUES(?,?,?,?,?,?)',
                    ('org-a','device-'+key,'Synthetic',key,api.utc_now(),api.utc_now()))
        for key in ['mechanic','other-mechanic']:
            self.p.tokens[key]={'Authorization':'Bearer '+api.make_token(key,'org-a','device-'+key)}
    def tearDown(self):self.p.tearDown()
    def order(self,**overrides):
        body={'id':str(uuid4()),'property_id':self.p.prop,'machine_id':self.p.machine,
          'title':'Reparo fictício','description':'Vazamento fictício','mechanic_id':'mechanic'}
        return self.p.post('/work/orders',body|overrides)
    def progress(self,row,status='in_progress',**extra):
        return {'id':str(uuid4()),'expected_version':row['version'],'description':'Andamento fictício',
          'status':status}|extra
    def task(self,**extra):
        return self.p.post('/work/tasks',{'id':str(uuid4()),'cycle_id':self.p.cycle,'assignee_id':'worker',
          'title':'Aplicação fictícia','kind':'application','due_on':date.today().isoformat(),
          'planned_area_ha':'5','planned_inputs':[{'input_id':self.p.diesel,'quantity':'2'}]}|extra)
    def test_task_completed_only_by_real_operation_and_idempotent_consumption(self):
        self.p.opening();task=self.task(planned_cost_cents=1200)
        own=self.p.request('GET','/work/workspace',user='worker')['tasks'][0]
        self.assertNotIn('planned_cost_cents',own)
        self.p.post('/work/tasks/'+task['id']+'/progress',self.progress(task,'completed'),user='worker',expected=422)
        op=self.p.operation();op.update(machines=[],inputs=[{'input_id':self.p.diesel,'quantity':'2'}],
          task_id=task['id'],task_expected_version=1,performed_on=date.today().isoformat())
        self.p.post('/operations',op,user='worker');self.p.post('/operations',op,user='worker')
        self.assertEqual(self.p.stock()['quantity'],'98')
        result=self.p.request('GET','/work/workspace')['tasks'][0]
        self.assertEqual(result['status'],'completed');self.assertEqual(result['operation_id'],op['id'])
        self.assertEqual(result['actual']['registered_cost']['value'],'1200')
        op['id']=str(uuid4());self.p.post('/operations',op,user='worker',expected=409)
    def test_task_rejects_wrong_operator_foreign_context_and_stale_version(self):
        self.p.grant('consultant','consultant')
        self.task()
        body={'id':str(uuid4()),'cycle_id':self.p.cycle,'assignee_id':'consultant','title':'Errada',
          'kind':'management','due_on':date.today().isoformat()}
        self.p.post('/work/tasks',body,expected=403)
        self.p.post('/work/tasks',body,user='worker',expected=403)
        task=self.p.request('GET','/work/workspace')['tasks'][0]
        self.p.post('/work/tasks/'+task['id']+'/progress',self.progress(task),user='consultant',expected=404)
        update=self.progress(task);self.p.post('/work/tasks/'+task['id']+'/progress',update,user='worker')
        self.p.post('/work/tasks/'+task['id']+'/progress',update|{'id':str(uuid4())},user='worker',expected=409)
        api.app.dependency_overrides[api.current_user]=lambda:{'id':'foreign','farmId':'org-b','role':'admin'}
        self.assertEqual(self.p.request('GET','/work/workspace')['tasks'],[])
        self.p.post('/work/tasks/'+task['id']+'/progress',update,expected=404)
    def test_diary_is_append_only_assigned_mechanic_only_and_machine_blocked(self):
        row=self.order();self.p.opening()
        self.p.post('/operations',self.p.operation(),expected=409)
        self.p.request('GET','/work/orders/'+row['id'],user='other-mechanic',expected=404)
        self.p.post('/work/orders/'+row['id']+'/progress',self.progress(row),user='worker',expected=404)
        body=self.progress(row,description='Desmontagem iniciada')
        row=self.p.post('/work/orders/'+row['id']+'/progress',body,user='mechanic')
        self.p.post('/work/orders/'+row['id']+'/progress',body,user='mechanic')
        row=self.p.post('/work/orders/'+row['id']+'/progress',self.progress(row,'waiting_parts',description='Aguardando peça'),user='mechanic')
        self.assertEqual([p['description'] for p in row['progress']],['Desmontagem iniciada','Aguardando peça'])
        self.assertTrue(all(p['actor_id']=='mechanic' and p['created_at'] for p in row['progress']))
        self.p.post('/work/orders/'+row['id']+'/progress',self.progress(row,'completed',machine_released=True),user='mechanic',expected=409)
        row=self.p.post('/work/orders/'+row['id']+'/progress',self.progress(row),user='mechanic')
        self.p.post('/work/orders/'+row['id']+'/progress',self.progress(row,'completed'),user='mechanic',expected=422)
        row=self.p.post('/work/orders/'+row['id']+'/progress',self.progress(row,'completed',machine_released=True),user='mechanic')
        self.p.post('/operations',self.p.operation())
        self.assertEqual(len(row['progress']),4)
    def test_reservation_is_not_consumption_parts_consumed_once_and_cost_separate(self):
        self.p.opening(quantity='10',value=10000);row=self.order(stop_machine=False)
        row=self.p.post('/work/orders/'+row['id']+'/reserve',{'id':str(uuid4()),'expected_version':row['version'],
          'input_id':self.p.diesel,'quantity':'8'})
        self.assertEqual(self.p.stock()['quantity'],'10')
        op=self.p.operation(quantity='3');op['machines']=[]
        self.p.post('/operations',op,expected=409)
        row=self.p.post('/work/orders/'+row['id']+'/progress',self.progress(row),user='mechanic')
        body=self.progress(row,'completed',machine_released=True,parts=[{'input_id':self.p.diesel,'quantity':'3'}],
          labor_hours='2',labor_cost_cents=5000)
        self.p.post('/work/orders/'+row['id']+'/progress',body,user='mechanic')
        self.p.post('/work/orders/'+row['id']+'/progress',body,user='mechanic')
        self.assertEqual(self.p.stock()['quantity'],'7');self.assertEqual(self.p.stock()['value_cents'],7000)
        row=self.p.request('GET','/work/orders/'+row['id']);self.assertEqual(row['reservations'],[])
        self.assertEqual(row['registered_cost']['value'],'8000')
        with api.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM v2_operations').fetchone()[0],0)
            self.assertEqual(db.execute('SELECT hourly_cost_cents FROM v2_machines').fetchone()[0],12000)
    def test_parts_failure_rolls_back_diary_reservations_and_costs(self):
        self.p.opening(quantity='1');row=self.order()
        row=self.p.post('/work/orders/'+row['id']+'/progress',self.progress(row),user='mechanic')
        self.p.post('/work/orders/'+row['id']+'/progress',self.progress(row,parts=[{'input_id':self.p.diesel,'quantity':'2'}]),user='mechanic',expected=409)
        current=self.p.request('GET','/work/orders/'+row['id'])
        self.assertEqual(current['version'],row['version']);self.assertEqual(len(current['progress']),1)
        self.assertEqual(self.p.stock()['quantity'],'1')
    def test_occurrence_assignment_checklist_and_alerts_are_scoped(self):
        body={'id':str(uuid4()),'property_id':self.p.prop,'machine_id':self.p.machine,
          'title':'Problema fictício','description':'Relato do operador'}
        row=self.p.post('/work/orders',body,user='worker');self.assertEqual(row['status'],'reported')
        row=self.p.post('/work/orders/'+row['id']+'/assign',{'id':str(uuid4()),'expected_version':1,
          'mechanic_id':'mechanic','priority':'high','due_on':'2026-01-01'})
        self.p.opening(quantity='10');self.p.post('/work/stock-limits',{'id':str(uuid4()),'property_id':self.p.prop,
          'input_id':self.p.diesel,'minimum_quantity':'12'})
        check={'id':str(uuid4()),'property_id':self.p.prop,'machine_id':self.p.machine,'phase':'before',
          'items':[{'label':'Condição visual','ok':False}],'notes':'Verificar vazamento'}
        self.p.post('/work/checklists',check,user='mechanic')
        self.p.post('/work/checklists',check|{'id':str(uuid4())},user='other-mechanic',expected=404)
        admin=self.p.request('GET','/work/workspace')
        self.assertEqual({a['kind'] for a in admin['alerts']},{'late_order','low_stock'})
        self.assertEqual(self.p.request('GET','/work/workspace',user='other-mechanic')['orders'],[])
        self.assertEqual(self.p.request('GET','/work/workspace',user='mechanic')['checklists'][0]['items'][0]['ok'],False)
    def test_photo_permissions_immutable_and_tenant_scoped(self):
        row=self.order();key=str(uuid4());path=f"/api/v2/work/order/{row['id']}/photos/{key}"
        image=b'\x89PNG\r\n\x1a\n' + b'synthetic-image-header'
        upload=lambda data,user='mechanic':self.p.http.put(path,headers=self.p.tokens[user],files={'file':('foto.png',data,'image/png')})
        self.assertEqual(upload(image).status_code,200);self.assertEqual(upload(image).status_code,200)
        self.assertEqual(upload(image+b'changed').status_code,409)
        self.assertEqual(upload(image,'other-mechanic').status_code,404)
        self.assertEqual(self.p.http.get(path,headers=self.p.tokens['mechanic']).content,image)
        self.assertEqual(self.p.http.get(path,headers=self.p.tokens['worker']).status_code,404)
        update=self.progress(row,photos=[key]);self.p.post('/work/orders/'+row['id']+'/progress',update,user='mechanic')
        self.assertEqual(self.p.request('GET','/work/orders/'+row['id'])['progress'][0]['photos'],[key])
    def test_upgrade_is_additive_and_repeatable(self):
        self.p.opening();before=self.p.stock();row=self.order()
        api.initialize_database();api.initialize_database()
        self.assertEqual(self.p.stock(),before);self.assertEqual(self.p.request('GET','/work/orders/'+row['id'])['version'],1)
        with api.connect() as db:self.assertEqual(db.execute('PRAGMA foreign_key_check').fetchall(),[])

    def test_concurrent_reservations_cannot_overbook_and_receipts_are_private(self):
        from concurrent.futures import ThreadPoolExecutor
        self.p.opening(quantity='10');first=self.order(stop_machine=False);second=self.order(stop_machine=False)
        def reserve(order):
            body={'id':str(uuid4()),'expected_version':1,'input_id':self.p.diesel,'quantity':'8'}
            response=self.p.http.post('/api/v2/work/orders/'+order['id']+'/reserve',json=body,headers=self.p.tokens['admin'])
            return response.status_code,body['id']
        with ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(reserve,[first,second]))
        self.assertEqual(sorted(r[0] for r in results),[200,409]);self.assertEqual(self.p.stock()['quantity'],'10')
        confirmed=next(id for status,id in results if status==200)
        self.assertTrue(self.p.request('GET','/work/receipts/'+confirmed)['confirmed'])
        self.p.request('GET','/work/receipts/'+confirmed,user='mechanic',expected=404)

    def test_unpriced_parts_and_labor_remain_unknown_in_maintenance_total(self):
        self.p.opening(quantity='10',value=None);row=self.order()
        row=self.p.post('/work/orders/'+row['id']+'/progress',self.progress(row),user='mechanic')
        self.p.post('/work/orders/'+row['id']+'/progress',self.progress(row,'completed',machine_released=True,
          parts=[{'input_id':self.p.diesel,'quantity':'2'}],labor_hours='1'),user='mechanic')
        result=self.p.request('GET','/work/orders/'+row['id'])['registered_cost']
        self.assertEqual(result['status'],'incomplete');self.assertIsNone(result['value']);self.assertEqual(result['missing'],2)
        self.assertIsNone(self.p.stock()['value_cents'])

if __name__=='__main__':unittest.main()
