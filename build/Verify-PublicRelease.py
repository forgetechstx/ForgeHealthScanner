"""Download public release without authentication and verify exact published bytes."""
from pathlib import Path
import hashlib
import io
import json
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
BASE = 'https://github.com/forgetechstx/ForgeHealthScanner'
HOME = 'https://forgetechstx.github.io/ForgeHealthScanner/'
VERSION = '1.6.0'
STEM = f'ForgeHealthScanner-{VERSION}-portable-unsigned'

def get(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'ForgeHealthScanner-release-verification'})
    with urllib.request.urlopen(request, timeout=90) as response:
        if response.status != 200:
            raise ValueError(f'Expected HTTP 200: {url}')
        data = response.read()
        print(f'HTTP 200 {url}')
        return data

for url in [BASE, BASE + '/releases/tag/v' + VERSION, BASE + '/actions',
            BASE + '/blob/main/LICENSE', BASE + '/blob/main/CODE-SIGNING.md',
            BASE + '/blob/main/docs/SIGNPATH-APPLICATION.md', HOME]:
    get(url)

manifest = json.loads((ROOT / 'site/site-sha256.json').read_bytes())
for name, expected in manifest.items():
    actual = get(HOME + name)
    if hashlib.sha256(actual).hexdigest() != expected:
        raise ValueError(f'Deployed website bytes differ: {name}')
if json.loads(get(HOME + 'site-sha256.json')) != manifest:
    raise ValueError('Deployed website manifest differs')

download = BASE + '/releases/download/v' + VERSION + '/'
checksums = get(download + 'SHA256SUMS.txt').decode('utf-8-sig')
files = {}
expected_names = {STEM + suffix for suffix in ['.zip', '.cdx.json', '.manifest.json']}
for line in checksums.splitlines():
    expected, name = line.split('  ', 1)
    if name not in expected_names or name in files:
        raise ValueError('Unexpected or duplicate checksum filename')
    content = get(download + name)
    if hashlib.sha256(content).hexdigest() != expected:
        raise ValueError(f'Release download checksum mismatch: {name}')
    files[name] = content
if set(files) != expected_names:
    raise ValueError('Missing checksummed assets')
with zipfile.ZipFile(io.BytesIO(files[STEM + '.zip'])) as package:
    expected = {'HealthScan.exe', 'README.md', 'README.txt', 'LICENSE', 'PRIVACY.md',
                'CODE-SIGNING.md', 'THIRD-PARTY-NOTICES.md'}
    if len(package.namelist()) != len(expected) or set(package.namelist()) != expected:
        raise ValueError('Unexpected package contents')
    executable = package.read('HealthScan.exe')
exe_hash = hashlib.sha256(executable).hexdigest()
build = json.loads(files[STEM + '.manifest.json'])
bom = json.loads(files[STEM + '.cdx.json'])
if build['executableSHA256'] != exe_hash or build['signature'] != 'unsigned' or build['version'] != VERSION:
    raise ValueError('Downloaded EXE does not match build manifest')
if bom['metadata']['component']['hashes'][0]['content'] != exe_hash:
    raise ValueError('Downloaded EXE does not match SBOM')
output = ROOT / 'dist/public-verification'
output.mkdir(parents=True, exist_ok=True)
for name, content in files.items():
    (output / name).write_bytes(content)
(output / 'HealthScan.exe').write_bytes(executable)
(output / 'SHA256SUMS.txt').write_text(checksums, encoding='utf-8')
print('PASS public HTTP 200, exact deployed website bytes, downloaded checksums, package and executable/SBOM hashes')
print('Source revision: ' + build['sourceRevision'])
