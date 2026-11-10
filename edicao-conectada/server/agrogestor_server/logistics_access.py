"""Dedicated driver access. Property/operator grants do not authorize trips."""
from fastapi import HTTPException


def is_driver_account(db, tenant, user_id):
    return db.execute(
        'SELECT 1 FROM v2_driver_accounts WHERE tenant_id=? AND user_id=?',
        (tenant, user_id)).fetchone() is not None


def effective_role(db, row):
    # Always recognize the restriction, even if the v2 feature is disabled.
    # An archived driver or an unlinked driver record never becomes an operator.
    installed = db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='v2_driver_accounts'").fetchone()
    if installed and is_driver_account(db, row['farm_id'], row['user_id']):
        return 'driver'
    return row['role']


def require_trip_access(db, user, trip_id, *, administer=False):
    tenant = user['farmId']
    row = db.execute('SELECT * FROM v2_trips WHERE tenant_id=? AND id=?',
                     (tenant, str(trip_id))).fetchone()
    if row is None:
        raise HTTPException(404, 'Viagem não disponível para esta conta.')
    if user['role'] == 'admin':
        return row
    if administer:
        raise HTTPException(403, 'Somente o gestor pode administrar esta viagem.')
    if user['role'] != 'driver' or not is_driver_account(db, tenant, user['id']):
        raise HTTPException(404, 'Viagem não disponível para esta conta.')
    driver = db.execute('''SELECT 1 FROM v2_drivers d JOIN users u
      ON u.farm_id=d.tenant_id AND u.user_id=d.user_id
      WHERE d.tenant_id=? AND d.id=? AND d.user_id=? AND d.archived=0 AND u.disabled=0''',
        (tenant, row['driver_id'], user['id'])).fetchone()
    if driver is None:
        raise HTTPException(404, 'Viagem não disponível para esta conta.')
    return row


def require_driver_details(db, user, driver_id):
    row = db.execute('SELECT * FROM v2_drivers WHERE tenant_id=? AND id=?',
                     (user['farmId'], str(driver_id))).fetchone()
    if row is None:
        raise HTTPException(404, 'Caminhoneiro não disponível para esta conta.')
    if user['role'] == 'admin':
        return row
    if (user['role'] == 'driver' and row['user_id'] == user['id']
            and not row['archived'] and is_driver_account(db, user['farmId'], user['id'])):
        active = db.execute('SELECT 1 FROM users WHERE farm_id=? AND user_id=? AND disabled=0',
                            (user['farmId'], user['id'])).fetchone()
        if active:
            return row
    raise HTTPException(404, 'Caminhoneiro não disponível para esta conta.')
