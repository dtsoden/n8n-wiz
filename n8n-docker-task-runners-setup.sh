#!/bin/bash
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
# n8n with external task runners on Docker (macOS and Linux)
# https://github.com/dtsoden/n8n-docker-task-runners
# =============================================================================
#
# What this script does
#   1. Makes sure Docker is running, then works out your settings.
#   2. Pulls the n8n and n8n runners images (same version for both).
#   3. Stops and removes any old "n8n" and "n8n-runners" containers.
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
# Two ways to set it up
#   Answer questions: just run the script. The first time, it asks a few
#   questions and saves your answers in n8n-docker-task-runners-settings.env,
#   in the same folder as this script. Every later run reads that file and asks
#   nothing, so a scheduled nightly run works unattended. Keep the two files
#   in the same folder: the script only looks for the settings file next to
#   itself. To change your answers later, run it with --reconfigure, or open
#   the settings file in a text editor.
#
#   Edit this file: change the values under "Settings" below (line numbers are
#   listed further down), then run the script with --no-questions. If a
#   settings file exists next to the script, its values win over the ones
#   written here, so delete it if you go this way.
#
# Options
#   --reconfigure    ask the questions again and save new answers
#   --no-questions   never ask; use the settings file if there is one,
#                    otherwise the values written in this script
#   --help           show these options
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
#   macOS: Docker Desktop. Linux: Docker Engine (or Docker Desktop).
#   Podman is not covered here. Docker Desktop needs a paid subscription for
#   larger businesses, so check Docker's licence terms before using it at work.
#   openssl is used for the token. It ships with macOS and most Linux distros,
#   and the script falls back to /dev/urandom if it is missing.
#
# Settings you can edit directly (line numbers refer to this file as published)
#   Line 113  N8N_DATA_DIR        folder on your machine for n8n data
#   Line 117  N8N_VERSION         n8n version; the runners image uses the same one
#   Line 120  N8N_HOST_PORT       port you open in the browser
#   Line 125  N8N_WEBHOOK_URL     the public address of your n8n, if it has one
#   Line 128  DOCKER_NETWORK      only if you already use a different network name
#   Line 133  TASK_TIMEOUT        seconds a Code node may run before it is stopped
#   Lines 146 to 149  JS_* and PY_*  modules the Code node may import
#   Line 154  ENABLE_EXEC_NODES   Execute Command and Local File Trigger on or off
#
# How to run
#   chmod +x n8n-docker-task-runners-setup.sh
#   ./n8n-docker-task-runners-setup.sh
#
# Linux only: n8n runs as user ID 1000 inside the container. If n8n logs show
# "permission denied" on /home/node/.n8n, run this once and start again:
#   sudo chown -R 1000:1000 "$HOME/n8n"
# =============================================================================

# ---- Settings ---------------------------------------------------------------
# Used when there is no settings file. The questions also offer these values
# as the answer you get by pressing Enter.

# Folder on your machine for n8n's data (database, encryption key, binary
# files) and task-runners.json. $HOME works on both macOS and Linux.
N8N_DATA_DIR="$HOME/n8n"

# n8n and n8nio/runners always run the same version. "latest" upgrades on every
# run; a number such as "2.45.4" holds you on that release.
N8N_VERSION="latest"

# Port on your machine. With 5678 you open http://localhost:5678
N8N_HOST_PORT="5678"

# The address people and services use to reach n8n, which n8n uses to build
# webhook URLs, for example "https://n8n.example.com/". Leave it empty on a
# machine that is only used locally; the script then uses http://localhost:<port>/
N8N_WEBHOOK_URL=""

# Docker network both containers join so they can find each other by name.
DOCKER_NETWORK="n8n-network"

# Seconds a single Code node execution may run before it is stopped. Both
# containers get this value. n8n says its default will drop from 300 to 60 in
# a later release, so set it here rather than relying on the default.
TASK_TIMEOUT="300"

