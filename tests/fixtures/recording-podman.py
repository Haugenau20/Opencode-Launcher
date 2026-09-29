#!/usr/bin/env python3
"""Minimal engine for testing the REAL podman-compose command construction."""
import json
import os
import sys

args = sys.argv[1:]
with open(os.environ['OCL_PROVIDER_ARGV_LOG'], 'a') as stream:
    stream.write(json.dumps({
        'args': args,
        'host': os.environ.get('CONTAINER_HOST'),
        'connection': os.environ.get('CONTAINER_CONNECTION'),
    }) + '\n')
if not args or args[0] != '--remote=false':
    print('global --remote=false must be the first argument', file=sys.stderr)
    sys.exit(125)
args = args[1:]
if any(arg.startswith('--remote') for arg in args):
    print('global --remote option appeared after the subcommand', file=sys.stderr)
    sys.exit(125)
command = args[0]
if command == '--version':
    print('podman version 5.4.2')
elif command == 'inspect':
    print('[]')
elif command == 'ps' and any('json' in arg for arg in args):
    print('[]')
elif command == 'run':
    print('recorded-container-id')
elif command == 'logs':
    print('fixture log line')
# Other operations succeed without side effects; their complete argument
# vectors remain in the log for assertions against the real provider.
