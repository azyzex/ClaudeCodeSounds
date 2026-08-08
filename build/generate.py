#!/usr/bin/env python3
"""
Generate the single-file installers from templates plus the standalone notifiers.

The installers are distributed as one file each, because people pipe them
straight from a URL. But the notifier inside each one is also what the desktop
app ships, so it cannot live only inside an installer heredoc or the two copies
drift. The notifiers are therefore real files under notifier/, and this script
injects them into templates/ to produce the installers at the repo root.

    python build/generate.py           regenerate the installers
    python build/generate.py --check   fail if they are out of date

CI runs --check, so a change to a notifier that is not regenerated fails the
build rather than silently shipping a stale installer.
"""

import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# template -> (placeholder, notifier source, generated installer)
TARGETS = [
    (
        'templates/install-claude-sound-alerts.sh.in',
        '@@NOTIFIER_SH@@',
        'notifier/claude-notify.sh',
        'install-claude-sound-alerts.sh',
    ),
    (
        'templates/install-claude-sound-alerts.ps1.in',
        '@@NOTIFIER_PS1@@',
        'notifier/claude-notify.ps1',
        'install-claude-sound-alerts.ps1',
    ),
]


def read(path):
    with io.open(os.path.join(ROOT, path), encoding='utf-8', newline='') as f:
        return f.read()


def render(template_path, placeholder, notifier_path):
    template = read(template_path)
    notifier = read(notifier_path)

    if placeholder not in template:
        raise SystemExit('%s does not contain %s' % (template_path, placeholder))

    # Normalise to LF and drop the trailing newline: the placeholder occupies a
    # whole line, so the surrounding join supplies the line ending.
    notifier = notifier.replace('\r\n', '\n').rstrip('\n')

    # A heredoc terminator or a PowerShell here-string terminator appearing at
    # column 0 inside the notifier would end the block early and produce a
    # broken installer. Nothing legitimate needs those at column 0.
    for bad in ('NOTIFYEOF', "'@"):
        for i, line in enumerate(notifier.split('\n'), 1):
            if line.startswith(bad):
                raise SystemExit(
                    '%s line %d starts with %r, which would terminate the '
                    'embedded block early' % (notifier_path, i, bad)
                )

    return template.replace(placeholder, notifier).replace('\r\n', '\n')


def main():
    check = '--check' in sys.argv
    stale = []

    for template_path, placeholder, notifier_path, out_path in TARGETS:
        rendered = render(template_path, placeholder, notifier_path)
        full = os.path.join(ROOT, out_path)

        current = None
        if os.path.exists(full):
            with io.open(full, encoding='utf-8', newline='') as f:
                current = f.read().replace('\r\n', '\n')

        if current == rendered:
            print('  up to date  %s' % out_path)
            continue

        if check:
            stale.append(out_path)
            print('  STALE       %s' % out_path)
            continue

        with io.open(full, 'w', encoding='utf-8', newline='\n') as f:
            f.write(rendered)
        print('  wrote       %s' % out_path)

    if stale:
        print('')
        print('These installers do not match their template plus notifier:')
        for s in stale:
            print('  %s' % s)
        print('')
        print('Run: python build/generate.py')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
