"""Pilot integration tests use only temporary databases and fictitious identities."""
import atexit
import json
import os
import re
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal
from uuid import uuid4

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
_bootstrap = tempfile.TemporaryDirectory(prefix='agro-v2-bootstrap-')
atexit.register(_bootstrap.cleanup)
os.environ['AGROGESTOR_CONTRACT_API_BASE'] = ''
os.environ['AGROGESTOR_CONTRACT_ORGANIZATION_KEY'] = ''
os.environ.setdefault('AGROGESTOR_DATA_DIR', _bootstrap.name)
os.environ.setdefault('AGROGESTOR_JWT_SECRET', 'synthetic-test-secret-at-least-32-characters')
from fastapi.testclient import TestClient
from agrogestor_server import app as api
from agrogestor_server import v2_schema
from agrogestor_server.logistics_schema import STATEMENTS as LOGISTICS_STATEMENTS
from agrogestor_server.v2_metrics import metric, stock_balance, consumption_value


def identity():
    return str(uuid4())


class PilotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='agro-v2-test-')
        self.saved = {key: getattr(api, key) for key in ('DATA_DIR', 'DB_PATH', 'ATTACHMENTS_DIR', 'V2_ENABLED', 'LICENSE_API_BASE', 'LICENSE_API_KEY', 'LICENSE_PROVIDER')}
        api.DATA_DIR = Path(self.temp.name)
        api.DB_PATH = api.DATA_DIR / 'test.sqlite3'
        api.ATTACHMENTS_DIR = api.DATA_DIR / 'attachments'
        api.V2_ENABLED = True
        api.LICENSE_API_BASE = api.LICENSE_API_KEY = ''
        api.LICENSE_PROVIDER = 'local'
        api.initialize_database()
        with api.connect() as db:
            db.execute("INSERT INTO farm VALUES(1,'org-a','Organização fictícia')")
            for user, role in [('admin', 'admin'), ('worker', 'operator'), ('consultant', 'operator'), ('owner', 'operator'), ('manager', 'operator')]:
                db.execute('''INSERT INTO users(user_id,farm_id,email,display_name,role,password_hash,created_at)
                  VALUES(?,'org-a',?,?,?,'unused',?)''', (user, user + '@example.invalid', user, role, api.utc_now()))
                db.execute('''INSERT INTO devices(farm_id,device_id,device_name,activated_by,activated_at,last_seen_at)
                  VALUES('org-a',?,?,?, ?,?)''', ('device-' + user, 'Synthetic', user, api.utc_now(), api.utc_now()))
        self.http = TestClient(api.app)
        self.tokens = {user: {'Authorization': 'Bearer ' + api.make_token(user, 'org-a', 'device-' + user)}
                       for user in ['admin', 'worker', 'consultant', 'owner', 'manager']}
        self.client_id, self.prop, self.plot, self.crop, self.cycle, self.machine, self.diesel, self.foliar = [identity() for _ in range(8)]
        self.post('/clients', {'id': self.client_id, 'name': 'Cliente fictício'})
        self.post('/properties', {'id': self.prop, 'client_id': self.client_id, 'name': 'Fazenda fictícia', 'area_ha': '10'})
        self.post('/plots', {'id': self.plot, 'property_id': self.prop, 'name': 'Talhão fictício', 'area_ha': '10'})
        self.post('/crops', {'id': self.crop, 'name': 'Café', 'kind': 'coffee'})
        self.post('/cycles', {'id': self.cycle, 'name': 'Safra fictícia 2026', 'plot_id': self.plot,
                             'crop_id': self.crop, 'area_ha': '10', 'starts_on': '2026-01-01', 'ends_on': '2026-12-31'})
        self.post('/machines', {'id': self.machine, 'name': 'Trator fictício', 'hour_meter': '100',
                               'hourly_cost_cents': 12000, 'property_ids': [self.prop]})
        for key, name in [(self.diesel, 'Diesel'), (self.foliar, 'Foliar')]:
            self.post('/inputs', {'id': key, 'name': name, 'unit': 'L'})

    def tearDown(self):
        self.http.close()
        api.app.dependency_overrides.clear()
        for key, value in self.saved.items():
            setattr(api, key, value)
        self.temp.cleanup()

    def request(self, method, path, body=None, user='admin', expected=200):
        response = self.http.request(method, '/api/v2' + path, json=body, headers=self.tokens[user])
        self.assertEqual(response.status_code, expected, response.text)
        return response.json()

    def post(self, path, body, user='admin', expected=200):
        return self.request('POST', path, body, user, expected)

    def grant(self, user, role):
        return self.request('PUT', f'/properties/{self.prop}/access', {'user_id': user, 'role': role})

    def opening(self, input_id=None, quantity='100', value=60000, day='2026-01-01'):
        return self.post(f'/properties/{self.prop}/inventory', {'id': identity(), 'input_id': input_id or self.diesel,
                         'kind': 'opening', 'quantity': quantity, 'value_cents': value, 'occurred_on': day})

    def operation(self, start='100', end='103', quantity='30', day='2026-01-03'):
        return {'id': identity(), 'cycle_id': self.cycle, 'kind': 'application', 'performed_on': day,
                'area_ha': '10', 'machines': [{'machine_id': self.machine, 'start_meter': start, 'end_meter': end}],
                'inputs': [{'input_id': self.diesel, 'quantity': quantity}]}

    def stock(self, input_id=None, user='admin'):
        return self.request('GET', f'/properties/{self.prop}/inventory/{input_id or self.diesel}', user=user)

    def report(self, query='', user='admin'):
        return self.request('GET', f'/cycles/{self.cycle}/report' + query, user=user)

    def test_product_classification_uses_same_inventory_and_operation(self):
        product = {'id': identity(), 'name': 'Adubo fictício', 'unit': 'kg',
                   'category': 'Químicos e minerais', 'product_type': 'Fertilizantes e adubos minerais'}
        self.assertEqual(self.post('/inputs', product)['category'], product['category'])
        self.opening(product['id'], '10', 10000)
        operation = self.operation()
        operation['machines'] = []
        operation['inputs'] = [{'input_id': product['id'], 'quantity': '2'}]
        self.post('/operations', operation)
        self.assertEqual(self.stock(product['id'])['quantity'], '8')
        self.grant('worker', 'employee')
        snapshot = self.request('GET', f'/workspace?property_id={self.prop}', user='worker')
        self.assertEqual(snapshot['inputs'][0]['product_type'], product['product_type'])
        self.assertNotIn('value_cents', snapshot['inventory'][0])
        self.post('/inputs', {**product, 'id': identity()}, user='worker', expected=403)
        self.request('GET', '/workspace?property_id=' + identity(), user='worker', expected=404)

    def test_edit_product_audits_metadata_preserves_stock_and_conflicts(self):
        self.opening()
        body = {'id': identity(), 'name': 'Diesel revisado', 'category': 'Combustíveis e lubrificantes',
                'product_type': 'Diesel', 'expected_name': 'Diesel',
                'expected_category': '', 'expected_product_type': ''}
        path = f'/inputs/{self.diesel}'
        self.request('PATCH', path, body, user='worker', expected=403)
        result = self.request('PATCH', path, body)
        self.assertEqual(result['product_type'], 'Diesel')
        self.request('PATCH', path, body)  # idempotent retry
        self.request('PATCH', path, {**body, 'id': identity()}, expected=409)
        self.request('PATCH', path, {**body, 'id': identity(), 'unit': 'kg'}, expected=422)
        self.assertEqual(self.stock()['quantity'], '100')
        self.assertEqual(self.stock()['value_cents'], 60000)
        with api.connect() as db:
            row = db.execute("SELECT * FROM v2_audit WHERE action='update' AND entity_type='input'").fetchone()
            self.assertEqual(row['actor_id'], 'admin')
            self.assertEqual(json.loads(row['before_json'])['name'], 'Diesel')

    def test_classification_migration_preserves_old_input_stock_and_retries(self):
        self.opening()
        with api.connect() as db:
            db.execute('ALTER TABLE v2_inputs DROP COLUMN category')
            db.execute('ALTER TABLE v2_inputs DROP COLUMN product_type')
            db.execute('DELETE FROM v2_migrations WHERE version=3')
            previous = {'id': self.diesel, 'name': 'Diesel', 'unit': 'L'}
            db.execute("UPDATE v2_requests SET request_json=? WHERE entity_type='input' AND entity_id=?",
                       (json.dumps(previous), self.diesel))
        api.initialize_database()
        api.initialize_database()
        self.assertEqual(self.post('/inputs', previous)['category'], '')
        self.assertEqual(self.stock()['quantity'], '100')
        self.assertEqual(self.stock()['value_cents'], 60000)
        with api.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM v2_inputs').fetchone()[0], 2)
            self.assertEqual(db.execute('SELECT COUNT(*) FROM v2_migrations').fetchone()[0], 11)

    def test_unified_products_reject_parallel_legacy_inventory_writes(self):
        event = {'eventId': identity(), 'recordId': identity(), 'module': 'products',
                 'operation': 'upsert', 'baseVersion': 0, 'payload': {'name': 'Duplicado'}}
        response = self.http.post('/api/v1/sync/push', headers=self.tokens['admin'], json={'events': [event]})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(len(response.json()['rejected']), 1)
        with api.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM records WHERE module='products'").fetchone()[0], 0)

    def test_product_import_keeps_classification_without_inventing_stock(self):
        from agrogestor_server.v2_import import build_plan
        original = {'name': 'Produto antigo', 'unit': 'kg', 'category': 'Categoria antiga',
                    'productType': 'Tipo antigo', 'quantity': 250, 'lot': 'Lote A'}
        rows = [{'module': 'products', 'record_id': 'old-product', 'payload': json.dumps(original)}]
        plan = build_plan(rows, 'org-a')
        imported = plan['requests'][0]['body']
        self.assertEqual(imported['category'], original['category'])
        self.assertEqual(imported['product_type'], original['productType'])
        self.assertNotIn('quantity', imported)
        self.assertEqual(plan['mapping'], build_plan(rows, 'org-a')['mapping'])

    def property_edit(self, **changes):
        return {'id': identity(), 'expected_version': 1, 'name': 'Fazenda revisada', 'area_ha': '10',
                'location': 'Localização fictícia', 'notes': 'Observação fictícia', 'archived': False, **changes}

    def plot_edit(self, **changes):
        return {'id': identity(), 'expected_version': 1, 'name': 'Talhão revisado', 'area_ha': '10',
                'notes': 'Observação do talhão', 'archived': False, **changes}

    def test_catalog_edits_keep_operation_context_and_audit_versions(self):
        self.opening()
        operation = self.operation()
        self.post('/operations', operation)
        before = self.report()['metrics']
        body = self.property_edit()
        result = self.request('PATCH', f'/properties/{self.prop}', body)
        self.assertEqual(result['version'], 2)
        self.assertEqual(result['location'], body['location'])
        self.request('PATCH', f'/properties/{self.prop}', body)
        self.request('PATCH', f'/properties/{self.prop}', self.property_edit(), expected=409)
        self.request('PATCH', f'/plots/{self.plot}', self.plot_edit(area_ha='8'))
        current = self.request('GET', f'/operations/{operation["id"]}')
        self.assertEqual(current['context']['property']['name'], 'Fazenda fictícia')
        self.assertEqual(current['context']['plot']['name'], 'Talhão fictício')
        self.assertEqual(current['context']['plot']['area_ha'], '10')
        self.assertEqual(self.report()['metrics'], before)
        with api.connect() as db:
            rows = db.execute("SELECT version,snapshot_json FROM v2_catalog_revisions WHERE entity_type='property' AND entity_id=? ORDER BY version", (self.prop,)).fetchall()
            self.assertEqual([r['version'] for r in rows], [1, 2])
            self.assertEqual(json.loads(rows[0]['snapshot_json'])['name'], 'Fazenda fictícia')
            audit = db.execute("SELECT actor_id,before_json FROM v2_audit WHERE action='update' AND entity_type='property'").fetchone()
            self.assertEqual(audit['actor_id'], 'admin')
            self.assertEqual(json.loads(audit['before_json'])['name'], 'Fazenda fictícia')

    def test_archived_property_preserves_reports_and_blocks_new_records(self):
        self.opening()
        operation = self.operation()
        self.post('/operations', operation)
        before = self.report()['metrics']
        self.request('PATCH', f'/properties/{self.prop}', self.property_edit(archived=True))
        self.assertEqual(self.request('GET', '/properties')['items'], [])
        self.assertEqual(len(self.request('GET', '/properties?include_archived=true')['items']), 1)
        self.assertEqual(self.request('GET', '/workspace')['properties'], [])
        self.post('/operations', operation)  # already confirmed retry remains idempotent
        self.post('/operations', self.operation(start='103', end='104'), expected=409)
        self.post('/plots', {'id': identity(), 'property_id': self.prop, 'name': 'Novo'}, expected=409)
        self.post(f'/properties/{self.prop}/inventory', {'id': identity(), 'input_id': self.diesel,
                  'kind': 'receipt', 'quantity': '1', 'occurred_on': '2026-01-04'}, expected=409)
        self.assertEqual(self.report()['metrics'], before)
        response = self.http.delete('/api/v2/properties/' + self.prop, headers=self.tokens['admin'])
        self.assertEqual(response.status_code, 405)

    def test_archived_plot_retains_cycles_and_reactivation_checks_area(self):
        self.request('PATCH', f'/plots/{self.plot}', self.plot_edit(archived=True))
        self.assertEqual(self.request('GET', f'/properties/{self.prop}/plots')['items'], [])
        self.assertEqual(len(self.request('GET', f'/properties/{self.prop}/cycles')['items']), 1)
        self.assertEqual(self.request('GET', f'/properties/{self.prop}/cycles')['items'][0]['crop_name'], 'Café')
        self.post('/plots', {'id': identity(), 'property_id': self.prop, 'name': 'Outro', 'area_ha': '10'})
        self.request('PATCH', f'/plots/{self.plot}', self.plot_edit(expected_version=2), expected=422)
        self.opening()
        self.post('/operations', self.operation(), expected=409)

    def test_property_plot_permissions_and_area_validation(self):
        self.request('PATCH', f'/properties/{self.prop}', self.property_edit(), user='worker', expected=403)
        self.request('PATCH', f'/plots/{self.plot}', self.plot_edit(), user='worker', expected=403)
        self.grant('worker', 'employee')
        self.assertEqual(len(self.request('GET', '/properties', user='worker')['items']), 1)
        self.request('PATCH', f'/properties/{self.prop}', self.property_edit(area_ha='9'), expected=422)
        self.request('PATCH', f'/plots/{self.plot}', self.plot_edit(area_ha='11'), expected=422)
        self.request('PATCH', f'/plots/{self.plot}', self.plot_edit(area_ha='0'), expected=422)
        self.request('PATCH', f'/plots/{self.plot}', self.plot_edit(area_ha=None))
        self.assertIsNone(self.request('GET', f'/properties/{self.prop}/plots')['items'][0]['area_ha'])
        api.app.dependency_overrides[api.current_user] = lambda: {'id': 'other', 'farmId': 'org-b', 'role': 'admin'}
        self.assertEqual(self.request('GET', '/properties?include_archived=true')['items'], [])
        self.request('PATCH', f'/properties/{self.prop}', self.property_edit(), expected=404)
        self.request('PATCH', f'/plots/{self.plot}', self.plot_edit(), expected=404)

    def test_v3_upgrade_keeps_history_without_inventing_old_snapshots(self):
        self.opening()
        operation = self.operation()
        self.post('/operations', operation)
        before = self.report()['metrics']
        with api.connect() as db:
            for table in ['v2_implement_usage','v2_boundaries','v2_harvest_outputs','v2_plan_events','v2_plan_plots','v2_activity_plans','v2_operation_measurements','v2_property_responsibles']:
                db.execute('DROP TABLE '+table)
            db.execute('ALTER TABLE v2_inputs DROP COLUMN notes')
            # Rebuild an actual pre-v4 fixture, including removal of all later
            # additive logistics tables in reverse foreign-key order.
            for statement in reversed(LOGISTICS_STATEMENTS):
                table = re.match(r'CREATE TABLE (\w+)', statement)
                if table:
                    db.execute('DROP TABLE ' + table[1])
            db.execute('DROP TABLE v2_operation_context')
            db.execute('DROP TABLE v2_catalog_revisions')
            for table, columns in [('v2_properties', ['location', 'notes', 'archived', 'version','shared_operators']),
                                   ('v2_plots', ['notes', 'archived', 'version'])]:
                for column in columns:
                    db.execute(f'ALTER TABLE {table} DROP COLUMN {column}')
            for table in ['v2_refuelings','v2_work_photos','v2_stock_limits','v2_checklists','v2_work_parts','v2_reservations','v2_work_progress','v2_work_orders','v2_tasks']:
                db.execute('DROP TABLE '+table)
            db.execute('ALTER TABLE v2_machines DROP COLUMN archived')
            db.execute('ALTER TABLE v2_machines DROP COLUMN version')
            db.execute('DELETE FROM v2_migrations WHERE version>=4')
            old_body = {'id': self.prop, 'client_id': self.client_id, 'name': 'Fazenda fictícia', 'area_ha': '10'}
            db.execute("UPDATE v2_requests SET request_json=? WHERE entity_type='property' AND entity_id=?",
                       (json.dumps(old_body), self.prop))
        api.initialize_database()
        api.initialize_database()
        result = self.post('/properties', old_body)
        self.assertEqual(result['version'], 1)
        self.assertEqual(result['location'], '')
        self.assertEqual(self.report()['metrics'], before)
        current = self.request('GET', f'/operations/{operation["id"]}')
        self.assertIsNone(current['context'])
        self.assertEqual(current['context_status'], 'not_recorded_before_upgrade')

    def test_local_catalog_shares_only_operator_team_inside_organization(self):
        self.grant('consultant', 'consultant')
        shared = identity()
        self.post('/properties', {'id':shared,'client_id':self.client_id,'name':'Compartilhada',
                  'share_with_operators':True,'area_ha':'5'})
        plot = identity()
        self.post('/plots', {'id':plot,'property_id':shared,'name':'Talhão compartilhado','area_ha':'5'})
        worker = self.request('GET','/workspace?property_id='+shared,user='worker')
        self.assertEqual(worker['plots'][0]['id'],plot)
        self.assertEqual(worker['properties'][0]['access_role'],'employee')
        self.request('GET','/workspace?property_id='+shared,user='consultant',expected=404)
        self.post('/plots',{'id':identity(),'property_id':shared,'name':'Talhão do operador'},user='worker')
        self.request('PUT',f'/properties/{shared}/access',{'user_id':'worker','role':None})
        self.request('GET','/workspace?property_id='+shared,user='worker',expected=404)
        api.app.dependency_overrides[api.current_user] = lambda:{'id':'external','farmId':'org-b','role':'operator'}
        self.request('GET','/workspace?property_id='+shared,expected=404)

    def test_fictitious_report_matches_hand_calculation(self):
        self.opening()
        self.post(f'/properties/{self.prop}/inventory', {'id': identity(), 'input_id': self.diesel, 'kind': 'receipt',
                  'quantity': '50', 'value_cents': 33000, 'occurred_on': '2026-01-02'})
        self.opening(self.foliar, '10', 50000)
        first = self.operation()
        first['inputs'].append({'input_id': self.foliar, 'quantity': '2'})
        self.post('/operations', first)
        self.post('/operations', self.operation('103', '107', '40', '2026-01-04'))
        report = self.report()
        self.report_result = report
        values = {key: item['value'] for key, item in report['metrics'].items()}
        self.assertEqual(values['registered_cost'], '137400')
        self.assertEqual(values['machine_cost'], '84000')
        self.assertEqual(values['input_cost'], '10000')
        self.assertEqual(values['fuel_cost'], '43400')
        self.assertEqual(values['cost_per_cycle_ha'], '13740')
        self.assertEqual(values['machine_hours'], '7')
        self.assertEqual(values['worked_area_passes'], '20')
        self.assertIsNone(values['labor_hours'])
        self.assertEqual((self.stock()['quantity'], self.stock()['value_cents']), ('80', 49600))
        self.assertEqual((self.stock(self.foliar)['quantity'], self.stock(self.foliar)['value_cents']), ('8', 40000))
        self.assertEqual(len(report['operations']), 2)
        self.assertEqual(self.report('?starts_on=2026-01-04')['metrics']['registered_cost']['value'], '72800')

    def test_atomic_rollback_on_insufficient_stock(self):
        self.opening(quantity='1', value=600)
        body = self.operation()
        self.post('/operations', body, expected=409)
        self.assertEqual(self.stock()['quantity'], '1')
        with api.connect() as db:
            self.assertEqual(db.execute('SELECT hour_meter FROM v2_machines').fetchone()[0], '100')
            for table in ['v2_operations', 'v2_machine_usage']:
                self.assertEqual(db.execute(f'SELECT COUNT(*) FROM {table}').fetchone()[0], 0)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM v2_audit WHERE entity_type='operation'").fetchone()[0], 0)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM v2_requests WHERE entity_type='operation'").fetchone()[0], 0)

    def test_retries_are_idempotent_and_conflicts_rejected(self):
        self.opening()
        body = self.operation()
        first = self.post('/operations', body)
        self.assertEqual(first, self.post('/operations', body))
        self.assertEqual(self.stock()['quantity'], '70')
        body['notes'] = 'changed'
        self.post('/operations', body, expected=409)
        with api.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM v2_audit WHERE entity_type='operation'").fetchone()[0], 1)

    def test_unknown_prices_and_absence_are_not_zero(self):
        self.assertFalse(self.stock()['initialized'])
        self.assertIsNone(self.stock()['quantity'])
        self.assertEqual(self.report()['metrics']['registered_cost']['status'], 'no_data')
        self.opening(value=None)
        self.post('/operations', self.operation())
        report = self.report()
        self.assertEqual(report['metrics']['registered_cost']['status'], 'incomplete')
        self.assertIsNone(report['metrics']['registered_cost']['value'])
        self.assertEqual(report['metrics']['registered_cost']['known_subtotal'], '36000')
        self.assertEqual(report['metrics']['machine_cost']['value'], '36000')
        self.assertIsNone(self.stock()['value_cents'])

    def test_inventory_order_opening_and_zero(self):
        receipt = {'id': identity(), 'input_id': self.diesel, 'kind': 'receipt', 'quantity': '1',
                   'value_cents': 10, 'occurred_on': '2026-01-03'}
        self.post(f'/properties/{self.prop}/inventory', receipt, expected=409)
        self.opening(quantity='0', value=0, day='2026-01-02')
        self.assertEqual(self.stock()['quantity'], '0')
        self.post(f'/properties/{self.prop}/inventory', receipt)
        self.assertEqual(self.post(f'/properties/{self.prop}/inventory', receipt)['id'], receipt['id'])
        receipt = {**receipt, 'id': identity(), 'occurred_on': '2026-01-01'}
        self.post(f'/properties/{self.prop}/inventory', receipt, expected=409)
        self.post(f'/properties/{self.prop}/inventory', {**receipt, 'id': identity(), 'kind': 'opening'}, expected=409)

    def test_property_permissions_roles_and_revocation(self):
        self.opening()
        for user, role in [('worker', 'employee'), ('consultant', 'consultant'), ('owner', 'owner'), ('manager', 'manager')]:
            self.grant(user, role)
        body = self.operation()
        operation = self.post('/operations', body, user='worker')
        self.assertNotIn('value_cents', operation['inputs'][0])
        self.assertNotIn('cost_cents', operation['machines'][0])
        self.assertNotIn('value_cents', self.stock(user='worker'))
        self.request('GET', f'/cycles/{self.cycle}/report', user='worker', expected=403)
        self.post('/operations', self.operation('103', '104', '1'), user='consultant', expected=403)
        self.request('GET', f'/cycles/{self.cycle}/report', user='consultant', expected=403)
        self.request('GET', f'/properties/{self.prop}/audit', user='consultant', expected=403)
        self.request('GET', f'/properties/{self.prop}/audit', user='owner', expected=403)
        for user in ['owner', 'manager']:
            self.request('GET', f'/cycles/{self.cycle}/report', user=user, expected=403)
        self.post('/inputs', {'id': identity(), 'name': 'Denied', 'unit': 'L'}, user='worker', expected=403)
        self.grant('worker', None)
        self.request('GET', f'/operations/{body["id"]}', user='worker', expected=404)

    def test_other_property_and_other_org_are_inaccessible(self):
        self.grant('worker', 'employee')
        other_prop = identity()
        self.post('/properties', {'id': other_prop, 'client_id': self.client_id, 'name': 'Outra propriedade'})
        self.request('GET', f'/properties/{other_prop}/plots', user='worker', expected=404)
        self.assertEqual(len(self.request('GET', '/properties', user='worker')['items']), 1)
        foreign_client = identity()
        with api.connect() as db:
            db.execute('INSERT INTO v2_clients VALUES(?,?,?,?)', ('org-b', foreign_client, 'Outra organização', api.utc_now()))
        self.post('/properties', {'id': identity(), 'client_id': foreign_client, 'name': 'Forbidden'}, expected=404)
        # A second organization is not supported by legacy login; override only the trusted
        # authentication dependency to exercise repository isolation, never request fields.
        api.app.dependency_overrides[api.current_user] = lambda: {'id': 'other-admin', 'farmId': 'org-b', 'role': 'admin'}
        self.assertEqual(self.request('GET', '/properties')['items'], [])
        self.request('GET', f'/cycles/{self.cycle}/report', expected=404)
        self.post('/plots', {'id': identity(), 'property_id': self.prop, 'name': 'Forbidden'}, expected=404)

    def test_invalid_fields_areas_dates_and_meters(self):
        self.post('/clients', {'id': identity(), 'name': 'Spoof', 'tenant_id': 'org-b'}, expected=422)
        self.post('/plots', {'id': identity(), 'name': 'Excess', 'property_id': self.prop, 'area_ha': '1'}, expected=422)
        self.opening()
        body = self.operation()
        body['machines'][0]['end_meter'] = '99'
        self.post('/operations', body, expected=422)
        body = self.operation(day='2027-01-01')
        self.post('/operations', body, expected=422)
        self.post('/operations', self.operation('99', '100'), expected=409)
        self.post('/operations', self.operation('100', '103', day='2026-01-05'))
        self.post('/operations', self.operation('103', '104', day='2026-01-04'), expected=409)
        self.request('GET', f'/cycles/{self.cycle}/report?starts_on=2026-02-01&ends_on=2026-01-01', expected=422)

    def test_auth_required_disabled_pilot_and_disabled_account(self):
        self.assertEqual(self.http.get('/api/v2/properties').status_code, 401)
        api.V2_ENABLED = False
        self.request('GET', '/properties', expected=503)
        api.V2_ENABLED = True
        with api.connect() as db:
            db.execute("UPDATE users SET disabled=1 WHERE user_id='admin'")
        self.request('GET', '/properties', expected=401)

    def test_migration_is_additive_idempotent_and_transactional(self):
        with api.connect() as db:
            db.execute("INSERT INTO records VALUES('org-a','services','legacy','{\"name\":\"Original\"}',7,0,?)", (api.utc_now(),))
            before = tuple(db.execute('SELECT * FROM records').fetchone())
        api.initialize_database()
        api.initialize_database()
        with api.connect() as db:
            self.assertEqual(tuple(db.execute('SELECT * FROM records').fetchone()), before)
            self.assertEqual(db.execute('SELECT COUNT(*) FROM v2_migrations').fetchone()[0], 11)
            self.assertEqual(db.execute('PRAGMA foreign_key_check').fetchall(), [])
            db.execute("UPDATE v2_migrations SET checksum='wrong'")
        with self.assertRaises(RuntimeError):
            api.initialize_database()
        # A failed DDL migration must roll back all new tables.
        broken = sqlite3.connect(':memory:')
        statements = v2_schema.STATEMENTS
        try:
            broken.execute('CREATE TABLE users(farm_id TEXT,user_id TEXT)')
            v2_schema.STATEMENTS = [statements[0], 'INVALID SQL']
            with self.assertRaises(sqlite3.OperationalError):
                with broken:
                    v2_schema.migrate(broken)
            self.assertIsNone(broken.execute("SELECT name FROM sqlite_master WHERE name='v2_clients'").fetchone())
        finally:
            v2_schema.STATEMENTS = statements
            broken.close()

    def test_employee_cannot_read_others_operation(self):
        self.opening()
        self.grant('worker', 'employee')
        operation = self.post('/operations', self.operation())
        self.request('GET', '/operations/' + operation['id'], user='worker', expected=404)

    def test_concurrent_consumption_cannot_overdraw_stock(self):
        self.opening(quantity='10', value=1000)
        bodies = [self.operation(quantity='7'), self.operation(quantity='7')]
        for body in bodies:
            body['machines'] = []
        def send(body):
            return self.http.post('/api/v2/operations', json=body, headers=self.tokens['admin']).status_code
        with ThreadPoolExecutor(max_workers=2) as executor:
            statuses = sorted(executor.map(send, bodies))
        self.assertEqual(statuses, [200, 409])
        self.assertEqual((self.stock()['quantity'], self.stock()['value_cents']), ('3', 300))

    def test_concurrent_retry_consumes_once(self):
        self.opening()
        body = self.operation()
        def send(_):
            return self.http.post('/api/v2/operations', json=body, headers=self.tokens['admin']).status_code
        with ThreadPoolExecutor(max_workers=2) as executor:
            self.assertEqual(list(executor.map(send, range(2))), [200, 200])
        self.assertEqual(self.stock()['quantity'], '70')

    def test_machine_assignment_and_audit_author(self):
        other_prop = identity()
        self.post('/properties', {'id': other_prop, 'client_id': self.client_id, 'name': 'Outra'})
        other_machine = identity()
        self.post('/machines', {'id': other_machine, 'name': 'Restrita', 'hour_meter': '0', 'property_ids': [other_prop]})
        self.opening()
        invalid = self.operation()
        invalid['machines'][0] = {'machine_id': other_machine, 'start_meter': '0', 'end_meter': '1'}
        self.post('/operations', invalid, expected=404)
        self.grant('worker', 'employee')
        body = self.operation()
        self.post('/operations', body, user='worker')
        audit = self.request('GET', f'/properties/{self.prop}/audit')['items']
        event = next(row for row in audit if row['entity_id'] == body['id'])
        self.assertEqual(event['actor_id'], 'worker')
        self.assertTrue(event['created_at'])

    def test_backup_and_restore_preserve_v2_report(self):
        from agrogestor_server import cli
        self.opening()
        self.post('/operations', self.operation())
        before = self.report()['metrics']
        destination = Path(self.temp.name) / 'synthetic-backup'
        cli.backup(destination)
        with api.connect() as db:
            db.execute("UPDATE v2_machine_usage SET cost_cents=999")
        self.assertNotEqual(self.report()['metrics'], before)
        cli.restore(destination)
        self.assertEqual(self.report()['metrics'], before)

    def test_mobile_snapshot_enforces_property_and_price_permissions(self):
        self.opening()
        self.grant('worker', 'employee')
        operation = self.post('/operations', self.operation(), user='worker')
        snapshot = self.request('GET', '/workspace?property_id=' + self.prop, user='worker')
        self.assertEqual(snapshot['properties'][0]['access_role'], 'employee')
        self.assertEqual([c['id'] for c in snapshot['clients']], [self.client_id])
        self.assertNotIn('value_cents', snapshot['inventory'][0])
        self.assertNotIn('hourly_cost_cents', snapshot['machines'][0])
        self.assertEqual(snapshot['operations'][0]['id'], operation['id'])
        self.request('GET', '/workspace?property_id=' + identity(), user='worker', expected=404)
        self.grant('worker', None)
        self.request('GET', '/workspace?property_id=' + self.prop, user='worker', expected=404)

    def test_stock_correction_requires_current_balance_and_keeps_history(self):
        self.opening()
        snapshot = self.request('GET', '/workspace?property_id=' + self.prop)
        body = {'id': identity(), 'input_id': self.diesel, 'quantity': '90', 'value_cents': 55000,
                'occurred_on': '2026-01-02', 'expected_movement_id': snapshot['inventory'][0]['last_movement_id'], 'reason': 'Conferência física'}
        # Find the diesel entry independently of name ordering.
        body['expected_movement_id'] = next(s['last_movement_id'] for s in snapshot['inventory'] if s['input_id'] == self.diesel)
        path = f'/properties/{self.prop}/inventory-corrections'
        self.post(path, body)
        self.post(path, body)
        self.assertEqual((self.stock()['quantity'], self.stock()['value_cents']), ('90', 55000))
        self.post(path, {**body, 'id': identity()}, expected=409)
        with api.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM v2_inventory').fetchone()[0], 3)
            audit = db.execute("SELECT * FROM v2_audit WHERE action='correct_stock'").fetchone()
            self.assertIn('100', audit['before_json'])
        self.grant('worker', 'employee')
        self.post(path, {**body, 'id': identity()}, user='worker', expected=403)

    def test_void_restores_stock_and_meter_and_removes_report_cost(self):
        self.opening()
        body = self.operation()
        self.post('/operations', body)
        request = {'id': identity(), 'occurred_on': '2026-01-04', 'reason': 'Apontamento incorreto'}
        path = f'/operations/{body["id"]}/void'
        first = self.post(path, request)
        self.assertEqual(first['void']['actor_id'], 'admin')
        self.assertEqual(self.post(path, request), first)
        self.assertEqual((self.stock()['quantity'], self.stock()['value_cents']), ('100', 60000))
        self.assertEqual(self.report()['metrics']['registered_cost']['status'], 'no_data')
        with api.connect() as db:
            self.assertEqual(db.execute('SELECT hour_meter FROM v2_machines').fetchone()[0], '100')
            self.assertEqual(db.execute('SELECT COUNT(*) FROM v2_operations').fetchone()[0], 1)
        self.post(path, {**request, 'id': identity()}, expected=409)

    def test_void_with_later_usage_rejected_atomically(self):
        self.opening()
        first = self.operation()
        self.post('/operations', first)
        self.post('/operations', self.operation('103','104','10','2026-01-04'))
        self.post(f'/operations/{first["id"]}/void', {'id': identity(), 'occurred_on': '2026-01-05', 'reason': 'Teste'}, expected=409)
        self.assertEqual(self.stock()['quantity'], '60')
        with api.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM v2_voids').fetchone()[0], 0)

    def test_legacy_import_plan_is_deterministic_and_leaves_unknowns(self):
        from agrogestor_server.v2_import import build_plan
        rows = [
            {'module': 'clients', 'record_id': 'old-client', 'payload': json.dumps({'name': 'Cliente antigo', 'properties': [
                {'id': 'old-prop', 'name': 'Imóvel', 'totalArea': 0, 'fields': [{'id': 'old-plot', 'name': 'Talhão', 'area': 0}]}]})},
            {'module': 'machines', 'record_id': 'old-machine', 'payload': json.dumps({'name': 'Máquina antiga', 'hourMeter': 100})},
            {'module': 'products', 'record_id': 'old-product', 'payload': json.dumps({'name': 'Produto antigo', 'unit': 'L', 'quantity': 99})},
        ]
        plan = build_plan(rows, 'org-a')
        self.assertEqual(plan, build_plan(rows, 'org-a'))
        self.assertEqual(len(plan['requests']), 4)
        self.assertIsNone(plan['requests'][1]['body']['area_ha'])
        self.assertFalse(any('quantity' in r['body'] for r in plan['requests']))
        for item in plan['requests']:
            self.post(item['path'], item['body'])
            self.post(item['path'], item['body'])
        foreign = build_plan(rows, 'org-b')
        self.assertNotEqual(plan['mapping'], foreign['mapping'])
        with_assignment = build_plan(rows, 'org-a', {'old-machine': [plan['mapping']['property/old-client/old-prop']]})
        machine = next(r for r in with_assignment['requests'] if r['path'] == '/machines')
        self.post(machine['path'], machine['body'])

    def test_legacy_plan_reads_without_changing_records(self):
        from agrogestor_server.v2_import import read_plan
        with api.connect() as db:
            db.execute("INSERT INTO records VALUES('org-a','clients','legacy',?,1,0,?)", (json.dumps({'name': 'Legado', 'properties': []}), api.utc_now()))
            before = [tuple(r) for r in db.execute('SELECT * FROM records')]
        plan = read_plan(api.DB_PATH)
        self.assertEqual(len(plan['requests']), 1)
        with api.connect() as db:
            self.assertEqual([tuple(r) for r in db.execute('SELECT * FROM records')], before)

    def test_machine_rate_update_preserves_historical_cost_and_checks_conflict(self):
        self.opening()
        self.post('/operations', self.operation())
        old_report = self.report()['metrics']['machine_cost']['value']
        snapshot = self.request('GET', '/workspace?property_id=' + self.prop)
        machine = snapshot['machines'][0]
        update = {'id': identity(), 'name': 'Trator revisado', 'hourly_cost_cents': 15000,
                  'expected_name': machine['name'], 'expected_hour_meter': machine['hour_meter'],
                  'expected_hourly_cost_cents': machine['hourly_cost_cents'],
                  'expected_property_ids': machine['property_ids'], 'property_ids': [self.prop]}
        self.request('PATCH', '/machines/' + self.machine, update)
        self.request('PATCH', '/machines/' + self.machine, update)
        self.assertEqual(self.report()['metrics']['machine_cost']['value'], old_report)
        self.request('PATCH', '/machines/' + self.machine, {**update, 'id': identity()}, expected=409)
        self.post('/operations', self.operation('103', '104', '1', '2026-01-04'))
        self.assertEqual(self.report()['metrics']['machine_cost']['value'], '51000')

    def test_property_accounts_cannot_bypass_isolation_through_legacy_api(self):
        self.grant('worker', 'owner')
        for role in ['owner', None]:
            self.grant('worker', role)
            for path in ['/api/v1/sync/pull', '/api/v1/attachments/attachment-legacy-test-1234']:
                response = self.http.get(path, headers=self.tokens['worker'])
                self.assertEqual(response.status_code, 403, response.text)
            response = self.http.post('/api/v1/sync/push', headers=self.tokens['worker'], json={'events': []})
            self.assertEqual(response.status_code, 403, response.text)
        self.assertEqual(self.http.get('/api/v1/sync/pull', headers=self.tokens['admin']).status_code, 200)


class MetricsTests(unittest.TestCase):
    def test_rounding_residual_unknown_and_known_zero(self):
        rows = [{'kind': 'opening', 'quantity': '3', 'value_cents': 100}]
        self.assertEqual(consumption_value(stock_balance(rows), Decimal('1')), 33)
        rows.append({'kind': 'consume', 'quantity': '1', 'value_cents': 33})
        self.assertEqual(consumption_value(stock_balance(rows), Decimal('2')), 67)
        self.assertEqual(metric([0], 'BRL_cent')['value'], '0')
        self.assertIsNone(metric([], 'BRL_cent')['value'])
        self.assertEqual(metric([100, None], 'BRL_cent')['known_subtotal'], '100')
        rows = [{'kind': 'opening', 'quantity': '1', 'value_cents': None},
                {'kind': 'consume', 'quantity': '1', 'value_cents': None},
                {'kind': 'receipt', 'quantity': '1', 'value_cents': 50}]
        self.assertEqual(stock_balance(rows)['value_cents'], 50)


if __name__ == '__main__':
    unittest.main()
