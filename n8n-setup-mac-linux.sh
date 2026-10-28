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
# n8n wiz: install n8n and keep it up to date (macOS and Linux)
# https://github.com/dtsoden/n8n-wiz
# =============================================================================
#
# What this script does
#   1. Makes sure Docker is installed and running, offering to start it.
#   2. Starts downloading the n8n and n8n runners images in the background
#      (same version for both).
#   3. Works out your settings, asking the setup questions the first time.
#   4. Finishes the downloads, then stops and removes any old "n8n" and
#      "n8n-runners" containers.
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
#   --remove         uninstall: remove n8n, its images, the nightly update and
#                    the saved answers. Asks before deleting your workflows.
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
#   Line 123  N8N_DATA_DIR        folder on your machine for n8n data
#   Line 129  N8N_VERSION         n8n version; the runners image uses the same one
#   Line 132  N8N_HOST_PORT       port you open in the browser
#   Line 137  N8N_WEBHOOK_URL     the public address of your n8n, if it has one
#   Line 140  DOCKER_NETWORK      only if you already use a different network name
#   Line 145  TASK_TIMEOUT        seconds a Code node may run before it is stopped
#   Lines 158 to 161  JS_* and PY_*  modules the Code node may import
#   Line 166  ENABLE_EXEC_NODES   Execute Command and Local File Trigger on or off
#   Line 171  NIGHTLY_TIME        time of the nightly update, or off
#
# How to run
#   bash n8n-setup-mac-linux.sh
#   (or make it executable once with chmod +x and run ./n8n-setup-mac-linux.sh)
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

# n8n and n8nio/runners always run the same version. "latest" means the newest
# release in the major version you're on (2.x stays 2.x). A run at the keyboard
# asks before moving to a new major version. A number such as "2.45.4" holds
# you on that release.
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

# When the script runs by itself every night, as 24-hour HH:MM, or "off". The
# setup questions add or remove the cron entry for you. If you edit this file
# instead, add the cron line yourself (the README shows it).
NIGHTLY_TIME="02:00"

# ---- Nothing below this line needs editing ----------------------------------

# Both scripts share one version number. Each release is tagged vX.Y.Z on GitHub.
SCRIPT_VERSION="1.2.1"

# Stop at the first command that fails.
set -e

# Colors make each kind of line easy to spot: cyan headers, bold questions,
# gray hints, yellow "try again" notes, red errors, green good news. They only
# appear in a real terminal, and never when NO_COLOR is set (no-color.org), so
# the nightly log stays plain text.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_HEAD=$'\033[1;36m' C_ASK=$'\033[1m' C_DIM=$'\033[2m' C_WARN=$'\033[33m'
  C_ERR=$'\033[1;31m' C_OK=$'\033[32m' C_STAR=$'\033[36m' C_OFF=$'\033[0m'
  # The two library questions look alike, so each language gets its own color.
  C_JS=$'\033[1;33m' C_PY=$'\033[1;35m'
else
  C_HEAD="" C_ASK="" C_DIM="" C_WARN="" C_ERR="" C_OK="" C_STAR="" C_OFF=""
  C_JS="" C_PY=""
fi

# Whenever the script stops early, point to the place to report a bug.
# Ctrl+C (status 130) is a choice to quit, not a bug, so it gets no link.
# Neither does a stop the script makes on purpose (NOT_A_BUG=yes).
trap 'status=$?
if [ "$status" -ne 0 ] && [ "$status" -ne 130 ] && [ "${NOT_A_BUG:-}" != yes ]; then
  echo
  echo "${C_WARN}If this looks like a bug, please report it at${C_OFF}"
  echo "${C_WARN}https://github.com/dtsoden/n8n-wiz/issues/new${C_OFF}"
fi' EXIT

# The cron entry for the nightly update is found again by this tag at the end
# of its line.
CRON_TAG="# n8n-docker-task-runners nightly update"

# The settings file lives next to this script, wherever the script is run from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_FILE="$SCRIPT_DIR/n8n-docker-task-runners-settings.env"
SETTING_NAMES="N8N_DATA_DIR N8N_VERSION N8N_HOST_PORT N8N_WEBHOOK_URL DOCKER_NETWORK TASK_TIMEOUT JS_BUILTIN_ALLOW JS_EXTERNAL_ALLOW PY_STDLIB_ALLOW PY_EXTERNAL_ALLOW ENABLE_EXEC_NODES NIGHTLY_TIME"

RECONFIGURE=no
NO_QUESTIONS=no
REMOVE=no
UPDATE=no
for arg in "$@"; do
  case "$arg" in
    # The usual spellings all work, so -remove or plain "remove" don't fail.
    --reconfigure|-reconfigure|reconfigure)  RECONFIGURE=yes ;;
    --no-questions|-no-questions|no-questions|--noquestions|-noquestions) NO_QUESTIONS=yes ;;
    --remove|-remove|remove)  REMOVE=yes ;;
    --update|-update|update)  UPDATE=yes ;;
    -h|--help|help)
      echo "n8n-setup-mac-linux.sh version $SCRIPT_VERSION"
      echo "Usage: $0 [--reconfigure | --no-questions | --remove | --update]"
      echo "  --reconfigure   ask the setup questions again and save new answers"
      echo "  --no-questions  never ask; use the settings file if there is one,"
      echo "                  otherwise the values written in this script"
      echo "  --remove        uninstall n8n, its images, the nightly update and the"
      echo "                  saved answers; asks before deleting your workflows"
      echo "  --update        replace this script with the newest n8n wiz release"
      echo "Settings file: $SETTINGS_FILE"
      exit 0 ;;
    *) echo "${C_ERR}Unknown option: $arg (try --help)${C_OFF}"; exit 1 ;;
  esac
done

# ---- Checking values --------------------------------------------------------
# Every value is checked before use, whether it came from an answer, the
# settings file or this script. That also keeps quotes and other characters
# that would break task-runners.json out of it.

RE_NAME='^[A-Za-z0-9._-]+$'
RE_NUMBER='^[0-9]+$'
RE_URL='^https?://[^[:space:]]+$'
RE_VERSION='^[0-9]+\.[0-9]+\.[0-9]+$'
RE_ALLOW='^[A-Za-z0-9_.,*@/-]*$'
RE_TIME='^([01][0-9]|2[0-3]):[0-5][0-9]$'

