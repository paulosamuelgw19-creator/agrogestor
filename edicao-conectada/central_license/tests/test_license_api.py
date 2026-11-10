import atexit
import os
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
_bootstrap = tempfile.TemporaryDirectory(prefix="agrogestor-central-tests-")
atexit.register(_bootstrap.cleanup)
os.environ["AGROGESTOR_LICENSE_DATA_DIR"] = _bootstrap.name
os.environ["AGROGESTOR_LICENSE_JWT_SECRET"] = "test-central-secret-with-more-than-32-characters"
os.environ["AGROGESTOR_LICENSE_SERVER_API_KEY"] = "test-central-server-key-with-more-than-32-characters"

from license_server import app as api


class CentralLicenseTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="agrogestor-central-case-")
        api.DATA_DIR = Path(self.temp.name)
        api.DB_PATH = api.DATA_DIR / "licenses.sqlite3"
        self.original_clock = api.now_utc
        self.clock = datetime.now(timezone.utc)
        api.now_utc = lambda: self.clock
        api.initialize_database()
        with api.connect() as db:
            db.execute("INSERT INTO admins VALUES(?,?,?)", (
                "admin-test", api.password_hash.hash("TemporaryCentralPassword!2026"), api.iso(self.clock),
            ))
        self.http = httpx.AsyncClient(
            transport=httpx.ASGITransport(app=api.app), base_url="http://test-central",
        )
        login = await self.http.post("/api/v1/admin/login", json={
            "username": "admin-test", "password": "TemporaryCentralPassword!2026",
        })
        self.assertEqual(login.status_code, 200, login.text)
        self.admin = {"Authorization": f"Bearer {login.json()['token']}"}
        self.server = {"X-Agrogestor-License-Key": api.SERVER_API_KEY}

    async def asyncTearDown(self):
        api.now_utc = self.original_clock
        await self.http.aclose()
        self.temp.cleanup()

    async def issue(self, plan="monthly"):
        result = await self.http.post("/api/v1/admin/licenses", headers=self.admin, json={"plan": plan})
        self.assertEqual(result.status_code, 200, result.text)
        return result.json()

    async def activate(self, issued, farm="farm-alpha"):
        return await self.http.post("/activateLicense", headers=self.server, json={
            "farmId": farm, "farmName": "Fazenda de teste", "licenseKey": issued["licenseKey"],
        })

    async def test_activation_is_idempotent_and_cannot_renew_expired_license(self):
        issued = await self.issue()
        first = await self.activate(issued)
        self.assertEqual(first.status_code, 200, first.text)
        self.clock += timedelta(days=10)
        second = await self.activate(issued)
        self.assertEqual(second.json()["expiresAt"], first.json()["expiresAt"])
        self.clock += timedelta(days=21)
        self.assertEqual((await self.activate(issued)).status_code, 409)
        checked = await self.http.post("/checkLicense", headers=self.server, json={"farmId": "farm-alpha"})
        self.assertEqual(checked.json()["status"], "inactive")
        with api.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM license_events WHERE action='activated'").fetchone()[0], 1)

    async def test_activation_registers_farm_and_refuses_other_farm(self):
        issued = await self.issue()
        self.assertEqual((await self.activate(issued)).status_code, 200)
        self.assertEqual((await self.activate(issued, "farm-beta")).status_code, 409)
        farms = await self.http.get("/api/v1/admin/farms", headers=self.admin)
        self.assertEqual(farms.json()["farms"][0]["farmId"], "farm-alpha")
        with api.connect() as db:
            stored = db.execute("SELECT key_hash FROM licenses").fetchone()[0]
        self.assertNotEqual(stored, issued["licenseKey"])

    async def test_only_admin_can_revoke_or_transfer(self):
        issued = await self.issue()
        await self.activate(issued)
        for route, body in [
            ("/revokeLicense", {"licenseId": issued["licenseId"]}),
            ("/transferLicense", {"licenseId": issued["licenseId"], "newFarmId": "farm-beta"}),
        ]:
            denied = await self.http.post(route, headers=self.server, json=body)
            self.assertEqual(denied.status_code, 401, denied.text)
        revoked = await self.http.post("/revokeLicense", headers=self.admin, json={"licenseId": issued["licenseId"]})
        self.assertEqual(revoked.status_code, 200, revoked.text)
        self.assertEqual((await self.activate(issued)).status_code, 409)

    async def test_transfer_preserves_expiry_and_requires_registered_destination(self):
        issued = await self.issue()
        activated = await self.activate(issued)
        body = {"licenseId": issued["licenseId"], "newFarmId": "farm-beta"}
        self.assertEqual((await self.http.post("/transferLicense", headers=self.admin, json=body)).status_code, 404)
        await self.http.post("/checkLicense", headers=self.server, json={"farmId": "farm-beta"})
        transferred = await self.http.post("/transferLicense", headers=self.admin, json=body)
        self.assertEqual(transferred.status_code, 200, transferred.text)
        checked = await self.http.post("/checkLicense", headers=self.server, json={"farmId": "farm-beta"})
        self.assertEqual(checked.json()["expiresAt"], activated.json()["expiresAt"])

    async def test_trial_is_stable_and_expires(self):
        first = await self.http.post("/checkLicense", headers=self.server, json={"farmId": "trial-farm"})
        self.clock += timedelta(days=1)
        second = await self.http.post("/checkLicense", headers=self.server, json={"farmId": "trial-farm"})
        self.assertEqual(second.json()["trialEndsAt"], first.json()["trialEndsAt"])
        self.clock += timedelta(days=30)
        expired = await self.http.post("/checkLicense", headers=self.server, json={"farmId": "trial-farm"})
        self.assertEqual(expired.json()["status"], "expired")

    async def test_suspend_and_renew_require_admin_and_are_effective(self):
        issued = await self.issue()
        await self.activate(issued)
        url = "/api/v1/admin/farms/farm-alpha/license"
        self.assertEqual((await self.http.post(url, headers=self.server, json={"action": "renew"})).status_code, 401)
        self.assertEqual((await self.http.post(url, headers=self.admin, json={"action": "suspend"})).status_code, 200)
        checked = await self.http.post("/checkLicense", headers=self.server, json={"farmId": "farm-alpha"})
        self.assertEqual(checked.json()["status"], "inactive")
        renewed = await self.http.post(url, headers=self.admin, json={"action": "renew"})
        self.assertEqual(renewed.status_code, 200, renewed.text)
        checked = await self.http.post("/checkLicense", headers=self.server, json={"farmId": "farm-alpha"})
        self.assertEqual(checked.json()["status"], "active")

    async def test_invalid_bodies_and_missing_credentials_are_rejected(self):
        for body in [[], "text", None, {"farmId": 42}]:
            response = await self.http.post("/checkLicense", headers=self.server, json=body)
            self.assertEqual(response.status_code, 422, response.text)
        self.assertEqual((await self.http.post("/checkLicense", json={"farmId": "alpha"})).status_code, 401)
        self.assertEqual((await self.http.get("/api/v1/admin/licenses")).status_code, 401)

    async def test_token_needs_expiry_and_existing_admin(self):
        token = api.jwt.encode({"sub": "admin-test", "role": "admin"}, api.JWT_SECRET, algorithm="HS256")
        response = await self.http.get("/api/v1/admin/me", headers={"Authorization": f"Bearer {token}"})
        self.assertEqual(response.status_code, 401)
        with api.connect() as db:
            db.execute("DELETE FROM admins")
        self.assertEqual((await self.http.get("/api/v1/admin/me", headers=self.admin)).status_code, 401)

    async def test_login_limits_repeated_bad_passwords(self):
        name = "throttle-test"
        api.login_throttle.clear(name)
        body = {"username": name, "password": "WrongPassword"}
        for _ in range(8):
            self.assertEqual((await self.http.post("/api/v1/admin/login", json=body)).status_code, 401)
        limited = await self.http.post("/api/v1/admin/login", json=body)
        self.assertEqual(limited.status_code, 429)
        self.assertIn("retry-after", limited.headers)
        api.login_throttle.clear(name)



if __name__ == "__main__":
    unittest.main()
