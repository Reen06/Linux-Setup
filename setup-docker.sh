#!/usr/bin/env bash
# setup-docker.sh — Build a personal Ubuntu Docker image from selected modules.
# Uses the same module list and package definitions as setup-host.sh.
#
# Usage:
#   bash setup-docker.sh                  # interactive selector
#   bash setup-docker.sh --all            # enable all modules
#   IMAGE_NAME=mydev bash setup-docker.sh # custom image name

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/programs.conf"

# ─── Config ───────────────────────────────────────────────────────────────────
IMAGE_NAME="${IMAGE_NAME:-my-dev-env}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
SELECT_ALL=0
for _arg in "$@"; do
    case "$_arg" in --all) SELECT_ALL=1 ;; esac
done

# ─── Colors ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]] && command -v tput &>/dev/null && tput colors &>/dev/null; then
    C_GREEN=$(tput setaf 2); C_YELLOW=$(tput setaf 3); C_CYAN=$(tput setaf 6)
    C_BOLD=$(tput bold); C_DIM=$(tput dim); C_RESET=$(tput sgr0)
else
    C_GREEN="" C_YELLOW="" C_CYAN="" C_BOLD="" C_DIM="" C_RESET=""
fi

# ─── State ────────────────────────────────────────────────────────────────────
declare -A ENABLED=()
MODULES=("${SHARED_MODULES[@]}" "${DOCKER_ONLY_MODULES[@]}")

