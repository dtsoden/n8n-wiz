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
# n8n wiz: install n8n and keep it up to date (Windows, PowerShell)
# https://github.com/dtsoden/n8n-wiz
# =============================================================================
#
# What this script does
#   1. Makes sure Docker is installed and running, offering to start it.
#   2. Starts downloading the n8n and n8n runners images in the background
#      (same version for both).
#   3. Works out your settings, asking the setup questions the first time.
#   4. Finishes the downloads, then stops and removes any old "n8n" and
#      "n8n-runners" containers. If the "n8n" container wasn't set up by this
#      script, a run at the keyboard asks first.
#   5. Creates the data folder and its "files" folder, and writes the launcher
#      config file task-runners.json there.
#   6. Creates a shared random token and starts two containers on one network:
#        n8n          the editor, API and webhooks, plus the task broker on 5679
#        n8n-runners  the n8nio/runners sidecar that runs Code node JavaScript
#                     and Python in its own container, away from n8n itself
#   7. After the setup questions, adds or removes the nightly update.
#
#   Your workflows and credentials live in the data folder on your machine, so
#   removing and recreating the containers does not delete them. That is what
#   makes it safe to run this every night to stay on the latest n8n. The
#   "files" folder is where the Read/Write Files from Disk node reads and
#   writes; inside n8n it is /home/node/.n8n-files.
#
#   This is the Windows version of n8n-setup-mac-linux.sh. The
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
#   -Remove         uninstall: remove n8n, its images, the nightly update and
#                   the saved answers. Asks before deleting your workflows.
#   -Update         replace this script with the newest n8n wiz release. Your
#                   settings file stays as it is, and the old script is kept
#                   next to it as .previous.
#   -Help           show these options and this script's version
#
#   Every run checks GitHub for a newer n8n wiz and says so when there is one.
#   The script never updates itself; that only happens with -Update.
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
#   Line 164  N8N_DATA_DIR        folder on your machine for n8n data
#   Line 170  N8N_VERSION         n8n version; the runners image uses the same one
#   Line 173  N8N_HOST_PORT       port you open in the browser
#   Line 179  N8N_WEBHOOK_URL     the public address of your n8n, if it has one
#   Line 182  DOCKER_NETWORK      only if you already use a different network name
#   Line 187  TASK_TIMEOUT        seconds a Code node may run before it is stopped
#   Lines 200 to 203  JS_* and PY_*  modules the Code node may import
#   Line 208  ENABLE_EXEC_NODES   Execute Command and Local File Trigger on or off
#   Line 216  NIGHTLY_TIME        time of the nightly update, auto or off
#
# How to run (from the folder holding this file)
#   powershell -ExecutionPolicy Bypass -File .\n8n-setup-windows.ps1
#   The -ExecutionPolicy Bypass part applies to this one run only. If Windows
#   still blocks a downloaded file, run: Unblock-File .\n8n-setup-windows.ps1
#
# If n8n feels slow or logs "database is locked": the data folder is a Windows
# folder shared into Docker's Linux VM, and SQLite can struggle there. Swap the
# n8n data mount near the end of this file for a Docker volume: change
# "$($S.N8N_DATA_DIR):/home/node/.n8n" to "n8n_data:/home/node/.n8n".
# =============================================================================

param(
    [switch]$Reconfigure,
    [switch]$NoQuestions,
    [switch]$Remove,
    [switch]$Update
)

# Typed at a PowerShell prompt, --remove (two dashes) or a plain "remove" is
# not treated as an option; it lands in $args and would be silently ignored,
# so the script would just update n8n. Accept the usual spellings of each
# option and stop on anything else.
foreach ($word in $args) {
    switch -Regex ($word) {
        '^(--?|/)?remove$'        { $Remove = [switch]$true }
        '^(--?|/)?update$'        { $Update = [switch]$true }
        '^(--?|/)?reconfigure$'   { $Reconfigure = [switch]$true }
        '^(--?|/)?no-?questions$' { $NoQuestions = [switch]$true }
        '^(--?|/)?(h|help|\?)$'  { $ShowHelp = $true }
        default {
            Write-Host "I don't recognize this option: $word" -ForegroundColor Red
            Write-Host 'The options are -Reconfigure, -NoQuestions, -Remove, -Update and -Help.'
            exit 1
        }
    }
}

# ---- Settings ---------------------------------------------------------------
# Used when there is no settings file. The questions also offer these values
# as the answer you get by pressing Enter.

$S = [ordered]@{
    # Folder on your machine for n8n's data (database, encryption key, binary
    # files) and task-runners.json. Default: C:\Users\<you>\n8n
    N8N_DATA_DIR      = (Join-Path $env:USERPROFILE 'n8n')

    # n8n and n8nio/runners always run the same version. "latest" means the
    # newest release in the major version you're on (2.x stays 2.x). A run at
    # the keyboard asks before moving to a new major version. A number such as
    # "2.45.4" holds you on that release.
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

    # When the script runs by itself every night, as 24-hour HH:MM, or 'off'.
    # 'auto' has the setup questions suggest a time for your time zone: a few
    # hours after n8n usually releases, so you get each new version within
    # hours (README, "Picking a time"). The setup questions add or remove the
    # scheduled task for you. If you edit this file instead, create the task
    # yourself (the README shows how).
    NIGHTLY_TIME      = 'auto'
}

# Both scripts share one version number. Each release is tagged vX.Y.Z on GitHub.
$ScriptVersion = '1.3.0'

# ---- Nothing below this line needs editing ----------------------------------

if ($ShowHelp) {
    Write-Host "n8n-setup-windows.ps1 version $ScriptVersion"
    Write-Host 'Options:'
    Write-Host '  -Reconfigure   ask the setup questions again and save new answers'
    Write-Host '  -NoQuestions   never ask; use the settings file if there is one,'
    Write-Host '                 otherwise the values written in this script'
    Write-Host '  -Remove        uninstall n8n, its images, the nightly update and the'
    Write-Host '                 saved answers; asks before deleting your workflows'
    Write-Host '  -Update        replace this script with the newest n8n wiz release'
    Write-Host "Settings file: $(Join-Path $PSScriptRoot 'n8n-docker-task-runners-settings.env')"
    exit 0
}

