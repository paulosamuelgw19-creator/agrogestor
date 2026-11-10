"""Profile changes exercise real routes against disposable databases only."""
import unittest
from uuid import uuid4
import test_v2_pilot as pilot


class ProfileUpdateTests(unittest.TestCase):
    def setUp(self):
        self.p = pilot.PilotTests()
        self.p.setUp()
        self.p.grant('worker', 'employee')

    def tearDown(self):
        self.p.tearDown()

    def test_operator_creates_property_plot_machine_without_admin_privileges(self):
        p = self.p
        client = {'id': str(uuid4()), 'name': 'Responsável de teste'}
        p.post('/clients', client, user='worker')
        prop = {'id': str(uuid4()), 'client_id': client['id'], 'name': 'Cadastro do operador'}
        first = p.post('/properties', prop, user='worker')
        self.assertIsNone(first['area_ha'])
        self.assertEqual(p.post('/properties', prop, user='worker'), first)
        plot = p.post('/plots', {'id': str(uuid4()), 'property_id': prop['id'], 'name': 'Talhão sem área'}, user='worker')
        self.assertIsNone(plot['area_ha'])
        machine = {'id': str(uuid4()), 'name': 'Trator cadastrado em campo', 'hour_meter': '123.5', 'property_ids': [prop['id']]}
        self.assertNotIn('hourly_cost_cents', p.post('/machines', machine, user='worker'))
        p.post('/machines', machine, user='worker')
        p.post('/machines', machine | {'id': str(uuid4()), 'hourly_cost_cents': 100}, user='worker', expected=403)
        p.request('PUT', f"/properties/{prop['id']}/access", {'user_id': 'manager', 'role': 'manager'}, user='worker', expected=403)
        p.request('PATCH', f"/properties/{prop['id']}", {'id': str(uuid4()), 'expected_version': 1, 'name': 'Edit', 'area_ha': None, 'location': '', 'notes': '', 'archived': False}, user='worker', expected=403)
        p.request('GET', f"/properties/{prop['id']}/plots", user='manager', expected=404)
        self.assertIn(prop['id'], [v['id'] for v in p.request('GET', '/properties')['items']])
        with pilot.api.connect() as db:
            self.assertEqual(db.execute('SELECT role FROM v2_access WHERE tenant_id=? AND user_id=? AND property_id=?', ('org-a', 'worker', prop['id'])).fetchone()[0], 'employee')
            self.assertEqual(db.execute('SELECT COUNT(*) FROM v2_machine_properties WHERE tenant_id=? AND machine_id=?', ('org-a', machine['id'])).fetchone()[0], 1)
            self.assertEqual(db.execute('PRAGMA foreign_key_check').fetchall(), [])

    def test_operator_cannot_link_hidden_clients_properties_or_share_with_colleagues(self):
        p = self.p
        hidden_client = {'id': str(uuid4()), 'name': 'Responsável privado'}
        p.post('/clients', hidden_client)
        self.assertNotIn(hidden_client['id'], [c['id'] for c in p.request('GET', '/clients', user='worker')['items']])
        p.post('/clients', hidden_client, user='worker', expected=404)
        p.post('/properties', {'id': str(uuid4()), 'client_id': hidden_client['id'], 'name': 'Não permitido'}, user='worker', expected=404)
        p.post('/properties', {'id': str(uuid4()), 'client_id': p.client_id, 'name': 'Não compartilhar', 'share_with_operators': True}, user='worker', expected=403)
        hidden_prop = p.post('/properties', {'id': str(uuid4()), 'client_id': p.client_id, 'name': 'Propriedade privada'})
        p.post('/plots', {'id': str(uuid4()), 'property_id': hidden_prop['id'], 'name': 'Não permitido'}, user='worker', expected=404)
        p.post('/machines', {'id': str(uuid4()), 'property_ids': [hidden_prop['id']], 'name': 'Não permitido', 'hour_meter': '0'}, user='worker', expected=404)

    def test_operations_remain_private_even_with_manager_property_grant(self):
        p = self.p
        p.opening()
        admin_operation = p.operation()
        p.post('/operations', admin_operation)
        p.grant('worker', 'manager')
        p.request('GET', '/operations/' + admin_operation['id'], user='worker', expected=404)
        own = p.operation(start='103', end='104', quantity='1')
        p.post('/operations', own, user='worker')
        snapshot = p.request('GET', '/workspace?property_id=' + p.prop, user='worker')
        self.assertEqual([op['id'] for op in snapshot['operations']], [own['id']])
        self.assertEqual(len(p.request('GET', '/workspace?property_id=' + p.prop)['operations']), 2)

    def test_mechanic_cannot_create_general_catalog_or_access_other_tenants(self):
        p = self.p
        pilot.api.app.dependency_overrides[pilot.api.current_user] = lambda: {'id': 'mechanic', 'farmId': 'org-a', 'role': 'mechanic'}
        p.post('/clients', {'id': str(uuid4()), 'name': 'Não permitido'}, expected=403)
        p.post('/properties', {'id': str(uuid4()), 'name': 'Não permitido', 'client_id': p.client_id}, expected=403)
        p.post('/plots', {'id': str(uuid4()), 'name': 'Não permitido', 'property_id': p.prop}, expected=403)
        p.post('/machines', {'id': str(uuid4()), 'name': 'Não permitido', 'hour_meter': '0', 'property_ids': [p.prop]}, expected=403)
        pilot.api.app.dependency_overrides[pilot.api.current_user] = lambda: {'id': 'worker', 'farmId': 'org-b', 'role': 'operator'}
        self.assertEqual(p.request('GET', '/clients')['items'], [])
        p.post('/properties', {'id': str(uuid4()), 'name': 'Não permitido', 'client_id': p.client_id}, expected=404)

    def test_legacy_sync_and_photos_cannot_bypass_profile_isolation(self):
        p = self.p
        for method, path, body in [
            ('GET', '/api/v1/sync/pull', None),
            ('POST', '/api/v1/sync/push', {'events': []}),
            ('GET', '/api/v1/attachments/' + str(uuid4()), None),
        ]:
            response = p.http.request(method, path, json=body, headers=p.tokens['worker'])
            self.assertEqual(response.status_code, 403, response.text)


if __name__ == '__main__':
    unittest.main()
