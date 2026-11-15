"""Connected coffee lots backed by confirmed physical receipts."""

import json
import math
import re
from collections import defaultdict
from datetime import date
from uuid import UUID

from .connected_receipt import MODULE as RECEIPTS

MODULE = "coffeeProcessingLots"
SALES_RECEIPTS = "coffeeSaleReceipts"
_ID = re.compile(r"[A-Za-z0-9_.:-]{1,160}")
_DAY = re.compile(r"([0-9]{4}-[0-9]{2}-[0-9]{2})(?:T00:00:00(?:\.0{1,6})?)?")
_LIMIT = 1_000_000_000_000


class ProcessingError(ValueError):
    def __init__(self, message, code="INVALID_COFFEE_LOT"):
        super().__init__(message)
        self.code = code


def _fields(data, required, optional=()):
    if not isinstance(data, dict) or not set(required) <= data.keys() or set(data) - (set(required) | set(optional)):
        raise ProcessingError("Confira os dados do lote e seus movimentos.")


def _id(value):
    if not isinstance(value, str) or not _ID.fullmatch(value):
        raise ProcessingError("O lote contém um identificador inválido.")
    return value


def _uuid(value):
    try:
        if str(UUID(_id(value))) == value:
            return value
    except ValueError:
        pass
    raise ProcessingError("O identificador do lote deve ser um UUID válido.")


def _text(value, limit, *, required=False):
    if not isinstance(value, str) or len(value) > limit or (required and not value.strip()):
        raise ProcessingError("Confira o código e os textos do lote.")


def _day(value):
    match = _DAY.fullmatch(value) if isinstance(value, str) else None
    try:
        if match is not None:
            return date.fromisoformat(match[1])
    except ValueError:
        pass
    raise ProcessingError("Confira a data do lote ou movimento.")


def _amount(value, *, zero=False):
    if (type(value) not in (float, int)
            or not 0 <= value <= _LIMIT
            or (not zero and value == 0)):
        raise ProcessingError("Confira o volume ou o peso informado no lote.")
    return value


def _over(value, limit):
    return value - limit > max(abs(value), abs(limit)) * 1.8e-15


def _same(left, right):
    return json.dumps(left, sort_keys=True) == json.dumps(right, sort_keys=True)


def _input(item):
    _fields(item, ("id", "kind", "origin", "receiptId", "volumeLiters", "notes"),
            ("plotId", "harvestDate", "linkedLiters"))
    _id(item["id"])
    _id(item["receiptId"])
    _text(item["notes"], 4000)
    if item["kind"] not in ("picked", "raked") or item["origin"] != "confirmed":
        raise ProcessingError("Vincule a entrada a um recebimento físico confirmado.")
    liters = _amount(item["volumeLiters"])
    if "linkedLiters" in item:
        linked = _amount(item["linkedLiters"])
        if _over(liters, linked) or _over(linked, liters):
            raise ProcessingError("Os litros vinculados devem corresponder à entrada do lote.")
    if ("plotId" in item) != ("harvestDate" in item):
        raise ProcessingError("Informe juntos o talhão e o dia de origem do lote.")
    if "plotId" in item:
        _id(item["plotId"])
        _day(item["harvestDate"])


def _measurement(item):
    _fields(item, ("id", "date", "stage", "location", "state", "notes"), ("volumeLiters",))
    if item["stage"] not in ("reception", "washed", "dried", "cleaned", "other"):
        raise ProcessingError("A etapa da medição é inválida.")
    _text(item["location"], 300)
    _text(item["state"], 300)
    if "volumeLiters" in item:
        _amount(item["volumeLiters"], zero=True)


def _output_kg(item):
    mode = item["unit"]
    quantity = _amount(item["quantity"], zero=mode == "bags")
    if mode == "kilograms" and "kgPerBag" not in item and "remainderKg" not in item:
        return quantity
    if mode == "bags" and quantity == math.floor(quantity):
        bag_weight = _amount(item.get("kgPerBag"))
        remainder = _amount(item.get("remainderKg", 0), zero=True)
        if remainder < bag_weight:
            return _amount(quantity * bag_weight + remainder)
    raise ProcessingError("Informe o peso em kg, ou sacos inteiros com peso e sobra.")


