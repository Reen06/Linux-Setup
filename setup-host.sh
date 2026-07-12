#!/usr/bin/env bash
# setup.sh — Personal Linux/Docker environment installer
#
# Features:
#   - Interactive module selector (whiptail TUI, simple fallback if unavailable)
#   - Keeps running even when one step fails
#   - Per-step success/failure/skip tracking
#   - Color-coded terminal output; plain-text log file
#   - Timestamped logging to terminal + ~/setup-install.log
#   - Idempotent: safe to re-run multiple times
#   - Managed .bashrc blocks (replaced cleanly on re-run)
#   - Summary report printed at end + saved to ~/setup-summary.log
#   - ARM/x86 Miniconda auto-detection
#   - OpenFOAM repo auto-setup
#   - Dry-run mode: DRY_RUN=1 bash setup.sh
#
# Usage:
#   bash setup.sh               # interactive module selector
#   bash setup.sh --all         # enable all modules, skip selector
#   bash setup.sh --dry-run     # show what would run, don't change anything
#   bash setup.sh --all --dry-run

set -uo pipefail

# ─── Config (edit these if needed) ────────────────────────────────────────────
LOGFILE="${HOME}/setup-install.log"
SUMMARYFILE="${HOME}/setup-summary.log"
BASHRC="${HOME}/.bashrc"

# Load shared module definitions, package lists, and content generators
# shellcheck source=programs.conf
source "$(dirname "${BASH_SOURCE[0]}")/programs.conf"

# ─── Flags (set by CLI args or environment) ───────────────────────────────────
DRY_RUN=0
SELECT_ALL=0

for _arg in "$@"; do
    case "$_arg" in
        --dry-run)  DRY_RUN=1 ;;
        --all)      SELECT_ALL=1 ;;
        --help|-h)
            grep '^# ' "$0" | head -20 | sed 's/^# //'
            exit 0 ;;
    esac
done

# ─── Colors (terminal only; never written to log file) ────────────────────────
if [[ -t 1 ]] && command -v tput &>/dev/null && tput colors &>/dev/null; then
    C_RED=$(tput setaf 1)
    C_GREEN=$(tput setaf 2)
    C_YELLOW=$(tput setaf 3)
    C_CYAN=$(tput setaf 6)
    C_BOLD=$(tput bold)
    C_DIM=$(tput dim)
    C_RESET=$(tput sgr0)
else
    C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_BOLD="" C_DIM="" C_RESET=""
fi

# ─── State ────────────────────────────────────────────────────────────────────
declare -A _RESULTS=()      # step name → SUCCEEDED | FAILED | SKIPPED
declare -a _STEP_ORDER=()   # step names in run order
declare -a _FOLLOWUPS=()    # manual follow-up messages
declare -A ENABLED=()       # module-id → 1 if selected
_STEP_STATUS=""             # set to "skip" inside a step function
_SPINNER_PID=""             # PID of background spinner process
_SPINNER_ACTIVE=0           # 1 while a step is running (suppresses log terminal output)
_STEP_START=0               # $SECONDS at step start (for elapsed time)

# ─── Logging ──────────────────────────────────────────────────────────────────
_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log() {
    local plain="[INFO]  $(_ts)  $*"
    [[ "$_SPINNER_ACTIVE" == "0" ]] && printf '%s%s%s\n' "$C_GREEN" "$plain" "$C_RESET"
    printf '%s\n' "$plain" >> "$LOGFILE"
}

warn() {
    local plain="[WARN]  $(_ts)  $*"
    [[ "$_SPINNER_ACTIVE" == "0" ]] && printf '%s%s%s\n' "$C_YELLOW" "$plain" "$C_RESET" >&2
    printf '%s\n' "$plain" >> "$LOGFILE"
}

