"""API coverage for connected lots and sale receipts with a temporary database."""
import unittest
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
from uuid import uuid4

import test_connected_receipt as fixtures


class ConnectedProcessingTests(unittest.TestCase):
    lot_module = "coffeeProcessingLots"
    payment_module = "coffeeSaleReceipts"

    def setUp(self):
        self.fixture = fixtures.ConnectedReceiptTests()
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.setUp()
        self.server = self.fixture.server
        self.fixture.declare(quantity=460)
        self.receipt = self.fixture.receipt(self.fixture.source(), receivedLiters=440)
        self.accept(self.fixture.event(self.receipt))

    def event(self, payload, *, module=None, base=0):
        return self.fixture.fixture.event(module or self.lot_module, payload, base=base)

    def accept(self, event, headers=None, version=1):
        result = self.server.push(headers or self.server.a, event)
        self.assertEqual(result["acknowledged"], [{"eventId": event["eventId"], "version": version}], result)
        self.assertEqual(result["rejected"], [])
        self.assertEqual(result["conflicts"], [])

    def lot(self, code, liters):
        return {
            "id": str(uuid4()), "propertyId": self.receipt["propertyId"],
            "seasonYear": self.receipt["seasonYear"], "code": code,
            "date": self.receipt["receivedDate"], "location": "Terreiro fictício", "notes": "",
            "inputs": [{
                "id": str(uuid4()), "kind": "picked", "origin": "confirmed",
                "receiptId": self.receipt["id"], "volumeLiters": liters, "notes": "",
            }],
            "measurements": [], "cleanings": [], "sales": [],
        }

    def payment(self, lot, amount, *, sale_id=None):
        return {
            "id": str(uuid4()), "propertyId": lot["propertyId"], "lotId": lot["id"],
            "saleId": sale_id or lot["sales"][0]["id"], "date": "2027-01-10",
            "amountCents": amount, "notes": "Parcela fictícia",
        }

    def test_two_devices_allocate_440_liters_and_preserve_cash_and_stock(self):
        a, b = self.server.a, self.server.b
        first, second = self.lot("A", 300), self.lot("B", 140)
        opened = self.event(first)
        self.accept(opened, a)
        self.accept(opened, b)
        self.accept(self.event(second), b)
        extra = self.server.push(a, self.event(self.lot("EXCESSO", 1)))
        self.assertEqual(extra["rejected"][0]["code"], "COFFEE_RECEIPT_OVERALLOCATED")
        changed = {**opened, "payload": {**first, "location": "Outro local"}}
        self.assertEqual(len(self.server.push(b, changed)["rejected"]), 1)

        cleaning = {
            "id": str(uuid4()), "date": "2026-11-18", "unit": "bags", "quantity": 1,
            "kgPerBag": 60, "remainderKg": 10, "inputLiters": 200,
            "inputBase": "ripe", "notes": "",
        }
        cleaned = {**first, "cleanings": [cleaning]}
        self.accept(self.event(cleaned, base=1), a, 2)
        sale = {
            "id": str(uuid4()), "date": "2026-11-20", "unit": "kilograms",
            "quantity": 40, "totalPriceCents": 100000, "buyer": "Comprador fictício",
            "notes": "",
        }
        too_early = self.event({**cleaned, "sales": [{**sale, "date": "2026-11-16"}]}, base=2)
        self.assertEqual(self.server.push(a, too_early)["rejected"][0]["code"],
                         "COFFEE_LOT_STOCK_INSUFFICIENT")
        sold = {**cleaned, "sales": [sale]}
        self.accept(self.event(sold, base=2), b, 3)
        extra_sale = {**sale, "id": str(uuid4()), "quantity": 31}
        denied = self.server.push(a, self.event({**sold, "sales": [sale, extra_sale]}, base=3))
        self.assertEqual(denied["rejected"][0]["code"], "COFFEE_LOT_STOCK_INSUFFICIENT")
        self.assertEqual(len(self.server.push(a, self.event(cleaned, base=3))["rejected"]), 1)

        paid = self.payment(sold, 35000)
        pay_event = self.event(paid, module=self.payment_module)
        self.accept(pay_event, a)
        self.accept(pay_event, b)
        overpaid = self.event(self.payment(sold, 65001), module=self.payment_module)
        self.assertEqual(self.server.push(b, overpaid)["rejected"][0]["code"],
                         "COFFEE_SALE_RECEIPT_EXCEEDS_BALANCE")
        updated = self.event({**paid, "amountCents": 34000}, base=1, module=self.payment_module)
        self.assertEqual(len(self.server.push(a, updated)["rejected"]), 1)
        rows = self.server.pull(a)["changes"]
        closed = [row for row in rows if row["recordId"] == first["id"]][-1]
        self.assertEqual(closed["version"], 3)
        self.assertEqual(closed["payload"], sold)
        self.assertEqual(cleaning["kgPerBag"] + cleaning["remainderKg"] - sale["quantity"], 30)
        payments = [row["payload"] for row in rows if row["module"] == self.payment_module]
        self.assertEqual(payments, [paid])
        self.assertEqual(sale["totalPriceCents"] - sum(row["amountCents"] for row in payments), 65000)

    def test_competing_lot_ids_and_access_boundaries(self):
        barrier = Barrier(2, timeout=15)

        def submit(headers, payload):
            barrier.wait()
            return self.server.push(headers, self.event(payload))

        with ThreadPoolExecutor(max_workers=2) as pool:
            results = [pool.submit(submit, headers, self.lot(code, 300))
                       for headers, code in [(self.server.a, "RACE A"), (self.server.b, "RACE B")]]
            documents = [future.result(timeout=30) for future in results]
        self.assertEqual(sum(len(result["acknowledged"]) for result in documents), 1)
        rejected = [item for result in documents for item in result["rejected"]]
        self.assertEqual([item["code"] for item in rejected], ["COFFEE_RECEIPT_OVERALLOCATED"])

        for role in ("operator", "mechanic"):
            headers = self.server.login(role, f"beneficiamento-{role}-teste")
            self.server.pull(headers, expected=403)
            self.server.push(headers, self.event(self.lot("SEM ACESSO", 1)), expected=403)
        with self.server.use_server("org-cafe-b"):
            self.server.seed("org-cafe-b")
            foreign = self.server.login("admin", self.server.device_a, "org-cafe-b")
            self.server.pull(self.server.a, expected=401)
            self.assertEqual(self.server.pull(foreign)["changes"], [])
            foreign_farm, _ = self.server.catalog(foreign)
            stolen = {**self.lot("OUTRA ORGANIZAÇÃO", 1), "propertyId": foreign_farm}
            self.assertEqual(len(self.server.push(foreign, self.event(stolen))["rejected"]), 1)
