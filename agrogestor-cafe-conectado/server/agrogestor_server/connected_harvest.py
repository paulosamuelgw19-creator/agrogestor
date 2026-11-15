"""Validation for the Coffee app records carried by legacy versioned sync."""

import json
import math
import re
from datetime import datetime
from uuid import NAMESPACE_URL, uuid5

HARVEST_ENTRIES = "coffeeHarvestEntries"
PLOT_PRODUCTION = "coffeePlotProduction"
MODULES = frozenset({HARVEST_ENTRIES, PLOT_PRODUCTION})
MAX_QUANTITY = 1_000_000_000_000
_IDENTIFIER = re.compile(r"[A-Za-z0-9_.:-]{1,160}")
_ISO_CIVIL_DATE = re.compile(
    r"\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z?)?",
    re.ASCII,
)
_COMMON = {"id", "propertyId", "plotId", "date", "seasonYear", "unit",
           "quantity", "litersPerMeasure", "cartCapacityLiters"}


class HarvestValidationError(ValueError):
    def __init__(self, message, code="INVALID_HARVEST"):
        super().__init__(message)
        self.code = code


def _amount(value, *, zero=False):
    if (type(value) not in (int, float)
            or not 0 <= value <= MAX_QUANTITY
            or (not zero and value == 0)):
        raise HarvestValidationError("Confira as quantidades e unidades da colheita.")
    return value


def _day(value):
    if not isinstance(value, str) or not _ISO_CIVIL_DATE.fullmatch(value):
        raise HarvestValidationError("Confira a data do lançamento da colheita.")
    try:
        return datetime.fromisoformat(value.removesuffix("Z")).date().isoformat()
    except ValueError as error:
        raise HarvestValidationError("Confira a data do lançamento da colheita.") from error


def declaration_id(property_id, plot_id, season, day):
    key = json.dumps([property_id, plot_id, season, day],
                     ensure_ascii=False, separators=(",", ":"))
    return str(uuid5(NAMESPACE_URL, "agrogestor:coffeePlotProduction:" + key))


def _require_plot(db, tenant, property_id, plot_id, *, new):
    row = db.execute(
        """SELECT p.archived AS property_archived, t.archived AS plot_archived
           FROM v2_plots t JOIN v2_properties p
             ON p.tenant_id=t.tenant_id AND p.id=t.property_id
           WHERE t.tenant_id=? AND p.id=? AND t.id=?""",
        (tenant, property_id, plot_id),
    ).fetchone()
    if row is None or (new and (row["property_archived"] or row["plot_archived"])):
        raise HarvestValidationError("Selecione um talhão disponível desta fazenda.")


def _require_worker(db, tenant, payload):
    worker_id = payload.get("workerId")
    name = payload.get("workerName")
    if (not isinstance(worker_id, str) or not _IDENTIFIER.fullmatch(worker_id)
            or not isinstance(name, str) or not name.strip() or len(name) > 300):
        raise HarvestValidationError("Selecione um trabalhador cadastrado.")
    operator = db.execute(
        """SELECT payload FROM records
           WHERE farm_id=? AND module='operators' AND record_id=? AND deleted=0""",
        (tenant, worker_id),
    ).fetchone()
    worker = json.loads(operator["payload"] or "{}") if operator else {}
    worker_name = worker.get("name")
    if (worker.get("active", True) is not True or not isinstance(worker_name, str)
            or worker_name.strip() != name.strip()):
        raise HarvestValidationError("Selecione um trabalhador ativo cadastrado nesta fazenda.")


def _declared_worker_total(db, tenant, property_id, plot_id, season, day):
    rows = db.execute(
        """SELECT payload FROM records WHERE farm_id=? AND module=? AND deleted=0
           AND json_extract(payload,'$.propertyId')=?
           AND json_extract(payload,'$.plotId')=?
           AND json_extract(payload,'$.seasonYear')=?
           AND substr(json_extract(payload,'$.date'),1,10)=? ORDER BY record_id""",
        (tenant, HARVEST_ENTRIES, property_id, plot_id, season, day),
    ).fetchall()
    if not rows:
        return None
    volumes = []
    for row in rows:
        item = json.loads(row["payload"])
        unit = item["unit"]
        multiplier = item["litersPerMeasure"] if unit == "measures" else (
            item["cartCapacityLiters"] if unit == "carts" else 1
        )
        volumes.append(item["quantity"] * multiplier)
    return math.fsum(volumes)


