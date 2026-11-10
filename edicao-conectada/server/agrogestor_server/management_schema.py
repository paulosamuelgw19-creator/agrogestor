"""Additive management records; historical operations are never backfilled."""
STATEMENTS = [
    '''CREATE TABLE v2_property_responsibles (
      tenant_id TEXT NOT NULL, property_id TEXT NOT NULL, user_id TEXT NOT NULL,
      PRIMARY KEY(tenant_id,property_id),
      FOREIGN KEY(tenant_id,property_id) REFERENCES v2_properties(tenant_id,id),
      FOREIGN KEY(tenant_id,user_id) REFERENCES users(farm_id,user_id))''',
    "ALTER TABLE v2_inputs ADD COLUMN notes TEXT NOT NULL DEFAULT ''",
    '''CREATE TABLE v2_operation_measurements (
      tenant_id TEXT NOT NULL, operation_id TEXT NOT NULL, started_at TEXT, ended_at TEXT,
      consumed_fuel_liters TEXT, labor_cost_cents INTEGER, PRIMARY KEY(tenant_id,operation_id),
      FOREIGN KEY(tenant_id,operation_id) REFERENCES v2_operations(tenant_id,id))''',
    '''CREATE TABLE v2_activity_plans (
      tenant_id TEXT NOT NULL,id TEXT NOT NULL,title TEXT NOT NULL,season_name TEXT NOT NULL,
      activity TEXT NOT NULL,starts_on TEXT,due_on TEXT,notes TEXT NOT NULL,
      actor_id TEXT NOT NULL,created_at TEXT NOT NULL,PRIMARY KEY(tenant_id,id))''',
    '''CREATE TABLE v2_plan_plots (
      tenant_id TEXT NOT NULL,plan_id TEXT NOT NULL,cycle_id TEXT NOT NULL,
      activity TEXT NOT NULL,season_name TEXT NOT NULL,planned_ha TEXT NOT NULL,
      completed_ha TEXT NOT NULL DEFAULT '0',version INTEGER NOT NULL DEFAULT 1,
      assignee_id TEXT,PRIMARY KEY(tenant_id,plan_id,cycle_id),
      UNIQUE(tenant_id,cycle_id,activity,season_name),
      FOREIGN KEY(tenant_id,plan_id) REFERENCES v2_activity_plans(tenant_id,id),
      FOREIGN KEY(tenant_id,cycle_id) REFERENCES v2_cycles(tenant_id,id),
      FOREIGN KEY(tenant_id,assignee_id) REFERENCES users(farm_id,user_id))''',
    '''CREATE TABLE v2_plan_events (
      tenant_id TEXT NOT NULL,id TEXT NOT NULL,plan_id TEXT NOT NULL,cycle_id TEXT NOT NULL,
      operation_id TEXT,previous_ha TEXT NOT NULL,completed_ha TEXT NOT NULL,
      actor_id TEXT NOT NULL,reason TEXT NOT NULL,created_at TEXT NOT NULL,
      PRIMARY KEY(tenant_id,id),
      FOREIGN KEY(tenant_id,plan_id,cycle_id) REFERENCES v2_plan_plots(tenant_id,plan_id,cycle_id),
      FOREIGN KEY(tenant_id,operation_id) REFERENCES v2_operations(tenant_id,id))''',
]


def property_record(db, tenant, row):
    value = dict(row)
    person = db.execute('''SELECT u.user_id,u.display_name FROM v2_property_responsibles r
      JOIN users u ON u.farm_id=r.tenant_id AND u.user_id=r.user_id
      WHERE r.tenant_id=? AND r.property_id=?''', (tenant, row['id'])).fetchone()
    value['responsible_user_id'] = person['user_id'] if person else None
    value['responsible_name'] = person['display_name'] if person else None
    return value


def set_responsible(db, user, property_id, person):
    from fastapi import HTTPException
    if person is not None and not db.execute('SELECT 1 FROM users WHERE farm_id=? AND user_id=? AND disabled=0',
            (user['farmId'], person)).fetchone():
        raise HTTPException(422, 'Selecione um funcionário ativo desta organização.')
    db.execute('DELETE FROM v2_property_responsibles WHERE tenant_id=? AND property_id=?', (user['farmId'], str(property_id)))
    if person is not None:
        db.execute('INSERT INTO v2_property_responsibles VALUES(?,?,?)', (user['farmId'], str(property_id), person))
