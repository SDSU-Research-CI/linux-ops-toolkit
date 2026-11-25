# linux-ops-toolkit

Read-only helper scripts for the SDSU College of Science Linux, networking and VPN access duties. They are meant for the systems administrators who maintain these machines. Nothing in this repo changes a machine: every script only reports. Values such as the domain, login groups and gateway are detected, not hardcoded.

Related repositories:
- [linux-hardening-toolkit](https://github.com/SDSU-Research-CI/linux-hardening-toolkit): hardening launcher used in the workstation guide.
- [ad-realm-join-automation](https://github.com/SDSU-Research-CI/ad-realm-join-automation): `join-ad.sh`, the AD realm join script.

## Scripts

| Script | When to use it |
| --- | --- |
| `health-check.sh` (runs `scripts/troubleshooting/linux-health-check.sh`) | First look at any machine, joined to the domain or not: `bash health-check.sh`. disk, memory, failed services, network, time sync, AD and SSH settings. `--save` keeps a copy of the report. |
| `scripts/troubleshooting/ad-login-check.sh [user]` | An AD user cannot log in. Reads `realm list`, checks the permitted groups, the user's groups, sshusers and sudo rights. Run with `sudo` for the full report. |
| `patch-check.sh` (runs `scripts/patching/pre-patch-check.sh`) | Before patching: `bash patch-check.sh`. Runs `apt update`, checks for connected users, long jobs, GPU jobs, disk space, held packages and pending reboots, then gives a verdict and a note for the ticket. |
| `after-patch-check.sh` (runs `scripts/patching/post-patch-check.sh`) | After `sudo apt upgrade` and `sudo reboot`: `bash after-patch-check.sh`. Confirms the reboot, kernel, installed package count and services, and gives a note for the ticket. |
| `scripts/ad/ad-ou-report.sh [--group NAME]` | After a realm join. Shows which OU the computer object landed in and, with `--group`, who is in an AD access group. Needs `krb5-user` and `ldap-utils`, and campus network or VPN. |

`scripts/lib-common.sh` holds the shared helpers. Keep it next to the other script folders.

## Get the scripts

```bash
sudo apt install -y git
git clone https://github.com/SDSU-Research-CI/linux-ops-toolkit.git
cd linux-ops-toolkit
```

Update later with `git pull`. Run the scripts with `bash` (for example `bash patch-check.sh`), so no `chmod` is needed.

## Quick start for patching

```bash
cd linux-ops-toolkit
git pull
bash patch-check.sh
```

The check refreshes the package list (`apt update`) but installs nothing. Read the verdict at the bottom. It tells you the next step and prints a note to paste into the ServiceNow ticket. If the verdict allows patching:

```bash
sudo apt upgrade
sudo reboot
# log in again, then:
cd linux-ops-toolkit
bash after-patch-check.sh
```

The after check confirms the reboot happened, shows the old and new kernel, counts the packages installed, checks that services came back, and prints a second note for the ticket. Patching needs a reboot, so tell the server owner first. If the before check says not to patch (someone is connected, a job is running, low disk space), it prints a note to request approval.

## When something is wrong

Start with the health check. It works on any Ubuntu machine, including ones that are not joined to the domain (the Active Directory section is simply skipped).

```bash
cd linux-ops-toolkit
bash health-check.sh --save
```

Read each `[FAIL]` and `[WARN]`, starting at the top. `--save` keeps a copy in your home folder that you can attach to the ServiceNow ticket. For an AD user who cannot log in, continue with `scripts/troubleshooting/ad-login-check.sh USERNAME`.

## Exit codes

All check scripts use the same convention: `0` all good, `1` warnings to review, `2` failures or blockers.

## Patching rule of thumb

Patch only when nobody is connected. Run `pre-patch-check.sh` first, create a ServiceNow ticket as proof, and ask faculty for a restart window when users are connected.

## Status

The scripts pass `shellcheck` and were tested on Ubuntu 24.04 in a standalone environment. The AD login check was tested against a simulated `realm list`. `ad-ou-report.sh` has not been run against the real SDSU directory yet: test it on a joined workstation and report any problems to the Linux admin team before relying on it.

## Contributing

Keep scripts read-only unless a script name and its header say otherwise. Use `shellcheck -x` before committing. Add a new script to the table above.