valid() {
  case "$1" in
    N8N_DATA_DIR)               [ -n "$2" ] ;;
    N8N_VERSION|DOCKER_NETWORK) [[ "$2" =~ $RE_NAME ]] ;;
    N8N_HOST_PORT)              [[ "$2" =~ $RE_NUMBER ]] && [ "$2" -ge 1 ] && [ "$2" -le 65535 ] ;;
    N8N_WEBHOOK_URL)            [ -z "$2" ] || [[ "$2" =~ $RE_URL ]] ;;
    TASK_TIMEOUT)               [[ "$2" =~ $RE_NUMBER ]] && [ "$2" -ge 1 ] ;;
    JS_*|PY_*)                  [[ "$2" =~ $RE_ALLOW ]] ;;
    ENABLE_EXEC_NODES)          [ "$2" = yes ] || [ "$2" = no ] ;;
    NIGHTLY_TIME)               [ "$2" = off ] || [[ "$2" =~ $RE_TIME ]] ;;
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
      echo "${C_ERR}The settings file has a value that doesn't work for $key: $value${C_OFF}"
      echo "Fix it in $SETTINGS_FILE, or run with --reconfigure."
      exit 1
    fi
    printf -v "$key" '%s' "$value"
  done < "$SETTINGS_FILE"
}

save_settings() {
  local key
  {
    echo "# Settings for n8n-setup-mac-linux.sh, saved $(date '+%Y-%m-%d %H:%M')."
    echo "# Keep this file in the same folder as the script. Edit the values here,"
    echo "# or run the script with --reconfigure to answer the questions again."
    for key in $SETTING_NAMES; do
      echo "$key=${!key}"
    done
  } > "$SETTINGS_FILE"
  echo "${C_OK}Saved your answers to $SETTINGS_FILE${C_OFF}"
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
  echo "${C_ASK}$2${C_OFF}"
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
    echo "${C_WARN}  Sorry, that won't work here. Have another go.${C_OFF}"
  done
}

