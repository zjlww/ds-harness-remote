#!/usr/bin/env bash
set -euo pipefail

# Usage: install.sh

NODE_VERSION="${NODE_VERSION:-22.14.0}"
# Pin exact versions. `latest` is refused unless DSH_ALLOW_LATEST=1 is set, because
# it silently upgrades a boot-persistent, remote-reachable service to whatever was
# published most recently.
DSH_VERSION="${DSH_VERSION:-0.2.0-rc.2}"
REMOTE_VERSION="${REMOTE_VERSION:-0.4.27}"
DSH_PROFILE="${DSH_PROFILE:-web}"
NODE_HOME="${DSH_NODE_HOME:-${HOME}/.local/share/dsh-node/node-v${NODE_VERSION}}"
# Official registry by default; a mirror may still be chosen explicitly.
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org}"
NODE_MIRROR="${NODE_MIRROR:-https://nodejs.org/dist}"
SERVICE_NAME="${DSH_SERVICE_NAME:-dsh-remote}"
SERVICE_COMMAND="${DSH_SERVICE_COMMAND:-}"
# Installing a boot-persistent service is a deliberate opt-in. It runs the Host
# unattended from boot, so it must not happen as a side effect of installing a CLI.
DSH_INSTALL_SERVICE="${DSH_INSTALL_SERVICE:-false}"
# Remote terminal access is off unless the operator asks for it. It is equivalent to
# handing an interactive shell on this machine to any authorized remote device.
DSH_REMOTE_TERMINAL_ENABLED="${DSH_REMOTE_TERMINAL_ENABLED:-false}"
export DSH_REMOTE_TERMINAL_ENABLED
INITIAL_PATH="$PATH"
PATH_BLOCK_BEGIN='# >>> dsh-remote installer >>>'
PATH_BLOCK_END='# <<< dsh-remote installer <<<'

say() { printf '[dsh-install] %s\n' "$*"; }
die() { printf '[dsh-install] error: %s\n' "$*" >&2; exit 1; }

# Refuses mutable version selectors for anything that ends up in a persistent
# service, unless the operator explicitly opts in.
require_pinned_version() {
  local name="$1" value="$2"
  case "$value" in
    latest|next|canary|'') 
      if [[ "${DSH_ALLOW_LATEST:-0}" == "1" ]]; then
        say "warning: ${name}=${value} installs a mutable version (DSH_ALLOW_LATEST=1)"
        return 0
      fi
      die "${name} must be an exact version (got '${value}'). Set DSH_ALLOW_LATEST=1 to accept a moving tag."
      ;;
  esac
}

# Verifies a downloaded archive against a published SHA-256 before it is extracted
# and executed. The checksum file itself is fetched next to the artifact.
verify_sha256() {
  local file="$1" url="$2" name="$3" sums sums_url expected actual
  sums_url="${url%/*}/SHASUMS256.txt"
  sums="$(mktemp)"
  if ! curl --fail --silent --show-error --location --retry 3 --output "$sums" "$sums_url"; then
    rm -f "$sums"
    die "Cannot fetch ${sums_url} to verify ${name}. Refusing to run an unverified download."
  fi
  expected="$(awk -v n="$name" '$2 == n || $2 == "*"n { print $1; exit }' "$sums")"
  rm -f "$sums"
  [[ -n "$expected" ]] || die "No SHA-256 for ${name} in the published checksum list. Refusing to continue."
  actual="$(shasum -a 256 "$file" 2>/dev/null | awk '{print $1}')"
  [[ -n "$actual" ]] || actual="$(sha256sum "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || die "SHA-256 mismatch for ${name}: expected ${expected}, got ${actual}."
  say "Verified ${name} (sha256 ${expected:0:16}…)"
}

