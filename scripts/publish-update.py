#!/usr/bin/env python3
"""Create an immutable signed update archive and atomically switch a local feed.

No network calls, signing or key export. Upload archive first, manifest last.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import tempfile
from urllib.parse import urlsplit, urlunsplit
import zipfile


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, timeout=120).stdout


def publish(app, output, feed_url):
    origin = urlsplit(feed_url)
    if origin.scheme != 'https' or not origin.hostname or origin.username or origin.password or origin.query or origin.fragment or not origin.path.endswith('.json'):
        raise ValueError('feed URL must be an absolute HTTPS .json URL without credentials/query/fragment')
    if app.name != 'AxisCopilot.app' or app.is_symlink():
        raise ValueError('Expected a real AxisCopilot.app directory')
    with (app / 'Contents/Info.plist').open('rb') as f:
        info = plistlib.load(f)
    if info.get('CFBundleIdentifier') != 'ru.axisconsult.SalesCopilot' or info.get('CFBundleExecutable') != 'AxisCopilot':
        raise ValueError('Wrong bundle identifier/executable')
    build = info['CFBundleVersion']
    minimum = info['LSMinimumSystemVersion']
    for value in (build, minimum):
        if not isinstance(value, str) or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,3}', value):
            raise ValueError('Build and minimum OS must be numeric dotted versions')
    if info.get('AxisUpdateFeedURL') != feed_url:
        raise ValueError('Signed bundle AxisUpdateFeedURL must match --feed-url; configure before signing')
    resources = app / 'Contents/Resources'
    required = [resources / 'Tools/whisper-cli', resources / 'Tools/AxisUpdater', resources / 'Models/ggml-small.bin', resources / 'SpeakerModels']
    if any(not item.exists() or item.is_symlink() for item in required):
        raise ValueError('Publish the portable employee app with bundled whisper-cli, Small and speaker models')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))
    if 'arm64' not in run('/usr/bin/lipo', '-archs', str(app / 'Contents/MacOS/AxisCopilot')).decode().split():
        raise ValueError('Missing arm64 executable')
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.axis-publish-', dir=output) as temp:
        temp = Path(temp)
        # A certificate must exist: ad-hoc signatures are never publishable.
        cert = temp / 'app-cert-'
        helper_cert = temp / 'helper-cert-'
        run('/usr/bin/codesign', '-d', '--extract-certificates=' + str(cert), str(app))
        helper = app / 'Contents/Resources/Tools/AxisUpdater'
        run('/usr/bin/codesign', '--verify', '--strict', str(helper))
        run('/usr/bin/codesign', '-d', '--extract-certificates=' + str(helper_cert), str(helper))
        if not Path(str(cert) + '0').is_file() or Path(str(cert) + '0').read_bytes() != Path(str(helper_cert) + '0').read_bytes():
            raise ValueError('App and helper must use the same permanent signing certificate')
        archive_name = f'AxisCopilot-{build}-arm64.zip'
        archive = temp / archive_name
        total = 0
        with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=False) as zip_out:
            for source in [app] + sorted(app.rglob('*')):
                mode = source.lstat().st_mode
                if not stat.S_ISREG(mode) and not stat.S_ISDIR(mode):
                    raise ValueError(f'Links/special files are not allowed in updates: {source.relative_to(app.parent)}')
                relative = source.relative_to(app.parent).as_posix()
                if '\\' in relative or any(ord(c) < 32 for c in relative):
                    raise ValueError('Unsafe filename')
                if source.is_file():
                    total += source.stat().st_size
                if total > 4_000_000_000:
                    raise ValueError('Expanded archive exceeds 4 GB')
                zip_out.write(source, relative)
        size = archive.stat().st_size
        if size > 2_000_000_000:
            raise ValueError('Archive exceeds 2 GB')
        with archive.open('rb') as archive_stream:
            digest = hashlib.file_digest(archive_stream, 'sha256').hexdigest()
        archive_url = urlunsplit((origin.scheme, origin.netloc, origin.path.rsplit('/', 1)[0] + '/' + archive_name, '', ''))
        manifest = dict(schema=1, version=info['CFBundleShortVersionString'], build=build, architecture='arm64', minimumOS=minimum, url=archive_url, sha256=digest, size=size)
        destination = output / archive_name
        if destination.exists():
            with destination.open('rb') as existing:
                if hashlib.file_digest(existing, 'sha256').hexdigest() != digest:
                    raise ValueError('Archive name already exists with different contents; increment CFBundleVersion')
        else:
            os.replace(archive, destination)
        staged_feed = temp / 'manifest.json'
        staged_feed.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
        os.replace(staged_feed, output / Path(origin.path).name)
        print(f'Prepared {archive_name} and {Path(origin.path).name}; no network deployment performed')


def bump_version(plist_path, component):
    with plist_path.open('rb') as source:
        info = plistlib.load(source)
    version = info.get('CFBundleShortVersionString', '')
    build = info.get('CFBundleVersion', '')
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version) or not isinstance(build, str) or not build.isdecimal():
        raise ValueError('Expected numeric major.minor.patch and integer CFBundleVersion')
    numbers = [int(value) for value in version.split('.')]
    index = {'major': 0, 'minor': 1, 'patch': 2}[component]
    numbers[index] += 1
    for following in range(index + 1, 3):
        numbers[following] = 0
    info['CFBundleShortVersionString'] = '.'.join(map(str, numbers))
    info['CFBundleVersion'] = str(int(build) + 1)
    with tempfile.NamedTemporaryFile(dir=plist_path.parent, prefix='.version-', delete=False) as staged:
        staged.write(plistlib.dumps(info))
        temporary = Path(staged.name)
    try:
        os.chmod(temporary, plist_path.stat().st_mode & 0o777)
        os.replace(temporary, plist_path)
    finally:
        temporary.unlink(missing_ok=True)
    print(f"Version {version} ({build}) -> {info['CFBundleShortVersionString']} ({info['CFBundleVersion']})")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path, nargs='?')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--feed-url')
    parser.add_argument('--bump', choices=['patch', 'minor', 'major'])
    parser.add_argument('--plist', type=Path, default=Path(__file__).resolve().parent.parent / 'Resources/Info.plist')
    args = parser.parse_args()
    if args.bump:
        if args.app or args.output or args.feed_url:
            parser.error('--bump is a separate source versioning step before build/sign')
        bump_version(args.plist, args.bump)
    else:
        if not args.app or not args.output or not args.feed_url:
            parser.error('publish requires app, --output and --feed-url')
        publish(args.app.resolve() if not args.app.is_symlink() else args.app, args.output.resolve(), args.feed_url)


if __name__ == '__main__':
    main()
