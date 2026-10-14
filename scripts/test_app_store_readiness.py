#!/usr/bin/env python3
"""Ensure the offline App Store release audit is clear."""
from collections import Counter
from pathlib import Path
import re

from check_app_store import blockers, valid_release_version

ROOT = Path(__file__).resolve().parent.parent


# Xcode object identifiers must be unique. A repeated definition can silently point a source
# build entry at an unrelated plist or entitlement and leave the project malformed.
project = (ROOT / 'Agemin.xcodeproj/project.pbxproj').read_text()
object_ids = re.findall(r'^\s*([0-9A-F]{24})(?: /\*.*?\*/)? =', project, re.MULTILINE)
duplicates = sorted(identifier for identifier, count in Counter(object_ids).items() if count > 1)
assert duplicates == [], f'Duplicate Xcode object IDs: {duplicates}'

# Every app source must be referenced by the project and belong to its Sources build phase.
source_names = {path.name for path in (ROOT / 'Sources/AgeminApp').glob('*.swift')}
referenced_names = set(re.findall(r'path = Sources/AgeminApp/([^;]+\.swift);', project))
build_entries = dict(re.findall(
    r'^\s*([0-9A-F]{24}) /\* ([^*]+\.swift) in Sources \*/ =', project, re.MULTILINE
))
sources_phase = re.search(
    r'/\* Begin PBXSourcesBuildPhase section \*/.*?files = \((.*?)\);', project, re.DOTALL
)
assert sources_phase is not None, 'Missing Xcode Sources build phase'
source_build_ids = set(re.findall(r'[0-9A-F]{24}', sources_phase.group(1)))
built_names = {name for identifier, name in build_entries.items() if identifier in source_build_ids}
assert referenced_names == source_names, (
    f'Xcode source references differ: missing={sorted(source_names - referenced_names)}, '
    f'extra={sorted(referenced_names - source_names)}'
)
assert built_names == source_names, (
    f'Xcode Sources phase differs: missing={sorted(source_names - built_names)}, '
    f'extra={sorted(built_names - source_names)}'
)

# Monthly releases and patches remain valid even when built in a later month.
for version, build in [('26.9', '2026092600'), ('26.9.1', '2026100100'), ('26.10', '2026100700'), ('27.1', '2027010100')]:
    assert valid_release_version(version, build), (version, build)

# Reject the retired date format, bad months and patch numbers, extra parts, and malformed or
# impossible build dates.
for version in ['2026.09.26', '26.09', '26.0', '26.13', '26.9.0', '26.9.01', '26.9.1.1', '', None]:
    assert not valid_release_version(version, '2026092600'), version
for build in ['20260926', '20260926000', '2026130100', '2026023000', '20260926ab', '', None]:
    assert not valid_release_version('26.9', build), build

# The real project must have no offline blockers; the message lists every one found.
found = blockers()
assert found == [], '\n'.join(found)
print('App Store offline release audit passed')
