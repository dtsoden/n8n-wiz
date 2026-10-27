# MIT License
#
# Copyright (c) 2025-2026 DavidSoden.Com (https://davidsoden.com)
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# =============================================================================
# n8n with external task runners on Docker Desktop (Windows, PowerShell)
# https://github.com/dtsoden/n8n-docker-task-runners
# =============================================================================
#
# What this script does
#   1. Works out your settings (see "Two ways to set it up" below).
#   2. Pulls the n8n and n8n runners images (same version for both).
#   3. Removes any old "n8n" and "n8n-runners" containers.
#   4. Writes the launcher config file task-runners.json to your data folder.
#   5. Creates a shared random token and starts two containers on one network:
#        n8n          the editor, API and webhooks, plus the task broker on 5679
#        n8n-runners  the n8nio/runners sidecar that runs Code node JavaScript
#                     and Python in its own container, away from n8n itself
#
#   Your workflows and credentials live in the data folder on your machine, so
#   removing and recreating the containers does not delete them. That is what
#   makes it safe to run this every night to stay on the latest n8n.
#
#   This is the Windows version of n8n-docker-task-runners-setup.sh. The
#   containers and settings are the same. The differences are Windows only:
#   the token comes from .NET instead of openssl, and the JSON file is written
#   without a byte order mark, which Windows PowerShell 5.1 adds by default and
#   the launcher can't read.
#
# Two ways to set it up
#   Answer questions: just run the script. The first time, it asks a few
#   questions and saves your answers in n8n-docker-task-runners-settings.env,
#   in the same folder as this script. Every later run reads that file and asks
#   nothing, so a scheduled nightly run works unattended. Keep the two files
#   in the same folder: the script only looks for the settings file next to
#   itself. To change your answers later, run it with -Reconfigure, or open
#   the settings file in Notepad.
#
#   Edit this file: change the values under "Settings" below (line numbers are
#   listed further down), then run the script with -NoQuestions. If a settings
#   file exists next to the script, its values win over the ones written here,
#   so delete it if you go this way.
#
# Options
#   -Reconfigure    ask the questions again and save new answers
#   -NoQuestions    never ask; use the settings file if there is one,
#                   otherwise the values written in this script. Use this for
#                   Task Scheduler.
#
# Provided as is, as a convenience. I have run this script nightly for over a
# year to keep a community edition instance current. Read the docs below and
# decide whether its settings suit you; that responsibility is yours.
#
# Documentation (checked 27 October 2026, n8n 2.45.4)
#   Set up task runners:
#     https://docs.n8n.io/deploy/host-n8n/configure-n8n/set-up-task-runners
#   Task runner environment variables:
#     https://docs.n8n.io/deploy/host-n8n/configure-n8n/basic-configuration/use-environment-variables/task-runners
#   Harden task runners:
#     https://docs.n8n.io/deploy/host-n8n/configure-n8n/security/harden-task-runners
#   n8n 2.0 breaking changes (NODES_EXCLUDE, see ENABLE_EXEC_NODES below):
#     https://docs.n8n.io/2-0-breaking-changes
#   Launcher config file format:
#     https://github.com/n8n-io/task-runner-launcher/blob/main/docs/setup.md#config-file
#   Default launcher config inside the 2.45.4 runners image:
#     https://github.com/n8n-io/n8n/blob/n8n@2.45.4/docker/images/runners/n8n-task-runners.json
#
# Requirements
#   Docker Desktop for Windows with the WSL 2 backend, running before you start.
#   Windows PowerShell 5.1 (built into Windows) or PowerShell 7.
#   Podman is not covered here. Docker Desktop needs a paid subscription for
#   larger businesses, so check Docker's licence terms before using it at work.
#
# Settings you can edit directly (line numbers refer to this file as published)
#   Line 125  N8N_DATA_DIR        folder on your machine for n8n data
#   Line 129  N8N_VERSION         n8n version; the runners image uses the same one
#   Line 132  N8N_HOST_PORT       port you open in the browser
#   Line 138  N8N_WEBHOOK_URL     the public address of your n8n, if it has one
#   Line 141  DOCKER_NETWORK      only if you already use a different network name
#   Line 146  TASK_TIMEOUT        seconds a Code node may run before it is stopped
#   Lines 159 to 162  JS_* and PY_*  modules the Code node may import
#   Line 167  ENABLE_EXEC_NODES   Execute Command and Local File Trigger on or off
#
# How to run (from the folder holding this file)
#   powershell -ExecutionPolicy Bypass -File .\n8n-docker-task-runners-setup.ps1
#   The -ExecutionPolicy Bypass part applies to this one run only. If Windows
#   still blocks a downloaded file, run: Unblock-File .\n8n-docker-task-runners-setup.ps1
#
# If n8n feels slow or logs "database is locked": the data folder is a Windows
# folder shared into Docker's Linux VM, and SQLite can struggle there. Swap the
# n8n data mount near the end of this file for a Docker volume: change
# "$($S.N8N_DATA_DIR):/home/node/.n8n" to "n8n_data:/home/node/.n8n".
# =============================================================================

