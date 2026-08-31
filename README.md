# QNAP Plex watchdog

A conservative, environment-specific watchdog for a QNAP QPKG installation of Plex Media Server. It is intended to run as `root`/`admin` from cron and will act only while the `PlexMediaServer` QPKG is enabled.

## Assumptions and installation

This script is specifically written for a QNAP host where Plex is installed as the `PlexMediaServer` QPKG at:

```text
/share/CACHEDEV1_DATA/.qpkg/PlexMediaServer
```

Install it at:

```text
/share/CACHEDEV1_DATA/.qpkg/PlexMediaServer/plex-watchdog.sh
```

Make it executable:

```sh
chmod 755 /share/CACHEDEV1_DATA/.qpkg/PlexMediaServer/plex-watchdog.sh
```

Use this exact cron entry (every five minutes):

```cron
*/5 * * * * /share/CACHEDEV1_DATA/.qpkg/PlexMediaServer/plex-watchdog.sh
```

## Behavior

- Declares Plex healthy only when its process exists and the local HTTP check at `127.0.0.1:32400` succeeds.
- Retries once after 15 seconds before taking action, and observes a 10-minute boot grace period.
- Starts Plex when no process exists; otherwise cycles the QPKG when the local health check remains unhealthy.
- Detects a stuck advertised route from recent Plex log entries, cycles only after a 12-hour cooldown, and skips that cycle while non-local clients are active.
- Avoids concurrent runs with a directory lock and recovers locks older than 15 minutes.
- Bounds QPKG start/stop commands with a 180-second timeout.

Logs and state are stored under Plex's QPKG log directory:

```text
.../Library/Plex Media Server/Logs/plex-watchdog.log
.../Library/Plex Media Server/Logs/plex-watchdog.state
.../Library/Plex Media Server/Logs/plex-watchdog.route-restart
```

The transient lock directory is `/tmp/plex-watchdog.lock`.

## Warning

This is not a generic Plex watchdog. Review its QPKG name, storage path, available QNAP commands, timing values, and operational consequences before using it on another NAS or Plex deployment.
