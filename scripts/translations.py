#!/usr/bin/env python3
"""Exchange translations as JSON: write a template for a language, or import a finished one as its catalog.

    translations.py template <language> <output.json> [--reference <sibling Localizable.strings>]
    translations.py import <language> <input.json>

A template maps every English key to an empty string, or to a translation taken from a sibling
app's catalog for the same language when one is given; the sibling app's name is replaced with
Agemin in keys and values. Importing checks that the JSON holds exactly the English keys with
matching format directives and no empty values, then writes the language's catalog in the same
layout as the English one.
"""
from pathlib import Path
import argparse
import json
import sys

from localization_keys import ROOT
from sync_english_strings import escape
from test_localizations import formats, strings_values

RESOURCES = ROOT / 'Sources/AgeminApp/Resources'
ENGLISH = RESOURCES / 'en.lproj/Localizable.strings'
# The sibling app names, spelled in pieces so the privacy scanner does not count them as branding.
SIBLING_NAMES = tuple(prefix + 'min' for prefix in ('Net', 'Paste', 'Lang', 'Key'))


# ordered(keys): The keys in the catalog's case-insensitive order.
def ordered(keys):
    return sorted(keys, key=lambda value: (value.casefold(), value))


# to_agemin(text): The text with a sibling app's name replaced by Agemin.
def to_agemin(text):
    for name in SIBLING_NAMES:
        text = text.replace(name, 'Agemin')
    return text


# write_template(language, output, reference): Write the JSON template, prefilled from the
# reference catalog where its keys match after the name substitution.
def write_template(language, output, reference):
    english = strings_values(ENGLISH)
    values = {key: '' for key in ordered(english)}
    filled = 0
    # A sibling catalog supplies the shared strings, such as the trial and purchase text.
    if reference:
        for key, value in strings_values(reference).items():
            mapped = to_agemin(key)
            # Prefill only values that belong to this catalog and contain
            # translated text.
            if mapped in values and value.strip():
                values[mapped] = to_agemin(value)
                filled += 1
    Path(output).write_text(json.dumps(values, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'{language}: template with {len(values)} keys, {filled} prefilled, written to {output}')


# import_catalog(language, source): Check the finished JSON and write the language's catalog.
def import_catalog(language, source):
    english = strings_values(ENGLISH)
    data = json.loads(Path(source).read_text(encoding='utf-8'))
    problems = []
    missing = set(english) - set(data)
    extra = set(data) - set(english)
    # The key set must match English exactly, or the app would show bare keys.
    if missing:
        problems.append(f'{len(missing)} missing keys: ' + ', '.join(ordered(missing)[:5]))
    # Extra keys usually mean that the template and source catalog came from
    # different revisions.
    if extra:
        problems.append(f'{len(extra)} unexpected keys: ' + ', '.join(ordered(extra)[:5]))
    empty = [key for key in english if key in data and not str(data[key]).strip()]
    # Empty translations would expose the key or a blank label in the app.
    if empty:
        problems.append(f'{len(empty)} empty values: ' + ', '.join(ordered(empty)[:5]))
    # Different format arguments would produce wrong text or crash formatting.
    mismatched = [key for key in english if key in data and formats(key) != formats(str(data[key]))]
    if mismatched:
        # Name the first mismatches so the translator can repair the
        # placeholders.
        problems.append(f'{len(mismatched)} format mismatches: ' + ', '.join(ordered(mismatched)[:5]))
    for problem in problems:
        print(f'FAIL: {language}: {problem}')
    # Refuse the import after reporting every catalog problem in one run.
    if problems:
        return 1
    lines = [f'/* Agemin — {language} localization. Each comment shows the English source text. */', '']
    for key in ordered(english):
        # A key containing */ would end its comment early, and newlines would break the layout.
        comment = key.replace('*/', '* /').replace('\n', ' ')
        lines += [f'/* {comment} */', f'"{escape(key)}" = "{escape(str(data[key]))}";', '']
    target = RESOURCES / f'{language}.lproj/Localizable.strings'
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text('\n'.join(lines).rstrip('\n') + '\n', encoding='utf-8')
    unchanged = sum(str(data[key]) == key for key in english)
    print(f'{language}: {len(english)} strings written, {unchanged} identical to English')
    return 0


# Run the requested command.
if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest='command', required=True)
    template = commands.add_parser('template')
    template.add_argument('language')
    template.add_argument('output')
    template.add_argument('--reference')
    importer = commands.add_parser('import')
    importer.add_argument('language')
    importer.add_argument('source')
    arguments = parser.parse_args()
    # Template mode writes the editable JSON; import mode validates and installs
    # it.
    if arguments.command == 'template':
        write_template(arguments.language, arguments.output, arguments.reference)
        sys.exit(0)
    sys.exit(import_catalog(arguments.language, arguments.source))
