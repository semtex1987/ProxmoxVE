#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Fabian Pulch (fpulch)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/paperclipai/paperclip

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt install -y \
  build-essential \
  git \
  ripgrep
msg_ok "Installed Dependencies"

NODE_VERSION="24" NODE_MODULE="pnpm" setup_nodejs
PG_VERSION="17" setup_postgresql
PG_DB_NAME="paperclip" PG_DB_USER="paperclip" setup_postgresql_db

# FIX #2 — was: fetch_and_deploy_gh_release "paperclip-ai" "paperclipai/paperclip" "tarball"
# The first argument is the /opt/ subdirectory name.
# "paperclip-ai" → /opt/paperclip-ai.
# Paperclip's internal path resolution and plugin system expect the workspace at
# /opt/paperclip. Using "paperclip-ai" causes any app-internal references that
# assume the conventional /opt/<appname> path to resolve to a non-existent
# location, breaking plugin installations and relative-path lookups.
fetch_and_deploy_gh_release "paperclip" "paperclipai/paperclip" "tarball"

msg_info "Building Paperclip"
cd /opt/paperclip
export HUSKY=0
# FIX #3 — was: --max-old-space-size=8192 (100% of 8 GB container RAM).
# PostgreSQL 17 is already running at this point. Allocating all available RAM
# to the Node.js heap leaves nothing for the OS, Postgres, or other processes.
# An OOM kill during the TypeScript compilation either corrupts the compiled
# output or kills the Postgres process (data corruption risk).
# 4096 MB (~50%) leaves safe headroom for all concurrent processes.
export NODE_OPTIONS="--max-old-space-size=4096"
$STD pnpm install --frozen-lockfile
$STD pnpm build
unset NODE_OPTIONS
msg_ok "Built Paperclip"

# FIX #1 — Create dedicated service user before touching any application files.
# Running Paperclip as root causes one confirmed hard failure:
#
#   @anthropic-ai/claude-code has an explicit root-execution guard:
#   it calls getuid() at startup and exits immediately when the result is 0.
#   This is a deliberate security check in the CLI binary that cannot be
#   bypassed via config, environment variables, or wrappers.
#   On a root service every single agent invocation exits before doing any work.
#
# The fix is a non-root service user that owns all Paperclip files and under
# whose identity the systemd unit runs.
#
# Note on embedded PostgreSQL: this install uses real external PostgreSQL 17
# (via setup_postgresql, which runs Postgres as the 'postgres' OS user through
# its own systemd unit). db:migrate connects over TCP with credentials, so the
# calling process's UID is irrelevant for database access. The Claude Code root
# failure is the only PostgreSQL-independent reason a service user is required.
msg_info "Creating Service User"
useradd --system --create-home --shell /bin/bash paperclip
msg_ok "Created Service User"

# FIX #4 — was: npm install -g
# Agent CLIs must be discoverable by the 'paperclip' service user at runtime,
# not just by root during install. pnpm add --global writes to a user-specific
# store (/root/.local/share/pnpm/) that the paperclip user cannot find.
# npm install -g writes shims to /usr/local/bin which is in every user's PATH,
# making the CLIs accessible system-wide regardless of who runs the service.
# For these two external tools specifically, npm -g is the correct tool.
#
# @anthropic-ai/claude-code — Paperclip's default agent harness (claude_local).
#   Requires a non-root service user (see FIX #1). Installs fine here as root;
#   the binary itself does the root check at execution time, not at install time.
#
# @openai/codex — Paperclip's codex_local adapter harness.
#   May have a similar root restriction depending on version.
#
# Neither is documented in the official server install guide but both are
# required for their respective adapters to function. Each also needs its own
# API key available in the agent's execution environment — Paperclip's Secrets
# UI stores keys in the DB but does NOT inject them into spawned subprocesses.
msg_info "Installing Agent CLIs"
$STD npm install -g \
  @anthropic-ai/claude-code@latest \
  @openai/codex@latest
msg_ok "Installed Agent CLIs"

msg_info "Configuring Paperclip"
PAPERCLIP_HOME="/opt/paperclip-data"
PAPERCLIP_CONFIG="${PAPERCLIP_HOME}/instances/default/config.json"

# FIX — was: mkdir -p /opt/paperclip-data only (no ownership fix).
# All Paperclip directories must be owned by the service user so the process
# can write config updates, plugin state, and instance files without permission
# errors at runtime.
mkdir -p /opt/paperclip-data
# FIX — was: mkdir -p /root/.claude /root/.codex
# Agent CLI config directories were created under root's home, which is
# inaccessible when the service runs as the 'paperclip' user. Create them
# under the service user's home so the CLI processes find their config.
mkdir -p /home/paperclip/.claude /home/paperclip/.codex
chown -R paperclip:paperclip \
  /opt/paperclip \
  /opt/paperclip-data \
  /home/paperclip/.claude \
  /home/paperclip/.codex

