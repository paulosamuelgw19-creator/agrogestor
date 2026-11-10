"""Short-lived real API fixture for the Dart client integration test; synthetic only."""
import json
from pathlib import Path
import sys
import threading
import uvicorn
from test_v2_pilot import PilotTests, api


def main():
    case = PilotTests('test_fictitious_report_matches_hand_calculation')
    case.setUp()
    case.opening()
    with api.connect() as db:
        db.execute("INSERT INTO users(user_id,farm_id,email,display_name,role,password_hash,created_at) VALUES('mechanic','org-a','mechanic@example.invalid','Mecânico fictício','mechanic','unused',?)",(api.utc_now(),))
        db.execute("INSERT INTO devices(farm_id,device_id,device_name,activated_by,activated_at,last_seen_at) VALUES('org-a','device-mechanic','Synthetic','mechanic',?,?)",(api.utc_now(),api.utc_now()))
    mechanic_token=api.make_token('mechanic','org-a','device-mechanic')
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 8767
    destination = Path(sys.argv[1])
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps({'url': f'http://127.0.0.1:{port}', 'token': case.tokens['admin']['Authorization'].split(' ', 1)[1],
        'worker_token': case.tokens['worker']['Authorization'].split(' ', 1)[1],
        'mechanic_token':mechanic_token,
        'property': case.prop, 'cycle': case.cycle, 'machine': case.machine, 'input': case.diesel}), encoding='utf-8')
    server = uvicorn.Server(uvicorn.Config(api.app, host='127.0.0.1', port=port, log_level='warning', access_log=False))
    timer = threading.Timer(180, lambda: setattr(server, 'should_exit', True))
    timer.daemon = True
    timer.start()
    try:
        server.run()
    finally:
        timer.cancel()
        case.tearDown()
        destination.unlink(missing_ok=True)


if __name__ == '__main__':
    main()
