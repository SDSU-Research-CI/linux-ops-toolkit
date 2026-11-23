# linux-ops-toolkit

Read-only helper scripts for the SDSU College of Science Linux, networking and VPN access duties. They are meant for the systems administrators who maintain these machines. Nothing in this repo changes a machine: every script only reports. Values such as the domain, login groups and gateway are detected, not hardcoded.

Related repositories:
- [linux-hardening-toolkit](https://github.com/SDSU-Research-CI/linux-hardening-toolkit): hardening launcher used in the workstation guide.
- [ad-realm-join-automation](https://github.com/SDSU-Research-CI/ad-realm-join-automation): `join-ad.sh`, the AD realm join script.

## Scripts

| Script | When to use it |
| --- | --- |
| `scripts/troubleshooting/linux-health-check.sh` | First look at any machine: disk, memory, failed services, network, time sync, AD and SSH settings. `--save` keeps a copy of the report. |
| `scripts/troubleshooting/ad-login-check.sh [user]` | An AD user cannot log in. Reads `realm list`, checks the permitted groups, the user's groups, sshusers and sudo rights. Run with `sudo` for the full report. |
| `scripts/patching/pre-patch-check.sh` | Before patching. Checks for connected users, long jobs, GPU jobs, disk space, held packages and pending reboots. Prints a verdict and a note to paste into the ServiceNow ticket. |
| `scripts/ad/ad-ou-report.sh [--group NAME]` | After a realm join. Shows which OU the computer object landed in and, with `--group`, who is in an AD access group. Needs `krb5-user` and `ldap-utils`, and campus network or VPN. |

`scripts/lib-common.sh` holds the shared helpers. Keep it next to the other script folders.

## Get the scripts

```bash
sudo apt install -y git
git clone https://github.com/SDSU-Research-CI/linux-ops-toolkit.git
cd linux-ops-toolkit
chmod +x scripts/*/*.sh
```

Update later with `git pull`.

## Exit codes

All check scripts use the same convention: `0` all good, `1` warnings to review, `2` failures or blockers.

## Patching rule of thumb

Patch only when nobody is connected. Run `pre-patch-check.sh` first, create a ServiceNow ticket as proof, and ask faculty for a restart window when users are connected.

## Status

The scripts pass `shellcheck` and were tested on Ubuntu 24.04 in a standalone environment. The AD login check was tested against a simulated `realm list`. `ad-ou-report.sh` has not been run against the real SDSU directory yet: test it on a joined workstation and report any problems to the Linux admin team before relying on it.

## Contributing

Keep scripts read-only unless a script name and its header say otherwise. Use `shellcheck -x` before committing. Add a new script to the table above.
