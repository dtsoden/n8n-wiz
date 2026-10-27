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
#   1. Makes sure Docker is running, then works out your settings.
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

# Prints the question, offers the current value as the answer you get by
# pressing Enter, turns "none" into an empty value, and asks again until the
# answer works.
function Ask([string]$Name, [string]$Question) {
    $hint = if ($S[$Name] -eq '') {
        '  Press Enter to leave this empty, or type something'
    } else {
        "  Press Enter for $($S[$Name]), or type something else"
    }
    Write-Host ''
    Write-Host $Question
    while ($true) {
        $answer = Read-Host $hint
        if ($answer -eq '') { $answer = $S[$Name] }
        if ($Name -like 'JS_*' -or $Name -like 'PY_*') { $answer = $answer -replace '\s', '' }
        if ($answer -eq 'none') { $answer = '' }
        if ($answer.StartsWith('~')) { $answer = $env:USERPROFILE + $answer.Substring(1) }
        if (Test-Setting $Name $answer) {
            $S[$Name] = $answer
            return
        }
        Write-Host "  Sorry, that won't work here. Have another go." -ForegroundColor Yellow
    }
}

# Prints the question and returns $true for yes. $Default ('y' or 'n') is what
# pressing Enter means.
function Ask-YesNo([string]$Question, [string]$Default) {
    $hint = if ($Default -eq 'y') { '  Press Enter for yes, or type no' } else { '  Press Enter for no, or type yes' }
    Write-Host ''
    Write-Host $Question
    while ($true) {
        $answer = Read-Host $hint
        if ($answer -eq '') { $answer = $Default }
        if ($answer -match '^[Yy]') { return $true }
        if ($answer -match '^[Nn]') { return $false }
        Write-Host '  Please type yes or no.' -ForegroundColor Yellow
    }
}

# Empty values and * read better in the summary than the stored form.
function Show-Value([string]$Value) {
    if ($Value -eq '') { return 'nothing' }
    if ($Value -eq '*') { return 'everything' }
    return $Value
}

# Show-Seconds 300 returns "300 seconds (5 minutes)" so nobody has to do the math.
function Show-Seconds([int]$Seconds) {
    if ($Seconds -lt 60) { return "$Seconds seconds" }
    $m = [math]::Floor($Seconds / 60)
    $r = $Seconds % 60
    $out = if ($m -eq 1) { '1 minute' } else { "$m minutes" }
    if ($r -eq 1) { $out += ' 1 second' } elseif ($r -gt 1) { $out += " $r seconds" }
    return "$Seconds seconds ($out)"
}

# Prints numbered options and returns the number picked. Enter picks $Default.
function Select-Option([string]$Question, [int]$Default, [string[]]$Options) {
    Write-Host ''
    Write-Host $Question
    for ($i = 0; $i -lt $Options.Count; $i++) { Write-Host "  $($i + 1)  $($Options[$i])" }
    while ($true) {
        $answer = Read-Host "  Press Enter for $Default, or type a number"
        if ($answer -eq '') { $answer = "$Default" }
        if ($answer -match '^[0-9]+$' -and [int]$answer -ge 1 -and [int]$answer -le $Options.Count) { return [int]$answer }
        Write-Host "  Please type a number from 1 to $($Options.Count)." -ForegroundColor Yellow
    }
}

# Returns, comma separated, what the runners image offers: 'js-builtin',
# 'js-npm' or 'py-stdlib'. It asks the image itself, so the list always matches
# the version that will run, and returns '' if Docker can't answer.
function Get-ImageList([string]$Kind) {
    Wait-RunnersImage
    $image = "n8nio/runners:$($S.N8N_VERSION)"
    & docker image inspect $image *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host '  Downloading the n8n runners image to read the list. This can take a minute...'
        & docker pull -q $image *> $null
        if ($LASTEXITCODE -ne 0) { return '' }
    }
    $out = switch ($Kind) {
        'js-builtin' {
            & docker run --rm --entrypoint node $image -e "console.log(require('module').builtinModules.filter(m=>!m.startsWith('_')&&!m.includes('/')).join(','))" 2>$null
        }
        'js-npm' {
            # Scoped (@...) and n8n-* folders are the runner's own code.
            & docker run --rm --entrypoint ls $image /opt/runners/task-runner-javascript/node_modules 2>$null |
                Where-Object { $_ -notmatch '^(@|n8n-)' }
        }
        'py-stdlib' {
            & docker run --rm --entrypoint /opt/runners/task-runner-python/.venv/bin/python $image -c "import sys; print(','.join(sorted(m for m in sys.stdlib_module_names if not m.startswith('_'))))" 2>$null
        }
    }
    if ($LASTEXITCODE -ne 0) { return '' }
    return (@($out) -join ',').Trim()
}

