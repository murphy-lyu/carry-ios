#!/usr/bin/env python3
"""Run synthetic HTTP fixtures and native tests in one supervised lifetime.
No real account, Apple credentials, trips or files are used by the fixtures.
"""
import argparse
import os
from pathlib import Path
import shutil
import socket
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--node', default=shutil.which('node'))
    parser.add_argument('--device', required=True)
    parser.add_argument('--rounds', type=int, default=2, choices=[1, 2])
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--derived-data', default='/tmp/CarryAccountReplicaQA')
    parser.add_argument('--packages', default='/tmp/CarryAccountPackages')
    args = parser.parse_args()
    if not args.node:
        raise SystemExit('Node 24+ required')
    major = subprocess.check_output([args.node, '-p', 'process.versions.node.split(".")[0]'], text=True).strip()
    if int(major) < 24:
        raise SystemExit('Node 24+ required')
    root = Path(__file__).resolve().parents[2]
    args.output.mkdir(parents=True, exist_ok=False)
    service = root / 'scripts/carry-account-service'
    fixtures = [(8891, 'graph-qa-server.mjs', 'CARRY_GRAPH_QA'),
                (8892, 'asset-qa-server.mjs', 'CARRY_ASSET_QA'),
                (8893, 'asset-download-qa-server.mjs', 'CARRY_ASSET_DOWNLOAD_QA')]
    processes, logs = [], []
    try:
        for port, script, flag in fixtures:
            with socket.socket() as probe:
                probe.settimeout(0.2)
                if probe.connect_ex(('127.0.0.1', port)) == 0:
                    raise RuntimeError(f'Port {port} already occupied; no process was stopped')
            log = (args.output / f'fixture-{port}.log').open('w')
            logs.append(log)
            env = dict(os.environ, **{flag: 'synthetic-only'})
            process = subprocess.Popen([args.node, script], cwd=service, env=env, stdout=log, stderr=subprocess.STDOUT)
            processes.append(process)
            deadline = time.monotonic() + 30
            while True:
                if process.poll() is not None:
                    raise RuntimeError(f'Fixture {port} exited: inspect its log')
                with socket.socket() as probe:
                    probe.settimeout(0.2)
                    if probe.connect_ex(('127.0.0.1', port)) == 0:
                        break
                if time.monotonic() > deadline:
                    raise RuntimeError(f'Fixture {port} did not start')
                time.sleep(0.1)
        for number in range(1, args.rounds + 1):
            print(f'Native QA round {number}/{args.rounds}', flush=True)
            command = ['xcodebuild', 'test', '-project', 'Carry.xcodeproj', '-scheme', 'CarryAutomationTests',
                       '-configuration', 'Debug', '-destination', f'platform=iOS Simulator,id={args.device}',
                       '-derivedDataPath', args.derived_data, '-clonedSourcePackagesDirPath', args.packages,
                       '-skip-testing:CarryAutomationTests/RelayRoundTripTests',
                       '-resultBundlePath', str(args.output / f'round-{number}.xcresult'), 'SWIFT_EMIT_LOC_STRINGS=NO']
            with (args.output / f'round-{number}.log').open('w') as log:
                completed = subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT)
            if completed.returncode:
                raise RuntimeError(f'Round {number} failed: inspect its log and xcresult')
            print(f'Native QA round {number} passed', flush=True)
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
        for process in processes:
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        for log in logs:
            log.close()


if __name__ == '__main__':
    main()
