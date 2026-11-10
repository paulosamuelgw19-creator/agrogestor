import os
import sys
import tempfile
import unittest
import urllib.error
import atexit
from datetime import datetime, timedelta, timezone
from pathlib import Path

SERVER_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SERVER_DIR))
_bootstrap_data = tempfile.TemporaryDirectory(prefix="agrogestor-test-bootstrap-")
atexit.register(_bootstrap_data.cleanup)
os.environ["AGROGESTOR_DATA_DIR"] = _bootstrap_data.name
os.environ["AGROGESTOR_JWT_SECRET"] = "test-only-secret-with-more-than-32-characters"
os.environ.pop("AGROGESTOR_LICENSE_API_BASE", None)

import httpx
from agrogestor_server import app as api
from agrogestor_server import cli as api_cli


class FarmApiContractTests(unittest.IsolatedAsyncioTestCase):
    password = "TemporaryPassword!2026"

    def setUp(self):
        self.v2_enabled=api.V2_ENABLED
        api.V2_ENABLED=False
        self.temp_dir = tempfile.TemporaryDirectory(prefix="agrogestor-api-test-")
        api.DATA_DIR = Path(self.temp_dir.name) / "data"
        api.DB_PATH = api.DATA_DIR / "agrogestor.sqlite3"
        api.ATTACHMENTS_DIR = api.DATA_DIR / "attachments"
        api.LICENSE_API_BASE = ""
        api.LICENSE_API_KEY = ""
        api.initialize_database()
        self.farm_id = "farm-test-001"
        self.accounts = [
            ("admin-test-001", "admin@example.invalid", "Admin Test", "admin"),
            ("operator-test-1", "operator@example.invalid", "Operator Test", "operator"),
            ("mechanic-test-1", "mechanic@example.invalid", "Mechanic Test", "mechanic"),
        ]
        with api.connect() as connection:
            connection.execute("INSERT INTO farm(singleton,farm_id,name) VALUES(1,?,?)", (self.farm_id, "Farm Test"))
            for user_id, email, name, role in self.accounts:
                connection.execute(
                    "INSERT INTO users(user_id,farm_id,email,display_name,role,password_hash,created_at) VALUES(?,?,?,?,?,?,?)",
                    (user_id, self.farm_id, email, name, role, api.password_hash.hash(self.password), api.utc_now()),
                )
        self.cloud_post = api.cloud_post
        self.license_api_base = api.LICENSE_API_BASE
        self.license_api_key = api.LICENSE_API_KEY

    async def asyncSetUp(self):
        self.http = httpx.AsyncClient(
            transport=httpx.ASGITransport(app=api.app),
            base_url="http://agrogestor-test",
        )

    async def asyncTearDown(self):
        api.V2_ENABLED=self.v2_enabled
        await self.http.aclose()
        api.cloud_post = self.cloud_post
        api.LICENSE_API_BASE = self.license_api_base
        api.LICENSE_API_KEY = self.license_api_key
        self.temp_dir.cleanup()

    def test_firebase_license_requests_require_and_send_server_secret(self):
        api.LICENSE_API_BASE = "https://functions.example.invalid"
        api.LICENSE_API_KEY = "temporary-test-shared-secret"
        original_urlopen = api.urllib.request.urlopen
        captured = {}

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self, _limit):
                return b'{"status":"active"}'

        def fake_urlopen(request, timeout):
            captured["request"] = request
            captured["timeout"] = timeout
            return FakeResponse()

        try:
            api.urllib.request.urlopen = fake_urlopen
            response = api.cloud_post("checkLicense", {"farmId": self.farm_id})
            self.assertEqual(response, {"status": "active"})
            self.assertEqual(captured["request"].get_header("X-agrogestor-license-key"), api.LICENSE_API_KEY)
            self.assertEqual(captured["timeout"], 8)

            api.LICENSE_API_KEY = ""
            with self.assertRaises(ValueError):
                api.cloud_post("checkLicense", {"farmId": self.farm_id})
        finally:
            api.urllib.request.urlopen = original_urlopen

    async def login(self, email, device_id):
        response = await self.http.post("/api/v1/auth/login", json={
            "email": email,
            "password": self.password,
            "deviceId": device_id,
            "deviceName": "Test device",
        })
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    async def test_admin_user_management_blocking_and_revocation(self):
        admin = await self.login("admin@example.invalid", "device-admin-users-01")
        admin_headers = {"Authorization": f"Bearer {admin['token']}"}
        operator = await self.login("operator@example.invalid", "device-operator-users-01")
        operator_headers = {"Authorization": f"Bearer {operator['token']}"}

        users = await self.http.get("/api/v1/auth/users", headers=admin_headers)
        self.assertEqual(users.status_code, 200, users.text)
        self.assertEqual(len(users.json()["users"]), 3)
        self.assertNotIn("password_hash", users.text)
        denied_list = await self.http.get("/api/v1/auth/users", headers=operator_headers)
        self.assertEqual(denied_list.status_code, 403)

        last_admin = await self.http.patch(
            "/api/v1/auth/users/admin-test-001/access",
            headers=admin_headers,
            json={"active": False},
        )
        self.assertEqual(last_admin.status_code, 409, last_admin.text)

        blocked = await self.http.patch(
            "/api/v1/auth/users/operator-test-1/access",
            headers=admin_headers,
            json={"active": False},
        )
        self.assertEqual(blocked.status_code, 200, blocked.text)
        old_session = await self.http.get("/api/v1/licensing/status", headers=operator_headers)
        self.assertEqual(old_session.status_code, 401)
        blocked_login = await self.http.post("/api/v1/auth/login", json={
            "email": "operator@example.invalid",
            "password": self.password,
            "deviceId": "device-operator-users-01",
            "deviceName": "Test device",
        })
        self.assertEqual(blocked_login.status_code, 401)

        restored = await self.http.patch(
            "/api/v1/auth/users/operator-test-1/access",
            headers=admin_headers,
            json={"active": True},
        )
        self.assertEqual(restored.status_code, 200, restored.text)
        self.assertEqual((await self.http.get("/api/v1/licensing/status", headers=operator_headers)).status_code, 200)

    async def test_auth_sync_permissions_licensing_and_backup_contract(self):
        self.assertEqual((await self.http.get("/api/v1/licensing/status")).status_code, 401)

        admin = await self.login("admin@example.invalid", "device-admin-0001")
        self.assertEqual(admin["entitlement"]["status"], "trial")
        trial_end = datetime.fromisoformat(admin["entitlement"]["trialEndsAt"])
        trial_duration = trial_end - datetime.now(timezone.utc)
        self.assertGreater(trial_duration, timedelta(days=29))
        self.assertLessEqual(trial_duration, timedelta(days=30))
        admin_headers = {"Authorization": f"Bearer {admin['token']}"}
        attachment_id = "a" * 32
        image_bytes = b"temporary machine photo"
        uploaded = await self.http.put(
            f"/api/v1/attachments/{attachment_id}",
            headers=admin_headers,
            files={"file": ("machine.jpg", image_bytes, "image/jpeg")},
        )
        self.assertEqual(uploaded.status_code, 200, uploaded.text)
        downloaded = await self.http.get(f"/api/v1/attachments/{attachment_id}", headers=admin_headers)
        self.assertEqual(downloaded.status_code, 200, downloaded.text)
        self.assertEqual(downloaded.content, image_bytes)

        records = [
            {"eventId": "event-machines-0001", "module": "machines", "recordId": "machine-001", "operation": "upsert", "payload": {"name": "Trator", "photoAttachmentId": attachment_id}, "baseVersion": 0},
            {"eventId": "event-clients-0001", "module": "clients", "recordId": "client-001", "operation": "upsert", "payload": {"name": "Cliente"}, "baseVersion": 0},
            {"eventId": "event-services-0001", "module": "services", "recordId": "service-001", "operation": "upsert", "payload": {"machineId": "machine-001"}, "baseVersion": 0},
            {"eventId": "event-maintenance-0001", "module": "maintenance", "recordId": "maintenance-001", "operation": "upsert", "payload": {"machineId": "machine-001"}, "baseVersion": 0},
        ]
        first = await self.http.post("/api/v1/sync/push", headers=admin_headers, json={"events": records})
        self.assertEqual(first.status_code, 200, first.text)
        self.assertEqual(len(first.json()["acknowledged"]), 4)

        retry = await self.http.post("/api/v1/sync/push", headers=admin_headers, json={"events": records})
        self.assertEqual(retry.status_code, 200, retry.text)
        self.assertEqual({item["version"] for item in retry.json()["acknowledged"]}, {1})
        with api.connect() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM changes").fetchone()[0], 4)
            self.assertEqual(connection.execute("SELECT MAX(version) FROM records").fetchone()[0], 1)

        stale_edit = await self.http.post("/api/v1/sync/push", headers=admin_headers, json={"events": [
            {"eventId": "event-machine-conflict-01", "module": "machines", "recordId": "machine-001", "operation": "upsert", "payload": {"name": "Old edit"}, "baseVersion": 0}
        ]})
        self.assertEqual(stale_edit.status_code, 200, stale_edit.text)
        self.assertEqual(len(stale_edit.json()["conflicts"]), 1)
        self.assertEqual(stale_edit.json()["conflicts"][0]["serverPayload"]["name"], "Trator")
        current_edit = await self.http.post("/api/v1/sync/push", headers=admin_headers, json={"events": [
            {"eventId": "event-machine-update-01", "module": "machines", "recordId": "machine-001", "operation": "upsert", "payload": {"name": "Updated tractor"}, "baseVersion": 1}
        ]})
        self.assertEqual(current_edit.status_code, 200, current_edit.text)
        self.assertEqual(current_edit.json()["acknowledged"][0]["version"], 2)

        operator = await self.login("operator@example.invalid", "device-operator-01")
        self.assertEqual(operator["entitlement"]["trialEndsAt"], admin["entitlement"]["trialEndsAt"])
        operator_headers = {"Authorization": f"Bearer {operator['token']}"}
        operator_pull = await self.http.get("/api/v1/sync/pull", headers=operator_headers)
        self.assertEqual(operator_pull.status_code, 200, operator_pull.text)
        self.assertEqual({item["module"] for item in operator_pull.json()["changes"]}, {"machines", "services"})
        denied_write = await self.http.post("/api/v1/sync/push", headers=operator_headers, json={"events": [
            {"eventId": "event-denied-client-001", "module": "clients", "recordId": "client-002", "operation": "upsert", "payload": {"name": "Forbidden"}, "baseVersion": 0}
        ]})
        self.assertEqual(denied_write.status_code, 200, denied_write.text)
        self.assertEqual(len(denied_write.json()["rejected"]), 1)
        denied_invite = await self.http.post("/api/v1/auth/invitations", headers=operator_headers, json={
            "email": "other@example.invalid", "role": "mechanic",
        })
        self.assertEqual(denied_invite.status_code, 403, denied_invite.text)

        third_device = await self.http.post("/api/v1/auth/login", json={
            "email": "admin@example.invalid",
            "password": self.password,
            "deviceId": "device-third-0001",
            "deviceName": "Third device",
        })
        self.assertEqual(third_device.status_code, 200, third_device.text)
        self.assertEqual(third_device.json()["entitlement"]["deviceLimit"], -1)
        release = await self.http.delete("/api/v1/licensing/devices/device-operator-01", headers=admin_headers)
        self.assertEqual(release.status_code, 200, release.text)
        mechanic = await self.login("mechanic@example.invalid", "device-operator-01")
        mechanic_headers = {"Authorization": f"Bearer {mechanic['token']}"}
        self.assertEqual((await self.http.get("/api/v1/sync/pull", headers=operator_headers)).status_code, 401)
        mechanic_pull = await self.http.get("/api/v1/sync/pull", headers=mechanic_headers)
        self.assertEqual(mechanic_pull.status_code, 200, mechanic_pull.text)
        self.assertEqual({item["module"] for item in mechanic_pull.json()["changes"]}, {"machines", "maintenance"})

        with api.connect() as connection:
            old_start = (datetime.now(timezone.utc) - timedelta(days=31)).isoformat()
            connection.execute("UPDATE farm_license SET trial_started_at=? WHERE farm_id=?", (old_start, self.farm_id))
        expired = await self.http.get("/api/v1/licensing/status", headers=admin_headers)
        self.assertEqual(expired.status_code, 200, expired.text)
        self.assertEqual(expired.json()["status"], "expired")
        blocked_write = await self.http.post("/api/v1/sync/push", headers=admin_headers, json={"events": [
            {"eventId": "event-after-expired-01", "module": "machines", "recordId": "machine-002", "operation": "upsert", "payload": {"name": "Blocked"}, "baseVersion": 0}
        ]})
        self.assertEqual(blocked_write.status_code, 402, blocked_write.text)
        self.assertEqual((await self.http.get("/api/v1/sync/pull", headers=admin_headers)).status_code, 200)

        api.LICENSE_API_BASE = "https://test-project.example.invalid"

        def cloud_unavailable(*_args, **_kwargs):
            raise urllib.error.URLError("offline")

        api.cloud_post = cloud_unavailable
        with api.connect() as connection:
            checked_six_days_ago = (datetime.now(timezone.utc) - timedelta(days=6)).isoformat()
            connection.execute(
                "UPDATE farm_license SET paid_license_id=?,paid_activated_at=?,last_cloud_checked_at=? WHERE farm_id=?",
                ("license-test-id", checked_six_days_ago, checked_six_days_ago, self.farm_id),
            )
        offline_six_days = await self.http.get("/api/v1/licensing/status", headers=admin_headers)
        self.assertEqual(offline_six_days.status_code, 200, offline_six_days.text)
        self.assertEqual(offline_six_days.json()["status"], "licensed")
        self.assertTrue(offline_six_days.json()["writeAllowed"])
        with api.connect() as connection:
            checked_eight_days_ago = (datetime.now(timezone.utc) - timedelta(days=8)).isoformat()
            connection.execute("UPDATE farm_license SET last_cloud_checked_at=? WHERE farm_id=?", (checked_eight_days_ago, self.farm_id))
        offline_eight_days = await self.http.get("/api/v1/licensing/status", headers=admin_headers)
        self.assertEqual(offline_eight_days.status_code, 200, offline_eight_days.text)
        self.assertEqual(offline_eight_days.json()["status"], "validation_required")
        self.assertFalse(offline_eight_days.json()["writeAllowed"])

        backup_path = Path(self.temp_dir.name) / "backup"
        api_cli.backup(backup_path)
        with api.connect() as connection:
            connection.execute("DELETE FROM records")
            connection.execute("DELETE FROM attachments")
        api_cli.restore(backup_path)
        with api.connect() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM records").fetchone()[0], 4)
        self.assertEqual((api.ATTACHMENTS_DIR / self.farm_id / attachment_id).read_bytes(), image_bytes)

    async def test_paid_expiry_is_enforced_offline_and_limits_cached_deadline(self):
        admin = await self.login("admin@example.invalid", "device-admin-001")
        headers = {"Authorization": f"Bearer {admin['token']}"}
        api.LICENSE_API_BASE = "https://central.example.invalid"
        def unavailable(*_args, **_kwargs):
            raise urllib.error.URLError("offline")
        api.cloud_post = unavailable
        now = datetime.now(timezone.utc)
        expiry = now + timedelta(hours=1)
        with api.connect() as db:
            db.execute("UPDATE farm_license SET paid_license_id=?,last_cloud_checked_at=?,last_cloud_status='active',paid_expires_at=? WHERE farm_id=?",
                       ("paid-001", now.isoformat(), expiry.isoformat(), self.farm_id))
        valid = await self.http.get("/api/v1/licensing/status", headers=headers)
        self.assertTrue(valid.json()["writeAllowed"])
        self.assertEqual(datetime.fromisoformat(valid.json()["offlineUntil"]), expiry)
        with api.connect() as db:
            db.execute("UPDATE farm_license SET paid_expires_at=? WHERE farm_id=?", ((now-timedelta(seconds=1)).isoformat(), self.farm_id))
        expired = await self.http.get("/api/v1/licensing/status", headers=headers)
        self.assertEqual(expired.json()["status"], "expired")
        self.assertFalse(expired.json()["writeAllowed"])
        api.cloud_post = lambda *_args: {"status": "active", "licenseId": "paid-001", "checkedAt": now.isoformat(), "expiresAt": expiry.isoformat()}
        online = await self.http.get("/api/v1/licensing/status", headers=headers)
        self.assertEqual(datetime.fromisoformat(online.json()["offlineUntil"]), expiry)

    async def test_attachment_retries_are_safe_and_overwrite_is_rejected(self):
        admin = await self.login("admin@example.invalid", "device-admin-001")
        headers = {"Authorization": f"Bearer {admin['token']}"}
        url = "/api/v1/attachments/attachment-test-0001"
        original = b"original-photo"
        for _ in range(2):
            result = await self.http.put(url, headers=headers, files={"file": ("photo.bin", original)})
            self.assertEqual(result.status_code, 200, result.text)
        overwrite = await self.http.put(url, headers=headers, files={"file": ("photo.bin", b"changed-photo")})
        self.assertEqual(overwrite.status_code, 409, overwrite.text)
        download = await self.http.get(url, headers=headers)
        self.assertEqual(download.content, original)
        self.assertEqual(list((api.ATTACHMENTS_DIR/self.farm_id).glob("upload-*")), [])

    async def test_tokens_without_expiry_are_rejected(self):
        await self.login("admin@example.invalid", "device-admin-001")
        token = api.jwt.encode({"sub": "admin-test-001", "farm_id": self.farm_id, "device_id": "device-admin-001"}, api.JWT_SECRET, algorithm="HS256")
        result = await self.http.get("/api/v1/sync/pull", headers={"Authorization": f"Bearer {token}"})
        self.assertEqual(result.status_code, 401)


    async def test_login_limits_repeated_bad_passwords(self):
        email = "throttle-test@example.invalid"
        api.login_throttle.clear(email)
        body = {"email": email, "password": "WrongPassword", "deviceId": "device-throttle-01"}
        for _ in range(8):
            self.assertEqual((await self.http.post("/api/v1/auth/login", json=body)).status_code, 401)
        limited = await self.http.post("/api/v1/auth/login", json=body)
        self.assertEqual(limited.status_code, 429)
        self.assertIn("retry-after", limited.headers)
        api.login_throttle.clear(email)


    async def test_device_schema_upgrade_preserves_existing_device_and_session(self):
        admin = await self.login("admin@example.invalid", "device-migrate-01")
        with api.connect() as db:
            db.execute("ALTER TABLE devices DROP COLUMN token_version")
        api.initialize_database()
        with api.connect() as db:
            row = db.execute("SELECT device_id,token_version FROM devices WHERE device_id=?", ("device-migrate-01",)).fetchone()
        self.assertEqual(row["device_id"], "device-migrate-01")
        self.assertEqual(row["token_version"], 0)
        response = await self.http.get("/api/v1/sync/pull", headers={"Authorization": f"Bearer {admin['token']}"})
        self.assertEqual(response.status_code, 200, response.text)



if __name__ == "__main__":
    unittest.main()