# ─── Minimal logging ──────────────────────────────────────────────────────────
log()  { printf '%s[INFO]  %s%s\n' "$C_GREEN"  "$*" "$C_RESET"; }
warn() { printf '%s[WARN]  %s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }

is_enabled() { [[ "${ENABLED[${1}]:-0}" == "1" ]]; }

# ─── Module Selector ──────────────────────────────────────────────────────────
show_selector() {
    if [[ "$SELECT_ALL" == "1" ]] || [[ ! -t 0 ]]; then
        local id label default
        for entry in "${MODULES[@]}"; do
            IFS='|' read -r id label default <<< "$entry"
            ENABLED["$id"]=1
        done
        return 0
    fi

    run_selector "Docker Image Builder — Module Selector"

    printf '\n%s%sModules selected for image:%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
    local id label default
    for entry in "${MODULES[@]}"; do
        IFS='|' read -r id label default <<< "$entry"
        if is_enabled "$id"; then
            printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$label"
        else
            printf '  %s–%s %s %s(skipped)%s\n' "$C_DIM" "$C_RESET" "$label" "$C_DIM" "$C_RESET"
        fi
    done
    printf '\n%sImage name [%s]: %s' "$C_BOLD" "$IMAGE_NAME" "$C_RESET"
    local img_input; read -r img_input
    [[ -n "$img_input" ]] && IMAGE_NAME="$img_input"

    printf '%sBuild image "%s:%s"? [Y/n]: %s' "$C_BOLD" "$IMAGE_NAME" "$IMAGE_TAG" "$C_RESET"
    local confirm; read -r confirm
    [[ "${confirm:-Y}" =~ ^[Nn] ]] && { printf 'Cancelled.\n'; exit 0; }
}

# ─── Dockerfile Generator ─────────────────────────────────────────────────────
build_image() {
    local ctx
    ctx="$(mktemp -d /tmp/dev-image-XXXXXX)"
    trap 'rm -rf "$ctx"' EXIT
    mkdir -p "$ctx/resources"

    log "Generating build context in $ctx ..."
    local df="$ctx/Dockerfile"

    # Write prompt resource file (no escaping headaches this way)
    cat > "$ctx/resources/prompt.sh" << 'PSEOF'
# Purple colored prompt for the container root shell
PS1="\[\033[1;35m\]\u@\h:\w\$ \[\033[0m\]"
PSEOF

    {
        printf 'FROM %s\n' "$DOCKER_BASE_IMAGE"
        printf 'ENV DEBIAN_FRONTEND=noninteractive\n'
        printf 'ENV TERM=xterm-256color\n\n'

        # Always inject colored prompt — makes the container feel like home
        printf '# Purple bash prompt\n'
        printf 'COPY resources/prompt.sh /tmp/prompt.sh\n'
        printf 'RUN cat /tmp/prompt.sh >> /root/.bashrc && rm /tmp/prompt.sh\n\n'

        if is_enabled "system-update"; then
            printf '# System update\n'
            printf 'RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*\n\n'
        fi

        if is_enabled "base-packages"; then
            printf '# Base packages\n'
            printf 'RUN apt-get update && apt-get install -y \\\n'
            printf '    %s \\\n' "${PKGS_BASE[@]}"
            printf '    && rm -rf /var/lib/apt/lists/*\n\n'
        fi

        if is_enabled "miniconda"; then
            local url; url="$(miniconda_url)"
            printf '# Miniconda\n'
            printf 'RUN wget -q "%s" -O /tmp/mc.sh \\\n' "$url"
            printf '    && bash /tmp/mc.sh -b -p /opt/miniconda3 \\\n'
            printf '    && rm /tmp/mc.sh\n'
            printf 'ENV PATH="/opt/miniconda3/bin:${PATH}"\n\n'
        fi

        if is_enabled "conda-init"; then
            printf '# Conda init\n'
            printf 'RUN /opt/miniconda3/bin/conda init bash\n\n'
        fi

        if is_enabled "mamba"; then
            printf '# Mamba\n'
            printf 'RUN /opt/miniconda3/bin/conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main \\\n'
            printf '    && /opt/miniconda3/bin/conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r \\\n'
            printf '    && /opt/miniconda3/bin/conda install -y mamba -n base -c conda-forge\n\n'
        fi

        if is_enabled "nnn-plugin"; then
            get_nnn_plugin_content > "$ctx/resources/nnn-runfile"
            get_nnn_exit_plugin_content > "$ctx/resources/nnn-runfile-exit"
            chmod +x "$ctx/resources/nnn-runfile" "$ctx/resources/nnn-runfile-exit"
            printf '# nnn runfile plugins\n'
            printf 'RUN mkdir -p /root/.config/nnn/plugins\n'
            printf 'COPY resources/nnn-runfile /root/.config/nnn/plugins/runfile\n'
            printf 'COPY resources/nnn-runfile-exit /root/.config/nnn/plugins/runfile-exit\n'
            printf 'RUN chmod +x /root/.config/nnn/plugins/runfile /root/.config/nnn/plugins/runfile-exit\n\n'
        fi

        if is_enabled "bashrc-core"; then
            printf '# Shell aliases\n'
            printf 'RUN echo '"'"'alias refresh="source ~/.bashrc"'"'"' >> /root/.bashrc\n'
            # nnn wrapper: restores terminal state on exit (fixes cursor/display in containers)
            printf 'RUN echo '"'"'nnn() { command nnn "$@"; tput cnorm 2>/dev/null; stty sane 2>/dev/null; }'"'"' >> /root/.bashrc\n'
            is_enabled "nnn-plugin" && \
                printf 'RUN echo '"'"'export NNN_PLUG="r:runfile;R:runfile-exit"'"'"' >> /root/.bashrc\n'
            printf '\n'
        fi

        if is_enabled "conda-manager" || is_enabled "mamba-manager"; then
            local managers_content=""
            is_enabled "conda-manager" && managers_content+="$(get_conda_manager_content)"
            if is_enabled "mamba-manager"; then
                [[ -n "$managers_content" ]] && managers_content+=$'\n'
                managers_content+="$(get_mamba_manager_content)"
            fi
            managers_content+=$'\n'"$(get_cm_content)"
            printf '%s\n' "$managers_content" > "$ctx/resources/bashrc-managers"
            printf '# Conda/Mamba manager functions\n'
            printf 'COPY resources/bashrc-managers /tmp/managers.sh\n'
            printf 'RUN cat /tmp/managers.sh >> /root/.bashrc && rm /tmp/managers.sh\n\n'
        fi

        if is_enabled "openfoam"; then
            # Ubuntu 24.04 codename is "noble"; adjust if DOCKER_BASE_IMAGE changes
            local codename="noble"
            printf '# OpenFOAM %s (ESI/OpenCFD)\n' "$OPENFOAM_VERSION"
            printf 'RUN apt-get update \\\n'
            printf '    && apt-get install -y curl gpg \\\n'
            printf '    && curl -fsSL https://dl.openfoam.com/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/openfoam.gpg \\\n'
            printf '    && echo "deb [signed-by=/usr/share/keyrings/openfoam.gpg arch=amd64] https://dl.openfoam.com/ubuntu %s main" > /etc/apt/sources.list.d/openfoam.list \\\n' "$codename"
            printf '    && apt-get update \\\n'
            printf '    && apt-get install -y openfoam%s \\\n' "$OPENFOAM_VERSION"
            printf '    && rm -rf /var/lib/apt/lists/*\n\n'
        fi

        if is_enabled "paraview"; then
            printf '# ParaView\n'
            printf 'RUN apt-get update && apt-get install -y %s && rm -rf /var/lib/apt/lists/*\n\n' \
                "${PKGS_PARAVIEW[*]}"
        fi

        if is_enabled "freecad"; then
            printf '# FreeCAD\n'
            printf 'RUN apt-get update && apt-get install -y %s && rm -rf /var/lib/apt/lists/*\n\n' \
                "${PKGS_FREECAD[*]}"
        fi

        if is_enabled "claude-code"; then
            printf '# Claude Code CLI\n'
            printf 'RUN npm install -g @anthropic-ai/claude-code\n\n'
        fi

        printf 'WORKDIR /root\n'
        printf 'CMD ["/bin/bash"]\n'
    } > "$df"

    log "Dockerfile written. Building image ${IMAGE_NAME}:${IMAGE_TAG} ..."
    printf '%s\n' "────────────────────────────────────────────────────────"
    if docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" "$ctx"; then
        printf '%s\n\n' "────────────────────────────────────────────────────────"
        log "Image built: ${IMAGE_NAME}:${IMAGE_TAG}"
        printf '\n%sRun it now?%s  [Y/n]: ' "$C_BOLD" "$C_RESET"
        local ans; read -r ans
        if [[ ! "${ans:-Y}" =~ ^[Nn] ]]; then
            local run_args=(-it --rm)
            is_enabled "host-network" && run_args+=(--network=host)
            docker run "${run_args[@]}" "${IMAGE_NAME}:${IMAGE_TAG}"
        fi
    else
        warn "Docker build failed. Check output above."
        exit 1
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    if ! command -v docker &>/dev/null; then
        warn "Docker is not installed. Run setup-host.sh first."
        exit 1
    fi

    show_selector
    build_image
}

main "$@"
