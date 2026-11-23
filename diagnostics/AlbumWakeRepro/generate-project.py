#!/usr/bin/env python3
"""Standalone iPhone/iOS 27 diagnostic; deliberately imports no production files."""
from pathlib import Path
import hashlib, plistlib
root = Path(__file__).resolve().parent
objects = []
def uid(s): return hashlib.sha1(s.encode()).hexdigest()[:24].upper()
def add(k, text):
    objects.append(f'{uid(k)} = {{ {text} }};')
    return uid(k)
def q(s): return '"' + s.replace('"', '\\"') + '"'
targets = [('WakeExtension', 'com.apple.product-type.extensionkit-extension', 'appex'), ('AlbumWakeRepro', 'com.apple.product-type.application', 'app')]
products, groups = [], []
for name, kind, suffix in targets:
    host = name == 'AlbumWakeRepro'
    sources = ['Probe.swift', 'WakeApp.swift' if host else 'WakeExtension.swift']
    refs, builds = [], []
    for file in sources:
        ref = add(name + file, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {file}; sourceTree = SOURCE_ROOT;')
        refs.append(ref)
        builds.append(add('build'+name+file, f'isa = PBXBuildFile; fileRef = {ref};'))
    groups.append(add('group'+name, f'isa = PBXGroup; name = {name}; children = ({",".join(refs)},); sourceTree = "<group>";'))
    product = add('product'+name, f'isa = PBXFileReference; explicitFileType = {"wrapper.application" if host else "wrapper.app-extension"}; path = {name}.{suffix}; sourceTree = BUILT_PRODUCTS_DIR;')
    products.append(product)
    phases = [add('sources'+name, f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)},); runOnlyForDeploymentPostprocessing = 0;')]
    deps = []
    if host:
        proxy = add('proxy', f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {uid("targetWakeExtension")}; remoteInfo = WakeExtension;')
        deps.append(add('dep', f'isa = PBXTargetDependency; target = {uid("targetWakeExtension")}; targetProxy = {proxy};'))
        embed = add('embed', f'isa = PBXBuildFile; fileRef = {uid("productWakeExtension")}; settings = {{ ATTRIBUTES = (RemoveHeadersOnCopy,); }};')
        phases.append(add('copy', f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = "$(CONTENTS_FOLDER_PATH)/Extensions"; dstSubfolderSpec = 16; files = ({embed},); runOnlyForDeploymentPostprocessing = 0;'))
    configs = []
    for config in ['Debug', 'Release']:
        settings = {'PRODUCT_NAME':'$(TARGET_NAME)', 'PRODUCT_BUNDLE_IDENTIFIER':'com.xdjs.AlbumWakeRepro' + ('' if host else '.WakeExtension'), 'SWIFT_VERSION':'5.0', 'IPHONEOS_DEPLOYMENT_TARGET':'27.0', 'TARGETED_DEVICE_FAMILY':'1', 'SUPPORTED_PLATFORMS':'iphoneos iphonesimulator', 'GENERATE_INFOPLIST_FILE':'YES', 'INFOPLIST_FILE':name+'.plist', 'CODE_SIGN_ENTITLEMENTS':'Repro.entitlements', 'CODE_SIGN_STYLE':'Automatic', 'DEVELOPMENT_TEAM':'', 'CURRENT_PROJECT_VERSION':'1', 'MARKETING_VERSION':'0.1', 'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if config=='Debug' else '-O'}
        if host:
            settings.update({'INFOPLIST_KEY_CFBundleDisplayName':'Album Wake Repro', 'INFOPLIST_KEY_UILaunchScreen_Generation':'YES', 'INFOPLIST_KEY_UIApplicationSceneManifest_Generation':'YES', 'INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone':'UIInterfaceOrientationPortrait'})
        else:
            settings.update({'APPLICATION_EXTENSION_API_ONLY':'YES', 'SKIP_INSTALL':'YES', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS':'WAKE_EXTENSION'})
        configs.append(add(name+config, 'isa = XCBuildConfiguration; name = '+config+'; buildSettings = {'+' '.join(f'{k} = {q(v)};' for k,v in settings.items())+'};'))
    cl = add('config'+name, f'isa = XCConfigurationList; buildConfigurations = ({",".join(configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    add('target'+name, f'isa = PBXNativeTarget; buildConfigurationList = {cl}; buildPhases = ({",".join(phases)},); buildRules = (); dependencies = ({",".join(deps)}); name = {name}; productName = {name}; productReference = {product}; productType = {q(kind)};')
pg = add('products', f'isa = PBXGroup; children = ({",".join(products)},); name = Products; sourceTree = "<group>";')
main = add('main', f'isa = PBXGroup; children = ({",".join(groups)},{pg},); sourceTree = "<group>";')
configs = [add('project'+c, f'isa = XCBuildConfiguration; name = {c}; buildSettings = {{ SDKROOT = iphoneos; CLANG_ENABLE_MODULES = YES; CLANG_ENABLE_OBJC_ARC = YES; }};') for c in ['Debug', 'Release']]
cl = add('projectconfigs', f'isa = XCConfigurationList; buildConfigurations = ({",".join(configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
add('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2700; }}; buildConfigurationList = {cl}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {main}; productRefGroup = {pg}; projectDirPath = ""; projectRoot = ""; targets = ({",".join(uid("target"+t[0]) for t in targets)},);')
project = root/'AlbumWakeRepro.xcodeproj'; project.mkdir(exist_ok=True)
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+'\n}; rootObject = '+uid('project')+'; }\n')
ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("targetAlbumWakeRepro")}" BuildableName="AlbumWakeRepro.app" BlueprintName="AlbumWakeRepro" ReferencedContainer="container:AlbumWakeRepro.xcodeproj"/>'
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>'''
p = project/'xcshareddata/xcschemes'; p.mkdir(parents=True, exist_ok=True); (p/'AlbumWakeRepro.xcscheme').write_text(scheme)
for name,_,_ in targets:
    info = {'NSPhotoLibraryUsageDescription':'Observe an isolated test album for a non-publishing background scheduling diagnostic.'}
    if name == 'WakeExtension':
        info.update({'EXAppExtensionAttributes':{'EXExtensionPointIdentifier':'com.apple.photos.background-upload'}, 'BackgroundUploadURLBase':'https://example.invalid'})
    (root/(name+'.plist')).write_bytes(plistlib.dumps(info))
(root/'Repro.entitlements').write_bytes(plistlib.dumps({'com.apple.security.application-groups':['group.com.xdjs.AlbumWakeRepro']}))
print('Generated independent AlbumWakeRepro.xcodeproj')
