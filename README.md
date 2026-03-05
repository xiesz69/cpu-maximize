# Background App Booster for Termux (Android 12-15)

Root-first Bash daemon for prioritizing selected apps/games, moderating non-target apps, enforcing CPU/RAM safety ceilings, and sending Discord alerts when monitored apps disappear unexpectedly.

## Requirements
- Android 12-15
- Termux
- Root access (`su`)
- Tools: `pidof`, `ps`, `awk`, `sed`, `renice`, `curl`

## Project Files
- `bg_boost.sh`: main script + interactive menu
- `install.sh`: quick install/setup helper
- `config/priority_apps.conf`: target app list
- `config/bg_boost.env`: runtime settings
- `config/discord_webhooks.conf`: multi webhook list
- `logs/bg_boost.log`: runtime logs
- `state/bg_boost.state`: last cycle state

## Installation
```bash
pkg update -y
pkg install -y curl git python
```

Clone and enter project:
```bash
git clone https://github.com/xiesz69/cpu-maximize.git
cd cpu-maximize
```

Run installer:
```bash
chmod +x install.sh bg_boost.sh
./install.sh
```

## Configuration
Edit target apps:
```bash
nano config/priority_apps.conf
```

Optional Discord webhooks:
```bash
nano config/discord_webhooks.conf
```

## Usage
Interactive menu (recommended):
```bash
./bg_boost.sh menu
```

Direct commands:
```bash
./bg_boost.sh start
./bg_boost.sh stop
./bg_boost.sh status
./bg_boost.sh once
./bg_boost.sh webhooks
```

## Interactive Menu Features
- Live auto-refresh dashboard
- Color health status: green (healthy), yellow (warning), red (critical)
- Live internet speed (download/upload Mbps)
- Scan running app packages and add to target list
- Manual add/remove target apps
- Add/remove/list Discord webhooks
- Send test webhook
- Quick ceiling settings (CPU/RAM)
- Start/stop daemon and run one-cycle tune
- Tail recent logs

## App Config Format
`config/priority_apps.conf`:
```conf
# package_name|mode|cpu_weight|oom_adj
com.your.game|boost|90|-800
com.your.app|boost|85|-700
```

## Webhook Config
`config/discord_webhooks.conf`:
```conf
https://discord.com/api/webhooks/....
https://discord.com/api/webhooks/....
```

`DISCORD_WEBHOOK_URL` in env is still supported (legacy single URL).

## GitHub Sync Script
If you use a local sync script (for example `/root/github_sync.py`), run it from this project directory:
```bash
cd cpu-maximize
python3 /root/github_sync.py
```

## Notes
- Root (`su`) is required for tuning other app processes.
- Android vendor behavior differs; some kernel controls may be ignored.
- Script avoids touching key core system daemons.
- Keep target list focused to reduce thermal throttling and LMKD pressure.
- Do not hardcode tokens in source files.
