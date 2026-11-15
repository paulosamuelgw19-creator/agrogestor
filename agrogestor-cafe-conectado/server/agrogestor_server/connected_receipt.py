"""Authoritative field volumes and immutable physical coffee receipts."""

import hashlib
import json
import math
import re
from datetime import date
from uuid import NAMESPACE_URL, uuid5

from . import connected_harvest

MODULE = "coffeeHarvestReceipts"
_ID = re.compile(r"[A-Za-z0-9_.:-]{1,160}")
_DAY = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")
_REVISION = re.compile(r"[a-f0-9]{64}")
_REQUIRED = {
    "id", "propertyId", "plotId", "seasonYear", "harvestDate", "receivedDate",
    "receivedLiters", "fieldLiters", "sourceRevision",
}


class ReceiptError(ValueError):
    def __init__(self, message, code="INVALID_HARVEST_RECEIPT"):
        super().__init__(message)
        self.code = code


def _date(value):
    try:
        if not isinstance(value, str) or not _DAY.fullmatch(value):
            raise ValueError
        return date.fromisoformat(value)
    except ValueError as error:
        raise ReceiptError("Informe uma data de colheita ou recebimento válida.") from error


def _volume(payload):
    quantity = payload["quantity"]
    unit = payload["unit"]
    if unit == "measures":
        return quantity * payload["litersPerMeasure"] + (payload.get("remainderLiters") or 0)
    if unit == "carts":
        return quantity * payload["cartCapacityLiters"]
    return quantity


def source(db, tenant, property_id, plot_id, season, harvest_date, *, active=False):
    if (not all(isinstance(value, str) and _ID.fullmatch(value)
                for value in (property_id, plot_id))
            or type(season) is not int or not 1900 <= season <= 9999):
        raise ReceiptError("Confira a fazenda, o talhão e o ano da safra.")
    day = _date(harvest_date).isoformat()
    try:
        connected_harvest._require_plot(db, tenant, property_id, plot_id, new=active)
    except connected_harvest.HarvestValidationError as error:
        raise ReceiptError(str(error), "HARVEST_SOURCE_NOT_FOUND") from error
    rows = db.execute(
        """SELECT module,record_id,version,payload FROM records
           WHERE farm_id=? AND module IN (?,?) AND deleted=0
           AND json_extract(payload,'$.propertyId')=?
           AND json_extract(payload,'$.plotId')=?
           AND json_extract(payload,'$.seasonYear')=?
           AND substr(json_extract(payload,'$.date'),1,10)=?
           ORDER BY record_id""",
        (tenant, connected_harvest.PLOT_PRODUCTION, connected_harvest.HARVEST_ENTRIES,
         property_id, plot_id, season, day),
    ).fetchall()
    declarations = [row for row in rows if row["module"] == connected_harvest.PLOT_PRODUCTION]
    if len(declarations) > 1:
        raise ReceiptError("Há mais de uma declaração para esta colheita.", "HARVEST_SOURCE_AMBIGUOUS")
    selected = declarations or rows
    if not selected:
        raise ReceiptError("Não há colheita confirmada neste talhão, dia e safra.", "HARVEST_SOURCE_NOT_FOUND")
    field_liters = math.fsum(_volume(json.loads(row["payload"])) for row in selected)
    revision_data = [
        tenant, property_id, plot_id, season, day,
        [[row["module"], row["record_id"], row["version"]] for row in selected],
    ]
    revision = hashlib.sha256(json.dumps(
        revision_data, ensure_ascii=False, separators=(",", ":"),
    ).encode("utf-8")).hexdigest()
    return {"fieldLiters": field_liters, "sourceRevision": revision}


def validate(db, tenant, event, current):
    if event.operation != "upsert" or current is not None:
        raise ReceiptError("O recebimento confirmado não pode ser alterado ou excluído.")
    payload = event.payload
    if (not _REQUIRED <= payload.keys() or set(payload) - (_REQUIRED | {"notes"})
            or payload["id"] != event.recordId):
        raise ReceiptError("Confira os dados do recebimento de café.")
    harvest_day = _date(payload["harvestDate"])
    if _date(payload["receivedDate"]) < harvest_day:
        raise ReceiptError("O recebimento não pode ser anterior à colheita.")
    notes = payload.get("notes", "")
    if not isinstance(notes, str) or len(notes) > 4000:
        raise ReceiptError("Use até 4 mil caracteres nas observações.")
    received, field = payload["receivedLiters"], payload["fieldLiters"]
    revision = payload["sourceRevision"]
    if (type(received) not in (int, float)
            or not 0 <= received <= connected_harvest.MAX_QUANTITY
            or type(field) not in (int, float) or not 0 <= field <= 1e308
            or not isinstance(revision, str) or not _REVISION.fullmatch(revision)):
        raise ReceiptError("Confira os volumes e a origem do recebimento.")
    property_id, plot_id, season = (payload[key] for key in ("propertyId", "plotId", "seasonYear"))
    day = harvest_day.isoformat()
    expected = source(db, tenant, property_id, plot_id, season, day, active=True)
    key = json.dumps([property_id, plot_id, season, day], ensure_ascii=False, separators=(",", ":"))
    if event.recordId != str(uuid5(NAMESPACE_URL, "agrogestor:coffeeHarvestReceipts:" + key)):
        raise ReceiptError("O identificador do recebimento não corresponde ao talhão, dia e safra.")
    if revision != expected["sourceRevision"] or field != expected["fieldLiters"]:
        raise ReceiptError(
            "A origem da colheita mudou. Atualize a colheita antes de registrar o recebimento.",
            "HARVEST_SOURCE_CHANGED",
        )