install_node() {
  command -v curl >/dev/null 2>&1 || die 'curl is required to install Node.js automatically.'
  local os arch archive url tmp extract_dir
  case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux) os=linux ;;
    *) die 'This script supports Linux and macOS. Use scripts/install.ps1 on Windows.' ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
  archive="node-v${NODE_VERSION}-${os}-${arch}.tar.gz"
  url="${NODE_MIRROR}/v${NODE_VERSION}/${archive}"
  tmp="$(mktemp -d)"
  say "Node.js not found; downloading ${NODE_VERSION} from ${NODE_MIRROR}"
  curl --fail --location --retry 3 --output "$tmp/$archive" "$url"
  verify_sha256 "$tmp/$archive" "$url" "$archive"
  mkdir -p "$(dirname "$NODE_HOME")"
  tar -xzf "$tmp/$archive" -C "$(dirname "$NODE_HOME")"
  extract_dir="$(dirname "$NODE_HOME")/node-v${NODE_VERSION}-${os}-${arch}"
  if [[ "$extract_dir" != "$NODE_HOME" ]]; then
    rm -rf "$NODE_HOME"
    mv "$extract_dir" "$NODE_HOME"
  fi
  export PATH="$NODE_HOME/bin:$PATH"
  rm -rf "$tmp"
  say "Node.js installed at $NODE_HOME"
}

# The global bin directory is often outside the user's default PATH (nvm, or
# the Node.js this script just downloaded), and the export below only affects
# this process. Persist it so `dsh` and `ds-harness-remote` survive the install
# for later shells too.
persist_path() {
  local bin_dir="$1" rc
  local rcs=("${HOME}/.profile")
  case "${SHELL:-}" in
    */zsh) rcs+=("${HOME}/.zshrc") ;;
    */bash) rcs+=("${HOME}/.bashrc") ;;
  esac
  for rc in "${rcs[@]}"; do
    touch "$rc"
    if grep -qF "$PATH_BLOCK_BEGIN" "$rc"; then
      say "PATH entry already present in $rc"
      continue
    fi
    {
      printf '\n%s\n' "$PATH_BLOCK_BEGIN"
      printf 'export PATH="%s:$PATH"\n' "$bin_dir"
      printf '%s\n' "$PATH_BLOCK_END"
    } >>"$rc"
    say "Added ${bin_dir} to PATH in $rc"
  done
}

if ! command -v node >/dev/null 2>&1; then install_node; fi
command -v npm >/dev/null 2>&1 || die 'npm was not found next to Node.js.'

export PATH="$(npm prefix --global)/bin:$PATH"
if ! command -v pnpm >/dev/null 2>&1; then
  say 'Installing pnpm (required by the DSH plugin manager)'
  # pnpm >= 11 is what DSH profiles are written for: their pnpm-workspace.yaml
  # carries pnpm 11 settings and their packageManager pins pnpm@11. Installing
  # pnpm 9 here would also shadow that pin with an older lockfile format.
  npm --registry "$NPM_REGISTRY" install --global pnpm@11.21.0
fi
pnpm --version
export npm_config_registry="$NPM_REGISTRY"

say "Installing @deepseek-ai/dsh (${DSH_VERSION})"
require_pinned_version DSH_VERSION "$DSH_VERSION"
npm --registry "$NPM_REGISTRY" install --global "@deepseek-ai/dsh@${DSH_VERSION}"
say "Installing ds-harness-remote CLI (${REMOTE_VERSION})"
require_pinned_version REMOTE_VERSION "$REMOTE_VERSION"
npm --registry "$NPM_REGISTRY" install --global "ds-harness-remote@${REMOTE_VERSION}"
REMOTE_PACKAGE_DIR="$(npm root --global)/ds-harness-remote"
[[ -f "$REMOTE_PACKAGE_DIR/package.json" ]] || die "Global ds-harness-remote package was not found at $REMOTE_PACKAGE_DIR"

NPM_GLOBAL_BIN="$(npm prefix --global)/bin"
if [[ ":$INITIAL_PATH:" != *":${NPM_GLOBAL_BIN}:"* ]]; then
  persist_path "$NPM_GLOBAL_BIN"
fi

# -w is required: a DSH profile is itself a pnpm workspace, and pnpm < 11
# refuses to add a dependency to a workspace root without it
# (ERR_PNPM_ADDING_TO_ROOT), which aborts the install before the service step.
say "Adding ds-harness-remote@${REMOTE_VERSION} to the ${DSH_PROFILE} profile"
dsh plugin --profile "$DSH_PROFILE" add -w "$REMOTE_PACKAGE_DIR"