# The settings file lives next to this script, wherever it is run from.
$SettingsFile = Join-Path $PSScriptRoot 'n8n-docker-task-runners-settings.env'

# Scheduled runs (always -NoQuestions) have no window, so they keep a log
# next to the script.
if ($NoQuestions) {
    Start-Transcript -LiteralPath (Join-Path $PSScriptRoot 'n8n-nightly.log') -Append | Out-Null
}

# Stops the script with an error and points to the place to report a bug.
function Stop-Script {
    Write-Host ''
    Write-Host 'If this looks like a bug, please report it at' -ForegroundColor Yellow
    Write-Host 'https://github.com/dtsoden/n8n-wiz/issues/new' -ForegroundColor Yellow
    exit 1
}

# An unexpected error stops the script the same way.
trap {
    Write-Host "Something went wrong: $($_.Exception.Message)" -ForegroundColor Red
    Stop-Script
}

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
        'NIGHTLY_TIME'      { return ($Value -eq 'off') -or ($Value -eq 'auto') -or ($Value -match '^([01][0-9]|2[0-3]):[0-5][0-9]$') }
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
            Stop-Script
        }
        $S[$key] = $value
    }
}

function Save-SettingsFile {
    $lines = @(
        "# Settings for n8n-setup-windows.ps1, saved $(Get-Date -Format 'yyyy-MM-dd HH:mm').",
        '# Keep this file in the same folder as the script. Edit the values here,',
        '# or run the script with -Reconfigure to answer the questions again.'
    )
    foreach ($key in $S.Keys) { $lines += "$key=$($S[$key])" }
    [System.IO.File]::WriteAllLines($SettingsFile, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Saved your answers to $SettingsFile" -ForegroundColor Green
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
    Write-Host $Question -ForegroundColor White
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
    $hint = if ($Default -eq 'y') { '  Press Enter for yes, or type n for no' } else { '  Press Enter for no, or type y for yes' }
    Write-Host ''
    Write-Host $Question -ForegroundColor White
    while ($true) {
        $answer = Read-Host $hint
        if ($answer -eq '') { $answer = $Default }
        if ($answer -match '^[Yy]') { return $true }
        if ($answer -match '^[Nn]') { return $false }
        Write-Host '  Please type y for yes or n for no.' -ForegroundColor Yellow
    }
}

# Empty values and * read better in the summary than the stored form.
function Show-Value([string]$Value) {
    if ($Value -eq '') { return 'nothing' }
    if ($Value -eq '*') { return 'everything' }
    return $Value
}

# ConvertTo-Time '2am' returns '02:00'. It understands 2, 2:30, 14:30, 2am,
# 2:30 pm and so on, and returns '' for anything else.
function ConvertTo-Time([string]$Text) {
    $s = $Text.ToLower() -replace '[\s.]', ''
    if ($s -notmatch '^([0-9]{1,2})(:([0-9]{2}))?(am|pm|a|p)?$') { return '' }
    $h = [int]$Matches[1]
    $m = if ($Matches[3]) { [int]$Matches[3] } else { 0 }
    $half = $Matches[4]
    if ($half) {
        if ($h -lt 1 -or $h -gt 12) { return '' }
        if ($h -eq 12) { $h = 0 }
        if ($half.StartsWith('p')) { $h += 12 }
    }
    if ($h -gt 23 -or $m -gt 59) { return '' }
    return '{0:D2}:{1:D2}' -f $h, $m
}

# Show-Time '14:30' returns '2:30 PM'.
function Show-Time([string]$Time) {
    return ([datetime]::ParseExact($Time, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)).ToString('h:mm tt', [Globalization.CultureInfo]::InvariantCulture)
}

# n8n usually publishes new versions on weekdays around 07:20 UTC. The nightly
# update is suggested for 11:30 UTC (6:30 AM US Eastern Standard Time), a few
# hours later, so it picks each one up within hours. ConvertFrom-UtcMinutes 690
# returns 11:30 UTC (690 minutes after midnight) as this computer's local HH:mm.
function ConvertFrom-UtcMinutes([int]$Minutes) {
    $utc = [datetime]::SpecifyKind([datetime]::UtcNow.Date.AddMinutes($Minutes), 'Utc')
    return $utc.ToLocalTime().ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture)
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
function Select-Option([string]$Question, [int]$Default, [string[]]$Options, [string]$Color = 'White') {
    Write-Host ''
    Write-Host $Question -ForegroundColor $Color
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
    $image = "n8nio/runners:$ImageTag"
    & docker image inspect $image *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host '  Downloading the n8n runners image to read the list. This can take a minute...' -ForegroundColor Yellow
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
        Write-Host "  I couldn't read the list from Docker. The names are at $Where" -ForegroundColor Yellow
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
    # A rejected answer must not become the next suggestion.
    $prev = $S[$Name]
    while ($true) {
        Ask $Name $Question
        if ($List -eq '') { return }
        $bad = @($S[$Name].Split(',') | Where-Object { $_ -ne '' -and $_ -ne '*' -and $known -notcontains $_ })
        if ($bad.Count -eq 0) { return }
        Write-Host "  Not in the list: $($bad -join ', '). Check the spelling against the list above." -ForegroundColor Yellow
        $S[$Name] = $prev
    }
}

# Prints the n8n wiz title in the header color.
function Show-Banner {
    Write-Host @'
            /$$$$$$                                /$$
           /$$__  $$                              |__/
 /$$$$$$$ | $$  \ $$ /$$$$$$$        /$$  /$$  /$$ /$$ /$$$$$$$$
| $$__  $$|  $$$$$$/| $$__  $$      | $$ | $$ | $$| $$|____ /$$/
| $$  \ $$ >$$__  $$| $$  \ $$      | $$ | $$ | $$| $$   /$$$$/
| $$  | $$| $$  \ $$| $$  | $$      | $$ | $$ | $$| $$  /$$__/
| $$  | $$|  $$$$$$/| $$  | $$      |  $$$$$/$$$$/| $$ /$$$$$$$$
|__/  |__/ \______/ |__/  |__/       \_____/\___/ |__/|________/
'@ -ForegroundColor Cyan
    Write-Host "  version $ScriptVersion" -ForegroundColor DarkGray
}

# Clears the screen so each question stands on its own instead of scrolling
# under the ones before it.
function Show-NewScreen([string]$Title, [string]$Color = 'Cyan') {
    try { Clear-Host } catch { Write-Host "" }
    Write-Host "Setting up n8n: $Title" -ForegroundColor $Color
    Write-Host "If you're not sure, press Enter to take the suggested answer." -ForegroundColor DarkGray
    Write-Host 'Made a mistake? You can change any answer on the summary screen at the end.' -ForegroundColor DarkGray
}

function Invoke-Question1 {
    Show-NewScreen 'question 1 of 8, Data folder'
    Ask 'N8N_DATA_DIR' 'Where should n8n keep its workflows, credentials and other data?'
}

function Invoke-Question2 {
    Show-NewScreen 'question 2 of 8, Port'
    Ask 'N8N_HOST_PORT' "Which port number should n8n use? If you don't know what that means, just press Enter."
}

function Invoke-Question3 {
    Show-NewScreen 'question 3 of 8, Internet address'
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
}

function Invoke-Question4 {
    Show-NewScreen 'question 4 of 8, Code node time limit'
    Ask 'TASK_TIMEOUT' "How many seconds should a Code node get to finish before n8n stops it? The suggestion is $(Show-Seconds $S.TASK_TIMEOUT). For 10 minutes, type 600."
}

function Invoke-Question5 {
    Show-NewScreen 'question 5 of 8, JavaScript libraries' 'Yellow'
    Write-Host ''
    Write-Host 'Allowing everything is easiest, but it also lets a Code node do more on' -ForegroundColor DarkGray
    Write-Host 'the machine it runs on. If you want to read up before deciding, see' -ForegroundColor DarkGray
    Write-Host 'https://docs.n8n.io/deploy/host-n8n/configure-n8n/security/harden-task-runners' -ForegroundColor DarkGray

    $jsNow = ''
    $jsDefault = if ($S.JS_BUILTIN_ALLOW -eq '*' -and $S.JS_EXTERNAL_ALLOW -eq '*') { 1 }
        elseif ($S.JS_BUILTIN_ALLOW -eq 'crypto' -and $S.JS_EXTERNAL_ALLOW -eq 'moment') { 2 }
        elseif ($S.JS_BUILTIN_ALLOW -eq '' -and $S.JS_EXTERNAL_ALLOW -eq '') { 3 }
        else { $jsNow = " (you have $(Show-Value $S.JS_BUILTIN_ALLOW) and $(Show-Value $S.JS_EXTERNAL_ALLOW) now)"; 4 }
    $choice = Select-Option 'Which libraries can JavaScript Code nodes use?' $jsDefault @(
        'Everything that comes installed',
        'Just crypto and moment',
        'None',
        "Let me pick from the full list$jsNow") 'Yellow'
    switch ($choice) {
        1 { $S.JS_BUILTIN_ALLOW = '*'; $S.JS_EXTERNAL_ALLOW = '*' }
        2 { $S.JS_BUILTIN_ALLOW = 'crypto'; $S.JS_EXTERNAL_ALLOW = 'moment' }
        3 { $S.JS_BUILTIN_ALLOW = ''; $S.JS_EXTERNAL_ALLOW = '' }
        4 {
            Write-Host ''
            Write-Host 'First, Node.js built-in libraries.' -ForegroundColor White
            $list = Get-ImageList 'js-builtin'
            Show-List $list 'https://nodejs.org/api/'
            Read-Names 'JS_BUILTIN_ALLOW' 'Type the ones to allow, separated by commas:' $list
            Write-Host ''
            Write-Host 'Now npm packages.' -ForegroundColor White
            $list = Get-ImageList 'js-npm'
            Show-List $list 'https://github.com/n8n-io/n8n/tree/master/docker/images/runners'
            Read-Names 'JS_EXTERNAL_ALLOW' 'Type the ones to allow, separated by commas:' $list
        }
    }

}

# Python's extra packages in the image are only the runner's own plumbing,
# so they follow the standard library answer instead of getting a question.
function Invoke-Question6 {
    Show-NewScreen 'question 6 of 8, Python libraries' 'Magenta'
    Write-Host ''
    Write-Host 'Allowing everything is easiest, but it also lets a Code node do more on' -ForegroundColor DarkGray
    Write-Host 'the machine it runs on. If you want to read up before deciding, see' -ForegroundColor DarkGray
    Write-Host 'https://docs.n8n.io/deploy/host-n8n/configure-n8n/security/harden-task-runners' -ForegroundColor DarkGray
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
        "Let me pick from the full list$pyNow") 'Magenta'
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
}

