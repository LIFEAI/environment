import urllib.request, json, subprocess

base = 'https://deploy.regendevcorp.com/api/v1'

raw = subprocess.check_output(
    ['curl', '-s', 'http://127.0.0.1:52437/get/coolify-api']
).decode()
parsed = json.loads(raw)
token = (parsed.get('value') or parsed.get('token') or parsed.get('api_key') or list(parsed.values())[0]).strip()
print(f'Token prefix: {token[:6]}...')

hdrs = {
    'Authorization': f'Bearer {token}',
    'Accept': 'application/json',
    'Content-Type': 'application/json',
}

def get(path):
    out = subprocess.check_output([
        'curl', '-s', '-H', f'Authorization: Bearer {token}',
        '-H', 'Accept: application/json',
        base + path
    ]).decode()
    return json.loads(out)

def post_cancel(dep_uuid):
    out = subprocess.check_output([
        'curl', '-s', '-X', 'POST',
        '-H', f'Authorization: Bearer {token}',
        '-H', 'Accept: application/json',
        '-H', 'Content-Type: application/json',
        base + f'/deployments/{dep_uuid}/cancel'
    ]).decode()
    try:
        return json.loads(out)
    except Exception:
        return {'raw': out[:100]}

ACTIVE = {'running','in_progress','queued','building','started','in-progress','build','deploying'}

apps = get('/applications')
apps = apps if isinstance(apps, list) else apps.get('data', [])
print(f'Scanning {len(apps)} apps...')

total = 0
for app in apps:
    uuid = app.get('uuid', '')
    name = app.get('name', '?')[:35]
    try:
        deploys = get(f'/applications/{uuid}/deployments?per_page=5')
        rows = deploys if isinstance(deploys, list) else deploys.get('data', [])
        for d in rows:
            status = str(d.get('status', '')).lower()
            if status in ACTIVE:
                dep_uuid = d.get('id') or d.get('uuid', '')
                result = post_cancel(dep_uuid)
                msg = result.get('message') or result.get('status') or result.get('error', '?')
                print(f'  CANCEL [{name}] {dep_uuid[:14]} ({status}) → {msg}')
                total += 1
    except Exception as e:
        print(f'  ERR [{name}]: {e}')

print(f'\nCancelled {total} deployments.')
