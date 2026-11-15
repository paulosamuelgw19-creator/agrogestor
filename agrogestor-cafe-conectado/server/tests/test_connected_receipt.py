"""API acceptance tests for immutable coffee receipts."""
import json
import unittest
from unittest.mock import patch
from uuid import NAMESPACE_URL, uuid4, uuid5

import test_connected_harvest as harvest
from agrogestor_server import cli


class ConnectedReceiptTests(unittest.TestCase):
    module = "coffeeHarvestReceipts"

    def setUp(self):
        self.fixture = harvest.ConnectedHarvestTests()
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.setUp()
        self.server = self.fixture.server

    def push_harvest(self, payload, module="coffeePlotProduction", base=0):
        result = self.server.push(
            self.server.a, self.fixture.event(module, payload, base=base),
        )
        self.assertEqual(len(result["acknowledged"]), 1, result)

    def declare(self, quantity=600, base=0):
        payload = self.fixture.declaration(unit="liters", quantity=quantity)
        del payload["remainderLiters"]
        self.push_harvest(payload, base=base)

    def source(self, *, headers=None, expected=200, **scope):
        response = self.server.http.get(
            "/api/v1/coffee/harvest-source",
            headers=headers or self.server.a,
            params={
                "propertyId": self.server.farm, "plotId": self.server.plot,
                "seasonYear": self.fixture.season, "harvestDate": self.fixture.day,
                **scope,
            },
        )
        self.assertEqual(response.status_code, expected, response.text)
        return response.json()

    def receipt(self, source, **fields):
        scope = [self.server.farm, self.server.plot, self.fixture.season, self.fixture.day]
        key = json.dumps(scope, ensure_ascii=False, separators=(",", ":"))
        return {
            "id": str(uuid5(NAMESPACE_URL, f"agrogestor:{self.module}:{key}")),
            "propertyId": scope[0], "plotId": scope[1],
            "seasonYear": scope[2], "harvestDate": scope[3],
            "receivedDate": "2026-11-14", "receivedLiters": 580, **source, **fields,
        }

    def event(self, payload, **options):
        return self.fixture.event(self.module, payload, **options)

    def receipts(self, headers):
        return [
            row for row in self.server.pull(headers)["changes"]
            if row["module"] == self.module
        ]

    def test_receipt_sync_replay_overlapping_devices_and_immutability(self):
        self.declare()
        self.push_harvest(self.fixture.worker_entry(quantity=590), "coffeeHarvestEntries")
        source = self.source(headers=self.server.b)
        self.assertEqual(source["fieldLiters"], 600)
        receipt = self.receipt(source)
        event = self.event(receipt)
        acknowledged = self.server.push(self.server.a, event)
        self.assertEqual(acknowledged["acknowledged"], [
            {"eventId": event["eventId"], "version": 1},
        ])
        self.assertEqual(self.server.push(self.server.b, event), acknowledged)
        tampered = {**event, "payload": {**receipt, "receivedLiters": 579}}
        self.assertEqual(len(self.server.push(self.server.b, tampered)["rejected"]), 1)

        competing = self.event({**receipt, "receivedLiters": 575})
        conflict = self.server.push(self.server.b, competing)["conflicts"][0]
        self.assertEqual(conflict["serverVersion"], 1)
        self.assertEqual(conflict["serverPayload"], receipt)
        foreign_id = self.event({**receipt, "id": str(uuid4())})
        edit = self.event({**receipt, "receivedLiters": 575}, base=1)
        delete = self.event(receipt, base=1, operation="delete")
        self.assertEqual(len(self.server.push(self.server.b, foreign_id, edit, delete)["rejected"]), 3)
        pulled = self.receipts(self.server.b)
        self.assertEqual(len(pulled), 1)
        self.assertEqual(pulled[0]["payload"], receipt)
        self.assertEqual(receipt["fieldLiters"] - receipt["receivedLiters"], 20)

        # A subsequent correction to production cannot rewrite the receipt snapshot.
        self.declare(quantity=610, base=1)
        self.assertEqual(self.source()["fieldLiters"], 610)
        self.assertEqual(self.receipts(self.server.a)[0]["payload"]["fieldLiters"], 600)
        backup = self.server.root / "receipt-backup"
        cli.backup(backup)
        with harvest.fixtures.api.connect() as db:
            db.execute("DELETE FROM records WHERE module=?", (self.module,))
            db.execute("DELETE FROM changes WHERE module=?", (self.module,))
        self.assertEqual(self.receipts(self.server.a), [])
        cli.restore(backup)
        self.assertEqual(self.receipts(self.server.b), pulled)

    def test_worker_only_source_revisions_and_scope(self):
        self.source(expected=404)
        entry = self.fixture.worker_entry(quantity=300)
        self.push_harvest(entry, "coffeeHarvestEntries")
        original = self.source()
        self.assertEqual(original["fieldLiters"], 300)
        self.push_harvest(self.fixture.worker_entry(quantity=280), "coffeeHarvestEntries")
        current = self.source()
        self.assertEqual(current["fieldLiters"], 580)
        self.assertNotEqual(current["sourceRevision"], original["sourceRevision"])
        for stale in (original, {**current, "fieldLiters": 579}):
            result = self.server.push(self.server.b, self.event(self.receipt(stale)))
            self.assertEqual(result["rejected"][0]["code"], "HARVEST_SOURCE_CHANGED")
        self.source(expected=404, seasonYear=self.fixture.season - 1)
        self.source(expected=404, harvestDate="2026-11-12")
        invalid_date = self.event(self.receipt(current, receivedDate="2026-11-12"))
        self.assertEqual(len(self.server.push(self.server.b, invalid_date)["rejected"]), 1)
        saved = self.event(self.receipt(current))
        self.assertEqual(self.server.push(self.server.b, saved)["acknowledged"][0]["version"], 1)

    def test_other_roles_and_organization_cannot_access_receipt(self):
        self.declare()
        receipt = self.event(self.receipt(self.source()))
        self.assertEqual(len(self.server.push(self.server.a, receipt)["acknowledged"]), 1)
        operator = self.server.login("operator", "operador-recebimento-01")
        mechanic = self.server.login("mechanic", "mecanico-recebimento-01")
        for headers in (operator, mechanic):
            self.source(headers=headers, expected=403)
            self.server.pull(headers, expected=403)
            self.server.push(headers, receipt, expected=403)
        with patch.object(harvest.fixtures.api, "V2_ENABLED", False):
            self.source(expected=404)
            self.assertEqual(self.receipts(self.server.a), [])

        with self.server.use_server("org-cafe-b"):
            self.server.seed("org-cafe-b")
            manager = self.server.login("admin", self.server.device_a, "org-cafe-b")
            self.source(headers=manager, expected=404)
            self.source(headers=self.server.a, expected=401)
            self.assertEqual(self.receipts(manager), [])
            foreign = {**receipt, "eventId": str(uuid4())}
            denied = self.server.push(manager, foreign)["rejected"][0]
            self.assertEqual(denied["code"], "HARVEST_SOURCE_NOT_FOUND")
