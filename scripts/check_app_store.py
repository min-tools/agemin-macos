#!/usr/bin/env python3
"""Report release blockers found by local checks and, with --online, verify the public submission URLs."""
from datetime import date
from pathlib import Path
import plistlib
import re
import socket
import sys
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent.parent


# valid_release_version(version, build_number): Accept a YY.M or YY.M.N public version paired with a
# ten-digit YYYYMMDDNN build number whose date exists.
def valid_release_version(version, build_number):
    # Keep public versions compact, without leading zeros or a day component.
    if not isinstance(version, str) or re.fullmatch(r'[0-9]{2}\.(?:[1-9]|1[0-2])(?:\.[1-9][0-9]*)?', version) is None:
        return False
    # Check the date-plus-sequence shape; this does not compare with previous uploads.
    if not isinstance(build_number, str) or re.fullmatch(r'[0-9]{10}', build_number) is None:
        return False
    # A patch can be built in a later month, but its build date must be real.
    try:
        date(int(build_number[:4]), int(build_number[4:6]), int(build_number[6:8]))
    # An impossible month or day means the build number was mistyped.
    except ValueError:
        return False
    return True


# blockers([check_online=False]): Collect failures from these local release checks.
# With check_online, also fetch the public URLs named in BuildEdition.swift.
def blockers(check_online=False):
    issues = []
    # Load every project file, source file, and policy that the checks below inspect.
    project = (ROOT / 'Agemin.xcodeproj/project.pbxproj').read_text()
    scheme = (ROOT / 'Agemin.xcodeproj/xcshareddata/xcschemes/Agemin.xcscheme').read_text()
    info = plistlib.loads((ROOT / 'AgeminInfo.plist').read_bytes())
    entitlements = plistlib.loads((ROOT / 'AgeminApp.entitlements').read_bytes())
    manifest = plistlib.loads((ROOT / 'Sources/AgeminApp/Resources/PrivacyInfo.xcprivacy').read_bytes())
    edition = (ROOT / 'Sources/AgeminApp/BuildEdition.swift').read_text()
    key_store = (ROOT / 'Sources/AgeminApp/KeyStore.swift').read_text()
    products = (ROOT / 'Sources/AgeminApp/ProEntitlementLogic.swift').read_text()
    banner = (ROOT / 'Sources/AgeminApp/AccessBanner.swift').read_text()
    model = (ROOT / 'Sources/AgeminApp/AppModel.swift').read_text()
    pro_store = (ROOT / 'Sources/AgeminApp/ProStore.swift').read_text()
    engine = (ROOT / 'Sources/AgeminApp/AgeEngine.swift').read_text()
    byte_io = (ROOT / 'Sources/AgeminApp/ByteIO.swift').read_text()
    sources = '\n'.join(path.read_text() for path in (ROOT / 'Sources/AgeminApp').glob('*.swift'))
    policy = (ROOT / 'PRIVACY.md').read_text()
    bundled_policy = (ROOT / 'Sources/AgeminApp/Resources/PRIVACY.md').read_text()
    notices = (ROOT / 'THIRD_PARTY_NOTICES.md').read_text()
    bundled_notices = (ROOT / 'Sources/AgeminApp/Resources/THIRD_PARTY_NOTICES.md').read_text()

    # The store edition is selected by a compile flag at both the project and the target level.
    if project.count('SWIFT_ACTIVE_COMPILATION_CONDITIONS = AGEMIN_APP_STORE;') < 2:
        issues.append('AppStore must compile AGEMIN_APP_STORE at project and target level.')
    # Crash symbols are a target-level setting, so inspect only the target's AppStore block.
    app_store_target = re.search(r'100000000000000000000807.*?name = AppStore;', project, re.S)
    # Without that configuration the scheme below has nothing to archive.
    if app_store_target is None:
        issues.append('The Agemin target is missing its AppStore configuration.')
    # Without dSYMs, App Store crash reports cannot be symbolicated.
    elif 'DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";' not in app_store_target.group():
        issues.append('The AppStore archive must include dSYM crash symbols.')
    # Archiving any other configuration would upload a source edition.
    if '<ArchiveAction buildConfiguration="AppStore"' not in scheme:
        issues.append('The shared scheme must archive the AppStore configuration.')
    # Debug, Release, and AppStore must all produce the same bundle identifier.
    if project.count('PRODUCT_BUNDLE_IDENTIFIER = tools.min.agemin;') < 3:
        issues.append('The Agemin bundle identifier is not consistent across configurations.')
    versions = re.findall(r'MARKETING_VERSION = ([^;]+);', project)
    build_numbers = re.findall(r'CURRENT_PROJECT_VERSION = ([^;]+);', project)
    # All three target configurations must agree on one version and build number.
    if len(versions) != 3 or len(build_numbers) != 3 or len(set(versions)) != 1 or len(set(build_numbers)) != 1:
        issues.append('The release version is inconsistent across configurations.')
    # The agreed pair must also follow the dated release scheme.
    elif not valid_release_version(versions[0].strip('"'), build_numbers[0].strip('"')):
        issues.append('Use a YY.M or YY.M.N public version and a valid YYYYMMDDNN build number.')
    # Info.plist resolves $(AGEMIN_DISPLAY_NAME); an unset configuration would ship a blank name.
    if project.count('AGEMIN_DISPLAY_NAME = Agemin;') != 3:
        issues.append('The Agemin display name is unresolved in one or more target configurations.')
    # Info.plist is hand-written, so its executable name must track the Xcode setting.
    if 'EXECUTABLE_NAME = AgeminApp;' not in project or info.get('CFBundleExecutable') != 'AgeminApp':
        issues.append('The Xcode product and Info.plist executable names do not match.')
    # The store listing promises Apple silicon and macOS 14.
    if 'ARCHS = arm64;' not in project or info.get('LSMinimumSystemVersion') != '14.0':
        issues.append('The supported architecture or minimum macOS version changed.')
    # The hardened runtime must stay enabled.
    if 'ENABLE_HARDENED_RUNTIME = YES;' not in project:
        issues.append('Hardened Runtime is not enabled.')
    # BuildEdition.swift holds the identity constants and the compile-time guard against local
    # access in store builds.
    if 'tools.min.agemin' not in edition or 'AGEMIN_LOCAL_BUILD && AGEMIN_APP_STORE' not in edition:
        issues.append('The shared app identity or private-build boundary is incomplete.')
    # Both product identifiers must match App Store Connect exactly.
    if 'tools.min.agemin.pro.yearly' not in products or 'tools.min.agemin.pro.lifetime' not in products:
        issues.append('StoreKit product identifiers are incomplete.')
    # The trial length and Free limit are what the listing and privacy policy describe.
    if 'static let trialLengthDays = 30' not in products or 'static let dailyOperationLimit = 1' not in products:
        issues.append('The 30-day trial or one-operation daily Free allowance is missing.')
    # Public builds show the banner only once the entitlement is known and access is limited.
    if 'struct AgeminAccessBanner' not in banner or 'if store.hasResolvedEntitlement && store.hasPreparedFreeAccess && !store.hasFullAccess' not in banner:
        issues.append('The shared access banner is missing from public builds.')
    # Every encryption and decryption passes through the allowance before it starts.
    if 'guard proStore.beginOperation() else {' not in model or 'proStore.present(feature: .unlimitedOperations)' not in model \
            or model.count('guard self.beginOperation() else { return }') < 2:
        issues.append('The Free daily allowance is not enforced for both encryption and decryption.')
    # Subscriptions must link to the terms and privacy policy from the purchase panel.
    if 'AppLinks.termsOfUse' not in pro_store or 'AppLinks.privacyPolicy' not in pro_store:
        issues.append('The purchase panel is missing its legal links.')
    # The purchase panel's terms link must be Apple's standard EULA, not a page of the app's own.
    if 'static let termsOfUse = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!' not in edition:
        issues.append("Apple's standard EULA link is missing.")
    # The first release excludes France. Apple's documentation table requires a French declaration
    # for these published standard algorithms only when the app is available there.
    if info.get('ITSAppUsesNonExemptEncryption') is not False:
        issues.append('Agemin must stay documentation-exempt while France is excluded from availability.')
    # The About panel shows this notice.
    if info.get('NSHumanReadableCopyright') != '© 2026 Ilia Ross':
        issues.append('The About-panel copyright notice is missing.')
    document_types = [entry.get('LSItemContentTypes', []) for entry in info.get('CFBundleDocumentTypes', [])]
    # Finder offers Agemin for age files only through this declaration.
    if not any('org.c2sp.age' in types for types in document_types):
        issues.append('The age document type is not declared.')
    # The Mac App Store requires the sandbox.
    if not entitlements.get('com.apple.security.app-sandbox'):
        issues.append('App Sandbox is not enabled.')
    # The user picks files and key folders through open and save panels.
    if not entitlements.get('com.apple.security.files.user-selected.read-write'):
        issues.append('User-selected file access is missing; files and key folders cannot be opened.')
    # Access to the chosen folders is kept across launches through security-scoped bookmarks.
    if not entitlements.get('com.apple.security.files.bookmarks.app-scope'):
        issues.append('App-scoped bookmarks are missing; key folders would not survive a relaunch.')
    # The privacy policy promises an offline app.
    if any(key.startswith('com.apple.security.network') for key in entitlements):
        issues.append('Agemin must not request network access.')
    # The manifest must deny tracking explicitly rather than omit the key.
    if manifest.get('NSPrivacyTracking') is not False:
        issues.append('Privacy manifest tracking declaration is missing.')
    # The manifest must list no collected data types.
    if manifest.get('NSPrivacyCollectedDataTypes') != []:
        issues.append('Agemin collects no data; the privacy manifest must declare none.')
    # Index the declared reason codes by API category.
    reasons = {item.get('NSPrivacyAccessedAPIType'): item.get('NSPrivacyAccessedAPITypeReasons', []) for item in manifest.get('NSPrivacyAccessedAPITypes', [])}
    # Preferences need reason CA92.1, and the metadata of user-chosen files needs 3B52.1.
    if 'CA92.1' not in reasons.get('NSPrivacyAccessedAPICategoryUserDefaults', []) or '3B52.1' not in reasons.get('NSPrivacyAccessedAPICategoryFileTimestamp', []):
        issues.append('The privacy manifest must declare the UserDefaults and file metadata reasons.')
    # The in-app policy window shows the bundled copy, so it must match the published one.
    if not policy.strip() or policy != bundled_policy:
        issues.append('The repository and bundled privacy policies are missing or inconsistent.')
    # The OpenBSD and OpenSSH notices must ship unchanged in every binary distribution.
    if not notices.strip() or notices != bundled_notices:
        issues.append('The repository and bundled third-party notices are missing or inconsistent.')
    if 'Copyright (c) 2013 Ted Unangst' not in notices or 'Copyright 1997 Niels Provos' not in notices:
        issues.append('The required bcrypt_pbkdf or Blowfish attribution is missing.')
    if 'THIRD_PARTY_NOTICES.md in Resources' not in project:
        issues.append('The Xcode target does not bundle the third-party notices.')
    # Info.plist and the Xcode project must both reference the production icon.
    if info.get('CFBundleIconFile') != 'AgeminIcon' or 'AgeminIcon.icns' not in project:
        issues.append('The production Agemin icon is not configured.')
    # A referenced icon still has to exist on disk.
    if not (ROOT / 'Sources/AgeminApp/Resources/AgeminIcon.icns').is_file():
        issues.append('The Agemin icon file is missing from the bundle resources.')
    # Key folders stay reachable across launches only through security-scoped bookmarks.
    for marker in ('.withSecurityScope', 'startAccessingSecurityScopedResource()', 'stopAccessingSecurityScopedResource()'):
        # Each marker is part of the sandbox-safe folder access the policy describes.
        if marker not in key_store:
            issues.append(f'The key store no longer uses {marker}.')
    # Outputs are created private to the user and removed again when a run fails.
    if 'O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600' not in byte_io:
        issues.append('Output files are no longer created with owner-only permissions.')
    # Encryption and decryption each delete their partial output on failure.
    if engine.count('try? FileManager.default.removeItem(at: output)') < 2:
        issues.append('A failed encryption or decryption no longer removes its partial output.')
    # Search every source for process-launching and networking APIs.
    for forbidden in ('Process(', 'NSAppleScript', 'posix_spawn', 'URLSession'):
        # The policy promises the app runs no commands and makes no connections.
        if forbidden in sources:
            issues.append(f'The app must not run commands or connect: {forbidden}.')
    # Search for the usual package-manager install prefixes.
    for forbidden in ('/opt/homebrew', '/usr/local'):
        # Agemin implements age itself; nothing may depend on a package manager's tools.
        if forbidden in sources:
            issues.append(f'The app must not depend on package managers: {forbidden}.')
    # Resolve and fetch each public URL so a dead listing link is caught before submission.
    if check_online:
        urls = re.findall(r'static let (?:website|privacyPolicy|termsOfUse|support) = URL\(string: "(https://[^"]+)"\)!', edition)
        # Check each link on its own so one failure does not hide the others.
        for url in urls:
            # Resolve the host first, then fetch the page with a short timeout.
            try:
                host = re.match(r'https://([^/]+)', url).group(1)
                socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)
                request = Request(url, headers={'User-Agent': 'Agemin release checker/1.0'})
                with urlopen(request, timeout=10) as response:
                    # urlopen normally raises HTTPError for 4xx and 5xx; this covers any other handler.
                    if response.status >= 400:
                        issues.append(f'Public submission URL returned HTTP {response.status}: {url}')
            # The host answered with an error status; report that status code.
            except HTTPError as error:
                issues.append(f'Public submission URL returned HTTP {error.code}: {url}')
            # DNS, connection, timeout, and malformed-URL failures all mean the link cannot be reached.
            except (OSError, URLError, AttributeError) as error:
                issues.append(f'Public submission URL is unavailable: {url} ({error})')
    return issues


# Run the audit as a command; --online is the only accepted option.
if __name__ == '__main__':
    unknown = [argument for argument in sys.argv[1:] if argument != '--online']
    # Reject anything else so a typo cannot silently skip the online checks.
    if unknown:
        print(f'Usage: {Path(sys.argv[0]).name} [--online]', file=sys.stderr)
        sys.exit(2)
    found = blockers(check_online='--online' in sys.argv[1:])
    # List every blocker and exit nonzero so release scripts stop here.
    if found:
        print('App Store archive is blocked:')
        for issue in found:
            print(f'- {issue}')
        sys.exit(1)
    print('App Store release metadata checks passed')