error() {
    local plain="[ERROR] $(_ts)  $*"
    [[ "$_SPINNER_ACTIVE" == "0" ]] && printf '%s%s%s\n' "$C_RED" "$plain" "$C_RESET" >&2
    printf '%s\n' "$plain" >> "$LOGFILE"
}

section() {
    local title="  $*"
    local sep="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    [[ "$_SPINNER_ACTIVE" == "0" ]] && printf '\n%s%s%s\n%s\n%s%s%s\n\n' \
        "$C_BOLD$C_CYAN" "$sep" "$C_RESET" \
        "$title" \
        "$C_BOLD$C_CYAN" "$sep" "$C_RESET"
    printf '\n%s\n%s\n%s\n\n' "$sep" "$title" "$sep" >> "$LOGFILE"
}

# ─── Spinner ──────────────────────────────────────────────────────────────────
_start_spinner() {
    local _label="$1"
    _SPINNER_ACTIVE=1
    _STEP_START=$SECONDS
    local _log="$LOGFILE" _cyan="$C_CYAN" _reset="$C_RESET"
    (
        local _f=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) _i=0
        while true; do
            local _last
            _last=$(tail -1 "$_log" 2>/dev/null \
                | sed 's/^\[[A-Z]*\][[:space:]]*[0-9-]* [0-9:]*[[:space:]]*//' \
                | cut -c1-50)
            printf '\r  %s%s%s  %-36s  \033[2m%s\033[0m\033[K' \
                "$_cyan" "${_f[$_i]}" "$_reset" "$_label" "$_last"
            _i=$(( (_i+1) % 10 ))
            sleep 0.1
        done
    ) &
    _SPINNER_PID=$!
}

_stop_spinner() {
    [[ -z "$_SPINNER_PID" ]] && return
    kill "$_SPINNER_PID" 2>/dev/null
    wait "$_SPINNER_PID" 2>/dev/null
    _SPINNER_PID=""
    _SPINNER_ACTIVE=0
    printf '\r\033[K'
}

# Print one line to both terminal (with optional color) and log file (plain).
_both() {
    local color="$1"; shift
    local text="$*"
    printf '%s%s%s\n' "$color" "$text" "$C_RESET"
    printf '%s\n' "$text" >> "$LOGFILE"
}

# ─── Tracking ─────────────────────────────────────────────────────────────────
add_followup() { _FOLLOWUPS+=("$*"); }

skip_step() {
    log "Skipping: $*"
    _STEP_STATUS="skip"
}

is_enabled() { [[ "${ENABLED[${1}]:-0}" == "1" ]]; }

# ─── Step Runner ──────────────────────────────────────────────────────────────
run_step() {
    local name="$1"
    local func="$2"
    _STEP_STATUS=""
    _STEP_ORDER+=("$name")

    if [[ "$DRY_RUN" == "1" ]]; then
        printf '  \033[2m–  %s  (dry-run)\033[0m\n' "$name"
        printf '[DRY-RUN] %s\n' "$name" >> "$LOGFILE"
        _RESULTS["$name"]="SKIPPED"
        return 0
    fi

    # Suppress terminal output from log/warn/error while spinner is running
    _SPINNER_ACTIVE=1
    section "$name"
    printf '[INFO]  %s  ▶ Starting: %s\n' "$(_ts)" "$name" >> "$LOGFILE"
    _start_spinner "$name"

    if "$func"; then
        _stop_spinner
        if [[ "$_STEP_STATUS" == "skip" ]]; then
            _RESULTS["$name"]="SKIPPED"
            printf '[INFO]  %s  ⏭ Skipped: %s\n' "$(_ts)" "$name" >> "$LOGFILE"
            printf '  %s⏭%s  %-36s  \033[2m(already done)\033[0m\n' \
                "$C_DIM" "$C_RESET" "$name"
        else
            local _elapsed=$(( SECONDS - _STEP_START ))
            _RESULTS["$name"]="SUCCEEDED"
            printf '[INFO]  %s  ✓ Succeeded: %s\n' "$(_ts)" "$name" >> "$LOGFILE"
            printf '  %s✓%s  %-36s  \033[2m(%ds)\033[0m\n' \
                "$C_GREEN" "$C_RESET" "$name" "$_elapsed"
        fi
    else
        _stop_spinner
        _RESULTS["$name"]="FAILED"
        printf '[ERROR] %s  ✗ Failed: %s\n' "$(_ts)" "$name" >> "$LOGFILE"
        printf '  %s✗%s  %-36s  \033[2msee %s\033[0m\n' \
            "$C_RED" "$C_RESET" "$name" "$LOGFILE"
    fi
}

