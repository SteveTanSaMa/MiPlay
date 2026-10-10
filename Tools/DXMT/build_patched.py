#!/usr/bin/env python3
"""Rebuild MiPlay's pinned DXMT + upstream fix, without changing an installed runtime.
Toolchains must already be installed from their official distributions. Output must
be a new directory. Build logs and full debug symbols stay in --work-dir.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

BASE = '654f547ffab4e0c395ee368aad52bb4586b04576'
FIX = 'fb4515681daefb789a4d0f403c4bdbca88f3b3de'
VERSION = '654f547+miplay-fb45156'
FILES = ['d3d10/d3d10core.dll', 'd3d11/d3d11.dll', 'dxgi/dxgi.dll',
         'winemetal/winemetal.dll', 'winemetal/unix/winemetal.so',
         'nvapi/nvapi64.dll', 'nvngx/nvngx.dll']

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['source-repo', 'llvm', 'mingw', 'wine-sdk', 'work-dir', 'output']:
        parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    repo, llvm, mingw, wine, work, output = [p.resolve() for p in
        [args.source_repo, args.llvm, args.mingw, args.wine_sdk, args.work_dir, args.output]]
    if work.exists() or output.exists():
        parser.error('Use new work and output directories; existing assets are never overwritten')
    required = [llvm/'lib/libLLVMCore.a', mingw/'bin/x86_64-w64-mingw32-clang++', wine/'bin/winebuild']
    if not all(p.is_file() for p in required):
        parser.error('Missing LLVM 15 x86_64 static libraries, LLVM-MinGW or Wine SDK')
    work.mkdir(parents=True)
    log = (work/'build.log').open('w')
    def run(command, **kwargs):
        subprocess.run([str(x) for x in command], check=True, stdout=log, stderr=subprocess.STDOUT, **kwargs)
    source, build = work/'source', work/'build'
    run(['git','clone','--no-checkout',repo,source])
    run(['git','-C',source,'checkout','--detach',BASE])
    run(['git','-C',source,'submodule','update','--init','--recursive'])
    patch = Path(__file__).resolve().parent/'patches/fb45156-device-initialization.patch'
    run(['git','-C',source,'apply',patch])
    version = source/'version.h.in'
    version.write_text(version.read_text().replace('@VCS_TAG@', VERSION))
    # Do not let the compiler's bundled libc++.dylib escape into the app assets.
    static = work/'llvm-static'; (static/'lib').mkdir(parents=True)
    (static/'include').symlink_to(llvm/'include')
    for p in (llvm/'lib').glob('libLLVM*.a'): (static/'lib'/p.name).symlink_to(p)
    cross = work/'cross.ini'
    names = {'c':'clang','cpp':'clang++','ar':'ar','strip':'strip','windres':'windres'}
    cross.write_text('[binaries]\n'+'\n'.join(f"{k} = {str(mingw/'bin'/('x86_64-w64-mingw32-'+v))!r}" for k,v in names.items())+
        "\n[properties]\nneeds_exe_wrapper = true\n[host_machine]\nsystem = 'windows'\ncpu_family = 'x86_64'\ncpu = 'x86_64'\nendian = 'little'\n")
    run(['meson','setup',build,source,'--cross-file',cross,'--buildtype=debugoptimized',
         '-Dwine_builtin_dll=true','-Denable_nvapi=true','-Denable_nvngx=true',
         '-Dwine_install_path='+str(wine),'-Dnative_llvm_path='+str(static),
         '-Dbuild.c_args=-mmacosx-version-min=14.0','-Dbuild.cpp_args=-mmacosx-version-min=14.0'])
    run(['meson','compile','-C',build,'-j','4'])
    output.mkdir(parents=True)
    for rel in FILES:
        src=build/'src'/rel; dst=output/src.name; shutil.copy2(src,dst)
        if dst.suffix=='.dll': run([mingw/'bin/x86_64-w64-mingw32-strip','--strip-debug',dst])
        else: run(['xcrun','strip','-S',dst])
    deps=subprocess.check_output(['otool','-L',str(output/'winemetal.so')],text=True)
    for line in deps.splitlines()[1:]:
        dependency=line.strip().split(' (')[0]
        if not dependency.startswith(('/System/Library/','/usr/lib/')) and dependency not in ['@rpath/winemetal.so','@rpath/winemac.so','@rpath/ntdll.so']:
            raise RuntimeError('Nonportable dynamic library dependency: '+dependency)
    commit=subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip()
    metadata={'rendererBuild':VERSION,'upstreamBase':commit,'upstreamFix':FIX,
              'source':'https://github.com/3Shain/dxmt','files':{
                  p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(output.iterdir())}}
    (output/'ASSET_MANIFEST.json').write_text(json.dumps(metadata,indent=2)+'\n')
    (output/'VERSION').write_text(VERSION+'\n')
    print('Built', output, '— game acceptance still required')

if __name__ == '__main__': main()
