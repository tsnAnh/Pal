"""Native metadata and artifact publication use the same verified bytes."""
import hashlib
import copy
import json
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

import hermes_yaml
import pytest

from scripts.bundles.release_artifacts import materialize, record, stamp_matches
from tests.scripts.test_release_r2 import r2_server as r2_server  # noqa: PLC0414 -- the self-alias is load-bearing: it suppresses F811 for the pytest fixture parameter shadowing this import
from tests.scripts.test_stable_release import https_origin as https_origin  # noqa: PLC0414 -- same self-alias, for the https_origin fixture
from tests.scripts.test_release_darwin import _inputs
from scripts.bundles import release_artifacts as artifacts
from scripts.releases import lanes as lane_set

ROOT = Path(__file__).resolve().parents[2]
SMOKE_RESULTS = {name: {'result': 'success'} for name in (
    'smoke-darwin-arm64', 'smoke-win32-arm64', 'smoke-win32-x64')}
RELEASE_EPOCH = 1_787_965_323
WINDOWS_VERSION = '2026.5761.123.0'


def test_windows_metadata_is_read_from_package_and_stale_stamp_is_rejected(tmp_path):
    tag, commit = 'v1.2.3', 'a' * 40
    root = tmp_path / 'release'
    root.mkdir()
    package = root / 'Product-1.2.3-win-x64.msix'
    manifest = '<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"><Identity Name="Product" Publisher="CN=Test" Version="1.2.3.0" ProcessorArchitecture="x64"/><Applications><Application Id="App"/></Applications></Package>'

    def write_package(sha, receiver=None):
        with zipfile.ZipFile(package, 'w') as archive:
            archive.writestr('AppxManifest.xml', manifest)
            archive.writestr('app/resources/install-stamp.json', json.dumps({
                'tag': tag, 'commit': sha, 'baseVersion': tag[1:],
                'receiverProtocol': receiver,
            }))

    write_package(commit)
    out = root / 'metadata-windows-x64.json'
    original = package.read_bytes()
    record('windows', 'x64', root, tag, commit, out)
    metadata = json.loads(out.read_text(encoding='utf-8-sig'))
    assert metadata['identity'] == 'Product'
    assert metadata['version'] == '1.2.3.0'
    assert metadata['publisher'] == 'CN=Test'
    assert metadata['applicationId'] == 'App'
    assert package.read_bytes() == original
    assert 'receiverProtocol' not in metadata
    write_package(commit, receiver=1)
    record('windows', 'x64', root, tag, commit, out)
    assert json.loads(out.read_text())['receiverProtocol'] == 1
    write_package('b' * 40)
    with pytest.raises(ValueError, match='provenance'):
        record('windows', 'x64', root, tag, commit, tmp_path / 'bad.json')
    with pytest.raises(ValueError, match='provenance'):
        stamp_matches({}, tag, commit)


