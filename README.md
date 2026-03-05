# CPU Maximize (Auto Background Optimizer)

`bg_boost.sh` is now a fully automatic, non-interactive optimizer for Termux (Android).

It runs without menu, without webhooks, and without manual package input. The script automatically scans currently running background apps and applies optimization continuously.

## What It Does
- Automatically scans running app processes
- Detects current foreground app and avoids tuning it
- Optimizes background apps with `renice` and `oom_score_adj`
- Applies safety mode when CPU/RAM usage is high
- Writes runtime state to `state/bg_boost.state`
- Writes activity logs to `logs/bg_boost.log`

## Requirements
- Android (Termux environment)
- Root access (`su`)
- Commands: `su`, `ps`, `pidof`, `awk`, `sed`, `renice`

## Project Files
- `bg_boost.sh`: main automatic optimizer
- `install.sh`: setup helper
- `config/bg_boost.env`: optional runtime config overrides
- `logs/bg_boost.log`: runtime logs
- `state/bg_boost.state`: latest cycle state

## Installation
```bash
pkg update -y
pkg install -y git python
```

Clone project:
```bash
git clone https://github.com/xiesz69/cpu-maximize.git
cd cpu-maximize
chmod +x bg_boost.sh install.sh
```

Optional setup helper:
```bash
./install.sh
```

## Usage
Run directly (default command = `run`):
```bash
./bg_boost.sh
```

Run as background daemon:
```bash
./bg_boost.sh start
```

Stop daemon:
```bash
./bg_boost.sh stop
```

Check status and last cycle:
```bash
./bg_boost.sh status
```

Run one optimization cycle only:
```bash
./bg_boost.sh once
```

## Optional Configuration
Edit `config/bg_boost.env` to override defaults.

Supported variables:
```bash
SCAN_INTERVAL_SEC=2
TARGET_NICE=-10
TARGET_OOM_ADJ=-700
SAFE_CPU_PERCENT=90
SAFE_RAM_PERCENT=92
SAFE_TARGET_NICE=-2
SAFE_TARGET_OOM_ADJ=0
MAX_APPS_PER_CYCLE=40
IGNORE_PREFIXES="android,com.android"
```

Notes:
- `IGNORE_PREFIXES` is comma-separated.
- Packages matching these prefixes are skipped from optimization.

## Behavior Details
- Script scans package-like process names from `ps -A`.
- Foreground app is detected via `dumpsys` and skipped.
- If CPU or RAM exceeds safety thresholds, script uses safer tuning values.
- No UI/menu prompts are used.

## GitHub Sync
If you use `/root/github_sync.py`:
```bash
cd cpu-maximize
python3 /root/github_sync.py
```

## Important Notes
- Root permissions are required; without root, tuning will fail.
- Android vendor kernels can limit or ignore some tuning operations.
- Do not hardcode GitHub tokens in scripts.
