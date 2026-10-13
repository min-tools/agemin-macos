#!/usr/bin/env python3
"""Collect the English source strings that Agemin localizes at runtime."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'Sources/AgeminApp'

# A Swift string literal body, with escaped characters kept for unescape().
STRING = r'"((?:[^"\\]|\\.)*)"'
# Direct calls and the custom controls that pass their literal arguments through localized().
DIRECT = re.compile(r'(?:localized|localizedFormat|SectionLabel|KeyCap|CardHeading)\(\s*' + STRING)
# Labeled view arguments whose literal text the receiving view localizes itself.
LABELLED = re.compile(r'(?<![A-Za-z])(?:title|subtitle|help|placeholder|summary|detail|text|prompt|buttonTitle|label)\s*:\s*' + STRING)
# Literal segmented-control option lists; each entry is localized when displayed.
OPTIONS = re.compile(r'options:\s*\[((?:\s*' + STRING + r'\s*,?)+)\]')
# Files whose string literals are protocol constants, not interface text.
SKIPPED_LABELLED = {'AgeFormat.swift', 'AgeRecipients.swift', 'AgeIdentities.swift', 'OpenSSHKey.swift', 'RSAOAEP.swift', 'Scrypt.swift', 'Blowfish.swift', 'BlowfishTables.swift', 'Bech32.swift', 'BigUInt.swift', 'ByteIO.swift', 'AgeEngine.swift', 'Curve25519Conversion.swift'}


# unescape(text): Decode quotes, backslashes, and newlines in a captured Swift literal body.
def unescape(text):
    return text.replace(r'\"', '"').replace(r'\\', '\\').replace(r'\n', '\n')


# source_keys(): Collect literals matching the localization and control patterns above.
# This text scan also sees comments and does not evaluate computed Swift strings.
def source_keys():
    keys = set()
    for path in sorted(SOURCE.glob('*.swift')):
        text = path.read_text(encoding='utf-8')
        keys.update(unescape(match.group(1)) for match in DIRECT.finditer(text))
        # The format and key files hold protocol constants such as stanza types and key labels;
        # only their localized() calls are interface text, so labeled arguments there are skipped.
        if path.name in SKIPPED_LABELLED:
            continue
        keys.update(unescape(match.group(1)) for match in LABELLED.finditer(text))
        # An option list holds several literals in one match; split them apart.
        for match in OPTIONS.finditer(text):
            keys.update(unescape(value) for value in re.findall(STRING, match.group(1)))
    keys.discard('')
    return keys
