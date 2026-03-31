#!/usr/bin/env bash
# dm.sh — fzf-based Docker image & container manager.
#
# Usage:
#   bash dm.sh

set -uo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]] && command -v tput &>/dev/null && tput colors &>/dev/null; then
    C_GREEN=$(tput setaf 2); C_YELLOW=$(tput setaf 3); C_CYAN=$(tput setaf 6)
    C_BOLD=$(tput bold); C_RESET=$(tput sgr0)
else
    C_GREEN="" C_YELLOW="" C_CYAN="" C_BOLD="" C_RESET=""
fi

log()  { printf '%s[INFO]  %s%s\n' "$C_GREEN"  "$*" "$C_RESET"; }
warn() { printf '%s[WARN]  %s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }

# ─── Helpers ──────────────────────────────────────────────────────────────────
require_fzf() {
    command -v fzf &>/dev/null || { warn "fzf is required but not installed."; exit 1; }
}

pick_image() {
    docker images --format '{{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}' \
        | column -t -s $'\t' \
        | fzf --prompt="Image > " --header="Select an image" --height=50% --reverse --border
}

pick_container() {
    local filter="${1:-}"
    docker ps ${filter} --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.ID}}' \
        | column -t -s $'\t' \
        | fzf --prompt="Container > " --header="Select a container" --height=50% --reverse --border
}

container_name() { awk '{print $1}' <<< "$1"; }
image_name()     { awk '{print $1}' <<< "$1"; }

# ─── Actions ──────────────────────────────────────────────────────────────────
run_image() {
    local img_line; img_line=$(pick_image) || return
    local img; img=$(image_name "$img_line")
    [[ -z "$img" ]] && return

    printf '%sContainer name (blank = auto): %s' "$C_BOLD" "$C_RESET"
    local cname; read -r cname

    local mode_choice
    mode_choice=$(printf "enter now — open interactive shell\nstart in background — keep running, attach later" \
        | fzf --prompt="Mode > " --height=15% --reverse --border)
    [[ -z "$mode_choice" ]] && return

    local run_args=(--init)
    [[ -n "$cname" ]] && run_args+=(--name "$cname")
    [[ "$mode_choice" == enter* ]] && run_args+=(-it) || run_args+=(-dit)

    local rm_choice
    rm_choice=$(printf "no  — keep container when stopped\nyes — remove when stopped (--rm)" \
        | fzf --prompt="Remove when stopped? > " --height=15% --reverse --border)
    [[ -z "$rm_choice" ]] && return
    [[ "$rm_choice" == yes* ]] && run_args+=(--rm)

    local net_choice
    net_choice=$(printf "no\nyes — host network (--network=host)" \
        | fzf --prompt="Host network? > " --height=15% --reverse --border)
    [[ -z "$net_choice" ]] && return
    [[ "$net_choice" == yes* ]] && run_args+=(--network=host)

    log "Running: docker run ${run_args[*]} $img"
    if [[ "$mode_choice" == enter* ]]; then
        docker run "${run_args[@]}" "$img"
    else
        local cid; cid=$(docker run "${run_args[@]}" "$img")
        log "Container started: ${cid:0:12}"
        log "Use 'manage containers → attach' to enter it."
    fi
}

manage_containers() {
    local choice
    choice=$(printf "attach (running)\nstart (stopped)\nstop (running)\nrestart\nremove\nlogs\nexec shell" \
        | fzf --prompt="Container action > " --height=40% --reverse --border)
    [[ -z "$choice" ]] && return

    local row name
    case "$choice" in
        attach*)
            row=$(pick_container "-a --filter status=running") || return
            name=$(container_name "$row")
            [[ -z "$name" ]] && return
            log "Attaching to $name ..."
            docker attach "$name"
            ;;
        start*)
            row=$(pick_container "-a --filter status=exited") || return
            name=$(container_name "$row")
            [[ -z "$name" ]] && return
            docker start -ai "$name"
            ;;
        stop*)
            row=$(pick_container "-a --filter status=running") || return
            name=$(container_name "$row")
            [[ -z "$name" ]] && return
            log "Stopping $name ..."
            docker stop "$name"
            ;;
        restart*)
            row=$(pick_container "-a") || return
            name=$(container_name "$row")
            [[ -z "$name" ]] && return
            log "Restarting $name ..."
            docker restart "$name"
            ;;
        remove*)
            row=$(pick_container "-a") || return
            name=$(container_name "$row")
            [[ -z "$name" ]] && return
            printf '%sRemove container "%s"? [y/N]: %s' "$C_BOLD" "$name" "$C_RESET"
            local confirm; read -r confirm
            [[ "${confirm:-N}" =~ ^[Yy] ]] || return
            docker rm -f "$name"
            log "Removed $name."
            ;;
        logs*)
            row=$(pick_container "-a") || return
            name=$(container_name "$row")
            [[ -z "$name" ]] && return
            docker logs --tail 100 -f "$name"
            ;;
        "exec shell"*)
            row=$(pick_container "-a --filter status=running") || return
            name=$(container_name "$row")
            [[ -z "$name" ]] && return
            log "Opening shell in $name ..."
            docker exec -it "$name" /bin/bash
            ;;
    esac
}

remove_image() {
    local img_line; img_line=$(pick_image) || return
    local img; img=$(image_name "$img_line")
    [[ -z "$img" ]] && return
    printf '%sRemove image "%s"? [y/N]: %s' "$C_BOLD" "$img" "$C_RESET"
    local confirm; read -r confirm
    [[ "${confirm:-N}" =~ ^[Yy] ]] || return
    docker rmi "$img"
    log "Removed $img."
}

prune_menu() {
    local choice
    choice=$(printf "stopped containers\ndangling images\nboth" \
        | fzf --prompt="Prune > " --height=20% --reverse --border)
    [[ -z "$choice" ]] && return
    case "$choice" in
        stopped*)  docker container prune -f ;;
        dangling*) docker image prune -f ;;
        both*)     docker container prune -f && docker image prune -f ;;
    esac
}

# ─── Main loop ────────────────────────────────────────────────────────────────
main() {
    if ! command -v docker &>/dev/null; then
        warn "Docker is not installed."
        exit 1
    fi
    require_fzf

    while true; do
        local action
        action=$(printf "build new image\nrun image\nmanage containers\nremove image\nprune\nquit" \
            | fzf --prompt="Docker > " --header="${C_BOLD}dm — Docker Manager${C_RESET}" \
                  --height=40% --reverse --border)
        case "$action" in
            "build new image")   bash "$(dirname "${BASH_SOURCE[0]}")/setup-docker.sh" ;;
            "run image")         run_image ;;
            "manage containers") manage_containers ;;
            "remove image")      remove_image ;;
            prune)               prune_menu ;;
            quit|"")             break ;;
        esac
    done
}

main "$@"
