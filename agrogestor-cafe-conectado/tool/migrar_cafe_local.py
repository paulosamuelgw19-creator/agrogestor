"""Inspect a Café Local backup and rehearse catalog transfer via the V2 API."""

import argparse
import base64
from collections import Counter, defaultdict
from hashlib import sha256
import json
from datetime import date
from decimal import Decimal, InvalidOperation
from pathlib import Path
from uuid import NAMESPACE_URL, UUID, uuid5


def _invalid_constant(value):
    raise ValueError(f"Número inválido no backup: {value}.")


def _check_media_refs(value, blobs):
    if isinstance(value, dict):
        for item in value.values():
            _check_media_refs(item, blobs)
    elif isinstance(value, list):
        for item in value:
            _check_media_refs(item, blobs)
    elif isinstance(value, str):
        prefix, _, key = value.partition(":")
        if prefix in blobs and key not in blobs[prefix]:
            raise ValueError("Há uma referência para anexo ausente no backup.")
        if value.startswith(("{", "[")) and ("agrophoto:" in value or "agropdf:" in value):
            try:
                nested = json.loads(value)
            except ValueError:
                return
            _check_media_refs(nested, blobs)


def _verified_backup(path):
    if path.stat().st_size > 128 * 1024**2:
        raise ValueError("O backup excede o limite de 128 MiB para este ensaio.")
    raw = path.read_bytes()
    document = json.loads(raw, parse_constant=_invalid_constant)
    if (document.get("format") != "agrogestor-local-backup"
            or type(document.get("schemaVersion")) is not int
            or not 1 <= document["schemaVersion"] <= 8):
        raise ValueError("Formato de backup local desconhecido.")
    payload = document["payload"]
    canonical = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    if sha256(canonical.encode()).hexdigest() != document["sha256"]:
        # Dart and Python can format scientific numbers differently. Check the
        # original compact payload bytes, keeping the same data representation.
        marker = '"payload":'
        source = raw.decode("utf-8")
        start = source.index(marker, source.index('"schemaVersion"')) + len(marker)
        parsed, end = json.JSONDecoder(parse_constant=_invalid_constant).raw_decode(source, start)
        if parsed != payload or sha256(source[start:end].encode()).hexdigest() != document["sha256"]:
            raise ValueError("O conteúdo do backup está diferente do SHA-256 registrado.")
    photos, pdfs = payload.get("photos", {}), payload.get("pdfs", {})
    for media in (photos, pdfs):
        for digest, encoded in media.items():
            if sha256(base64.b64decode(encoded, validate=True)).hexdigest() != digest:
                raise ValueError("Há um anexo com conteúdo inválido.")
    catalog = payload["catalog"]
    records = payload["records"]
    for value in (catalog, records, payload.get("audit", [])):
        _check_media_refs(value, {"agrophoto": photos, "agropdf": pdfs})
    if not isinstance(catalog, list) or not isinstance(records, list):
        raise ValueError("Registros do backup inválidos.")
    for items, kind_key in ((catalog, "kind"), (records, "module")):
        keys = set()
        for row in items:
            key = (row[kind_key], row["id"])
            if key in keys or row["id"] != row["data"].get("id"):
                raise ValueError("Há um identificador duplicado ou divergente.")
            keys.add(key)
    report = {
        "backupSha256": sha256(raw).hexdigest(),
        "schemaVersion": document["schemaVersion"],
        "recordsByModule": dict(Counter(row["module"] for row in records)),
        "catalogByKind": dict(Counter(row["kind"] for row in catalog)),
        "photos": len(photos),
        "pdfs": len(pdfs),
        "auditRows": len(payload.get("audit", [])),
    }
    return report, payload


def inspect_backup(path):
    report, payload = _verified_backup(path)
    return report, payload["catalog"]


def _server_id(kind, identity):
    if not isinstance(identity, str) or not identity or len(identity) > 160:
        raise ValueError("Identificador de catálogo inválido.")
    try:
        return str(UUID(identity))
    except ValueError:
        key = json.dumps([kind, identity], ensure_ascii=False, separators=(",", ":"))
        return str(uuid5(NAMESPACE_URL, "agrogestor:local-catalog:" + key))