function Invoke-Question7 {
    Show-NewScreen 'question 7 of 8, Execute Command and Local File Trigger'
    Write-Host ''
    Write-Host 'n8n 2.0 and later switch off two nodes for safety:'
    Write-Host ''
    Write-Host '  Execute Command     runs any command you give it, such as a script or a'
    Write-Host "                      program. It runs inside n8n's Docker container."
    Write-Host '  Local File Trigger  starts a workflow when a file or folder changes.'
    Write-Host ''
    Write-Host 'If you say no, workflows that use either of these two nodes stop working.'
    Write-Host 'Everything else keeps working, including Read/Write Files from Disk,'
    Write-Host 'Compression (zip and unzip), and Convert to File / Extract from File.'
    Write-Host ''
    Write-Host 'If you say yes, anyone who can edit workflows on this n8n can run any'
    Write-Host 'command inside its container, which holds your saved credentials and the'
    Write-Host "key that unlocks them. If you're the only person using this n8n, that"
    Write-Host 'risk is small. If you use Execute Command today, say yes.'
    $execDefault = if ($S.ENABLE_EXEC_NODES -eq 'yes') { 'y' } else { 'n' }
    $S.ENABLE_EXEC_NODES = if (Ask-YesNo 'Do you want them switched back on?' $execDefault) { 'yes' } else { 'no' }
}