param(
    [switch]$Reconfigure,
    [switch]$NoQuestions
)

# ---- Settings ---------------------------------------------------------------
# Used when there is no settings file. The questions also offer these values
# as the answer you get by pressing Enter.

$S = [ordered]@{
    # Folder on your machine for n8n's data (database, encryption key, binary
    # files) and task-runners.json. Default: C:\Users\<you>\n8n
    N8N_DATA_DIR      = (Join-Path $env:USERPROFILE 'n8n')

    # n8n and n8nio/runners always run the same version. "latest" upgrades on
    # every run; a number such as "2.45.4" holds you on that release.
    N8N_VERSION       = 'latest'

    # Port on your machine. With 5678 you open http://localhost:5678
    N8N_HOST_PORT     = '5678'

    # The address people and services use to reach n8n, which n8n uses to
    # build webhook URLs, for example 'https://n8n.example.com/'. Leave it
    # empty on a machine that is only used locally; the script then uses
    # http://localhost:<port>/
    N8N_WEBHOOK_URL   = ''

    # Docker network both containers join so they can find each other by name.
    DOCKER_NETWORK    = 'n8n-network'

    # Seconds a single Code node execution may run before it is stopped. Both
    # containers get this value. n8n says its default will drop from 300 to 60
    # in a later release, so set it here rather than relying on the default.
    TASK_TIMEOUT      = '300'

    # What the Code node may import: names separated by commas, * for
    # everything available in the runners image, or empty for nothing. Only
    # packages that are in the image can load; adding others means building a
    # custom runners image (see the "Set up task runners" page above).
    #   JS_BUILTIN_ALLOW    Node.js built-in modules, such as crypto,fs,path
    #   JS_EXTERNAL_ALLOW   npm packages, such as moment,uuid
    #   PY_STDLIB_ALLOW     Python standard library modules, such as json,datetime
    #   PY_EXTERNAL_ALLOW   third-party Python packages, such as numpy,pandas
    # The Python values here are *, which allows every module in the image.
    # Some see that as a security hole, others as the right setting. Decide for
    # your own instance; the "Harden task runners" page above covers the risks.
    JS_BUILTIN_ALLOW  = 'crypto'
    JS_EXTERNAL_ALLOW = 'moment'
    PY_STDLIB_ALLOW   = '*'
    PY_EXTERNAL_ALLOW = '*'

    # n8n 2.0 and later refuse to load Execute Command and Local File Trigger.
    # 'yes' turns them back on (it sets NODES_EXCLUDE=[], which loads every
    # node). 'no' leaves n8n's default in place.
    ENABLE_EXEC_NODES = 'yes'
}

# ---- Nothing below this line needs editing ----------------------------------

# The settings file lives next to this script, wherever it is run from.
$SettingsFile = Join-Path $PSScriptRoot 'n8n-docker-task-runners-settings.env'

# ---- Checking values --------------------------------------------------------
# Every value is checked before use, whether it came from an answer, the
# settings file or this script. That also keeps quotes and other characters
# that would break task-runners.json out of it.

