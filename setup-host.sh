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

# ─── Logging ──────────────────────────────────────────────────────────────────
_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log() {
    local plain="[INFO]  $(_ts)  $*"
    printf '%s%s%s\n' "$C_GREEN" "$plain" "$C_RESET"
    printf '%s\n' "$plain" >> "$LOGFILE"
}

warn() {
    local plain="[WARN]  $(_ts)  $*"
    printf '%s%s%s\n' "$C_YELLOW" "$plain" "$C_RESET" >&2
    printf '%s\n' "$plain" >> "$LOGFILE"
}

error() {
    local plain="[ERROR] $(_ts)  $*"
    printf '%s%s%s\n' "$C_RED" "$plain" "$C_RESET" >&2
    printf '%s\n' "$plain" >> "$LOGFILE"
}

section() {
    local title="  $*"
    local sep="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    # Terminal: bold cyan separator
    printf '\n%s%s%s\n%s\n%s%s%s\n\n' \
        "$C_BOLD$C_CYAN" "$sep" "$C_RESET" \
        "$title" \
        "$C_BOLD$C_CYAN" "$sep" "$C_RESET"
    # Log file: plain text
    printf '\n%s\n%s\n%s\n\n' "$sep" "$title" "$sep" >> "$LOGFILE"
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
    section "$name"

    if [[ "$DRY_RUN" == "1" ]]; then
        log "${C_DIM}[DRY-RUN] would execute: $func${C_RESET}"
        _RESULTS["$name"]="SKIPPED"
        return 0
    fi

    log "▶ Starting: $name"
    if "$func"; then
        if [[ "$_STEP_STATUS" == "skip" ]]; then
            _RESULTS["$name"]="SKIPPED"
            log "⏭ Skipped:   $name"
        else
            _RESULTS["$name"]="SUCCEEDED"
            log "✓ Succeeded: $name"
        fi
    else
        _RESULTS["$name"]="FAILED"
        error "✗ Failed:    $name"
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

# Whiptail-based checklist
_selector_whiptail() {
    local args=()
    local id label default
    for entry in "${MODULES[@]}"; do
        IFS='|' read -r id label default <<< "$entry"
        args+=("$id" "$label" "$default")
    done

    local result
    result=$(whiptail \
        --title "Personal Linux Setup — Module Selector" \
        --checklist \
        "Use SPACE to toggle. ENTER to confirm. TAB to switch buttons.\nSelected modules will be installed." \
        30 72 18 \
        "${args[@]}" \
        3>&1 1>&2 2>&3) || {
        printf '\n%sSetup cancelled.%s\n' "$C_YELLOW" "$C_RESET"
        exit 0
    }

    # Parse whiptail output: space-separated quoted tokens → strip quotes
    local cleaned="${result//\"/}"
    local item
    for item in $cleaned; do
        [[ -n "$item" ]] && ENABLED["$item"]=1
    done
}

# Simple read-based fallback for environments without whiptail
_selector_simple() {
    printf '\n%s%s%s\n' "$C_BOLD" "Personal Linux Setup — Module Selector" "$C_RESET"
    printf '%s(Enter y/n for each module. Press ENTER for the default shown in brackets.)%s\n\n' \
        "$C_DIM" "$C_RESET"

    local id label default answer
    for entry in "${MODULES[@]}"; do
        IFS='|' read -r id label default <<< "$entry"
        local prompt_default="y/N"
        [[ "$default" == "ON" ]] && prompt_default="Y/n"
        printf '  %-16s %s [%s]: ' "$id" "$label" "$prompt_default"
        read -r answer
        answer="${answer:-$default}"
        case "${answer^^}" in
            Y|YES|ON)  ENABLED["$id"]=1 ;;
            *)         : ;;  # not enabled
        esac
    done
    printf '\n'
}

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

    # Ensure whiptail is available (install silently if missing)
    if ! command_exists whiptail; then
        printf '%sInstalling whiptail for the module selector...%s\n' "$C_DIM" "$C_RESET"
        sudo apt-get update -qq >> "$LOGFILE" 2>&1 \
            && sudo apt-get install -y -qq whiptail >> "$LOGFILE" 2>&1 \
            || true  # non-fatal: falls back to simple selector below
    fi

    if command_exists whiptail; then
        _selector_whiptail
    else
        warn "whiptail unavailable — using simple text selector."
        _selector_simple
    fi

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
    local packages=("${PKGS_BASE[@]}" "${PKGS_HOST_EXTRA[@]}")
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
    local plugin_file="${plugin_dir}/runfile"
    mkdir -p "$plugin_dir"
    log "Writing nnn runfile plugin to $plugin_file..."
    get_nnn_plugin_content > "$plugin_file"
    chmod +x "$plugin_file"
    log "nnn runfile plugin installed."
}

