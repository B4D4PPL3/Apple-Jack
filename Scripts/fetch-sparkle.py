#!/usr/bin/env python3
"""Fetch the pinned official Sparkle distribution; keep binaries out of git."""
from pathlib import Path
import hashlib, shutil, subprocess, tempfile, urllib.request

root = Path(__file__).resolve().parents[1]
destination = root / 'ThirdParty/Sparkle'
version = '2.10.1'
digest = '1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27'

def fetch():
    if (destination/'Sparkle.framework').exists() and (destination/'bin/sign_update').exists():
        subprocess.run(['codesign','--verify','--deep','--strict',str(destination/'Sparkle.framework')],check=True)
        return
    destination.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='sparkle-',dir=destination) as temporary:
        folder = Path(temporary)
        archive = folder/'Sparkle.tar.xz'
        request = urllib.request.Request(f'https://github.com/sparkle-project/Sparkle/releases/download/{version}/Sparkle-{version}.tar.xz',headers={'User-Agent':'Apple-Jack-Build'})
        with urllib.request.urlopen(request,timeout=60) as response, archive.open('wb') as output:
            count = 0
            while True:
                data = response.read(1048576)
                if not data: break
                count += len(data)
                if count > 100 * 1024 * 1024: raise RuntimeError('Unexpected Sparkle archive size')
                output.write(data)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
            raise RuntimeError('Sparkle archive checksum does not match the pinned release')
        # Only the exact official archive above is extracted.
        extracted = folder/'distribution'
        extracted.mkdir()
        subprocess.run(['tar','-xJf',str(archive),'-C',str(extracted)],check=True)
        for name in ['Sparkle.framework','bin']:
            target=destination/name
            if target.exists(): shutil.rmtree(target)
            shutil.copytree(extracted/name,target,symlinks=True)
        subprocess.run(['codesign','--verify','--deep','--strict',str(destination/'Sparkle.framework')],check=True)

if __name__ == '__main__': fetch()