function Test-Setting([string]$Name, [string]$Value) {
    switch -Wildcard ($Name) {
        'N8N_DATA_DIR'      { return $Value -ne '' }
        'N8N_VERSION'       { return $Value -match '^[A-Za-z0-9._-]+$' }
        'DOCKER_NETWORK'    { return $Value -match '^[A-Za-z0-9._-]+$' }
        'N8N_HOST_PORT'     { return ($Value -match '^[0-9]+$') -and ([int]$Value -ge 1) -and ([int]$Value -le 65535) }
        'N8N_WEBHOOK_URL'   { return ($Value -eq '') -or ($Value -match '^https?://\S+$') }
        'TASK_TIMEOUT'      { return ($Value -match '^[0-9]+$') -and ([int]$Value -ge 1) }
        'JS_*'              { return $Value -match '^[A-Za-z0-9_.,*@/-]*$' }
        'PY_*'              { return $Value -match '^[A-Za-z0-9_.,*@/-]*$' }
        'ENABLE_EXEC_NODES' { return ($Value -eq 'yes') -or ($Value -eq 'no') }
    }
    return $false
}

# ---- Settings file ----------------------------------------------------------
# Plain NAME=value lines. Lines starting with # are ignored.

function Read-SettingsFile {
    foreach ($line in Get-Content -LiteralPath $SettingsFile) {
        $line = $line.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        $key, $value = $line -split '=', 2
        if (-not $S.Contains($key)) {
            Write-Host "Ignoring unknown line in the settings file: $key"
            continue
        }
        if ($null -eq $value) { $value = '' }
        if (-not (Test-Setting $key $value)) {
            Write-Host "The settings file has a value that doesn't work for ${key}: $value" -ForegroundColor Red
            Write-Host "Fix it in $SettingsFile, or run with -Reconfigure."
            exit 1
        }
        $S[$key] = $value
    }
}