BETTER_AUTH_SECRET=$(openssl rand -hex 32)
# FIX — was: cat <<EOF >/opt/paperclip-ai/.env (wrong path)
# Path updated to match the corrected install location.
# chmod 600: the .env contains the database password, BETTER_AUTH_SECRET, and
# other credentials — it must not be world-readable.
cat <<EOF >/opt/paperclip/.env
DATABASE_URL=postgresql://${PG_DB_USER}:${PG_DB_PASS}@127.0.0.1:5432/${PG_DB_NAME}
HOST=0.0.0.0
PORT=3100
SERVE_UI=true
PAPERCLIP_HOME=${PAPERCLIP_HOME}
PAPERCLIP_CONFIG=${PAPERCLIP_CONFIG}
PAPERCLIP_INSTANCE_ID=default
PAPERCLIP_DEPLOYMENT_MODE=authenticated
PAPERCLIP_DEPLOYMENT_EXPOSURE=private
PAPERCLIP_PUBLIC_URL=http://${LOCAL_IP}:3100
BETTER_AUTH_SECRET=${BETTER_AUTH_SECRET}
EOF
chmod 600 /opt/paperclip/.env
chown paperclip:paperclip /opt/paperclip/.env
msg_ok "Configured Paperclip"

msg_info "Running Database Migrations"
# FIX — was: set -a && source /opt/paperclip-ai/.env && set +a
# Path updated to match corrected install location.
# Note: db:migrate connects to PostgreSQL over TCP with credentials from
# DATABASE_URL. The calling user's UID does not affect DB connectivity here.
# We still run as the service user for ownership consistency — any files
# the migration creates will be owned by paperclip, not root.
set -a && source /opt/paperclip/.env && set +a
sudo -u paperclip bash -c "
  set -a && source /opt/paperclip/.env && set +a
  cd /opt/paperclip && pnpm db:migrate
"
msg_ok "Ran Database Migrations"

msg_info "Bootstrapping Paperclip"
# FIX — was: /opt/paperclip-ai/paperclip-onboard.log (wrong path)
PAPERCLIP_ONBOARD_LOG=/opt/paperclip/paperclip-onboard.log
PAPERCLIP_BOOTSTRAP_LOG=/opt/paperclip/paperclip-bootstrap.log

for PAPERCLIP_ONBOARD_CMD in \
  "pnpm paperclipai onboard --yes --bind lan" \
  "pnpm paperclipai onboard --yes"; do
  rm -f "$PAPERCLIP_ONBOARD_LOG"
  # FIX — was: setsid env PAPERCLIP_HOME=... bash -c ... (ran as root)
  # Onboarding must run as the service user so config.json and master.key are
  # created with paperclip ownership. Root-owned instance files cannot be read
  # or written by the service at runtime, causing startup failures.
  # HOME is set explicitly because sudo -u in a non-login shell may not set it.
  setsid sudo -u paperclip env \
    HOME=/home/paperclip \
    PAPERCLIP_HOME="$PAPERCLIP_HOME" \
    PAPERCLIP_CONFIG="$PAPERCLIP_CONFIG" \
    bash -c 'cd /opt/paperclip && exec "$@"' _ $PAPERCLIP_ONBOARD_CMD \
    >"$PAPERCLIP_ONBOARD_LOG" 2>&1 &
  PAPERCLIP_ONBOARD_PID=$!
  # FIX — was: {1..60} (120s). Increased to {1..90} (180s) to accommodate
  # slower systems where the initial pnpm paperclipai first-run may take longer.
  for _ in {1..90}; do
    if [[ -f "$PAPERCLIP_CONFIG" ]]; then
      break
    fi
    if ! kill -0 "$PAPERCLIP_ONBOARD_PID" 2>/dev/null; then
      break
    fi
    sleep 2
  done
  if kill -0 "$PAPERCLIP_ONBOARD_PID" 2>/dev/null; then
    kill -- -"${PAPERCLIP_ONBOARD_PID}" >/dev/null 2>&1 || true
    wait "$PAPERCLIP_ONBOARD_PID" 2>/dev/null || true
  fi
  [[ -f "$PAPERCLIP_CONFIG" ]] && break
  if ! grep -q "unknown option '--bind'" "$PAPERCLIP_ONBOARD_LOG"; then
    break
  fi
  msg_info "Retrying Paperclip Onboarding"
done

if [[ ! -f "$PAPERCLIP_CONFIG" ]]; then
  msg_error "Failed to bootstrap Paperclip"
  # Surface the onboard log so the operator can diagnose without re-running
  cat "$PAPERCLIP_ONBOARD_LOG" 2>/dev/null || true
  exit 1
fi

