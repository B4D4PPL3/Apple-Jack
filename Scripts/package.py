#!/usr/bin/env python3
"""Package a local test DMG or a signed, notarized GitHub release."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
app = root / "build/Apple Jack Public.app"
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())

def run(*args):
    subprocess.run(list(map(str, args)), check=True)

def notarize(upload, staple_target, profile):
    result = subprocess.check_output(["xcrun","notarytool","submit",str(upload),"--keychain-profile",profile,"--wait","--output-format","json"])
    reply = json.loads(result)
    if reply.get("status") != "Accepted":
        raise SystemExit("Notarization failed: " + str(reply))
    run("xcrun","stapler","staple",staple_target)
    run("xcrun","stapler","validate",staple_target)

def verify_app(bundle):
    run("codesign","--verify","--deep","--strict",bundle)
    for path in ("MacOS/AppleJack","Helpers/AppleJackUpdater","Frameworks/MediaRemoteAdapter.framework/MediaRemoteAdapter"):
        slices = subprocess.check_output(["xcrun","lipo","-archs",str(bundle/"Contents"/path)],text=True).split()
        if set(slices) != {"arm64","x86_64"}: raise RuntimeError(f"Incomplete universal binary: {path}")

def package(args):
    version = info["CFBundleShortVersionString"]
    public = bool(args.notary_profile)
    if public and (not args.identity or not info.get("AppleJackGitHubRepository") or not args.notes):
        raise SystemExit("Distribution needs a configured repository, Developer ID Application identity, and release notes.")
    if args.identity and not public:
        raise SystemExit("Supply --notary-profile with --identity for a distribution package.")
    if args.notes and len(args.notes) > 8000:
        raise SystemExit("Release notes must fit in 8000 characters.")
    name = f"Apple-Jack-{version}-macOS.dmg" if public else f"Apple-Jack-{version}-local-macOS.dmg"
    output = root / "dist" / ("release" if public else "local")
    output.mkdir(parents=True,exist_ok=True)
    verify_app(app)
    with tempfile.TemporaryDirectory(dir=output) as temp:
        tmp = Path(temp)
        contents = tmp/"Contents"
        contents.mkdir()
        copy = contents/app.name
        run("ditto",app,copy)
        if public:
            run("codesign","--verify","--strict","--deep","-R=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists",copy)
            archive = tmp/"app.zip"
            run("ditto","-c","-k","--keepParent",copy,archive)
            notarize(archive,copy,args.notary_profile)
        (contents/"Applications").symlink_to("/Applications")
        shutil.copyfile(copy/"Contents/Resources/Setup.html",contents/"Getting Started.html")
        for item in ["LICENSE","ARTWORK.md"]:
            shutil.copyfile(root/item,contents/item)
        shutil.copyfile(root/"ThirdParty/MediaRemoteAdapter/LICENSE",contents/"MediaRemoteAdapter License.txt")
        shutil.copyfile(root/'ThirdParty/Sparkle/LICENSE',contents/'Sparkle License.txt')
        dmg = tmp/name
        run("hdiutil","create","-srcfolder",contents,"-volname","Apple Jack Public","-fs","HFS+","-format","UDZO",dmg)
        if public:
            run("codesign","--force","--timestamp","--sign",args.identity,dmg)
            notarize(dmg,dmg,args.notary_profile)
        run("hdiutil","verify",dmg)
        mount = tmp/"Mounted"
        mount.mkdir()
        run("hdiutil","attach",dmg,"-readonly","-nobrowse","-mountpoint",mount)
        try:
            installed = mount/app.name
            verify_app(installed)
            assert (mount/"Applications").readlink() == Path("/Applications")
            assert (installed/"Contents/Info.plist").read_bytes() == (app/"Contents/Info.plist").read_bytes()
            if public:
                run("spctl","--assess","--type","execute",installed)
        finally:
            run("hdiutil","detach",mount)
        digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
        dmg.replace(output/name)
        (output/(name+".sha256")).write_text(f"{digest}  {name}\n")
        if public:
            release = dict(schemaVersion=1, bundleIdentifier=info["CFBundleIdentifier"],version=version,
                build=int(info["CFBundleVersion"]),minimumSystemVersion=info["LSMinimumSystemVersion"],architecture="universal",
                file=name,sha256=digest,notes=args.notes,channel="stable")
            manifest = tmp/"latest.json"
            manifest.write_text(json.dumps(release,indent=2)+"\n")
            manifest.replace(output/"latest.json")
        print(output/name,flush=True)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--identity",help="Developer ID Application identity used for the build")
    parser.add_argument("--notary-profile",help="Existing notarytool Keychain profile")
    parser.add_argument("--notes",help="Release notes shown in Jack")
    package(parser.parse_args())