# ask_yes_no "Question" y|n : prints the question and returns success for yes.
# The second argument is what pressing Enter means.
ask_yes_no() {
  local answer hint
  if [ "$2" = y ]; then
    hint="Press Enter for yes, or type n for no: "
  else
    hint="Press Enter for no, or type y for yes: "
  fi
  echo
  echo "${C_ASK}$1${C_OFF}"
  while true; do
    read -r -p "  $hint" answer
    answer="${answer:-$2}"
    case "$answer" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
    esac
    echo "${C_WARN}  Please type y for yes or n for no.${C_OFF}"
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
# normalize_time "2am" prints 02:00. It understands 2, 2:30, 14:30, 2am, 2:30 pm
# and so on, and prints nothing for anything else.
RE_TIME_INPUT='^([0-9]{1,2})(:([0-9]{2}))?(am|pm|a|p)?$'
normalize_time() {
  local s h m
  s="$(echo "$1" | tr 'A-Z' 'a-z' | tr -d ' .')"
  if ! [[ "$s" =~ $RE_TIME_INPUT ]]; then return 0; fi
  h=$((10#${BASH_REMATCH[1]}))
  m=$((10#${BASH_REMATCH[3]:-0}))
  case "${BASH_REMATCH[4]}" in
    a|am|p|pm)
      if [ "$h" -lt 1 ] || [ "$h" -gt 12 ]; then return 0; fi
      if [ "$h" -eq 12 ]; then h=0; fi
      case "${BASH_REMATCH[4]}" in p|pm) h=$((h + 12)) ;; esac ;;
  esac
  if [ "$h" -le 23 ] && [ "$m" -le 59 ]; then printf '%02d:%02d' "$h" "$m"; fi
}

# show_time 14:30 prints "2:30 PM".
show_time() {
  local h=$((10#${1%%:*})) m="${1#*:}" half=AM
  if [ "$h" -ge 12 ]; then half=PM; fi
  h=$((h % 12))
  if [ "$h" -eq 0 ]; then h=12; fi
  echo "$h:$m $half"
}

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
  echo "${C_ASK}$question${C_OFF}"
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
    echo "${C_WARN}  Please type a number from 1 to $#.${C_OFF}"
  done
}

# image_list js-builtin|js-npm|py-stdlib prints, comma separated, what the
# runners image offers. It asks the image itself, so the list always matches
# the version that will run, and prints nothing if Docker can't answer.
image_list() {
  local image="n8nio/runners:$IMAGE_TAG"
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "${C_DIM}  Downloading the n8n runners image to read the list. This can take a minute...${C_OFF}" >&2
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
    echo "${C_WARN}  I couldn't read the list from Docker. The names are at $2${C_OFF}"
  fi
}

# pick_names NAME "Question" LIST: like ask, but turns down names that aren't
# in LIST so a typo doesn't slip through. An empty LIST skips that check.
pick_names() {
  local name="$1" question="$2" list="$3" n bad prev
  # A rejected answer must not become the next suggestion.
  prev="${!name}"
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
    echo "${C_WARN}  Not in the list:$bad. Check the spelling against the list above.${C_OFF}"
    printf -v "$name" '%s' "$prev"
  done
}

# show_banner prints the n8n wiz title in the header color.
show_banner() {
  printf '%s' "$C_HEAD"
  cat <<'BANNER'
            /$$$$$$                                /$$
           /$$__  $$                              |__/
 /$$$$$$$ | $$  \ $$ /$$$$$$$        /$$  /$$  /$$ /$$ /$$$$$$$$
| $$__  $$|  $$$$$$/| $$__  $$      | $$ | $$ | $$| $$|____ /$$/
| $$  \ $$ >$$__  $$| $$  \ $$      | $$ | $$ | $$| $$   /$$$$/
| $$  | $$| $$  \ $$| $$  | $$      | $$ | $$ | $$| $$  /$$__/
| $$  | $$|  $$$$$$/| $$  | $$      |  $$$$$/$$$$/| $$ /$$$$$$$$
|__/  |__/ \______/ |__/  |__/       \_____/\___/ |__/|________/
BANNER
  printf '%s' "$C_OFF"
  echo "${C_DIM}  version $SCRIPT_VERSION${C_OFF}"
}

# new_screen "question 1 of 8, Data folder" [COLOR]: clears the screen so each
# question stands on its own instead of scrolling under the ones before it.
# COLOR replaces the usual header color.
new_screen() {
  clear 2>/dev/null || printf '\033[2J\033[H'
  echo "${2:-$C_HEAD}Setting up n8n: $1${C_OFF}"
  echo "${C_DIM}If you're not sure, press Enter to take the suggested answer.${C_OFF}"
  echo "${C_DIM}Made a mistake? You can change any answer on the summary screen at the end.${C_OFF}"
}

question_1() {
  new_screen "question 1 of 8, Data folder"
  ask N8N_DATA_DIR "Where should n8n keep its workflows, credentials and other data?"
}

question_2() {
  new_screen "question 2 of 8, Port"
  ask N8N_HOST_PORT "Which port number should n8n use? If you don't know what that means, just press Enter."
}

question_3() {
  new_screen "question 3 of 8, Internet address"
  local has_url=n
  [ -n "$N8N_WEBHOOK_URL" ] && has_url=y
  if ask_yes_no "Will anyone reach this n8n from the internet, at an address like https://n8n.example.com? Say no if you'll only use it on this computer." "$has_url"; then
    while true; do
      ask N8N_WEBHOOK_URL "What's that address? Include the https:// at the start."
      [ -n "$N8N_WEBHOOK_URL" ] && break
      echo "${C_WARN}  You said people will reach it from the internet, so I need the address.${C_OFF}"
    done
  else
    N8N_WEBHOOK_URL=""
  fi
}

question_4() {
  new_screen "question 4 of 8, Code node time limit"
  ask TASK_TIMEOUT "How many seconds should a Code node get to finish before n8n stops it? The suggestion is $(show_seconds "$TASK_TIMEOUT"). For 10 minutes, type 600."
}

question_5() {
  new_screen "question 5 of 8, JavaScript libraries" "$C_JS"
  echo
  echo "${C_DIM}Allowing everything is easiest, but it also lets a Code node do more on${C_OFF}"
  echo "${C_DIM}the machine it runs on. If you want to read up before deciding, see${C_OFF}"
  echo "${C_DIM}https://docs.n8n.io/deploy/host-n8n/configure-n8n/security/harden-task-runners${C_OFF}"
  local js_default=4 js_now=""
  if [ "$JS_BUILTIN_ALLOW" = "*" ] && [ "$JS_EXTERNAL_ALLOW" = "*" ]; then js_default=1
  elif [ "$JS_BUILTIN_ALLOW" = crypto ] && [ "$JS_EXTERNAL_ALLOW" = moment ]; then js_default=2
  elif [ -z "$JS_BUILTIN_ALLOW" ] && [ -z "$JS_EXTERNAL_ALLOW" ]; then js_default=3
  else js_now=" (you have $(show_value "$JS_BUILTIN_ALLOW") and $(show_value "$JS_EXTERNAL_ALLOW") now)"
  fi
  menu "${C_JS}Which libraries can JavaScript Code nodes use?${C_OFF}" "$js_default" \
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
      echo "${C_ASK}First, Node.js built-in libraries.${C_OFF}"
      wait_for_runners_image
      list="$(image_list js-builtin)"
      show_list "$list" "https://nodejs.org/api/"
      pick_names JS_BUILTIN_ALLOW "Type the ones to allow, separated by commas:" "$list"
      echo
      echo "${C_ASK}Now npm packages.${C_OFF}"
      list="$(image_list js-npm)"
      show_list "$list" "https://github.com/n8n-io/n8n/tree/master/docker/images/runners"
      pick_names JS_EXTERNAL_ALLOW "Type the ones to allow, separated by commas:" "$list"
      ;;
  esac

}

# Python's extra packages in the image are only the runner's own plumbing,
# so they follow the standard library answer instead of getting a question.
question_6() {
  new_screen "question 6 of 8, Python libraries" "$C_PY"
  echo
  echo "${C_DIM}Allowing everything is easiest, but it also lets a Code node do more on${C_OFF}"
  echo "${C_DIM}the machine it runs on. If you want to read up before deciding, see${C_OFF}"
  echo "${C_DIM}https://docs.n8n.io/deploy/host-n8n/configure-n8n/security/harden-task-runners${C_OFF}"
  local py_common="json,datetime,math,re,random,statistics" py_default=4 py_now=""
  if [ "$PY_STDLIB_ALLOW" = "*" ]; then py_default=1
  elif [ "$PY_STDLIB_ALLOW" = "$py_common" ]; then py_default=2
  elif [ -z "$PY_STDLIB_ALLOW" ]; then py_default=3
  else py_now=" (you have $PY_STDLIB_ALLOW now)"
  fi
  menu "${C_PY}Which libraries can Python Code nodes use?${C_OFF}" "$py_default" \
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
}

question_7() {
  new_screen "question 7 of 8, Execute Command and Local File Trigger"
  echo
  echo "n8n 2.0 and later switch off two nodes for safety:"
  echo
  echo "  Execute Command     runs any command you give it, such as a script or a"
  echo "                      program. It runs inside n8n's Docker container."
  echo "  Local File Trigger  starts a workflow when a file or folder changes."
  echo
  echo "If you say no, workflows that use either of these two nodes stop working."
  echo "Everything else keeps working, including Read/Write Files from Disk,"
  echo "Compression (zip and unzip), and Convert to File / Extract from File."
  echo
  echo "If you say yes, anyone who can edit workflows on this n8n can run any"
  echo "command inside its container, which holds your saved credentials and the"
  echo "key that unlocks them. If you're the only person using this n8n, that"
  echo "risk is small. If you use Execute Command today, say yes."
  local exec_default=n
  [ "$ENABLE_EXEC_NODES" = yes ] && exec_default=y
  if ask_yes_no "Do you want them switched back on?" "$exec_default"; then
    ENABLE_EXEC_NODES=yes
  else
    ENABLE_EXEC_NODES=no
  fi
}

question_8() {
  new_screen "question 8 of 8, Nightly update"
  local nightly_default=y answer t
  [ "$NIGHTLY_TIME" = off ] && nightly_default=n
  if ask_yes_no "Do you want this script to run by itself every night, so n8n always stays up to date? This computer needs to be on at that time." "$nightly_default"; then
    [ "$NIGHTLY_TIME" = off ] && NIGHTLY_TIME="02:00"
    echo
    echo "${C_ASK}What time should it run? n8n is down for a few seconds while it updates,${C_OFF}"
    echo "${C_ASK}so pick a time nobody is using it. You can type 2am, 2:30am, 11pm or 23:00.${C_OFF}"
    while true; do
      read -r -p "  Press Enter for $(show_time "$NIGHTLY_TIME"), or type a time: " answer
      t="$(normalize_time "${answer:-$NIGHTLY_TIME}")"
      if [ -n "$t" ]; then
        NIGHTLY_TIME="$t"
        break
      fi
      echo "${C_WARN}  Sorry, I didn't understand that time. Try something like 2am or 23:00.${C_OFF}"
    done
  else
    NIGHTLY_TIME=off
  fi
}

# Every answer on one numbered screen. Typing a number shows that question
# again, so a mistake is easy to fix before anything is saved.
run_questions() {
  local n answer note=""
  clear 2>/dev/null || printf '\033[2J\033[H'
  show_banner
  echo
  echo "Welcome. This sets up n8n on this computer and keeps it up to date."
  echo "You'll answer 8 quick questions, each with a suggested answer. If you're"
  echo "not sure, press Enter to take it. You can fix any answer at the end."
  echo
  read -r -p "  Press Enter to start: " answer || true
  for n in 1 2 3 4 5 6 7 8; do "question_$n"; done
  while true; do
    clear 2>/dev/null || printf '\033[2J\033[H'
    echo "${C_HEAD}Setting up n8n: check your answers${C_OFF}"
    echo
    echo "  1  Data folder:                    $N8N_DATA_DIR"
    echo "  2  Port:                           $N8N_HOST_PORT"
    echo "  3  Internet address:               ${N8N_WEBHOOK_URL:-none, this computer only}"
    echo "  4  Code node time limit:           $(show_seconds "$TASK_TIMEOUT")"
    echo "${C_JS}  5  JavaScript built-in libraries:  $(show_value "$JS_BUILTIN_ALLOW")"
    echo "     JavaScript npm packages:        $(show_value "$JS_EXTERNAL_ALLOW")${C_OFF}"
    echo "${C_PY}  6  Python libraries:               $(show_value "$PY_STDLIB_ALLOW")${C_OFF}"
    echo "  7  Execute Command and Local File: $ENABLE_EXEC_NODES"
    if [ "$NIGHTLY_TIME" = off ]; then
      echo "  8  Nightly update:                 off"
    else
      echo "  8  Nightly update:                 every night at $(show_time "$NIGHTLY_TIME")"
    fi
    echo
    echo "${C_DIM}You can also change any of this later by running the script with --reconfigure.${C_OFF}"
    echo "${C_DIM}To quit without saving anything, press Ctrl+C.${C_OFF}"
    if [ -n "$note" ]; then echo; echo "${C_WARN}  $note${C_OFF}"; note=""; fi
    echo
    read -r -p "  Press Enter to save and start n8n, or type a number to change that answer: " answer || answer=""
    case "$answer" in
      "") break ;;
      [1-8]) "question_$answer" ;;
      *) note="Please press Enter, or type a number from 1 to 8." ;;
    esac
  done
  ASKED_QUESTIONS=yes
  save_settings
}

# ---- Updating n8n wiz itself -------------------------------------------------
# Each run asks GitHub for the newest n8n wiz release and says when there's a
# newer one. --update installs it, but only when someone asks for it. The
# script never replaces itself on its own, so new code from GitHub never runs
# on a machine until a person decides it should.

GITHUB_REPO="dtsoden/n8n-wiz"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

version_lt() {  # version_lt A B: true when release A is older than release B
  local IFS=. i
  local -a a b
  a=($1); b=($2)
  for i in 0 1 2; do
    [ "${a[i]}" -lt "${b[i]}" ] && return 0
    [ "${a[i]}" -gt "${b[i]}" ] && return 1
  done
  return 1
}

newest_script_version() {  # the newest n8n wiz release on GitHub, e.g. 1.2.0, or nothing
  curl -fsS --max-time 10 "https://api.github.com/repos/$GITHUB_REPO/releases/latest" 2>/dev/null \
    | grep -o '"tag_name": *"v[0-9]*\.[0-9]*\.[0-9]*"' | grep -o '[0-9]*\.[0-9]*\.[0-9]*' | head -1 || true
}

run_update() {
  local newest tmp
  echo "Checking GitHub for the newest n8n wiz..."
  newest="$(newest_script_version)"
  if ! [[ "$newest" =~ $RE_VERSION ]]; then
    echo "${C_ERR}I couldn't reach GitHub to check for a newer n8n wiz. Try again later.${C_OFF}"
    NOT_A_BUG=yes
    exit 1
  fi
  if ! version_lt "$SCRIPT_VERSION" "$newest"; then
    echo "${C_OK}You already have the newest n8n wiz ($SCRIPT_VERSION).${C_OFF}"
    exit 0
  fi
  echo "Downloading n8n wiz $newest..."
  tmp="$SCRIPT_PATH.new"
  # Check the download before using it: it must be a script bash can read, and
  # it must say it is the version the release says it is.
  if ! curl -fsSL --max-time 60 -o "$tmp" \
         "https://github.com/$GITHUB_REPO/releases/download/v$newest/n8n-setup-mac-linux.sh" \
     || ! bash -n "$tmp" 2>/dev/null \
     || ! grep -q "^SCRIPT_VERSION=\"$newest\"$" "$tmp"; then
    rm -f "$tmp"
    echo "${C_ERR}The download didn't come through right, so nothing was changed. Try again later.${C_OFF}"
    NOT_A_BUG=yes
    exit 1
  fi
  cp -p "$SCRIPT_PATH" "$SCRIPT_PATH.previous"
  if [ -x "$SCRIPT_PATH" ]; then chmod +x "$tmp"; fi
  # mv swaps in a new file rather than writing over this one while it runs.
  mv "$tmp" "$SCRIPT_PATH"
  echo "${C_OK}Updated n8n wiz from $SCRIPT_VERSION to $newest.${C_OFF}"
  echo "Your settings are unchanged. The old version is saved as"
  echo "  $SCRIPT_PATH.previous"
  echo "What's new: https://github.com/$GITHUB_REPO/releases/tag/v$newest"
  echo "The nightly update uses the new version from tonight."
  exit 0
}

if [ "$UPDATE" = yes ]; then run_update; fi

# ---- Docker -----------------------------------------------------------------
# Everything after the questions needs Docker, so make sure it is installed and
# running before asking anything. [ -t 0 ] is true when someone is at the
# keyboard. Under cron it is false, so a scheduled run never stops to wait for
# an answer.

# The title shows whenever someone is watching, but never in the nightly log.
if [ -t 0 ] && [ "$NO_QUESTIONS" != yes ]; then
  show_banner
  echo
else
  # The nightly log still records which version ran.
  echo "n8n-setup-mac-linux.sh version $SCRIPT_VERSION, $(date '+%Y-%m-%d %H:%M')"
fi

# Say so when a newer n8n wiz is out. Quiet when GitHub can't be reached.
NEWEST_SCRIPT=""
if [ "$REMOVE" != yes ]; then
  NEWEST_SCRIPT="$(newest_script_version)"
  if [[ "$NEWEST_SCRIPT" =~ $RE_VERSION ]] && version_lt "$SCRIPT_VERSION" "$NEWEST_SCRIPT"; then
    echo "${C_WARN}n8n wiz $NEWEST_SCRIPT is available (you have $SCRIPT_VERSION). Run this script with --update to get it.${C_OFF}"
    echo "What's new: https://github.com/$GITHUB_REPO/releases/tag/v$NEWEST_SCRIPT"
  else
    NEWEST_SCRIPT=""
  fi
fi

if [ "$RECONFIGURE" = yes ] && [ ! -t 0 ]; then
  echo "${C_ERR}--reconfigure needs someone at the keyboard to answer the questions.${C_OFF}"
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
  echo "${C_ERR}Docker isn't installed on this computer, and n8n runs inside it.${C_OFF}"
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
    echo "${C_WARN}Docker isn't running. Trying to start it...${C_OFF}"
  fi
  start_docker || true
  printf "Waiting for Docker to start"
  tries=0
  until docker info >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -gt 60 ]; then
      echo
      echo "${C_ERR}Docker still isn't running after 3 minutes. Open Docker yourself, wait${C_OFF}"
      echo "${C_ERR}until it says it's running, then run this script again.${C_OFF}"
      exit 1
    fi
    printf "."
    sleep 3
  done
  echo "${C_OK} Docker is running.${C_OFF}"