def _cleaning(item):
    _fields(item, ("id", "date", "unit", "quantity", "notes"),
            ("kgPerBag", "remainderKg", "inputLiters", "inputBase"))
    output_kg = _output_kg(item)
    basis = item.get("inputBase")
    if "inputBase" in item and basis not in ("ripe", "dry", "washed"):
        raise ProcessingError("A base de entrada da limpa é inválida.")
    if "inputLiters" in item:
        liters = _amount(item["inputLiters"])
        if basis is not None and not math.isfinite(output_kg / liters):
            raise ProcessingError("Confira o rendimento informado na limpa.")
    return output_kg


def _cents(value):
    if type(value) is not int or not 0 < value <= _LIMIT:
        raise ProcessingError("Informe um valor em centavos maior que zero.")
    return value


def _sale(item):
    _fields(item, ("id", "date", "unit", "quantity", "totalPriceCents", "buyer", "notes"),
            ("kgPerBag", "remainderKg"))
    _cents(item["totalPriceCents"])
    _text(item["buyer"], 300)
    return _output_kg(item)


def _validate_lot(payload):
    _fields(payload, ("id", "propertyId", "seasonYear", "code", "date", "location", "notes",
                      "inputs", "measurements", "cleanings", "sales"))
    _uuid(payload["id"])
    _id(payload["propertyId"])
    year = payload["seasonYear"]
    if type(year) is not int or not 1900 <= year <= 9999:
        raise ProcessingError("Confira o ano da safra.")
    opened = _day(payload["date"])
    _text(payload["code"], 160, required=True)
    _text(payload["location"], 300)
    _text(payload["notes"], 4000)
    if (not all(isinstance(payload[key], list) for key in ("inputs", "measurements", "cleanings", "sales"))
            or not payload["inputs"]):
        raise ProcessingError("Inclua pelo menos uma entrada no lote.")
    inputs = set()
    for item in payload["inputs"]:
        _input(item)
        if item["id"] in inputs:
            raise ProcessingError("Há uma entrada repetida neste lote.")
        inputs.add(item["id"])
    movements = set()
    production_by_day, sales_by_day = defaultdict(list), defaultdict(list)
    for items, check, amounts in (
        (payload["measurements"], _measurement, None),
        (payload["cleanings"], _cleaning, production_by_day),
        (payload["sales"], _sale, sales_by_day),
    ):
        for item in items:
            weight = check(item)
            record_id = _id(item["id"])
            _text(item["notes"], 4000)
            occurred = _day(item["date"])
            if record_id in movements or occurred < opened:
                raise ProcessingError("Há um movimento duplicado ou anterior à abertura do lote.")
            movements.add(record_id)
            if amounts is not None:
                amounts[occurred].append(weight)
    ripe_in = math.fsum(item["volumeLiters"] for item in payload["inputs"]
                        if item["kind"] == "picked")
    used = math.fsum(item.get("inputLiters", 0) for item in payload["cleanings"]
                     if item.get("inputBase") == "ripe")
    if _over(used, ripe_in):
        raise ProcessingError("As limpas excedem o volume de café maduro do lote.")
    produced = sold = 0
    for day in sorted(production_by_day.keys() | sales_by_day.keys()):
        produced = math.fsum((produced, *production_by_day[day]))
        sold = math.fsum((sold, *sales_by_day[day]))
        if _over(sold, produced):
            raise ProcessingError("O estoque beneficiado é insuficiente na data da venda.",
                                  "COFFEE_LOT_STOCK_INSUFFICIENT")
    return movements


