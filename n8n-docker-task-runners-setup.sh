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
#   1. Works out your settings (see "Two ways to set it up" below).
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

# ask NAME "Question": offers the current value as the default (Enter keeps
# it), turns "none" into an empty value, and asks again until the answer works.
ask() {
  local name="$1" answer shown="${!1}"
  [ -z "$shown" ] && shown="none"
  while true; do
    read -r -p "$2 [$shown]: " answer
    [ -z "$answer" ] && answer="${!name}"
    [ "$answer" = "none" ] && answer=""
    case "$answer" in "~"*) answer="$HOME${answer#\~}" ;; esac
    if valid "$name" "$answer"; then
      printf -v "$name" '%s' "$answer"
      return
    fi
    echo "  That doesn't look right. Please try again."
  done
}

# ask_yes_no "Question" y|n : returns success for yes.
ask_yes_no() {
  local answer
  while true; do
    read -r -p "$1 [$2]: " answer
    answer="${answer:-$2}"
    case "$answer" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
    esac
  done
}

run_questions() {
  echo
  echo "Press Enter to accept the value in brackets."
  echo
  ask N8N_DATA_DIR "Folder for n8n's data"
  echo "  \"latest\" upgrades n8n every time this script runs. A number such as"
  echo "  2.45.4 stays on that release."
  ask N8N_VERSION "n8n version"
  ask N8N_HOST_PORT "Port to open n8n on in your browser"

  local has_url=n
  [ -n "$N8N_WEBHOOK_URL" ] && has_url=y
  if ask_yes_no "Will other people or services reach this n8n at a public address?" "$has_url"; then
    while true; do
      ask N8N_WEBHOOK_URL "Public address, such as https://n8n.example.com/"
      [ -n "$N8N_WEBHOOK_URL" ] && break
      echo "  Enter the full address, starting with https://"
    done
  else
    N8N_WEBHOOK_URL=""
  fi

  ask TASK_TIMEOUT "Seconds a Code node may run before it is stopped"

  echo
  echo "What the Code node may import. Use commas between names, * for"
  echo "everything in the runners image, or none. Whether * suits you is your"
  echo "call. The risks are covered at"
  echo "https://docs.n8n.io/deploy/host-n8n/configure-n8n/security/harden-task-runners"
  ask JS_BUILTIN_ALLOW "JavaScript, Node.js built-in modules"
  ask JS_EXTERNAL_ALLOW "JavaScript, npm packages"
  ask PY_STDLIB_ALLOW "Python, standard library modules"
  ask PY_EXTERNAL_ALLOW "Python, third-party packages"

  echo
  echo "n8n 2.0 and later turn off the Execute Command and Local File Trigger nodes."
  local exec_default=n
  [ "$ENABLE_EXEC_NODES" = yes ] && exec_default=y
  if ask_yes_no "Turn them back on?" "$exec_default"; then
    ENABLE_EXEC_NODES=yes
  else
    ENABLE_EXEC_NODES=no
  fi

  echo
  echo "Your settings:"
  local key
  for key in $SETTING_NAMES; do
    echo "  $key=${!key}"
  done
  if ! ask_yes_no "Save these and start n8n?" y; then
    echo "Nothing changed. Run the script again when you're ready."
    exit 0
  fi
  save_settings
}

# ---- Work out the settings --------------------------------------------------
# [ -t 0 ] is true when someone is at the keyboard. Under cron it is false, so
# a scheduled run never stops to wait for an answer.

if [ "$RECONFIGURE" = yes ]; then
  if [ ! -t 0 ]; then
    echo "--reconfigure needs someone at the keyboard to answer the questions."
    exit 1
  fi
  # Load the current answers first so they show up as the defaults.
  if [ -f "$SETTINGS_FILE" ]; then load_settings; fi
  run_questions
elif [ -f "$SETTINGS_FILE" ]; then
  echo "Using settings from $SETTINGS_FILE"
  load_settings
elif [ "$NO_QUESTIONS" = yes ] || [ ! -t 0 ]; then
  echo "No settings file next to the script; using the values written in it."
else
  echo "No settings file found next to this script."
  if ask_yes_no "Answer a few setup questions now? (n uses the values written in the script)" y; then
    run_questions
  fi
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