function Invoke-Question8 {
    Show-NewScreen 'question 8 of 8, Nightly update'
    $nightlyDefault = if ($S.NIGHTLY_TIME -eq 'off') { 'n' } else { 'y' }
    if (Ask-YesNo 'Do you want this script to run by itself every night, so n8n always stays up to date? This computer needs to be on and you need to be signed in at that time.' $nightlyDefault) {
        # A saved time stays as it is. Otherwise suggest 11:30 UTC in local
        # time, or 2:00 AM where that falls in the daytime (9 AM or later).
        $suggested = 'no'
        if ($S.NIGHTLY_TIME -eq 'off' -or $S.NIGHTLY_TIME -eq 'auto') {
            $S.NIGHTLY_TIME = ConvertFrom-UtcMinutes 690
            $suggested = 'yes'
            if ([int]$S.NIGHTLY_TIME.Substring(0, 2) -ge 9) { $S.NIGHTLY_TIME = '02:00'; $suggested = 'night' }
        }
        Write-Host ''
        Write-Host 'What time should it run? n8n is down for a few seconds while it updates,' -ForegroundColor White
        Write-Host 'so pick a time nobody is using it. You can type 2am, 2:30am, 11pm or 23:00.' -ForegroundColor White
        Write-Host "New n8n versions usually come out on weekdays around $(Show-Time (ConvertFrom-UtcMinutes 440)) your time." -ForegroundColor DarkGray
        if ($suggested -eq 'yes') {
            Write-Host "Running at $(Show-Time $S.NIGHTLY_TIME), a few hours later, gets you each one within hours." -ForegroundColor DarkGray
        } elseif ($suggested -eq 'night') {
            Write-Host "That's during your day, so 2:00 AM is suggested. It gets each one that night." -ForegroundColor DarkGray
        }
        while ($true) {
            $answer = Read-Host "  Press Enter for $(Show-Time $S.NIGHTLY_TIME), or type a time"
            if ($answer -eq '') { $answer = $S.NIGHTLY_TIME }
            $time = ConvertTo-Time $answer
            if ($time -ne '') { $S.NIGHTLY_TIME = $time; break }
            Write-Host "  Sorry, I didn't understand that time. Try something like 2am or 23:00." -ForegroundColor Yellow
        }
    } else {
        $S.NIGHTLY_TIME = 'off'
    }
}

# Every answer on one numbered screen. Typing a number shows that question
# again, so a mistake is easy to fix before anything is saved.
function Invoke-Questions {
    try { Clear-Host } catch { Write-Host '' }
    Show-Banner
    Write-Host ''
    Write-Host "Welcome. This sets up n8n on this computer and keeps it up to date."
    Write-Host "You'll answer 8 quick questions, each with a suggested answer. If you're"
    Write-Host "not sure, press Enter to take it. You can fix any answer at the end."
    Write-Host ''
    Read-Host '  Press Enter to start' | Out-Null
    foreach ($n in 1..8) { & "Invoke-Question$n" }
    $note = ''
    while ($true) {
        try { Clear-Host } catch { Write-Host '' }
        Write-Host 'Setting up n8n: check your answers' -ForegroundColor Cyan
        Write-Host ''
        Write-Host "  1  Data folder:                    $($S.N8N_DATA_DIR)"
        Write-Host "  2  Port:                           $($S.N8N_HOST_PORT)"
        Write-Host "  3  Internet address:               $(if ($S.N8N_WEBHOOK_URL) { $S.N8N_WEBHOOK_URL } else { 'none, this computer only' })"
        Write-Host "  4  Code node time limit:           $(Show-Seconds $S.TASK_TIMEOUT)"
        Write-Host "  5  JavaScript built-in libraries:  $(Show-Value $S.JS_BUILTIN_ALLOW)" -ForegroundColor Yellow
        Write-Host "     JavaScript npm packages:        $(Show-Value $S.JS_EXTERNAL_ALLOW)" -ForegroundColor Yellow
        Write-Host "  6  Python libraries:               $(Show-Value $S.PY_STDLIB_ALLOW)" -ForegroundColor Magenta
        Write-Host "  7  Execute Command and Local File: $($S.ENABLE_EXEC_NODES)"
        if ($S.NIGHTLY_TIME -eq 'off') {
            Write-Host '  8  Nightly update:                 off'
        } else {
            Write-Host "  8  Nightly update:                 every night at $(Show-Time $S.NIGHTLY_TIME)"
        }
        Write-Host ''
        Write-Host 'You can also change any of this later by running the script with -Reconfigure.' -ForegroundColor DarkGray
        Write-Host 'To quit without saving anything, press Ctrl+C.' -ForegroundColor DarkGray
        if ($note) { Write-Host ''; Write-Host "  $note" -ForegroundColor Yellow; $note = '' }
        Write-Host ''
        $answer = Read-Host '  Press Enter to save and start n8n, or type a number to change that answer'
        if ([string]::IsNullOrEmpty($answer)) { break }
        if ($answer -match '^[1-8]$') { & "Invoke-Question$answer" }
        else { $note = 'Please press Enter, or type a number from 1 to 8.' }
    }
    $script:AskedQuestions = $true
    Save-SettingsFile
}

# ---- Docker -----------------------------------------------------------------
# Everything after the questions needs Docker, so make sure it is installed and
# running before asking anything. A scheduled task has nobody at the keyboard,
# so it must never stop to ask. -NoQuestions guarantees that; the check below
# catches most other cases.

$interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected

# ---- Updating n8n wiz itself -------------------------------------------------
# Each run asks GitHub for the newest n8n wiz release and says when there's a
# newer one. -Update installs it, but only when someone asks for it. The script
# never replaces itself on its own, so new code from GitHub never runs on a
# machine until a person decides it should.

$GitHubRepo = 'dtsoden/n8n-wiz'

