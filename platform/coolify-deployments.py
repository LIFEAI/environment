#!/usr/bin/env python3
"""
Coolify deployment utility — cancel active builds, list status.
Usage:
  python3 scripts/coolify-deployments.py          # list active deployments
  python3 scripts/coolify-deployments.py cancel   # cancel all active deployments
"""
import json, subprocess, sys

BASE = 'https://deploy.regendevcorp.com/api/v1'
ACTIVE_STATUSES = {'in_progress', 'queued', 'running', 'building', 'started'}

def get_token():
    raw = subprocess.check_output(
        ['curl', '-s', 'http://127.0.0.1:52437/get/coolify-api']
    ).decode()
    d = json.loads(raw)
    return (d.get('value') or d.get('token') or d.get('api_key') or list(d.values())[0]).strip()

def api_get(token, path):
    out = subprocess.check_output([
        'curl', '-s', '-H', f'Authorization: Bearer {token}',
        '-H', 'Accept: application/json',
        BASE + path
    ], timeout=15).decode()
    data = json.loads(out)
    # /deployments returns a dict keyed by index — normalise to list
    if isinstance(data, dict) and all(k.isdigit() for k in list(data.keys())[:3]):
        return list(data.values())
    return data if isinstance(data, list) else data.get('data', data)

def api_post(token, path):
    out = subprocess.check_output([
        'curl', '-s', '-X', 'POST',
        '-H', f'Authorization: Bearer {token}',
        '-H', 'Accept: application/json',
        BASE + path
    ], timeout=10).decode()
    try:
        return json.loads(out)
    except Exception:
        return {'raw': out[:120]}

def main():
    cancel_mode = len(sys.argv) > 1 and sys.argv[1] == 'cancel'
    token = get_token()

    rows = api_get(token, '/deployments')
    active = [r for r in rows if str(r.get('status', '')).lower() in ACTIVE_STATUSES]

    print(f'Active deployments: {len(active)} / {len(rows)} total')
    for r in active:
        dep_uuid = r.get('deployment_uuid') or r.get('uuid', '')
        app = r.get('application_name', '?')[:35]
        status = r.get('status', '?')
        commit = str(r.get('commit', ''))[:8]
        print(f'  [{status:12}] {app:35} {dep_uuid[:16]} commit={commit}')

    if cancel_mode and active:
        print(f'\nCancelling {len(active)} deployments...')
        cancelled = 0
        for r in active:
            dep_uuid = r.get('deployment_uuid') or r.get('uuid', '')
            app = r.get('application_name', '?')[:35]
            result = api_post(token, f'/deployments/{dep_uuid}/cancel')
            msg = result.get('message') or result.get('status') or result.get('raw', '?')
            print(f'  CANCEL [{app}] -> {msg[:60]}')
            cancelled += 1
        print(f'Done. Cancelled {cancelled}.')
    elif not cancel_mode and active:
        print('\nRun with "cancel" argument to cancel all active deployments.')

if __name__ == '__main__':
    main()
