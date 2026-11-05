#!/usr/bin/env python3
"""Package this workspace's LSFG fork and an explicit MoltenVK generator.

Never copies commercial shaders, modifies Wine, or downloads executables.
Run the fork's Scripts/package-miplay.sh first after changing Rust sources.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    app = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fork', type=Path, default=app.parent / 'MiPlay LSFG')
    parser.add_argument('--driver', type=Path)
    parser.add_argument('--driver-license', type=Path)
    parser.add_argument('--output', type=Path, default=app / 'RuntimeAssets/lsfg')
    args = parser.parse_args()
    fork = args.fork.resolve()
    driver = (args.driver or fork / 'target/qa/driver/libMoltenVK.1.4.2.real.dylib').resolve()
    package = fork / 'dist/miplay/lsfg'
    metadata = json.loads((package / 'component.json').read_text())
    if metadata['fault_injection'] or metadata['commercial_shaders_included']:
        raise SystemExit('Refusing test-only or commercial content')
    names = ['liblsfg_metal.dylib', 'preflight', 'shader-check']
    for name in names:
        if sha(package / name) != metadata['sha256'][name]:
            raise SystemExit(f'Stale component manifest: {name}')
        subprocess.run(['codesign', '--verify', '--strict', str(package / name)], check=True)
        subprocess.run(['lipo', '-verify_arch', 'x86_64', str(package / name)], check=True)
    # The baseline generator is deliberately pinned, independently of Wine's driver.
    driver_hash = 'aef00b13bcc808adf15b85bef9ae67393d92be7ed5dfe41cad16fa809e4a4c5f'
    if sha(driver) != driver_hash:
        raise SystemExit('Expected the verified official MoltenVK 1.4.2 universal driver')
    license_path = (args.driver_license or fork / 'target/qa/mvk142/MoltenVK/LICENSE').resolve()
    if not license_path.is_file():
        raise SystemExit('Supply the official MoltenVK license with --driver-license')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.lsfg-stage-', dir=args.output.parent) as temp:
        staging = Path(temp)
        for name in names:
            shutil.copy2(package / name, staging / name)
        shutil.copy2(package / 'LICENSE', staging / 'LSFG-LICENSE')
        shutil.copy2(driver, staging / 'libMoltenVK.generator.dylib')
        shutil.copy2(license_path, staging / 'MoltenVK-LICENSE')
        files = names + ['libMoltenVK.generator.dylib']
        manifest = {
            'schema': 1,
            'upstream': metadata['upstream'],
            'upstream_baseline': metadata['upstream_baseline'],
            'component': metadata,
            'generator_version': '1.4.2',
            'generator_source': 'https://github.com/KhronosGroup/MoltenVK/releases/tag/v1.4.2',
            'commercial_shaders_included': False,
            'sha256': {name: sha(staging / name) for name in files},
        }
        (staging / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        args.output.mkdir(parents=True, exist_ok=True)
        for file in staging.iterdir():
            shutil.copy2(file, args.output / file.name)
    print(f'Packaged LSFG code and generator driver: {args.output}')


if __name__ == '__main__':
    main()
