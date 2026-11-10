import unittest
from concurrent.futures import ThreadPoolExecutor
from uuid import uuid4
import test_v2_pilot as pilot


def identity(): return str(uuid4())


class ManagementTests(unittest.TestCase):
    def setUp(self):
        self.p = pilot.PilotTests(); self.p.setUp()
    def tearDown(self): self.p.tearDown()

    def test_farm_bundle_optional_responsible_atomic_and_retry(self):
        p = self.p
        body = {'id':identity(),'name':'Fazenda São José','area_ha':'100',
            'plots':[{'id':identity(),'name':f'Talhão {i+1}','area_ha':str(n),'notes':'Cadastro inicial'} for i,n in enumerate([20,30,25,25])]}
        first = p.post('/properties',body)
        self.assertIsNone(first['responsible_user_id'])
        self.assertEqual(p.post('/properties',body),first)
        self.assertEqual(len(p.request('GET',f"/properties/{body['id']}/plots")['items']),4)
        invalid = {**body,'id':identity(),'plots':[{'id':identity(),'name':'Excesso','area_ha':'101'}]}
        p.post('/properties',invalid,expected=422)
        p.request('GET',f"/properties/{invalid['id']}/plots",expected=404)
        wrong = {**body,'id':identity(),'responsible_user_id':'outro-cliente','plots':[]}
        p.post('/properties',wrong,expected=422)
        valid = {**wrong,'id':identity(),'responsible_user_id':'worker'}
        self.assertEqual(p.post('/properties',valid)['responsible_name'],'worker')
        with pilot.api.connect() as db:
            self.assertEqual(db.execute('PRAGMA foreign_key_check').fetchall(),[])

    def test_admin_reports_protected_even_with_property_manager_grant(self):
        p = self.p; p.grant('worker','manager')
        for path in ['/admin/reports/options','/admin/reports/overview',f'/cycles/{p.cycle}/report']:
            p.request('GET',path,user='worker',expected=403)

    def test_program_cumulative_unique_area_retry_conflict_rework_and_void(self):
        p = self.p
        program = {'id':identity(),'title':'Colheita','season_name':'Café 2026','activity':'harvest',
            'plots':[{'cycle_id':p.cycle,'planned_ha':'10'}]}
        p.post('/activity-plans',program); p.post('/activity-plans',program)
        op = {'id':identity(),'cycle_id':p.cycle,'kind':'harvest','performed_on':'2026-01-03',
            'area_ha':'7.5','plan_id':program['id'],'plan_expected_version':1,'coverage_total_ha':'7.5',
            'consumed_fuel_liters':'0','started_at':'2026-01-03T08:00:00-03:00','ended_at':'2026-01-03T10:00:00-03:00'}
        p.post('/operations',op); p.post('/operations',op)
        progress = p.request('GET','/activity-plans')['items'][0]
        self.assertEqual(progress['percent'],'75'); self.assertEqual(progress['version'],2)
        p.post('/operations',{**op,'id':identity()},expected=409)
        rework = {**op,'id':identity(),'area_ha':'1','plan_expected_version':2}
        p.post('/operations',rework)
        self.assertEqual(p.request('GET','/activity-plans')['items'][0]['percent'],'75')
        p.post(f"/operations/{op['id']}/void",{'id':identity(),'reason':'Correção','occurred_on':'2026-01-04'},expected=409)
        p.post(f"/operations/{rework['id']}/void",{'id':identity(),'reason':'Correção','occurred_on':'2026-01-04'})
        self.assertEqual(p.request('GET','/activity-plans')['items'][0]['percent'],'75')
        p.post(f"/operations/{op['id']}/void",{'id':identity(),'reason':'Correção final','occurred_on':'2026-01-04'})
        self.assertEqual(p.request('GET','/activity-plans')['items'][0]['percent'],'0')

    def test_ledger_stock_fuel_external_and_missing_costs(self):
        p=self.p;p.opening()
        op=p.operation();op['inputs']=[]
        op['refuelings']=[{'id':identity(),'machine_id':p.machine,'source':'stock','input_id':p.diesel,'liters':'10','hour_meter':'103'},
            {'id':identity(),'machine_id':p.machine,'source':'external','liters':'5','hour_meter':'103','unit_price_cents':700}]
        p.post('/operations',op)
        report=p.request('GET','/admin/reports/costs')
        self.assertEqual(report['categories']['Combustível']['value'],'9500')
        self.assertEqual(report['categories']['Máquinas']['value'],'36000')
        self.assertEqual(report['metrics']['registered_cost']['value'],'45500')
        self.assertIsNone(report['metrics']['consumed_fuel']['value'])
        self.assertEqual(len(report['ledger']),3)
        filtered=p.request('GET',f'/admin/reports/plots?property_id={p.prop}&plot_id={p.plot}&cycle_id={p.cycle}&starts_on=2026-01-01&ends_on=2026-01-31')
        self.assertEqual(len(filtered['operations']),1)
        p.request('GET','/admin/reports/costs?starts_on=2026-02-01&ends_on=2026-01-01',expected=422)

    def test_stock_item_opening_minimum_equal_alert_idempotent(self):
        p=self.p
        body={'id':identity(),'name':'Diesel novo','unit':'L','category':'Combustíveis e lubrificantes','product_type':'Diesel',
            'property_id':p.prop,'quantity':'100','minimum_quantity':'100','value_cents':60000,'occurred_on':'2026-01-01','notes':'Tanque central'}
        p.post('/admin/stock-items',body);p.post('/admin/stock-items',body)
        report=p.request('GET','/admin/reports/stock')
        self.assertTrue(report['stock'][0]['low_stock'])
        self.assertEqual(report['stock'][0]['available_quantity'],'100')
        p.post('/admin/stock-items',{**body,'id':identity(),'unit':'kg'},expected=422)
        p.post('/admin/stock-items',{**body,'id':identity()},user='worker',expected=403)
        with pilot.api.connect() as db:
            self.assertEqual(db.execute('PRAGMA integrity_check').fetchone()[0],'ok')
            self.assertEqual(db.execute('PRAGMA foreign_key_check').fetchall(),[])

    def test_season_activities_stay_separate_and_forecast_is_explicit_estimate(self):
        p=self.p
        ids=[]
        for activity in ['harvest','application']:
            plan={'id':identity(),'title':activity,'season_name':'Café 2026','activity':activity,'plots':[{'cycle_id':p.cycle,'planned_ha':'10'}]}
            p.post('/activity-plans',plan);ids.append(plan['id'])
        for index,(day,total) in enumerate([('2026-01-01','2'),('2026-01-02','5')]):
            p.post('/operations',{'id':identity(),'cycle_id':p.cycle,'kind':'harvest','performed_on':day,
                'plan_id':ids[0],'plan_expected_version':index+1,'coverage_total_ha':total,'area_ha':'3'})
        report=p.request('GET','/admin/reports/season')
        groups={g['activity']:g for g in report['programs']}
        self.assertEqual(groups['harvest']['percent'],'50')
        self.assertEqual(groups['application']['percent'],'0')
        self.assertEqual(groups['harvest']['forecast']['type'],'estimate')
        self.assertEqual(groups['harvest']['forecast']['completion_date'],'2026-01-04')
        self.assertIsNone(groups['application']['forecast'])
        p.post('/activity-plans',{'id':identity(),'title':'Duplicado','season_name':'Café 2026','activity':'harvest',
            'plots':[{'cycle_id':p.cycle,'planned_ha':'10'}]},expected=409)

    def test_two_devices_cannot_overwrite_same_progress_revision(self):
        p=self.p
        plan={'id':identity(),'title':'Colheita','season_name':'2026','activity':'harvest','plots':[{'cycle_id':p.cycle,'planned_ha':'10'}]}
        p.post('/activity-plans',plan)
        bodies=[{'id':identity(),'cycle_id':p.cycle,'kind':'harvest','performed_on':'2026-01-03','plan_id':plan['id'],
            'plan_expected_version':1,'coverage_total_ha':'5'} for _ in range(2)]
        def send(body):return p.http.post('/api/v2/operations',json=body,headers=p.tokens['admin']).status_code
        with ThreadPoolExecutor(max_workers=2) as pool: statuses=list(pool.map(send,bodies))
        self.assertEqual(sorted(statuses),[200,409])
        self.assertEqual(p.request('GET','/activity-plans')['items'][0]['completed_ha'],'5')
        p.request('GET','/admin/reports/costs?property_id='+identity(),expected=404)

    def test_hectare_denominator_respects_cycle_filter(self):
        p=self.p
        other=p.post('/properties',{'id':identity(),'name':'Outra fazenda','area_ha':'100'})
        p.post('/plots',{'id':identity(),'name':'Outro talhão','area_ha':'100','property_id':other['id']})
        p.opening();p.post('/operations',p.operation())
        report=p.request('GET','/admin/reports/costs?cycle_id='+p.cycle)
        self.assertEqual(report['metrics']['registered_plot_area']['value'],'10')
        self.assertEqual(report['metrics']['cost_per_cycle_ha']['value'],'5400')
        self.assertEqual(len(report['properties']),1)