fi

# ---- Uninstall (--remove) ---------------------------------------------------
# Takes away everything this script set up. Your workflows and credentials are
# a separate question, and deleting them means typing the word "delete", so a
# stray Enter can't wipe them.

run_remove() {
  local answer
  if [ ! -t 0 ]; then
    echo "${C_ERR}--remove needs someone at the keyboard to confirm.${C_OFF}"
    exit 1
  fi
  clear 2>/dev/null || printf '\033[2J\033[H'
  show_banner
  echo
  echo "${C_HEAD}Removing n8n from this computer${C_OFF}"
  echo
  echo "This will:"
  echo "  - stop and delete the n8n and n8n-runners containers"
  echo "  - delete the $DOCKER_NETWORK Docker network"
  echo "  - delete the downloaded n8n and n8n runners images"
  echo "  - turn off the nightly update"
  echo "  - delete your saved answers and the nightly log next to this script"
  echo
  echo "Your workflows, credentials and files in $N8N_DATA_DIR are kept"
  echo "unless you choose otherwise on the next question."
  if ! ask_yes_no "${C_ERR}Remove n8n?${C_OFF}" n; then
    echo "OK, nothing was removed."
    exit 0
  fi

  local delete_data=no
  if [ -d "$N8N_DATA_DIR" ] && [ "$N8N_DATA_DIR" != "/" ] && [ "$N8N_DATA_DIR" != "$HOME" ]; then
    echo
    echo "${C_ERR}Do you also want to delete $N8N_DATA_DIR?${C_OFF}"
    echo "That's every workflow, credential and file n8n has. It can't be undone."
    read -r -p "  Type delete to delete it, or press Enter to keep it: " answer || answer=""
    [ "$answer" = delete ] && delete_data=yes
  fi

  echo
  echo "Removing the containers..."
  docker rm -f n8n n8n-runners >/dev/null 2>&1 || true
  echo "Removing the network..."
  docker network rm "$DOCKER_NETWORK" >/dev/null 2>&1 || true
  echo "Removing the images..."
  local images
  images="$(docker images -q n8nio/n8n; docker images -q n8nio/runners)"
  if [ -n "$images" ]; then
    # shellcheck disable=SC2086
    docker rmi -f $images >/dev/null 2>&1 || true
  fi
  if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -qF "$CRON_TAG"; then
    echo "Turning off the nightly update..."
    crontab -l 2>/dev/null | grep -vF "$CRON_TAG" | crontab - || true
  fi
  echo "Removing the saved answers and the nightly log..."
  rm -f "$SETTINGS_FILE" "$SCRIPT_DIR/n8n-nightly.log" "$SCRIPT_PATH.previous"

  echo
  if [ "$delete_data" = yes ]; then
    if rm -rf "$N8N_DATA_DIR" 2>/dev/null; then
      echo "Deleted $N8N_DATA_DIR."
    else
      echo "${C_WARN}Some files in $N8N_DATA_DIR belong to the container's user, so I"
      echo "couldn't delete them all. Finish with: sudo rm -rf \"$N8N_DATA_DIR\"${C_OFF}"
    fi
  else
    echo "Your workflows, credentials and files are still in $N8N_DATA_DIR."
    echo "Run this script again any time to bring n8n back with them."
  fi
  echo "${C_OK}n8n has been removed.${C_OFF} This script is still here; delete its folder"
  echo "if you don't need it anymore."
  exit 0
}

