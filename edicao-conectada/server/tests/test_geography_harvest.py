import json
import unittest
from decimal import Decimal
import test_v2_pilot as fixture
from agrogestor_server.geography import area_ha


class GeographyHarvestTests(unittest.TestCase):
    def setUp(self):
        self.p = fixture.PilotTests(); self.p.setUp()
    def tearDown(self): self.p.tearDown()
    def boundary(self, points=None, version=0, **extra):
        return {'id':fixture.identity(),'expected_version':version,
                'points':points if points is not None else [[-46,-21],[-45.99,-21],[-45.99,-20.99],[-46,-20.99]],
                'reason':'Desenho sintético de teste',**extra}

    def test_geodesic_area_invalid_geometry_bounds_and_orientation(self):
        p=self.p; path=f'/maps/property/{p.prop}'
        body=self.boundary(); result=p.post(path,body)
        self.assertTrue(114 < Decimal(result['area_ha']) < 116)
        self.assertEqual(result['area_ha'],area_ha(list(reversed(body['points']))))
        self.assertEqual(p.post(path,body)['version'],1)
        self.assertEqual(p.request('GET',f'/properties/{p.prop}/map')['property']['area_ha'],'10')
        for points in [[[-46,-21],[-45.99,-20.99],[-46,-20.99],[-45.99,-21]],
                       [[-46,91],[-45,20],[-46,21]],[[0,0],[1,1],[2,2]],
                       [[-179,0],[179,1],[179,0]]]:
            p.post(path,self.boundary(points,1),expected=422)
        p.post(path,self.boundary(version=0),expected=409)
        self.assertEqual(p.request('GET',f'/properties/{p.prop}/map')['boundaries'][0]['version'],1)

    def test_containment_deletion_audit_recreation_and_no_history_loss(self):
        p=self.p
        p.post(f'/maps/property/{p.prop}',self.boundary())
        path=f'/maps/plot/{p.plot}'
        inside=[[-45.999,-20.999],[-45.998,-20.999],[-45.998,-20.998],[-45.999,-20.998]]
        body=self.boundary(inside);p.post(path,body)
        outside=[[-47,-21],[-46.9,-21],[-46.9,-20.9],[-47,-20.9]]
        p.post(path,self.boundary(outside,1),expected=422)
        p.post(path,self.boundary([],1,deleted=True))
        data=p.request('GET',f'/properties/{p.prop}/map')
        removed=next(b for b in data['boundaries'] if b['target_kind']=='plot')
        self.assertEqual(removed['points'],inside)
        self.assertEqual(removed['deleted'],1)
        self.assertEqual(p.post(path,self.boundary(inside,2))['version'],3)
        with fixture.api.connect() as db:
            self.assertEqual(db.execute('PRAGMA foreign_key_check').fetchall(),[])
            self.assertEqual(db.execute("SELECT COUNT(*) FROM v2_audit WHERE action IN ('save-boundary','remove-boundary')").fetchone()[0],4)

    def test_permission_isolation_plot_history_no_financial_leak(self):
        p=self.p
        p.request('GET',f'/properties/{p.prop}/map',user='worker',expected=404)
        p.grant('worker','employee');p.grant('consultant','consultant')
        p.post(f'/maps/property/{p.prop}',self.boundary(),user='worker')
        p.post(f'/maps/property/{p.prop}',self.boundary(version=1),user='consultant',expected=403)
        p.opening();op=p.operation();p.post('/operations',op,user='worker')
        own=p.request('GET',f'/plots/{p.plot}/operations',user='worker')['items']
        self.assertEqual(len(own),1);self.assertNotIn('cost_cents',own[0]['machines'][0])
        self.assertEqual(p.request('GET',f'/plots/{p.plot}/operations',user='consultant')['items'],[])
        p.grant('worker',None)
        p.request('GET',f'/plots/{p.plot}/operations',user='worker',expected=404)
        fixture.api.app.dependency_overrides[fixture.api.current_user]=lambda:{'id':'other','farmId':'org-b','role':'admin'}
        p.request('GET',f'/properties/{p.prop}/map',expected=404)

    def test_harvest_conversions_unknown_zero_filters_replay_and_void(self):
        p=self.p
        base={'id':fixture.identity(),'cycle_id':p.cycle,'kind':'harvest','performed_on':'2026-02-01','area_ha':'3',
              'harvest_output':{'quantity':'20','unit':'saca','kg_per_unit':'60'}}
        p.post('/operations',base);p.post('/operations',base)
        report=p.request('GET','/admin/reports/production')['harvest'][0]
        self.assertEqual(report['production_kg']['value'],'1200')
        self.assertEqual(report['production_per_registered_ha']['value'],'120')
        p.post('/operations',{**base,'id':fixture.identity(),'harvest_output':{'quantity':'0','unit':'kg'},'performed_on':'2026-02-02'})
        p.post('/operations',{**base,'id':fixture.identity(),'harvest_output':None,'performed_on':'2026-02-03'})
        report=p.request('GET','/admin/reports/production')['harvest'][0]
        self.assertIsNone(report['production_kg']['value'])
        self.assertEqual(report['production_kg']['known_subtotal'],'1200')
        self.assertEqual(report['missing_outputs'],1)
        filtered=p.request('GET','/admin/reports/production?ends_on=2026-02-02')['harvest'][0]
        self.assertEqual(filtered['production_kg']['value'],'1200')
        p.request('GET','/admin/reports/production',user='worker',expected=403)
        p.post(f'/operations/{base["id"]}/void',{'id':fixture.identity(),'reason':'Correção teste','occurred_on':'2026-02-04'})
        self.assertEqual(p.request('GET','/admin/reports/production?ends_on=2026-02-02')['harvest'][0]['production_kg']['value'],'0')
        p.post('/operations',{**base,'id':fixture.identity(),'kind':'planting'},expected=422)

    def test_unweighed_units_never_converted_or_counted_as_zero(self):
        p=self.p
        p.post('/operations',{'id':fixture.identity(),'cycle_id':p.cycle,'kind':'harvest','performed_on':'2026-01-02',
          'harvest_output':{'quantity':'5','unit':'caixa'}})
        result=p.request('GET','/admin/reports/production')['harvest'][0]
        self.assertIsNone(result['production_kg']['value'])
        self.assertEqual(result['quantities_by_unit'],[{'unit':'caixa','quantity':'5'}])
        self.assertIsNone(result['production_per_registered_ha']['value'])

    def test_implement_history_keeps_snapshot_and_never_duplicates_costs(self):
        p=self.p;identity=fixture.identity()
        with fixture.api.connect() as db:
            db.execute('INSERT INTO records VALUES(?,?,?,?,1,0,?)',('org-a','implements',identity,json.dumps({'id':identity,'name':'Grade sintética','active':True}),fixture.api.utc_now()))
        p.opening();body={**p.operation(),'implement_ids':[identity]}
        result=p.post('/operations',body)
        self.assertEqual(result['implements'][0]['name'],'Grade sintética')
        p.post('/operations',body)
        report=p.request('GET','/admin/reports/implements')
        total=p.request('GET','/admin/reports/operations')['metrics']['registered_cost']['value']
        self.assertEqual(report['metrics']['registered_cost']['value'],total)
        self.assertEqual(report['implements'][0]['operation_ids'],[body['id']])
        with fixture.api.connect() as db:
            db.execute("UPDATE records SET deleted=1 WHERE module='implements'")
        self.assertEqual(p.request('GET',f'/operations/{body["id"]}')['implements'][0]['name'],'Grade sintética')
        p.post('/operations',{**body,'id':fixture.identity(),'machines':[],'inputs':[]},expected=422)

    def test_catalog_photos_require_entity_access_are_private_and_idempotent(self):
        import base64
        p=self.p;p.grant('worker','employee')
        key=fixture.identity();path=f'/api/v2/work/machine/{p.machine}/photos/{key}'
        image=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/j18AAAAASUVORK5CYII=')
        def upload(user='admin',data=image):
            return p.http.put(path,headers=p.tokens[user],files={'file':('photo.png',data,'image/png')})
        self.assertEqual(upload().status_code,200)
        self.assertEqual(upload().status_code,200)
        self.assertEqual(upload(data=image+b'changed').status_code,409)
        self.assertEqual(p.http.get(path,headers=p.tokens['worker']).content,image)
        self.assertEqual(p.http.get(path,headers=p.tokens['consultant']).status_code,404)
        self.assertEqual(upload('consultant').status_code,404)
        p.grant('consultant','consultant')
        self.assertFalse(p.request('GET',f'/work/machine/{p.machine}/photos',user='consultant')['can_edit'])
        self.assertEqual(upload('consultant').status_code,404)
        listing=p.request('GET',f'/work/machine/{p.machine}/photos',user='worker')
        self.assertEqual(len(listing['items']),1)
        self.assertNotIn('path',listing['items'][0])
        p.grant('worker',None)
        self.assertEqual(p.http.get(path,headers=p.tokens['worker']).status_code,404)


if __name__=='__main__':unittest.main()