function Save-SettingsFile {
    $lines = @(
        "# Settings for n8n-docker-task-runners-setup.ps1, saved $(Get-Date -Format 'yyyy-MM-dd HH:mm').",
        '# Keep this file in the same folder as the script. Edit the values here,',
        '# or run the script with -Reconfigure to answer the questions again.'
    )
    foreach ($key in $S.Keys) { $lines += "$key=$($S[$key])" }
    [System.IO.File]::WriteAllLines($SettingsFile, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Saved your answers to $SettingsFile"
}

# ---- Questions --------------------------------------------------------------

# Offers the current value as the default (Enter keeps it), turns "none" into
# an empty value, and asks again until the answer works.
function Ask([string]$Name, [string]$Question) {
    $shown = if ($S[$Name] -eq '') { 'none' } else { $S[$Name] }
    while ($true) {
        $answer = Read-Host "$Question [$shown]"
        if ($answer -eq '') { $answer = $S[$Name] }
        if ($answer -eq 'none') { $answer = '' }
        if ($answer.StartsWith('~')) { $answer = $env:USERPROFILE + $answer.Substring(1) }
        if (Test-Setting $Name $answer) {
            $S[$Name] = $answer
            return
        }
        Write-Host "  That doesn't look right. Please try again." -ForegroundColor Yellow
    }
}

# Returns $true for yes. $Default is 'y' or 'n'.
function Ask-YesNo([string]$Question, [string]$Default) {
    while ($true) {
        $answer = Read-Host "$Question [$Default]"
        if ($answer -eq '') { $answer = $Default }
        if ($answer -match '^[Yy]') { return $true }
        if ($answer -match '^[Nn]') { return $false }
    }
}

function Invoke-Questions {
    Write-Host ''
    Write-Host 'Press Enter to accept the value in brackets.'
    Write-Host ''
    Ask 'N8N_DATA_DIR' "Folder for n8n's data"
    Write-Host '  "latest" upgrades n8n every time this script runs. A number such as'
    Write-Host '  2.45.4 stays on that release.'
    Ask 'N8N_VERSION' 'n8n version'
    Ask 'N8N_HOST_PORT' 'Port to open n8n on in your browser'

    $hasUrl = if ($S.N8N_WEBHOOK_URL -ne '') { 'y' } else { 'n' }
    if (Ask-YesNo 'Will other people or services reach this n8n at a public address?' $hasUrl) {
        while ($true) {
            Ask 'N8N_WEBHOOK_URL' 'Public address, such as https://n8n.example.com/'
            if ($S.N8N_WEBHOOK_URL -ne '') { break }
            Write-Host '  Enter the full address, starting with https://' -ForegroundColor Yellow
        }
    } else {
        $S.N8N_WEBHOOK_URL = ''
    }

    Ask 'TASK_TIMEOUT' 'Seconds a Code node may run before it is stopped'

    Write-Host ''
    Write-Host 'What the Code node may import. Use commas between names, * for'
    Write-Host 'everything in the runners image, or none. Whether * suits you is your'
    Write-Host 'call. The risks are covered at'
    Write-Host 'https://docs.n8n.io/deploy/host-n8n/configure-n8n/security/harden-task-runners'
    Ask 'JS_BUILTIN_ALLOW' 'JavaScript, Node.js built-in modules'
    Ask 'JS_EXTERNAL_ALLOW' 'JavaScript, npm packages'
    Ask 'PY_STDLIB_ALLOW' 'Python, standard library modules'
    Ask 'PY_EXTERNAL_ALLOW' 'Python, third-party packages'

    Write-Host ''
    Write-Host 'n8n 2.0 and later turn off the Execute Command and Local File Trigger nodes.'
    $execDefault = if ($S.ENABLE_EXEC_NODES -eq 'yes') { 'y' } else { 'n' }
    $S.ENABLE_EXEC_NODES = if (Ask-YesNo 'Turn them back on?' $execDefault) { 'yes' } else { 'no' }

    Write-Host ''
    Write-Host 'Your settings:'
    foreach ($key in $S.Keys) { Write-Host "  $key=$($S[$key])" }
    if (-not (Ask-YesNo 'Save these and start n8n?' 'y')) {
        Write-Host "Nothing changed. Run the script again when you're ready."
        exit 0
    }
    Save-SettingsFile
}

# ---- Work out the settings --------------------------------------------------
# A scheduled task has nobody at the keyboard, so it must never stop to ask.
# -NoQuestions guarantees that; the check below catches most other cases.

$interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected

if ($Reconfigure) {
    if (-not $interactive) {
        Write-Host '-Reconfigure needs someone at the keyboard to answer the questions.' -ForegroundColor Red
        exit 1
    }
    # Load the current answers first so they show up as the defaults.
    if (Test-Path -LiteralPath $SettingsFile) { Read-SettingsFile }
    Invoke-Questions
} elseif (Test-Path -LiteralPath $SettingsFile) {
    Write-Host "Using settings from $SettingsFile"
    Read-SettingsFile
} elseif ($NoQuestions -or -not $interactive) {
    Write-Host 'No settings file next to the script; using the values written in it.'
} else {
    Write-Host 'No settings file found next to this script.'
    if (Ask-YesNo 'Answer a few setup questions now? (n uses the values written in the script)' 'y') {
        Invoke-Questions
    }
}

# Values typed straight into this script are checked here too.
foreach ($key in @($S.Keys)) {
    if (-not (Test-Setting $key $S[$key])) {
        Write-Host "The value for $key doesn't work: $($S[$key])" -ForegroundColor Red
        exit 1
    }
}

# No public address means a machine used only locally.
$WebhookUrlToUse = if ($S.N8N_WEBHOOK_URL -ne '') { $S.N8N_WEBHOOK_URL } else { "http://localhost:$($S.N8N_HOST_PORT)/" }

# ---- Docker helper ----------------------------------------------------------
# PowerShell does not stop when docker.exe fails, so check its exit code after
# each call that has to work. This plays the part of "set -e" in the bash script.

function Invoke-Docker {
    & docker @args
    if ($LASTEXITCODE -ne 0) {
        Write-Host "docker $($args -join ' ') failed with exit code $LASTEXITCODE" -ForegroundColor Red
        exit 1
    }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host 'docker was not found. Install Docker Desktop and start it first.' -ForegroundColor Red
    exit 1
}

# ---- Pull images first ------------------------------------------------------
# Pulling before removing anything means a typo in the version or a network
# problem stops the script while your current n8n is still running.

$version = $S.N8N_VERSION
Write-Host "Pulling n8nio/n8n:$version and n8nio/runners:$version..."
Invoke-Docker pull "n8nio/n8n:$version"
Invoke-Docker pull "n8nio/runners:$version"

# ---- Remove old containers --------------------------------------------------
# Ask Docker whether each container exists rather than letting "docker rm"
# fail on the first run. "rm -f" stops a running container before removing it.

Write-Host 'Removing old containers...'
foreach ($name in @('n8n', 'n8n-runners')) {
    $id = & docker ps -aq --filter "name=^$name$"
    if ($id) { Invoke-Docker rm -f $name | Out-Null }
}

# ---- Network and data folder ------------------------------------------------

$network = $S.DOCKER_NETWORK
Write-Host "Creating network $network if needed..."
$net = & docker network ls -q --filter "name=^$network$"
if (-not $net) { Invoke-Docker network create $network | Out-Null }

New-Item -ItemType Directory -Force -Path $S.N8N_DATA_DIR | Out-Null

# ---- Launcher config: task-runners.json -------------------------------------
# The runners container starts a small program called the launcher. It reads
# /etc/n8n-task-runners.json to learn how to start each runner. The image
# ships a locked-down default; we mount our own copy over it (see the
# n8n-runners container below) to change what the Code node may import.
#
# This file replaces the whole default, so it should track the runners image
# version. It is a copy of the 2.45.4 default (link at the top) with the four
# allowlists filled in from your settings. After upgrades, compare it now and
# then with the default for the version you run:
#   https://github.com/n8n-io/n8n/blob/n8n@<version>/docker/images/runners/n8n-task-runners.json
#
# JSON does not allow comments, so the fields are explained here:
#   runner-type               "javascript" or "python"
#   workdir, command, args    how the launcher starts that runner; leave as is
#   health-check-server-port  internal port per runner (5681 JS, 5682 Python);
#                             not published to your machine
#   allowed-env               variables the launcher passes through to the runner
#   env-overrides             variables set on that runner only; the four
#                             *_ALLOW values come from the settings above
#
# The template uses placeholders such as __JS_BUILTIN_ALLOW__, replaced below.
# The single-quoted here-string (@' ... '@) keeps PowerShell from changing
# anything else inside it. The closing '@ has to sit at the very start of its line.
$taskRunnersJson = @'
{
  "task-runners": [
    {
      "runner-type": "javascript",
      "workdir": "/home/runner",
      "command": "/usr/local/bin/node",
      "args": [
        "--disallow-code-generation-from-strings",
        "--disable-proto=delete",
        "/opt/runners/task-runner-javascript/dist/start.js"
      ],
      "health-check-server-port": "5681",
      "allowed-env": [
        "PATH",
        "GENERIC_TIMEZONE",
        "NODE_OPTIONS",
        "NODE_PATH",
        "N8N_RUNNERS_AUTO_SHUTDOWN_TIMEOUT",
        "N8N_RUNNERS_GRACEFUL_SHUTDOWN_TIMEOUT",
        "N8N_RUNNERS_SHUTDOWN_FORCE_KILL_MARGIN",
        "N8N_RUNNERS_TASK_TIMEOUT",
        "N8N_RUNNERS_MAX_CONCURRENCY",
        "N8N_SENTRY_DSN",
        "N8N_VERSION",
        "ENVIRONMENT",
        "DEPLOYMENT_NAME",
        "HOME"
      ],
      "env-overrides": {
        "NODE_FUNCTION_ALLOW_BUILTIN": "__JS_BUILTIN_ALLOW__",
        "NODE_FUNCTION_ALLOW_EXTERNAL": "__JS_EXTERNAL_ALLOW__",
        "N8N_RUNNERS_HEALTH_CHECK_SERVER_HOST": "0.0.0.0"
      }
    },
    {
      "runner-type": "python",
      "workdir": "/home/runner",
      "command": "/opt/runners/task-runner-python/.venv/bin/python",
      "args": ["-I", "-B", "-X", "disable_remote_debug", "-m", "src.main"],
      "health-check-server-port": "5682",
      "allowed-env": [
        "PATH",
        "N8N_RUNNERS_LAUNCHER_LOG_LEVEL",
        "N8N_RUNNERS_AUTO_SHUTDOWN_TIMEOUT",
        "N8N_RUNNERS_GRACEFUL_SHUTDOWN_TIMEOUT",
        "N8N_RUNNERS_TASK_TIMEOUT",
        "N8N_RUNNERS_MAX_CONCURRENCY",
        "N8N_SENTRY_DSN",
        "N8N_VERSION",
        "ENVIRONMENT",
        "DEPLOYMENT_NAME"
      ],
      "env-overrides": {
        "N8N_RUNNERS_STDLIB_ALLOW": "__PY_STDLIB_ALLOW__",
        "N8N_RUNNERS_EXTERNAL_ALLOW": "__PY_EXTERNAL_ALLOW__"
      }
    }
  ]
}
'@

foreach ($key in 'JS_BUILTIN_ALLOW', 'JS_EXTERNAL_ALLOW', 'PY_STDLIB_ALLOW', 'PY_EXTERNAL_ALLOW') {
    $taskRunnersJson = $taskRunnersJson.Replace("__${key}__", $S[$key])
}

# Write UTF-8 without a byte order mark and with Linux line endings. Do not
# swap this for Set-Content or Out-File: on Windows PowerShell 5.1 they add a
# byte order mark and the launcher fails to parse the file.
$taskRunnersPath = Join-Path $S.N8N_DATA_DIR 'task-runners.json'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($taskRunnersPath, ($taskRunnersJson -replace "`r`n", "`n"), $utf8NoBom)

# ---- Shared token -----------------------------------------------------------
# n8n and the runners container prove who they are to each other with the same
# secret. This is the Windows stand-in for "openssl rand -hex 32": 32 random
# bytes from the .NET cryptographic generator, written as 64 hex characters.
# Nothing extra to install. A new token on every run is fine because both
# containers are recreated together below.

$bytes = New-Object byte[] 32
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$rng.GetBytes($bytes)
$rng.Dispose()
$RunnersAuthToken = -join ($bytes | ForEach-Object { $_.ToString('x2') })

# ---- Start n8n --------------------------------------------------------------
# Each docker option sits on its own line in an array, which avoids the
# backtick line continuations that break if a space follows them.

Write-Host 'Starting n8n...'
$n8nArgs = @(
    'run', '-d',
    '--name', 'n8n',
    '--restart', 'always',
    '--network', $network,
    # n8n listens on 5678 inside the container
    '-p', "$($S.N8N_HOST_PORT):5678",
    # Keeps your data on your machine
    '-v', "$($S.N8N_DATA_DIR):/home/node/.n8n",
    # Replaces the older WEBHOOK_URL, which n8n 2.x flags as deprecated.
    # n8n 1.x also needed N8N_RUNNERS_ENABLED=true; 2.x says it is no longer
    # needed, so add it back only if you pin a 1.x version.
    '-e', "N8N_WEBHOOK_URL=$WebhookUrlToUse",
    # Run Code nodes in the sidecar, not inside n8n
    '-e', 'N8N_RUNNERS_MODE=external',
    # Must match the runners container
    '-e', "N8N_RUNNERS_AUTH_TOKEN=$RunnersAuthToken",
    # From TASK_TIMEOUT
    '-e', "N8N_RUNNERS_TASK_TIMEOUT=$($S.TASK_TIMEOUT)",
    # The broker (port 5679) only listens on localhost by default, which
    # another container can't reach
    '-e', 'N8N_RUNNERS_BROKER_LISTEN_ADDRESS=0.0.0.0',
    # In n8n's reference compose file for the Python runner
    '-e', 'N8N_NATIVE_PYTHON_RUNNER=true'
)
# Only when ENABLE_EXEC_NODES is yes: [] loads every node, including Execute
# Command and Local File Trigger.
if ($S.ENABLE_EXEC_NODES -eq 'yes') { $n8nArgs += @('-e', 'NODES_EXCLUDE=[]') }
$n8nArgs += "n8nio/n8n:$version"
Invoke-Docker @n8nArgs | Out-Null

# ---- Start the runners sidecar ----------------------------------------------

Write-Host 'Starting n8n-runners...'
$runnerArgs = @(
    'run', '-d',
    '--name', 'n8n-runners',
    '--restart', 'always',
    '--network', $network,
    '-e', "N8N_RUNNERS_AUTH_TOKEN=$RunnersAuthToken",
    # "n8n" is the container name above; Docker resolves it on the shared
    # network. 5679 is the broker port.
    '-e', 'N8N_RUNNERS_TASK_BROKER_URI=http://n8n:5679',
    # From TASK_TIMEOUT
    '-e', "N8N_RUNNERS_TASK_TIMEOUT=$($S.TASK_TIMEOUT)",
    # Replaces the image's default launcher config with the file written above
    '-v', "${taskRunnersPath}:/etc/n8n-task-runners.json",
    "n8nio/runners:$version"
)
Invoke-Docker @runnerArgs | Out-Null

Write-Host ''
Write-Host "Done. Open http://localhost:$($S.N8N_HOST_PORT)"
Write-Host 'Check the runners connected with: docker logs n8n'
Write-Host '(look for two lines starting with: Registered runner)'