# What the Code node may import: names separated by commas, * for everything
# available in the runners image, or empty for nothing. Only packages that are
# in the image can load; adding others means building a custom runners image
# (see the "Set up task runners" page above).
#   JS_BUILTIN_ALLOW    Node.js built-in modules, such as crypto,fs,path
#   JS_EXTERNAL_ALLOW   npm packages, such as moment,uuid
#   PY_STDLIB_ALLOW     Python standard library modules, such as json,datetime
#   PY_EXTERNAL_ALLOW   third-party Python packages, such as numpy,pandas
# The Python values here are *, which allows every module in the image. Some
# see that as a security hole, others as the right setting. Decide for your own
# instance; the "Harden task runners" page above covers the risks.
JS_BUILTIN_ALLOW="crypto"
JS_EXTERNAL_ALLOW="moment"
PY_STDLIB_ALLOW="*"
PY_EXTERNAL_ALLOW="*"

# n8n 2.0 and later refuse to load Execute Command and Local File Trigger.
# "yes" turns them back on (it sets NODES_EXCLUDE="[]", which loads every
# node). "no" leaves n8n's default in place.
ENABLE_EXEC_NODES="yes"

# ---- Nothing below this line needs editing ----------------------------------

# Stop at the first command that fails.
set -e

# The settings file lives next to this script, wherever the script is run from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_FILE="$SCRIPT_DIR/n8n-docker-task-runners-settings.env"
SETTING_NAMES="N8N_DATA_DIR N8N_VERSION N8N_HOST_PORT N8N_WEBHOOK_URL DOCKER_NETWORK TASK_TIMEOUT JS_BUILTIN_ALLOW JS_EXTERNAL_ALLOW PY_STDLIB_ALLOW PY_EXTERNAL_ALLOW ENABLE_EXEC_NODES"

RECONFIGURE=no
NO_QUESTIONS=no
for arg in "$@"; do
  case "$arg" in
    --reconfigure)  RECONFIGURE=yes ;;
    --no-questions) NO_QUESTIONS=yes ;;
    -h|--help)
      echo "Usage: $0 [--reconfigure | --no-questions]"
      echo "  --reconfigure   ask the setup questions again and save new answers"
      echo "  --no-questions  never ask; use the settings file if there is one,"
      echo "                  otherwise the values written in this script"
      echo "Settings file: $SETTINGS_FILE"
      exit 0 ;;
    *) echo "Unknown option: $arg (try --help)"; exit 1 ;;
  esac
done

# ---- Checking values --------------------------------------------------------
# Every value is checked before use, whether it came from an answer, the
# settings file or this script. That also keeps quotes and other characters
# that would break task-runners.json out of it.

RE_NAME='^[A-Za-z0-9._-]+$'
RE_NUMBER='^[0-9]+$'
RE_URL='^https?://[^[:space:]]+$'
RE_ALLOW='^[A-Za-z0-9_.,*@/-]*$'

valid() {
  case "$1" in
    N8N_DATA_DIR)               [ -n "$2" ] ;;
    N8N_VERSION|DOCKER_NETWORK) [[ "$2" =~ $RE_NAME ]] ;;
    N8N_HOST_PORT)              [[ "$2" =~ $RE_NUMBER ]] && [ "$2" -ge 1 ] && [ "$2" -le 65535 ] ;;
    N8N_WEBHOOK_URL)            [ -z "$2" ] || [[ "$2" =~ $RE_URL ]] ;;
    TASK_TIMEOUT)               [[ "$2" =~ $RE_NUMBER ]] && [ "$2" -ge 1 ] ;;
    JS_*|PY_*)                  [[ "$2" =~ $RE_ALLOW ]] ;;
    ENABLE_EXEC_NODES)          [ "$2" = yes ] || [ "$2" = no ] ;;
    *)                          false ;;
  esac
}

# ---- Settings file ----------------------------------------------------------
# Plain NAME=value lines. Lines starting with # are ignored.

load_settings() {
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#$'\xef\xbb\xbf'}"
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"
    value="${line#*=}"
    case " $SETTING_NAMES " in
      *" $key "*) ;;
      *) echo "Ignoring unknown line in the settings file: $key"; continue ;;
    esac
    if ! valid "$key" "$value"; then
      echo "The settings file has a value that doesn't work for $key: $value"
      echo "Fix it in $SETTINGS_FILE, or run with --reconfigure."
      exit 1
    fi
    printf -v "$key" '%s' "$value"
  done < "$SETTINGS_FILE"
}

save_settings() {
  local key
  {
    echo "# Settings for n8n-docker-task-runners-setup.sh, saved $(date '+%Y-%m-%d %H:%M')."
    echo "# Keep this file in the same folder as the script. Edit the values here,"
    echo "# or run the script with --reconfigure to answer the questions again."
    for key in $SETTING_NAMES; do
      echo "$key=${!key}"
    done
  } > "$SETTINGS_FILE"
  echo "Saved your answers to $SETTINGS_FILE"
}