# Prints the names to copy from, or where to find them when Docker couldn't
# supply the list.
function Show-List([string]$List, [string]$Where) {
    if ($List -eq '') {
        Write-Host "  I couldn't read the list from Docker. The names are at $Where"
        return
    }
    Write-Host '  These come installed:'
    $line = '   '
    foreach ($n in $List.Split(',')) {
        if ($line.Length + $n.Length + 2 -gt 76) { Write-Host $line.TrimEnd(); $line = '   ' }
        $line += " $n,"
    }
    Write-Host $line.TrimEnd(',')
}

# Like Ask, but turns down names that aren't in $List so a typo doesn't slip
# through. An empty $List skips that check.
function Read-Names([string]$Name, [string]$Question, [string]$List) {
    $known = $List.Split(',')
    while ($true) {
        Ask $Name $Question
        if ($List -eq '') { return }
        $bad = @($S[$Name].Split(',') | Where-Object { $_ -ne '' -and $_ -ne '*' -and $known -notcontains $_ })
        if ($bad.Count -eq 0) { return }
        Write-Host "  Not in the list: $($bad -join ', '). Check the spelling against the list above." -ForegroundColor Yellow
    }
}

function Invoke-Questions {
    Write-Host ''
    Write-Host "Each question comes with a suggested answer. If you're not sure, just"
    Write-Host 'press Enter to take it. You can change any of this later by running the'
    Write-Host 'script with -Reconfigure.'

    Ask 'N8N_DATA_DIR' 'Where should n8n keep its workflows, credentials and other data?'

    Ask 'N8N_HOST_PORT' "Which port number should n8n use? If you don't know what that means, just press Enter."

    $hasUrl = if ($S.N8N_WEBHOOK_URL -ne '') { 'y' } else { 'n' }
    if (Ask-YesNo "Will anyone reach this n8n from the internet, at an address like https://n8n.example.com? Say no if you'll only use it on this computer." $hasUrl) {
        while ($true) {
            Ask 'N8N_WEBHOOK_URL' "What's that address? Include the https:// at the start."
            if ($S.N8N_WEBHOOK_URL -ne '') { break }
            Write-Host '  You said people will reach it from the internet, so I need the address.' -ForegroundColor Yellow
        }
    } else {
        $S.N8N_WEBHOOK_URL = ''
    }

    Ask 'TASK_TIMEOUT' "How many seconds should a Code node get to finish before n8n stops it? The suggestion is $(Show-Seconds $S.TASK_TIMEOUT). For 10 minutes, type 600."

    Write-Host ''
    Write-Host 'Next, which code libraries your Code nodes may load. Allowing everything'
    Write-Host 'is easiest, but it also lets a Code node do more on the machine it runs'
    Write-Host 'on. If you want to read up before deciding, see'
    Write-Host 'https://docs.n8n.io/deploy/host-n8n/configure-n8n/security/harden-task-runners'

    $jsNow = ''
    $jsDefault = if ($S.JS_BUILTIN_ALLOW -eq '*' -and $S.JS_EXTERNAL_ALLOW -eq '*') { 1 }
        elseif ($S.JS_BUILTIN_ALLOW -eq 'crypto' -and $S.JS_EXTERNAL_ALLOW -eq 'moment') { 2 }
        elseif ($S.JS_BUILTIN_ALLOW -eq '' -and $S.JS_EXTERNAL_ALLOW -eq '') { 3 }
        else { $jsNow = " (you have $(Show-Value $S.JS_BUILTIN_ALLOW) and $(Show-Value $S.JS_EXTERNAL_ALLOW) now)"; 4 }
    $choice = Select-Option 'Which libraries can JavaScript Code nodes use?' $jsDefault @(
        'Everything that comes installed',
        'Just crypto and moment',
        'None',
        "Let me pick from the full list$jsNow")
    switch ($choice) {
        1 { $S.JS_BUILTIN_ALLOW = '*'; $S.JS_EXTERNAL_ALLOW = '*' }
        2 { $S.JS_BUILTIN_ALLOW = 'crypto'; $S.JS_EXTERNAL_ALLOW = 'moment' }
        3 { $S.JS_BUILTIN_ALLOW = ''; $S.JS_EXTERNAL_ALLOW = '' }
        4 {
            Write-Host ''
            Write-Host 'First, Node.js built-in libraries.'
            $list = Get-ImageList 'js-builtin'
            Show-List $list 'https://nodejs.org/api/'
            Read-Names 'JS_BUILTIN_ALLOW' 'Type the ones to allow, separated by commas:' $list
            Write-Host ''
            Write-Host 'Now npm packages.'
            $list = Get-ImageList 'js-npm'
            Show-List $list 'https://github.com/n8n-io/n8n/tree/master/docker/images/runners'
            Read-Names 'JS_EXTERNAL_ALLOW' 'Type the ones to allow, separated by commas:' $list
        }
    }

    # Python's extra packages in the image are only the runner's own plumbing,
    # so they follow the standard library answer instead of getting a question.
    $pyCommon = 'json,datetime,math,re,random,statistics'
    $pyNow = ''
    $pyDefault = if ($S.PY_STDLIB_ALLOW -eq '*') { 1 }
        elseif ($S.PY_STDLIB_ALLOW -eq $pyCommon) { 2 }
        elseif ($S.PY_STDLIB_ALLOW -eq '') { 3 }
        else { $pyNow = " (you have $($S.PY_STDLIB_ALLOW) now)"; 4 }
    $choice = Select-Option 'Which libraries can Python Code nodes use?' $pyDefault @(
        "Everything in Python's standard library",
        'Just json, datetime, math, re, random and statistics',
        'None',
        "Let me pick from the full list$pyNow")
    switch ($choice) {
        1 { $S.PY_STDLIB_ALLOW = '*'; $S.PY_EXTERNAL_ALLOW = '*' }
        2 { $S.PY_STDLIB_ALLOW = $pyCommon; $S.PY_EXTERNAL_ALLOW = '' }
        3 { $S.PY_STDLIB_ALLOW = ''; $S.PY_EXTERNAL_ALLOW = '' }
        4 {
            Write-Host ''
            $list = Get-ImageList 'py-stdlib'
            Show-List $list 'https://docs.python.org/3/py-modindex.html'
            Read-Names 'PY_STDLIB_ALLOW' 'Type the ones to allow, separated by commas:' $list
            $S.PY_EXTERNAL_ALLOW = ''
        }
    }

    Write-Host ''
    Write-Host 'n8n 2.0 and later switch off two nodes that can run commands and read'
    Write-Host 'files on this computer: Execute Command and Local File Trigger.'
    $execDefault = if ($S.ENABLE_EXEC_NODES -eq 'yes') { 'y' } else { 'n' }
    $S.ENABLE_EXEC_NODES = if (Ask-YesNo 'Do you want them switched back on?' $execDefault) { 'yes' } else { 'no' }

    Write-Host ''
    Write-Host "Here's what you chose:"
    Write-Host "  Data folder:                    $($S.N8N_DATA_DIR)"
    Write-Host "  Port:                           $($S.N8N_HOST_PORT)"
    Write-Host "  Internet address:               $(if ($S.N8N_WEBHOOK_URL) { $S.N8N_WEBHOOK_URL } else { 'none, this computer only' })"
    Write-Host "  Code node time limit:           $(Show-Seconds $S.TASK_TIMEOUT)"
    Write-Host "  JavaScript built-in libraries:  $(Show-Value $S.JS_BUILTIN_ALLOW)"
    Write-Host "  JavaScript npm packages:        $(Show-Value $S.JS_EXTERNAL_ALLOW)"
    Write-Host "  Python libraries:               $(Show-Value $S.PY_STDLIB_ALLOW)"
    Write-Host "  Execute Command and Local File: $($S.ENABLE_EXEC_NODES)"
    if (-not (Ask-YesNo "Does that look right? I'll save it and start n8n." 'y')) {
        Write-Host "OK, nothing was changed. Run the script again when you're ready."
        exit 0
    }
    Save-SettingsFile
}

