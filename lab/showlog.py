#!/usr/bin/env python3
"""Prints the tail of a PowerShell transcript from the share (UTF-8 with BOM or UTF-16), without the header noise.
usage: showlog.py <path> [lines]"""
import sys
path = sys.argv[1]
n = int(sys.argv[2]) if len(sys.argv) > 2 else 60
b = open(path, 'rb').read()
t = b.decode('utf-16') if b[:2] in (b'\xff\xfe', b'\xfe\xff') else b.decode('utf-8-sig', 'replace')
skip = ('Transcript', 'Windows PowerShell', 'Start time', 'Username', 'RunAs', 'Configuration', 'Machine', 'Host Application',
        'Process ID', 'PSVersion', 'WSMan', 'SerializationVersion', 'CLRVersion', 'BuildVersion', 'PSCompatible', 'PSRemoting',
        'PSEdition', 'End time')
lines = [l for l in t.splitlines() if l.strip() and not l.startswith('***') and not l.startswith(skip)]
print('\n'.join(lines[-n:]))