if [ "$REMOVE" = yes ]; then run_remove; fi

# ---- Which n8n version to run -----------------------------------------------
# A new major version of n8n (2.x to 3.x) almost always has breaking changes,
# so "latest" means the newest release in the major version already installed.
# Unattended runs never move up a major version. A run at the keyboard asks.

container_version() {  # the n8n version the n8n container runs, e.g. 2.45.4
  docker container inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' n8n 2>/dev/null || true
}
image_version() {  # image_version IMAGE: the n8n version an image holds
  docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$1" 2>/dev/null || true
}
hub_digests() {  # hub_digests TAG: the image digests Docker Hub lists for n8nio/n8n:TAG
  curl -fsS "https://hub.docker.com/v2/repositories/n8nio/n8n/tags/$1" 2>/dev/null \
    | grep -o 'sha256:[0-9a-f]*' | sort -u | tr '\n' ' ' || true
}
newest_in_major() {  # newest_in_major 2: the newest stable 2.x.y release on Docker Hub
  local tag beta next
  beta="$(hub_digests beta)"; next="$(hub_digests next)"
  # Newest first. The beta and next tags can point at a pre-release that
  # still has a plain number, so those are skipped.
  for tag in $(curl -fsS "https://hub.docker.com/v2/repositories/n8nio/n8n/tags?name=$1.&page_size=100&ordering=last_updated" 2>/dev/null \
      | grep -o "\"name\":\"$1\.[0-9]*\.[0-9]*\"" | sed 's/"name":"//; s/"//' \
      | sort -t. -k1,1nr -k2,2nr -k3,3nr); do
    case "$(hub_digests "$tag")" in
      "$beta"|"$next"|"") continue ;;
    esac
    echo "$tag"
    return 0
  done
}