# ---- Questions --------------------------------------------------------------

# ask NAME "Question": prints the question, offers the current value as the
# answer you get by pressing Enter, turns "none" into an empty value, and asks
# again until the answer works.
ask() {
  local name="$1" answer hint
  if [ -n "${!name}" ]; then
    hint="Press Enter for ${!name}, or type something else: "
  else
    hint="Press Enter to leave this empty, or type something: "
  fi
  echo
  echo "$2"
  while true; do
    read -r -p "  $hint" answer
    [ -z "$answer" ] && answer="${!name}"
    case "$name" in JS_*|PY_*) answer="${answer// /}" ;; esac
    [ "$answer" = "none" ] && answer=""
    case "$answer" in "~"*) answer="$HOME${answer#\~}" ;; esac
    if valid "$name" "$answer"; then
      printf -v "$name" '%s' "$answer"
      return
    fi
    echo "  Sorry, that won't work here. Have another go."
  done
}

# ask_yes_no "Question" y|n : prints the question and returns success for yes.
# The second argument is what pressing Enter means.
ask_yes_no() {
  local answer hint
  if [ "$2" = y ]; then
    hint="Press Enter for yes, or type no: "
  else
    hint="Press Enter for no, or type yes: "
  fi
  echo
  echo "$1"
  while true; do
    read -r -p "  $hint" answer
    answer="${answer:-$2}"
    case "$answer" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
    esac
    echo "  Please type yes or no."
  done
}

# Empty values and * read better in the summary than the stored form.
show_value() {
  case "$1" in
    "") echo "nothing" ;;
    "*") echo "everything" ;;
    *) echo "$1" ;;
  esac
}

# show_seconds 300 prints "300 seconds (5 minutes)" so nobody has to do the math.
show_seconds() {
  local s="$1" m=$(( $1 / 60 )) r=$(( $1 % 60 )) out=""
  if [ "$s" -lt 60 ]; then
    echo "$s seconds"
    return
  fi
  if [ "$m" -eq 1 ]; then out="1 minute"; else out="$m minutes"; fi
  if [ "$r" -eq 1 ]; then out="$out 1 second"; elif [ "$r" -gt 1 ]; then out="$out $r seconds"; fi
  echo "$s seconds ($out)"
}

# menu "Question" DEFAULT "option" "option" ...: prints numbered options and
# sets MENU_CHOICE to the number picked. Enter picks DEFAULT.
menu() {
  local question="$1" default="$2" answer i=1 opt
  shift 2
  echo
  echo "$question"
  for opt in "$@"; do
    echo "  $i  $opt"
    i=$((i + 1))
  done
  while true; do
    read -r -p "  Press Enter for $default, or type a number: " answer
    answer="${answer:-$default}"
    if [[ "$answer" =~ $RE_NUMBER ]] && [ "$answer" -ge 1 ] && [ "$answer" -le $# ]; then
      MENU_CHOICE="$answer"
      return
    fi
    echo "  Please type a number from 1 to $#."
  done
}

# image_list js-builtin|js-npm|py-stdlib prints, comma separated, what the
# runners image offers. It asks the image itself, so the list always matches
# the version that will run, and prints nothing if Docker can't answer.
image_list() {
  local image="n8nio/runners:$N8N_VERSION"
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "  Downloading the n8n runners image to read the list. This can take a minute..." >&2
    docker pull -q "$image" >/dev/null 2>&1 || return 0
  fi
  case "$1" in
    js-builtin)
      docker run --rm --entrypoint node "$image" \
        -e "console.log(require('module').builtinModules.filter(m=>!m.startsWith('_')&&!m.includes('/')).join(','))" ;;
    js-npm)
      # Scoped (@...) and n8n-* folders are the runner's own code.
      docker run --rm --entrypoint ls "$image" /opt/runners/task-runner-javascript/node_modules \
        | grep -v -e '^@' -e '^n8n-' | paste -sd, - ;;
    py-stdlib)
      docker run --rm --entrypoint /opt/runners/task-runner-python/.venv/bin/python "$image" \
        -c "import sys; print(','.join(sorted(m for m in sys.stdlib_module_names if not m.startswith('_'))))" ;;
  esac 2>/dev/null
}

