"""Commercial module gates exercised through authenticated API requests."""

import json
import unittest
from datetime import date
from uuid import uuid4

import test_v2_pilot as pilot
import test_workflows as workflows
from agrogestor_server import commercial


class ContractModuleGateTests(unittest.TestCase):
    def setUp(self):
        self.work = workflows.WorkTests()
        self.work.setUp()
        self.addCleanup(self.work.tearDown)
        self.pilot = self.work.p

    def restrict(self, *enabled):
        with pilot.api.connect() as connection:
            contract, _ = commercial.config(connection, 'org-a')
            contract['modules'] = list(enabled)
            connection.execute(
                'INSERT INTO commercial_entitlements VALUES(?,1,?,?,NULL,NULL)',
                ('org-a', json.dumps(contract), pilot.api.utc_now()),
            )

    def push(self, *events):
        response = self.pilot.http.post(
            '/api/v1/sync/push', headers=self.pilot.tokens['admin'],
            json={'events': events},
        )
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    def status(self, user):
        response = self.pilot.http.get(
            '/api/v1/licensing/status', headers=self.pilot.tokens[user],
        )
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    def test_entitlement_exposes_compatibility_and_restricted_lists(self):
        compatible = self.status('worker')
        self.assertEqual(compatible['contractModules'], sorted(commercial.MODULES))
        self.assertTrue(compatible['writeAllowed'])

        self.restrict('properties', 'inventory')
        for account in ('admin', 'worker', 'mechanic'):
            with self.subTest(account=account):
                restricted = self.status(account)
                self.assertEqual(restricted['contractModules'], ['inventory', 'properties'])
                self.assertTrue(restricted['writeAllowed'])

        password = 'SyntheticOnlyPassword2026!'
        with pilot.api.connect() as connection:
            connection.execute(
                "UPDATE users SET password_hash=? WHERE user_id='admin'",
                (pilot.api.password_hash.hash(password),),
            )
        login = self.pilot.http.post('/api/v1/auth/login', json={
            'email': 'admin@example.invalid', 'password': password,
            'deviceId': 'synthetic-login-device', 'deviceName': 'Dispositivo fictício',
        })
        self.assertEqual(login.status_code, 200, login.text)
        self.assertEqual(login.json()['entitlement']['contractModules'], ['inventory', 'properties'])

    def test_legacy_module_blocks_new_edits_and_removal_but_preserves_ack_and_history(self):
        original = {
            'eventId': str(uuid4()), 'recordId': str(uuid4()), 'module': 'machines',
            'baseVersion': 0, 'operation': 'upsert', 'payload': {'name': 'Trator legado fictício'},
        }
        accepted = [{'eventId': original['eventId'], 'version': 1}]
        self.assertEqual(self.push(original)['acknowledged'], accepted)
        self.restrict('properties')

        edit = dict(original, eventId=str(uuid4()), baseVersion=1, payload={'name': 'Edição bloqueada'})
        remove = dict(original, eventId=str(uuid4()), baseVersion=1, operation='delete', payload=None)
        create = dict(original, eventId=str(uuid4()), recordId=str(uuid4()))
        result = self.push(edit, remove, create, original)
        self.assertEqual(result['acknowledged'], accepted)
        self.assertEqual(result['conflicts'], [])
        self.assertEqual(
            {event['eventId']: event['code'] for event in result['rejected']},
            {event['eventId']: 'MODULE_DISABLED' for event in (edit, remove, create)},
        )

        history = self.pilot.http.get('/api/v1/sync/pull', headers=self.pilot.tokens['admin'])
        self.assertEqual(history.status_code, 200, history.text)
        changes = [row for row in history.json()['changes'] if row['module'] == 'machines']
        self.assertEqual(len(changes), 1)
        self.assertEqual(changes[0]['recordId'], original['recordId'])
        self.assertEqual(changes[0]['version'], 1)
        self.assertEqual(changes[0]['payload'], original['payload'])
        self.assertFalse(changes[0]['deleted'])

    def test_v2_gates_inventory_edits_and_workflow_actions_with_existing_history(self):
        p = self.pilot
        p.opening()
        operation = p.operation()
        p.post('/operations', operation)
        task = self.work.task()
        order = self.work.order(stop_machine=False)
        initial_stock = p.stock()
        initial_operation = p.request('GET', f"/operations/{operation['id']}")
        self.restrict('properties', 'fleet')

        operations = [
            ('PATCH', f'/inputs/{p.diesel}', {
                'id': str(uuid4()), 'name': 'Diesel alterado', 'expected_name': 'Diesel',
                'category': '', 'product_type': '', 'expected_category': '', 'expected_product_type': '',
            }, 'inventory', 'admin'),
            ('POST', '/work/stock-limits', {
                'id': str(uuid4()), 'property_id': p.prop, 'input_id': p.diesel, 'minimum_quantity': '2',
            }, 'inventory', 'admin'),
            ('POST', f"/work/tasks/{task['id']}/progress", self.work.progress(task), 'tasks', 'worker'),
            ('POST', f"/work/orders/{order['id']}/assign", {
                'id': str(uuid4()), 'expected_version': order['version'],
                'mechanic_id': 'other-mechanic', 'priority': 'normal',
            }, 'workshop', 'admin'),
            ('POST', f"/work/orders/{order['id']}/reserve", {
                'id': str(uuid4()), 'expected_version': order['version'], 'input_id': p.diesel, 'quantity': '1',
            }, 'workshop', 'admin'),
            ('POST', f"/work/orders/{order['id']}/progress", self.work.progress(order), 'workshop', 'mechanic'),
            ('POST', f"/operations/{operation['id']}/void", {
                'id': str(uuid4()), 'reason': 'Estorno fictício', 'occurred_on': '2026-01-03',
            }, 'operations', 'admin'),
        ]
        for method, path, body, module, user in operations:
            with self.subTest(method=method, path=path, module=module):
                response = p.request(method, path, body, user=user, expected=409)
                self.assertEqual(response['code'], 'MODULE_DISABLED')
                self.assertEqual(response['resource'], module)

        self.assertEqual(p.stock(), initial_stock)
        self.assertEqual(p.request('GET', f"/operations/{operation['id']}"), initial_operation)
        current_tasks = p.request('GET', '/work/workspace', user='worker')['tasks']
        self.assertEqual([(row['id'], row['version']) for row in current_tasks], [(task['id'], task['version'])])
        current_order = p.request('GET', f"/work/orders/{order['id']}", user='mechanic')
        self.assertEqual(current_order['version'], order['version'])
        self.assertEqual(current_order['progress'], [])
        self.assertEqual(current_order['reservations'], [])

    def test_operation_without_tasks_module_cannot_complete_existing_task(self):
        task = self.work.task()
        p = self.pilot
        self.restrict('properties', 'fleet', 'inventory', 'operations')
        operation = {
            **p.operation(),
            'performed_on': date.today().isoformat(),
            'machines': [],
            'inputs': [],
        }
        linked = {
            **operation,
            'task_id': task['id'],
            'task_expected_version': task['version'],
        }
        rejected = p.post('/operations', linked, user='worker', expected=409)
        self.assertEqual(rejected['code'], 'MODULE_DISABLED')
        self.assertEqual(rejected['resource'], 'tasks')
        tasks = p.request('GET', '/work/workspace', user='worker')['tasks']
        self.assertEqual([(row['id'], row['status'], row['version']) for row in tasks],
                         [(task['id'], task['status'], task['version'])])
        self.assertEqual(p.post('/operations', operation, user='worker')['id'],
                         operation['id'])