# The newest n8n wiz release on GitHub, e.g. 1.2.0, or '' if it can't be reached.
function Get-NewestScriptVersion {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $r = Invoke-RestMethod -UseBasicParsing -TimeoutSec 10 "https://api.github.com/repos/$GitHubRepo/releases/latest"
        $v = ([string]$r.tag_name) -replace '^v', ''
        if ($v -match '^\d+\.\d+\.\d+$') { return $v }
    } catch { }
    return ''
}

function Invoke-Update {
    Write-Host 'Checking GitHub for the newest n8n wiz...'
    $newest = Get-NewestScriptVersion
    if (-not $newest) {
        Write-Host "I couldn't reach GitHub to check for a newer n8n wiz. Try again later." -ForegroundColor Red
        exit 1
    }
    if ([version]$ScriptVersion -ge [version]$newest) {
        Write-Host "You already have the newest n8n wiz ($ScriptVersion)." -ForegroundColor Green
        exit 0
    }
    Write-Host "Downloading n8n wiz $newest..."
    $tmp = "$PSCommandPath.new"
    # Check the download before using it: it must be a script PowerShell can
    # read, and it must say it is the version the release says it is.
    $ok = $false
    try {
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -OutFile $tmp -Uri "https://github.com/$GitHubRepo/releases/download/v$newest/n8n-setup-windows.ps1"
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$null, [ref]$errors) | Out-Null
        $text = Get-Content -LiteralPath $tmp -Raw
        $ok = ($errors.Count -eq 0) -and ($text -match ("(?m)^\`$ScriptVersion = '" + [regex]::Escape($newest) + "'"))
    } catch { $ok = $false }
    if (-not $ok) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Write-Host "The download didn't come through right, so nothing was changed. Try again later." -ForegroundColor Red
        exit 1
    }
    Copy-Item -LiteralPath $PSCommandPath -Destination "$PSCommandPath.previous" -Force
    Move-Item -LiteralPath $tmp -Destination $PSCommandPath -Force
    Write-Host "Updated n8n wiz from $ScriptVersion to $newest." -ForegroundColor Green
    Write-Host 'Your settings are unchanged. The old version is saved as'
    Write-Host "  $PSCommandPath.previous"
    Write-Host "What's new: https://github.com/$GitHubRepo/releases/tag/v$newest"
    Write-Host 'The nightly update uses the new version from tonight.'
    exit 0
}

if ($Update) { Invoke-Update }

# The title shows whenever someone is watching, but never in the nightly log.
if ($interactive -and -not $NoQuestions) {
    Show-Banner
    Write-Host ''
} else {
    # The nightly log still records which version ran.
    Write-Host "n8n-setup-windows.ps1 version $ScriptVersion, $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
}

# Say so when a newer n8n wiz is out. Quiet when GitHub can't be reached.
$NewestScript = ''
if (-not $Remove) {
    $NewestScript = Get-NewestScriptVersion
    if ($NewestScript -and [version]$ScriptVersion -lt [version]$NewestScript) {
        Write-Host "n8n wiz $NewestScript is available (you have $ScriptVersion). Run this script with -Update to get it." -ForegroundColor Yellow
        Write-Host "What's new: https://github.com/$GitHubRepo/releases/tag/v$NewestScript"
    } else {
        $NewestScript = ''
    }
}

if ($Reconfigure -and -not $interactive) {
    Write-Host '-Reconfigure needs someone at the keyboard to answer the questions.' -ForegroundColor Red
    Stop-Script
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
    Stop-Script
}

if (-not (Test-DockerRunning)) {
    $dockerDesktop = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
    if ($NoQuestions -or -not $interactive) {
        Write-Host "Docker isn't running. Trying to start it..." -ForegroundColor Yellow
    } elseif (-not (Ask-YesNo "Docker is installed but isn't running. Do you want me to start it?" 'y')) {
        Write-Host 'OK. Start Docker Desktop yourself, then run this script again.'
        Stop-Script
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
            Write-Host "wait until it says it's running, then run this script again." -ForegroundColor Red
            Stop-Script
        }
        Write-Host '.' -NoNewline
        Start-Sleep -Seconds 3
    }
    Write-Host ' Docker is running.' -ForegroundColor Green
}

# ---- Uninstall (-Remove) ----------------------------------------------------
# Takes away everything this script set up. Your workflows and credentials are
# a separate question, and deleting them means typing the word "delete", so a
# stray Enter can't wipe them.

