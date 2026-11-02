#!/bin/bash
# Explicit public model download only. Application inference never downloads.
set -euo pipefail
model_dir="${AXIS_SPEAKER_MODELS:-$HOME/Library/Application Support/AxisCopilot/SpeakerModels}"
python3 - "$model_dir" <<'PY'
import hashlib, json, pathlib, sys, urllib.request
revision = '7eab74f3463c736418d0eb10296261ae581146c9'
base = 'https://huggingface.co/FluidInference/speaker-diarization-coreml'
root = pathlib.Path(sys.argv[1]).expanduser()
root.mkdir(parents=True, exist_ok=True, mode=0o700)
files = json.load(urllib.request.urlopen(f'https://huggingface.co/api/models/FluidInference/speaker-diarization-coreml/tree/{revision}?recursive=true&limit=1000'))
wanted = [f for f in files if f['type'] == 'file' and (f['path'].startswith(('pyannote_segmentation.mlmodelc/', 'wespeaker_v2.mlmodelc/')) or f['path'] in ('NOTICE.md', 'LICENSE', 'README.md'))]
if len([f for f in wanted if f['path'].endswith('/weights/weight.bin')]) != 2:
    raise SystemExit('Incomplete pinned model listing')
for f in wanted:
    destination = root / f['path']
    destination.parent.mkdir(parents=True, exist_ok=True)
    expected = f.get('lfs', {}).get('oid')
    if destination.exists() and expected and hashlib.sha256(destination.read_bytes()).hexdigest() == expected:
        continue
    temporary = destination.with_name(destination.name + '.download')
    with urllib.request.urlopen(f"{base}/resolve/{revision}/{f['path']}") as response, temporary.open('wb') as output:
        while chunk := response.read(1024 * 1024): output.write(chunk)
    if temporary.stat().st_size != f['size']:
        temporary.unlink(); raise SystemExit('Model size mismatch: ' + f['path'])
    if expected and hashlib.sha256(temporary.read_bytes()).hexdigest() != expected:
        temporary.unlink(); raise SystemExit('Model hash mismatch: ' + f['path'])
    temporary.replace(destination)
sdk_license = urllib.request.urlopen('https://raw.githubusercontent.com/FluidInference/FluidAudio/9830ce835881c0d0d40f90aabfaae3a6da5bebfb/LICENSE').read()
(root / 'FluidAudio-LICENSE.txt').write_bytes(sdk_license)
(root / 'REVISION').write_text(revision + '\n')
(root / 'ATTRIBUTION.txt').write_text('FluidAudio 0.12.4, Apache-2.0. Local Core ML conversions by Fluid Inference.\nSegmentation: pyannote/segmentation-3.0, Copyright 2023 CNRS, MIT.\nEmbedding: WeSpeaker and pyannote/wespeaker-voxceleb-resnet34-LM, CC-BY-4.0.\nModified Core ML conversions, embedding palettized to 8 bits.\nhttps://creativecommons.org/licenses/by/4.0/\nhttps://huggingface.co/FluidInference/speaker-diarization-coreml\nSee NOTICE.md for upstream MIT notice and exact revisions.\n')
print('Local speaker models ready:', root)
PY
