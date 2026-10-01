# Wi-Fi Drop Monitor

Are you tired of your fiber connection randomly disconnecting? Not sure if the problem is your PC, Wi-Fi, router, or ISP?

Run this Windows monitor 24/7. It checks the connection twice per second and keeps a live dashboard with outage times, duration, failed targets, latency, and the likely cause.

## What it does

- Detects drops as short as one second.
- Checks three public targets and the local router in parallel.
- Uses TCP confirmation before calling an outage an ISP failure.
- Separates probe noise, local Wi-Fi/router failures, and upstream outages.
- Shows live status, history, latency, and the connected Wi-Fi name.
- Provides a mobile-friendly public HTTPS link through Cloudflare Quick Tunnel.
- Stores monitoring data locally in `%LOCALAPPDATA%\WifiConnectivityMonitor`.

## Run it

1. Download or clone the repository on a Windows PC.
2. Run **Set Dashboard Password.cmd** once.
3. Run **Start WiFi Monitor.cmd**.

Use **Open WiFi Dashboard.cmd** to reopen the dashboard and **Stop WiFi Monitor.cmd** to stop it. Run **Enable Start at Login.cmd** once if the monitor should start automatically with Windows.

The public URL is temporary and changes when the Cloudflare tunnel restarts. The local dashboard continues collecting data during an internet outage.

## How outages are classified

- **Probe noise:** one public ping fails while the router and other probes respond.
- **Local path loss:** the router also stops responding; this PC alone cannot distinguish its Wi-Fi adapter from the access point or router.
- **Confirmed upstream outage:** the router responds while all public ICMP probes and both TCP confirmations fail.

The reset button clears saved history without stopping the monitor. Its password stays in the local data directory and is never stored in the repository.
