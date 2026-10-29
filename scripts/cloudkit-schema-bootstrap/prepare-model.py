#!/usr/bin/env python3
"""Copy only the native model export from a selected simulator, never a user DB."""
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--simulator", required=True, help="Dedicated simulator that ran CloudKitModelExportTests")
args = parser.parse_args()
container = subprocess.check_output([
    "xcrun", "simctl", "get_app_container", args.simulator,
    "app.nevestudio.carry", "data",
], text=True).strip()
source = Path(container) / "Documents/CarrySchema.generated.mom"
if not source.is_file():
    parser.error("Run CloudKitModelExportTests on this simulator first")
destination = Path(__file__).resolve().parent / "Resources/CarrySchema.generated.mom"
destination.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(source, destination)
print(f"Native model: {destination.stat().st_size} bytes")
print(f"SHA256: {hashlib.sha256(destination.read_bytes()).hexdigest()}")