# show_list LIST WHERE: prints the names to copy from, or where to find them
# when Docker couldn't supply the list.
show_list() {
  if [ -n "$1" ]; then
    echo "  These come installed:"
    echo "$1" | sed 's/,/, /g' | fold -s -w 72 | sed 's/^/    /' | sed "s/ *$//"
  else
    echo "  I couldn't read the list from Docker. The names are at $2"
  fi
}

# pick_names NAME "Question" LIST: like ask, but turns down names that aren't
# in LIST so a typo doesn't slip through. An empty LIST skips that check.
pick_names() {
  local name="$1" question="$2" list="$3" n bad
  while true; do
    ask "$name" "$question"
    bad=""
    if [ -n "$list" ]; then
      for n in $(echo "${!name}" | tr ',' ' '); do
        [ "$n" = "*" ] && continue
        case ",$list," in *",$n,"*) ;; *) bad="$bad $n" ;; esac
      done
    fi
    [ -z "$bad" ] && return
    echo "  Not in the list:$bad. Check the spelling against the list above."
  done
}

run_questions() {
  echo
  echo "Each question comes with a suggested answer. If you're not sure, just"
  echo "press Enter to take it. You can change any of this later by running the"
  echo "script with --reconfigure."

  ask N8N_DATA_DIR "Where should n8n keep its workflows, credentials and other data?"

  ask N8N_HOST_PORT "Which port number should n8n use? If you don't know what that means, just press Enter."

  local has_url=n
  [ -n "$N8N_WEBHOOK_URL" ] && has_url=y
  if ask_yes_no "Will anyone reach this n8n from the internet, at an address like https://n8n.example.com? Say no if you'll only use it on this computer." "$has_url"; then
    while true; do
      ask N8N_WEBHOOK_URL "What's that address? Include the https:// at the start."
      [ -n "$N8N_WEBHOOK_URL" ] && break
      echo "  You said people will reach it from the internet, so I need the address."
    done
  else
    N8N_WEBHOOK_URL=""
  fi

  ask TASK_TIMEOUT "How many seconds should a Code node get to finish before n8n stops it? The suggestion is $(show_seconds "$TASK_TIMEOUT"). For 10 minutes, type 600."

  echo
  echo "Next, which code libraries your Code nodes may load. Allowing everything"
  echo "is easiest, but it also lets a Code node do more on the machine it runs"
  echo "on. If you want to read up before deciding, see"
  echo "https://docs.n8n.io/deploy/host-n8n/configure-n8n/security/harden-task-runners"

  local js_default=4 js_now=""
  if [ "$JS_BUILTIN_ALLOW" = "*" ] && [ "$JS_EXTERNAL_ALLOW" = "*" ]; then js_default=1
  elif [ "$JS_BUILTIN_ALLOW" = crypto ] && [ "$JS_EXTERNAL_ALLOW" = moment ]; then js_default=2
  elif [ -z "$JS_BUILTIN_ALLOW" ] && [ -z "$JS_EXTERNAL_ALLOW" ]; then js_default=3
  else js_now=" (you have $(show_value "$JS_BUILTIN_ALLOW") and $(show_value "$JS_EXTERNAL_ALLOW") now)"
  fi
  menu "Which libraries can JavaScript Code nodes use?" "$js_default" \
    "Everything that comes installed" \
    "Just crypto and moment" \
    "None" \
    "Let me pick from the full list$js_now"
  case "$MENU_CHOICE" in
    1) JS_BUILTIN_ALLOW="*"; JS_EXTERNAL_ALLOW="*" ;;
    2) JS_BUILTIN_ALLOW="crypto"; JS_EXTERNAL_ALLOW="moment" ;;
    3) JS_BUILTIN_ALLOW=""; JS_EXTERNAL_ALLOW="" ;;
    4)
      local list
      echo
      echo "First, Node.js built-in libraries."
      wait_for_runners_image
      list="$(image_list js-builtin)"
      show_list "$list" "https://nodejs.org/api/"
      pick_names JS_BUILTIN_ALLOW "Type the ones to allow, separated by commas:" "$list"
      echo
      echo "Now npm packages."
      list="$(image_list js-npm)"
      show_list "$list" "https://github.com/n8n-io/n8n/tree/master/docker/images/runners"
      pick_names JS_EXTERNAL_ALLOW "Type the ones to allow, separated by commas:" "$list"
      ;;
  esac

  # Python's extra packages in the image are only the runner's own plumbing,
  # so they follow the standard library answer instead of getting a question.
  local py_common="json,datetime,math,re,random,statistics" py_default=4 py_now=""
  if [ "$PY_STDLIB_ALLOW" = "*" ]; then py_default=1
  elif [ "$PY_STDLIB_ALLOW" = "$py_common" ]; then py_default=2
  elif [ -z "$PY_STDLIB_ALLOW" ]; then py_default=3
  else py_now=" (you have $PY_STDLIB_ALLOW now)"
  fi
  menu "Which libraries can Python Code nodes use?" "$py_default" \
    "Everything in Python's standard library" \
    "Just json, datetime, math, re, random and statistics" \
    "None" \
    "Let me pick from the full list$py_now"
  case "$MENU_CHOICE" in
    1) PY_STDLIB_ALLOW="*"; PY_EXTERNAL_ALLOW="*" ;;
    2) PY_STDLIB_ALLOW="$py_common"; PY_EXTERNAL_ALLOW="" ;;
    3) PY_STDLIB_ALLOW=""; PY_EXTERNAL_ALLOW="" ;;
    4)
      local list
      echo
      wait_for_runners_image
      list="$(image_list py-stdlib)"
      show_list "$list" "https://docs.python.org/3/py-modindex.html"
      pick_names PY_STDLIB_ALLOW "Type the ones to allow, separated by commas:" "$list"
      PY_EXTERNAL_ALLOW=""
      ;;
  esac

  echo
  echo "n8n 2.0 and later switch off two nodes that can run commands and read"
  echo "files on this computer: Execute Command and Local File Trigger."
  local exec_default=n
  [ "$ENABLE_EXEC_NODES" = yes ] && exec_default=y
  if ask_yes_no "Do you want them switched back on?" "$exec_default"; then
    ENABLE_EXEC_NODES=yes
  else
    ENABLE_EXEC_NODES=no
  fi

  echo
  echo "Here's what you chose:"
  echo "  Data folder:                    $N8N_DATA_DIR"
  echo "  Port:                           $N8N_HOST_PORT"
  echo "  Internet address:               ${N8N_WEBHOOK_URL:-none, this computer only}"
  echo "  Code node time limit:           $(show_seconds "$TASK_TIMEOUT")"
  echo "  JavaScript built-in libraries:  $(show_value "$JS_BUILTIN_ALLOW")"
  echo "  JavaScript npm packages:        $(show_value "$JS_EXTERNAL_ALLOW")"
  echo "  Python libraries:               $(show_value "$PY_STDLIB_ALLOW")"
  echo "  Execute Command and Local File: $ENABLE_EXEC_NODES"
  if ! ask_yes_no "Does that look right? I'll save it and start n8n." y; then
    echo "OK, nothing was changed. Run the script again when you're ready."
    exit 0
  fi
  save_settings
}

