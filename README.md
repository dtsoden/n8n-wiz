# n8n with external task runners on Docker

One script that installs, upgrades and restarts a self-hosted n8n community edition with external task runners, on macOS, Linux or Windows. Run it once to set things up. Run it again, by hand or on a schedule, to pull the latest n8n and restart cleanly. Your workflows and credentials stay put.

I wrote it because keeping a community edition current by hand got old: stop the containers, pull new images, remember every flag, start them again. I've run this script for over a year, most of that time automatically every night, and my instance stays current without me touching it. When n8n moved Code node execution to external task runners, the script grew to set those up too.

It's provided as is, as a convenience. It reflects my setup and my choices. Read the n8n docs linked below and make sure you understand what it does before you run it on anything you care about. That part is your responsibility.

If it saves you some time, please give it a star with the Star button at the top right of this page. Stars are how other n8n users find it.

## What you get

Two containers on one Docker network:

- `n8n` runs the editor, API and webhooks, and hosts the task broker on port 5679.
- `n8n-runners` uses the `n8nio/runners` image. A launcher inside it starts a JavaScript runner and a Python runner, which connect to the broker with a shared token and run your Code nodes outside the n8n process. The n8n docs recommend this external mode for production.

Your data lives in a folder on your machine, so replacing the containers doesn't touch it. That's what makes the nightly run safe.

## Requirements

Docker Desktop on macOS or Windows, or Docker Engine on Linux. Podman isn't covered.

If you're setting this up for a company, read Docker's licence terms first. Docker Desktop is free for personal use, education and small businesses, but larger companies need a paid subscription. Docker Engine on Linux doesn't have that restriction, and Podman is the usual alternative if Docker Desktop is off the table. That decision is your organisation's to make.

## Quick start

macOS or Linux:

```bash
git clone https://github.com/dtsoden/n8n-docker-task-runners.git
cd n8n-docker-task-runners
chmod +x n8n-docker-task-runners-setup.sh
./n8n-docker-task-runners-setup.sh
```

Windows (PowerShell):

```powershell
git clone https://github.com/dtsoden/n8n-docker-task-runners.git
cd n8n-docker-task-runners
powershell -ExecutionPolicy Bypass -File .\n8n-docker-task-runners-setup.ps1
```

No git? Download the repo as a ZIP from the green Code button and unzip it. On Windows, if the script is blocked as a downloaded file, run `Unblock-File .\n8n-docker-task-runners-setup.ps1` once.

Then open http://localhost:5678 (or the port you chose).

## What happens when you run it

1. It checks that Docker is installed. If it isn't, it gives you the Docker Desktop download link and stops.
2. It checks that Docker is running. If it isn't, it asks whether to start it, starts it, and waits up to three minutes for it to come up.
3. It starts downloading the n8n and runners images in the background, so they're ready or nearly ready when you finish the questions.
4. The first time, or with `--reconfigure`, it asks eight questions, one per screen, then shows all your answers on one numbered summary screen. Type a number there to redo that question, or press Enter to save. Later runs skip this and read the saved answers.
5. It finishes the downloads. Only then does it remove the old containers, so a failed download leaves your current n8n running.
6. It creates the Docker network if needed, writes `task-runners.json` to your data folder, and starts the two containers.
7. If you answered the questions, it sets up or removes the nightly schedule to match.
8. It prints the address to open and how to check that the runners connected.

If anything goes wrong along the way, the script stops and ends with a link to report the bug.

## Two ways to set it up

### Answer the questions

Run the script. The first time, it asks eight questions, each on its own screen with a suggested answer. If you're not sure, press Enter to take the suggestion. For yes or no questions, `y` and `n` are enough.

| Question | Suggested answer |
|---|---|
| Where should n8n keep its data? | `~/n8n`, or `C:\Users\<you>\n8n` on Windows |
| Which port should n8n use? | 5678 |
| Will anyone reach it from the internet? If yes, at what address? | No |
| How many seconds may a Code node run? | 300 seconds (5 minutes) |
| Which libraries can JavaScript Code nodes use? | Just `crypto` and `moment` |
| Which libraries can Python Code nodes use? | Everything in Python's standard library |
| Switch Execute Command and Local File Trigger back on? | Yes |
| Run by itself every night? If yes, at what time? | Yes, at 2:00 AM |