@pytest.fixture
def staged_candidate(tmp_path, r2_server, https_origin):
    from scripts.bundles.release_artifacts import assemble
    from scripts.releases import handoff

    tag, commit, base = 'v1.2.3', 'a' * 40, https_origin.base
    attempt = 'rc.2-v1.2.3'
    https_origin.store = r2_server.store
    legs, mac_bytes = _inputs('1.2.3')
    built = tmp_path / 'built'
    built.mkdir()
    for platform, arches in [('windows', ('x64', 'arm64')), ('macos', ('arm64',)), ('termux', ('aarch64',))]:
        for arch in arches:
            row = {
                # Exactly the keys record() writes: a row is metadata, not a stamp (no baseVersion).
                'platform': platform, 'arch': arch, 'tag': tag, 'commit': commit,
                'identity': 'Product',
            }
            if platform == 'windows':
                row.update(version=WINDOWS_VERSION, executableVersion=WINDOWS_VERSION,
                           publisher='CN=Test', applicationId='App')
                package = f'HermesBundled-1.2.3-win-{arch}.msix'
                handoff_name = f'win32-{arch}'
            elif platform == 'macos':
                package = f'HermesBundled-1.2.3-mac-{arch}.zip'
                row.update(version='1.2.3', teamId='ABCDEFGHIJ', filename=package)
                handoff_name = f'darwin-{arch}'
            else:
                package = 'deb/product.deb'
                row.update(version='1.2.3-1', filename=package)
                handoff_name = 'termux'
            file = built / package
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(mac_bytes.get(f'releases/tag/{tag}/{package}', b'package transport fixture'))
            metadata = built / f'metadata-{platform}-{arch}.json'
            metadata.write_text(json.dumps(row), encoding='utf-8')
            includes = [package, metadata.name]
            if platform == 'macos':
                feed = f'{arch}-stable-mac.yml'
                (built / feed).write_text(legs[feed], encoding='utf-8')
                includes.append(feed)
            if platform == 'termux':
                for name in ('pool/package.deb', 'dists/hermes-stable/InRelease', 'dists/hermes-stable/Release'):
                    path = built / 'apt' / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(f'index transport fixture: {name}'.encode())
                includes.append('apt/**/*')
            handoff.stage(attempt, commit, handoff_name, built, includes)
    bundle = built / 'Product-win.msixbundle'
    with zipfile.ZipFile(bundle, 'w') as archive:
        archive.writestr('AppxMetadata/AppxBundleManifest.xml', f'<Bundle><Identity Name="Product" Publisher="CN=Test" Version="{WINDOWS_VERSION}"/><Packages><Package Type="application" Architecture="arm64"/><Package Type="application" Architecture="x64"/></Packages></Bundle>')
    (built / 'Store-Product-win.msixbundle').write_bytes(b'Store bundle transport fixture')
    handoff.stage(attempt, commit, 'windows-universal', built, ['*.msixbundle'])
    fetched = tmp_path / 'fetched'
    names = ['win32-x64', 'win32-arm64', 'darwin-arm64', 'termux', 'windows-universal']
    handoff.fetch(attempt, commit, names, fetched, ['metadata-*.json', '*.msixbundle'])
    r2_server.requests.clear()
    manifest = assemble(fetched, tag, commit, base, tmp_path / 'release-candidates.json',
                        smoke_results=SMOKE_RESULTS, release_epoch=RELEASE_EPOCH, archive=attempt,
                        lanes=lane_set.NAMES)
    assert manifest['archive'] == attempt and manifest['tag'] == tag
    assert {row['platform'] + '/' + row['arch'] for row in manifest['packages']} == {
        'windows/x64', 'windows/arm64', 'macos/arm64', 'termux/aarch64'}
    assert all(not file['path'].startswith(('handoff-', 'metadata-')) for file in manifest['files'])
    assert all(file['url'].startswith(f'{base}/releases/tag/{attempt}/') for file in manifest['files'])
    puts = [path for method, path, _ in r2_server.requests if method == 'PUT']
    assert puts == [f'/hermes-releases/releases/tag/{attempt}/release-candidates.json']
    assert all(key.startswith(f'releases/tag/{attempt}/') for key in r2_server.store)
    assert not any(key.startswith(f'releases/tag/{tag}/') for key in r2_server.store)
    return manifest, fetched, base


def test_bootstrap_reuses_published_candidate_and_rejects_substitution(staged_candidate, r2_server, monkeypatch):
    from scripts.releases import channel_releases
    candidate, _, base = staged_candidate
    request = {'releaseTag': candidate['tag'], 'commit': candidate['commit'], 'publicBase': base,
               'identity': {'token': 'a' * 16, 'appNamePascal': 'App'}}
    packages = []
    for row in candidate['packages']:
        if row['platform'] == 'termux':
            continue
        packages.append({**row, 'platform': 'darwin' if row['platform'] == 'macos' else 'win32',
                         'artifact': {'key': row['artifact']['url'].removeprefix(base + '/'),
                                      'sha256': row['artifact']['sha256']}})
    manifest = {'request': request, 'packages': packages}
    monkeypatch.setattr(channel_releases, 'product_identity', lambda tag: request['identity'])
    published = {'draft': False, 'prerelease': False, 'published_at': 'fixture-published'}
    monkeypatch.setattr(channel_releases.stable, 'output', lambda args: candidate['commit']
                        if '/commits/' in args[2] else json.dumps(published))
    r2_server.store['releases/stable/release-candidates.json'] = r2_server.store[f"releases/tag/{candidate['archive']}/release-candidates.json"]
    assert channel_releases.verify_bootstrap(request, manifest, base, 'fixture/repo')
    substituted = copy.deepcopy(manifest)
    substituted['packages'][0]['artifact']['sha256'] = 'f' * 64
    with pytest.raises(ValueError, match='accepted'):
        channel_releases.verify_bootstrap(request, substituted, base, 'fixture/repo')
    published['draft'] = True
    with pytest.raises(ValueError, match='published'):
        channel_releases.verify_bootstrap(request, manifest, base, 'fixture/repo')


def test_assemble_rejects_missing_and_changed_receipts(tmp_path, staged_candidate):
    from scripts.bundles.release_artifacts import assemble

    manifest, fetched, base = staged_candidate
    tag, commit = manifest['tag'], manifest['commit']
    receipt = fetched / 'handoff-darwin-arm64.json'
    original = receipt.read_bytes()
    receipt.unlink()
    with pytest.raises(ValueError, match='handoff'):
        assemble(fetched, tag, commit, base, tmp_path / 'missing.json',
                 smoke_results=SMOKE_RESULTS, release_epoch=RELEASE_EPOCH, archive=manifest['archive'],
                 lanes=lane_set.NAMES)
    receipt.write_bytes(original)
    (fetched / 'metadata-windows-x64.json').write_text('{}', encoding='utf-8')
    with pytest.raises(ValueError, match='digest'):
        assemble(fetched, tag, commit, base, tmp_path / 'changed.json',
                 smoke_results=SMOKE_RESULTS, release_epoch=RELEASE_EPOCH, archive=manifest['archive'],
                 lanes=lane_set.NAMES)


