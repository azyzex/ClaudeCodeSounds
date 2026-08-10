#!/usr/bin/env python3
"""
Install Earshot Bridge, the local link between the browser extension and the
notifier.

    python bridge/install-bridge.py --extension-id <id>
    python bridge/install-bridge.py --uninstall

Native messaging works by the browser reading a small manifest that says which
program to launch and which extension IDs are allowed to launch it. That
allowlist is the security boundary, which is why the ID is required rather than
defaulted: a manifest that trusted any extension would let any extension on your
machine start this.

Nothing here opens a port or starts a service. The browser runs the bridge on
demand and it exits when the browser closes.
"""

import argparse
import json
import os
import shutil
import sys

HOST_NAME = 'com.azyzex.earshot'

# The extension pins its own id by carrying a public key in its manifest, so it
# is the same on every machine and there is nothing to copy. Passing
# --extension-id is still allowed, for a fork or a store build with a different
# key, but nobody should have to.
DEFAULT_EXTENSION_ID = 'gkinjfdcpheaejgdcdmhocpnfianbmpf'
HERE = os.path.dirname(os.path.abspath(__file__))

# Where each browser looks for host manifests. Chromium browsers and Firefox use
# different directories and slightly different manifest keys.
def manifest_dirs():
    home = os.environ.get('HOME') or os.environ.get('USERPROFILE') or ''
    if sys.platform == 'darwin':
        base = os.path.join(home, 'Library', 'Application Support')
        return {
            'chrome':  os.path.join(base, 'Google', 'Chrome', 'NativeMessagingHosts'),
            'edge':    os.path.join(base, 'Microsoft Edge', 'NativeMessagingHosts'),
            'chromium':os.path.join(base, 'Chromium', 'NativeMessagingHosts'),
            'firefox': os.path.join(base, 'Mozilla', 'NativeMessagingHosts'),
        }
    if os.name == 'nt':
        # Windows keeps the path in the registry rather than a fixed directory,
        # so the manifest lives beside the bridge and is registered below.
        return {'windows': os.path.join(home, '.earshot')}
    base = os.path.join(home, '.config')
    return {
        'chrome':  os.path.join(base, 'google-chrome', 'NativeMessagingHosts'),
        'chromium':os.path.join(base, 'chromium', 'NativeMessagingHosts'),
        'edge':    os.path.join(base, 'microsoft-edge', 'NativeMessagingHosts'),
        'firefox': os.path.join(home, '.mozilla', 'native-messaging-hosts'),
    }


def launcher_path():
    """A small wrapper, so the manifest points at something executable.

    The manifest must name a program the browser can run directly. A .py file
    is not that on Windows, and is only that on Unix if it is executable and has
    a shebang, so a wrapper is the portable answer.
    """
    target = os.path.join(HERE, 'earshot-bridge.py')
    if os.name == 'nt':
        path = os.path.join(HERE, 'earshot-bridge.bat')
        with open(path, 'w', encoding='utf-8') as f:
            f.write('@echo off\r\n"%s" "%s" %%*\r\n' % (sys.executable, target))
        return path
    path = os.path.join(HERE, 'earshot-bridge.sh')
    with open(path, 'w', encoding='utf-8') as f:
        f.write('#!/bin/sh\nexec "%s" "%s" "$@"\n' % (sys.executable, target))
    os.chmod(path, 0o755)
    return path


def manifest_for(browser, extension_id, program):
    base = {
        'name': HOST_NAME,
        'description': 'Earshot Bridge, by Azyzex',
        'path': program,
        'type': 'stdio',
    }
    if browser == 'firefox':
        # Firefox allowlists by extension id, Chromium by an origin URL.
        base['allowed_extensions'] = [extension_id]
    else:
        base['allowed_origins'] = ['chrome-extension://%s/' % extension_id]
    return base


def install(extension_id):
    program = launcher_path()
    written = []
    for browser, directory in manifest_dirs().items():
        try:
            os.makedirs(directory, exist_ok=True)
            path = os.path.join(directory, HOST_NAME + '.json')
            with open(path, 'w', encoding='utf-8') as f:
                json.dump(manifest_for(browser, extension_id, program), f, indent=2)
            written.append((browser, path))
        except Exception as exc:
            print('  could not write the %s manifest: %s' % (browser, exc))

    if os.name == 'nt':
        # Chromium on Windows finds the manifest through the registry.
        try:
            import winreg
            path = written[0][1] if written else ''
            for key in (r'Software\Google\Chrome\NativeMessagingHosts',
                        r'Software\Microsoft\Edge\NativeMessagingHosts'):
                with winreg.CreateKey(winreg.HKEY_CURRENT_USER,
                                      key + '\\' + HOST_NAME) as handle:
                    winreg.SetValueEx(handle, None, 0, winreg.REG_SZ, path)
            print('  registered for Chrome and Edge')
        except Exception as exc:
            print('  could not write the registry entries: %s' % exc)

    for browser, path in written:
        print('  %-9s %s' % (browser, path))
    if not written:
        print('  nothing was installed')
        return 1
    print('')
    print('  Turn on "Send to the desktop app" in the extension popup.')
    return 0


def uninstall():
    removed = 0
    for _, directory in manifest_dirs().items():
        path = os.path.join(directory, HOST_NAME + '.json')
        if os.path.exists(path):
            try:
                os.remove(path)
                removed += 1
            except Exception:
                pass
    for name in ('earshot-bridge.bat', 'earshot-bridge.sh'):
        path = os.path.join(HERE, name)
        if os.path.exists(path):
            os.remove(path)
    if os.name == 'nt':
        try:
            import winreg
            for key in (r'Software\Google\Chrome\NativeMessagingHosts',
                        r'Software\Microsoft\Edge\NativeMessagingHosts'):
                try:
                    winreg.DeleteKey(winreg.HKEY_CURRENT_USER, key + '\\' + HOST_NAME)
                except FileNotFoundError:
                    pass
        except Exception:
            pass
    print('  removed %d manifest(s)' % removed)
    return 0


def main():
    parser = argparse.ArgumentParser(description='Install Earshot Bridge.')
    parser.add_argument('--extension-id',
                        help='the ID shown on chrome://extensions for Earshot for Web')
    parser.add_argument('--uninstall', action='store_true')
    args = parser.parse_args()

    print('')
    print('Earshot Bridge')
    print('--------------')

    if args.uninstall:
        return uninstall()

    extension_id = args.extension_id or DEFAULT_EXTENSION_ID
    if extension_id == DEFAULT_EXTENSION_ID:
        print('  using the published extension id')
    else:
        print('  using the id you gave: %s' % extension_id)

    if not shutil.which(sys.executable):
        print('  could not find the python that is running this')
        return 1

    return install(extension_id)


if __name__ == '__main__':
    sys.exit(main())