class ManagementWorkshopTests(unittest.TestCase):
    def setUp(self):
        from test_workflows import WorkTests
        self.w=WorkTests();self.w.setUp();self.p=self.w.p
    def tearDown(self): self.w.tearDown()

    def test_parts_labor_and_service_are_counted_once_and_stay_general_property(self):
        p=self.p
        part=identity();p.post('/inputs',{'id':part,'name':'Filtro','unit':'un','category':'Peças e materiais de máquinas e implementos'})
        p.opening(part,'100',60000)
        order=self.w.order()
        body=self.w.progress(order,parts=[{'input_id':part,'quantity':'2'}],labor_hours='1',labor_cost_cents=500,service_cost_cents=300)
        path='/work/orders/'+order['id']+'/progress'
        p.post(path,body,user='mechanic');p.post(path,body,user='mechanic')
        report=p.request('GET','/admin/reports/maintenance?mechanic_id=mechanic')
        self.assertEqual(report['metrics']['registered_cost']['value'],'2000')
        self.assertEqual(report['categories']['Manutenção']['value'],'1500')
        self.assertEqual(report['categories']['Mão de obra']['value'],'500')
        self.assertEqual(len(report['ledger']),3)
        self.assertEqual(len(report['maintenance'][0]['parts']),1)
        field=p.request('GET','/admin/reports/plots?plot_id='+p.plot)
        self.assertIsNone(field['metrics']['registered_cost']['value'])
        p.request('GET','/admin/reports/maintenance',user='mechanic',expected=403)

    def test_explicit_labor_cost_is_private_and_unknown_hours_do_not_become_zero(self):
        p=self.p
        op={'id':identity(),'cycle_id':p.cycle,'kind':'management','performed_on':'2026-01-03','labor_cost_cents':1234}
        p.post('/operations',op,user='worker',expected=403)
        p.post('/operations',op)
        report=p.request('GET','/admin/reports/costs')
        self.assertEqual(report['categories']['Mão de obra']['value'],'1234')
        self.assertEqual(report['metrics']['registered_cost']['value'],'1234')
        own={**op,'id':identity(),'labor_hours':'1','labor_cost_cents':None}
        result=p.post('/operations',own,user='worker')
        self.assertNotIn('labor_cost_cents',result['measurements'])
        report=p.request('GET','/admin/reports/costs')
        self.assertIsNone(report['metrics']['registered_cost']['value'])
        self.assertEqual(report['metrics']['registered_cost']['known_subtotal'],'1234')

    def test_stock_report_respects_preexisting_workshop_reservations(self):
        p=self.p;p.opening(quantity='50',value=30000)
        order=self.w.order()
        p.post('/work/orders/'+order['id']+'/reserve',{'id':identity(),'expected_version':order['version'],'input_id':p.diesel,'quantity':'5'})
        p.post('/work/stock-limits',{'id':identity(),'property_id':p.prop,'input_id':p.diesel,'minimum_quantity':'46'})
        row=p.request('GET','/admin/reports/stock?property_id='+p.prop)['stock'][0]
        self.assertEqual(row['quantity'],'50');self.assertEqual(row['available_quantity'],'45')
        self.assertTrue(row['low_stock'])
        work=p.request('GET','/work/workspace')['stock'][0]
        self.assertEqual(row['available_quantity'],work['available_quantity'])