# ---- Docker -----------------------------------------------------------------
# Everything after the questions needs Docker, so make sure it is installed and
# running before asking anything. [ -t 0 ] is true when someone is at the
# keyboard. Under cron it is false, so a scheduled run never stops to wait for
# an answer.

if [ "$RECONFIGURE" = yes ] && [ ! -t 0 ]; then
  echo "--reconfigure needs someone at the keyboard to answer the questions."
  exit 1
fi

# Saved answers are loaded now so the downloads below fetch the right version.
# On --reconfigure they also show up as the answers you get by pressing Enter.
if [ -f "$SETTINGS_FILE" ]; then load_settings; fi

start_docker() {
  case "$(uname -s)" in
    Darwin) open -a Docker ;;
    Linux)
      # Docker Desktop for Linux runs as a user service; plain Docker Engine
      # runs as a system service.
      if systemctl --user cat docker-desktop >/dev/null 2>&1; then
        systemctl --user start docker-desktop
      else
        sudo systemctl start docker
      fi ;;
  esac
}

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker isn't installed on this computer, and n8n runs inside it."
  echo "Install Docker Desktop from https://www.docker.com/products/docker-desktop/"
  echo "(on Linux, Docker Engine works too), start it, then run this script again."
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  if [ -t 0 ]; then
    if ! ask_yes_no "Docker is installed but isn't running. Do you want me to start it?" y; then
      echo "OK. Start Docker yourself, then run this script again."
      exit 1
    fi
  else
    echo "Docker isn't running. Trying to start it..."
  fi
  start_docker || true
  printf "Waiting for Docker to start"
  tries=0
  until docker info >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -gt 60 ]; then
      echo
      echo "Docker still isn't running after 3 minutes. Open Docker yourself, wait"
      echo "until it says it's running, then run this script again."
      exit 1
    fi
    printf "."
    sleep 3
  done
  echo " Docker is running."
