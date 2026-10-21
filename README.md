# vs2022-windows-container

Windows Server 2025 build VM, run on a Linux host with Docker, with a Gitea Actions runner inside.

Windows containers need a Windows kernel, so this can't be a real Windows container image. Instead,
[dockur/windows](https://github.com/dockur/windows) runs Windows under QEMU/KVM inside a Linux
container. dockur downloads the Windows Server 2025 evaluation ISO and installs it unattended, then
runs `oem/setup.ps1` on first boot, which:

- makes sure winget is available, installing it if needed (the Microsoft Store isn't supported on Server)
- installs, with winget, VS2022 Community from the team [`oem/vs2022.vsconfig`](oem/vs2022.vsconfig), plus the reference build host's toolset (CMake, Git, Git LFS, Node.js LTS, Python Install Manager, 7-Zip, PowerShell 7) as machine-wide installs, and adds VS's `MSBuild\Current\Bin` and bundled CMake `bin` folders to the machine PATH. `run:` steps without `shell:` use PowerShell 7
- runs [gitea-runner](https://gitea.com/gitea/runner) in host mode, as a `gitea-runner` task running as SYSTEM: started at boot, restarted 10 s after any exit, and relaunched within 5 minutes by a watchdog trigger if the task itself stops
- registers the `gitea-runner` task, which runs `configure.ps1` before starting the runner (see [Changing settings later](#changing-settings-later)). That script converts the evaluation edition and activates it against your KMS server, and sets up the weekly `auto-update` task
- trims the VM at every boot with [`oem/tune.ps1`](oem/tune.ps1): disables or sets to Manual services a build machine doesn't need (spooler, telemetry, SysMain, search, audio, ...), removes the Azure Arc Setup tray app, stops Server Manager opening at logon, excludes build tools from Defender scanning, switches to the High performance power plan, and turns off auto-logon. To use the desktop, sign in through the web console with `WIN_USER` / `WIN_PASSWORD`

## Requirements

- Linux host with `/dev/kvm` and Docker Compose v2
- Windows Server volume licences served by your KMS server
- about 32 GB of RAM and 12 cores to spare for the VM, plus 200 GB of disk under `./storage`
- network access from the VM to Gitea and your KMS server (the VM uses NAT: give addresses as LAN IPs or DNS names, never `localhost`)

## Quick start

On btrfs, turn off copy-on-write for `./storage` before the first start, or dockur warns that Windows Setup may break:
`mkdir -p storage && chattr +C storage`.

```sh
cp .env.example .env     # set WIN_PASSWORD, GITEA_*, KMS_HOST
docker compose up -d
```

To follow progress, open the web console at <http://127.0.0.1:8006>. The Windows install and
provisioning take roughly 1–2 hours, most of it spent installing VS2022. When it's done, the
runner shows as idle in Gitea under **Settings → Actions → Runners**.

Each value can come from `.env`, from your shell or CI environment (which overrides `.env`), or from
`--env-file`.

## Container image

GitHub Actions ([`.github/workflows/docker.yml`](.github/workflows/docker.yml)) builds an image with the
`oem/` scripts baked in and pushes it to `ghcr.io/flcontainers/windows-gitea-runner`:

- a `v*` tag (for example `v1.2.0`) publishes that tag and `latest`
- every push to a branch publishes `nightly`

The image renders `config.env` from its own environment at start, so it runs without the `oem-config` service
or the `./oem` mounts. Replace the `windows` service's `image:` with it, pass the `GITEA_*`, `RUNNER_*`, `UPDATE_*`,
`KMS_*` and `LOCALE_*` variables to that service, and drop the `oem-config` service and the `./oem` volumes.

## Changing settings later

Edit `.env` and run `docker compose up -d`. If you changed any `GITEA_*`, `RUNNER_*`, `UPDATE_*` or
`KMS_*` value, here is what happens:

1. `oem-config` writes a new `oem/config.env`, and compose restarts the VM (`restart: true`).
   **A job that is running at that moment is lost.**
2. Before the runner starts, [`oem/configure.ps1`](oem/configure.ps1) copies `config.env` and the
   scripts from `oem/` through dockur's read-only share (`\\host.lan\Data`), then updates the existing setup in place:
   - `config.yaml` is written again, picking up the capacity and labels. The runner announces new labels to Gitea when it starts, without registering again.
   - gitea-runner is replaced if the installed version no longer matches `RUNNER_VERSION`.
   - The existing registration is kept unless `GITEA_INSTANCE_URL` or `RUNNER_NAME` changed. Then it registers again with `GITEA_RUNNER_TOKEN`; if that fails, the previous registration is restored. The old runner entry stays in Gitea, offline, and can be deleted there.
   - The `auto-update` and `kms-activate` tasks are created, updated or removed to match the settings.

The same happens on every restart of the runner task. Fixes to the scripts in `oem/` also reach
the VM this way, except `setup.ps1`, which only runs at install. VM settings (`WIN_*`) apply when
the container restarts.

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `WIN_VERSION` | `2025` | dockur `VERSION`: `2025` or `2022` |
| `WIN_RAM` / `WIN_CPUS` / `WIN_DISK` | `32G` / `12` / `200G` | VM resources (the disk can be grown later) |
| `WIN_USER` / `WIN_PASSWORD` | `Docker` / *required* | Local admin, used for RDP and the web console |
| `BIND_ADDR` | `127.0.0.1` | Host address that ports 8006 and 3389 are published on |
| `GITEA_INSTANCE_URL` | *required* | Gitea base URL |
| `GITEA_RUNNER_TOKEN` | | Registration token, used when registering for the first time or again; keep it valid in `.env` |
| `RUNNER_NAME` | `win-runner-01` | Runner name shown in Gitea |
| `RUNNER_LABELS` | `windows-latest:host,windows-2025:host` | Labels the runner accepts; `windows-latest` matches the existing workflows |
| `RUNNER_VERSION` | `5` | gitea-runner version: a major (`5` = newest 5.x), `latest`, or exact (`5.1.1`) |
| `RUNNER_CAPACITY` | `1` | Number of jobs run at the same time |
| `UPDATE_DAYS` | `Sunday` | Weekdays for the auto-update task (comma-separated); empty disables it |
| `UPDATE_TIME` | `03:00` | Time the auto-update task starts |
| `UPDATE_MAX_WAIT_MIN` | `240` | How long to wait for a running job before skipping that week |
| `LOCALE_KEYBOARD` | | Keyboard as a culture name (`fr-FR` = AZERTY), applied to every user's session, the login screen and new users |
| `LOCALE_TIMEZONE` | | Windows time zone ID (`tzutil /l`); Europe/Paris is `Romance Standard Time` |
| `KMS_HOST` | | KMS server address, `auto` for DNS SRV discovery, or empty to skip activation |
| `KMS_PORT` | `1688` | KMS port |
| `KMS_EDITION` | `ServerStandard` | Edition the evaluation install is converted to (`ServerStandard` or `ServerDatacenter`) |
| `KMS_CLIENT_KEY` | | Overrides the built-in GVLK for the OS build and edition |

## KMS activation

dockur installs an **evaluation** edition, and an evaluation edition can't take a KMS key. When
`KMS_HOST` is set, `configure.ps1` registers and starts the `kms-activate` task
([`oem/activate.ps1`](oem/activate.ps1)), which also runs at every boot:

1. On an evaluation edition, it waits for the runner to go idle, stops it, and converts the edition to `KMS_EDITION` with
   `DISM /Set-Edition`, using Microsoft's public KMS client key (GVLK) for that build. This step reboots the VM
   and can take more than 10 minutes.
2. After that, it runs `slmgr /skms <host>:<port>` and then `/ato`. Once the VM is activated against
   the configured host, it does nothing.

It logs to `C:\OEM\activate.log`, and works the same whether `KMS_HOST` is set before install or added later.

To skip the conversion, use your own volume-licence ISO: uncomment the `/custom.iso` mount in
`docker-compose.yml`. Check the licence state with `slmgr /dlv`.

## Automatic updates

The `auto-update` task ([`oem/update.ps1`](oem/update.ps1)) runs at `UPDATE_DAYS` / `UPDATE_TIME` as SYSTEM:

1. It waits until the runner is idle, meaning no job processes for 2 minutes. If a job is still running after `UPDATE_MAX_WAIT_MIN`, it skips that week.
2. It stops the runner, then installs the newest gitea-runner release matching `RUNNER_VERSION`.
3. It updates VS2022 in place with the official bootstrapper (`vs_<edition>.exe update --installPath ...`), staying on the 17.x release channel.
4. It upgrades the winget toolset (CMake, Git, Git LFS, Node.js LTS, 7-Zip, PowerShell 7, Python Install Manager), keeping each machine-wide install. The list lives in `$WingetPackages` in [`oem/common.ps1`](oem/common.ps1), shared with setup. The task runs as SYSTEM, which has no `winget` command, so it calls `winget.exe` from the App Installer package folder.
5. It restarts the runner, or reboots the VM if an update requires it.

The task logs to `C:\OEM\update.log`. To run it immediately, use `schtasks /run /tn auto-update`.
It doesn't install newer components added to `vs2022.vsconfig`, or handle Windows Update.

## Using it from your workflows

No workflow changes are needed. `runs-on: windows-latest` jobs get picked up by this runner, and
`microsoft/setup-msbuild` finds VS2022 through `vswhere`. Jobs run as SYSTEM directly on the VM,
under `C:\runner\work`, so state carries over between jobs. Use `clean: true` on checkout and a full
rebuild (e.g. `/t:Rebuild`) to avoid stale build output.

## Troubleshooting

| What | Where |
|---|---|
| Provisioning log | `C:\OEM\setup.log` |
| VS installer logs | `%TEMP%\dd_*.log` |
| Runner log | `C:\runner\runner.log` |
| Config log | `C:\OEM\configure.log` |
| KMS log | `C:\OEM\activate.log` |
| Update log | `C:\OEM\update.log` |
| Re-apply config without a VM restart | `schtasks /end /tn gitea-runner` then `schtasks /run /tn gitea-runner` |
| Run provisioning again | `powershell -ExecutionPolicy Bypass -File C:\OEM\setup.ps1` |

## Licensing

Windows Server is licensed through your KMS server. VS2022 Community is free only for
individuals, open-source work, academic use and small organisations (up to 5 users in an
organisation that isn't an "enterprise"). Otherwise, switch the winget id in `setup.ps1` to
`Microsoft.VisualStudio.2022.Professional` or `.Enterprise`; the vsconfig works with every
edition. The GVLKs in `oem/common.ps1` are Microsoft's published KMS client setup keys.