ask_major_upgrade() {  # ask_major_upgrade CURRENT NEWEST
  local new_major="${2%%.*}"
  clear 2>/dev/null || printf '\033[2J\033[H'
  show_banner
  echo
  echo "${C_WARN}n8n $2 is out. You're on n8n $1.${C_OFF}"
  echo
  echo "A new major version usually has breaking changes. Some nodes are removed"
  echo "and some defaults change, so a few workflows may need fixing first."
  echo "Before upgrading, open n8n, go to Settings > Migration Report and fix what"
  echo "it flags, and back up your data folder. What's changing:"
  echo "https://docs.n8n.io/changelog/v${new_major}0-breaking-changes"
  echo
  echo "If you say no, you stay on n8n ${1%%.*} and keep getting its updates."
  ask_yes_no "Upgrade to n8n $2 now?" n
}

IMAGE_TAG="$N8N_VERSION"
if [ "$N8N_VERSION" = latest ]; then
  CURRENT_VERSION="$(container_version)"
  echo "Checking for the newest n8n..."
  NEWEST_VERSION=""
  if docker pull -q n8nio/n8n:latest >/dev/null 2>&1; then
    NEWEST_VERSION="$(image_version n8nio/n8n:latest)"
  fi
  cur_major="${CURRENT_VERSION%%.*}"
  new_major="${NEWEST_VERSION%%.*}"
  if ! [[ "$NEWEST_VERSION" =~ $RE_VERSION ]]; then
    # Couldn't check, so keep what's running (or plain latest on a new install).
    IMAGE_TAG="${CURRENT_VERSION:-latest}"
  elif ! [[ "$CURRENT_VERSION" =~ $RE_VERSION ]] || [ "$cur_major" = "$new_major" ]; then
    IMAGE_TAG="$NEWEST_VERSION"
  elif [ "$new_major" -gt "$cur_major" ]; then
    if [ -t 0 ] && [ "$NO_QUESTIONS" != yes ] && ask_major_upgrade "$CURRENT_VERSION" "$NEWEST_VERSION"; then
      IMAGE_TAG="$NEWEST_VERSION"
    else
      IMAGE_TAG="$(newest_in_major "$cur_major")"
      [[ "$IMAGE_TAG" =~ $RE_VERSION ]] || IMAGE_TAG="$CURRENT_VERSION"
      echo "${C_WARN}n8n $new_major is available. Staying on n8n $cur_major ($IMAGE_TAG).${C_OFF}"
      echo "To upgrade, run this script yourself and say yes when it asks."
    fi
  else
    # Already on something newer than latest, such as a beta. Leave it.
    IMAGE_TAG="$CURRENT_VERSION"
  fi
  # Never move back to an older release: n8n doesn't support downgrades, and
  # its database may already have the newer version's changes.
  if [[ "$CURRENT_VERSION" =~ $RE_VERSION ]] && [[ "$IMAGE_TAG" =~ $RE_VERSION ]] \
     && version_lt "$IMAGE_TAG" "$CURRENT_VERSION"; then
    echo "${C_WARN}You're on n8n $CURRENT_VERSION, newer than $IMAGE_TAG. Staying on $CURRENT_VERSION.${C_OFF}"
    IMAGE_TAG="$CURRENT_VERSION"
  fi
fi

# Start downloading both images now, so they're ready or nearly ready by the
# time the questions are done. The pull step further down waits for them.
docker pull -q "n8nio/runners:$IMAGE_TAG" >/dev/null 2>&1 &
RUNNERS_PULL_PID=$!
docker pull -q "n8nio/n8n:$IMAGE_TAG" >/dev/null 2>&1 &
N8N_PULL_PID=$!

# The list questions read from the runners image, so they wait for it first.
wait_for_runners_image() {
  if [ -n "$RUNNERS_PULL_PID" ]; then
    echo "${C_DIM}  Waiting for the n8n download to finish so I can read the list...${C_OFF}"
    wait "$RUNNERS_PULL_PID" || true
    RUNNERS_PULL_PID=""
  fi
}

# ---- An n8n that was set up some other way ---------------------------------
# On a first run, an existing "n8n" container was set up by something else,
# and this script would replace it. Say so, ask first, and suggest that
# container's data folder, port and public address so nothing gets lost.

# Containers this script starts carry this label, so it can tell its own n8n
# from one set up some other way.
OUR_LABEL="n8n-docker-task-runners=managed"

is_our_n8n() {
  docker container inspect -f '{{json .Config.Labels}}' n8n 2>/dev/null | grep -qF '"n8n-docker-task-runners":"managed"'
}