The two library questions are menus: everything that comes installed, a short common set, none, or your own pick. If you pick your own, the script reads the full list from the runners image you're about to run and shows it so you can copy names. It turns down any name that isn't on the list, so a typo can't slip through.

Times can be typed the way you'd say them: `2am`, `2:30pm`, `11pm` or `23:00` all work.

Made a mistake? After the last question, every answer is listed with a number. Type a number to redo that question, as often as you like, then press Enter to save. Press Ctrl+C on that screen to quit without saving anything. Once it's saved, run the script again with `--reconfigure` (bash) or `-Reconfigure` (PowerShell) to change anything later. The script reminds you of that command when it finishes.

Your answers go into `n8n-docker-task-runners-settings.env`, and every later run reads that file without asking anything.

The questions don't ask which n8n version to run. Every run uses `latest`, which is the point of the script.

The settings file has to sit in the same folder as the script. The script only looks for it there, so if you move the script, move the settings file with it. To change your answers, run the script again with `--reconfigure` (bash) or `-Reconfigure` (PowerShell), or edit the settings file in any text editor. It's plain `NAME=value` lines.

### Edit the script

If you're comfortable with code, open the script and change the values in the Settings block near the top. Every setting is commented, and the script header lists the line numbers. Then run it with `--no-questions` (bash) or `-NoQuestions` (PowerShell). If a settings file exists next to the script, it overrides the values in the script, so delete it if you go this way.

| Setting | bash line | PowerShell line | What it is |
|---|---|---|---|
| `N8N_DATA_DIR` | 114 | 126 | Folder for n8n's database, encryption key and `task-runners.json`. Defaults to `~/n8n` or `C:\Users\<you>\n8n` |
| `N8N_VERSION` | 118 | 130 | `latest` upgrades on every run. A number such as `2.45.4` holds you on that release. Both images always use the same version. Only changeable here or in the settings file |
| `N8N_HOST_PORT` | 121 | 133 | The port you open in the browser |
| `N8N_WEBHOOK_URL` | 126 | 139 | Your public address, such as `https://n8n.example.com/`. Leave empty for a machine used only locally |
| `DOCKER_NETWORK` | 129 | 142 | Only if you already have a network with another name |
| `TASK_TIMEOUT` | 134 | 147 | Seconds a Code node may run before it's stopped |
| `JS_*` and `PY_*` | 147-150 | 160-163 | What the Code node may import. Commas between names, `*` for everything, or empty for nothing |
| `ENABLE_EXEC_NODES` | 155 | 168 | `yes` turns Execute Command and Local File Trigger back on |
| `NIGHTLY_TIME` | 160 | 173 | When the script runs by itself every night, as 24-hour `HH:MM`, or `off`. The setup questions create or remove the schedule. If you set it here, schedule the script yourself |

## A word on the wildcards

By default the scripts allow every Python module available in the runners image (`*` in both Python allowlists). Some will see that as a security hole and others as the right setting. I don't make a claim either way, and I'm not going to debate it. You decide what fits your instance, and the "Harden task runners" page below is the place to start. The setup questions let you change it, or you can edit the `PY_*` values.

## Running it every night

Each run pulls the images first and only then replaces the containers, so a failed pull leaves your current n8n running. n8n is down for the few seconds it takes to restart, so pick a quiet hour. Executions running at that moment are interrupted.

The easy way is the last setup question. Say yes, give it a time such as `2am`, and the script schedules itself: a cron entry on macOS and Linux, or a scheduled task called "n8n nightly update" on Windows. Each nightly run is logged to `n8n-nightly.log` next to the script. Run `--reconfigure` (or `-Reconfigure`) and say no to turn it off again. The Windows task runs while you're signed in, which is also when Docker Desktop runs, and creating it doesn't need an administrator. On macOS, the first time the script edits your crontab, macOS may ask whether Terminal may administer your computer. Say yes.

If you edit the script instead of answering questions, schedule it yourself. On macOS or Linux, a cron entry like this runs it at 2 a.m. (edit with `crontab -e`, and use full paths). Cron's own `PATH` often can't find `docker`, so the line sets one:

```
0 2 * * * PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin /path/to/n8n-docker-task-runners/n8n-docker-task-runners-setup.sh --no-questions >> /path/to/n8n-nightly.log 2>&1
```

On Windows:

```
schtasks /create /tn "n8n nightly update" /sc daily /st 02:00 /tr "powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\path\to\n8n-docker-task-runners\n8n-docker-task-runners-setup.ps1 -NoQuestions"
```

`--no-questions` and `-NoQuestions` make sure a scheduled run never sits waiting for an answer. If Docker isn't running when a scheduled run starts, the script tries to start it and gives it three minutes before giving up. On Linux with Docker Engine that needs `sudo`, so keep Docker running there.

## Found a bug?

If the script stops with an error, it ends with a link to report it. You can also open an issue directly at https://github.com/dtsoden/n8n-docker-task-runners/issues/new. Include the last lines the script printed and which operating system you're on.

## Checking it worked

Run `docker logs n8n` and look for these two lines near the end:

```
Registered runner "launcher-javascript"
Registered runner "launcher-python"
```

Then add a Code node, set the language to Python, and run something with `import json`. If the import is refused, check the Python allowlist.

## Things worth knowing

- The `n8nio/runners` version has to match `n8nio/n8n`. The scripts use one version setting for both images, so they always move together.
- Each run writes `task-runners.json` into your data folder and mounts it over the runners image's default config, which it replaces entirely. It's a copy of the 2.45.4 default with your allowlists filled in. When n8n changes its default in a later release, this copy doesn't follow, so compare it now and then with the default for the version you run. Copy from the release tag, not the `master` branch, which can be ahead of the released image.
- By default the broker listens only on localhost. The scripts set `N8N_RUNNERS_BROKER_LISTEN_ADDRESS=0.0.0.0`, because a separate container can't reach localhost.
- On 2.x, n8n logs deprecation warnings for `WEBHOOK_URL` (use `N8N_WEBHOOK_URL`) and for `N8N_RUNNERS_ENABLED` (no longer needed). The scripts use the current names. If you pin a 1.x version, add `N8N_RUNNERS_ENABLED=true` back.
- n8n warns that the default task timeout will drop from 300 to 60 seconds in a future release, so the scripts set it explicitly on both containers.
- An allowlist can't add packages the runners image doesn't contain. For that you build a custom runners image, which the "Set up task runners" page covers.
- A new shared token is generated on every run. That's fine because both containers are recreated together.
- On Windows there's no `openssl` by default, so the PowerShell script generates the token with .NET's cryptographic random generator. It also writes the JSON without a byte order mark, because `Set-Content` and `Out-File` in Windows PowerShell 5.1 add one and the launcher fails to parse the file.
- On Windows, the data folder is shared into Docker's Linux VM. If n8n feels slow or logs "database is locked", the script header explains how to switch to a Docker volume.
- On Linux, n8n runs as user ID 1000 inside the container. If you see "permission denied" on `/home/node/.n8n`, run `sudo chown -R 1000:1000 ~/n8n` once.

## Docs (as of 27 October 2026)

- [Set up task runners](https://docs.n8n.io/deploy/host-n8n/configure-n8n/set-up-task-runners)
- [Task runner environment variables](https://docs.n8n.io/deploy/host-n8n/configure-n8n/basic-configuration/use-environment-variables/task-runners)
- [Harden task runners](https://docs.n8n.io/deploy/host-n8n/configure-n8n/security/harden-task-runners)
- [n8n 2.0 breaking changes](https://docs.n8n.io/2-0-breaking-changes) (`NODES_EXCLUDE`)
- [Launcher config file format](https://github.com/n8n-io/task-runner-launcher/blob/main/docs/setup.md#config-file)
- [Default launcher config in the 2.45.4 image](https://github.com/n8n-io/n8n/blob/n8n@2.45.4/docker/images/runners/n8n-task-runners.json)

## License

MIT, copyright (c) 2025-2026 [DavidSoden.Com](https://davidsoden.com). You're free to use, change and share these scripts in personal or commercial work, as long as you keep the copyright and license notice. See [LICENSE](LICENSE). The scripts come with no warranty.
