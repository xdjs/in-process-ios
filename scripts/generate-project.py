#!/usr/bin/env python3
"""Regenerate the dependency-free Xcode project after adding source files."""
from pathlib import Path
import hashlib
from xml.sax.saxutils import escape
root = Path(__file__).resolve().parents[1]
def uid(s): return hashlib.sha1(s.encode()).hexdigest()[:24].upper()
def q(s): return '"'+s.replace('\\','\\\\').replace('"','\\"')+'"'
objects=[]
seen=set()
def add(key, body):
 if key not in seen: objects.append(f'{uid(key)} = {{ {body} }};'); seen.add(key)
 return uid(key)
targets=[('InProcessUploadExtension','com.apple.product-type.extensionkit-extension','appex'),('InProcess','com.apple.product-type.application','app'),('InProcessTests','com.apple.product-type.bundle.unit-test','xctest'),('InProcessUITests','com.apple.product-type.bundle.ui-testing','xctest')]
groups=[]
# The team comes from Config/Signing.xcconfig, which includes the git-ignored Config/Local.xcconfig when present.
signing=add('file:Config/Signing.xcconfig','isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = "Config/Signing.xcconfig"; sourceTree = SOURCE_ROOT;')
for name,kind,ext in targets:
 files=sorted((root/name).rglob('*.swift'))
 if name=='InProcessUploadExtension':
  files+=sorted((root/'InProcess/Automatic').glob('*.swift')) + sorted((root/'InProcess/Models').glob('*.swift')) + sorted((root/'InProcess/Services').glob('*.swift'))
 sources=[]; children=[]
 for path in files:
  rel=str(path.relative_to(root)); ref=add(name+":"+rel,'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = '+q(rel)+'; sourceTree = SOURCE_ROOT;')
  build=add('build:'+name+':'+rel,f'isa = PBXBuildFile; fileRef = {ref};'); sources.append(build); children.append(ref)
 resources=[]
 if name in ['InProcess','InProcessUploadExtension']:
  rel='InProcess/Resources/ServiceConfig.plist'; ref=add(name+":"+rel,'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = '+q(rel)+'; sourceTree = SOURCE_ROOT;')
  resources.append(add('build:'+name+':'+rel,f'isa = PBXBuildFile; fileRef = {ref};')); children.append(ref)
 if name=='InProcess':
  for path in sorted((root/'InProcess/Resources/Fonts').glob('*.ttf')):
   rel=str(path.relative_to(root)); ref=add(name+":"+rel,'isa = PBXFileReference; lastKnownFileType = file; path = '+q(rel)+'; sourceTree = SOURCE_ROOT;')
   resources.append(add('build:'+name+':'+rel,f'isa = PBXBuildFile; fileRef = {ref};')); children.append(ref)
  rel='InProcess/Resources/Assets.xcassets'; ref=add(name+":"+rel,'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = '+q(rel)+'; sourceTree = SOURCE_ROOT;')
  resources.append(add('build:'+name+':'+rel,f'isa = PBXBuildFile; fileRef = {ref};')); children.append(ref)
 groups.append(add('group:'+name,f'isa = PBXGroup; children = ({",".join(children)},); name = {name}; sourceTree = "<group>";'))
 product=add('product:'+name,f'isa = PBXFileReference; explicitFileType = {"wrapper.application" if ext=="app" else ("wrapper.app-extension" if ext=="appex" else "wrapper.cfbundle")}; path = {name}.{ext}; sourceTree = BUILT_PRODUCTS_DIR;')
 sourcePhase=add('sources:'+name,f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(sources)},); runOnlyForDeploymentPostprocessing = 0;')
 resourcePhase=add('resources:'+name,f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(resources)}{"," if resources else ""}); runOnlyForDeploymentPostprocessing = 0;')
 frameworkPhase=add('frameworks:'+name,'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
 configs=[]
 for config in ['Debug','Release']:
  settings={'PRODUCT_NAME':'$(TARGET_NAME)','PRODUCT_BUNDLE_IDENTIFIER':'com.xdjs.InProcess'+('' if name=='InProcess' else '.'+name),'SWIFT_VERSION':'5.0','IPHONEOS_DEPLOYMENT_TARGET':'27.0','TARGETED_DEVICE_FAMILY':'1','GENERATE_INFOPLIST_FILE':'YES','CODE_SIGN_STYLE':'Automatic','CURRENT_PROJECT_VERSION':'1','MARKETING_VERSION':'1.0','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','SWIFT_EMIT_LOC_STRINGS':'YES','ENABLE_USER_SCRIPT_SANDBOXING':'YES'}
  if name=='InProcess': settings.update({'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','INFOPLIST_KEY_CFBundleDisplayName':'In Process','INFOPLIST_KEY_UILaunchScreen_Generation':'YES','INFOPLIST_KEY_UIApplicationSceneManifest_Generation':'YES','INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone':'UIInterfaceOrientationPortrait','INFOPLIST_KEY_ITSAppUsesNonExemptEncryption':'NO'})
  if name in ['InProcess','InProcessUploadExtension']: settings.update({'CODE_SIGN_ENTITLEMENTS':'InProcess/Resources/InProcess.entitlements'})
  if name=='InProcess': settings['INFOPLIST_FILE']='InProcess/Resources/Info.plist'
  if name=='InProcess': settings['INFOPLIST_KEY_NSPhotoLibraryUsageDescription']='In Process reads the album you publish from and uploads its photos in the background, keeping your current Photos edits.'
  if name=='InProcessUploadExtension': settings.update({'INFOPLIST_KEY_CFBundleDisplayName':'In Process','INFOPLIST_FILE':'InProcessUploadExtension/Info.plist','SKIP_INSTALL':'YES','APPLICATION_EXTENSION_API_ONLY':'YES'})
  if name=='InProcessTests': settings.update({'TEST_HOST':'$(BUILT_PRODUCTS_DIR)/InProcess.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/InProcess','BUNDLE_LOADER':'$(TEST_HOST)'})
  if name=='InProcessUITests': settings['TEST_TARGET_NAME']='InProcess'
  if config=='Debug': settings.update({'SWIFT_OPTIMIZATION_LEVEL':'-Onone','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG $(inherited)','ENABLE_TESTABILITY':'YES'})
  else: settings.update({'SWIFT_OPTIMIZATION_LEVEL':'-O','SWIFT_COMPILATION_MODE':'wholemodule'})
  if name=='InProcessUploadExtension': settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS']=settings.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS','$(inherited)')+' UPLOAD_EXTENSION'
  configs.append(add(name+config,'isa = XCBuildConfiguration; '+(f'baseConfigurationReference = {signing}; ' if name in ['InProcess','InProcessUploadExtension'] else '')+'buildSettings = {'+' '.join(f'{k} = {q(v)};' for k,v in settings.items())+'}; name = '+config+';'))
 cl=add('configlist:'+name,f'isa = XCConfigurationList; buildConfigurations = ({",".join(configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
 deps=[]
 if name in ['InProcessTests','InProcessUITests']:
  proxy=add('proxy:'+name,f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {uid("target:InProcess")}; remoteInfo = InProcess;')
  deps.append(add('dep:'+name,f'isa = PBXTargetDependency; target = {uid("target:InProcess")}; targetProxy = {proxy};'))
 phases=[sourcePhase,frameworkPhase,resourcePhase]
 if name=='InProcess':
  proxy=add('proxy:extension',f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {uid("target:InProcessUploadExtension")}; remoteInfo = InProcessUploadExtension;')
  deps.append(add('dep:extension',f'isa = PBXTargetDependency; target = {uid("target:InProcessUploadExtension")}; targetProxy = {proxy};'))
  embedded=add('embed:extension',f'isa = PBXBuildFile; fileRef = {uid("product:InProcessUploadExtension")}; settings = {{ ATTRIBUTES = (RemoveHeadersOnCopy,); }};')
  phases.append(add('embedphase',f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = "$(CONTENTS_FOLDER_PATH)/Extensions"; dstSubfolderSpec = 16; files = ({embedded},); name = "Embed App Extensions"; runOnlyForDeploymentPostprocessing = 0;'))
 add('target:'+name,f'isa = PBXNativeTarget; buildConfigurationList = {cl}; buildPhases = ({",".join(phases)},); buildRules = (); dependencies = ({",".join(deps)}{"," if deps else ""}); name = {name}; productName = {name}; productReference = {product}; productType = {q(kind)};')
products=add('products','isa = PBXGroup; children = ('+','.join(uid('product:'+t[0]) for t in targets)+',); name = Products; sourceTree = "<group>";')
main=add('main',f'isa = PBXGroup; children = ({",".join(groups)},{signing},{products},); sourceTree = "<group>";')
configs=[]
for config in ['Debug','Release']:
 configs.append(add('project'+config,'isa = XCBuildConfiguration; buildSettings = { SDKROOT = iphoneos; CLANG_ENABLE_MODULES = YES; CLANG_ENABLE_OBJC_ARC = YES; DEBUG_INFORMATION_FORMAT = '+('dwarf' if config=='Debug' else '"dwarf-with-dsym"')+'; }; name = '+config+';'))
cl=add('projectconfigs',f'isa = XCConfigurationList; buildConfigurations = ({",".join(configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
add('project',f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2700; }}; buildConfigurationList = {cl}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {main}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({",".join(uid("target:"+t[0]) for t in targets)},);')
project=root/'InProcess.xcodeproj'; project.mkdir(exist_ok=True)
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+'\n}; rootObject = '+uid('project')+'; }\n')
def reference(name,ext): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("target:"+name)}" BuildableName="{name}.{ext}" BlueprintName="{name}" ReferencedContainer="container:InProcess.xcodeproj"/>'
scheme=f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference('InProcess','app')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>{''.join('<TestableReference skipped="NO">'+reference(n,'xctest')+'</TestableReference>' for n in ['InProcessTests','InProcessUITests'])}</Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference('InProcess','app')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference('InProcess','app')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
sdir=project/'xcshareddata/xcschemes';sdir.mkdir(parents=True,exist_ok=True);(sdir/'InProcess.xcscheme').write_text(scheme)
print('Generated InProcess.xcodeproj')
