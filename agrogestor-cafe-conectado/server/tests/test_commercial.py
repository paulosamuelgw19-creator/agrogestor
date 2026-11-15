import json
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch
from uuid import uuid4, uuid5, NAMESPACE_URL
import test_v2_pilot as fixture
from agrogestor_server import commercial as c


class CommercialTests(unittest.TestCase):
    def setUp(self):
        self.p = fixture.PilotTests(); self.p.setUp()
    def tearDown(self): self.p.tearDown()

    def rights(self, **limits):
        with fixture.api.connect() as db:
            value = c.config(db,'org-a')[0]
            value['limits'].update(limits)
            db.execute('INSERT INTO commercial_entitlements VALUES(?,1,?,?,NULL,NULL) ON CONFLICT(farm_id) DO UPDATE SET config_json=excluded.config_json',
                       ('org-a',json.dumps(value),fixture.api.utc_now()))
        return value

    def test_last_slot_concurrent_replay_and_manual_reduction(self):
        p=self.p
        self.rights(machines=2)
        bodies=[{'id':str(uuid4()),'name':'Máquina sintética','hour_meter':'0','property_ids':[p.prop]} for _ in range(2)]
        def submit(b): return p.http.post('/api/v2/machines',json=b,headers=p.tokens['admin'])
        with ThreadPoolExecutor(2) as pool: responses=list(pool.map(submit,bodies))
        self.assertEqual(sorted(r.status_code for r in responses),[200,409])
        winner=next(b for b,r in zip(bodies,responses) if r.status_code==200)
        self.assertEqual(submit(winner).status_code,200)
        self.assertEqual(next(r for r in responses if r.status_code==409).json()['code'],'QUOTA_EXCEEDED')
        self.rights(machines=0)
        p.opening();p.post('/operations',p.operation())
        self.assertEqual(submit(winner).status_code,200)
        self.assertEqual(submit({**winner,'id':str(uuid4())}).status_code,409)
        with fixture.api.connect() as db: self.assertEqual(c.usage(db,'org-a')['machines'],2)

    def test_property_bundle_atomic_archive_and_reactivate(self):
        p=self.p;self.rights(properties=1)
        body={'id':str(uuid4()),'name':'Sem vaga','plots':[{'id':str(uuid4()),'name':'Preservado no rascunho'}]}
        p.post('/properties',body,expected=409)
        with fixture.api.connect() as db:
            self.assertFalse(db.execute('SELECT 1 FROM v2_plots WHERE id=?',(body['plots'][0]['id'],)).fetchone())
        edit=p.property_edit();edit['archived']=True
        p.request('PATCH',f'/properties/{p.prop}',edit)
        p.post('/properties',body)
        edit.update(archived=False,expected_version=2,id=str(uuid4()))
        p.request('PATCH',f'/properties/{p.prop}',edit,expected=409)

    def test_multi_property_machine_archive_and_no_history_loss(self):
        p=self.p;self.rights(machines=1)
        extra=p.post('/properties',{'id':str(uuid4()),'name':'Outra propriedade'})
        with fixture.api.connect() as db:
            db.execute('INSERT INTO v2_machine_properties VALUES(?,?,?)',('org-a',p.machine,extra['id']))
            self.assertEqual(c.usage(db,'org-a')['machines'],1)
        route=f'/api/v1/licensing/machines/{p.machine}/archive'
        self.assertEqual(p.http.patch(route,json={'archived':True,'expected_version':1},headers=p.tokens['worker']).status_code,403)
        for _ in range(2): self.assertEqual(p.http.patch(route,json={'archived':True,'expected_version':1},headers=p.tokens['admin']).status_code,200)
        p.post('/machines',{'id':str(uuid4()),'name':'Nova','hour_meter':'0','property_ids':[p.prop]})
        r=p.http.patch(route,json={'archived':False,'expected_version':2},headers=p.tokens['admin'])
        self.assertEqual(r.json()['code'],'QUOTA_EXCEEDED')

    def test_user_reservations_expiry_accept_and_reactivation(self):
        p=self.p;self.rights(users=6)
        headers=p.tokens['admin']
        def invite(email):return p.http.post('/api/v1/auth/invitations',json={'email':email,'role':'operator'},headers=headers)
        first=invite('new@example.invalid');self.assertEqual(first.status_code,200,first.text)
        self.assertEqual(invite('blocked@example.invalid').status_code,409)
        renewed=invite('new@example.invalid');self.assertEqual(renewed.status_code,200)
        accepted=p.http.post('/api/v1/auth/accept-invitation',json={'email':'new@example.invalid','code':renewed.json()['code'],'displayName':'Novo','password':'TemporarySafePassword2026!'})
        self.assertEqual(accepted.status_code,200,accepted.text)
        with fixture.api.connect() as db:
            self.assertEqual(c.usage(db,'org-a')['users'],6)
            self.assertEqual(c.usage(db,'org-a')['reserved_users'],0)
        r=p.http.patch('/api/v1/auth/users/worker/access',json={'active':False},headers=headers);self.assertEqual(r.status_code,200)
        self.assertEqual(invite('expired@example.invalid').status_code,200)
        self.assertEqual(p.http.patch('/api/v1/auth/users/worker/access',json={'active':True},headers=headers).status_code,409)
        with fixture.api.connect() as db:db.execute("UPDATE invitations SET expires_at='2000-01-01T00:00:00+00:00' WHERE email='expired@example.invalid'")
        self.assertEqual(p.http.patch('/api/v1/auth/users/worker/access',json={'active':True},headers=headers).status_code,200)

    def test_multiple_devices_one_user_quota(self):
        p=self.p;self.rights(devices=6)
        with fixture.api.connect() as db:db.execute('UPDATE users SET password_hash=? WHERE user_id=?',(fixture.api.password_hash.hash('TemporarySafePassword2026!'),'admin'))
        def login(device): return p.http.post('/api/v1/auth/login',json={'email':'admin@example.invalid','password':'TemporarySafePassword2026!','deviceId':device,'deviceName':'Teste'})
        self.assertEqual(login('additional-device').status_code,200)
        self.assertEqual(login('additional-device').status_code,200)
        denied=login('over-device-0001');self.assertEqual(denied.status_code,409,denied.text)
        self.assertEqual(denied.json()['code'],'QUOTA_EXCEEDED')
        with fixture.api.connect() as db:
            self.assertEqual(c.usage(db,'org-a')['users'],5)
            self.assertEqual(c.usage(db,'org-a')['devices'],6)

    def test_tenant_profile_and_commercial_write_rejected(self):
        p=self.p
        self.assertEqual(p.http.get('/api/v1/licensing/plan',headers=p.tokens['worker']).status_code,403)
        self.assertEqual(p.http.put('/api/v1/licensing/plan',json={'limits':{'machines':999}},headers=p.tokens['admin']).status_code,405)
        self.rights(machines=0)
        with fixture.api.connect() as db:
            self.assertIsNone(c.config(db,'org-b')[0]['limits']['machines'])
            self.assertEqual(c.usage(db,'org-b')['machines'],0)

    def test_modules_deny_new_work_preserve_reads_and_unknown_not_zero(self):
        p=self.p;value=self.rights();value['modules']=['properties','fleet','inventory']
        with fixture.api.connect() as db:db.execute('UPDATE commercial_entitlements SET config_json=?',(json.dumps(value),))
        self.assertEqual(p.post('/operations',p.operation(),expected=409)['code'],'MODULE_DISABLED')
        self.assertEqual(p.request('GET','/workspace')['administrator'],True)
        self.assertEqual(p.http.get('/api/v1/licensing/plan',headers=p.tokens['admin']).status_code,200)

    def test_legacy_import_identity_not_counted_twice(self):
        p=self.p
        with fixture.api.connect() as db:
            source='legacy-tractor'
            db.execute('INSERT INTO records VALUES(?,?,?,?,1,0,?)',('org-a','machines',source,json.dumps({'id':source,'name':'Antigo'}),fixture.api.utc_now()))
            mapped=str(uuid5(NAMESPACE_URL,f'agrogestor-v2/org-a/machine/{source}'))
            db.execute('INSERT INTO v2_machines(tenant_id,id,name,hour_meter) VALUES(?,?,?,?)',('org-a',mapped,'Renomeado','0'))
            self.assertEqual(c.usage(db,'org-a')['machines'],2)
            db.execute("UPDATE v2_machines SET archived=1 WHERE id=?",(mapped,))
            self.assertEqual(c.usage(db,'org-a')['machines'],1)

    def test_contract_refresh_outage_and_revision_rollback(self):
        p=self.p;value=self.rights(machines=3)
        class Response:
            def __init__(self,data):self.data=data
            def __enter__(self):return self
            def __exit__(self,*args):pass
            def read(self,*args):return json.dumps(self.data).encode()
        saved=fixture.api.LICENSE_API_BASE;fixture.api.LICENSE_API_BASE='http://127.0.0.1:9999'
        try:
            with patch.dict('os.environ',{'AGROGESTOR_CONTRACT_ORGANIZATION_KEY':'synthetic-key'}):
                value['limits']['machines']=4
                raw={'farm_id':'org-a','revision':2,'contract':value}
                with patch('agrogestor_server.commercial.open_remote',return_value=Response(raw)):
                    self.assertTrue(c.refresh(fixture.api,'org-a'))
                with patch('agrogestor_server.commercial.open_remote',side_effect=OSError('offline')):
                    self.assertFalse(c.refresh(fixture.api,'org-a'))
                with patch('agrogestor_server.commercial.open_remote',return_value=Response({**raw,'revision':1})):
                    self.assertFalse(c.refresh(fixture.api,'org-a'))
                with fixture.api.connect() as db:
                    rights,row=c.config(db,'org-a');self.assertEqual(rights['limits']['machines'],4);self.assertEqual(row['revision'],2)
        finally:fixture.api.LICENSE_API_BASE=saved

    def test_legacy_batches_cannot_bypass_quotas_and_keep_replay(self):
        p=self.p;self.rights(machines=2,implements=1)
        events=[{'eventId':str(uuid4()),'recordId':str(uuid4()),'module':'machines','operation':'upsert','payload':{'name':'Legada'},'baseVersion':0} for _ in range(2)]
        route='/api/v1/sync/push'
        first=p.http.post(route,headers=p.tokens['admin'],json={'events':events})
        self.assertEqual(first.status_code,200,first.text)
        self.assertEqual(len(first.json()['acknowledged']),1)
        self.assertEqual(len(first.json()['rejected']),1)
        self.assertEqual(first.json()['rejected'][0]['code'],'QUOTA_EXCEEDED')
        repeated=p.http.post(route,headers=p.tokens['admin'],json={'events':[events[0]]})
        self.assertEqual(len(repeated.json()['acknowledged']),1)
        with fixture.api.connect() as db:self.assertEqual(c.usage(db,'org-a')['machines'],2)

    def test_unknown_legacy_usage_never_becomes_zero(self):
        p=self.p
        with fixture.api.connect() as db:
            db.execute('INSERT INTO records VALUES(?,?,?,?,1,0,?)',('org-a','clients','broken',json.dumps({'properties':[{'name':'Sem ID'}]}),fixture.api.utc_now()))
            with self.assertRaises(c.CommercialError):c.usage(db,'org-a')
        response=p.http.get('/api/v1/licensing/plan',headers=p.tokens['admin'])
        self.assertEqual(response.status_code,200,response.text)
        self.assertIsNone(response.json()['usage']['properties'])
