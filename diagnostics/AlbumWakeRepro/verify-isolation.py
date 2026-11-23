#!/usr/bin/env python3
"""Offline guard against accidentally linking production code or capabilities."""
from pathlib import Path
import json, plistlib, subprocess, re
root = Path(__file__).resolve().parent
project = json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(root/'AlbumWakeRepro.xcodeproj/project.pbxproj')]))
objects = project['objects']
sources = {o['path'] for o in objects.values() if o.get('lastKnownFileType') == 'sourcecode.swift'}
assert sources == {'Probe.swift', 'WakeApp.swift', 'WakeExtension.swift'}, sources
for o in objects.values():
    if o.get('isa') == 'XCBuildConfiguration' and 'PRODUCT_BUNDLE_IDENTIFIER' in o['buildSettings']:
        s = o['buildSettings']
        assert s['PRODUCT_BUNDLE_IDENTIFIER'] in ['com.xdjs.AlbumWakeRepro','com.xdjs.AlbumWakeRepro.WakeExtension']
        assert s['IPHONEOS_DEPLOYMENT_TARGET'] == '27.0' and s['TARGETED_DEVICE_FAMILY'] == '1'
        assert s['CODE_SIGN_ENTITLEMENTS'] == 'Repro.entitlements'
entitlements = plistlib.loads((root/'Repro.entitlements').read_bytes())
assert entitlements == {'com.apple.security.application-groups':['group.com.xdjs.AlbumWakeRepro']}
info = plistlib.loads((root/'WakeExtension.plist').read_bytes())
assert info['BackgroundUploadURLBase'] == 'https://example.invalid'
assert info['EXAppExtensionAttributes']['EXExtensionPointIdentifier'] == 'com.apple.photos.background-upload'
for file in sources:
    text = (root/file).read_text()
    for symbol in ['InProcessAPI','UploadCoordinator','UploadStore','SecItem','URLSession','PHAssetResourceUploadJobChangeRequest','PHAssetChangeRequest','creationRequestForAssetFrom','PHAssetResourceManager','registerChangeObserver','BGTaskScheduler']:
        assert symbol not in text, (file,symbol)
    assert 'com.xdjs.InProcess' not in text
assert re.findall(r'return \.(\w+)',(root/'WakeExtension.swift').read_text()) == ['completed','failure']
assert 'throw ProbeError.physicalDevice' in (root/'Probe.swift').read_text()
print('PASS: independent targets/groups, iPhone iOS 27, no production/auth/network/resource/job code, bounded extension results')
