#!/usr/bin/env python3
"""Write the public manifest/appcast for an already signed final GitHub archive."""
import argparse, base64, hashlib, json, plistlib, re
from datetime import datetime, timezone
from pathlib import Path
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('archive',type=Path); p.add_argument('--signature',required=True)
    p.add_argument('--tag',required=True); p.add_argument('--notes-file',type=Path,required=True)
    args=p.parse_args()
    info=plistlib.loads((root/'build/Apple Jack Public.app/Contents/Info.plist').read_bytes())
    repo=info['AppleJackGitHubRepository']; version=info['CFBundleShortVersionString']
    assert re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*',repo)
    assert re.fullmatch('v'+re.escape(version)+r'(?:-preview\.[1-9][0-9]*)?',args.tag)
    assert args.archive.name in (f'Apple-Jack-{version}-macOS.dmg',f'Apple-Jack-{version}-preview-macOS.dmg')
    signature=base64.b64decode(args.signature,validate=True); assert len(signature)==64
    notes=args.notes_file.read_text().strip(); assert len(notes)<=8000
    data=args.archive.read_bytes(); assert 512<=len(data)<=1_073_741_824
    # Verify the signature with Apple's CryptoKit before advertising the archive.
    import subprocess,tempfile
    with tempfile.TemporaryDirectory(prefix='jack-signature-') as temp:
        verifier=Path(temp)/'verify.swift'
        verifier.write_text('import Foundation\nimport CryptoKit\nlet a=CommandLine.arguments\nlet k=try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded:a[1])!)\nguard k.isValidSignature(Data(base64Encoded:a[2])!, for:try Data(contentsOf:URL(fileURLWithPath:a[3]))) else { fatalError("Invalid archive signature") }\n')
        subprocess.run(['xcrun','swift','-module-cache-path',str(root/'build/modules'),str(verifier),info['SUPublicEDKey'],args.signature,str(args.archive.resolve())],check=True)
    release=dict(schemaVersion=1,bundleIdentifier=info['CFBundleIdentifier'],version=version,
        build=int(info['CFBundleVersion']),minimumSystemVersion=info['LSMinimumSystemVersion'],architecture='universal',
        file=args.archive.name,sha256=hashlib.sha256(data).hexdigest(),notes=notes,channel='stable',
        releaseTag=args.tag,sparkleEdSignature=args.signature,sparkleLength=len(data))
    ns='http://www.andymatuschak.org/xml-namespaces/sparkle'; ET.register_namespace('sparkle',ns)
    rss=ET.Element('rss',version='2.0'); channel=ET.SubElement(rss,'channel')
    ET.SubElement(channel,'title').text='Apple Jack Public Updates'
    ET.SubElement(channel,'link').text=f'https://github.com/{repo}'
    item=ET.SubElement(channel,'item'); ET.SubElement(item,'title').text=f'Apple Jack {version}'
    ET.SubElement(item,'pubDate').text=datetime.now(timezone.utc).strftime('%a, %d %b %Y %H:%M:%S %z')
    ET.SubElement(item,'description').text=notes
    ET.SubElement(item,f'{{{ns}}}version').text=str(release['build'])
    ET.SubElement(item,f'{{{ns}}}shortVersionString').text=version
    ET.SubElement(item,f'{{{ns}}}minimumSystemVersion').text=release['minimumSystemVersion']
    ET.SubElement(item,'enclosure',url=f'https://github.com/{repo}/releases/download/{args.tag}/{args.archive.name}',length=str(len(data)),type='application/octet-stream',attrib={f'{{{ns}}}edSignature':args.signature})
    output=root/'Updates'; output.mkdir(exist_ok=True)
    (output/'latest.json').write_text(json.dumps(release,indent=2)+'\n')
    ET.indent(rss); ET.ElementTree(rss).write(output/'appcast.xml',encoding='utf-8',xml_declaration=True)
    print('Verified signature and wrote public update feeds.')
if __name__=='__main__': main()