# Ensure any files created by onboarding are owned by the service user.
# The setsid + sudo chain should handle this, but belt-and-suspenders for
# any edge case where the process wrote to paths owned by a different user.
chown -R paperclip:paperclip "${PAPERCLIP_HOME}" 2>/dev/null || true

if grep -q 'authenticated' "$PAPERCLIP_CONFIG"; then
  # FIX — was: pnpm paperclipai auth bootstrap-ceo (ran as root)
  # bootstrap-ceo writes the invite token to the database and generates a URL
  # anchored to PAPERCLIP_PUBLIC_URL from the loaded env. Running as root
  # would succeed (it's just a DB write), but for consistency and to ensure
  # HOME and env are correct for the service user, run as paperclip.
  sudo -u paperclip bash -c "
    set -a && source /opt/paperclip/.env && set +a
    cd /opt/paperclip && pnpm paperclipai auth bootstrap-ceo
  " >"$PAPERCLIP_BOOTSTRAP_LOG" 2>&1 || true
  PAPERCLIP_INVITE_URL=$(awk -F'Invite URL: ' '/Invite URL:/ {print $2; exit}' "$PAPERCLIP_BOOTSTRAP_LOG")
  PAPERCLIP_INVITE_EXPIRY=$(awk -F'Expires: ' '/Expires:/ {print $2; exit}' "$PAPERCLIP_BOOTSTRAP_LOG")
  if [[ -n "$PAPERCLIP_INVITE_URL" ]]; then
    cat <<EOF >>~/paperclip.creds

Paperclip Admin Invite
Invite URL: ${PAPERCLIP_INVITE_URL}
Expires: ${PAPERCLIP_INVITE_EXPIRY}
EOF
    msg_ok "Generated Paperclip CEO Invite"
    echo -e "${INFO}${YW} Open this invite URL to finish Paperclip admin setup:${CL}"
    echo -e "${TAB}${GATEWAY}${BGN}${PAPERCLIP_INVITE_URL}${CL}"
    [[ -n "$PAPERCLIP_INVITE_EXPIRY" ]] && echo -e "${TAB}${INFO}${YW}Invite expires: ${PAPERCLIP_INVITE_EXPIRY}${CL}"
    rm -f "$PAPERCLIP_BOOTSTRAP_LOG"
  else
    msg_warn "Paperclip authenticated mode is enabled, but no CEO invite URL was extracted"
    # FIX — was: rm -f "$PAPERCLIP_BOOTSTRAP_LOG" unconditionally
    # If URL extraction failed, deleting the log destroys the only diagnostic
    # evidence. Keep it so the operator can inspect what bootstrap-ceo actually
    # printed and re-run manually: sudo -u paperclip pnpm paperclipai auth
    # bootstrap-ceo --force (from /opt/paperclip with .env sourced)
    msg_info "Bootstrap log preserved for debugging: ${PAPERCLIP_BOOTSTRAP_LOG}"
  fi
else
  msg_info "Paperclip Bootstrapped in Local Trusted Mode"
  rm -f "$PAPERCLIP_BOOTSTRAP_LOG"
fi
rm -f "$PAPERCLIP_ONBOARD_LOG"
msg_ok "Bootstrapped Paperclip"

msg_info "Creating Service"
cat <<EOF >/etc/systemd/system/paperclip.service
[Unit]
Description=Paperclip
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
# FIX — was: User=root
# Claude Code (@anthropic-ai/claude-code) has a hardcoded root-execution
# guard. It calls getuid() at startup and exits immediately when the result
# is 0. This is a deliberate security check that cannot be bypassed via any
# configuration, environment variable, or wrapper. On the original root
# service, every agent invocation exited before doing any work — Paperclip
# appeared to start correctly but all actual agent tasks were silently failing.
User=paperclip
Group=paperclip
# FIX — was: WorkingDirectory=/opt/paperclip-ai (wrong path)
WorkingDirectory=/opt/paperclip
# FIX — was: EnvironmentFile=/opt/paperclip-ai/.env (wrong path)
EnvironmentFile=/opt/paperclip/.env
# FIX — was: Environment=HOME=/root
# HOME must match the service user's home so Claude Code and Codex find their
# config directories (api keys, settings) in ~/.claude and ~/.codex.
Environment=HOME=/home/paperclip
Environment=CODEX_HOME=/home/paperclip/.codex
# FIX — was: PATH=/root/.local/bin:/usr/local/bin:/usr/bin:/bin
# /root/.local/bin is irrelevant for the paperclip user.
# /usr/local/bin covers npm global installs (claude-code, codex shims).
Environment=PATH=/home/paperclip/.local/bin:/usr/local/bin:/usr/bin:/bin
Environment=DISABLE_AUTOUPDATER=1
ExecStart=/usr/bin/env pnpm paperclipai run
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now paperclip
msg_ok "Created Service"

motd_ssh
customize
cleanup_lxc