def test_publish_rejects_a_universal_bundle_whose_identity_differs_from_its_packages(
        tmp_path, r2_server, staged_candidate):
    """Candidate staging binds the bundle by digest only; publish opens it before anything goes live."""
    manifest, _, base = staged_candidate
    key = f"releases/tag/{manifest['archive']}/Product-win.msixbundle"
    forged = tmp_path / 'forged.msixbundle'
    with zipfile.ZipFile(forged, 'w') as archive:
        archive.writestr('AppxMetadata/AppxBundleManifest.xml', f'<Bundle><Identity Name="Other" Publisher="CN=Test" Version="{WINDOWS_VERSION}"/><Packages><Package Type="application" Architecture="arm64"/><Package Type="application" Architecture="x64"/></Packages></Bundle>')
    body = forged.read_bytes()
    r2_server.store[key] = (body, *r2_server.store[key][1:])
    tampered = copy.deepcopy(manifest)
    digest = hashlib.sha256(body).hexdigest()
    for item in tampered['files']:
        if item['path'] == 'Product-win.msixbundle':
            item['sha256'], item['size'] = digest, len(body)
    for row in tampered['packages']:
        if row['platform'] == 'windows':
            row['artifact']['sha256'] = digest
    r2_server.requests.clear()
    with pytest.raises(ValueError, match='Universal bundle identity'):
        artifacts.publish(tampered, tmp_path / 'publish', base)
    assert not [path for method, path, _ in r2_server.requests if method == 'PUT']


def test_candidate_publication_and_store_selection(tmp_path, monkeypatch, r2_server, staged_candidate):
    manifest, _, base = staged_candidate
    tag, commit = manifest['tag'], manifest['commit']
    raw = r2_server.store[f"releases/tag/{manifest['archive']}/release-candidates.json"][0]
    args = ['--tag', tag, '--archive', manifest['archive'], '--commit', commit, '--public-base', base]
    monkeypatch.setenv('CANDIDATE_MANIFEST_SHA256', hashlib.sha256(raw).hexdigest())
    artifacts.main(['materialize', *args, '--root', str(tmp_path / 'store'), '--store-only'])
    assert [p.name for p in (tmp_path / 'store').iterdir()] == ['Store-Product-win.msixbundle']
    assert (tmp_path / 'store/Store-Product-win.msixbundle').read_bytes() == b'Store bundle transport fixture'
    monkeypatch.setenv('CANDIDATE_MANIFEST_SHA256', 'f' * 64)
    with pytest.raises(ValueError, match='digest mismatch'):
        artifacts.main(['materialize', *args, '--root', str(tmp_path / 'wrong')])
    assert not (tmp_path / 'wrong').exists()
    missing = copy.deepcopy(manifest)
    missing['files'] = [f for f in missing['files'] if not f['path'].startswith('Store-')]
    with pytest.raises(ValueError, match='one Store candidate'):
        materialize(missing, tmp_path / 'missing-store', public_base=base, store_only=True)
    changed = copy.deepcopy(manifest)
    changed['files'][0]['sha256'] = 'b' * 64
    with pytest.raises(ValueError, match='receipts differ'):
        materialize(changed, tmp_path / 'bad', public_base=base)

    r2_server.requests.clear()
    artifacts.publish(manifest, tmp_path / 'publish', base)
    assert [path for method, path, _ in r2_server.requests if method == 'PUT'] == [
        '/hermes-releases/releases/termux/stable/pool/package.deb']
    r2_server.requests.clear()
    artifacts.promote(manifest, tmp_path / 'promote', base)
    puts = [path for method, path, _ in r2_server.requests if method == 'PUT']
    assert puts == ['/hermes-releases/' + name for name in (
        'releases/darwin/stable/stable-mac.yml', 'releases/win32/stable/stable.appinstaller',
        'releases/termux/stable/dists/hermes-stable/Release', 'releases/termux/stable/dists/hermes-stable/InRelease')]
    # Promotion materializes only feed legs and indexes; packages stay receipt-bound on R2.
    for item in manifest['files']:
        local = tmp_path / 'promote' / item['path']
        if item['path'].endswith(artifacts.PACKAGE_SUFFIXES):
            assert not local.exists(), item['path']
        else:
            assert local.read_bytes() == r2_server.store[f"releases/tag/{manifest['archive']}/{item['path']}"][0]
    descriptor = ET.fromstring(r2_server.store['releases/win32/stable/stable.appinstaller'][0])
    assert descriptor.attrib == {
        'Uri': base + '/releases/win32/stable/stable.appinstaller',
        'Version': WINDOWS_VERSION,
    }
    assert descriptor.find('{*}MainBundle').attrib == {
        'Name': 'Product', 'Publisher': 'CN=Test', 'Version': WINDOWS_VERSION,
        'Uri': base + f"/releases/tag/{manifest['archive']}/Product-win.msixbundle"}
    pointer = 'releases/win32/stable/stable.appinstaller'
    original = r2_server.store[pointer]
    r2_server.corrupt_put = pointer
    r2_server.requests.clear()
    with pytest.raises(ValueError, match='Channel read-back differs'):
        artifacts.promote(manifest, tmp_path / 'bad-readback', base)
    assert [path for method, path, _ in r2_server.requests if method == 'PUT'] == ['/hermes-releases/' + pointer]
    r2_server.corrupt_put = None
    r2_server.store[pointer] = original
    before = dict(r2_server.store)
    # Packages are receipt-bound and never re-downloaded here; a corrupt file that
    # promotion does materialize (a feed leg) is still refused before any write.
    r2_server.store[f"releases/tag/{manifest['archive']}/arm64-stable-mac.yml"] = (b'corrupt', '"e"')
    r2_server.requests.clear()
    with pytest.raises(ValueError, match='digest mismatch'):
        artifacts.promote(manifest, tmp_path / 'broken', base)
    assert not any(method == 'PUT' for method, _, _ in r2_server.requests)
    assert all(value == r2_server.store[key] for key, value in before.items() if not key.startswith('releases/tag/'))