def catalog_plan(catalog):
    """Build the exact API bodies supported by the conservative catalog rehearsal."""
    properties = {}
    plots_by_property = defaultdict(list)
    for row in catalog:
        kind, value = row["kind"], row["data"]
        if kind not in ("properties", "plots"):
            continue
        identity = _server_id(kind, row["id"])
        if value.get("archived", 0):
            raise ValueError("O catálogo contém arquivados. A migração exige um fluxo de arquivo.")
        common = {"id": identity, "name": value["name"], "notes": value.get("notes") or ""}
        if value.get("area_ha") is not None:
            common["area_ha"] = value["area_ha"]
        if kind == "properties":
            if value.get("responsible_user_id") or value.get("client_id"):
                raise ValueError("O catálogo contém vínculos que exigem mapeamento de responsáveis.")
            properties[identity] = {**common, "location": value.get("location") or ""}
        else:
            parent = _server_id("properties", value["property_id"])
            plots_by_property[parent].append(common)
    if set(plots_by_property) - set(properties):
        raise ValueError("O catálogo contém talhão sem fazenda de origem.")
    return [{**value, "plots": plots_by_property[identity]}
            for identity, value in properties.items()]


def rehearse(client, catalog):
    planned = catalog_plan(catalog)
    for farm in planned:
        response = client.post("/api/v2/properties", json=farm)
        response.raise_for_status()
        if response.json()["id"] != farm["id"]:
            raise ValueError("A API retornou uma fazenda diferente da origem.")
    for farm in planned:
        response = client.get(f"/api/v2/properties/{farm['id']}/plots")
        response.raise_for_status()
        actual = {row["id"]: row for row in response.json()["items"]}
        expected = {row["id"]: row for row in farm["plots"]}
        if set(actual) != set(expected) or any(
            actual[identity]["name"] != plot["name"]
            or actual[identity]["property_id"] != farm["id"]
            for identity, plot in expected.items()
        ):
            raise ValueError("Os talhões gravados divergem do backup.")
    return {"properties": len(planned), "plots": sum(len(farm["plots"]) for farm in planned)}


def rehearse_records(client, path):
    """Replay mapped records against an isolated test client and compare pull."""
    report, payload = _verified_backup(path)
    catalog = payload["catalog"]
    # The V2 inventory needs opening balances and operational links. Importing
    # both old quantities and usage events without them can debit stock twice.
    order = ("machines", "implements", "operators", "services", "fuel")
    event_groups = defaultdict(list)
    skipped = Counter()
    source_ids = {kind: {row["id"] for row in catalog if row["kind"] == kind}
                  for kind in ("properties", "plots")}
    for row in payload["records"]:
        module, identity = row["module"], row["id"]
        data = dict(row["data"])
        if module not in order or data.get("pdfPath") or (
                module != "machines" and data.get("photoPath")):
            skipped[module] += 1
            continue
        for key, kind in (("propertyId", "properties"), ("plotId", "plots"), ("fieldId", "plots")):
            if data.get(key) in source_ids[kind]:
                data[key] = _server_id(kind, data[key])
        photo = data.pop("photoPath", None)
        if photo:
            prefix, _, digest = photo.partition(":")
            if prefix != "agrophoto" or digest not in payload["photos"]:
                raise ValueError("Referência de foto da máquina inválida.")
            attachment = str(uuid5(NAMESPACE_URL, "agrogestor:migration-photo:" + digest))
            response = client.put(f"/api/v1/attachments/{attachment}",
                                  files={"file": ("photo.bin", base64.b64decode(payload["photos"][digest]))})
            response.raise_for_status()
            data["photoAttachmentId"] = attachment
        key = json.dumps([report["backupSha256"], module, identity], ensure_ascii=False)
        event_groups[module].append({
            "eventId": str(uuid5(NAMESPACE_URL, "agrogestor:migration-event:" + key)),
            "module": module, "recordId": identity, "operation": "upsert",
            "baseVersion": 0, "payload": data,
        })
    for module in order:
        events = event_groups[module]
        for start in range(0, len(events), 100):
            batch = events[start:start + 100]
            response = client.post("/api/v1/sync/push", json={"events": batch})
            response.raise_for_status()
            if {item["eventId"] for item in response.json()["acknowledged"]} != {
                    event["eventId"] for event in batch}:
                raise ValueError(f"O servidor recusou registros de {module}.")
    cursor = 0
    synced = {}
    while True:
        response = client.get("/api/v1/sync/pull", params={"cursor": cursor, "limit": 500})
        response.raise_for_status()
        batch = response.json()
        for item in batch["changes"]:
            synced[item["module"], item["recordId"]] = item["payload"]
        if not batch["hasMore"]:
            break
        if batch["nextCursor"] <= cursor:
            raise ValueError("O servidor repetiu o cursor da migração.")
        cursor = batch["nextCursor"]
    for module, events in event_groups.items():
        for event in events:
            data = event["payload"]
            if synced.get((module, event["recordId"])) != data:
                raise ValueError(f"Dados sincronizados divergentes em {module}.")
            if data.get("photoAttachmentId"):
                response = client.get(f"/api/v1/attachments/{data['photoAttachmentId']}")
                response.raise_for_status()
                if sha256(response.content).hexdigest() not in payload["photos"]:
                    raise ValueError("A foto sincronizada diverge do backup.")
    return {"transferred": sum(map(len, event_groups.values())), "skipped": dict(skipped)}


