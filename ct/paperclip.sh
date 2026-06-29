#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2026 community-scripts ORG
# Author: Fabian Pulch (fpulch)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/paperclipai/paperclip

APP="Paperclip"
var_tags="${var_tags:-ai;automation;dev-tools}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-8192}"
var_disk="${var_disk:-20}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_arm64="${var_arm64:-yes}"
var_unprivileged="${var_unprivileged:-1}"

# ---------------------------------------------------------------------------
# Path constants — kept in sync with install/paperclip-install.sh.
#
# PAPERCLIP_APP_DIR
#   FIX: was /opt/paperclip-ai (from fetch_and_deploy_gh_release "paperclip-ai").
#   The install script's fetch_and_deploy_gh_release first arg must be
#   "paperclip" → /opt/paperclip, matching what the app expects internally.
#   Both scripts must agree on this path or updates deploy to an orphan
#   directory that the running service never reads.
#
# PAPERCLIP_DATA_DIR
#   The install script intentionally separates code (/opt/paperclip) from
#   persistent state (/opt/paperclip-data). The original update_script never
#   referenced this directory at all — config.json, master.key, and instance
#   state were fully exposed to loss on every update.
# ---------------------------------------------------------------------------
PAPERCLIP_APP_DIR="/opt/paperclip"
PAPERCLIP_DATA_DIR="/opt/paperclip-data"
PAPERCLIP_INSTANCE_DIR="${PAPERCLIP_DATA_DIR}/instances/default"
PAPERCLIP_ENV="${PAPERCLIP_APP_DIR}/.env"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  # FIX: was /opt/paperclip-ai — install script uses /opt/paperclip.
  if [[ ! -d "${PAPERCLIP_APP_DIR}" ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  # FIX: first arg was "paperclip-ai" → deployed to /opt/paperclip-ai.
  # Must match install script: "paperclip" → /opt/paperclip.
  if check_for_gh_release "paperclip" "paperclipai/paperclip"; then

    msg_info "Stopping Service"
    systemctl stop paperclip
    msg_ok "Stopped Service"

    # -----------------------------------------------------------------------
    # FIX — Comprehensive backup replacing the original single `cp` line.
    #
    # Original: cp /opt/paperclip-ai/.env /opt/paperclip.env.bak
    # Three problems:
    #   1. Source path /opt/paperclip-ai/.env didn't match the install
    #      location — the file was not found and the copy silently failed
    #      or backed up nothing.
    #   2. /opt/paperclip-data was never referenced, so config.json and
    #      secrets/master.key had zero protection against update corruption.
    #   3. master.key encrypts every API key and credential stored in
    #      Paperclip. Loss is permanent. Official docs: "Back up
    #      secrets/master.key somewhere safe. If you lose it, you lose
    #      access to all of them."
    #
    # fetch_and_deploy_gh_release (CLEAN_INSTALL=1) only wipes
    # PAPERCLIP_APP_DIR (/opt/paperclip). PAPERCLIP_DATA_DIR survives.
    # We snapshot both so a failed update can be fully rolled back.
    # -----------------------------------------------------------------------
    msg_info "Backing up Configuration"
    BACKUP_DIR="/opt/paperclip-backup-$(date +%Y%m%d%H%M%S)"
    mkdir -p "${BACKUP_DIR}"
    chmod 700 "${BACKUP_DIR}"

    [[ -f "${PAPERCLIP_ENV}" ]] \
      && cp "${PAPERCLIP_ENV}" "${BACKUP_DIR}/app.env.bak" \
      && chmod 600 "${BACKUP_DIR}/app.env.bak"

    if [[ -d "${PAPERCLIP_DATA_DIR}" ]]; then
      cp -a "${PAPERCLIP_DATA_DIR}" "${BACKUP_DIR}/paperclip-data.bak"
      chmod -R 600 "${BACKUP_DIR}/paperclip-data.bak"
      find "${BACKUP_DIR}/paperclip-data.bak" -type d -exec chmod 700 {} +
    else
      msg_error "Data directory not found at ${PAPERCLIP_DATA_DIR}"
      msg_error "Aborting — cannot proceed without a verifiable backup."
      exit 1
    fi
    msg_ok "Backed up Configuration → ${BACKUP_DIR}"

    # FIX: first arg was "paperclip-ai". Corrected to "paperclip".
    CLEAN_INSTALL=1 fetch_and_deploy_gh_release "paperclip" "paperclipai/paperclip" "tarball"

    msg_info "Restoring App-Level Configuration"
    [[ -f "${BACKUP_DIR}/app.env.bak" ]] \
      && mv "${BACKUP_DIR}/app.env.bak" "${PAPERCLIP_ENV}" \
      && chmod 600 "${PAPERCLIP_ENV}"
    msg_ok "Restored App-Level Configuration"

    msg_info "Rebuilding Paperclip"
    cd "${PAPERCLIP_APP_DIR}"
    export HUSKY=0
    # FIX: was --max-old-space-size=8192 (100% of 8 GB container RAM).
    # PostgreSQL 17 runs concurrently. Allocating all RAM to the Node heap
    # OOM-kills either the build (corrupted output) or Postgres (data risk).
    # 4096 MB (~50%) leaves safe headroom.
    export NODE_OPTIONS="--max-old-space-size=4096"
    $STD pnpm install --frozen-lockfile
    $STD pnpm build
    unset NODE_OPTIONS
    msg_ok "Rebuilt Paperclip"

    # Agent CLIs are installed with npm -g (not pnpm add --global) because
    # they must be accessible to the 'paperclip' service user at runtime.
    # pnpm global installs go to a user-specific store under the installer's
    # home; npm -g shims land in /usr/local/bin which is in every user's PATH.
    # See install script comments for full rationale.
    msg_info "Updating Agent CLIs"
    $STD npm install -g \
      @anthropic-ai/claude-code@latest \
      @openai/codex@latest
    msg_ok "Updated Agent CLIs"

    msg_info "Running Database Migrations"
    # FIX: was `set -a && source /opt/paperclip-ai/.env && set +a` (wrong path)
    # and ran as root. Run as paperclip service user for ownership consistency;
    # TCP-connected external PostgreSQL is not affected by the caller's UID.
    set -a && source "${PAPERCLIP_ENV}" && set +a
    sudo -u paperclip bash -c "
      set -a && source '${PAPERCLIP_ENV}' && set +a
      cd '${PAPERCLIP_APP_DIR}' && pnpm db:migrate
    "
    msg_ok "Ran Database Migrations"

    # Restore ownership after CLEAN_INSTALL + pnpm operations which run as
    # root and may have created root-owned files in the app directory.
    chown -R paperclip:paperclip "${PAPERCLIP_APP_DIR}"

    # Validate configuration before restarting to catch schema errors (e.g.
    # missing PAPERCLIP_PUBLIC_URL) before the service enters a crash loop.
    msg_info "Validating Configuration"
    if sudo -u paperclip bash -c "
        set -a && source '${PAPERCLIP_ENV}' && set +a
        cd '${PAPERCLIP_APP_DIR}' && npx paperclipai doctor
      "; then
      msg_ok "Configuration Valid"
    else
      msg_error "paperclipai doctor reported errors — service NOT started."
      echo -e "  Repair: sudo -u paperclip bash"
      echo -e "          set -a; source ${PAPERCLIP_ENV}; set +a"
      echo -e "          cd ${PAPERCLIP_APP_DIR}"
      echo -e "          npx paperclipai configure --section server"
      echo -e "          npx paperclipai doctor --repair"
      echo -e "  Then:   systemctl start paperclip"
      exit 1
    fi

    msg_info "Starting Service"
    systemctl start paperclip
    msg_ok "Started Service"

    msg_ok "Updated Successfully"
    echo -e "${INFO}${YW} Backup retained at ${BACKUP_DIR} — remove manually once satisfied.${CL}"
  fi
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:3100${CL}"
echo -e ""
echo -e "${INFO}${YW} To add a hostname or update the public URL after install:${CL}"
echo -e "${TAB}  sudo -u paperclip bash"
echo -e "${TAB}  set -a; source ${PAPERCLIP_ENV}; set +a"
echo -e "${TAB}  cd ${PAPERCLIP_APP_DIR}"
echo -e "${TAB}  pnpm paperclipai allowed-hostname <your-hostname>"
echo -e "${TAB}  # Edit PAPERCLIP_PUBLIC_URL in ${PAPERCLIP_ENV}, then:"
echo -e "${TAB}  systemctl restart paperclip"
echo -e ""
echo -e "${INFO}${YW} If no invite URL was printed above, generate one manually:${CL}"
echo -e "${TAB}  sudo -u paperclip bash"
echo -e "${TAB}  set -a; source ${PAPERCLIP_ENV}; set +a"
echo -e "${TAB}  cd ${PAPERCLIP_APP_DIR}"
echo -e "${TAB}  pnpm paperclipai auth bootstrap-ceo --force"
echo -e ""
echo -e "${INFO}${YW} Back up your master key — loss is permanent:${CL}"
echo -e "${TAB}  ${PAPERCLIP_INSTANCE_DIR}/secrets/master.key"
