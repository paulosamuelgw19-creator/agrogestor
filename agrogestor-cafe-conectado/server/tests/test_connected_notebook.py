"""Acceptance tests for the connected edition, using isolated SQLite files."""
import base64
import hashlib
import json
import tempfile
import unittest
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch
from uuid import uuid4

from fastapi.testclient import TestClient
import test_v2_pilot as fixture
from agrogestor_server import commercial

api = fixture.api

PIXEL = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/aF0AAAAASUVORK5CYII="
)
OTHER_PIXEL = base64.b64decode("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")


class ConnectedNotebookTests(unittest.TestCase):
    password = "TemporaryNotebookPassword2026!"
    device_a = "gestor-aparelho-teste-a"
    device_b = "gestor-aparelho-teste-b"

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="agro-cafe-connected-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.primary = self.use_server("org-cafe-a")
        self.primary.__enter__()
        self.addCleanup(self.primary.__exit__, None, None, None)
        self.http = TestClient(api.app)
        self.addCleanup(self.http.close)
        self.seed("org-cafe-a")
        self.contract(devices=5)
        self.a = self.login("admin", self.device_a)
        self.b = self.login("admin", self.device_b)
        self.farm, self.plot = self.catalog(self.a)

    @contextmanager
    def use_server(self, organization):
        data = self.root / organization
        with patch.multiple(
            api,
            DATA_DIR=data,
            DB_PATH=data / "test.sqlite3",
            ATTACHMENTS_DIR=data / "attachments",
            V2_ENABLED=True,
            LICENSE_PROVIDER="local",
            LICENSE_API_BASE="",
            LICENSE_API_KEY="",
            JWT_SECRET="fictitious-connected-test-key-more-than-32-characters",
        ):
            api.initialize_database()
            yield

    def seed(self, organization):
        digest = api.password_hash.hash(self.password)
        with api.connect() as db:
            db.execute("INSERT INTO farm VALUES(1,?,?)", (organization, organization))
            for role in ("admin", "operator", "mechanic"):
                db.execute(
                    """INSERT INTO users(user_id,farm_id,email,display_name,role,password_hash,created_at)
                       VALUES(?,?,?,?,?,?,?)""",
                    (f"{organization}-{role}", organization, f"{role}@{organization}.invalid",
                     role, role, digest, api.utc_now()),
                )

    def contract(self, *, devices=5, modules=None):
        with api.connect() as db:
            tenant = api.farm_row(db)["farm_id"]
            rights = commercial.config(db, tenant)[0]
            rights["limits"]["devices"] = devices
            if modules is not None:
                rights["modules"] = modules
            db.execute(
                """INSERT INTO commercial_entitlements VALUES(?,1,?,?,NULL,NULL)
                   ON CONFLICT(farm_id) DO UPDATE SET config_json=excluded.config_json""",
                (tenant, json.dumps(rights), api.utc_now()),
            )

    def login_response(self, role, device, organization="org-cafe-a", password=None):
        return self.http.post("/api/v1/auth/login", json={
            "email": f"{role}@{organization}.invalid",
            "password": self.password if password is None else password,
            "deviceId": device,
            "deviceName": "Aparelho fictício",
        })

    def login(self, role, device, organization="org-cafe-a"):
        response = self.login_response(role, device, organization)
        self.assertEqual(response.status_code, 200, response.text)
        document = response.json()
        self.assertEqual(document["user"]["farmId"], organization)
        self.assertEqual(document["user"]["role"], role)
        self.assertTrue(document["entitlement"]["writeAllowed"])
        return {"Authorization": f"Bearer {document['token']}"}

    def catalog(self, headers):
        farm, plot = str(uuid4()), str(uuid4())
        response = self.http.post("/api/v2/properties", headers=headers, json={
            "id": farm,
            "name": "Fazenda fictícia",
            "plots": [{"id": plot, "name": "Talhão fictício"}],
        })
        self.assertEqual(response.status_code, 200, response.text)
        return farm, plot

    def event(self, payload=None, *, base=0, operation="upsert", record=None):
        record = record or str(uuid4())
        if operation == "upsert":
            payload = {
                "id": record,
                "propertyId": self.farm,
                "plotId": self.plot,
                "date": "2026-11-12T08:00:00",
                "text": "Vistoria fictícia",
                "status": "open",
                "inspection": True,
                "followUpOn": "2026-11-19T00:00:00",
                **(payload or {}),
            }
        return {
            "eventId": str(uuid4()), "module": "plotNotebook", "recordId": record,
            "operation": operation, "payload": payload, "baseVersion": base,
        }

    def push(self, headers, *events, expected=200):
        response = self.http.post("/api/v1/sync/push", headers=headers, json={"events": events})
        self.assertEqual(response.status_code, expected, response.text)
        return response.json()

    def pull(self, headers, cursor=0, *, expected=200):
        response = self.http.get(f"/api/v1/sync/pull?cursor={cursor}", headers=headers)
        self.assertEqual(response.status_code, expected, response.text)
        return response.json()

    def test_two_manager_devices_replay_and_conflict_preserve_history(self):
        self.assertNotEqual(self.a, self.b)
        event = self.event()
        created = self.push(self.a, event)
        self.assertEqual(created["acknowledged"], [{"eventId": event["eventId"], "version": 1}])
        self.assertEqual(self.push(self.a, event), created)
        first = self.pull(self.b)
        self.assertEqual(len(first["changes"]), 1)
        self.assertEqual(first["changes"][0]["payload"], event["payload"])
        self.assertEqual(self.pull(self.b, first["nextCursor"])["changes"], [])

        tampered = {**event, "payload": {**event["payload"], "text": "Alterado"}}
        self.assertIn("diferentes", self.push(self.b, tampered)["rejected"][0]["message"])
        stale = self.event({"status": "resolved"}, record=event["recordId"])
        conflict = self.push(self.b, stale)["conflicts"][0]
        self.assertEqual(conflict["serverVersion"], 1)
        self.assertEqual(conflict["serverPayload"], event["payload"])
        resolved = self.event({"status": "resolved"}, record=event["recordId"], base=1)
        self.assertEqual(self.push(self.b, resolved)["acknowledged"][0]["version"], 2)
        self.assertEqual(self.pull(self.a, first["nextCursor"])["changes"][0]["payload"]["status"],
                         "resolved")

        other_farm, other_plot = self.catalog(self.a)
        move = self.event({"propertyId": other_farm, "plotId": other_plot},
                          record=event["recordId"], base=2)
        delete = self.event(record=event["recordId"], base=2, operation="delete")
        rejected = self.push(self.a, move, delete)
        self.assertEqual(len(rejected["rejected"]), 2)
        self.assertEqual(len(self.pull(self.b)["changes"]), 2)

    def test_contract_profiles_device_revocation_and_expiry(self):
        operator = self.login("operator", "operador-aparelho-teste")
        mechanic = self.login("mechanic", "mecanico-aparelho-teste")
        event = self.event()
        self.assertEqual(self.push(self.a, event)["acknowledged"][0]["version"], 1)
        for headers in (operator, mechanic):
            self.pull(headers, expected=403)
            self.push(headers, self.event(), expected=403)
        denied = self.login_response("admin", "dispositivo-credencial-errada", password="wrong")
        self.assertEqual(denied.status_code, 401)
        self.contract(devices=4, modules=list(commercial.MODULES))
        exceeded = self.login_response("admin", "dispositivo-fora-do-limite")
        self.assertEqual(exceeded.status_code, 409, exceeded.text)
        self.assertEqual(exceeded.json()["code"], "QUOTA_EXCEEDED")
        self.contract(devices=4, modules=[])
        self.assertEqual(self.push(self.a, self.event())["rejected"][0]["code"], "MODULE_DISABLED")
        self.contract(devices=4, modules=list(commercial.MODULES))

        endpoint = f"/api/v1/licensing/devices/{self.device_b}"
        self.assertEqual(self.http.delete(endpoint, headers=self.a).status_code, 200)
        api.initialize_database()
        self.pull(self.b, expected=401)
        self.assertEqual(self.login_response("admin", self.device_b).status_code, 403)
        self.assertEqual(self.login_response("operator", self.device_b).status_code, 403)
        replacement = self.login("admin", "dispositivo-substituto-01")
        self.assertEqual(len(self.pull(replacement)["changes"]), 1)

        with api.connect() as db:
            expired = (datetime.now(timezone.utc) - timedelta(days=31)).isoformat()
            db.execute("UPDATE farm_license SET trial_started_at=? WHERE farm_id='org-cafe-a'",
                       (expired,))
        license_status = self.http.get("/api/v1/licensing/status", headers=self.a)
        self.assertEqual(license_status.json()["status"], "expired")
        self.assertFalse(license_status.json()["writeAllowed"])
        self.push(self.a, self.event(), expected=402)
        self.assertEqual(len(self.pull(self.a)["changes"]), 1)

    def test_photo_sync_and_two_organization_servers_are_isolated(self):
        attachment = f"notebook-{uuid4()}"
        endpoint = f"/api/v1/attachments/{attachment}"
        note = self.event({"text": "", "photoAttachmentId": attachment})
        self.assertIn("ainda não chegou", self.push(self.a, note)["rejected"][0]["message"])
        upload = self.http.put(endpoint, headers=self.a, files={"file": ("note.png", PIXEL, "image/png")})
        self.assertEqual(upload.status_code, 200, upload.text)
        self.assertEqual(upload.json()["sha256"], hashlib.sha256(PIXEL).hexdigest())
        self.assertEqual(self.push(self.a, note)["acknowledged"][0]["version"], 1)
        self.assertEqual(self.pull(self.b)["changes"][0]["payload"]["photoAttachmentId"], attachment)
        download = self.http.get(endpoint, headers=self.b)
        self.assertEqual(download.status_code, 200, download.text)
        self.assertEqual(download.content, PIXEL)
        self.assertEqual(download.headers["Cache-Control"], "private, no-store")
        overwrite = self.http.put(
            endpoint, headers=self.b,
            files={"file": ("other.gif", OTHER_PIXEL, "image/gif")},
        )
        self.assertEqual(overwrite.status_code, 409)
        invalid_path = f"/api/v1/attachments/notebook-{uuid4()}"
        bad_file = self.http.put(invalid_path, headers=self.a,
                                 files={"file": ("fake.png", b"invalid", "image/png")})
        self.assertEqual(bad_file.status_code, 400, bad_file.text)
        restricted_devices = [
            self.login("operator", "operador-foto-teste-01"),
            self.login("mechanic", "mecanico-foto-teste-01"),
        ]
        for v2_enabled in (True, False):
            with patch.object(api, "V2_ENABLED", v2_enabled):
                for headers in restricted_devices:
                    self.assertEqual(self.http.get(endpoint, headers=headers).status_code, 403)
                    denied = self.http.put(
                        invalid_path, headers=headers,
                        files={"file": ("note.png", PIXEL, "image/png")},
                    )
                    self.assertEqual(denied.status_code, 403, denied.text)

        with self.use_server("org-cafe-b"):
            self.seed("org-cafe-b")
            self.contract(devices=2)
            b_org = self.login("admin", self.device_a, "org-cafe-b")
            self.assertEqual(self.login_response("admin", self.device_a).status_code, 401)
            self.pull(self.a, expected=401)
            self.assertEqual(self.pull(b_org)["changes"], [])
            self.assertEqual(self.http.get(endpoint, headers=b_org).status_code, 404)
            b_farm, b_plot = self.catalog(b_org)
            foreign = self.push(b_org, self.event())
            self.assertIn("talhão", foreign["rejected"][0]["message"])
            foreign_photo = self.event({"propertyId": b_farm, "plotId": b_plot,
                                        "photoAttachmentId": attachment})
            self.assertIn("foto", self.push(b_org, foreign_photo)["rejected"][0]["message"])
            local = self.event({"propertyId": b_farm, "plotId": b_plot})
            self.assertEqual(self.push(b_org, local)["acknowledged"][0]["version"], 1)
        self.pull(b_org, expected=401)
        self.assertEqual(len(self.pull(self.a)["changes"]), 1)
        self.assertEqual(self.http.get(endpoint, headers=self.b).content, PIXEL)