say 'Plugins installed.'

if [[ "${DSH_INSTALL_SERVICE}" != "1" && "${DSH_INSTALL_SERVICE}" != "true" ]]; then
  say 'Skipping service installation (default).'
  say "The CLI and profile are ready; start the Host with 'dsh --profile ${DSH_PROFILE}' when you want it."
  say 'To install a boot-persistent service, re-run with DSH_INSTALL_SERVICE=1.'
  exit 0
fi

say 'Configuring the Host service.'

executable="${SERVICE_COMMAND:-}"
  if [[ -z "$executable" ]]; then
    executable="$(command -v dsh || true)"
  fi
  [[ -n "$executable" ]] || die 'Cannot find dsh. Set DSH_SERVICE_COMMAND to its executable.'
  # A service has no interactive terminal and must use the installed profile.
  runner_dir="$HOME/.local/share/dsh-remote"
  mkdir -p "$runner_dir"
  runner="$runner_dir/start-host.sh"
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    printf 'export PATH=%q\n' "$PATH"
    printf 'export DSH_REMOTE_TERMINAL_ENABLED=%q\n' "$DSH_REMOTE_TERMINAL_ENABLED"
    printf 'cd %q\n' "$HOME"
    printf 'exec %q --profile %q\n' "$executable" "$DSH_PROFILE"
  } > "$runner"
  chmod 700 "$runner"
  case "$(uname -s)" in
    Linux)
      command -v systemctl >/dev/null 2>&1 || die 'systemctl is required to install the system service.'
      if [[ "${EUID}" -eq 0 ]]; then
        sudo_prefix=""
      else
        command -v sudo >/dev/null 2>&1 || die 'sudo is required to install the system service. Re-run as root.'
        sudo_prefix="sudo"
      fi
      run_user="$(id -un)"
      unit_path="/etc/systemd/system/${SERVICE_NAME}.service"
      ${sudo_prefix} tee "$unit_path" >/dev/null <<EOF
[Unit]
Description=DSH Remote Host
After=network-online.target
Wants=network-online.target

[Service]
User=${run_user}
ExecStart=/bin/bash "${runner}"
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
      ${sudo_prefix} systemctl daemon-reload
      ${sudo_prefix} systemctl enable --now "${SERVICE_NAME}.service"
      say "Installed and started systemd system service ${SERVICE_NAME} (running as ${run_user})."
      ;;
    Darwin)
      plist_dir="${HOME}/Library/LaunchAgents"
      plist_path="$plist_dir/${SERVICE_NAME}.plist"
      mkdir -p "$plist_dir"
      escaped_command="${runner//&/&amp;}"
      escaped_command="${escaped_command//</&lt;}"
      escaped_command="${escaped_command//>/&gt;}"
      cat >"$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${SERVICE_NAME}</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>${escaped_command}</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
</dict></plist>
EOF
      launchctl bootout "gui/$(id -u)" "$plist_path" >/dev/null 2>&1 || true
      launchctl bootstrap "gui/$(id -u)" "$plist_path"
      say "Installed and started launchd user agent ${SERVICE_NAME}."
      ;;
    *) die 'Service installation supports Linux systemd and macOS launchd.' ;;
esac

printf '\n'
say 'The ds-harness-remote CLI is ready to use. Examples:'
printf '  ds-harness-remote login zhihu     # sign in with a Zhihu QR code (default)\n'
printf '  ds-harness-remote login github    # sign in with GitHub\n'
printf '  ds-harness-remote status          # show login and Host status\n'
printf '  ds-harness-remote logout          # sign out this device\n'
say 'Inside dsh-TUI the equivalents are /remote login, /remote status, /remote logout.'

case "$(uname -s)" in
  Linux) say "After CLI login/logout, run: sudo systemctl restart ${SERVICE_NAME}.service" ;;
  Darwin) say "After CLI login/logout, run: launchctl kickstart -k gui/$(id -u)/${SERVICE_NAME}" ;;
esac
