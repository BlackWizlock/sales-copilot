#!/usr/bin/env python3
"""Check application localization keys, format contracts and unlocalized messages.

Application state must use L10n.string/format; SwiftUI's implicit literal keys are
also inventoried. Client values, numeric/time-only labels, model prompts and
machine protocols are deliberately preserved. --runtime exercises both catalogs
without changing the installed application or the user's language preference.
"""
import argparse
import collections
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
ENTRY = re.compile(r'"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;')
CYRILLIC = re.compile('[А-Яа-яЁё]')
UI_CALL = re.compile(r'\b(?:Text|Button|Label|Toggle|Picker|GroupBox|Section|DisclosureGroup|ProgressView|TextField|SecureField|Menu|Link|NSLocalizedString|LocalizedStringKey|help|accessibilityLabel|alert)\s*\(\s*$')
L10N_CALL = re.compile(r'\bL10n\.(string|format)\s*\(\s*$')
MESSAGE_SITE = re.compile(r'(?:\b(?:error|status|speakerStatus|messageText|informativeText)\s*=|CopilotError\.message\(|onError\?\(|addButton\(withTitle:)\s*$')
MACHINE_FILES = {'MCPServer.swift': 'stdio protocol', 'KeychainAccess.swift': 'Keychain adapter', 'UpdateSupport.swift': 'separately compiled update helper'}

def decode(value):
    return json.loads('"' + value + '"')

def expression_end(source, index):
    depth = 1
    while index < len(source):
        if source[index] == '"':
            index = string_end(source, index)
            continue
        if source[index] == '(':
            depth += 1
        elif source[index] == ')':
            depth -= 1
            if not depth:
                return index + 1
        index += 1
    raise ValueError('Unclosed Swift interpolation')

def string_end(source, index):
    index += 1
    while index < len(source):
        if source[index] == '"':
            return index + 1
        if source.startswith('\\(', index):
            index = expression_end(source, index + 2)
        elif source[index] == '\\':
            index += 2
        else:
            index += 1
    raise ValueError('Unclosed Swift string')

def literals(source):
    index = 0
    while index < len(source):
        if source.startswith('//', index):
            end = source.find('\n', index)
            index = len(source) if end < 0 else end
        elif source.startswith('/*', index):
            end = source.find('*/', index + 2)
            if end < 0:
                raise ValueError('Unclosed Swift comment')
            index = end + 2
        elif source[index] == '"':
            end = string_end(source, index)
            yield index, end, source[index + 1:end - 1]
            index = end
        else:
            index += 1

def inventory():
    keys, formats, failures = set(), set(), []
    preserved = collections.Counter()
    for path in sorted((ROOT / 'Sources' / 'AxisCopilot').glob('*.swift')):
        if path.name in MACHINE_FILES or 'Verification' in path.name:
            preserved[MACHINE_FILES.get(path.name, 'synthetic diagnostic executable')] += 1
            continue
        source = path.read_text()
        for start, end, raw in literals(source):
            prefix = source[max(0, start - 100):start]
            line = source[source.rfind('\n', 0, start) + 1:source.find('\n', end) if '\n' in source[end:] else len(source)]
            location = f'{path.name}:{source[:start].count(chr(10)) + 1}'
            explicit = L10N_CALL.search(prefix)
            implicit = UI_CALL.search(prefix)
            if explicit or implicit:
                if '\\(' in raw:
                    if explicit or CYRILLIC.search(raw):
                        failures.append(f'{location}: localize the template before interpolating values')
                    else:
                        preserved['client/numeric/time-only interpolated UI label'] += 1
                    continue
                key = decode(raw)
                if re.search('[A-Za-zА-Яа-яЁё]', key):
                    keys.add(key)
                    if explicit and explicit.group(1) == 'format':
                        formats.add(key)
                continue
            if not CYRILLIC.search(raw):
                if MESSAGE_SITE.search(prefix) and re.search(r'[A-Za-z].*\s[A-Za-z]', raw):
                    if path.name == 'App.swift' and '@main enum EntryPoint' in source[:start]:
                        preserved['synthetic CLI diagnostic'] += 1
                    else:
                        failures.append(f'{location}: unlocalized application message {raw!r}')
                continue
            if path.name == 'Localization.swift':
                # Explicit core-error whitelist is itself a catalog key source.
                if 'private static let coreMessageKeys' in source[:start]:
                    keys.add(decode(raw))
                else:
                    preserved['core error parsing markers'] += 1
                continue
            if path.name == 'GroundedSummaryGenerator.swift' and line.lstrip().startswith('system:'):
                preserved['Russian model prompt/schema/matching rule'] += 1
                continue
            if any(marker in line for marker in ('let system =', 'generate(system:', 'let schema:', 'let needsHelp =', 'var chunks = IntelligenceContext.batches')):
                preserved['Russian model prompt/schema/matching rule'] += 1
                continue
            if raw in {'КП', 'Сделка', '[скрыто]'}:
                preserved['machine source ID or sanitization marker'] += 1
                continue
            if path.name == 'BitrixClient.swift' and '"DESCRIPTION": .string(p.summary' in line:
                preserved['CRM export payload annotation'] += 1
                continue
            if path.name == 'App.swift' and raw == 'сто':
                preserved['Russian ASR diagnostic assertion'] += 1
                continue
            failures.append(f'{location}: unlocalized application literal {raw!r}')
    return keys, formats, failures, preserved