def test_promote_writes_the_stable_mac_feed_from_the_attempt_archive(tmp_path, monkeypatch, r2_server, https_origin, staged_candidate):
    import urllib.request

    manifest, _, base = staged_candidate
    # urlopen caches one global opener; use the fixture's per-test context so
    # this test is order-independent against the per-test self-signed CA.
    monkeypatch.setattr(urllib.request, 'urlopen', https_origin.opener)
    artifacts.promote(manifest, tmp_path / 'promote', base)
    feed = hermes_yaml.safe_load(r2_server.store['releases/darwin/stable/stable-mac.yml'][0].decode())
    # The feed version is the plain package version, never the attempt ref.
    assert feed['version'] == '1.2.3'
    assert feed['version'] != manifest['archive']
    urls = [entry['url'] for entry in feed['files']]
    assert urls and all(url.startswith(f"/releases/tag/{manifest['archive']}/") for url in urls)
    assert f"/releases/tag/{manifest['archive']}/HermesBundled-1.2.3-mac-arm64.zip" in urls
    assert not any('-mac-x64' in url for url in urls)

    # A release that did not opt into Termux promotes the Mac feed and leaves
    # the APT channel untouched.
    default = copy.deepcopy(manifest)
    default['packages'] = [row for row in default['packages'] if row['platform'] != 'termux']
    default['files'] = [f for f in default['files'] if not f['path'].startswith(('apt/', 'deb/'))]
    del r2_server.store['releases/darwin/stable/stable-mac.yml']
    r2_server.requests.clear()
    artifacts.promote(default, tmp_path / 'promote-default', base)
    puts = [path for method, path, _ in r2_server.requests if method == 'PUT']
    assert puts == ['/hermes-releases/releases/darwin/stable/stable-mac.yml',
                    '/hermes-releases/releases/win32/stable/stable.appinstaller']
    feed = hermes_yaml.safe_load(r2_server.store['releases/darwin/stable/stable-mac.yml'][0].decode())
    assert [entry['url'].rsplit('/', 1)[1] for entry in feed['files']] == ['HermesBundled-1.2.3-mac-arm64.zip']


def test_promote_refuses_when_the_macos_feed_is_missing(tmp_path, monkeypatch, r2_server, https_origin, staged_candidate):
    import urllib.request

    manifest, _, base = staged_candidate
    monkeypatch.setattr(urllib.request, 'urlopen', https_origin.opener)
    broken = copy.deepcopy(manifest)
    broken['files'] = [f for f in broken['files'] if f['path'] != 'arm64-stable-mac.yml']
    r2_server.requests.clear()
    with pytest.raises(ValueError, match='one ARM64 macOS feed'):
        artifacts.promote(broken, tmp_path / 'broken-arch', base)
    # The refusal happens before any channel pointer moves.
    assert not [path for method, path, _ in r2_server.requests
                if method == 'PUT' and '/releases/win32/stable/' in path]