# ─── Utilities ────────────────────────────────────────────────────────────────
command_exists() { command -v "$1" &>/dev/null; }

pkg_installed() { dpkg -l "$1" 2>/dev/null | grep -q '^ii'; }

systemd_available() {
    command_exists systemctl \
        && [[ -d /run/systemd/system ]] \
        && systemctl status &>/dev/null
}

install_apt_pkg() {
    local pkg="$1"
    if pkg_installed "$pkg"; then
        log "Already installed: $pkg"
        return 0
    fi
    log "Installing: $pkg"
    if sudo apt-get install -y "$pkg" >> "$LOGFILE" 2>&1; then
        log "Installed:  $pkg"
        return 0
    else
        error "Failed to install: $pkg"
        return 1
    fi
}

# miniconda_url — defined in programs.conf

# append_managed_block <block-id> <content>
# Writes (or replaces) a clearly-marked block in $BASHRC.
# Markers:  # >>> block-id >>>  ...  # <<< block-id <<<
append_managed_block() {
    local block_id="$1"
    local content="$2"
    local open_marker="# >>> ${block_id} >>>"
    local close_marker="# <<< ${block_id} <<<"

    touch "$BASHRC"

    if grep -qF "$open_marker" "$BASHRC" 2>/dev/null; then
        log "Replacing managed block '${block_id}' in ${BASHRC}"
        local tmp
        tmp="$(mktemp)"
        local inside=0
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == "$open_marker" ]]; then
                inside=1
                printf '%s\n' "$open_marker"  >> "$tmp"
                printf '%s\n' "$content"      >> "$tmp"
                printf '%s\n' "$close_marker" >> "$tmp"
            elif [[ "$line" == "$close_marker" ]]; then
                inside=0
            elif [[ $inside -eq 0 ]]; then
                printf '%s\n' "$line" >> "$tmp"
            fi
        done < "$BASHRC"
        mv "$tmp" "$BASHRC"
    else
        log "Appending managed block '${block_id}' to ${BASHRC}"
        {
            printf '\n%s\n' "$open_marker"
            printf '%s\n'   "$content"
            printf '%s\n'   "$close_marker"
        } >> "$BASHRC"
    fi
}

# ─── Module Selector ──────────────────────────────────────────────────────────


show_module_selector() {
    # --all flag or non-interactive stdin: enable everything
    if [[ "$SELECT_ALL" == "1" ]]; then
        log "Flag --all: enabling all modules."
        local id label default
        for entry in "${MODULES[@]}"; do
            IFS='|' read -r id label default <<< "$entry"
            ENABLED["$id"]=1
        done
        return 0
    fi

    if [[ ! -t 0 ]]; then
        warn "Non-interactive stdin detected — enabling all modules."
        local id label default
        for entry in "${MODULES[@]}"; do
            IFS='|' read -r id label default <<< "$entry"
            ENABLED["$id"]=1
        done
        return 0
    fi

    run_selector "Personal Linux Setup — Module Selector"

    # Confirm selection
    printf '\n%s%sModules selected:%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
    local id label default
    for entry in "${MODULES[@]}"; do
        IFS='|' read -r id label default <<< "$entry"
        if is_enabled "$id"; then
            printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$label"
        else
            printf '  %s–%s %s %s(skipped)%s\n' "$C_DIM" "$C_RESET" "$label" "$C_DIM" "$C_RESET"
        fi
    done

    printf '\n%sProceed with installation? [Y/n]: %s' "$C_BOLD" "$C_RESET"
    local confirm
    read -r confirm
    case "${confirm:-Y}" in
        [Nn]*) printf 'Cancelled.\n'; exit 0 ;;
    esac
}

