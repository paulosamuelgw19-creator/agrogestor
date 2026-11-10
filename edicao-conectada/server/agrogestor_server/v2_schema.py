"""Additive pilot schema. No legacy JSON records are imported or rewritten."""
import hashlib
from datetime import datetime, timezone
from .logistics_schema import STATEMENTS as EIGHTH_STATEMENTS
from .management_schema import STATEMENTS as NINTH_STATEMENTS
from .commercial import TENTH_STATEMENTS
from .geography import STATEMENTS as BOUNDARY_STATEMENTS
from .harvest import STATEMENTS as HARVEST_STATEMENTS
from .implement_usage import STATEMENTS as IMPLEMENT_STATEMENTS

ELEVENTH_STATEMENTS = BOUNDARY_STATEMENTS + HARVEST_STATEMENTS + IMPLEMENT_STATEMENTS


STATEMENTS = [
    """CREATE TABLE v2_clients (
      tenant_id TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL,
      created_at TEXT NOT NULL, PRIMARY KEY(tenant_id,id))""",
    """CREATE TABLE v2_properties (
      tenant_id TEXT NOT NULL, id TEXT NOT NULL, client_id TEXT NOT NULL,
      name TEXT NOT NULL, area_ha TEXT, created_at TEXT NOT NULL,
      PRIMARY KEY(tenant_id,id),
      FOREIGN KEY(tenant_id,client_id) REFERENCES v2_clients(tenant_id,id))""",
    """CREATE TABLE v2_plots (
      tenant_id TEXT NOT NULL, id TEXT NOT NULL, property_id TEXT NOT NULL,
      name TEXT NOT NULL, area_ha TEXT, created_at TEXT NOT NULL,
      PRIMARY KEY(tenant_id,id),
      FOREIGN KEY(tenant_id,property_id) REFERENCES v2_properties(tenant_id,id))""",
    """CREATE TABLE v2_crops (
      tenant_id TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL,
      kind TEXT NOT NULL CHECK(kind IN ('coffee','grain','other')),
      PRIMARY KEY(tenant_id,id))""",
    """CREATE TABLE v2_cycles (
      tenant_id TEXT NOT NULL, id TEXT NOT NULL, plot_id TEXT NOT NULL,
      crop_id TEXT NOT NULL, name TEXT NOT NULL, area_ha TEXT,
      starts_on TEXT NOT NULL, ends_on TEXT,
      PRIMARY KEY(tenant_id,id),
      FOREIGN KEY(tenant_id,plot_id) REFERENCES v2_plots(tenant_id,id),
      FOREIGN KEY(tenant_id,crop_id) REFERENCES v2_crops(tenant_id,id))""",
    "CREATE UNIQUE INDEX v2_user_scope_idx ON users(farm_id,user_id)",
    """CREATE TABLE v2_access (
      tenant_id TEXT NOT NULL, user_id TEXT NOT NULL, property_id TEXT NOT NULL,
      role TEXT NOT NULL CHECK(role IN ('administrator','owner','manager','employee','consultant')),
      PRIMARY KEY(tenant_id,user_id,property_id),
      FOREIGN KEY(tenant_id,user_id) REFERENCES users(farm_id,user_id),
      FOREIGN KEY(tenant_id,property_id) REFERENCES v2_properties(tenant_id,id))""",
    """CREATE TABLE v2_machines (
      tenant_id TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL,
      hour_meter TEXT NOT NULL, hourly_cost_cents INTEGER,
      PRIMARY KEY(tenant_id,id),
      CHECK(hourly_cost_cents IS NULL OR hourly_cost_cents >= 0))""",
    """CREATE TABLE v2_machine_properties (
      tenant_id TEXT NOT NULL, machine_id TEXT NOT NULL, property_id TEXT NOT NULL,
      PRIMARY KEY(tenant_id,machine_id,property_id),
      FOREIGN KEY(tenant_id,machine_id) REFERENCES v2_machines(tenant_id,id),
      FOREIGN KEY(tenant_id,property_id) REFERENCES v2_properties(tenant_id,id))""",
    """CREATE TABLE v2_inputs (
      tenant_id TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL,
      unit TEXT NOT NULL CHECK(unit IN ('kg','L','un')),
      PRIMARY KEY(tenant_id,id))""",
    """CREATE TABLE v2_operations (
      tenant_id TEXT NOT NULL, id TEXT NOT NULL, cycle_id TEXT NOT NULL,
      kind TEXT NOT NULL, performed_on TEXT NOT NULL, area_ha TEXT, notes TEXT NOT NULL,
      labor_hours TEXT, actor_id TEXT NOT NULL, created_at TEXT NOT NULL,
      request_json TEXT NOT NULL,
      PRIMARY KEY(tenant_id,id),
      FOREIGN KEY(tenant_id,cycle_id) REFERENCES v2_cycles(tenant_id,id))""",
    """CREATE TABLE v2_machine_usage (
      tenant_id TEXT NOT NULL, operation_id TEXT NOT NULL, machine_id TEXT NOT NULL,
      start_meter TEXT NOT NULL, end_meter TEXT NOT NULL, hours TEXT NOT NULL,
      meter_gap_hours TEXT NOT NULL, hourly_cost_cents INTEGER, cost_cents INTEGER,
      PRIMARY KEY(tenant_id,operation_id,machine_id),
      FOREIGN KEY(tenant_id,operation_id) REFERENCES v2_operations(tenant_id,id),
      FOREIGN KEY(tenant_id,machine_id) REFERENCES v2_machines(tenant_id,id))""",
    """CREATE TABLE v2_inventory (
      seq INTEGER PRIMARY KEY AUTOINCREMENT, tenant_id TEXT NOT NULL,
      id TEXT NOT NULL, property_id TEXT NOT NULL, input_id TEXT NOT NULL,
      operation_id TEXT, kind TEXT NOT NULL CHECK(kind IN ('opening','receipt','consume')),
      quantity TEXT NOT NULL, value_cents INTEGER, actor_id TEXT NOT NULL,
      occurred_on TEXT NOT NULL, created_at TEXT NOT NULL, request_json TEXT NOT NULL,
      UNIQUE(tenant_id,id),
      FOREIGN KEY(tenant_id,property_id) REFERENCES v2_properties(tenant_id,id),
      FOREIGN KEY(tenant_id,input_id) REFERENCES v2_inputs(tenant_id,id),
      FOREIGN KEY(tenant_id,operation_id) REFERENCES v2_operations(tenant_id,id))""",
    "CREATE INDEX v2_stock_idx ON v2_inventory(tenant_id,property_id,input_id,seq)",
    """CREATE UNIQUE INDEX v2_stock_opening_idx
      ON v2_inventory(tenant_id,property_id,input_id) WHERE kind='opening'""",
    """CREATE TABLE v2_audit (
      seq INTEGER PRIMARY KEY AUTOINCREMENT, tenant_id TEXT NOT NULL,
      property_id TEXT, actor_id TEXT NOT NULL, action TEXT NOT NULL,
      entity_type TEXT NOT NULL, entity_id TEXT NOT NULL, before_json TEXT,
      after_json TEXT NOT NULL, created_at TEXT NOT NULL)""",
    """CREATE TABLE v2_requests (
      tenant_id TEXT NOT NULL, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
      request_json TEXT NOT NULL, PRIMARY KEY(tenant_id,entity_type,entity_id))""",
]