function Invoke-Remove {
    if (-not $interactive) {
        Write-Host '-Remove needs someone at the keyboard to confirm.' -ForegroundColor Red
        exit 1
    }
    try { Clear-Host } catch { Write-Host '' }
    Show-Banner
    Write-Host ''
    Write-Host 'Removing n8n from this computer' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'This will:'
    Write-Host '  - stop and delete the n8n and n8n-runners containers'
    Write-Host "  - delete the $($S.DOCKER_NETWORK) Docker network"
    Write-Host '  - delete the downloaded n8n and n8n runners images'
    Write-Host '  - turn off the nightly update'
    Write-Host '  - delete your saved answers and the nightly log next to this script'
    Write-Host ''
    Write-Host "Your workflows, credentials and files in $($S.N8N_DATA_DIR) are kept"
    Write-Host 'unless you choose otherwise on the next question.'
    if (-not (Ask-YesNo 'Remove n8n?' 'n')) {
        Write-Host 'OK, nothing was removed.'
        exit 0
    }

    $deleteData = $false
    $dataDir = $S.N8N_DATA_DIR
    if ((Test-Path -LiteralPath $dataDir) -and $dataDir.TrimEnd('\') -ne $env:USERPROFILE.TrimEnd('\') -and $dataDir.Length -gt 3) {
        Write-Host ''
        Write-Host "Do you also want to delete ${dataDir}?" -ForegroundColor Red
        Write-Host "That's every workflow, credential and file n8n has. It can't be undone."
        $answer = Read-Host '  Type delete to delete it, or press Enter to keep it'
        $deleteData = ($answer -eq 'delete')
    }

    Write-Host ''
    Write-Host 'Removing the containers...'
    foreach ($name in @('n8n', 'n8n-runners')) {
        $id = & docker ps -aq --filter "name=^$name$"
        if ($id) { & docker rm -f $name *> $null }
    }
    Write-Host 'Removing the network...'
    $net = & docker network ls -q --filter "name=^$($S.DOCKER_NETWORK)$"
    if ($net) { & docker network rm $S.DOCKER_NETWORK *> $null }
    Write-Host 'Removing the images...'
    $images = @(& docker images -q n8nio/n8n) + @(& docker images -q n8nio/runners) | Where-Object { $_ }
    if ($images) { & docker rmi -f @($images | Select-Object -Unique) *> $null }
    if (Get-ScheduledTask -TaskName 'n8n nightly update' -ErrorAction SilentlyContinue) {
        Write-Host 'Turning off the nightly update...'
        Unregister-ScheduledTask -TaskName 'n8n nightly update' -Confirm:$false
    }
    Write-Host 'Removing the saved answers and the nightly log...'
    Remove-Item -LiteralPath $SettingsFile, (Join-Path $PSScriptRoot 'n8n-nightly.log'), "$PSCommandPath.previous" -Force -ErrorAction SilentlyContinue

    Write-Host ''
    if ($deleteData) {
        Remove-Item -LiteralPath $dataDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $dataDir) {
            Write-Host "Some files in $dataDir couldn't be deleted. Close anything using them and delete the folder yourself." -ForegroundColor Yellow
        } else {
            Write-Host "Deleted $dataDir."
        }
    } else {
        Write-Host "Your workflows, credentials and files are still in $dataDir."
        Write-Host 'Run this script again any time to bring n8n back with them.'
    }
    Write-Host 'n8n has been removed.' -ForegroundColor Green
    Write-Host "This script is still here; delete its folder if you don't need it anymore."
    exit 0
}

if ($Remove) { Invoke-Remove }

# ---- Which n8n version to run -----------------------------------------------
# A new major version of n8n (2.x to 3.x) almost always has breaking changes,
# so "latest" means the newest release in the major version already installed.
# Unattended runs never move up a major version. A run at the keyboard asks.

# The n8n version an image or container holds, e.g. 2.45.4, read from its JSON
# because Windows PowerShell 5.1 mangles the quotes a --format template needs.
function Get-N8nVersion([string]$Kind, [string]$Name) {
    $json = & docker $Kind inspect $Name 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { return '' }
    $o = @(($json | Out-String) | ConvertFrom-Json)[0]
    if ($o.Config.Labels) { return [string]$o.Config.Labels.'org.opencontainers.image.version' }
    return ''
}

# The newest stable $Major.x.y release on Docker Hub, or '' if Docker Hub can't
# be reached. The beta and next tags can point at a pre-release that still has
# a plain number, so those are skipped.
function Get-NewestInMajor([string]$Major) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $hub = 'https://hub.docker.com/v2/repositories/n8nio/n8n/tags'
        $skip = @('beta', 'next') | ForEach-Object { (Invoke-RestMethod -UseBasicParsing -TimeoutSec 20 "$hub/$_").digest }
        $r = Invoke-RestMethod -UseBasicParsing -TimeoutSec 20 "$hub`?name=$Major.&page_size=100&ordering=last_updated"
        $tags = @($r.results | Where-Object { $_.name -match "^$Major\.\d+\.\d+$" -and $skip -notcontains $_.digest })
        if (-not $tags) { return '' }
        return ($tags | Sort-Object { [version]$_.name } | Select-Object -Last 1).name
    } catch { return '' }
}

function Confirm-MajorUpgrade([string]$Current, [string]$Newest) {
    $newMajor = $Newest.Split('.')[0]
    try { Clear-Host } catch { Write-Host '' }
    Show-Banner
    Write-Host ''
    Write-Host "n8n $Newest is out. You're on n8n $Current." -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'A new major version usually has breaking changes. Some nodes are removed'
    Write-Host 'and some defaults change, so a few workflows may need fixing first.'
    Write-Host 'Before upgrading, open n8n, go to Settings > Migration Report and fix what'
    Write-Host "it flags, and back up your data folder. What's changing:"
    Write-Host "https://docs.n8n.io/changelog/v$($newMajor)0-breaking-changes"
    Write-Host ''
    Write-Host "If you say no, you stay on n8n $($Current.Split('.')[0]) and keep getting its updates."
    return (Ask-YesNo "Upgrade to n8n $Newest now?" 'n')
}

$ImageTag = $S.N8N_VERSION
if ($S.N8N_VERSION -eq 'latest') {
    $current = Get-N8nVersion 'container' 'n8n'
    Write-Host 'Checking for the newest n8n...'
    $newest = ''
    & docker pull -q n8nio/n8n:latest *> $null
    if ($LASTEXITCODE -eq 0) { $newest = Get-N8nVersion 'image' 'n8nio/n8n:latest' }
    $versionPattern = '^\d+\.\d+\.\d+$'
    if ($newest -notmatch $versionPattern) {
        # Couldn't check, so keep what's running (or plain latest on a new install).
        $ImageTag = if ($current) { $current } else { 'latest' }
    } elseif ($current -notmatch $versionPattern -or $current.Split('.')[0] -eq $newest.Split('.')[0]) {
        $ImageTag = $newest
    } elseif ([int]$newest.Split('.')[0] -gt [int]$current.Split('.')[0]) {
        if ($interactive -and -not $NoQuestions -and -not $Remove -and (Confirm-MajorUpgrade $current $newest)) {
            $ImageTag = $newest
        } else {
            $curMajor = $current.Split('.')[0]
            $ImageTag = Get-NewestInMajor $curMajor
            if ($ImageTag -notmatch $versionPattern) { $ImageTag = $current }
            Write-Host "n8n $($newest.Split('.')[0]) is available. Staying on n8n $curMajor ($ImageTag)." -ForegroundColor Yellow
            Write-Host 'To upgrade, run this script yourself and say yes when it asks.'
        }
    } else {
        # Already on something newer than latest, such as a beta. Leave it.
        $ImageTag = $current
    }
    # Never move back to an older release: n8n doesn't support downgrades, and
    # its database may already have the newer version's changes.
    if ($current -match $versionPattern -and $ImageTag -match $versionPattern -and [version]$ImageTag -lt [version]$current) {
        Write-Host "You're on n8n $current, newer than $ImageTag. Staying on $current." -ForegroundColor Yellow
        $ImageTag = $current
    }
}