fi

# Start downloading both images now, so they're ready or nearly ready by the
# time the questions are done. The pull step further down waits for them.
docker pull -q "n8nio/runners:$N8N_VERSION" >/dev/null 2>&1 &
RUNNERS_PULL_PID=$!
docker pull -q "n8nio/n8n:$N8N_VERSION" >/dev/null 2>&1 &
N8N_PULL_PID=$!

# The list questions read from the runners image, so they wait for it first.
wait_for_runners_image() {
  if [ -n "$RUNNERS_PULL_PID" ]; then
    echo "  Waiting for the n8n download to finish so I can read the list..."
    wait "$RUNNERS_PULL_PID" || true
    RUNNERS_PULL_PID=""
  fi
}

# ---- Work out the settings --------------------------------------------------

if [ "$RECONFIGURE" = yes ]; then
  run_questions
elif [ -f "$SETTINGS_FILE" ]; then
  echo "Using settings from $SETTINGS_FILE"
elif [ "$NO_QUESTIONS" = yes ] || [ ! -t 0 ]; then
  echo "No settings file next to the script; using the values written in it."
else
  echo "Looks like this is your first time running this, so I have a few"
  echo "questions to get n8n set up the way you want."
  run_questions
fi

# Values typed straight into this script are checked here too.
for key in $SETTING_NAMES; do
  if ! valid "$key" "${!key}"; then
    echo "The value for $key doesn't work: ${!key}"
    exit 1
  fi
done

# No public address means a machine used only locally.
WEBHOOK_URL_TO_USE="${N8N_WEBHOOK_URL:-http://localhost:$N8N_HOST_PORT/}"

# ---- Pull images first ------------------------------------------------------
# Pulling before removing anything means a typo in the version or a network
# problem stops the script while your current n8n is still running.

echo "Pulling n8nio/n8n:$N8N_VERSION and n8nio/runners:$N8N_VERSION..."
# Let the background downloads finish. Pulling again afterwards takes a moment
# and shows a real error if one of them failed.
if [ -n "$RUNNERS_PULL_PID" ]; then wait "$RUNNERS_PULL_PID" || true; fi
wait "$N8N_PULL_PID" || true
docker pull "n8nio/n8n:$N8N_VERSION"
docker pull "n8nio/runners:$N8N_VERSION"

# ---- Remove old containers --------------------------------------------------
# "|| true" keeps going when the containers don't exist yet (first run).

echo "Stopping and removing old containers..."
docker stop n8n n8n-runners 2>/dev/null || true
docker rm -f n8n n8n-runners 2>/dev/null || true

# ---- Network and data folder ------------------------------------------------

echo "Creating network $DOCKER_NETWORK if needed..."
docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1 || docker network create "$DOCKER_NETWORK"

mkdir -p "$N8N_DATA_DIR"

# ---- Launcher config: task-runners.json -------------------------------------
# The runners container starts a small program called the launcher. It reads
# /etc/n8n-task-runners.json to learn how to start each runner. The image
# ships a locked-down default; we mount our own copy over it (see the
# "docker run" for n8n-runners below) to change what the Code node may import.
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
# The heredoc below fills in the $JS_... and $PY_... values and nothing else.
cat > "$N8N_DATA_DIR/task-runners.json" << EOF
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
        "NODE_FUNCTION_ALLOW_BUILTIN": "$JS_BUILTIN_ALLOW",
        "NODE_FUNCTION_ALLOW_EXTERNAL": "$JS_EXTERNAL_ALLOW",
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
        "N8N_RUNNERS_STDLIB_ALLOW": "$PY_STDLIB_ALLOW",
        "N8N_RUNNERS_EXTERNAL_ALLOW": "$PY_EXTERNAL_ALLOW"
      }
    }
  ]
}
EOF

