#!/usr/bin/env python3
"""Preserve both GRUB command lines without executing shell configuration."""
from pathlib import Path
import re
import shlex
import sys

KEYS = {
    'zswap.enabled', 'zswap.compressor', 'zswap.max_pool_percent', 'zswap.zpool',
    'zswap.shrinker_enabled', 'mitigations', 'audit', 'nmi_watchdog', 'nowatchdog',
    'split_lock_detect',
}

def transform(text, mode):
    parsed = {}
    lines = text.splitlines(keepends=True)
    for index, line in enumerate(lines):
        match = re.match(r'^\s*(GRUB_CMDLINE_LINUX(?:_DEFAULT)?)\s*=(.*)$', line.rstrip('\n'))
        if not match:
            continue
        key, rhs = match.groups()
        if key in parsed:
            raise ValueError(f'atribuição duplicada: {key}')
        values = shlex.split(rhs, comments=True)
        if len(values) != 1 or '$' in values[0] or '`' in values[0]:
            raise ValueError(f'formato de {key} não suportado; arquivo preservado')
        parsed[key] = (index, shlex.split(values[0]))
    if mode == 'validate':
        return text
    common = ['mitigations=off', 'audit=0', 'nmi_watchdog=0', 'nowatchdog', 'split_lock_detect=off']
    if mode == 'zswap':
        common[:0] = ['zswap.enabled=1', 'zswap.compressor=lz4', 'zswap.max_pool_percent=35', 'zswap.shrinker_enabled=1']
    elif mode == 'zram':
        common.insert(0, 'zswap.enabled=0')
    else:
        raise ValueError('modo inválido')
    for key, (index, tokens) in parsed.items():
        tokens = [t for t in tokens if t.split('=', 1)[0] not in KEYS]
        if key == 'GRUB_CMDLINE_LINUX':
            tokens += common
        lines[index] = f'{key}={shlex.quote(shlex.join(tokens))}\n'
    if 'GRUB_CMDLINE_LINUX' not in parsed:
        if lines and not lines[-1].endswith('\n'):
            lines[-1] += '\n'
        lines.append(f'GRUB_CMDLINE_LINUX={shlex.quote(shlex.join(common))}\n')
    return ''.join(lines)

if __name__ == '__main__':
    path, mode = Path(sys.argv[1]), sys.argv[2]
    try:
        result = transform(path.read_text(encoding='utf-8'), mode)
        if mode != 'validate':
            sys.stdout.write(result)
    except (ValueError, OSError) as error:
        print(f'GRUB: {error}', file=sys.stderr)
        sys.exit(1)