# Start downloading both images now, so they're ready or nearly ready by the
# time the questions are done. The pull step further down waits for them.
$RunnersPull = Start-Process -FilePath (Get-Command docker).Source -ArgumentList 'pull', '-q', "n8nio/runners:$ImageTag" -WindowStyle Hidden -PassThru
$N8nPull = Start-Process -FilePath (Get-Command docker).Source -ArgumentList 'pull', '-q', "n8nio/n8n:$ImageTag" -WindowStyle Hidden -PassThru

# The list questions read from the runners image, so they wait for it first.
function Wait-RunnersImage {
    if ($script:RunnersPull -and -not $script:RunnersPull.HasExited) {
        Write-Host '  Waiting for the n8n download to finish so I can read the list...' -ForegroundColor DarkGray
        $script:RunnersPull.WaitForExit()
    }
}

# ---- An n8n that was set up some other way ---------------------------------
# On a first run, an existing "n8n" container was set up by something else,
# and this script would replace it. Say so, ask first, and suggest that
# container's data folder, port and public address so nothing gets lost.
# Containers this script starts carry this label, so it can tell its own n8n
# from one set up some other way.
$OurLabel = 'n8n-docker-task-runners=managed'

function Test-OurN8n {
    $c = @((& docker container inspect n8n 2>$null) | Out-String | ConvertFrom-Json)[0]
    return ($c -and $c.Config.Labels -and $c.Config.Labels.'n8n-docker-task-runners' -eq 'managed')
}

# docker inspect's JSON is read instead of a --format template, because
# Windows PowerShell 5.1 mangles the double quotes a template needs.

function Use-ExistingN8n {
    & docker container inspect n8n *> $null
    if ($LASTEXITCODE -ne 0) { return }
    $c = @((& docker container inspect n8n) | Out-String | ConvertFrom-Json)[0]
    $mount = $c.Mounts | Where-Object { $_.Destination -eq '/home/node/.n8n' } | Select-Object -First 1
    $port = ''
    if ($c.HostConfig.PortBindings -and $c.HostConfig.PortBindings.'5678/tcp') {
        $port = [string]$c.HostConfig.PortBindings.'5678/tcp'[0].HostPort
    }
    $envs = @($c.Config.Env)
    $url = ''
    foreach ($e in $envs) {
        if ($e -match '^(N8N_)?WEBHOOK_URL=(.+)$') { $url = $Matches[2]; break }
    }

    try { Clear-Host } catch { Write-Host '' }
    Show-Banner
    Write-Host ''
    Write-Host "There's already an n8n on this computer, in a container called n8n." -ForegroundColor Yellow
    Write-Host 'If you go ahead, this script replaces that container with its own setup.'
    Write-Host ''
    if ($mount -and $mount.Type -eq 'bind' -and $mount.Source) {
        Write-Host "Its workflows and credentials are in $($mount.Source)."
        Write-Host "I'll suggest that folder as the data folder, so they carry over."
        $S.N8N_DATA_DIR = $mount.Source
    } elseif ($mount -and $mount.Type -eq 'volume') {
        Write-Host "Its workflows and credentials are in a Docker volume called $($mount.Name)," -ForegroundColor Yellow
        Write-Host 'not in a folder. This script uses a folder, so the new n8n would' -ForegroundColor Yellow
        Write-Host "start empty. The volume itself isn't deleted." -ForegroundColor Yellow
    } else {
        Write-Host "I couldn't tell where its workflows and credentials are kept." -ForegroundColor Yellow
    }
    if ($port -and (Test-Setting 'N8N_HOST_PORT' $port)) {
        Write-Host "It uses port $port, so I'll suggest that too."
        $S.N8N_HOST_PORT = $port
    }
    if ($url -and (Test-Setting 'N8N_WEBHOOK_URL' $url)) {
        Write-Host "Its public address is $url, so I'll suggest that as well."
        $S.N8N_WEBHOOK_URL = $url
    }
    if ($envs | Where-Object { $_ -like 'N8N_ENCRYPTION_KEY=*' }) {
        Write-Host ''
        Write-Host "It also sets its encryption key directly, and this script doesn't. Without" -ForegroundColor Red
        Write-Host "that key the new n8n can't read your saved credentials. Only go ahead if" -ForegroundColor Red
        Write-Host "you know the same key is saved in the data folder's config file." -ForegroundColor Red
    }
    Write-Host ''
    Write-Host "Any other settings you gave the old container aren't carried over."
    if (-not (Ask-YesNo 'Do you want to replace it?' 'n')) {
        Write-Host 'OK, nothing was changed.'
        exit 0
    }
}