adopt_existing_n8n() {
  docker container inspect n8n >/dev/null 2>&1 || return 0
  local info rest type src vol port envs url
  info="$(docker container inspect -f '{{range .Mounts}}{{if eq .Destination "/home/node/.n8n"}}{{.Type}}|{{.Source}}|{{if eq .Type "volume"}}{{.Name}}{{end}}{{end}}{{end}}' n8n 2>/dev/null)"
  type="${info%%|*}"; rest="${info#*|}"; src="${rest%%|*}"; vol="${rest#*|}"
  # "|| true": a binding with no entries makes the template fail; no port then.
  port="$(docker container inspect -f '{{range $p, $b := .HostConfig.PortBindings}}{{if eq $p "5678/tcp"}}{{(index $b 0).HostPort}}{{end}}{{end}}' n8n 2>/dev/null || true)"
  envs="$(docker container inspect -f '{{range .Config.Env}}{{println .}}{{end}}' n8n 2>/dev/null)"
  url="$(printf '%s\n' "$envs" | sed -n 's/^N8N_WEBHOOK_URL=//p; s/^WEBHOOK_URL=//p' | head -1)"

  clear 2>/dev/null || printf '\033[2J\033[H'
  show_banner
  echo
  echo "${C_WARN}There's already an n8n on this computer, in a container called n8n.${C_OFF}"
  echo "If you go ahead, this script replaces that container with its own setup."
  echo
  if [ "$type" = bind ] && [ -n "$src" ]; then
    echo "Its workflows and credentials are in $src."
    echo "I'll suggest that folder as the data folder, so they carry over."
    N8N_DATA_DIR="$src"
  elif [ "$type" = volume ]; then
    echo "${C_WARN}Its workflows and credentials are in a Docker volume called $vol,${C_OFF}"
    echo "${C_WARN}not in a folder. This script uses a folder, so the new n8n would${C_OFF}"
    echo "${C_WARN}start empty. The volume itself isn't deleted.${C_OFF}"
  else
    echo "${C_WARN}I couldn't tell where its workflows and credentials are kept.${C_OFF}"
  fi
  if [ -n "$port" ] && valid N8N_HOST_PORT "$port"; then
    echo "It uses port $port, so I'll suggest that too."
    N8N_HOST_PORT="$port"
  fi
  if [ -n "$url" ] && valid N8N_WEBHOOK_URL "$url"; then
    echo "Its public address is $url, so I'll suggest that as well."
    N8N_WEBHOOK_URL="$url"
  fi
  if printf '%s\n' "$envs" | grep -q '^N8N_ENCRYPTION_KEY='; then
    echo
    echo "${C_ERR}It also sets its encryption key directly, and this script doesn't. Without${C_OFF}"
    echo "${C_ERR}that key the new n8n can't read your saved credentials. Only go ahead if${C_OFF}"
    echo "${C_ERR}you know the same key is saved in the data folder's config file.${C_OFF}"
  fi
  echo
  echo "Any other settings you gave the old container aren't carried over."
  if ! ask_yes_no "Do you want to replace it?" n; then
    echo "OK, nothing was changed."
    exit 0
  fi
}

# A run at the keyboard with saved answers would otherwise replace, without a
# word, an n8n that something else installed or replaced since the last run.
# Say so, show what will be used, and ask first.
confirm_foreign_n8n() {
  docker container inspect n8n >/dev/null 2>&1 || return 0
  if is_our_n8n; then return 0; fi
  local src port
  src="$(docker container inspect -f '{{range .Mounts}}{{if eq .Destination "/home/node/.n8n"}}{{.Source}}{{end}}{{end}}' n8n 2>/dev/null || true)"
  port="$(docker container inspect -f '{{range $p, $b := .HostConfig.PortBindings}}{{if eq $p "5678/tcp"}}{{(index $b 0).HostPort}}{{end}}{{end}}' n8n 2>/dev/null || true)"
  echo
  echo "${C_WARN}The n8n running now wasn't set up by n8n wiz. Something else may have${C_OFF}"
  echo "${C_WARN}installed or replaced it since you last ran this script.${C_OFF}"
  echo "If you go ahead, it's replaced using your saved n8n wiz settings:"
  echo "  Data folder: $N8N_DATA_DIR"
  if [ -n "$src" ] && [ "${src%/}" != "${N8N_DATA_DIR%/}" ]; then
    echo "${C_ERR}  The running n8n keeps its data in $src instead. Its workflows${C_OFF}"
    echo "${C_ERR}  only come along if that's the same folder.${C_OFF}"
  fi
  echo "  Port:        $N8N_HOST_PORT"
  if [ -n "$port" ] && [ "$port" != "$N8N_HOST_PORT" ]; then
    echo "${C_WARN}  The running n8n uses port $port.${C_OFF}"
  fi
  if ! ask_yes_no "Do you want to replace it with your n8n wiz setup?" n; then
    echo "OK, nothing was changed."
    exit 0
  fi
}

# ---- Work out the settings --------------------------------------------------

if [ "$RECONFIGURE" = yes ]; then
  if [ ! -f "$SETTINGS_FILE" ]; then adopt_existing_n8n; else confirm_foreign_n8n; fi
  run_questions
elif [ -f "$SETTINGS_FILE" ]; then
  echo "Using settings from $SETTINGS_FILE"
  if [ -t 0 ] && [ "$NO_QUESTIONS" != yes ]; then confirm_foreign_n8n; fi
elif [ "$NO_QUESTIONS" = yes ] || [ ! -t 0 ]; then
  # Nobody is here to answer the question adopt_existing_n8n asks, so an n8n
  # this script didn't create is left alone rather than replaced.
  if docker container inspect n8n >/dev/null 2>&1 && ! is_our_n8n; then
    echo "${C_ERR}There's an n8n on this computer that this script didn't set up, and${C_OFF}"
    echo "${C_ERR}there's no settings file next to the script, so nothing was changed.${C_OFF}"
    echo "Run the script once without --no-questions to decide what to do with it."
    NOT_A_BUG=yes
    exit 1
  fi
  echo "No settings file next to the script; using the values written in it."
else
  adopt_existing_n8n
  run_questions
fi

# Values typed straight into this script are checked here too.
for key in $SETTING_NAMES; do
  if ! valid "$key" "${!key}"; then
    echo "${C_ERR}The value for $key doesn't work: ${!key}${C_OFF}"
    exit 1
  fi
done

# No public address means a machine used only locally.
WEBHOOK_URL_TO_USE="${N8N_WEBHOOK_URL:-http://localhost:$N8N_HOST_PORT/}"

# ---- Pull images first ------------------------------------------------------
# Pulling before removing anything means a typo in the version or a network
# problem stops the script while your current n8n is still running.

echo "Pulling n8nio/n8n:$IMAGE_TAG and n8nio/runners:$IMAGE_TAG..."
# Let the background downloads finish. Pulling again afterwards takes a moment
# and shows a real error if one of them failed.
if [ -n "$RUNNERS_PULL_PID" ]; then wait "$RUNNERS_PULL_PID" || true; fi
wait "$N8N_PULL_PID" || true
docker pull "n8nio/n8n:$IMAGE_TAG"
docker pull "n8nio/runners:$IMAGE_TAG"