# ─── Step Functions ───────────────────────────────────────────────────────────

step_system_update() {
    log "Running apt-get update + upgrade..."
    sudo apt-get update  -y >> "$LOGFILE" 2>&1 || { error "apt-get update failed.";  return 1; }
    sudo apt-get upgrade -y >> "$LOGFILE" 2>&1 || { error "apt-get upgrade failed."; return 1; }
    log "System update complete."
}

step_base_packages() {
    local packages=()
    for pkg in "${PKGS_BASE[@]}"; do
        is_subitem_enabled "base-packages" "$pkg" && packages+=("$pkg")
    done
    packages+=("${PKGS_HOST_EXTRA[@]}")  # host-only extras always included
    local failed=()
    for pkg in "${packages[@]}"; do
        install_apt_pkg "$pkg" || failed+=("$pkg")
    done
    if [[ ${#failed[@]} -gt 0 ]]; then
        error "Failed to install: ${failed[*]}"
        add_followup "Manually install these base packages: ${failed[*]}"
        return 1
    fi
}

step_docker() {
    if command_exists docker; then
        log "Docker already installed: $(docker --version 2>/dev/null || true)"
    else
        log "Downloading Docker install script..."
        local tmp
        tmp="$(mktemp /tmp/get-docker-XXXXXX.sh)"
        if ! curl -fsSL https://get.docker.com -o "$tmp" 2>> "$LOGFILE"; then
            error "Failed to download Docker install script."
            rm -f "$tmp"; return 1
        fi
        log "Running Docker install script..."
        if ! sudo sh "$tmp" >> "$LOGFILE" 2>&1; then
            error "Docker install script failed."
            rm -f "$tmp"; return 1
        fi
        rm -f "$tmp"
        log "Docker installed."
    fi

    getent group docker &>/dev/null || sudo groupadd docker >> "$LOGFILE" 2>&1 || true

    if id -nG "$USER" | grep -qw docker; then
        log "User '$USER' is already in the docker group."
    else
        sudo usermod -aG docker "$USER" >> "$LOGFILE" 2>&1
        add_followup "Re-login or run 'newgrp docker' for docker group membership to take effect."
    fi

    if systemd_available; then
        sudo systemctl enable --now docker >> "$LOGFILE" 2>&1 \
            || warn "Could not enable/start docker service via systemd."
    else
        warn "systemd not available — Docker service not started automatically."
        add_followup "Start Docker manually: sudo dockerd &"
    fi
}

step_miniconda() {
    if [[ -d "${HOME}/miniconda3" ]]; then
        skip_step "Miniconda already installed at ~/miniconda3"
        return 0
    fi
    local url
    url="$(miniconda_url)"
    log "Downloading Miniconda from: $url"
    local tmp
    tmp="$(mktemp /tmp/miniconda-XXXXXX.sh)"
    wget -q "$url" -O "$tmp" >> "$LOGFILE" 2>&1 \
        || { error "Failed to download Miniconda."; rm -f "$tmp"; return 1; }
    log "Running Miniconda installer (this may take a minute)..."
    bash "$tmp" -b -p "${HOME}/miniconda3" >> "$LOGFILE" 2>&1 \
        || { error "Miniconda installer failed."; rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    log "Miniconda installed to ~/miniconda3."
}

step_conda_init() {
    local conda_bin="${HOME}/miniconda3/bin/conda"
    if [[ ! -x "$conda_bin" ]]; then
        error "conda not found at $conda_bin — was Miniconda installed?"
        return 1
    fi
    if grep -q '# >>> conda initialize >>>' "$BASHRC" 2>/dev/null; then
        skip_step "conda already initialized in ${BASHRC}"
        return 0
    fi
    log "Running conda init bash..."
    "$conda_bin" init bash >> "$LOGFILE" 2>&1 \
        || { error "conda init failed."; return 1; }
    log "conda init complete."
}

step_mamba() {
    local conda_sh="${HOME}/miniconda3/etc/profile.d/conda.sh"
    [[ -f "$conda_sh" ]] && source "$conda_sh"

    if [[ -x "${HOME}/miniconda3/bin/mamba" ]]; then
        skip_step "mamba already installed in base env"
        return 0
    fi

    if ! command_exists conda; then
        error "conda not available — cannot install mamba."
        return 1
    fi

    log "Installing mamba into base environment (this may take a minute)..."
    conda install -y mamba -n base -c conda-forge >> "$LOGFILE" 2>&1 \
        || { error "mamba installation failed."; return 1; }
    log "mamba installed."
}

step_nnn_plugin() {
    local plugin_dir="${HOME}/.config/nnn/plugins"
    mkdir -p "$plugin_dir"
    if is_subitem_enabled "nnn-plugin" "runfile"; then
        log "Writing nnn runfile plugin to ${plugin_dir}/runfile..."
        get_nnn_plugin_content > "${plugin_dir}/runfile"
        chmod +x "${plugin_dir}/runfile"
    fi
    if is_subitem_enabled "nnn-plugin" "runfile-exit"; then
        log "Writing nnn runfile-exit plugin to ${plugin_dir}/runfile-exit..."
        get_nnn_exit_plugin_content > "${plugin_dir}/runfile-exit"
        chmod +x "${plugin_dir}/runfile-exit"
    fi
    log "nnn plugins installed."
}

step_bashrc_blocks() {
    local script_dir
    script_dir="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"

    # Block 1: core aliases and NNN_PLUG (only if bashrc-core is enabled)
    if is_enabled "bashrc-core"; then
        local core_content='alias refresh="source ~/.bashrc"'
        if is_enabled "nnn-plugin"; then
            local _plug=""
            is_subitem_enabled "nnn-plugin" "runfile"      && _plug+="r:runfile;"
            is_subitem_enabled "nnn-plugin" "runfile-exit" && _plug+="R:runfile-exit;"
            _plug="${_plug%;}"
            [[ -n "$_plug" ]] && core_content+=$'\n'"export NNN_PLUG='$_plug'"
        fi
        is_enabled "docker" && core_content+=$'\n'"alias dm='bash $script_dir/dm.sh'"
        append_managed_block "personal-setup-core" "$core_content"
    fi

    # Block 2: manager functions — only if at least one manager is enabled
    if is_enabled "conda-manager" || is_enabled "mamba-manager"; then
        local managers_content=""

        is_enabled "conda-manager" && managers_content+=$(get_conda_manager_content)
        if is_enabled "mamba-manager"; then
            [[ -n "$managers_content" ]] && managers_content+=$'\n'
            managers_content+=$(get_mamba_manager_content)
        fi
        managers_content+=$'\n'
        managers_content+=$(get_cm_content)

        append_managed_block "personal-setup-managers" "$managers_content"
    fi

    log ".bashrc managed blocks written."
}

step_nvidia_toolkit() {
    if ! command_exists nvidia-smi; then
        skip_step "No NVIDIA GPU detected (nvidia-smi not found)"
        return 0
    fi

    log "NVIDIA GPU detected. Installing NVIDIA Container Toolkit..."
    local distribution
    distribution=$(. /etc/os-release; printf '%s%s' "$ID" "$VERSION_ID")
    log "Distribution: $distribution"

    log "Adding NVIDIA GPG key..."
    if ! curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | sudo gpg --dearmor \
            -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
            2>> "$LOGFILE"; then
        error "Failed to add NVIDIA GPG key."
        return 1
    fi

    log "Adding NVIDIA apt repository..."
    if ! curl -fsSL "https://nvidia.github.io/libnvidia-container/${distribution}/libnvidia-container.list" \
        2>> "$LOGFILE" \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >> "$LOGFILE"; then
        error "Failed to configure NVIDIA apt repository."
        return 1
    fi

    sudo apt-get update -y >> "$LOGFILE" 2>&1 \
        || { error "apt-get update failed after adding NVIDIA repo."; return 1; }

    install_apt_pkg nvidia-container-toolkit \
        || { error "Failed to install nvidia-container-toolkit."; return 1; }

    log "Configuring NVIDIA runtime for Docker..."
    sudo nvidia-ctk runtime configure --runtime=docker >> "$LOGFILE" 2>&1 \
        || { error "nvidia-ctk runtime configure failed."; return 1; }

    if systemd_available; then
        sudo systemctl restart docker >> "$LOGFILE" 2>&1 \
            || warn "Could not restart Docker after NVIDIA setup."
    else
        warn "systemd not available — Docker not restarted after NVIDIA setup."
        add_followup "Restart Docker after NVIDIA toolkit install: sudo service docker restart"
    fi

    log "NVIDIA Container Toolkit configured."
}

# Add the ESI/OpenCFD OpenFOAM repo if the package isn't in current sources
_openfoam_add_repo() {
    log "Adding ESI OpenFOAM repo for openfoam${OPENFOAM_VERSION}..."

    if ! command_exists lsb_release; then
        warn "lsb_release not available — cannot auto-detect Ubuntu codename for OpenFOAM repo."
        return 1
    fi
    local codename
    codename=$(lsb_release -cs 2>/dev/null)
    if [[ -z "$codename" ]]; then
        warn "Could not detect Ubuntu codename."
        return 1
    fi

    curl -fsSL https://dl.openfoam.com/pubkey.gpg \
        | sudo gpg --dearmor -o /usr/share/keyrings/openfoam.gpg >> "$LOGFILE" 2>&1 \
        || { warn "Failed to add OpenFOAM GPG key."; return 1; }

    printf 'deb [signed-by=/usr/share/keyrings/openfoam.gpg arch=amd64] https://dl.openfoam.com/ubuntu %s main\n' "$codename" \
        | sudo tee /etc/apt/sources.list.d/openfoam.list >> "$LOGFILE" \
        || { warn "Failed to write OpenFOAM apt source."; return 1; }

    sudo apt update -y >> "$LOGFILE" 2>&1 \
        || { warn "apt update failed after adding OpenFOAM repo."; return 1; }

    log "OpenFOAM repo added."
}

step_openfoam() {
    local pkg="openfoam${OPENFOAM_VERSION}"

    if pkg_installed "$pkg"; then
        skip_step "OpenFOAM $OPENFOAM_VERSION already installed"
        return 0
    fi

    if ! apt-cache show "$pkg" &>/dev/null 2>&1; then
        _openfoam_add_repo || warn "Could not add OpenFOAM repo automatically."
    fi

    log "Installing $pkg..."
    if sudo apt install -y "$pkg" >> "$LOGFILE" 2>&1; then
        log "$pkg installed successfully."
        local _of_bashrc="/usr/lib/openfoam/openfoam${OPENFOAM_VERSION}/etc/bashrc"
        if [[ -f "$_of_bashrc" ]]; then
            append_managed_block "openfoam-bashrc" "source $_of_bashrc"
            log "Added OpenFOAM bashrc source to ${BASHRC}."
        fi
    else
        warn "Could not install $pkg."
        add_followup "OpenFOAM install failed. See: https://openfoam.com/download/"
        return 1
    fi
}

step_paraview() {
    if pkg_installed paraview; then
        skip_step "ParaView already installed"
        return 0
    fi
    install_apt_pkg paraview \
        || { add_followup "Install ParaView manually: sudo apt install paraview"; return 1; }
}

step_freecad() {
    if pkg_installed freecad || command_exists freecad; then
        skip_step "FreeCAD already installed"
        return 0
    fi

    # Try snap first (usually more up to date), then apt
    if command_exists snap; then
        log "Installing FreeCAD via snap..."
        if sudo snap install freecad >> "$LOGFILE" 2>&1; then
            log "FreeCAD installed via snap."
            return 0
        else
            warn "snap install failed, trying apt..."
        fi
    fi

    log "Installing FreeCAD via apt..."
    install_apt_pkg freecad \
        || { add_followup "Install FreeCAD manually: https://www.freecad.org/downloads.php"; return 1; }
}

step_wifi_manager() {
    if ! command_exists nmcli; then
        log "nmcli not found — installing network-manager..."
        install_apt_pkg network-manager || { error "Failed to install network-manager."; return 1; }
    fi

    if [[ -d "${WIFI_MANAGER_DIR}/.git" ]]; then
        log "Updating existing wifi-manager checkout at ${WIFI_MANAGER_DIR}..."
        git -C "$WIFI_MANAGER_DIR" pull >> "$LOGFILE" 2>&1 \
            || { error "Failed to update wifi-manager repo."; return 1; }
    else
        log "Cloning wifi-manager from ${WIFI_MANAGER_REPO}..."
        git clone "$WIFI_MANAGER_REPO" "$WIFI_MANAGER_DIR" >> "$LOGFILE" 2>&1 \
            || { error "Failed to clone wifi-manager repo."; return 1; }
    fi

    log "Installing wifi-manager into PATH..."
    sudo bash "${WIFI_MANAGER_DIR}/install.sh" >> "$LOGFILE" 2>&1 \
        || { error "wifi-manager install.sh failed."; return 1; }

    log "wifi-manager installed. Run 'wifi-manager' from anywhere."
}

step_claude_code() {
    if command_exists claude; then
        skip_step "Claude Code already installed: $(claude --version 2>/dev/null || true)"
        return 0
    fi

    log "Installing Claude Code via install script..."
    curl -fsSL https://claude.ai/install.sh | bash >> "$LOGFILE" 2>&1 \
        || { error "Claude Code install failed."; return 1; }
    log "Claude Code installed: $(claude --version 2>/dev/null || true)"
}

# ─── Summary ──────────────────────────────────────────────────────────────────
print_summary() {
    local sep="══════════════════════════════════════════════════════════════"

    # Helper: prints to terminal with color AND appends plain to log + summary
    local _sumfile_content=""
    _sline() {
        local color="$1"; shift
        local text="$*"
        printf '%s%s%s\n' "$color" "$text" "$C_RESET"
        _sumfile_content+="$text"$'\n'
    }

    printf '\n'
    _sline "$C_BOLD$C_CYAN"  "$sep"
    _sline "$C_BOLD"         "  SETUP SUMMARY — $(_ts)"
    [[ "$DRY_RUN" == "1" ]] && _sline "$C_YELLOW" "  *** DRY-RUN MODE — no changes were made ***"
    _sline "$C_BOLD$C_CYAN"  "$sep"
    _sline ""                ""

    _sline "$C_BOLD$C_GREEN" "✅  SUCCEEDED"
    local any=false
    for name in "${_STEP_ORDER[@]}"; do
        [[ "${_RESULTS[$name]:-}" == "SUCCEEDED" ]] \
            && { _sline "$C_GREEN" "    • $name"; any=true; }
    done
    $any || _sline "" "    (none)"

    _sline "" ""
    _sline "$C_BOLD$C_RED"   "❌  FAILED"
    any=false
    for name in "${_STEP_ORDER[@]}"; do
        [[ "${_RESULTS[$name]:-}" == "FAILED" ]] \
            && { _sline "$C_RED" "    • $name"; any=true; }
    done
    $any || _sline "" "    (none)"

    _sline "" ""
    _sline "$C_BOLD$C_YELLOW" "⏭   SKIPPED"
    any=false
    for name in "${_STEP_ORDER[@]}"; do
        [[ "${_RESULTS[$name]:-}" == "SKIPPED" ]] \
            && { _sline "$C_DIM" "    • $name"; any=true; }
    done
    $any || _sline "" "    (none)"

    _sline "" ""
    _sline "$C_BOLD" "📋  MANUAL FOLLOW-UP"
    if [[ ${#_FOLLOWUPS[@]} -gt 0 ]]; then
        for msg in "${_FOLLOWUPS[@]}"; do
            _sline "$C_YELLOW" "    → $msg"
        done
    else
        _sline "" "    (none)"
    fi

    _sline "" ""
    _sline "$C_BOLD$C_CYAN" "$sep"
    _sline "$C_BOLD"        "  Next steps:"
    _sline ""               "  1. source ~/.bashrc"
    _sline ""               "  2. Re-login (or 'newgrp docker') for docker group changes."
    _sline "$C_BOLD$C_CYAN" "$sep"
    _sline ""               ""
    _sline "$C_DIM"         "  Full install log : $LOGFILE"
    _sline "$C_DIM"         "  This summary     : $SUMMARYFILE"
    _sline "" ""

    # Write plain text to both files
    printf '%s' "$_sumfile_content" >> "$LOGFILE"
    printf '%s' "$_sumfile_content" > "$SUMMARYFILE"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    # Initialize log file (overwrite each run)
    {
        printf '══════════════════════════════════════════════════════════════\n'
        printf '  Personal Linux Setup — %s\n' "$(_ts)"
        [[ "$DRY_RUN" == "1" ]] && printf '  *** DRY-RUN MODE ***\n'
        printf '══════════════════════════════════════════════════════════════\n\n'
    } > "$LOGFILE"

    log "Starting setup. Log: $LOGFILE"
    log "User: ${USER}  Host: $(uname -n)  Arch: $(uname -m)"

    # Merge shared + host-only modules, then show selector
    MODULES=("${SHARED_MODULES[@]}" "${HOST_ONLY_MODULES[@]}")
    show_module_selector

    log "Selected modules: ${!ENABLED[*]}"

    # Run selected steps (always run bashrc_blocks if any bashrc module is on)
    is_enabled "system-update"   && run_step "System Update"             step_system_update
    is_enabled "base-packages"   && run_step "Base Packages"             step_base_packages
    is_enabled "docker"          && run_step "Docker"                    step_docker
    is_enabled "miniconda"       && run_step "Miniconda"                 step_miniconda
    is_enabled "conda-init"      && run_step "Conda Init"                step_conda_init
    is_enabled "mamba"           && run_step "Mamba"                     step_mamba
    is_enabled "nnn-plugin"      && run_step "nnn Plugin"                step_nnn_plugin

    # .bashrc blocks run if any of its sub-modules are selected
    if is_enabled "bashrc-core" || is_enabled "conda-manager" || is_enabled "mamba-manager"; then
        run_step "Shell Config (.bashrc)" step_bashrc_blocks
    fi

    is_enabled "nvidia-toolkit"  && run_step "NVIDIA Container Toolkit"  step_nvidia_toolkit
    is_enabled "wifi-manager"    && run_step "Wi-Fi Manager"             step_wifi_manager
    is_enabled "openfoam"        && run_step "OpenFOAM"                  step_openfoam
    is_enabled "paraview"        && run_step "ParaView"                  step_paraview
    is_enabled "freecad"         && run_step "FreeCAD"                   step_freecad
    is_enabled "claude-code"     && run_step "Claude Code"               step_claude_code

    print_summary
}

main "$@"
