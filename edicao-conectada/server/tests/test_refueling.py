import unittest
from uuid import uuid4
import test_v2_pilot as pilot


class RefuelingTests(unittest.TestCase):
    def setUp(self):
        self.p=pilot.PilotTests('test_fictitious_report_matches_hand_calculation');self.p.setUp()
        self.p.grant('worker','employee')
    def tearDown(self):self.p.tearDown()
    def body(self,source='stock',**extra):
        op=self.p.operation();op['inputs']=[]
        op['refuelings']=[{'id':str(uuid4()),'machine_id':self.p.machine,'source':source,
          'input_id':self.p.diesel if source=='stock' else None,'liters':'30','hour_meter':'103',**extra}]
        return op
    def test_stock_refueling_consumes_once_and_report_does_not_duplicate_cost(self):
        self.p.opening();body=self.body()
        first=self.p.post('/operations',body,user='worker')
        self.p.post('/operations',body,user='worker')
        self.assertEqual(len(first['refuelings']),1)
        self.assertNotIn('total_cost_cents',first['refuelings'][0])
        self.assertEqual(self.p.stock()['quantity'],'70')
        report=self.p.report()['metrics']
        self.assertEqual(report['registered_cost']['value'],'54000')
        self.assertEqual(report['refueling_cost']['value'],'18000')
        self.assertEqual(report['refueled_liters']['value'],'30')
        with pilot.api.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM v2_refuelings').fetchone()[0],1)
    def test_external_purchase_does_not_reduce_stock_and_keeps_missing_price_unknown(self):
        self.p.opening();body=self.body('external',unit_price_cents=625,location='Posto FICTÍCIO')
        self.p.post('/operations',body,user='worker')
        self.assertEqual(self.p.stock()['quantity'],'100')
        self.assertEqual(self.p.report()['metrics']['registered_cost']['value'],'54750')
        unknown=self.body('external');unknown['machines']=[];unknown['refuelings'][0]['hour_meter']='103'
        self.p.post('/operations',unknown,user='worker')
        total=self.p.report()['metrics']['registered_cost']
        self.assertIsNone(total['value']);self.assertEqual(total['status'],'incomplete')
        self.assertEqual(total['known_subtotal'],'54750')
    def test_invalid_type_meter_and_duplicate_fuel_roll_back_entire_operation(self):
        self.p.opening();body=self.body(input_id=self.p.foliar)
        self.p.post('/operations',body,user='worker',expected=422)
        body=self.body(hour_meter='104');self.p.post('/operations',body,user='worker',expected=422)
        body=self.body();body['inputs']=[{'input_id':self.p.diesel,'quantity':'30'}]
        self.p.post('/operations',body,user='worker',expected=422)
        body=self.body(liters='101');self.p.post('/operations',body,user='worker',expected=409)
        self.assertEqual(self.p.stock()['quantity'],'100')
        with pilot.api.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM v2_operations').fetchone()[0],0)
            self.assertEqual(db.execute('SELECT hour_meter FROM v2_machines').fetchone()[0],'100')
    def test_scope_and_operator_ownership_are_enforced_on_server(self):
        self.p.opening();body=self.body()
        self.p.post('/operations',body,user='consultant',expected=404)
        row=self.p.post('/operations',body,user='worker')
        self.p.grant('consultant','employee')
        self.p.request('GET','/operations/'+row['id'],user='consultant',expected=404)
        pilot.api.app.dependency_overrides[pilot.api.current_user]=lambda:{'id':'foreign','farmId':'org-b','role':'admin'}
        self.p.request('GET','/operations/'+row['id'],expected=404)
    def test_stock_allocation_rounds_to_exact_debit_and_void_preserves_history(self):
        self.p.opening(quantity='3',value=2)
        machine=str(uuid4());self.p.post('/machines',{'id':machine,'name':'Segundo trator fictício','hour_meter':'0','property_ids':[self.p.prop]})
        body=self.body(liters='1',hour_meter='100');body['machines']=[]
        body['refuelings'].append({'id':str(uuid4()),'machine_id':machine,'source':'stock','input_id':self.p.diesel,'liters':'2','hour_meter':'0'})
        row=self.p.post('/operations',body)
        self.assertEqual(sum(r['total_cost_cents'] for r in row['refuelings']),2)
        self.assertEqual(self.p.report()['metrics']['registered_cost']['value'],'2')
        void=self.p.post('/operations/'+row['id']+'/void',{'id':str(uuid4()),'reason':'Correção fictícia','occurred_on':'2026-01-03'})
        self.assertIsNotNone(void['void']);self.assertEqual(len(void['refuelings']),2)
        self.assertEqual(self.p.stock()['quantity'],'3')
        self.assertEqual(self.p.report()['metrics']['refueled_liters']['status'],'no_data')
    def test_upgrade_and_old_operation_replay_are_compatible(self):
        self.p.opening();old=self.p.operation();self.p.post('/operations',old)
        with pilot.api.connect() as db:
            import json
            db.execute("UPDATE v2_requests SET request_json=? WHERE entity_type='operation'",(json.dumps(old,sort_keys=True,separators=(',',':')),))
        pilot.api.initialize_database();pilot.api.initialize_database()
        self.p.post('/operations',old)
        self.assertEqual(self.p.stock()['quantity'],'70')


if __name__=='__main__':unittest.main()