def validate(db, tenant, event, current):
    """Validate with the SQLite write lock already held by sync."""
    if event.operation != "upsert" or (current is not None and current["deleted"]):
        raise ProcessingError("O histórico do lote não pode ser apagado ou recriado.")
    data = event.payload
    moves = _validate_lot(data)
    if data["id"] != event.recordId:
        raise ProcessingError("O identificador do lote não corresponde ao lançamento.")
    previous = json.loads(current["payload"]) if current is not None else None
    property_id, season = data["propertyId"], data["seasonYear"]
    if previous is not None:
        if (previous["propertyId"], previous["seasonYear"]) != (property_id, season):
            raise ProcessingError("O lote pertence a outra fazenda ou safra.")
        if previous["cleanings"] and not _same(data["inputs"], previous["inputs"]):
            raise ProcessingError("As entradas não podem ser alteradas depois da primeira limpa.")
        for key in ("measurements", "cleanings", "sales"):
            old = previous[key]
            if not _same(data[key][:len(old)], old):
                raise ProcessingError("Os movimentos registrados não podem ser alterados ou apagados.")
    property_row = db.execute(
        "SELECT archived FROM v2_properties WHERE tenant_id=? AND id=?", (tenant, property_id),
    ).fetchone()
    if property_row is None or (previous is None and property_row["archived"]):
        raise ProcessingError("A fazenda do lote não está disponível.")

    claimed = defaultdict(list)
    for item in data["inputs"]:
        claimed[item["receiptId"]].append(item["volumeLiters"])
    for row in db.execute(
        "SELECT payload FROM records WHERE farm_id=? AND module=? AND deleted=0 AND record_id<>?",
        (tenant, MODULE, event.recordId),
    ):
        lot = json.loads(row["payload"])
        if ((lot["propertyId"], lot["seasonYear"]) == (property_id, season)
                and lot["code"].strip().casefold() == data["code"].strip().casefold()):
            raise ProcessingError("Já existe um lote com este código nesta fazenda e safra.",
                                  "COFFEE_LOT_CODE_EXISTS")
        for key in ("measurements", "cleanings", "sales"):
            if any(item["id"] in moves for item in lot[key]):
                raise ProcessingError("Um movimento já pertence a outro lote.")
        for item in lot["inputs"]:
            receipt = item.get("receiptId")
            if receipt in claimed:
                claimed[receipt].append(item["volumeLiters"])

    for item in data["inputs"]:
        receipt_id = item["receiptId"]
        row = db.execute(
            "SELECT payload FROM records WHERE farm_id=? AND module=? AND record_id=? AND deleted=0",
            (tenant, RECEIPTS, receipt_id),
        ).fetchone()
        received = json.loads(row["payload"]) if row else None
        if (received is None or (received["propertyId"], received["seasonYear"]) != (property_id, season)
                or ("plotId" in item and item["plotId"] != received["plotId"])
                or ("harvestDate" in item and _day(item["harvestDate"]) != _day(received["harvestDate"]))
                or _day(data["date"]) < _day(received["receivedDate"])):
            raise ProcessingError("A entrada não corresponde a um recebimento confirmado desta fazenda e safra.")
        if _over(math.fsum(claimed[receipt_id]), received["receivedLiters"]):
            raise ProcessingError("O volume reservado excede o saldo do recebimento.",
                                  "COFFEE_RECEIPT_OVERALLOCATED")


def validate_sale_receipt(db, tenant, event, current):
    """Financial receipts use the same transaction as versioning and audit."""
    if event.operation != "upsert" or current is not None:
        raise ProcessingError("Um recebimento confirmado não pode ser editado ou apagado.")
    data = event.payload
    _fields(data, ("id", "propertyId", "lotId", "saleId", "date", "amountCents", "notes"))
    for identity in ("id", "propertyId", "lotId", "saleId"):
        _id(data[identity])
    if data["id"] != event.recordId:
        raise ProcessingError("O identificador do recebimento é inválido.")
    occurred = _day(data["date"])
    amount = _cents(data["amountCents"])
    _text(data["notes"], 4000)
    row = db.execute(
        "SELECT payload FROM records WHERE farm_id=? AND module=? AND record_id=? AND deleted=0",
        (tenant, MODULE, data["lotId"]),
    ).fetchone()
    lot = json.loads(row["payload"]) if row else None
    if lot is None or lot["propertyId"] != data["propertyId"]:
        raise ProcessingError("A venda confirmada não existe nesta fazenda.")
    sale = next((item for item in lot["sales"] if item["id"] == data["saleId"]), None)
    if sale is None:
        raise ProcessingError("A venda confirmada não existe neste lote.")
    if occurred < _day(sale["date"]):
        raise ProcessingError("O recebimento não pode ser anterior à venda.")
    already_received = db.execute(
        """SELECT COALESCE(SUM(json_extract(payload,'$.amountCents')),0) FROM records
           WHERE farm_id=? AND module=? AND deleted=0
           AND json_extract(payload,'$.propertyId')=?
           AND json_extract(payload,'$.lotId')=?
           AND json_extract(payload,'$.saleId')=?""",
        (tenant, SALES_RECEIPTS, data["propertyId"], data["lotId"], data["saleId"]),
    ).fetchone()[0]
    if already_received + amount > sale["totalPriceCents"]:
        raise ProcessingError("O recebimento ultrapassa o saldo da venda.",
                              "COFFEE_SALE_RECEIPT_EXCEEDS_BALANCE")
