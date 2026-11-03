#!/bin/bash
set -euo pipefail
# Build-time packaging only. Never modify Homebrew originals or download weights.
app="${1:?Usage: setup-intelligence.sh /absolute/path/AxisCopilot.app}"
runtime="${OLLAMA_RUNTIME_ROOT:-/opt/homebrew/opt/ollama/libexec}"
[[ "$app" = /* && -d "$app/Contents/Resources" ]] || { echo "An existing absolute .app path is required" >&2; exit 1; }
[[ -x "$runtime/ollama" && -x "$runtime/lib/ollama/llama-server" ]] || { echo "Complete Ollama runtime not found" >&2; exit 1; }
python3 - "$app" "$runtime" <<'PY'
import os, pathlib, shutil, subprocess, sys
app, runtime = map(pathlib.Path, sys.argv[1:])
runtime = runtime.resolve()
target = app / 'Contents/Resources/Tools/Ollama'
# Rebuild only this generated component. This also removes stale external symlinks.
if target.exists():
    for entry in target.rglob('*'):
        if not entry.is_symlink():
            try: entry.chmod(entry.stat().st_mode | 0o200)
            except OSError: pass
    shutil.rmtree(target)
shutil.copytree(runtime, target, symlinks=False)
source_to_dest = {}
queue = []
license_roots = {runtime.parent}

def output(*args):
    return subprocess.check_output(args, text=True)
def macho(path):
    return 'Mach-O' in output('/usr/bin/file', '-b', str(path))
def register(source, destination):
    source = source.resolve()
    if source not in source_to_dest:
        source_to_dest[source] = destination
        if macho(destination):
            queue.append((source, destination))
            for parent in source.parents:
                if (parent / 'LICENSE').is_file():
                    license_roots.add(parent); break
for source in runtime.rglob('*'):
    if source.is_file(): register(source, target / source.relative_to(runtime))

vendor = target / 'lib/ollama/mlx_metal_v3'
vendor.mkdir(parents=True, exist_ok=True)
notices = target / 'ThirdPartyNotices'
notices.mkdir(exist_ok=True)

def external(source):
    source = source.resolve(strict=True)
    if source in source_to_dest: return source_to_dest[source]
    destination = vendor / source.name
    if destination.exists():
        raise RuntimeError('Vendor basename collision: ' + str(destination))
    shutil.copy2(source, destination)
    destination.chmod(destination.stat().st_mode | 0o200)
    register(source, destination)
    # Metal kernels are a runtime dependency of libmlx, beyond Mach-O linkage.
    if source.name == 'libmlx.dylib':
        kernels = source.parent / 'mlx.metallib'
        if not kernels.is_file(): raise RuntimeError('MLX Metal kernels missing')
        shutil.copy2(kernels, vendor / kernels.name)
    for parent in source.parents:
        if (parent / 'LICENSE').is_file():
            license_roots.add(parent); break
    return destination

def rpaths(source):
    lines = output('/usr/bin/otool', '-l', str(source)).splitlines()
    result = []
    for i, line in enumerate(lines):
        if line.strip() == 'cmd LC_RPATH':
            result.append(lines[i+2].strip().split(' (offset', 1)[0].removeprefix('path '))
    return result

def resolve(load, source):
    if load.startswith('@loader_path/'):
        return (source.parent / load[len('@loader_path/'):]).resolve(strict=True)
    if load.startswith('@executable_path/'):
        return (runtime / load[len('@executable_path/'):]).resolve(strict=True)
    if load.startswith('@rpath/'):
        leaf = load[len('@rpath/'):]
        candidates = [source.parent / leaf]
        for path in rpaths(source):
            path = path.replace('@loader_path', str(source.parent)).replace('@executable_path', str(runtime))
            if not path.startswith('@'): candidates.append(pathlib.Path(path) / leaf)
        for candidate in candidates:
            if candidate.is_file(): return candidate.resolve()
        raise RuntimeError('Unresolved dependency: ' + load + ' in ' + str(source))
    if load.startswith('/'):
        return pathlib.Path(load).resolve(strict=True)
    raise RuntimeError('Unsupported dependency: ' + load)

processed = set()
while queue:
    source, destination = queue.pop(0)
    if source in processed: continue
    processed.add(source)
    destination.chmod(destination.stat().st_mode | 0o200)
    # Read originals before changing any load commands in the generated copy.
    identifiers = output('/usr/bin/otool', '-D', str(source)).splitlines()[1:]
    identifier = identifiers[0].strip() if identifiers else None
    loads = [line.strip().split(' (compatibility', 1)[0] for line in output('/usr/bin/otool', '-L', str(source)).splitlines()[1:]]
    for load in loads:
        if load == identifier or load.startswith('/usr/lib/') or load.startswith('/System/Library/'): continue
        dependency = external(resolve(load, source))
        relative = '@loader_path/' + os.path.relpath(dependency, destination.parent)
        subprocess.run(['/usr/bin/install_name_tool', '-change', load, relative, str(destination)], check=True)
    if identifier:
        subprocess.run(['/usr/bin/install_name_tool', '-id', '@rpath/' + destination.name, str(destination)], check=True)
    # All non-system loads now use @loader_path. Remove unused host rpaths too.
    for path in rpaths(source):
        subprocess.run(['/usr/bin/install_name_tool', '-delete_rpath', path, str(destination)], check=True)

for root in sorted(license_roots):
    label = root.parent.name + '-' + root.name
    for notice in root.glob('LICENSE*'):
        if notice.is_file(): shutil.copy2(notice, notices / (label + '-' + notice.name))

# Verify the complete generated graph, not just regular top-level files.
for path in target.rglob('*'):
    if path.is_symlink(): raise RuntimeError('Symlink remains in runtime: ' + str(path))
    if not path.is_file() or not macho(path): continue
    identifiers = output('/usr/bin/otool', '-D', str(path)).splitlines()[1:]
    identifier = identifiers[0].strip() if identifiers else None
    for line in output('/usr/bin/otool', '-L', str(path)).splitlines()[1:]:
        load = line.strip().split(' (compatibility', 1)[0]
        if load == identifier or load.startswith('/usr/lib/') or load.startswith('/System/Library/'): continue
        if not load.startswith('@loader_path/'): raise RuntimeError('Nonportable dependency: ' + load)
        dependency = (path.parent / load[len('@loader_path/'):]).resolve(strict=True)
        if not dependency.is_relative_to(target.resolve()): raise RuntimeError('Dependency escapes runtime: ' + load)
    if rpaths(path): raise RuntimeError('Unexpected unresolved runtime search path: ' + str(path))
(target / 'MODEL-NOTICE.txt').write_text('Qwen2.5 7B: Apache 2.0. Model downloaded separately by explicit app action.\nhttps://ollama.com/library/qwen2.5:7b/blobs/832dd9e00a68\n')
print('Packaged self-contained Ollama runtime: %d Mach-O files; no symlinks or external non-system loads.' % len(processed))
PY
echo "Sign nested Mach-O files before signing the application."