# ---- Shared token -----------------------------------------------------------
# n8n and the runners container prove who they are to each other with the same
# secret. 32 random bytes as 64 hex characters. A new token on every run is
# fine because both containers are recreated together below.

if command -v openssl >/dev/null 2>&1; then
  N8N_RUNNERS_AUTH_TOKEN=$(openssl rand -hex 32)
else
  N8N_RUNNERS_AUTH_TOKEN=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
fi

# ---- Start n8n --------------------------------------------------------------
#   -p HOST:5678                 n8n listens on 5678 inside the container
#   -v DATA:/home/node/.n8n      keeps your data on your machine
#   N8N_WEBHOOK_URL              replaces the older WEBHOOK_URL, which n8n 2.x
#                                flags as deprecated at startup
#   N8N_RUNNERS_MODE=external    run Code nodes in the sidecar, not inside n8n
#   N8N_RUNNERS_AUTH_TOKEN       must match the runners container
#   N8N_RUNNERS_TASK_TIMEOUT     from TASK_TIMEOUT
#   N8N_RUNNERS_BROKER_LISTEN_ADDRESS=0.0.0.0
#                                the broker (port 5679) only listens on
#                                localhost by default, which another container
#                                can't reach
#   N8N_NATIVE_PYTHON_RUNNER     in n8n's reference compose file for the
#                                Python runner
#   NODES_EXCLUDE="[]"           added only when ENABLE_EXEC_NODES is yes
#   (n8n 1.x also needed N8N_RUNNERS_ENABLED=true. n8n 2.x says it is no
#   longer needed, so it is left out. Add it back only if you pin a 1.x version.)

EXEC_NODES_ENV=()
if [ "$ENABLE_EXEC_NODES" = yes ]; then
  EXEC_NODES_ENV=(-e "NODES_EXCLUDE=[]")
fi

echo "Starting n8n..."
docker run -d \
  --name n8n \
  --restart always \
  --network "$DOCKER_NETWORK" \
  -p "$N8N_HOST_PORT:5678" \
  -v "$N8N_DATA_DIR:/home/node/.n8n" \
  -e N8N_WEBHOOK_URL="$WEBHOOK_URL_TO_USE" \
  -e N8N_RUNNERS_MODE=external \
  -e N8N_RUNNERS_AUTH_TOKEN="$N8N_RUNNERS_AUTH_TOKEN" \
  -e N8N_RUNNERS_TASK_TIMEOUT="$TASK_TIMEOUT" \
  -e N8N_RUNNERS_BROKER_LISTEN_ADDRESS=0.0.0.0 \
  -e N8N_NATIVE_PYTHON_RUNNER=true \
  "${EXEC_NODES_ENV[@]}" \
  "n8nio/n8n:$N8N_VERSION"

# ---- Start the runners sidecar ----------------------------------------------
#   N8N_RUNNERS_TASK_BROKER_URI  "n8n" is the container name above; Docker
#                                resolves it on the shared network. 5679 is
#                                the broker port.
#   N8N_RUNNERS_TASK_TIMEOUT     from TASK_TIMEOUT
#   -v .../task-runners.json:/etc/n8n-task-runners.json
#                                replaces the image's default launcher config
#                                with the file written above

echo "Starting n8n-runners..."
docker run -d \
  --name n8n-runners \
  --restart always \
  --network "$DOCKER_NETWORK" \
  -e N8N_RUNNERS_AUTH_TOKEN="$N8N_RUNNERS_AUTH_TOKEN" \
  -e N8N_RUNNERS_TASK_BROKER_URI=http://n8n:5679 \
  -e N8N_RUNNERS_TASK_TIMEOUT="$TASK_TIMEOUT" \
  -v "$N8N_DATA_DIR/task-runners.json:/etc/n8n-task-runners.json" \
  "n8nio/runners:$N8N_VERSION"

echo
echo "Done. Open http://localhost:$N8N_HOST_PORT"
echo "Check the runners connected with: docker logs n8n"
echo "(look for two lines starting with: Registered runner)"

# Only when someone is watching, so the nightly log stays quiet.
if [ -t 0 ]; then
  echo
  echo "If this saved you some time, please give it a star on GitHub. Stars are"
  echo "how other n8n users find it. The Star button is at the top right of:"
  echo "https://github.com/dtsoden/n8n-docker-task-runners"
fi
