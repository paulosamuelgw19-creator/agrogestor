"""Connected harvest API acceptance tests with isolated SQLite databases."""
import json
import unittest
from uuid import NAMESPACE_URL, uuid4, uuid5

import test_connected_notebook as fixtures


class ConnectedHarvestTests(unittest.TestCase):
    day = "2026-11-13"
    season = 2026
    worker_id = "worker-harvest-test"

    def setUp(self):
        self.server = fixtures.ConnectedNotebookTests()
        self.addCleanup(self.server.doCleanups)
        self.server.setUp()
        worker = self.event("operators", {
            "id": self.worker_id, "name": "Trabalhador fictício", "phone": "",
            "role": "Colhedor", "active": True,
        })
        result = self.server.push(self.server.a, worker)
        self.assertEqual(result["acknowledged"], [{"eventId": worker["eventId"], "version": 1}])

    def event(self, module, payload, *, base=0, operation="upsert"):
        return {
            "eventId": str(uuid4()), "module": module, "recordId": payload["id"],
            "baseVersion": base, "operation": operation,
            "payload": payload if operation == "upsert" else None,
        }

    def declaration(self, day=None, **fields):
        day = day or self.day
        scope = [self.server.farm, self.server.plot, self.season, day]
        identity = uuid5(
            NAMESPACE_URL,
            "agrogestor:coffeePlotProduction:" +
            json.dumps(scope, ensure_ascii=False, separators=(",", ":")),
        )
        return {
            "id": str(identity), "propertyId": scope[0], "plotId": scope[1],
            "seasonYear": scope[2], "date": day + "T00:00:00.000",
            "unit": "measures", "quantity": 7, "litersPerMeasure": 60,
            "remainderLiters": 40, **fields,
        }

    def worker_entry(self, **fields):
        payload = self.declaration(
            id=str(uuid4()), workerId=self.worker_id, workerName="Trabalhador fictício",
            unit="liters", quantity=460,
        )
        del payload["remainderLiters"]
        return {**payload, **fields}

    @staticmethod
    def volume(payload):
        match payload["unit"]:
            case "measures":
                return (payload["quantity"] * payload["litersPerMeasure"] +
                        payload.get("remainderLiters", 0))
            case "liters":
                return payload["quantity"]
            case "carts":
                return payload["quantity"] * payload["cartCapacityLiters"]
            case unit:
                raise AssertionError(f"Unexpected unit from API: {unit}")

    def test_measures_liters_and_carts_sync_between_manager_devices(self):
        a, b = self.server.a, self.server.b
        self.assertNotEqual(a, b)
        mixed = self.declaration()
        liters = self.declaration("2026-11-14", unit="liters", quantity=320)
        carts = self.declaration("2026-11-15", unit="carts", quantity=1.5,
                                 cartCapacityLiters=250)
        del liters["remainderLiters"]
        del carts["remainderLiters"]
        submitted = [
            self.event("coffeePlotProduction", value) for value in (mixed, liters, carts)
        ]
        first = self.server.push(a, *submitted)
        self.assertEqual(len(first["acknowledged"]), 3)
        self.assertEqual(self.server.push(a, *submitted), first)
        fetched = [
            row for row in self.server.pull(b)["changes"]
            if row["module"] == "coffeePlotProduction"
        ]
        self.assertEqual([self.volume(row["payload"]) for row in fetched], [460, 320, 375])
        self.assertEqual([row["payload"] for row in fetched], [mixed, liters, carts])

        duplicate = self.event("coffeePlotProduction", {**mixed, "quantity": 8})
        conflicting = self.server.push(b, duplicate)
        self.assertEqual(conflicting["conflicts"][0]["serverVersion"], 1)
        self.assertEqual(conflicting["conflicts"][0]["serverPayload"], mixed)
        tampered_replay = {**submitted[0], "payload": {**mixed, "quantity": 8}}
        self.assertEqual(len(self.server.push(a, tampered_replay)["rejected"]), 1)
        duplicate_id = self.event("coffeePlotProduction", {**mixed, "id": str(uuid4())})
        rejection = self.server.push(b, duplicate_id)["rejected"][0]
        self.assertEqual(rejection["code"], "HARVEST_DAY_ALREADY_DECLARED")
        updated = self.event("coffeePlotProduction", {**mixed, "quantity": 8}, base=1)
        self.assertEqual(self.server.push(b, updated)["acknowledged"][0]["version"], 2)
        delta = self.server.pull(a, fetched[-1]["cursor"])["changes"]
        self.assertEqual(len(delta), 1)
        self.assertEqual(self.volume(delta[0]["payload"]), 520)

    def test_conference_accepts_only_current_volume_and_no_financial_data(self):
        a, b = self.server.a, self.server.b
        production = self.declaration()
        entry = self.worker_entry()
        self.assertEqual(len(self.server.push(
            a, self.event("coffeePlotProduction", production),
            self.event("coffeeHarvestEntries", entry),
        )["acknowledged"]), 2)
        valid = self.event("coffeePlotProduction", {
            **production, "checkedWorkerLiters": 460,
        }, base=1)
        self.assertEqual(self.server.push(b, valid)["acknowledged"][0]["version"], 2)
        extra = self.worker_entry(quantity=50)
        self.assertEqual(len(self.server.push(
            a, self.event("coffeeHarvestEntries", extra),
        )["acknowledged"]), 1)
        stale = self.event("coffeePlotProduction", valid["payload"], base=2)
        self.assertEqual(self.server.push(b, stale)["rejected"][0]["code"],
                         "HARVEST_WORKER_TOTAL_CHANGED")
        rechecked = self.event("coffeePlotProduction", {
            **production, "checkedWorkerLiters": 510,
        }, base=2)
        self.assertEqual(self.server.push(b, rechecked)["acknowledged"][0]["version"], 3)

        paid = self.event("coffeeHarvestPayments", {"id": str(uuid4()), "amountCents": 100})
        rate = self.event("coffeeHarvestEntries", self.worker_entry(ratePerMeasureCents=3000))
        disguised = self.event("coffeePlotProduction", {
            **production, "checkedWorkerLiters": 510, "amountCents": 100,
        }, base=3)
        delete = self.event("coffeeHarvestEntries", entry, base=1, operation="delete")
        rejected = self.server.push(a, paid, rate, disguised, delete)
        self.assertEqual(len(rejected["rejected"]), 4)
        self.assertEqual(rejected["acknowledged"], [])
        pulled = self.server.pull(b)["changes"]
        self.assertFalse(any(row["module"] == "coffeeHarvestPayments" for row in pulled))
        scoped = [row["payload"] for row in pulled if row["module"] == "coffeeHarvestEntries"]
        self.assertEqual(scoped, [entry, extra])

    def test_offline_conference_can_be_saved_with_the_first_declaration(self):
        a, b = self.server.a, self.server.b
        reviewed = self.event("coffeePlotProduction",
                              self.declaration(quantity=8, checkedWorkerLiters=460))
        worker = self.event("coffeeHarvestEntries", self.worker_entry())
        pending = self.server.push(a, reviewed, worker)
        self.assertEqual(pending["rejected"][0]["code"], "HARVEST_WORKER_TOTAL_CHANGED")
        self.assertEqual(pending["acknowledged"], [{"eventId": worker["eventId"], "version": 1}])
        expected = [{"eventId": reviewed["eventId"], "version": 1}]
        self.assertEqual(self.server.push(a, reviewed)["acknowledged"], expected)
        self.assertEqual(self.server.push(a, reviewed)["acknowledged"], expected)
        pulled = [item["payload"] for item in self.server.pull(b)["changes"]
                  if item["module"] == "coffeePlotProduction"]
        self.assertEqual(pulled, [reviewed["payload"]])

    def test_profiles_and_organization_cannot_read_or_write_foreign_harvest(self):
        operator = self.server.login("operator", "operador-colheita-teste-01")
        mechanic = self.server.login("mechanic", "mecanico-colheita-teste-01")
        declaration = self.event("coffeePlotProduction", self.declaration())
        self.assertEqual(len(self.server.push(self.server.a, declaration)["acknowledged"]), 1)
        for headers in (operator, mechanic):
            self.server.pull(headers, expected=403)
            self.server.push(headers, declaration, expected=403)

        with self.server.use_server("org-cafe-b"):
            self.server.seed("org-cafe-b")
            remote = self.server.login("admin", self.server.device_a, "org-cafe-b")
            self.server.pull(self.server.a, expected=401)
            self.assertEqual(self.server.pull(remote)["changes"], [])
            result = self.server.push(remote, declaration)
            self.assertIn("talhão", result["rejected"][0]["message"])
            other_farm, other_plot = self.server.catalog(remote)
            # Even a valid local property is paired with its own plot.
            mismatched = self.event("coffeePlotProduction", {
                **declaration["payload"], "propertyId": other_farm,
                "plotId": self.server.plot,
            })
            self.assertIn("talhão", self.server.push(remote, mismatched)["rejected"][0]["message"])
            self.assertNotEqual(other_plot, self.server.plot)
            self.assertEqual(self.server.pull(remote)["changes"], [])
        self.server.pull(remote, expected=401)
