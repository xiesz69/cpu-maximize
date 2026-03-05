# cpu-maximize Installation Guide (Termux)

This guide helps you install and run `cpu-maximize` quickly on Android (Termux).

## 1) Install prerequisites
```bash
pkg update -y
pkg install -y curl git python
```

## 2) Clone/download project
If not downloaded yet:
```bash
git clone https://github.com/xiesz69/cpu-maximize.git
cd cpu-maximize
```

If already downloaded:
```bash
cd cpu-maximize
```

## 3) Run one-command installer
```bash
chmod +x install.sh bg_boost.sh
./install.sh
```

## 4) Configure target apps and webhooks
Edit app list:
```bash
nano config/priority_apps.conf
```

Optional Discord webhooks:
```bash
nano config/discord_webhooks.conf
```

## 5) Start and manage
Interactive menu (recommended):
```bash
./bg_boost.sh menu
```

Direct commands:
```bash
./bg_boost.sh start
./bg_boost.sh status
./bg_boost.sh stop
```

## 6) Sync/update to GitHub with Python script
Configure sync (optional):
```bash
nano config/github_sync.env
```

Dry-run first:
```bash
python3 github_sync.py --dry-run
```

Push/sync:
```bash
python3 github_sync.py
```

Optional with token in command:
```bash
python3 github_sync.py --repo-url "https://github.com/xiesz69/cpu-maximize.git" --token "<YOUR_TOKEN>"
```

## Notes
- Root (`su`) is required for tuning other app processes.
- Keep app target list small to reduce thermal throttling.
- Do not hardcode tokens in source files.
