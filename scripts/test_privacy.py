#!/usr/bin/env python3
"""Check privacy, sandbox, identity, and release metadata without launching the app."""
from pathlib import Path
import plistlib

ROOT = Path(__file__).resolve().parent.parent
# Load the metadata, policies, license, and the sources whose behavior the policy describes.
info = plistlib.loads((ROOT / 'AgeminInfo.plist').read_bytes())
entitlements = plistlib.loads((ROOT / 'AgeminApp.entitlements').read_bytes())
manifest = plistlib.loads((ROOT / 'Sources/AgeminApp/Resources/PrivacyInfo.xcprivacy').read_bytes())
policy = (ROOT / 'PRIVACY.md').read_text()
bundled_policy = (ROOT / 'Sources/AgeminApp/Resources/PRIVACY.md').read_text()
project = (ROOT / 'Agemin.xcodeproj/project.pbxproj').read_text()
readme = (ROOT / 'README.md').read_text()
license_text = (ROOT / 'LICENSE').read_text()
privacy_source = (ROOT / 'Sources/AgeminApp/PrivacyPolicy.swift').read_text()
app_source = (ROOT / 'Sources/AgeminApp/AgeminApp.swift').read_text()
key_store = (ROOT / 'Sources/AgeminApp/KeyStore.swift').read_text()
pro_source = (ROOT / 'Sources/AgeminApp/ProStore.swift').read_text()
all_sources = '\n'.join(path.read_text() for path in (ROOT / 'Sources/AgeminApp').glob('*.swift'))

# The in-app policy window shows the bundled copy, found under SwiftPM or the Xcode bundle,
# in a native panel that stays usable during the app's modal alerts and open panels.
assert policy == bundled_policy, 'Bundled and repository privacy policies differ'
assert 'final class PrivacyPolicyController' in privacy_source
assert 'Bundle.module.url(forResource: "PRIVACY", withExtension: "md")' in privacy_source
assert 'Bundle.main.url(forResource: "PRIVACY", withExtension: "md")' in privacy_source
assert 'panel.worksWhenModal = true' in privacy_source
assert '.fullSizeContentView' in privacy_source and 'NSVisualEffectView()' in privacy_source
assert 'NSTextView.scrollableTextView()' in privacy_source
# The in-app privacy command opens that window rather than sending the user to the website.
assert 'PrivacyPolicyController.shared.show()' in app_source
assert 'NSWorkspace.shared.open(AppLinks.privacyPolicy)' not in app_source
# The purchase panel keeps the large control size for its buttons.
assert '.controlSize(.large)' in pro_source
# The purchase panel must declare its legal links; reachability is checked separately.
assert 'Link(localized("Terms of Use (EULA)"), destination: AppLinks.termsOfUse)' in pro_source
assert 'Link(localized("Privacy Policy"), destination: AppLinks.privacyPolicy)' in pro_source
assert 'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/' in (ROOT / 'Sources/AgeminApp/BuildEdition.swift').read_text()
# The policy must disclose that Apple, not the app, handles purchases.
assert 'Apple processes Agemin Pro purchases' in policy
# The license is PolyForm Strict with the two added permissions, and the README names the same one.
assert license_text.startswith('# PolyForm Strict License 1.0.0\n')
assert 'Additional Permission for Personal Modification' in license_text
assert 'Additional Permission for Contributions' in license_text
assert 'Agemin' in license_text
assert 'PolyForm Strict License 1.0.0' in readme and 'Elastic License' not in readme
# Info.plist, the entitlements, and the privacy manifest must describe an offline sandboxed
# utility that implements its own file encryption.
assert info['ITSAppUsesNonExemptEncryption'] is True
assert info['LSApplicationCategoryType'] == 'public.app-category.utilities'
assert entitlements['com.apple.security.app-sandbox'] is True
assert entitlements['com.apple.security.files.user-selected.read-write'] is True
assert entitlements['com.apple.security.files.bookmarks.app-scope'] is True
assert not any(key.startswith('com.apple.security.network') for key in entitlements), 'Agemin needs no network access'
assert manifest['NSPrivacyTracking'] is False
assert manifest['NSPrivacyCollectedDataTypes'] == []
# UserDefaults access needs a declared reason; CA92.1 covers data only the app itself reads.
# File metadata of user-chosen files needs 3B52.1.
reasons = {item['NSPrivacyAccessedAPIType']: item['NSPrivacyAccessedAPITypeReasons'] for item in manifest['NSPrivacyAccessedAPITypes']}
assert 'CA92.1' in reasons['NSPrivacyAccessedAPICategoryUserDefaults']
assert '3B52.1' in reasons['NSPrivacyAccessedAPICategoryFileTimestamp']
# All three configurations carry the identity settings, and the store edition exists.
assert project.count('PRODUCT_BUNDLE_IDENTIFIER = tools.min.agemin;') == 3
assert project.count('AGEMIN_DISPLAY_NAME = Agemin;') == 3
assert 'AGEMIN_APP_STORE' in project

# Check for scoped folder access and reject direct networking or command execution.
assert '.withSecurityScope' in key_store and 'startAccessingSecurityScopedResource()' in key_store
assert 'Forget Folder Access' in app_source and 'forgetAccess()' in key_store
assert 'URLSession' not in all_sources and 'Process(' not in all_sources and 'NSAppleScript' not in all_sources

# Keep the sibling apps' names and identifiers out of this repository.
peer_markers = ('Net' + 'min', 'Paste' + 'min', 'Lang' + 'min', 'Key' + 'min', 'tools.min.net', 'tools.min.paste', 'tools.min.lang', 'tools.min.key')
text_suffixes = {
    '.entitlements', '.json', '.md', '.pbxproj', '.plist', '.py', '.swift',
    '.strings', '.xcprivacy', '.xcscheme',
}
stale_branding = []
# Walk the whole checkout; the filters below limit the scan to known text files.
for path in ROOT.rglob('*'):
    relative = path.relative_to(ROOT)
    # This script spells the markers out, so it is the one file allowed to contain them.
    if path.resolve() == Path(__file__).resolve():
        continue
    # Skip build and release output, git metadata, and the ignored private directory.
    if not path.is_file() or {'.git', '.build', 'build', 'dist', '__pycache__', 'private'} & set(relative.parts):
        continue
    # Read only known text files; binaries such as the icon are skipped.
    if path.suffix not in text_suffixes and path.name not in {'.gitignore', 'LICENSE'}:
        continue
    text = path.read_text()
    for marker in peer_markers:
        # A marker in a file name counts as much as one in its content.
        if marker in str(relative) or marker in text:
            stale_branding.append(f'{relative}: {marker}')
assert not stale_branding, 'Peer app branding found:\n' + '\n'.join(stale_branding)

print('Agemin privacy, sandbox, identity, and App Store metadata passed')