# Only %@ is currently used by application templates. Numbered object placeholders
# are accepted for translator reordering; literal percent signs must be escaped.
PLACEHOLDER = re.compile(r'%(?:(\d+)\$)?@|%%')
def format_signature(value):
    implicit, arguments, index = 0, [], 0
    for match in PLACEHOLDER.finditer(value):
        if '%' in value[index:match.start()]:
            raise ValueError('unsupported format placeholder')
        index = match.end()
        if match.group() == '%%':
            continue
        implicit += 1
        arguments.append(int(match.group(1)) if match.group(1) else implicit)
    if '%' in value[index:]:
        raise ValueError('unescaped percent sign')
    return sorted(arguments)

def read_catalog(language):
    path = ROOT / 'Resources' / f'{language}.lproj' / 'Localizable.strings'
    pairs = [(decode(k), decode(v)) for k, v in ENTRY.findall(path.read_text())]
    duplicates = [key for key, count in collections.Counter(k for k, _ in pairs).items() if count > 1]
    if duplicates:
        raise ValueError(f'{language}: duplicate keys {duplicates}')
    return dict(pairs)

def runtime_checks():
    with tempfile.TemporaryDirectory(prefix='axis-l10n-check-') as temporary:
        folder = pathlib.Path(temporary)
        bundle = folder / 'Synthetic.bundle'
        bundle.mkdir()
        for language in ('ru', 'en'):
            shutil.copytree(ROOT / 'Resources' / f'{language}.lproj', bundle / f'{language}.lproj')
        harness = folder / 'Checks.swift'
        harness.write_text(r'''import Foundation
@main struct Checks {
    static func main() {
        let bundle = Bundle(path: CommandLine.arguments[1])!
        precondition(L10n.languageCode(selection: "en") == "en")
        precondition(L10n.languageCode(selection: "ru") == "ru")
        precondition(L10n.string("Новая встреча", language: "en", bundle: bundle) == "New meeting")
        precondition(L10n.string("Новая встреча", language: "ru", bundle: bundle) == "Новая встреча")
        let client = "Клиент: 100% / %@ / \"quote\" / Русский"
        let en = L10n.format("Сделка №%@ · %@", "42", client, language: "en", bundle: bundle)
        let ru = L10n.format("Сделка №%@ · %@", "42", client, language: "ru", bundle: bundle)
        precondition(en == "Deal #42 · " + client && ru == "Сделка №42 · " + client)
        precondition(L10n.string(client, language: "en", bundle: bundle) == client)
        let external = NSError(domain: "SyntheticExternalProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "Новая встреча"])
        precondition(L10n.error(external) == "Новая встреча")
        print("PASS: RU/EN catalogs, dynamic arguments unchanged, unknown data and external errors preserved; no preference writes")
    }
}
''')
        executable = folder / 'checks'
        subprocess.run(['xcrun', 'swiftc', str(ROOT / 'Sources/AxisCopilot/Localization.swift'), str(harness), '-o', str(executable)], check=True, timeout=90)
        subprocess.run([str(executable), str(bundle)], check=True, timeout=15)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--inventory', action='store_true')
    parser.add_argument('--runtime', action='store_true')
    args = parser.parse_args()
    keys, formats, failures, preserved = inventory()
    if args.inventory:
        print(json.dumps(sorted(keys), ensure_ascii=False, indent=2))
        return
    for language in ('ru', 'en'):
        entries = read_catalog(language)
        missing = sorted(keys - entries.keys())
        empty = sorted(key for key in keys & entries.keys() if not entries[key].strip())
        for key in missing:
            failures.append(f'{language}: missing {key!r}')
        for key in empty:
            failures.append(f'{language}: empty {key!r}')
        for key in formats & entries.keys():
            try:
                if format_signature(key) != format_signature(entries[key]):
                    failures.append(f'{language}: format arguments differ for {key!r}')
            except ValueError as error:
                failures.append(f'{language}: {key!r}: {error}')
        print(f'{language}: {len(keys) - len(missing)}/{len(keys)} application keys, {len(formats)} checked format templates; missing {len(missing)}, empty {len(empty)}')
    for reason, count in sorted(preserved.items()):
        print(f'Preserved {count}: {reason}')
    print('External system/provider errors and persisted client/generated text keep their original language. This is a source/catalog check, not native UI verification.')
    for failure in failures:
        print('FAIL ' + failure)
    if failures:
        sys.exit(1)
    if args.runtime:
        runtime_checks()

if __name__ == '__main__':
    main()