def validate(db, tenant, event, current, *, v2_enabled):
    """Called inside the sync write transaction; its lock covers validation and upsert."""
    if not v2_enabled:
        raise HarvestValidationError("Ative o catálogo no PC gestor para sincronizar a colheita.")
    if event.operation != "upsert" or (current is not None and current["deleted"]):
        raise HarvestValidationError("O histórico da colheita não pode ser apagado ou recriado.")

    entry = event.module == HARVEST_ENTRIES
    payload = event.payload
    extra = {"workerId", "workerName", "ratePerMeasureCents"} if entry else {
        "remainderLiters", "checkedWorkerLiters"
    }
    if set(payload) - (_COMMON | extra) or payload.get("id") != event.recordId:
        raise HarvestValidationError("Os dados do lançamento da colheita são inválidos.")
    if payload.get("ratePerMeasureCents") is not None:
        raise HarvestValidationError("As tarifas ficam na edição local.")
    property_id, plot_id, season = (payload.get(key) for key in ("propertyId", "plotId", "seasonYear"))
    if (not all(isinstance(value, str) and _IDENTIFIER.fullmatch(value)
                for value in (property_id, plot_id))
            or type(season) is not int or not 1900 <= season <= 9999):
        raise HarvestValidationError("Confira a fazenda, o talhão e o ano da safra.")
    day = _day(payload.get("date"))
    _require_plot(db, tenant, property_id, plot_id, new=current is None)

    unit = payload.get("unit")
    quantity = _amount(payload.get("quantity"), zero=not entry)
    measure = _amount(payload.get("litersPerMeasure"))
    capacity = payload.get("cartCapacityLiters")
    remainder = payload.get("remainderLiters")
    if unit == "measures":
        if not entry and quantity != math.floor(quantity):
            raise HarvestValidationError("Informe medidas inteiras e a sobra em litros.")
        volume = quantity * measure
        if remainder is not None:
            if _amount(remainder, zero=True) >= measure:
                raise HarvestValidationError("A sobra deve ser menor que uma medida.")
            volume += remainder
    elif unit == "liters":
        volume = quantity
    elif unit == "carts":
        volume = quantity * _amount(capacity)
    else:
        raise HarvestValidationError("Selecione uma unidade de colheita válida.")
    if capacity is not None and unit != "carts":
        if not entry:
            raise HarvestValidationError("Informe capacidade somente para carretas.")
        _amount(capacity)
    if remainder is not None and unit != "measures":
        raise HarvestValidationError("Informe sobra somente com medidas.")
    _amount(volume, zero=not entry)
    previous = json.loads(current["payload"]) if current is not None else None
    if entry:
        _amount(volume / measure)
        if previous is None:
            _require_worker(db, tenant, payload)
        elif payload != previous:
            raise HarvestValidationError("O lançamento por pessoa já está registrado.")
        return

    if previous is not None and (
        previous["propertyId"], previous["plotId"], previous["seasonYear"], _day(previous["date"])
    ) != (property_id, plot_id, season, day):
        raise HarvestValidationError("A declaração pertence a outro talhão, dia ou safra.")
    duplicate = db.execute(
        """SELECT 1 FROM records WHERE farm_id=? AND module=? AND deleted=0
           AND json_extract(payload,'$.propertyId')=?
           AND json_extract(payload,'$.plotId')=?
           AND json_extract(payload,'$.seasonYear')=?
           AND substr(json_extract(payload,'$.date'),1,10)=?
           AND record_id<>? LIMIT 1""",
        (tenant, PLOT_PRODUCTION, property_id, plot_id, season, day, event.recordId),
    ).fetchone()
    if duplicate is not None:
        raise HarvestValidationError(
            "Já existe uma produção declarada para este talhão, dia e safra. Atualize a colheita.",
            "HARVEST_DAY_ALREADY_DECLARED",
        )
    if event.recordId != declaration_id(property_id, plot_id, season, day):
        raise HarvestValidationError(
            "O identificador desta declaração não corresponde ao talhão, dia e safra.",
            "HARVEST_DAY_ID_MISMATCH",
        )
    checked = payload.get("checkedWorkerLiters")
    if checked is not None:
        # A declaration reviewed offline may reach the server already carrying
        # the snapshot. It still has to match the worker entries on the server.
        total = _declared_worker_total(db, tenant, property_id, plot_id, season, day)
        if (type(checked) not in (int, float)
                or total is None or not 0 <= checked <= total + 1e-6
                or not math.isclose(checked, total, abs_tol=1e-6, rel_tol=0)):
            raise HarvestValidationError(
                "O total por pessoa mudou. Sincronize a colheita antes de conferir a declaração.",
                "HARVEST_WORKER_TOTAL_CHANGED",
            )
