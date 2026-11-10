"""Logistics foundation: constraints, access and upgrade preservation.

No real database, account or emulator is used by these tests.
"""
import re
import sqlite3
import unittest
from datetime import datetime, timedelta, timezone
from uuid import uuid4

from fastapi import HTTPException
from pydantic import ValidationError
import test_v2_pilot as pilot
from agrogestor_server.logistics_schema import STATEMENTS
from agrogestor_server.logistics_models import TruckBody, DriverBody, TripBody, TripProgress, ExpenseBody
from agrogestor_server.logistics_access import effective_role, require_trip_access, require_driver_details


def drop_logistics(db):
    for statement in reversed(STATEMENTS):
        found = re.match(r'CREATE TABLE (\w+)', statement)
        if found:
            db.execute('DROP TABLE ' + found[1])
    db.execute('DELETE FROM v2_migrations WHERE version=8')


class FoundationTests(unittest.TestCase):
    def setUp(self):
        self.p = pilot.PilotTests()
        self.p.setUp()
        self.api = pilot.api

    def tearDown(self):
        self.p.tearDown()

    def account(self, key):
        with self.api.connect() as db:
            db.execute('''INSERT INTO users(user_id,farm_id,email,display_name,role,password_hash,created_at)
              VALUES(?,?,?,?,?,?,?)''', (key, 'org-a', key+'@example.invalid', key, 'operator', 'unused', self.api.utc_now()))
            db.execute('INSERT INTO v2_driver_accounts VALUES(?,?,?)', ('org-a', key, self.api.utc_now()))
            db.execute('''INSERT INTO devices(farm_id,device_id,device_name,activated_by,activated_at,last_seen_at)
              VALUES(?,?,?,?,?,?)''', ('org-a', 'device-'+key, 'Synthetic', key, self.api.utc_now(), self.api.utc_now()))
        self.p.tokens[key] = {'Authorization': 'Bearer '+self.api.make_token(key, 'org-a', 'device-'+key)}

    def fixture(self):
        self.account('driver-a')
        self.account('driver-b')
        self.driver, self.other_driver, self.trip = [str(uuid4()) for _ in range(3)]
        with self.api.connect() as db:
            db.execute('''INSERT INTO v2_trucks
              (tenant_id,id,plate,brand,model,vehicle_type,ownership,notes,archived,rate_components_json,version)
              VALUES(?,?,?,?,?,?,?,?,?,?,?)''', ('org-a', self.p.machine, 'ABC1D23', '', '', 'Caminhão', 'own', '', 0, '[]', 1))
            for key, user in [(self.driver, 'driver-a'), (self.other_driver, 'driver-b')]:
                db.execute('''INSERT INTO v2_drivers
                  (tenant_id,id,name,phone,employment,user_id,license_category,notes,archived,version)
                  VALUES(?,?,?,?,?,?,?,?,?,?)''', ('org-a', key, 'FICTÍCIO', '', 'employee', user, 'E', '', 0, 1))
            db.execute('''INSERT INTO v2_trips
              (tenant_id,id,name,truck_id,driver_id,transport_mode,property_id,origin,destination,
               planned_departure_at,planned_arrival_at,rate_components_json,status,notes,actor_id,created_at,version)
              VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
              ('org-a', self.trip, 'FICTÍCIO', self.p.machine, self.driver, 'own', self.p.prop,
               'Origem', 'Destino', '2026-01-01T10:00:00Z', '2026-01-01T15:00:00Z', '[]', 'scheduled', '', 'admin', self.api.utc_now(), 1))

    def test_upgrade_preserves_every_previous_row_and_separates_counters(self):
        self.p.opening()
        self.p.post('/operations', self.p.operation())
        with self.api.connect() as db:
            drop_logistics(db)
            tables = [r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name!='v2_migrations' ORDER BY name")]
            before = {t: [tuple(r) for r in db.execute('SELECT * FROM '+t)] for t in tables}
            checksums = [tuple(r) for r in db.execute('SELECT version,checksum FROM v2_migrations WHERE version<=7 ORDER BY version')]
        self.api.initialize_database()
        self.api.initialize_database()
        with self.api.connect() as db:
            for table, rows in before.items():
                self.assertEqual([tuple(r) for r in db.execute('SELECT * FROM '+table)], rows, table)
            self.assertEqual([tuple(r) for r in db.execute('SELECT version,checksum FROM v2_migrations WHERE version<=7 ORDER BY version')], checksums)
            self.assertEqual(db.execute('SELECT COUNT(*) FROM v2_migrations').fetchone()[0], 11)
            self.assertEqual(db.execute('SELECT COUNT(*) FROM v2_trucks').fetchone()[0], 0)
            self.assertEqual(db.execute('SELECT hour_meter FROM v2_machines').fetchone()[0], '103')
            self.assertEqual(db.execute('PRAGMA integrity_check').fetchone()[0], 'ok')
            self.assertEqual(db.execute('PRAGMA foreign_key_check').fetchall(), [])

    def test_accounts_are_restricted_even_after_unlink_archive_or_feature_disable(self):
        self.fixture()
        with self.api.connect() as db:
            row = db.execute("SELECT * FROM users WHERE user_id='driver-a'").fetchone()
            self.assertEqual(effective_role(db, row), 'driver')
            db.execute("UPDATE v2_drivers SET archived=1,user_id=NULL WHERE id=?", (self.driver,))
            self.assertEqual(effective_role(db, row), 'driver')
        self.api.V2_ENABLED = False
        self.p.request('GET', '/capabilities', user='driver-a', expected=503)
        response = self.p.http.get('/api/v1/auth/users', headers=self.p.tokens['driver-a'])
        self.assertEqual(response.status_code, 403)
        # No fallback to the broad v1 operator module set.
        response = self.p.http.get('/api/v1/sync/pull', headers=self.p.tokens['driver-a'])
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()['changes'], [])
        self.assertEqual(self.api.public_user(row)['role'], 'driver')

    def test_driver_cannot_use_field_routes_even_with_stale_property_grant(self):
        self.fixture()
        with self.api.connect() as db:
            db.execute('INSERT INTO v2_access VALUES(?,?,?,?)', ('org-a', 'driver-a', self.p.prop, 'employee'))
        for path in ['/workspace', '/properties', '/work/workspace',
                     '/properties/'+self.p.prop+'/machines', '/cycles/'+self.p.cycle+'/report']:
            self.p.request('GET', path, user='driver-a', expected=403)
        self.p.post('/operations', self.p.operation(), user='driver-a', expected=403)
        self.p.request('PUT', '/properties/'+self.p.prop+'/access',
                       {'user_id': 'driver-b', 'role': 'employee'}, expected=422)
        # Driver identities are absent from the operator/mechanic picker.
        users = self.p.request('GET', '/work/workspace')['users']
        self.assertFalse(any(u['id'].startswith('driver-') for u in users))

    def test_shared_property_does_not_grant_driver_access(self):
        self.fixture()
        prop = self.p.post('/properties', {'id': str(uuid4()), 'client_id': self.p.client_id,
          'name': 'FICTÍCIA compartilhada', 'share_with_operators': True})
        with self.api.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM v2_access WHERE property_id=? AND user_id LIKE 'driver-%'", (prop['id'],)).fetchone()[0], 0)

    def test_trip_access_checks_assignment_tenant_archive_and_disabled_account(self):
        self.fixture()
        user = {'id': 'driver-a', 'farmId': 'org-a', 'role': 'driver'}
        with self.api.connect() as db:
            self.assertEqual(require_trip_access(db, user, self.trip)['id'], self.trip)
            self.assertEqual(require_driver_details(db, user, self.driver)['id'], self.driver)
            for wrong in [user|{'id': 'driver-b'}, user|{'farmId': 'org-b'}, user|{'role': 'operator'}]:
                with self.assertRaises(HTTPException) as e:
                    require_trip_access(db, wrong, self.trip)
                self.assertEqual(e.exception.status_code, 404)
            with self.assertRaises(HTTPException):
                require_driver_details(db, user, self.other_driver)
            with self.assertRaises(HTTPException):
                require_trip_access(db, user, self.trip, administer=True)
            db.execute("UPDATE users SET disabled=1 WHERE user_id='driver-a'")
            with self.assertRaises(HTTPException):
                require_trip_access(db, user, self.trip)
            db.execute("UPDATE users SET disabled=0 WHERE user_id='driver-a'")
            db.execute('UPDATE v2_drivers SET archived=1 WHERE id=?', (self.driver,))
            with self.assertRaises(HTTPException):
                require_trip_access(db, user, self.trip)

    def test_foreign_tenant_relations_are_rejected_and_fleet_is_not_duplicated(self):
        self.fixture()
        with self.api.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM v2_machines').fetchone()[0], 1)
            self.assertIsNone(db.execute('SELECT odometer_km FROM v2_trucks').fetchone()[0])
            self.assertEqual(db.execute('SELECT hour_meter FROM v2_machines').fetchone()[0], '100')
            with self.assertRaises(sqlite3.IntegrityError):
                db.execute('UPDATE v2_trucks SET tenant_id=?', ('org-b',))
            with self.assertRaises(sqlite3.IntegrityError):
                db.execute('UPDATE v2_trips SET status=?', ('unknown',))
            with self.assertRaises(sqlite3.IntegrityError):
                db.execute('UPDATE v2_trips SET driver_id=?', (str(uuid4()),))
            with self.assertRaises(sqlite3.IntegrityError):
                db.execute('DELETE FROM v2_drivers WHERE id=?', (self.driver,))

    def test_expense_source_cannot_be_linked_twice_and_unknown_is_not_zero(self):
        self.fixture()
        source = str(uuid4())
        with self.api.connect() as db:
            sql = '''INSERT INTO v2_trip_expenses
              (tenant_id,id,trip_id,category,description,amount_cents,source_kind,source_id,occurred_on,actor_id,created_at)
              VALUES(?,?,?,?,?,?,?,?,?,?,?)'''
            values = ('org-a', str(uuid4()), self.trip, 'fuel', 'FICTÍCIO', None, 'refueling', source, '2026-01-01', 'admin', self.api.utc_now())
            db.execute(sql, values)
            with self.assertRaises(sqlite3.IntegrityError):
                db.execute(sql, values[:1]+(str(uuid4()),)+values[2:])
            self.assertIsNone(db.execute('SELECT amount_cents FROM v2_trip_expenses').fetchone()[0])

    def test_cargo_delivery_cannot_create_two_stock_receipts(self):
        self.fixture()
        cargo, receipt = str(uuid4()), str(uuid4())
        with self.api.connect() as db:
            db.execute('''INSERT INTO v2_trip_cargo(tenant_id,id,trip_id,name,kind,input_id,unit)
              VALUES(?,?,?,?,?,?,?)''', ('org-a', cargo, self.trip, 'Insumo FICTÍCIO', 'input', self.p.diesel, 'L'))
            self.assertEqual(db.execute('SELECT COUNT(*) FROM v2_inventory').fetchone()[0], 0)
        self.p.opening(quantity='1', value=None)
        self.p.post('/properties/'+self.p.prop+'/inventory', {'id': receipt, 'input_id': self.p.diesel,
                    'kind': 'receipt', 'quantity': '2', 'value_cents': None, 'occurred_on': '2026-01-01'})
        with self.api.connect() as db:
            db.execute('INSERT INTO v2_trip_deliveries VALUES(?,?,?,?,?)', ('org-a', cargo, receipt, 'admin', self.api.utc_now()))
            with self.assertRaises(sqlite3.IntegrityError):
                db.execute('INSERT INTO v2_trip_deliveries VALUES(?,?,?,?,?)', ('org-a', cargo, receipt, 'admin', self.api.utc_now()))
            self.assertEqual(db.execute("SELECT COUNT(*) FROM v2_inventory WHERE kind='receipt'").fetchone()[0], 1)


class ContractTests(unittest.TestCase):
    def test_capacity_plate_rate_and_third_party_contract(self):
        body = dict(id=uuid4(), plate='abc-1d23', vehicle_type='Caminhão', ownership='own')
        truck = TruckBody(**body)
        self.assertEqual(truck.plate, 'ABC1D23')
        self.assertIsNone(truck.odometer_km)
        for changes in [{'capacity': '10'}, {'ownership': 'contracted'}, {'odometer_km': '-1'},
                        {'per_km_cents': 1.5}, {'rate_components': ['fuel']}, {'plate': '../x'}]:
            with self.assertRaises(ValidationError):
                TruckBody(**(body|changes))
        self.assertEqual(TruckBody(**(body|{'ownership': 'contracted', 'carrier_id': uuid4()})).ownership, 'contracted')

    def test_driver_carrier_and_unknown_documents(self):
        body = dict(id=uuid4(), name='FICTÍCIO', employment='carrier')
        with self.assertRaises(ValidationError):
            DriverBody(**body)
        self.assertIsNone(DriverBody(**(body|{'carrier_id': uuid4()})).license_expires_on)

    def test_manual_allocations_conserve_cents_and_reject_duplicate_destinations(self):
        prop1, prop2 = uuid4(), uuid4()
        body = dict(id=uuid4(), category='toll', description='FICTÍCIO', amount_cents=1001,
                    occurred_on='2026-01-01', allocations=[
                        {'id': uuid4(), 'property_id': prop1, 'amount_cents': 500},
                        {'id': uuid4(), 'property_id': prop2, 'amount_cents': 501}])
        self.assertEqual(sum(a.amount_cents for a in ExpenseBody(**body).allocations), 1001)
        for changes in [{'amount_cents': 1000}, {'amount_cents': None}, {'amount_cents': 1001.0},
                        {'category': 'fuel'}, {'category': 'maintenance'}]:
            with self.assertRaises(ValidationError):
                ExpenseBody(**(body|changes))
        repeated = [body['allocations'][0], body['allocations'][1]|{'property_id': prop1}]
        with self.assertRaises(ValidationError):
            ExpenseBody(**(body|{'allocations': repeated}))

    def test_trip_does_not_assume_unit_conversion_or_dates_without_timezone(self):
        body = dict(id=uuid4(), name='FICTÍCIO', truck_id=uuid4(), driver_id=uuid4(), transport_mode='own',
                    property_id=uuid4(), origin='Origem', destination='Destino',
                    planned_departure_at='2026-01-01T10:00:00-03:00', planned_arrival_at='2026-01-01T12:00:00-03:00',
                    cargo=[{'id': uuid4(), 'name': 'Café', 'kind': 'coffee', 'unit': 'saca', 'planned_quantity': '10'}])
        self.assertIsNone(TripBody(**body).cargo[0].tonnes_per_unit)
        for change in [{'planned_arrival_at': '2025-01-01T10:00:00-03:00'},
                       {'planned_departure_at': '2026-01-01T10:00:00'}, {'contracted_freight_cents': 1000},
                       {'cargo': body['cargo']*2}]:
            with self.assertRaises(ValidationError):
                TripBody(**(body|change))

    def test_unknown_expense_has_no_invented_allocation(self):
        body = dict(id=uuid4(), category='other', description='Comprovante FICTÍCIO sem valor', occurred_on='2026-01-01')
        expense = ExpenseBody(**body)
        self.assertIsNone(expense.amount_cents)
        self.assertEqual(expense.allocations, [])
        with self.assertRaises(ValidationError):
            ExpenseBody(**(body|{'allocations': [{'id': uuid4(), 'property_id': uuid4(), 'amount_cents': 0}]}))

    def test_progress_preserves_missing_quantities_and_validates_event_clock(self):
        now = datetime.now(timezone.utc)
        body = dict(id=uuid4(), expected_version=1, status='loading', description='FICTÍCIO', occurred_at=now-timedelta(minutes=1),
                    cargo=[{'cargo_id': uuid4(), 'loaded_quantity': '0'}])
        event = TripProgress(**body)
        self.assertEqual(event.cargo[0].loaded_quantity, 0)
        self.assertIsNone(event.cargo[0].delivered_quantity)
        for change in [{'start_km': '100', 'end_km': '99'}, {'occurred_at': now+timedelta(days=1)},
                       {'expected_version': True}, {'cargo': body['cargo']*2}]:
            with self.assertRaises(ValidationError):
                TripProgress(**(body|change))


if __name__ == '__main__':
    unittest.main()
