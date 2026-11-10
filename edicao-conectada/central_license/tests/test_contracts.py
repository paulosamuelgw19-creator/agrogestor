import unittest
from datetime import timedelta
import test_license_api as fixture


class ContractTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.f=fixture.CentralLicenseTests();await self.f.asyncSetUp()
        for org in ('alpha','beta'):
            r=await self.f.http.post('/checkLicense',headers=self.f.server,json={'farmId':org,'farmName':'Cliente '+org})
            self.assertEqual(r.status_code,200)
    async def asyncTearDown(self):await self.f.asyncTearDown()

    async def current(self,org='alpha'):
        r=await self.f.http.get('/api/v1/admin/contracts/'+org,headers=self.f.admin)
        self.assertEqual(r.status_code,200,r.text);return r.json()

    async def save(self,config,revision=1,confirm=True):
        return await self.f.http.put('/api/v1/admin/contracts/alpha',headers=self.f.admin,
            json={'contract':config,'expected_revision':revision,'reason':'Teste de contratação','confirm_reduction':confirm})

    async def test_independent_customers_revisions_audit_and_compatibility(self):
        a=await self.current();b=await self.current('beta')
        self.assertTrue(all(v is None for v in a['contract']['limits'].values()))
        self.assertIsNone(a['usage']['machines']['used']);self.assertTrue(a['pending'])
        config=a['contract'];config.update(customer_name='Empresa A',plan_name='Personalizado',price_cents=12345)
        config['limits'].update(properties=1,machines=20,users=15,devices=20)
        r=await self.save(config);self.assertEqual(r.status_code,200,r.text)
        self.assertEqual(r.json()['revision'],2)
        self.assertEqual((await self.current('beta'))['contract'],b['contract'])
        self.assertEqual((await self.save(config)).status_code,409)
        self.assertEqual((await self.current())['audit'][0]['admin'],'admin-test')

    async def test_reduction_preview_usage_ack_scope_and_staleness(self):
        a=await self.current()
        key=(await self.f.http.post('/api/v1/admin/contracts/alpha/integration-key',headers=self.f.admin)).json()['key']
        headers={'X-Agrogestor-Organization-Key':key}
        report={'farm_id':'alpha','applied_revision':1,'measured_at':fixture.api.iso(self.f.clock),
                'usage':{'properties':1,'machines':4,'users':3,'devices':4,'implements':0},'server_version':'test'}
        self.assertEqual((await self.f.http.post('/api/v1/contracts/exchange',headers=headers,json=report)).status_code,200)
        a=await self.current();self.assertFalse(a['pending']);self.assertFalse(a['stale'])
        config=a['contract'];config['limits']['machines']=2
        change={'contract':config,'expected_revision':1,'reason':'Redução revisada'}
        preview=await self.f.http.post('/api/v1/admin/contracts/alpha/preview',headers=self.f.admin,json=change)
        self.assertEqual(preview.json()['impact']['machines']['overage'],2)
        self.assertEqual((await self.save(config,confirm=False)).status_code,409)
        self.assertTrue((await self.save(config)).json()['pending'])
        denied=await self.f.http.post('/api/v1/contracts/exchange',headers=headers,json={**report,'farm_id':'beta'})
        self.assertEqual(denied.status_code,401)
        forbidden=await self.f.http.put('/api/v1/admin/contracts/alpha',headers=headers,json=change)
        self.assertEqual(forbidden.status_code,401)
        self.f.clock+=timedelta(days=2)
        # Use fresh admin JWT: advancing the test clock only changes license timestamps.
        self.assertTrue((await self.current())['stale'])

    async def test_modules_strict_limits_dates_and_money(self):
        base=(await self.current())['contract']
        for patch in ({'modules':['properties','tasks']},{'modules':['operations']},{'modules':['invented']},{'price_cents':1.5},
                      {'limits':{**base['limits'],'machines':True}},{'expires_at':base['starts_at']},
                      {'starts_at':'2026-01-01T00:00:00'}):
            self.assertEqual((await self.save({**base,**patch})).status_code,422)

    async def test_aggregate_exchange_rejects_operational_payload(self):
        await self.current()
        key=(await self.f.http.post('/api/v1/admin/contracts/alpha/integration-key',headers=self.f.admin)).json()['key']
        report={'farm_id':'alpha','applied_revision':1,'measured_at':fixture.api.iso(self.f.clock),
                'usage':{'properties':1,'machines':4,'users':3,'devices':4,'implements':0},'server_version':'test', 'photos':['private']}
        self.assertEqual((await self.f.http.post('/api/v1/contracts/exchange',headers={'X-Agrogestor-Organization-Key':key},json=report)).status_code,422)

    async def test_templates_are_snapshots_and_never_change_clients(self):
        a=await self.current();base=a['contract']
        body={'contract':base,'expected_revision':0,'reason':'Modelo opcional'}
        saved=await self.f.http.put('/api/v1/admin/contract-templates/custom',headers=self.f.admin,json=body)
        self.assertEqual(saved.status_code,200,saved.text)
        body['expected_revision']=1;body['contract']={**base,'plan_name':'Modelo alterado'}
        self.assertEqual((await self.f.http.put('/api/v1/admin/contract-templates/custom',headers=self.f.admin,json=body)).status_code,200)
        self.assertEqual((await self.current())['contract'],base)
        self.assertEqual((await self.f.http.get('/api/v1/admin/contract-templates',headers=self.f.admin)).json()['items'][0]['revision'],2)

    async def test_explicit_contract_validity_updates_license_without_automatic_renewal(self):
        original=(await self.current())['contract'];expiry=original['expires_at']
        original['limits']['machines']=10
        self.assertEqual((await self.save(original)).status_code,200)
        checked=await self.f.http.post('/checkLicense',headers=self.f.server,json={'farmId':'alpha'})
        self.assertEqual(checked.json()['expiresAt'],expiry)
        original['status']='suspended'
        self.assertEqual((await self.save(original,revision=2)).status_code,200)
        self.assertEqual((await self.f.http.post('/checkLicense',headers=self.f.server,json={'farmId':'alpha'})).json()['status'],'inactive')

    async def test_legacy_license_renewal_updates_compatibility_without_custom_override(self):
        await self.current()
        path='/api/v1/admin/farms/alpha/license'
        first=await self.f.http.post(path,headers=self.f.admin,json={'action':'activate','plan':'monthly'})
        self.assertEqual(first.status_code,200,first.text)
        renewal=await self.f.http.post(path,headers=self.f.admin,json={'action':'renew'})
        self.assertEqual(renewal.status_code,200,renewal.text)
        current=await self.current()
        self.assertEqual(current['revision'],3)
        self.assertEqual(current['contract']['expires_at'],renewal.json()['expiresAt'])
        self.assertEqual(current['contract']['status'],'active')
        config=current['contract'];config['limits']['machines']=10
        self.assertEqual((await self.save(config,revision=3)).status_code,200)
        self.assertEqual((await self.f.http.post(path,headers=self.f.admin,json={'action':'renew'})).status_code,409)

    async def test_registration_validates_unique_organization(self):
        path='/api/v1/admin/contracts'
        first=await self.f.http.post(path,headers=self.f.admin,json={'farm_id':'new-org','customer_name':'Cliente sintético'})
        self.assertEqual(first.status_code,200,first.text)
        self.assertEqual(first.json()['revision'],1)
        self.assertEqual((await self.f.http.post(path,headers=self.f.admin,json={'farm_id':'new-org','customer_name':'Outro'})).status_code,409)
        self.assertEqual((await self.f.http.post(path,headers=self.f.admin,json={'farm_id':'bad/id','customer_name':'Inválido'})).status_code,400)