# ---- Docker -----------------------------------------------------------------
# Everything after the questions needs Docker, so make sure it is installed and
# running before asking anything. A scheduled task has nobody at the keyboard,
# so it must never stop to ask. -NoQuestions guarantees that; the check below
# catches most other cases.

$interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected

if ($Reconfigure -and -not $interactive) {
    Write-Host '-Reconfigure needs someone at the keyboard to answer the questions.' -ForegroundColor Red
    exit 1
}

# Saved answers are loaded now so the downloads below fetch the right version.
# On -Reconfigure they also show up as the answers you get by pressing Enter.
if (Test-Path -LiteralPath $SettingsFile) { Read-SettingsFile }

function Test-DockerRunning {
    & docker info *> $null
    return $LASTEXITCODE -eq 0
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "Docker isn't installed on this computer, and n8n runs inside it." -ForegroundColor Red
    Write-Host 'Install Docker Desktop from https://www.docker.com/products/docker-desktop/'
    Write-Host 'start it, then run this script again.'
    exit 1
}

if (-not (Test-DockerRunning)) {
    $dockerDesktop = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
    if ($NoQuestions -or -not $interactive) {
        Write-Host "Docker isn't running. Trying to start it..."
    } elseif (-not (Ask-YesNo "Docker is installed but isn't running. Do you want me to start it?" 'y')) {
        Write-Host 'OK. Start Docker Desktop yourself, then run this script again.'
        exit 1
    }
    if (Test-Path -LiteralPath $dockerDesktop) {
        Start-Process -FilePath $dockerDesktop
    } else {
        Write-Host "I couldn't find Docker Desktop at $dockerDesktop, so please start it yourself." -ForegroundColor Yellow
    }
    Write-Host 'Waiting for Docker to start' -NoNewline
    $tries = 0
    while (-not (Test-DockerRunning)) {
        $tries++
        if ($tries -gt 60) {
            Write-Host ''
            Write-Host "Docker still isn't running after 3 minutes. Open Docker Desktop yourself," -ForegroundColor Red
            Write-Host "wait until it says it's running, then run this script again."
            exit 1
        }
        Write-Host '.' -NoNewline
        Start-Sleep -Seconds 3
    }
    Write-Host ' Docker is running.'
}