SECOND_STATEMENTS = [
    """CREATE TABLE v2_voids (
      tenant_id TEXT NOT NULL, operation_id TEXT NOT NULL, id TEXT NOT NULL,
      reason TEXT NOT NULL, actor_id TEXT NOT NULL, created_at TEXT NOT NULL,
      request_json TEXT NOT NULL, PRIMARY KEY(tenant_id,operation_id), UNIQUE(tenant_id,id),
      FOREIGN KEY(tenant_id,operation_id) REFERENCES v2_operations(tenant_id,id))""",
]


THIRD_STATEMENTS = [
    "ALTER TABLE v2_inputs ADD COLUMN category TEXT NOT NULL DEFAULT ''",
    "ALTER TABLE v2_inputs ADD COLUMN product_type TEXT NOT NULL DEFAULT ''",
]


FOURTH_STATEMENTS = [
    "ALTER TABLE v2_properties ADD COLUMN location TEXT NOT NULL DEFAULT ''",
    "ALTER TABLE v2_properties ADD COLUMN notes TEXT NOT NULL DEFAULT ''",
    "ALTER TABLE v2_properties ADD COLUMN archived INTEGER NOT NULL DEFAULT 0 CHECK(archived IN (0,1))",
    "ALTER TABLE v2_properties ADD COLUMN version INTEGER NOT NULL DEFAULT 1",
    "ALTER TABLE v2_plots ADD COLUMN notes TEXT NOT NULL DEFAULT ''",
    "ALTER TABLE v2_plots ADD COLUMN archived INTEGER NOT NULL DEFAULT 0 CHECK(archived IN (0,1))",
    "ALTER TABLE v2_plots ADD COLUMN version INTEGER NOT NULL DEFAULT 1",
    """CREATE TABLE v2_catalog_revisions (
      tenant_id TEXT NOT NULL, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
      version INTEGER NOT NULL, snapshot_json TEXT NOT NULL, actor_id TEXT NOT NULL,
      recorded_at TEXT NOT NULL, provenance TEXT NOT NULL,
      PRIMARY KEY(tenant_id,entity_type,entity_id,version))""",
    """CREATE TABLE v2_operation_context (
      tenant_id TEXT NOT NULL, operation_id TEXT NOT NULL, snapshot_json TEXT NOT NULL,
      PRIMARY KEY(tenant_id,operation_id),
      FOREIGN KEY(tenant_id,operation_id) REFERENCES v2_operations(tenant_id,id))""",
]