# ---- Remove old containers --------------------------------------------------
# "|| true" keeps going when the containers don't exist yet (first run).

echo "Stopping and removing old containers..."
docker stop n8n n8n-runners >/dev/null 2>&1 || true
docker rm -f n8n n8n-runners >/dev/null 2>&1 || true

# ---- Network and data folder ------------------------------------------------

echo "Creating network $DOCKER_NETWORK if needed..."
docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1 || docker network create "$DOCKER_NETWORK"

mkdir -p "$N8N_DATA_DIR" "$N8N_DATA_DIR/files"

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
#   -v DATA/files:/home/node/.n8n-files
#                                n8n 2.x limits Read/Write Files from Disk to
#                                /home/node/.n8n-files. Linking it to a folder
#                                on your machine keeps those files through
#                                updates and lets you add or collect them
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
#   N8N_COMPRESSION_NODE_*       keep the 2.x Compression node limits (2 GiB
#                                unzipped, 5000 files), which n8n 3.0 lowers
#   N8N_UNVERIFIED_PACKAGES_ENABLED=true
#                                keeps installed community nodes loading,
#                                which n8n 3.0 turns off by default
#   (n8n 1.x also needed N8N_RUNNERS_ENABLED=true. n8n 2.x says it is no
#   longer needed, so it is left out. Add it back only if you pin a 1.x version.)

EXEC_NODES_ENV=()
if [ "$ENABLE_EXEC_NODES" = yes ]; then
  EXEC_NODES_ENV=(-e "NODES_EXCLUDE=[]")
fi

echo "Starting n8n..."
docker run -d \
  --name n8n \
  --label "$OUR_LABEL" \
  --restart always \
  --network "$DOCKER_NETWORK" \
  -p "$N8N_HOST_PORT:5678" \
  -v "$N8N_DATA_DIR:/home/node/.n8n" \
  -v "$N8N_DATA_DIR/files:/home/node/.n8n-files" \
  -e N8N_WEBHOOK_URL="$WEBHOOK_URL_TO_USE" \
  -e N8N_RUNNERS_MODE=external \
  -e N8N_RUNNERS_AUTH_TOKEN="$N8N_RUNNERS_AUTH_TOKEN" \
  -e N8N_RUNNERS_TASK_TIMEOUT="$TASK_TIMEOUT" \
  -e N8N_RUNNERS_BROKER_LISTEN_ADDRESS=0.0.0.0 \
  -e N8N_NATIVE_PYTHON_RUNNER=true \
  -e N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES=2147483648 \
  -e N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES=5000 \
  -e N8N_UNVERIFIED_PACKAGES_ENABLED=true \
  "${EXEC_NODES_ENV[@]}" \
  "n8nio/n8n:$IMAGE_TAG"

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
  --label "$OUR_LABEL" \
  --restart always \
  --network "$DOCKER_NETWORK" \
  -e N8N_RUNNERS_AUTH_TOKEN="$N8N_RUNNERS_AUTH_TOKEN" \
  -e N8N_RUNNERS_TASK_BROKER_URI=http://n8n:5679 \
  -e N8N_RUNNERS_TASK_TIMEOUT="$TASK_TIMEOUT" \
  -v "$N8N_DATA_DIR/task-runners.json:/etc/n8n-task-runners.json" \
  "n8nio/runners:$IMAGE_TAG"

echo
echo "${C_OK}Done. Open http://localhost:$N8N_HOST_PORT${C_OFF}"
echo "Check the runners connected with: docker logs n8n"
echo "(look for two lines starting with: Registered runner)"

# ---- Nightly schedule -------------------------------------------------------
# Only after the questions, so a nightly run never rewrites its own schedule.
# The cron entry is found again by the tag at the end of its line. PATH is
# copied in because cron's own PATH usually can't find docker.

if [ "$ASKED_QUESTIONS" = yes ]; then
  echo
  if ! command -v crontab >/dev/null 2>&1; then
    echo "${C_WARN}I couldn't find cron on this computer, so I can't set up the nightly${C_OFF}"
    echo "${C_WARN}update. The README shows other ways to schedule it.${C_OFF}"
  else
    other_lines="$(crontab -l 2>/dev/null | grep -vF "$CRON_TAG" || true)"
    if [ "$NIGHTLY_TIME" = off ]; then
      if crontab -l 2>/dev/null | grep -qF "$CRON_TAG"; then
        printf '%s\n' "$other_lines" | crontab -
        echo "${C_OK}The nightly update is turned off.${C_OFF}"
      fi
    else
      script_path="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
      cron_line="$((10#${NIGHTLY_TIME#*:})) $((10#${NIGHTLY_TIME%%:*})) * * * PATH='$PATH' /bin/bash '$script_path' --no-questions >> '$SCRIPT_DIR/n8n-nightly.log' 2>&1 $CRON_TAG"
      if { if [ -n "$other_lines" ]; then printf '%s\n' "$other_lines"; fi; echo "$cron_line"; } | crontab -; then
        echo "${C_OK}n8n will update itself every night at $(show_time "$NIGHTLY_TIME").${C_OFF}"
        echo "Each run is logged to $SCRIPT_DIR/n8n-nightly.log"
      else
        echo "${C_WARN}I couldn't set up the nightly update. The README shows how to add it by hand.${C_OFF}"
      fi
    fi
  fi
fi

# Only when someone is watching, so the nightly log stays quiet.
if [ -t 0 ]; then
  echo
  if [ -n "$NEWEST_SCRIPT" ]; then
    echo "${C_WARN}n8n wiz $NEWEST_SCRIPT is available. Get it with: bash \"$0\" --update${C_OFF}"
    echo
  fi
  echo "Want to change an answer later? Run this script again like this:"
  echo "  bash \"$0\" --reconfigure"
  echo
  echo "${C_STAR}If this saved you some time, please give it a star on GitHub. Stars are${C_OFF}"
  echo "${C_STAR}how other n8n users find it. The Star button is at the top right of:${C_OFF}"
  echo "${C_STAR}https://github.com/dtsoden/n8n-wiz${C_OFF}"
fi