def inventory_plan(path, property_by_product, counted_on):
    """Map verified opening balances without reapplying past consumptions."""
    _, payload = _verified_backup(path)
    catalog = payload["catalog"]
    counted_on = date.fromisoformat(counted_on).isoformat()
    farms = {row["id"] for row in catalog if row["kind"] == "properties"
             and not row["data"].get("archived", 0)}
    records = payload["records"]
    products = {row["id"]: row["data"] for row in records if row["module"] == "products"}
    if set(property_by_product) - products.keys() or set(property_by_product.values()) - farms:
        raise ValueError("O mapeamento contém produto ou fazenda desconhecida.")
    plan = []
    for identity, property_id in sorted(property_by_product.items()):
        product = products[identity]
        unit = product["unit"]
        try:
            quantity = Decimal(str(product["quantity"]))
        except InvalidOperation as error:
            raise ValueError("Saldo inicial inválido.") from error
        if unit not in {"kg", "L", "un"} or not quantity.is_finite() or quantity < 0:
            raise ValueError("Confira a unidade e o saldo inicial do produto.")
        server_id = _server_id("inputs", identity)
        farm_id = _server_id("properties", property_id)
        movement = str(uuid5(NAMESPACE_URL, f"agrogestor:local-opening:{farm_id}:{server_id}"))
        plan.append({
            "propertyId": farm_id,
            "input": {
                "id": server_id,
                "name": product["name"],
                "unit": unit,
                "category": product.get("category") or "",
                "product_type": product.get("productType") or "",
                "notes": "Lote legado: " + product["lot"] if product.get("lot") else "",
            },
            "movement": {"id": movement, "input_id": server_id, "kind": "opening",
                         "quantity": str(quantity), "occurred_on": counted_on},
        })
    return plan


def rehearse_inventory(client, path, property_by_product, counted_on):
    plan = inventory_plan(path, property_by_product, counted_on)
    for item in plan:
        material, movement = item["input"], item["movement"]
        endpoint = f"/api/v2/properties/{item['propertyId']}/inventory"
        client.post("/api/v2/inputs", json=material).raise_for_status()
        client.post(endpoint, json=movement).raise_for_status()
        response = client.get(f"{endpoint}/{material['id']}")
        response.raise_for_status()
        balance = response.json()
        if not balance["initialized"] or Decimal(balance["quantity"]) != Decimal(movement["quantity"]):
            raise ValueError("O saldo inicial gravado diverge da cópia.")
    return len(plan)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("backup", type=Path)
    parser.add_argument("--estoque", type=Path,
                        help="JSON privado com countedOn e propertyByProduct; apenas planeja")
    args = parser.parse_args()
    try:
        report, catalog = inspect_backup(args.backup)
        report["catalogRehearsal"] = {
            "properties": len(catalog_plan(catalog)),
            "plots": report["catalogByKind"].get("plots", 0),
        }
        report["mappedLegacyIds"] = sum(
            _server_id(row["kind"], row["id"]) != row["id"]
            for row in catalog if row["kind"] in {"properties", "plots"}
        )
        if args.estoque:
            mapping = json.loads(args.estoque.read_text(encoding="utf-8-sig"))
            plan = inventory_plan(args.backup, mapping["propertyByProduct"], mapping["countedOn"])
            report["plannedOpeningBalances"] = len(plan)
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"Backup recusado: {error}\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
