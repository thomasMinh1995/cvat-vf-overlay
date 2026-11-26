#!/bin/bash
set -euo pipefail

export CVAT_VF_IMAGE=ghcr.io/thomasminh1995/cvat-vf-overlay:v2.83.1-vf-stable
label=com.cvat-vf.auto-update
state_dir="$HOME/Library/Application Support/CVAT VF Auto Update"
agent_dir="$HOME/Library/LaunchAgents"
plist="$agent_dir/$label.plist"
domain="gui/$(id -u)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
overlay="$script_dir/docker-compose.vf-ego.yml"
if [[ ! -f "$overlay" ]]; then
    overlay="$(dirname "$script_dir")/docker-compose.vf-ego.yml"
fi

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

update() {
    local docker_bin="$1" docker_context="$2"
    export PATH="$(dirname "$docker_bin"):/Applications/Docker.app/Contents/Resources/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
    local -a docker=("$docker_bin" --context "$docker_context")
    local template metadata project working_dir files env_files path server version
    template='{{.State.Running}}
{{index .Config.Labels "com.docker.compose.project"}}
{{index .Config.Labels "com.docker.compose.project.working_dir"}}
{{index .Config.Labels "com.docker.compose.project.config_files"}}
{{index .Config.Labels "com.docker.compose.project.environment_file"}}'
    if ! metadata=$("${docker[@]}" inspect --type container --format "$template" cvat_ui 2>/dev/null) ||
        [[ "${metadata%%$'\n'*}" != true ]]; then
        [[ "${3:-}" != --check ]] || fail 'Start CVAT before enabling auto-update.'
        printf '%s\n' 'CVAT UI is stopped or Docker Desktop is unavailable. Skipping.'
        return
    fi

    {
        read -r
        IFS= read -r project
        IFS= read -r working_dir
        IFS= read -r files
        IFS= read -r env_files
    } <<< "$metadata"$'\n'
    [[ -n "$project" && -d "$working_dir" && -n "$files" ]] ||
        fail 'CVAT Compose configuration could not be found on this Mac.'

    local -a compose=(compose --project-name "$project" --project-directory "$working_dir")
    local -a paths=()
    cd "$working_dir"
    if [[ -n "$env_files" ]]; then
        IFS=, read -r -a paths <<< "$env_files"
        for path in "${paths[@]}"; do
            [[ -f "$path" ]] || fail "Missing Compose environment file: $path"
            compose+=(--env-file "$path")
        done
    fi
    IFS=, read -r -a paths <<< "$files"
    for path in "${paths[@]}"; do
        [[ "$path" != "$overlay" ]] || continue
        [[ -f "$path" ]] || fail "Missing Compose file: $path"
        compose+=(-f "$path")
    done
    compose+=(-f "$overlay")

    server=$("${docker[@]}" "${compose[@]}" ps -q --status running cvat_server)
    [[ -n "$server" ]] || fail 'CVAT server is not running.'
    version=$("${docker[@]}" exec "$server" python -c 'from cvat import VERSION; print(".".join(map(str, VERSION[:3])))')
    [[ "$version" == 2.83.1 ]] || fail "CVAT server $version needs a different overlay channel."

    if [[ "${3:-}" != --check ]]; then
        "${docker[@]}" "${compose[@]}" up -d --no-deps --no-build --pull always cvat_ui
    fi
}

case "${1:-}" in
    --update)
        update "$2" "$3"
        exit
        ;;
    --disable)
        if launchctl print "$domain/$label" >/dev/null 2>&1; then
            launchctl bootout "$domain/$label"
        fi
        rm -f "$plist"
        printf '%s\n' 'CVAT VF auto-update disabled.'
        exit
        ;;
esac

[[ "$(uname -s)" == Darwin ]] || fail 'This installer is for macOS.'
time="${1:-08:00}"
[[ "$#" -le 1 && "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] ||
    fail "Usage: bash $0 [HH:MM|--disable]"

docker_bin="$(command -v docker)" || fail 'Docker CLI is unavailable. Start Docker Desktop first.'
context=$("$docker_bin" context show)
endpoint=$("$docker_bin" context inspect "$context" --format '{{.Endpoints.docker.Host}}')
[[ "$endpoint" == unix://* ]] || fail 'Select a local Docker Desktop context first.'
update "$docker_bin" "$context" --check

mkdir -p "$state_dir" "$agent_dir"
install -m 700 "$script_dir/enable-auto-update.sh" "$state_dir/enable-auto-update.sh"
install -m 600 "$overlay" "$state_dir/docker-compose.vf-ego.yml"

pending="$(mktemp "$agent_dir/$label.XXXXXX.plist")"
trap 'rm -f "$pending"' EXIT
plutil -create xml1 "$pending"
plutil -insert Label -string "$label" "$pending"
plutil -insert ProgramArguments -array "$pending"
args=(/bin/bash "$state_dir/enable-auto-update.sh" --update "$docker_bin" "$context")
for i in "${!args[@]}"; do
    plutil -insert "ProgramArguments.$i" -string "${args[$i]}" "$pending"
done
plutil -insert StartCalendarInterval -dictionary "$pending"
plutil -insert StartCalendarInterval.Hour -integer "$((10#${time%:*}))" "$pending"
plutil -insert StartCalendarInterval.Minute -integer "$((10#${time#*:}))" "$pending"
plutil -insert StandardOutPath -string "$state_dir/update.log" "$pending"
plutil -insert StandardErrorPath -string "$state_dir/update.log" "$pending"
plutil -lint "$pending" >/dev/null

if launchctl print "$domain/$label" >/dev/null 2>&1; then
    launchctl bootout "$domain/$label"
fi
mv -f "$pending" "$plist"
launchctl bootstrap "$domain" "$plist"
printf 'CVAT VF auto-update enabled daily at %s. Log: %s/update.log\n' "$time" "$state_dir"
