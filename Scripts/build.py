#!/usr/bin/env python3
"""Build the public universal app from this checkout using Apple's command line tools."""
import argparse
from base64 import b64encode
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = root / "Sources"
resources = root / "Resources"
upstream = root / "ThirdParty/MediaRemoteAdapter"
architectures = ("arm64", "x86_64")

def run(*command):
    subprocess.run([str(arg) for arg in command], check=True)

def build(output, identity, repository):
    run('python3', root/'Scripts/fetch-sparkle.py')
    sparkle = root/'ThirdParty/Sparkle'
    info = plistlib.loads((resources / "Info.plist").read_bytes())
    if repository:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*", repository):
            raise ValueError("Use a GitHub repository in owner/name format")
        info["AppleJackGitHubRepository"] = repository
        info['SUFeedURL'] = f'https://raw.githubusercontent.com/{repository}/main/Updates/appcast.xml'
    if identity != "-" and (not repository or not identity.startswith("Developer ID Application: ")):
        raise ValueError("Supply the repository and a Developer ID Application identity for distribution")
    output.mkdir(parents=True, exist_ok=True)
    # Stage away from the final bundle so failed builds leave a usable previous build.
    with tempfile.TemporaryDirectory(dir=output) as temporary:
        tmp = Path(temporary)
        app = tmp / "Apple Jack Public.app"
        contents = app / "Contents"
        framework = contents / "Frameworks/MediaRemoteAdapter.framework"
        version = framework / "Versions/A"
        for folder in [contents/"MacOS", contents/"Helpers", contents/"Resources", version/"Resources"]:
            folder.mkdir(parents=True)
        (contents/"Info.plist").write_bytes(plistlib.dumps(info))
        core = sorted(source.glob("*.swift"))
        helper = [source / s for s in ("Updater/main.swift","UpdateInstallation.swift","UpdateRelease.swift","ProcessExitMonitor.swift")]
        adapter = [upstream/"src"/(p+".m") for p in (
            "adapter/env","adapter/get","adapter/globals","adapter/keys","adapter/now_playing","adapter/stream","adapter/send",
            "private/MediaRemote","utility/Debounce","utility/helpers")]
        adapter += [source/"MediaPlayerCatalog.m", source/"NowPlayingParentMonitor.m"]
        for arch in architectures:
            target = arch + "-apple-macos13.0"
            flags = ["xcrun","swiftc","-O","-swift-version","5","-target",target,"-module-cache-path",output/"modules",
                     "-file-prefix-map",str(root)+"=."]
            run(*flags,'-F',sparkle,'-framework','Sparkle','-Xlinker','-rpath','-Xlinker','@executable_path/../Frameworks',*core,"-o",tmp/("jack-"+arch))
            run(*flags,"-parse-as-library",*helper,"-o",tmp/("updater-"+arch))
            run("xcrun","clang","-dynamiclib","-target",target,"-O2","-fobjc-arc",
                "-ffile-prefix-map="+str(root)+"=.","-Werror=unguarded-availability-new",
                "-I"+str(upstream/"include"),"-I"+str(upstream/"src"),
                "-framework","Foundation","-framework","AppKit","-framework","ImageIO","-framework","UniformTypeIdentifiers",
                "-install_name","@rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter",
                *adapter,"-o",tmp/("media-"+arch))
        for prefix, binary in [("jack",contents/"MacOS/AppleJack"),("updater",contents/"Helpers/AppleJackUpdater"),("media",version/"MediaRemoteAdapter")]:
            run("xcrun","lipo","-create",*(tmp/(prefix+"-"+arch) for arch in architectures),"-output",binary)
            slices = subprocess.check_output(["xcrun","lipo","-archs",str(binary)],text=True).split()
            if set(slices) != set(architectures): raise RuntimeError(f"Missing architecture in {binary.name}: {slices}")
        (version/"Resources/Info.plist").write_bytes(plistlib.dumps(dict(
            CFBundleExecutable="MediaRemoteAdapter",CFBundleIdentifier="com.fonz.applejack.public.mediaremote",
            CFBundleName="MediaRemoteAdapter",CFBundlePackageType="FMWK",CFBundleVersion="1",LSMinimumSystemVersion="13.0")))
        for link, target in [("Versions/Current","A"),("Resources","Versions/Current/Resources"),("MediaRemoteAdapter","Versions/Current/MediaRemoteAdapter")]:
            (framework/link).symlink_to(target)
        sparkle_framework = contents/'Frameworks/Sparkle.framework'
        shutil.copytree(sparkle/'Sparkle.framework',sparkle_framework,symlinks=True)
        dest = contents/"Resources"
        for name in ["AppleJackMac.icns","applejack-media.pl"]:
            shutil.copyfile(resources/name,dest/name)
        shutil.copytree(resources/"Sprites",dest/"Sprites")
        shutil.copytree(resources/"Shortcuts",dest/"Shortcuts")
        shutil.copytree(resources/"BubbleLogos",dest/"BubbleLogos")
        # Embed guide images so the standalone copy on the disk image works offline too.
        def embed_screenshot(match):
            image = root / "Docs/Screenshots" / match.group(1)
            return 'src="data:image/jpeg;base64,' + b64encode(image.read_bytes()).decode("ascii") + '"'
        guide = (resources/"Setup.html").read_text()
        guide = re.sub(r'src="[.][.]/Docs/Screenshots/([a-z-]+[.]jpg)"', embed_screenshot, guide)
        (dest/"Setup.html").write_text(guide)
        shutil.copyfile(upstream/"bin/mediaremote-adapter.pl",dest/"mediaremote-adapter.pl")
        for path,name in [(upstream/"LICENSE","MediaRemoteAdapter-LICENSE.txt"),(root/"LICENSE","LICENSE.txt"),(root/"ARTWORK.md","ARTWORK.txt")]:
            shutil.copyfile(path,dest/name)
        shutil.copyfile(sparkle/'LICENSE',dest/'Sparkle-LICENSE.txt')
        flags = ["--force","--sign",identity]
        if identity != "-": flags += ["--options","runtime","--timestamp"]
        if identity != '-':
            for nested in ['Versions/B/XPCServices/Downloader.xpc','Versions/B/XPCServices/Installer.xpc','Versions/B/Updater.app','Versions/B/Autoupdate']:
                if (sparkle_framework/nested).exists(): run('codesign',*flags,sparkle_framework/nested)
            run('codesign',*flags,sparkle_framework)
        run("codesign",*flags,framework)
        run("codesign",*flags,contents/"Helpers/AppleJackUpdater")
        app_flags = ["--entitlements",root/"Resources/Distribution.entitlements"] if identity != "-" else []
        run("codesign",*flags,*app_flags,app)
        run("codesign","--verify","--deep","--strict",app)
        final = output/app.name
        if final.exists(): shutil.rmtree(final)
        app.rename(final)
        print(final,flush=True)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository",help="GitHub owner/name hosting the public releases")
    parser.add_argument("--identity",default="-",help="Developer ID Application certificate name (default: local ad-hoc signing)")
    args = parser.parse_args()
    build(root/"build",args.identity,args.repository)
