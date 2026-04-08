# Automatic Upgrades

## Overview

The server uses Ubuntu's **unattended-upgrades** system to automatically install security patches without human intervention. This is critical for an autonomous server — Marvin cannot (and should not) decide when to apply kernel patches.

## Configuration

### APT Periodic Settings

```
# /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
```

- **Update-Package-Lists "1"**: Refresh package lists daily
- **Unattended-Upgrade "1"**: Apply eligible upgrades daily

### Allowed Origins

```
# /etc/apt/apt.conf.d/50unattended-upgrades
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
```

Only **security updates** from Ubuntu's official `-security` repository are applied automatically. Feature updates and third-party packages require manual intervention.

### Safety Settings

```
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
```

| Setting | Value | Rationale |
|---------|-------|-----------|
| AutoFixInterruptedDpkg | `true` | Self-heal if dpkg was interrupted |
| Remove-Unused-Dependencies | `true` | Clean up orphaned packages after updates |
| **Automatic-Reboot** | **`false`** | Marvin's prime directive: **never reboot**. A bad reboot on an unattended server could be unrecoverable. Kernel updates requiring a reboot are logged and flagged for human action. |

## Systemd Timer

The upgrade process runs via `apt-daily-upgrade.timer`:

```
apt-daily-upgrade.timer → apt-daily-upgrade.service
Schedule: daily (around 06:00 local time, with random delay)
```

The package list update runs separately:

```
apt-daily.timer → apt-daily.service
Schedule: daily (around 13:00 local time, with random delay)
```

## Monitoring

Marvin's `hourly-check.sh` and `morning-check.sh` scripts monitor for:

- Failed `apt-daily-upgrade.service` runs
- Packages held back due to dependency conflicts
- Kernel updates that require a reboot (flagged in logs)
- `dpkg` lock issues

## Step-by-Step: Setting Up Unattended Upgrades

1. **Install the package** (usually pre-installed on Ubuntu):
   ```bash
   apt install unattended-upgrades
   ```

2. **Enable automatic updates**:
   ```bash
   dpkg-reconfigure -plow unattended-upgrades
   ```
   Select "Yes" when prompted.

3. **Verify configuration**:
   ```bash
   cat /etc/apt/apt.conf.d/20auto-upgrades
   # Should show both lines set to "1"
   ```

4. **Customize** `/etc/apt/apt.conf.d/50unattended-upgrades`:
   - Restrict to security updates only
   - Disable automatic reboot
   - Enable unused dependency removal

5. **Test** (dry run):
   ```bash
   unattended-upgrade --dry-run --debug
   ```

6. **Verify the timer is active**:
   ```bash
   systemctl status apt-daily-upgrade.timer
   ```

## Known Considerations

- **No automatic reboot**: After kernel updates, the server runs the old kernel until manually rebooted. This is tracked by Canonical Livepatch (`snap.canonical-livepatch`) which applies critical kernel fixes without reboot where possible.
- **Snap packages**: Snapd handles its own updates independently of apt. The `snapd.service` auto-updates snaps on its own schedule.

---

*Previous: [VPS Setup](VPS-Setup.md) · Next: [Security Hardening](Security-Hardening.md)*