FIFTH_STATEMENTS = [
    "ALTER TABLE v2_properties ADD COLUMN shared_operators INTEGER NOT NULL DEFAULT 0 CHECK(shared_operators IN (0,1))",
]

SIXTH_STATEMENTS = [
    """CREATE TABLE v2_tasks (
      tenant_id TEXT NOT NULL,id TEXT NOT NULL,property_id TEXT NOT NULL,cycle_id TEXT NOT NULL,
      machine_id TEXT,assignee_id TEXT NOT NULL,title TEXT NOT NULL,kind TEXT NOT NULL,
      due_on TEXT NOT NULL,priority TEXT NOT NULL,planned_area_ha TEXT,planned_hours TEXT,
      planned_cost_cents INTEGER,planned_inputs_json TEXT NOT NULL,notes TEXT NOT NULL,
      status TEXT NOT NULL,version INTEGER NOT NULL,operation_id TEXT,actor_id TEXT NOT NULL,created_at TEXT NOT NULL,
      PRIMARY KEY(tenant_id,id),FOREIGN KEY(tenant_id,property_id) REFERENCES v2_properties(tenant_id,id),
      FOREIGN KEY(tenant_id,cycle_id) REFERENCES v2_cycles(tenant_id,id),
      FOREIGN KEY(tenant_id,machine_id) REFERENCES v2_machines(tenant_id,id),
      FOREIGN KEY(tenant_id,assignee_id) REFERENCES users(farm_id,user_id),
      FOREIGN KEY(tenant_id,operation_id) REFERENCES v2_operations(tenant_id,id))""",
    """CREATE TABLE v2_work_orders (
      tenant_id TEXT NOT NULL,id TEXT NOT NULL,property_id TEXT NOT NULL,machine_id TEXT NOT NULL,
      mechanic_id TEXT,title TEXT NOT NULL,description TEXT NOT NULL,priority TEXT NOT NULL,
      due_on TEXT,next_due_on TEXT,next_due_meter TEXT,status TEXT NOT NULL,version INTEGER NOT NULL,
      machine_released INTEGER NOT NULL CHECK(machine_released IN (0,1)),actor_id TEXT NOT NULL,created_at TEXT NOT NULL,
      PRIMARY KEY(tenant_id,id),FOREIGN KEY(tenant_id,property_id) REFERENCES v2_properties(tenant_id,id),
      FOREIGN KEY(tenant_id,machine_id) REFERENCES v2_machines(tenant_id,id),
      FOREIGN KEY(tenant_id,mechanic_id) REFERENCES users(farm_id,user_id))""",
    """CREATE TABLE v2_work_progress (
      tenant_id TEXT NOT NULL,id TEXT NOT NULL,order_id TEXT NOT NULL,description TEXT NOT NULL,status TEXT NOT NULL,
      labor_hours TEXT,labor_cost_cents INTEGER,service_cost_cents INTEGER,photos_json TEXT NOT NULL,
      actor_id TEXT NOT NULL,created_at TEXT NOT NULL,PRIMARY KEY(tenant_id,id),
      FOREIGN KEY(tenant_id,order_id) REFERENCES v2_work_orders(tenant_id,id))""",
    """CREATE TABLE v2_reservations (
      tenant_id TEXT NOT NULL,order_id TEXT NOT NULL,input_id TEXT NOT NULL,quantity TEXT NOT NULL,
      PRIMARY KEY(tenant_id,order_id,input_id),FOREIGN KEY(tenant_id,order_id) REFERENCES v2_work_orders(tenant_id,id),
      FOREIGN KEY(tenant_id,input_id) REFERENCES v2_inputs(tenant_id,id))""",
    """CREATE TABLE v2_work_parts (
      tenant_id TEXT NOT NULL,progress_id TEXT NOT NULL,input_id TEXT NOT NULL,inventory_id TEXT NOT NULL,
      PRIMARY KEY(tenant_id,progress_id,input_id),FOREIGN KEY(tenant_id,progress_id) REFERENCES v2_work_progress(tenant_id,id),
      FOREIGN KEY(tenant_id,input_id) REFERENCES v2_inputs(tenant_id,id),
      FOREIGN KEY(tenant_id,inventory_id) REFERENCES v2_inventory(tenant_id,id))""",
    """CREATE TABLE v2_checklists (
      tenant_id TEXT NOT NULL,id TEXT NOT NULL,property_id TEXT NOT NULL,machine_id TEXT NOT NULL,phase TEXT NOT NULL,
      items_json TEXT NOT NULL,notes TEXT NOT NULL,actor_id TEXT NOT NULL,created_at TEXT NOT NULL,
      PRIMARY KEY(tenant_id,id),FOREIGN KEY(tenant_id,property_id) REFERENCES v2_properties(tenant_id,id),
      FOREIGN KEY(tenant_id,machine_id) REFERENCES v2_machines(tenant_id,id))""",
    """CREATE TABLE v2_stock_limits (
      tenant_id TEXT NOT NULL,property_id TEXT NOT NULL,input_id TEXT NOT NULL,minimum_quantity TEXT NOT NULL,
      PRIMARY KEY(tenant_id,property_id,input_id),FOREIGN KEY(tenant_id,property_id) REFERENCES v2_properties(tenant_id,id),
      FOREIGN KEY(tenant_id,input_id) REFERENCES v2_inputs(tenant_id,id))""",
    """CREATE TABLE v2_work_photos (
      tenant_id TEXT NOT NULL,id TEXT NOT NULL,target_kind TEXT NOT NULL,target_id TEXT NOT NULL,
      sha256 TEXT NOT NULL,size_bytes INTEGER NOT NULL,mime_type TEXT NOT NULL,actor_id TEXT NOT NULL,created_at TEXT NOT NULL,
      PRIMARY KEY(tenant_id,id))""",
]

