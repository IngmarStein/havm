#!/usr/bin/env python3
"""Generate a minimal havm.xcodeproj for signing configuration.

This project wraps the SPM package so Xcode's Signing & Capabilities
tab can manage entitlements. The actual build still uses xcodebuild
via the package workspace.
"""
import os, uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJ_DIR = os.path.join(ROOT, "havm.xcodeproj")
os.makedirs(PROJ_DIR, exist_ok=True)

def xid(seed=""):
    h = uuid.uuid5(uuid.NAMESPACE_URL, f"havm-{seed}").hex.upper()
    return h[:24]

# IDs
OBJ = {}
def rid(name):
    obj[xid(name)] = None

rid("project")
rid("main_group")
rid("sources_group")
rid("resources_group")
rid("products_group")
rid("target")
rid("sources_phase")
rid("resources_phase")
rid("product_ref")
rid("proj_cfg_list")
rid("target_cfg_list")
rid("debug_cfg")
rid("release_cfg")
rid("proj_debug_cfg")
rid("proj_release_cfg")
rid("main_ref")

# Build the pbxproj
pbx = f'''// !$*UTF8*$!
{{
    archiveVersion = 1;
    classes = {{}};
    objectVersion = 56;
    objects = {{
        {OBJ["main_ref"]} /* main.swift */ = {{
            isa = PBXFileReference;
            lastKnownFileType = sourcecode.swift;
            path = "Sources/Havm/main.swift";
            sourceTree = "<group>";
        }};
        {OBJ["product_ref"]} /* havm */ = {{
            isa = PBXFileReference;
            explicitFileType = "compiled.mach-o.executable";
            path = havm;
            sourceTree = BUILT_PRODUCTS_DIR;
        }};
        {OBJ["sources_group"]} = {{
            isa = PBXGroup;
            children = ({OBJ["main_ref"]});
            name = Sources;
            sourceTree = "<group>";
        }};
        {OBJ["resources_group"]} = {{
            isa = PBXGroup;
            children = ();
            name = Resources;
            sourceTree = "<group>";
        }};
        {OBJ["products_group"]} = {{
            isa = PBXGroup;
            children = ({OBJ["product_ref"]});
            name = Products;
            sourceTree = "<group>";
        }};
        {OBJ["main_group"]} = {{
            isa = PBXGroup;
            children = (
                {OBJ["sources_group"]},
                {OBJ["resources_group"]},
                {OBJ["products_group"]},
            );
            sourceTree = "<group>";
        }};
        {OBJ["sources_phase"]} = {{
            isa = PBXSourcesBuildPhase;
            buildActionMask = 2147483647;
            files = (
                {xid("bf-main")} /* main.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {OBJ["main_ref"]}; }},
            );
            runOnlyForDeploymentPostprocessing = 0;
        }};
        {OBJ["resources_phase"]} = {{
            isa = PBXResourcesBuildPhase;
            buildActionMask = 2147483647;
            files = ();
            runOnlyForDeploymentPostprocessing = 0;
        }};
        {OBJ["target"]} /* havm */ = {{
            isa = PBXNativeTarget;
            buildConfigurationList = {OBJ["target_cfg_list"]};
            buildPhases = (
                {OBJ["sources_phase"]},
                {OBJ["resources_phase"]},
            );
            buildRules = ();
            dependencies = ();
            name = havm;
            productName = havm;
            productReference = {OBJ["product_ref"]};
            productType = "com.apple.product-type.tool";
        }};
        {OBJ["project"]} /* Project object */ = {{
            isa = PBXProject;
            attributes = {{
                BuildIndependentTargetsInParallel = 1;
                LastSwiftUpdateCheck = 1700;
                LastUpgradeCheck = 1700;
                TargetAttributes = {{
                    {OBJ["target"]} = {{
                        CreatedOnToolsVersion = 17.0;
                    }};
                }};
            }};
            buildConfigurationList = {OBJ["proj_cfg_list"]};
            compatibilityVersion = "Xcode 14.0";
            developmentRegion = en;
            hasScannedForEncodings = 0;
            knownRegions = (en, Base);
            mainGroup = {OBJ["main_group"]};
            productRefGroup = {OBJ["products_group"]};
            projectDirPath = "";
            projectRoot = "";
            targets = ({OBJ["target"]});
        }};
        {OBJ["debug_cfg"]} /* Debug */ = {{
            isa = XCBuildConfiguration;
            buildSettings = {{
                CODE_SIGN_ENTITLEMENTS = "resources/entitlements.plist";
                CODE_SIGN_STYLE = Automatic;
                ENABLE_HARDENED_RUNTIME = YES;
                PRODUCT_NAME = "$(TARGET_NAME)";
                SWIFT_VERSION = "6.0";
                MACOSX_DEPLOYMENT_TARGET = "$(RECOMMENDED_MACOSX_DEPLOYMENT_TARGET)";
                SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) SWIFT_PACKAGE";
                OTHER_SWIFT_FLAGS = "$(inherited)";
                HEADER_SEARCH_PATHS = "$(inherited)";
                LIBRARY_SEARCH_PATHS = "$(inherited)";
                FRAMEWORK_SEARCH_PATHS = "$(inherited)";
            }};
            name = Debug;
        }};
        {OBJ["release_cfg"]} /* Release */ = {{
            isa = XCBuildConfiguration;
            buildSettings = {{
                CODE_SIGN_ENTITLEMENTS = "resources/entitlements.plist";
                CODE_SIGN_STYLE = Automatic;
                ENABLE_HARDENED_RUNTIME = YES;
                PRODUCT_NAME = "$(TARGET_NAME)";
                SWIFT_VERSION = "6.0";
                MACOSX_DEPLOYMENT_TARGET = "$(RECOMMENDED_MACOSX_DEPLOYMENT_TARGET)";
                SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) SWIFT_PACKAGE";
                OTHER_SWIFT_FLAGS = "$(inherited)";
                HEADER_SEARCH_PATHS = "$(inherited)";
                LIBRARY_SEARCH_PATHS = "$(inherited)";
                FRAMEWORK_SEARCH_PATHS = "$(inherited)";
            }};
            name = Release;
        }};
        {OBJ["proj_debug_cfg"]} /* Debug */ = {{
            isa = XCBuildConfiguration;
            buildSettings = {{
                SDKROOT = macosx;
                MACOSX_DEPLOYMENT_TARGET = "$(RECOMMENDED_MACOSX_DEPLOYMENT_TARGET)";
            }};
            name = Debug;
        }};
        {OBJ["proj_release_cfg"]} /* Release */ = {{
            isa = XCBuildConfiguration;
            buildSettings = {{
                SDKROOT = macosx;
                MACOSX_DEPLOYMENT_TARGET = "$(RECOMMENDED_MACOSX_DEPLOYMENT_TARGET)";
            }};
            name = Release;
        }};
        {OBJ["target_cfg_list"]} /* Build configuration list */ = {{
            isa = XCConfigurationList;
            buildConfigurations = ({OBJ["debug_cfg"]}, {OBJ["release_cfg"]});
            defaultConfigurationIsVisible = 0;
            defaultConfigurationName = Release;
        }};
        {OBJ["proj_cfg_list"]} /* Build configuration list */ = {{
            isa = XCConfigurationList;
            buildConfigurations = ({OBJ["proj_debug_cfg"]}, {OBJ["proj_release_cfg"]});
            defaultConfigurationIsVisible = 0;
            defaultConfigurationName = Release;
        }};
    }};
    rootObject = {OBJ["project"]} /* Project object */;
}}
'''

with open(os.path.join(PROJ_DIR, "project.pbxproj"), "w") as f:
    f.write(pbx)

# Create xcshareddata with scheme
shared_dir = os.path.join(PROJ_DIR, "project.xcworkspace", "xcshareddata")
os.makedirs(shared_dir, exist_ok=True)
with open(os.path.join(shared_dir, "WorkspaceSettings.xcsettings"), "w") as f:
    f.write('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>''')

print(f"✅ Generated {PROJ_DIR}")
print()
print("Next steps:")
print("  1. Open havm.xcodeproj in Xcode")
print("  2. Select the 'havm' target → Signing & Capabilities")
print("  3. Set Team, add capabilities (Accessory Access, etc.)")
print("  4. The entitlements are pre-configured in resources/entitlements.plist")
print()
print("  Build from command line:")
print("    xcodebuild -project havm.xcodeproj -scheme havm -allowProvisioningUpdates")