# A run at the keyboard with saved answers would otherwise replace, without a
# word, an n8n that something else installed or replaced since the last run.
# Say so, show what will be used, and ask first.
function Confirm-ForeignN8n {
    & docker container inspect n8n *> $null
    if ($LASTEXITCODE -ne 0 -or (Test-OurN8n)) { return }
    $c = @((& docker container inspect n8n) | Out-String | ConvertFrom-Json)[0]
    $mount = $c.Mounts | Where-Object { $_.Destination -eq '/home/node/.n8n' } | Select-Object -First 1
    $port = ''
    if ($c.HostConfig.PortBindings -and $c.HostConfig.PortBindings.'5678/tcp') {
        $port = [string]$c.HostConfig.PortBindings.'5678/tcp'[0].HostPort
    }
    Write-Host ''
    Write-Host "The n8n running now wasn't set up by n8n wiz. Something else may have" -ForegroundColor Yellow
    Write-Host 'installed or replaced it since you last ran this script.' -ForegroundColor Yellow
    Write-Host "If you go ahead, it's replaced using your saved n8n wiz settings:"
    Write-Host "  Data folder: $($S.N8N_DATA_DIR)"
    if ($mount -and $mount.Source -and ($mount.Source.TrimEnd('\', '/') -ne $S.N8N_DATA_DIR.TrimEnd('\', '/'))) {
        Write-Host "  The running n8n keeps its data in $($mount.Source) instead. Its workflows" -ForegroundColor Red
        Write-Host "  only come along if that's the same folder." -ForegroundColor Red
    }
    Write-Host "  Port:        $($S.N8N_HOST_PORT)"
    if ($port -and $port -ne $S.N8N_HOST_PORT) {
        Write-Host "  The running n8n uses port $port." -ForegroundColor Yellow
    }
    if (-not (Ask-YesNo 'Do you want to replace it with your n8n wiz setup?' 'n')) {
        Write-Host 'OK, nothing was changed.'
        exit 0
    }
}

# ---- Work out the settings --------------------------------------------------

if ($Reconfigure) {
    if (-not (Test-Path -LiteralPath $SettingsFile)) { Use-ExistingN8n } else { Confirm-ForeignN8n }
    Invoke-Questions
} elseif (Test-Path -LiteralPath $SettingsFile) {
    Write-Host "Using settings from $SettingsFile"
    if ($interactive -and -not $NoQuestions) { Confirm-ForeignN8n }
} elseif ($NoQuestions -or -not $interactive) {
    # Nobody is here to answer the question Use-ExistingN8n asks, so an n8n
    # this script didn't create is left alone rather than replaced. This is a
    # deliberate stop, so it skips the bug-report link.
    & docker container inspect n8n *> $null
    if ($LASTEXITCODE -eq 0 -and -not (Test-OurN8n)) {
        Write-Host "There's an n8n on this computer that this script didn't set up, and" -ForegroundColor Red
        Write-Host "there's no settings file next to the script, so nothing was changed." -ForegroundColor Red
        Write-Host 'Run the script once without -NoQuestions to decide what to do with it.'
        exit 1
    }
    Write-Host 'No settings file next to the script; using the values written in it.'
} else {
    Use-ExistingN8n
    Invoke-Questions
}

# Values typed straight into this script are checked here too.
foreach ($key in @($S.Keys)) {
    if (-not (Test-Setting $key $S[$key])) {
        Write-Host "The value for $key doesn't work: $($S[$key])" -ForegroundColor Red
        Stop-Script
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
        Stop-Script
    }
}

# ---- Pull images first ------------------------------------------------------
# Pulling before removing anything means a typo in the version or a network
# problem stops the script while your current n8n is still running.

$version = $ImageTag
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
New-Item -ItemType Directory -Force -Path (Join-Path $S.N8N_DATA_DIR 'files') | Out-Null

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
        "--no-experimental-webstorage",
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
    '--label', $OurLabel,
    '--restart', 'always',
    '--network', $network,
    # n8n listens on 5678 inside the container
    '-p', "$($S.N8N_HOST_PORT):5678",
    # Keeps your data on your machine
    '-v', "$($S.N8N_DATA_DIR):/home/node/.n8n",
    # n8n 2.x limits Read/Write Files from Disk to /home/node/.n8n-files.
    # Linking it to a folder on your machine keeps those files through updates
    # and lets you add or collect them.
    '-v', "$(Join-Path $S.N8N_DATA_DIR 'files'):/home/node/.n8n-files",
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
    '-e', 'N8N_NATIVE_PYTHON_RUNNER=true',
    # Keep the 2.x Compression node limits (2 GiB unzipped, 5000 files),
    # which n8n 3.0 lowers
    '-e', 'N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES=2147483648',
    '-e', 'N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES=5000',
    # Keep installed community nodes loading, which n8n 3.0 turns off by default
    '-e', 'N8N_UNVERIFIED_PACKAGES_ENABLED=true'
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
    '--label', $OurLabel,
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
Write-Host "Done. Open http://localhost:$($S.N8N_HOST_PORT)" -ForegroundColor Green
Write-Host 'Check the runners connected with: docker logs n8n'
Write-Host '(look for two lines starting with: Registered runner)'

# ---- Nightly schedule -------------------------------------------------------
# Only after the questions, so a nightly run never rewrites its own schedule.
# The task runs as you, only while you're signed in, which is also when Docker
# Desktop is running. Creating it that way doesn't need an administrator.

if ($script:AskedQuestions) {
    Write-Host ''
    $taskName = 'n8n nightly update'
    try {
        if ($S.NIGHTLY_TIME -eq 'off') {
            if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
                Write-Host 'The nightly update is turned off.' -ForegroundColor Green
            }
        } else {
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -NoQuestions"
            $trigger = New-ScheduledTaskTrigger -Daily -At $S.NIGHTLY_TIME
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Description 'Keeps n8n up to date. Created by n8n-setup-windows.ps1.' -Force -ErrorAction Stop | Out-Null
            Write-Host "n8n will update itself every night at $(Show-Time $S.NIGHTLY_TIME)." -ForegroundColor Green
            Write-Host "Each run is logged to $(Join-Path $PSScriptRoot 'n8n-nightly.log')"
        }
    } catch {
        Write-Host "I couldn't set up the nightly update: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host 'The README shows how to add it by hand.' -ForegroundColor Yellow
    }
}

# Only when someone is watching, so the nightly log stays quiet.
if ($interactive -and -not $NoQuestions) {
    Write-Host ''
    if ($NewestScript) {
        Write-Host "n8n wiz $NewestScript is available. Get it with:" -ForegroundColor Yellow
        Write-Host "  powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Update" -ForegroundColor Yellow
        Write-Host ''
    }
    Write-Host 'Want to change an answer later? Run this script again like this:'
    Write-Host "  powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Reconfigure"
    Write-Host ''
    Write-Host 'If this saved you some time, please give it a star on GitHub. Stars are' -ForegroundColor Cyan
    Write-Host 'how other n8n users find it. The Star button is at the top right of:' -ForegroundColor Cyan
    Write-Host 'https://github.com/dtsoden/n8n-wiz' -ForegroundColor Cyan
}