SEVENTH_STATEMENTS = [
    """CREATE TABLE v2_refuelings (
      tenant_id TEXT NOT NULL,id TEXT NOT NULL,operation_id TEXT NOT NULL,machine_id TEXT NOT NULL,
      source TEXT NOT NULL CHECK(source IN ('stock','external')),input_id TEXT,liters TEXT NOT NULL,hour_meter TEXT NOT NULL,
      unit_price_cents INTEGER,total_cost_cents INTEGER,fuel_name TEXT NOT NULL,location TEXT NOT NULL,
      actor_id TEXT NOT NULL,occurred_on TEXT NOT NULL,created_at TEXT NOT NULL,
      PRIMARY KEY(tenant_id,id),FOREIGN KEY(tenant_id,operation_id) REFERENCES v2_operations(tenant_id,id),
      FOREIGN KEY(tenant_id,machine_id) REFERENCES v2_machines(tenant_id,id),
      FOREIGN KEY(tenant_id,input_id) REFERENCES v2_inputs(tenant_id,id))""",
    'CREATE INDEX v2_refuelings_machine_day ON v2_refuelings(tenant_id,machine_id,occurred_on)',
]


def migrate(db):
    """One transaction, versioned checksum, safe to call repeatedly."""
    db.execute("BEGIN IMMEDIATE")
    db.execute("""CREATE TABLE IF NOT EXISTS v2_migrations (
      version INTEGER PRIMARY KEY, checksum TEXT NOT NULL, applied_at TEXT NOT NULL)""")
    for version, statements in [(1, STATEMENTS), (2, SECOND_STATEMENTS), (3, THIRD_STATEMENTS), (4, FOURTH_STATEMENTS), (5, FIFTH_STATEMENTS), (6, SIXTH_STATEMENTS), (7, SEVENTH_STATEMENTS), (8, EIGHTH_STATEMENTS), (9, NINTH_STATEMENTS), (10, TENTH_STATEMENTS), (11, ELEVENTH_STATEMENTS)]:
        digest = hashlib.sha256("\n".join(statements).encode()).hexdigest()
        row = db.execute("SELECT checksum FROM v2_migrations WHERE version=?", (version,)).fetchone()
        if row:
            if row[0] != digest:
                raise RuntimeError("O esquema v2 diverge da migração registrada; restaure os fontes correspondentes.")
            continue
        for statement in statements:
            db.execute(statement)
        db.execute("INSERT INTO v2_migrations VALUES(?,?,?)", (version, digest, datetime.now(timezone.utc).isoformat()))