# Start downloading both images now, so they're ready or nearly ready by the
# time the questions are done. The pull step further down waits for them.
$RunnersPull = Start-Process -FilePath (Get-Command docker).Source -ArgumentList 'pull', '-q', "n8nio/runners:$($S.N8N_VERSION)" -WindowStyle Hidden -PassThru
$N8nPull = Start-Process -FilePath (Get-Command docker).Source -ArgumentList 'pull', '-q', "n8nio/n8n:$($S.N8N_VERSION)" -WindowStyle Hidden -PassThru

# The list questions read from the runners image, so they wait for it first.
function Wait-RunnersImage {
    if ($script:RunnersPull -and -not $script:RunnersPull.HasExited) {
        Write-Host '  Waiting for the n8n download to finish so I can read the list...'
        $script:RunnersPull.WaitForExit()
    }
}

# ---- Work out the settings --------------------------------------------------

if ($Reconfigure) {
    Invoke-Questions
} elseif (Test-Path -LiteralPath $SettingsFile) {
    Write-Host "Using settings from $SettingsFile"
} elseif ($NoQuestions -or -not $interactive) {
    Write-Host 'No settings file next to the script; using the values written in it.'
} else {
    Write-Host 'Looks like this is your first time running this, so I have a few'
    Write-Host 'questions to get n8n set up the way you want.'
    Invoke-Questions
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

# ---- Pull images first ------------------------------------------------------
# Pulling before removing anything means a typo in the version or a network
# problem stops the script while your current n8n is still running.

$version = $S.N8N_VERSION
Write-Host "Pulling n8nio/n8n:$version and n8nio/runners:$version..."
# Let the background downloads finish. Pulling again afterwards takes a moment
# and shows a real error if one of them failed.
$RunnersPull.WaitForExit()
$N8nPull.WaitForExit()
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

# Only when someone is watching, so the nightly log stays quiet.
if ($interactive -and -not $NoQuestions) {
    Write-Host ''
    Write-Host 'If this saved you some time, please give it a star on GitHub. Stars are' -ForegroundColor Cyan
    Write-Host 'how other n8n users find it. The Star button is at the top right of:' -ForegroundColor Cyan
    Write-Host 'https://github.com/dtsoden/n8n-docker-task-runners' -ForegroundColor Cyan
}