step_bashrc_blocks() {
    # Block 1: core aliases and NNN_PLUG (only if bashrc-core is enabled)
    if is_enabled "bashrc-core"; then
        local core_content='alias refresh="source ~/.bashrc"'
        is_enabled "nnn-plugin" && core_content+=$'\nexport NNN_PLUG="r:runfile"'
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

# Add the OpenFOAM Foundation repo if packages aren't in current sources
_openfoam_add_repo() {
    log "OpenFOAM packages not found in apt sources. Attempting to add repo..."

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

    log "Adding OpenFOAM Foundation repo for Ubuntu $codename..."

    curl -fsSL https://dl.openfoam.org/gpg.key \
        | sudo gpg --dearmor -o /usr/share/keyrings/openfoam.gpg >> "$LOGFILE" 2>&1 \
        || { warn "Failed to add OpenFOAM GPG key."; return 1; }

    printf 'deb [signed-by=/usr/share/keyrings/openfoam.gpg] https://dl.openfoam.org/ubuntu %s main\n' "$codename" \
        | sudo tee /etc/apt/sources.list.d/openfoam.list >> "$LOGFILE" \
        || { warn "Failed to write OpenFOAM apt source."; return 1; }

    sudo apt-get update -y >> "$LOGFILE" 2>&1 \
        || { warn "apt-get update failed after adding OpenFOAM repo."; return 1; }

    log "OpenFOAM repo added."
}

step_openfoam() {
    if pkg_installed openfoam13 || pkg_installed openfoam12; then
        skip_step "OpenFOAM already installed"
        return 0
    fi

    # If neither version is in apt cache, try adding the repo first
    if ! apt-cache show openfoam13 &>/dev/null 2>&1 \
    && ! apt-cache show openfoam12 &>/dev/null 2>&1; then
        _openfoam_add_repo || warn "Could not add OpenFOAM repo automatically."
    fi

    local of_installed=false
    for version in openfoam13 openfoam12; do
        log "Trying to install $version..."
        if sudo apt-get install -y "$version" >> "$LOGFILE" 2>&1; then
            log "$version installed successfully."
            of_installed=true
            break
        else
            warn "$version not available."
        fi
    done

    if ! $of_installed; then
        warn "Could not install OpenFOAM 12 or 13."
        add_followup "OpenFOAM install failed. See: https://openfoam.org/download/linux/"
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

step_claude_code() {
    if command_exists claude; then
        skip_step "Claude Code already installed: $(claude --version 2>/dev/null || true)"
        return 0
    fi

    if ! command_exists npm; then
        error "npm not found — cannot install Claude Code. Install Node.js/npm first."
        add_followup "Install Claude Code after npm is available: npm install -g @anthropic-ai/claude-code"
        return 1
    fi

    log "Installing Claude Code CLI via npm..."
    npm install -g @anthropic-ai/claude-code >> "$LOGFILE" 2>&1 \
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
    is_enabled "openfoam"        && run_step "OpenFOAM"                  step_openfoam
    is_enabled "paraview"        && run_step "ParaView"                  step_paraview
    is_enabled "freecad"         && run_step "FreeCAD"                   step_freecad
    is_enabled "claude-code"     && run_step "Claude Code"               step_claude_code

    print_summary
}

main "$@"
