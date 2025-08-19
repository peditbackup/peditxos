#!/bin/bash

# ==============================================================================
# PeDitXOS Repository Setup Script
# ==============================================================================
# This script automates the creation of the entire directory structure and
# all necessary files for the PeDitXOS firmware builder project.
#
# Instructions:
# 1. Save this script as `setup_peditxos_repo.sh`.
# 2. Make it executable: `chmod +x setup_peditxos_repo.sh`
# 3. Run it: `./setup_peditxos_repo.sh`
# 4. After it finishes, initialize git and push to your repository.
# ==============================================================================

# --- Start of Script ---
echo ">>> Starting PeDitXOS repository setup..."

# --- 1. Create Directory Structure ---
echo "--> Creating directory structure..."
mkdir -p .github/workflows
mkdir -p files/etc/uci-defaults
mkdir -p files/etc/profile.d
mkdir -p files/usr/bin
mkdir -p files/usr/lib/lua/luci/controller
mkdir -p files/usr/lib/lua/luci/view/peditxos
mkdir -p files/usr/lib/lua/luci/view/serviceinstaller
mkdir -p custom-keys
echo "    ...directories created successfully."

# --- 2. Create Core Files from Here-Documents ---

# --- GitHub Actions Workflow ---
echo "--> Creating .github/workflows/build.yml"
cat << 'EOF' > .github/workflows/build.yml
# .github/workflows/build.yml

name: 'PeDitXOS Firmware Builder'

# This workflow is triggered manually via the GitHub API
on:
  workflow_dispatch:
    inputs:
      device_target:
        description: 'Device Target (e.g., x86/64)'
        required: true
        type: string
      device_profile:
        description: 'Device Profile (e.g., generic)'
        required: true
        type: string
      openwrt_version:
        description: 'OpenWrt Version (e.g., 23.05.3)'
        required: true
        type: string
      extra_packages:
        description: 'A space-separated list of extra packages (e.g., luci-app-passwall)'
        required: false
        type: string
      theme_choice:
        description: 'The selected LuCI theme package'
        required: true
        type: string
        default: 'luci-theme-peditx'

jobs:
  build_firmware:
    name: Build Firmware
    runs-on: ubuntu-latest

    steps:
      - name: 'Checkout Repository'
        uses: actions/checkout@v4

      - name: 'Install Build Dependencies'
        run: |
          sudo apt-get update
          sudo apt-get install -y wget tar make coreutils rsync openssh-client curl

      - name: 'Download OpenWrt ImageBuilder'
        run: |
          # Construct the filename and URL
          TARGET_NAME=$(echo "${{ github.event.inputs.device_target }}" | tr '/' '-')
          IMAGEBUILDER_FILENAME="openwrt-imagebuilder-${{ github.event.inputs.openwrt_version }}-${TARGET_NAME}.Linux-x86_64.tar.xz"
          IMAGEBUILDER_URL="https://downloads.openwrt.org/releases/${{ github.event.inputs.openwrt_version }}/targets/${{ github.event.inputs.device_target }}/${IMAGEBUILDER_FILENAME}"
          
          echo "Downloading from: ${IMAGEBUILDER_URL}"
          wget -q "${IMAGEBUILDER_URL}"
          tar -xf "${IMAGEBUILDER_FILENAME}"

      - name: 'Prepare ImageBuilder Environment'
        run: |
          # Find the extracted ImageBuilder directory and save its path
          IMAGEBUILDER_DIR=$(find . -maxdepth 1 -type d -name "openwrt-imagebuilder-*")
          echo "IMAGEBUILDER_DIR=${IMAGEBUILDER_DIR}" >> $GITHUB_ENV

          # Add custom repository key
          KEY_DIR="${IMAGEBUILDER_DIR}/etc/opkg/keys"
          mkdir -p "${KEY_DIR}"
          cp ./custom-keys/passwall.pub "${KEY_DIR}/"
          echo "Custom repository key added."

          # Determine the target architecture from ImageBuilder info
          TARGET_ARCH=$(opkg --arch-file "${IMAGEBUILDER_DIR}/.targetinfo" print-architecture | awk '{print $2}')
          echo "TARGET_ARCH=${TARGET_ARCH}" >> $GITHUB_ENV
          echo "Detected architecture: ${TARGET_ARCH}"

          # Add custom repository feeds dynamically
          REPO_CONF_FILE="${IMAGEBUILDER_DIR}/etc/opkg/customfeeds.conf"
          RELEASE_MAJOR_VERSION=$(echo "${{ github.event.inputs.openwrt_version }}" | cut -d. -f1,2)
          
          echo "Adding custom feeds to ${REPO_CONF_FILE}..."
          echo "src/gz passwall_luci https://repo.peditxdl.ir/passwall-packages/releases/packages-${RELEASE_MAJOR_VERSION}/${TARGET_ARCH}/passwall_luci" >> "${REPO_CONF_FILE}"
          echo "src/gz passwall_packages https://repo.peditxdl.ir/passwall-packages/releases/packages-${RELEASE_MAJOR_VERSION}/${TARGET_ARCH}/passwall_packages" >> "${REPO_CONF_FILE}"
          echo "src/gz passwall2 https://repo.peditxdl.ir/passwall-packages/releases/packages-${RELEASE_MAJOR_VERSION}/${TARGET_ARCH}/passwall2" >> "${REPO_CONF_FILE}"
          echo "Custom feeds added."

      - name: 'Download Custom IPK Packages'
        run: |
          CUSTOM_PKG_DIR="${{ env.IMAGEBUILDER_DIR }}/packages"
          mkdir -p "${CUSTOM_PKG_DIR}"
          
          # Function to download latest release IPK from a GitHub repo
          download_latest_ipk() {
            local REPO_NAME="$1"
            local API_URL="https://api.github.com/repos/peditx/${REPO_NAME}/releases/latest"
            local IPK_URL=$(curl -s "$API_URL" | grep "browser_download_url.*ipk" | cut -d '"' -f 4 | head -n 1)
            if [ -n "$IPK_URL" ]; then
              echo "Downloading ${REPO_NAME} from ${IPK_URL}"
              wget -q "$IPK_URL" -P "${CUSTOM_PKG_DIR}"
            else
              echo "Warning: Could not find latest release for ${REPO_NAME}"
            fi
          }

          # Download architecture-specific themeswitch
          THEMESWITCH_VERSION=$(curl -s https://api.github.com/repos/peditx/luci-app-themeswitch/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
          if [ -n "$THEMESWITCH_VERSION" ]; then
            THEMESWITCH_URL="https://github.com/peditx/luci-app-themeswitch/releases/download/${THEMESWITCH_VERSION}/luci-app-themeswitch_${THEMESWITCH_VERSION}_${{ env.TARGET_ARCH }}.ipk"
            echo "Downloading themeswitch from ${THEMESWITCH_URL}"
            wget -q "$THEMESWITCH_URL" -P "${CUSTOM_PKG_DIR}"
          else
            echo "Warning: Could not determine themeswitch version."
          fi

          download_latest_ipk "luci-theme-peditx"
          download_latest_ipk "luci-theme-carbonpx"
          
          echo "--- Custom packages downloaded ---"
          ls -1 "${CUSTOM_PKG_DIR}"

      - name: 'Build Firmware Image'
        run: |
          cd "${{ env.IMAGEBUILDER_DIR }}"
          
          # Define base packages that are always included
          BASE_PACKAGES="luci luci-ssl luci-compat curl screen sshpass procps-ng-pkill luci-app-ttyd coreutils coreutils-base64 coreutils-nohup"
          
          # Combine all packages for the final build
          ALL_PACKAGES="${BASE_PACKAGES} -luci-theme-bootstrap ${{ github.event.inputs.theme_choice }} luci-app-themeswitch ${{ github.event.inputs.extra_packages }}"
          
          echo "Building with Profile: ${{ github.event.inputs.device_profile }}"
          echo "Final Packages: ${ALL_PACKAGES}"

          make image PROFILE="${{ github.event.inputs.device_profile }}" \
            PACKAGES="${ALL_PACKAGES}" \
            FILES="${{ github.workspace }}/files" \
            BIN_DIR="${{ github.workspace }}/output"

      - name: 'Organize and Rename Output Files'
        run: |
          cd "${{ github.workspace }}/output"
          if [ -z "$(ls -A .)" ]; then
            echo "Build failed: No files found in output directory."
            exit 1
          fi
          for f in openwrt-*; do
            mv -- "$f" "PeDitXOS-${f#openwrt-}"
          done
          echo "--- Renamed Files ---"
          ls -1

      - name: 'Upload Firmware to SourceForge'
        env:
          SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
          SF_USERNAME: ${{ secrets.SF_USERNAME }}
          SF_PROJECT_NAME: ${{ secrets.SF_PROJECT_NAME }}
        run: |
          mkdir -p ~/.ssh
          echo "${SSH_PRIVATE_KEY}" > ~/.ssh/id_rsa
          chmod 600 ~/.ssh/id_rsa
          ssh-keyscan -H frs.sourceforge.net >> ~/.ssh/known_hosts

          REMOTE_DIR="/home/frs/project/${SF_PROJECT_NAME}/${{ github.event.inputs.openwrt_version }}/"
          echo "Uploading files to SourceForge at ${REMOTE_DIR}"
          
          rsync -avz --progress -e "ssh -i ~/.ssh/id_rsa" \
            "${{ github.workspace }}/output/" \
            "${SF_USERNAME}@frs.sourceforge.net:${REMOTE_DIR}"
            
          echo "Upload complete."
EOF

# --- Banner File ---
echo "--> Creating files/etc/banner"
cat << 'EOF' > files/etc/banner
 ______      _____   _      _    _     _____       
(_____ \    (____ \ (_)_   \ \  / /   / ___ \      
 _____) )___ _   \ \ _| |_  \ \/ /   | |   | | ___ 
|  ____/ _  ) |   | | |  _)  )  (    | |   | |/___)
| |   ( (/ /| |__/ /| | |__ / /\ \   | |___| |___ |
|_|    \____)_____/ |_|\___)_/  \_\   \_____/(___/ 
                                                   
HTTPS://PEDITX.IR   
telegram : @PeDitX
EOF

# --- UCI Defaults Script ---
echo "--> Creating files/etc/uci-defaults/99-peditxos-defaults"
cat << 'EOF' > files/etc/uci-defaults/99-peditxos-defaults
#!/bin/sh
# This script runs once on the first boot to set initial configurations.

# Set system timezone and hostname
uci set system.@system[0].zonename='Asia/Tehran'
uci set system.@system[0].hostname='PeDitXOS'
uci commit system

# Set custom distribution information
sed -i 's/DISTRIB_ID=.*/DISTRIB_ID="PeDitXOS"/' /etc/openwrt_release
sed -i 's/DISTRIB_DESCRIPTION=.*/DISTRIB_DESCRIPTION="PeDitX OS telegram:@peditx"/' /etc/openwrt_release

exit 0
EOF

# --- Runner Script ---
echo "--> Creating files/usr/bin/peditx_runner.sh"
cat << 'EOF' > files/usr/bin/peditx_runner.sh
#!/bin/sh

# PeDitXOS Runner Script - Dynamic Action Handling
# If an action is not defined locally, it's delegated to the external service_runner.

ACTION="$1"
ARG1="$2"
ARG2="$3"
ARG3="$4"
LOG_FILE="/tmp/peditxos_log.txt"
LOCK_FILE="/tmp/peditx.lock"

# --- Lock File and Logging Setup ---
if [ -f "$LOCK_FILE" ]; then
    echo ">>> Another process is already running. Please wait for it to finish." >> "$LOG_FILE"
    exit 1
fi
touch "$LOCK_FILE"
# Ensure the lock file is removed on exit
trap 'rm -f "$LOCK_FILE"' EXIT TERM INT
# Redirect all output to the log file
exec >> "$LOG_FILE" 2>&1

# --- URLs (to keep logs clean) ---
URL_SERVICE_RUNNER="https://raw.githubusercontent.com/peditx/PeDitXOs/refs/heads/main/services/service_runner.sh"
URL_PW1="https://github.com/peditx/iranIPS/raw/refs/heads/main/.files/passwall.sh"
URL_PW2="https://github.com/peditx/iranIPS/raw/refs/heads/main/.files/passwall2.sh"
URL_PW_DUE="https://github.com/peditx/iranIPS/raw/refs/heads/main/.files/passwalldue.sh"
URL_EZEXROOT="https://github.com/peditx/ezexroot/raw/refs/heads/main/ezexroot.sh"
URL_EXPAND="https://raw.githubusercontent.com/peditx/PeDitXOs/refs/heads/main/.files/expand.sh"
URL_SERVICES_JSON="https://raw.githubusercontent.com/peditx/PeDitXOs/refs/heads/main/services/services.json"

# --- Function Definitions ---

# This is the key function for dynamic handling.
# It downloads and runs the external script for any given action.
handle_service_action() {
    local service_action="$1"
    echo ">>> Action '$service_action' not found locally. Delegating to Service Runner..."
    cd /tmp
    # Always remove the old runner to ensure we have the latest version
    rm -f service_runner.sh
    if ! wget -q "$URL_SERVICE_RUNNER" -O service_runner.sh; then
        echo "ERROR: Failed to download the service runner script from GitHub."
        return 1
    fi
    chmod +x service_runner.sh
    echo "--- Executing External Service Runner for: $service_action ---"
    # Pass the action to the external script
    sh ./service_runner.sh "$service_action"
    echo "--- Service Runner Finished ---"
}

update_service_list() {
    echo "Updating service list from remote source..."
    if wget -q "$URL_SERVICES_JSON" -O /etc/config/peditx_services.json; then
        echo "Service list downloaded successfully."
    else
        echo "ERROR: Failed to download the service list."
        return 1
    fi
}

refresh_luci() {
    echo "Clearing LuCI cache..."
    rm -f /tmp/luci-indexcache
    echo "LuCI cache cleared. Please reload the web page."
}

install_pw1() {
    echo "Downloading Passwall 1 components..."
    cd /tmp
    rm -f passwall.sh
    wget -q "$URL_PW1" -O passwall.sh
    chmod +x passwall.sh
    sh passwall.sh
    echo "Passwall 1 installed successfully."
}

install_pw2() {
    echo "Downloading Passwall 2 components..."
    cd /tmp
    rm -f passwall2.sh
    wget -q "$URL_PW2" -O passwall2.sh
    chmod +x passwall2.sh
    sh passwall2.sh
    echo "Passwall 2 installed successfully."
}

install_both() {
    echo "Downloading Passwall 1 & 2 components..."
    cd /tmp
    rm -f passwalldue.sh
    wget -q "$URL_PW_DUE" -O passwalldue.sh
    chmod +x passwalldue.sh
    sh passwalldue.sh
    echo "Both Passwall versions installed successfully."
}

easy_exroot() {
    echo "Downloading Easy Exroot script..."
    cd /tmp
    curl -ksSL "$URL_EZEXROOT" -o ezexroot.sh
    sh ezexroot.sh
    echo "Easy Exroot script finished."
}

uninstall_all() {
    echo "Uninstalling all PeDitXOS related packages..."
    opkg remove luci-app-passwall luci-app-passwall2 luci-app-torplus luci-app-sshplus luci-app-aircast luci-app-dns-changer
    echo "Uninstallation complete."
}

set_dns() {
    local provider="$1"
    local dns1="$2"
    local dns2="$3"
    local servers

    echo "Setting DNS to $provider..."
    case "$provider" in
        shecan)   servers="178.22.122.100 185.51.200.2" ;;
        electro)  servers="78.157.42.100 78.157.42.101" ;;
        cloudflare) servers="1.1.1.1 1.0.0.1" ;;
        google)   servers="8.8.8.8 8.8.4.4" ;;
        begzar)   servers="185.55.226.26 185.55.225.25" ;;
        radar)    servers="10.202.10.10 10.202.10.11" ;;
        custom)   servers="$dns1 $dns2" ;;
        *) echo "Error: Invalid DNS provider '$provider'."; return 1 ;;
    esac

    uci set network.wan.peerdns='0'
    uci set network.wan.dns='' 
    for server in $servers; do
        if [ -n "$server" ]; then
            uci add_list network.wan.dns="$server"
        fi
    done
    uci commit network
    /etc/init.d/network restart
    echo "DNS servers updated successfully."
}

set_wifi_config() {
    local ssid="$1"
    local key="$2"
    local band="$3"
    echo "Configuring WiFi (SSID: $ssid, Band: $band)..."
    echo "WiFi configuration is a placeholder. Implement actual UCI commands here."
}

set_lan_ip() {
    local ipaddr="$1"
    echo "Setting LAN IP to $ipaddr..."
    uci set network.lan.ipaddr="$ipaddr"
    uci commit network
    echo "LAN IP will be changed after the next network restart or system reboot."
}

get_system_info() {
    echo "Fetching system information..."
    (
        echo "Hostname: $(hostname)"
        echo "OpenWrt Version: $(cat /etc/openwrt_release)"
        echo "Kernel Version: $(uname -a)"
        echo "CPU Info: $(cat /proc/cpuinfo | grep 'model name' | uniq)"
        echo "Memory: $(free -h | grep 'Mem:' | awk '{print $2}')"
        echo "Disk Usage: $(df -h / | awk 'NR==2 {print $2, $3, $4}')"
    )
    echo "System information fetched."
}

install_opt_packages() {
    echo "Installing selected packages..."
    local packages_to_install="$1"
    
    if [ -z "$packages_to_install" ]; then
        echo "No packages selected to install."
        return 0
    fi

    if ! command -v whiptail >/dev/null 2>&1; then
        echo "Installing whiptail..."
        opkg update && opkg install whiptail
        if [ $? -ne 0 ]; then
            echo "Failed to install whiptail. Exiting..."
            return 1
        fi
    fi

    echo "Updating package lists..."
    opkg update

    for package_name in $packages_to_install; do
        echo "Installing $package_name..."
        opkg install "$package_name"
        if [ $? -eq 0 ]; then
            echo "$package_name installed successfully."
        else
            echo "Failed to install $package_name."
        fi
    done
}

apply_cpu_opts() {
    echo "Applying CPU optimizations..."
    for CPU in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -f "$CPU" ] && echo "performance" > "$CPU"
    done
    echo "CPU optimizations applied."
}

apply_mem_opts() {
    echo "Applying Memory optimizations..."
    sysctl -w vm.swappiness=10
    sysctl -w vm.vfs_cache_pressure=50
    echo "Memory optimizations applied."
}

apply_net_opts() {
    echo "Applying Network optimizations..."
    if ! opkg list-installed | grep -q "kmod-tcp-bbr"; then
        echo "Installing kmod-tcp-bbr for congestion control..."
        opkg update
        opkg install kmod-tcp-bbr
    fi
    sysctl -w net.ipv4.tcp_fastopen=3
    sysctl -w net.ipv4.tcp_congestion_control=bbr
    echo "Network optimizations applied."
}

apply_usb_opts() {
    echo "Applying USB optimizations..."
    echo "USB optimizations placeholder."
}

enable_luci_wan() {
    echo "Enabling LuCI on WAN..."
    uci set firewall.@rule[0].dest_port=80
    uci set firewall.@rule[1].dest_port=443
    uci commit firewall
    /etc/init.d/firewall restart
    echo "LuCI is now accessible from WAN."
}

expand_root() {
    echo "---"
    echo "CRITICAL WARNING: Expanding root partition... THIS WILL WIPE ALL DATA!"
    echo "---"
    echo "Downloading and preparing the expansion script..."
    cd /tmp
    wget -q "$URL_EXPAND" -O expand.sh
    chmod +x expand.sh
    echo "---"
    echo "--- ACTION REQUIRED ---"
    echo "The expansion script is about to run. The system will reboot automatically."
    echo "After reboot, the process will continue. Please be patient."
    echo "-----------------------"
    sh expand.sh
    # The script will likely not reach this point as a reboot is expected.
    echo "Expansion script initiated. System should be rebooting now."
}

restore_opt_backup() {
    echo "Restoring config backup..."
    echo "Restore config backup command placeholder."
}

reboot_system() {
    echo "Rebooting system in 5 seconds..."
    sleep 5
    reboot
}

# --- Main Execution Block ---
echo ">>> Starting action: $ACTION at $(date)"
echo "--------------------------------------"

EXIT_CODE=0
case "$ACTION" in
    # --- Actions handled LOCALLY by this script ---
    update_service_list) update_service_list ;;
    refresh_luci) refresh_luci ;;
    install_pw1) install_pw1 ;;
    install_pw2) install_pw2 ;;
    install_both) install_both ;;
    easy_exroot) easy_exroot ;;
    uninstall_all) uninstall_all ;;
    set_dns_shecan) set_dns "shecan" ;;
    set_dns_electro) set_dns "electro" ;;
    set_dns_cloudflare) set_dns "cloudflare" ;;
    set_dns_google) set_dns "google" ;;
    set_dns_begzar) set_dns "begzar" ;;
    set_dns_radar) set_dns "radar" ;;
    set_dns_custom) set_dns "custom" "$ARG1" "$ARG2" ;;
    set_wifi_config) set_wifi_config "$ARG1" "$ARG2" "$ARG3" ;;
    set_lan_ip) set_lan_ip "$ARG1" ;;
    get_system_info) get_system_info ;;
    opkg_update) opkg update ;;
    install_opt_packages | install_extra_packages) install_opt_packages "$ARG1" ;;
    apply_cpu_opts) apply_cpu_opts ;;
    apply_mem_opts) apply_mem_opts ;;
    apply_net_opts) apply_net_opts ;;
    apply_usb_opts) apply_usb_opts ;;
    enable_luci_wan) enable_luci_wan ;;
    expand_root) expand_root ;;
    restore_opt_backup) restore_opt_backup ;;
    reboot_system) reboot_system ;;
    clear_log) echo "Log cleared by user at $(date)" > "$LOG_FILE" ;;

    # --- DEFAULT: Any other action is assumed to be a service and is delegated ---
    *)
        handle_service_action "$ACTION"
        ;;
esac
EXIT_CODE=$?

echo "--------------------------------------"
if [ $EXIT_CODE -eq 0 ]; then
    echo "Action completed successfully at $(date)."
else
    echo "Action failed with exit code $EXIT_CODE at $(date)."
fi
echo ">>> SCRIPT FINISHED <<<"
exit 0
EOF

# --- LuCI Controller ---
echo "--> Creating files/usr/lib/lua/luci/controller/peditxos.lua"
cat << 'EOF' > files/usr/lib/lua/luci/controller/peditxos.lua
module("luci.controller.peditxos", package.seeall)
function index()
    entry({"admin", "peditxos"}, firstchild(), "PeDitXOS Tools", 40).dependent = false
    
    -- Entry for the main dashboard
    entry({"admin", "peditxos", "dashboard"}, template("peditxos/main"), "Dashboard", 1)
    
    -- Entry for the standalone Store page
    entry({"admin", "peditxos", "serviceinstaller"}, template("serviceinstaller/main"), "Store", 2)

    -- JSON endpoints for the main dashboard
    entry({"admin", "peditxos", "status"}, call("get_status")).json = true
    entry({"admin", "peditxos", "run"}, call("run_script")).json = true
    entry({"admin", "peditxos", "get_ttyd_info"}, call("get_ttyd_info")).json = true
end

function get_ttyd_info()
    local uci = require "luci.model.uci".cursor()
    local port = uci:get("ttyd", "core", "port") or "7681"
    local ssl = (uci:get("ttyd", "core", "ssl") == "1")
    
    luci.http.prepare_content("application/json")
    luci.http.write_json({
        port = port,
        ssl = ssl
    })
end

function get_status()
    local nixio = require "nixio"
    local log_file = "/tmp/peditxos_log.txt"
    local lock_file = "/tmp/peditx.lock"
    
    local content = ""
    local f = io.open(log_file, "r")
    if f then content = f:read("*a"); f:close() end
    
    local is_running = nixio.fs.access(lock_file)
    
    luci.http.prepare_content("application/json")
    luci.http.write_json({ running = is_running, log = content })
end

function run_script()
    local action = luci.http.formvalue("action")
    if not action or not action:match("^[a-zA-Z0-9_.-]+$") then
        luci.http.prepare_content("application/json")
        luci.http.write_json({success = false, error = "Invalid action"})
        return
    end

    if action == "stop_process" then
        luci.sys.exec("pkill -f '/usr/bin/peditx_runner.sh' >/dev/null 2>&1")
        luci.sys.exec("rm -f /tmp/peditx.lock")
        luci.sys.exec("echo '\n>>> Process stopped by user at $(date) <<<' >> /tmp/peditxos_log.txt")
        luci.http.prepare_content("application/json")
        luci.http.write_json({success = true})
        return
    elseif action == "clear_log" then
        luci.sys.exec("echo 'Log cleared by user at $(date)' > /tmp/peditxos_log.txt")
        luci.http.prepare_content("application/json")
        luci.http.write_json({success = true})
        return
    end
    
    local cmd = "/usr/bin/peditx_runner.sh " .. action
    
    if action == "set_dns_custom" then
        cmd = cmd .. " '" .. (luci.http.formvalue("dns1") or "") .. "' '" .. (luci.http.formvalue("dns2") or "") .. "'"
    elseif action == "install_extra_packages" or action == "install_opt_packages" then
        cmd = cmd .. " '" .. (luci.http.formvalue("packages") or "") .. "'"
    elseif action == "set_wifi_config" then
        cmd = cmd .. " '" .. (luci.http.formvalue("ssid") or "") .. "' '" .. (luci.http.formvalue("key") or "") .. "' '" .. (luci.http.formvalue("band") or "") .. "'"
    elseif action == "set_lan_ip" then
        cmd = cmd .. " '" .. (luci.http.formvalue("ipaddr") or "") .. "'"
    end
    
    luci.sys.exec("nohup " .. cmd .. " &")
    
    luci.http.prepare_content("application/json")
    luci.http.write_json({success = true})
end
EOF

# --- LuCI View ---
echo "--> Creating files/usr/lib/lua/luci/view/peditxos/main.htm"
cat << 'EOF' > files/usr/lib/lua/luci/view/peditxos/main.htm
<%# LuCI - Lua Configuration Interface v75.1 - Unified UI %>
<%+header%>
<style>
    /* ===== UNIFIED THEME (Dracula Inspired) ===== */
    :root {
        --bg-color: #282a36;
        --card-bg: #3a3c51;
        --header-bg: #21222c;
        --text-color: #f8f8f2;
        --primary-color: #50fa7b;   /* Green */
        --secondary-color: #ff79c6; /* Pink */
        --danger-color: #ff5555;    /* Red */
        --warning-color: #f1fa8c;   /* Yellow */
        --info-color: #8be9fd;      /* Cyan */
        --purple-color: #bd93f9;    /* Purple */
        --border-color: #44475a;
        --hover-color: #44475a;
    }
    body { 
        background-color: var(--bg-color);
        color: var(--text-color);
        font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
    }
    .cbi-map {
        background-color: transparent;
        border: none;
        box-shadow: none;
    }
    .cbi-map-title h2 {
        display: none; /* Hide default title, using custom header */
    }
    /* ===== END OF THEME ===== */

    .peditx-header {
        background-color: var(--header-bg);
        padding: 20px;
        border-radius: 8px;
        margin-bottom: 25px;
        border: 1px solid var(--border-color);
        text-align: center;
    }
    .peditx-header h2 {
        margin: 0 0 5px 0;
        color: var(--info-color);
        font-size: 24px;
        font-weight: 600;
    }
    .peditx-header p {
        margin: 0;
        color: var(--purple-color);
        font-size: 16px;
    }
    
    .peditx-tabs { display: flex; border-bottom: 2px solid var(--border-color); margin-bottom: 20px; flex-wrap: wrap; }
    .peditx-tab-link { background-color: transparent; border: none; border-bottom: 3px solid transparent; outline: none; cursor: pointer; padding: 14px 20px; transition: color 0.3s, background-color 0.3s, border-color 0.3s; font-size: 16px; font-weight: 500; color: var(--text-color); margin-right: 5px; margin-bottom: -2px; border-radius: 8px 8px 0 0; }
    .peditx-tab-link:hover { color: var(--text-color); background-color: var(--hover-color); }
    .peditx-tab-link.active { color: var(--primary-color); background-color: var(--card-bg); border-bottom-color: var(--primary-color); font-weight: 700; }
    .peditx-tab-content { display: none; padding: 6px 12px; border-top: none; }

    .action-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(250px, 1fr)); gap: 15px; }
    .action-item { background: var(--card-bg); padding: 15px; border-radius: 8px; display: flex; align-items: center; cursor: pointer; border: 1px solid var(--border-color); transition: transform 0.2s, box-shadow 0.2s, border-color 0.2s; }
    .action-item:hover { transform: translateY(-3px); box-shadow: 0 4px 15px rgba(0,0,0,0.2); border-color: var(--primary-color); }
    .action-item input[type="radio"], .pkg-item input[type="checkbox"] { margin-right: 15px; transform: scale(1.2); cursor: pointer; accent-color: var(--secondary-color); }
    .action-item input[type="radio"]:checked + label { color: var(--primary-color); font-weight: bold; }
    .action-item label, .pkg-item label { cursor: pointer; width: 100%; }
    
    .execute-bar { margin-top: 25px; text-align: center; display: flex; justify-content: center; gap: 20px; }
    
    /* ===== BUTTON STYLES (START & STOP) ===== */
    @keyframes pulse {
        0% { transform: scale(1); box-shadow: 0 0 0 0 rgba(255, 174, 66, 0.7); }
        70% { transform: scale(1.02); box-shadow: 0 0 0 10px rgba(255, 174, 66, 0); }
        100% { transform: scale(1); }
    }

    .peditx-main-button { 
        font-size: 18px; 
        padding: 12px 40px;
        font-weight: bold; 
        border: none; 
        border-radius: 50px; /* Make buttons round */
        box-shadow: 0 4px 15px rgba(0,0,0,0.2); 
        transition: background 0.3s ease, transform 0.2s ease; 
        cursor: pointer; 
        display: inline-flex; 
        align-items: center; 
        justify-content: center;
        text-shadow: 0 1px 1px rgba(0,0,0,0.2);
    }

    #execute-button { 
        background: linear-gradient(135deg, #ffae42, #ff8c00); /* Orange gradient */
        color: #21222c; /* Dark text for contrast */
        animation: pulse 2.5s infinite;
    }

    #execute-button:hover { 
        background: linear-gradient(135deg, #ff8c00, #e87a00); 
        transform: translateY(-2px);
        animation-play-state: paused;
    }

    #execute-button:disabled { 
        background: #555; 
        cursor: not-allowed; 
        box-shadow: none; 
        transform: none; 
        color: #999;
        animation: none; /* Stop animation when disabled */
    }

    #stop-button { 
        background: var(--danger-color); 
        color: var(--text-color); /* Ensure text is light */
    }

    #stop-button:hover { 
        background: #ff6e6e; 
        transform: translateY(-2px); 
    }
    /* ===== END OF BUTTON STYLES ===== */

    .peditx-log-container { background-color: var(--header-bg); color: var(--text-color); font-family: monospace; padding: 15px; border-radius: 8px; height: 350px; overflow-y: scroll; white-space: pre-wrap; border: 1px solid var(--border-color); margin-top: 10px; box-shadow: inset 0 0 5px rgba(0,0,0,0.2); }
    .peditx-status { padding: 15px; margin-top: 20px; background-color: var(--card-bg); border-radius: 8px; text-align: center; font-weight: bold; border: 1px solid var(--border-color); color: var(--warning-color); }
    
    .input-group { display: flex; flex-direction: column; gap: 10px; margin-top: 15px; }
    .cbi-input-text, .cbi-input-password, .cbi-input-select, textarea.cbi-input-text { background-color: var(--bg-color); border: 1px solid var(--border-color); color: var(--text-color); padding: 10px; border-radius: 5px; width: 100%; box-sizing: border-box; transition: border-color 0.3s, box-shadow 0.3s; }
    .cbi-input-text:focus, .cbi-input-password:focus, .cbi-input-select:focus, textarea.cbi-input-text:focus { outline: none; border-color: var(--secondary-color); box-shadow: 0 0 0 3px rgba(255, 121, 198, 0.2); }
    
    .pkg-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(250px, 1fr)); gap: 10px; margin-top: 15px; }
    .pkg-item { background: var(--card-bg); padding: 10px; border-radius: 8px; display: flex; align-items: center; border: 1px solid var(--border-color); transition: background 0.2s; }
    .pkg-item:hover { background: var(--hover-color); }
    
    .sub-section { background-color: var(--card-bg); border: 1px solid var(--border-color); padding: 20px; border-radius: 8px; margin-top: 20px; }
    
    .log-controls { display: flex; justify-content: flex-end; align-items: center; margin-top: 20px; gap: 10px; flex-wrap: wrap; }
    .log-controls .cbi-button { font-size: 12px; padding: 8px 15px; border-radius: 5px; background-color: var(--hover-color); color: var(--text-color); border: 1px solid var(--border-color); transition: background 0.2s, border-color 0.2s; cursor: pointer; }
    .log-controls .cbi-button:hover { background-color: var(--card-bg); border-color: var(--secondary-color); }
    #logout-button { background: var(--secondary-color); color: var(--bg-color); border-color: var(--secondary-color); }
    #logout-button:hover { background: #ff95d6; border-color: #ff95d6; }
    .log-controls label { margin-right: 10px; cursor: pointer; user-select: none; }
    .log-controls input[type="checkbox"] { vertical-align: middle; margin-right: 5px; accent-color: var(--secondary-color); }
    
    .peditx-modal { display: none; position: fixed; z-index: 100; left: 0; top: 0; width: 100%; height: 100%; overflow: auto; background-color: rgba(0,0,0,0.6); backdrop-filter: blur(5px); -webkit-backdrop-filter: blur(5px); }
    .peditx-modal-content { background-color: var(--card-bg); color: var(--text-color); margin: 15% auto; padding: 30px; border: 1px solid var(--border-color); width: 90%; max-width: 450px; border-radius: 12px; box-shadow: 0 8px 20px rgba(0,0,0,0.5); }
    .peditx-modal-buttons { display: flex; justify-content: flex-end; gap: 10px; margin-top: 20px; }
    .peditx-modal-buttons .cbi-button { padding: 10px 20px; border-radius: 8px; }
    #peditx-modal-yes { background-color: var(--primary-color); color: var(--bg-color); }
    #peditx-modal-no { background-color: var(--hover-color); }

    @media (max-width: 768px) {
        .peditx-tab-link { padding: 12px 10px; font-size: 14px; margin-right: 2px; }
        .peditx-header h2 { font-size: 20px; }
        .peditx-header p { font-size: 14px; }
    }
</style>

<div id="peditx-confirm-modal" class="peditx-modal">
    <div class="peditx-modal-content">
        <p id="peditx-modal-text"></p>
        <div class="peditx-modal-buttons">
            <button id="peditx-modal-yes" class="cbi-button">Yes</button>
            <button id="peditx-modal-no" class="cbi-button">No</button>
        </div>
    </div>
</div>

<div class="cbi-map">
    <div class="peditx-header">
        <h2>PeDitXOS Dashboard</h2>
        <p>Your central command for managing and optimizing the system.</p>
    </div>
    <div class="peditx-tabs">
        <button class="peditx-tab-link active" onclick="showTab(event, 'main-tools')">Main Tools</button>
        <button class="peditx-tab-link" onclick="showTab(event, 'dns-changer')">DNS Changer</button>
        <button class="peditx-tab-link" onclick="showTab(event, 'commander')">Commander</button>
        <button class="peditx-tab-link" onclick="showTab(event, 'extra-tools')">Extra Tools</button>
        <button class="peditx-tab-link" onclick="showTab(event, 'x86-pi-opts')">x86/Pi Opts</button>
    </div>

    <div id="main-tools" class="peditx-tab-content" style="display:block;">
        <div class="action-grid">
            <div class="action-item"><input type="radio" name="peditx_action" id="action_install_pw1" value="install_pw1"><label for="action_install_pw1">Install Passwall 1</label></div>
            <div class="action-item"><input type="radio" name="peditx_action" id="action_install_pw2" value="install_pw2"><label for="action_install_pw2">Install Passwall 2</label></div>
            <div class="action-item"><input type="radio" name="peditx_action" id="action_install_both" value="install_both"><label for="action_install_both">Install Passwall 1 + 2</label></div>
            <div class="action-item"><input type="radio" name="peditx_action" id="action_easy_exroot" value="easy_exroot"><label for="action_easy_exroot">Easy Exroot</label></div>
            <div class="action-item"><input type="radio" name="peditx_action" id="action_uninstall_all" value="uninstall_all" data-confirm="This will remove all related packages and PeDitXOS Tools itself. Are you sure?"><label for="action_uninstall_all">Uninstall All Tools</label></div>
        </div>
    </div>
    <div id="dns-changer" class="peditx-tab-content">
        <div class="action-grid">
            <div class="action-item"><input type="radio" name="peditx_action" id="action_set_dns_shecan" value="set_dns_shecan"><label for="action_set_dns_shecan">Shecan</label></div>
            <div class="action-item"><input type="radio" name="peditx_action" id="action_set_dns_electro" value="set_dns_electro"><label for="action_set_dns_electro">Electro</label></div>
            <div class="action-item"><input type="radio" name="peditx_action" id="action_set_dns_cloudflare" value="set_dns_cloudflare"><label for="action_set_dns_cloudflare">Cloudflare</label></div>
            <div class="action-item"><input type="radio" name="peditx_action" id="action_set_dns_google" value="set_dns_google"><label for="action_set_dns_google">Google</label></div>
            <div class="action-item"><input type="radio" name="peditx_action" id="action_set_dns_begzar" value="set_dns_begzar"><label for="action_set_dns_begzar">Begzar</label></div>
            <div class="action-item"><input type="radio" name="peditx_action" id="action_set_dns_radar" value="set_dns_radar"><label for="action_set_dns_radar">Radar</label></div>
        </div>
        <div class="action-item" style="margin-top: 15px;"><input type="radio" name="peditx_action" id="action_set_dns_custom" value="set_dns_custom"><label for="action_set_dns_custom">Custom DNS</label></div>
        <div class="input-group">
            <input class="cbi-input-text" type="text" id="custom_dns1" placeholder="Custom DNS 1">
            <input class="cbi-input-text" type="text" id="custom_dns2" placeholder="Custom DNS 2 (Optional)">
        </div>
    </div>
    <div id="commander" class="peditx-tab-content">
        <div class="sub-section">
            <h4>Welcome to the Commander!</h4>
            <p>This tab provides direct, root-level access to the system's command line.</p>
            <ul style="list-style-type: disc; padding-left: 20px; margin: 10px 0;">
                <li><b>Login:</b> Use your router's username (usually <code>root</code>) and password.</li>
                <li><b>Pasting Commands:</b> Use <code>Ctrl+Shift+V</code> (Windows/Linux) or <code>Cmd+V</code> (Mac) to paste commands. Right-clicking may also work depending on your browser.</li>
            </ul>
            <p style="color: var(--danger-color);"><b>Warning:</b> Commands executed here can permanently alter your system configuration and cause instability. Proceed with caution.</p>
            <div id="ttyd-placeholder" style="text-align: center; padding: 20px; color: var(--warning-color);">Loading Terminal...</div>
            <iframe id="ttyd-iframe" style="width: 100%; height: 500px; border: 1px solid var(--border-color); border-radius: 8px; margin-top: 15px; display: none;">
            </iframe>
        </div>
    </div>
    <div id="extra-tools" class="peditx-tab-content">
        <div class="sub-section">
            <h4>WiFi Settings</h4>
            <div class="action-item"><input type="radio" name="peditx_action" id="action_set_wifi_config" value="set_wifi_config"><label for="action_set_wifi_config">Apply WiFi Settings Below</label></div>
            <div class="input-group">
                <input class="cbi-input-text" type="text" id="wifi_ssid" placeholder="WiFi Name (SSID)">
                <input class="cbi-input-password" type="password" id="wifi_key" placeholder="WiFi Password">
                <div style="display: flex; gap: 20px; margin-top: 5px;">
                    <label><input type="checkbox" id="wifi_band_2g" checked> Enable 2.4GHz</label>
                    <label><input type="checkbox" id="wifi_band_5g" checked> Enable 5GHz</label>
                </div>
            </div>
        </div>
        <div class="sub-section">
            <h4>LAN IP Changer</h4>
            <div class="action-item"><input type="radio" name="peditx_action" id="action_set_lan_ip" value="set_lan_ip"><label for="action_set_lan_ip">Set LAN IP Address Below</label></div>
            <div class="input-group">
                <select id="lan_ip_preset" class="cbi-input-select" onchange="document.getElementById('custom_lan_ip').value = this.value">
                    <option value="10.1.1.1">Default (10.1.1.1)</option>
                    <option value="192.168.1.1">192.168.1.1</option>
                    <option value="11.1.1.1">11.1.1.1</option>
                    <option value="192.168.0.1">192.168.0.1</option>
                    <option value="">Custom</option>
                </select>
                <input class="cbi-input-text" type="text" id="custom_lan_ip" placeholder="Custom LAN IP">
            </div>
        </div>
        <div class="sub-section">
            <h4>Extra Package Installer</h4>
            <div class="action-item"><input type="radio" name="peditx_action" id="action_install_extra_packages" value="install_extra_packages"><label for="action_install_extra_packages">Install Selected Packages Below</label></div>
            <div class="log-controls">
                <button class="cbi-button cbi-button-action" onclick="startActionByName('opkg_update')">Update Package Lists</button>
            </div>
            <div class="pkg-grid">
                <div class="pkg-item"><input type="checkbox" name="extra_pkg" id="pkg_sing-box" value="sing-box"><label for="pkg_sing-box">Sing-Box</label></div>
                <div class="pkg-item"><input type="checkbox" name="extra_pkg" id="pkg_haproxy" value="haproxy"><label for="pkg_haproxy">HAProxy</label></div>
                <div class="pkg-item"><input type="checkbox" name="extra_pkg" id="pkg_v2ray-core" value="v2ray-core"><label for="pkg_v2ray-core">V2Ray Core</label></div>
                <div class="pkg-item"><input type="checkbox" name="extra_pkg" id="pkg_luci-app-v2raya" value="luci-app-v2raya"><label for="pkg_luci-app-v2raya">V2RayA App</label></div>
                <div class="pkg-item"><input type="checkbox" name="extra_pkg" id="pkg_luci-app-openvpn" value="luci-app-openvpn"><label for="pkg_luci-app-openvpn">OpenVPN App</label></div>
                <div class="pkg-item"><input type="checkbox" name="extra_pkg" id="pkg_softethervpn5-client" value="softethervpn5-client"><label for="pkg_softethervpn5-client">SoftEther Client</label></div>
                <div class="pkg-item"><input type="checkbox" name="extra_pkg" id="pkg_luci-app-wol" value="luci-app-wol"><label for="pkg_luci-app-wol">Wake-on-LAN App</label></div>
                <div class="pkg-item"><input type="checkbox" name="extra_pkg" id="pkg_luci-app-smartdns" value="luci-app-smartdns"><label for="pkg_luci-app-smartdns">SmartDNS App</label></div>
                <div class="pkg-item"><input type="checkbox" name="extra_pkg" id="pkg_hysteria" value="hysteria"><label for="pkg_hysteria">Hysteria</label></div>
                <div class="pkg-item"><input type="checkbox" name="extra_pkg" id="pkg_btop" value="btop"><label for="pkg_btop">btop</label></div>
            </div>
        </div>
    </div>
    <div id="x86-pi-opts" class="peditx-tab-content">
        <div class="action-grid">
            <div class="action-item"><input type="radio" name="peditx_action" id="action_get_system_info" value="get_system_info"><label for="action_get_system_info">Get System Info</label></div>
            <div class="action-item"><input type="radio" name="peditx_action" id="action_install_opt_packages" value="install_opt_packages"><label for="action_install_opt_packages">Install Opt Packages</label></div>
            <div class="action-item"><input type="radio" name="peditx_action" id="action_apply_cpu_opts" value="apply_cpu_opts"><label for="action_apply_cpu_opts">Apply CPU Opts</label></div>
            <div class="action-item"><input type="radio" name="peditx_action" id="action_apply_mem_opts" value="apply_mem_opts"><label for="action_apply_mem_opts">Apply Memory Opts</label></div>
            <div class="action-item"><input type="radio" name="peditx_action" id="action_apply_net_opts" value="apply_net_opts"><label for="action_apply_net_opts">Apply Network Opts</label></div>
            <div class="action-item"><input type="radio" name="peditx_action" id="action_apply_usb_opts" value="apply_usb_opts"><label for="action_apply_usb_opts">Apply USB Opts</label></div>
            <div class="action-item"><input type="radio" name="peditx_action" id="action_enable_luci_wan" value="enable_luci_wan" data-confirm="SECURITY WARNING: This will expose your router's web interface to the Internet! Continue?"><label for="action_enable_luci_wan">Enable LuCI on WAN</label></div>
            <div class="action-item"><input type="radio" name="peditx_action" id="action_expand_root" value="expand_root" data-confirm="CRITICAL WARNING: This will WIPE ALL DATA on your storage device! Are you absolutely sure?"><label for="action_expand_root">Expand Root Partition</label></div>
            <div class="action-item"><input type="radio" name="peditx_action" id="action_restore_opt_backup" value="restore_opt_backup"><label for="action_restore_opt_backup">Restore Config Backup</label></div>
            <div class="action-item"><input type="radio" name="peditx_action" id="action_reboot_system" value="reboot_system" data-confirm="Reboot the system now?"><label for="action_reboot_system">Reboot System</button></div>
        </div>
    </div>

    <div class="execute-bar">
        <button id="execute-button" class="peditx-main-button">Start</button>
        <button id="stop-button" class="peditx-main-button" style="display:none;">Stop</button>
    </div>

    <div id="peditx-status" class="peditx-status">Ready. Select an action and press Start.</div>
    <div class="log-controls">
		<label for="auto-refresh-toggle"><input type="checkbox" id="auto-refresh-toggle" checked> Auto Refresh</label>
        <button class="cbi-button" onclick="pollStatus(true)">Refresh Log</button>
        <button class="cbi-button" onclick="clearLog()">Clear Log</button>
        <button id="logout-button" class="cbi-button">Logout</button>
    </div>
    <pre id="log-output" class="peditx-log-container">Welcome to PeDitXOS Tools!</pre>
</div>
<script type="text/javascript">
    var modalCallback;
    var isPolling = false;
    var modal = document.getElementById('peditx-confirm-modal');
    var modalText = document.getElementById('peditx-modal-text');
    var modalYes = document.getElementById('peditx-modal-yes');
    var modalNo = document.getElementById('peditx-modal-no');
    var startButton = document.getElementById('execute-button');
    var stopButton = document.getElementById('stop-button');
    var statusDiv = document.getElementById('peditx-status');
    var logOutput = document.getElementById('log-output');
    var autoRefreshToggle = document.getElementById('auto-refresh-toggle');
    var statusURL = '<%=luci.dispatcher.build_url("admin", "peditxos", "status")%>';
    var runURL = '<%=luci.dispatcher.build_url("admin", "peditxos", "run")%>';
    
    var ttydInfoURL = '<%=luci.dispatcher.build_url("admin", "peditxos", "get_ttyd_info")%>';
    var ttydIframe = document.getElementById('ttyd-iframe');
    var ttydPlaceholder = document.getElementById('ttyd-placeholder');
    var ttydLoaded = false;

    function showTab(evt, tabName) {
        var i, tabcontent, tablinks;
        tabcontent = document.getElementsByClassName("peditx-tab-content");
        for (i = 0; i < tabcontent.length; i++) { tabcontent[i].style.display = "none"; }
        tablinks = document.getElementsByClassName("peditx-tab-link");
        for (i = 0; i < tablinks.length; i++) { tablinks[i].className = tablinks[i].className.replace(" active", ""); }
        document.getElementById(tabName).style.display = "block";
        evt.currentTarget.className += " active";
        
        if (tabName === 'commander' && !ttydLoaded) {
            loadTtydTerminal();
        }
    }
    
    function loadTtydTerminal() {
        XHR.get(ttydInfoURL, null, function(x, data) {
            if (x && x.status === 200 && data) {
                var protocol = data.ssl ? 'https://' : 'http://';
                var ttydUrl = protocol + window.location.hostname + ':' + data.port;
                ttydIframe.src = ttydUrl;
                ttydPlaceholder.style.display = 'none';
                ttydIframe.style.display = 'block';
                ttydLoaded = true;
            } else {
                ttydPlaceholder.innerText = 'Error: Could not load TTYD configuration. Please ensure luci-app-ttyd is installed and configured.';
            }
        });
    }

    function showConfirmModal(message, callback) {
        modalText.innerText = message;
        modal.style.display = 'block';
        modalCallback = callback;
    }

    modalYes.onclick = function() {
        modal.style.display = 'none';
        if (modalCallback) modalCallback(true);
    };

    modalNo.onclick = function() {
        modal.style.display = 'none';
        if (modalCallback) modalCallback(false);
    };

    function pollStatus(force) {
        if (isPolling && !force) return;

        XHR.poll(2, statusURL, null, function(x, data) {
            if (!x || x.status !== 200 || !data) {
                XHR.poll.stop();
                isPolling = false;
                return;
            }

            if (logOutput.textContent !== data.log) {
                logOutput.textContent = data.log;
                logOutput.scrollTop = logOutput.scrollHeight;
            }
            
            if (data.running) {
                isPolling = true;
                startButton.disabled = true;
                startButton.style.display = 'none';
                stopButton.style.display = 'inline-flex';
            } else {
                if (!autoRefreshToggle.checked) {
                    XHR.poll.stop();
                }
                isPolling = false;
                startButton.disabled = false;
                startButton.style.display = 'inline-flex';
                stopButton.style.display = 'none';
            }
        });
    }
    
    function clearLog() {
        XHR.get(runURL, { action: 'clear_log' }, function(x, data) {
            if (x && x.status === 200) {
                pollStatus(true);
            }
        });
    }

    function startActionByName(actionName, params) {
        params = params || {};
        params.action = actionName;

        XHR.get(runURL, params, function(x, data) {
            if (x && x.status === 200 && data.success) {
                statusDiv.innerText = 'Starting ' + actionName + '...';
                pollStatus(true);
            } else {
                statusDiv.innerText = 'Error starting action: ' + (data ? data.error : 'Unknown');
            }
        });
    }

    startButton.addEventListener('click', function() {
        var selectedActionInput = document.querySelector('input[name="peditx_action"]:checked');
        if (!selectedActionInput) {
            showConfirmModal('Please select an action first.', function(result) {});
            return;
        }

        var action = selectedActionInput.value;
        var confirmationMessage = selectedActionInput.getAttribute('data-confirm');
        
        var doStart = function() {
            var params = {};
            if (action === 'set_dns_custom') {
                var dns1 = document.getElementById('custom_dns1').value.trim();
                if (!dns1) {
                    showConfirmModal('Please enter at least the first DNS IP.', function(result) {});
                    return;
                }
                params.dns1 = dns1;
                params.dns2 = document.getElementById('custom_dns2').value.trim();
            } else if (action === 'install_extra_packages' || action === 'install_opt_packages') {
                var selectedPkgs = Array.from(document.querySelectorAll('input[name="extra_pkg"]:checked')).map(cb => cb.value);
                if (selectedPkgs.length === 0 && action === 'install_extra_packages') {
                    showConfirmModal('Please select at least one extra package to install.', function(result) {});
                    return;
                }
                params.packages = selectedPkgs.join(' ');
            } else if (action === 'set_wifi_config') {
                params.ssid = document.getElementById('wifi_ssid').value.trim();
                params.key = document.getElementById('wifi_key').value;
                var band2g = document.getElementById('wifi_band_2g').checked;
                var band5g = document.getElementById('wifi_band_5g').checked;
                if (!params.ssid || !params.key) {
                    showConfirmModal('Please enter WiFi SSID and Password.', function(result) {});
                    return;
                }
                if (!band2g && !band5g) {
                    showConfirmModal('Please select at least one WiFi band to enable.', function(result) {});
                    return;
                }
                params.band = (band2g && band5g) ? 'Both' : (band2g ? '2G' : '5G');
            } else if (action === 'set_lan_ip') {
				var presetIp = document.getElementById('lan_ip_preset').value;
				var customIp = document.getElementById('custom_lan_ip').value.trim();
				var finalIp = (presetIp !== "") ? presetIp : customIp;

				if (!finalIp) {
					showConfirmModal('Please select a preset or enter a custom LAN IP address.', function(result) {});
					return;
				}
				params.ipaddr = finalIp.replace(/\s/g, '');
            }
            startActionByName(action, params);
        };

        if (confirmationMessage) {
            showConfirmModal(confirmationMessage, function(result) {
                if (result) {
                    doStart();
                }
            });
        } else {
            doStart();
        }
    });

    stopButton.addEventListener('click', function() {
        statusDiv.innerText = 'Stopping process...';
        XHR.get(runURL, { action: 'stop_process' }, function(x, data) {
            if (x && x.status === 200 && data.success) {
                pollStatus(true);
            } else {
                statusDiv.innerText = 'Error stopping process.';
            }
        });
    });

    autoRefreshToggle.addEventListener('change', function() {
		if (this.checked) {
            statusDiv.innerText = 'Auto-refresh enabled.';
			pollStatus(true);
		} else {
            statusDiv.innerText = 'Auto-refresh disabled.';
			XHR.poll.stop();
		}
	});

    document.getElementById('logout-button').addEventListener('click', function() {
        window.location.href = '<%=luci.dispatcher.build_url("admin", "logout")%>';
    });

	document.getElementById('custom_lan_ip').value = document.getElementById('lan_ip_preset').value;
    pollStatus(true);
</script>
<%+footer%>
EOF

echo ">>> All files have been created."

# --- 3. Download External Files ---
echo "--> Downloading external configuration files..."

# Profile scripts
curl -L "https://raw.githubusercontent.com/peditx/PeDitXOs/refs/heads/main/.files/profile" -o files/etc/profile
curl -L "https://raw.githubusercontent.com/peditx/PeDitXOs/refs/heads/main/.files/30-sysinfo.sh" -o files/etc/profile.d/30-sysinfo.sh
curl -L "https://raw.githubusercontent.com/peditx/PeDitXOs/refs/heads/main/.files/sys_bashrc.sh" -o files/etc/profile.d/sys_bashrc.sh

# Store (Service Installer) files
curl -L "https://raw.githubusercontent.com/peditx/PeDitXOs/refs/heads/main/services/serviceinstaller.lua" -o files/usr/lib/lua/luci/controller/serviceinstaller.lua
curl -L "https://raw.githubusercontent.com/peditx/PeDitXOs/refs/heads/main/services/main.htm" -o files/usr/lib/lua/luci/view/serviceinstaller/main.htm

# Passwall repository key
curl -L "https://repo.peditxdl.ir/passwall-packages/passwall.pub" -o custom-keys/passwall.pub

echo "    ...external files downloaded successfully."

# --- 4. Set Execute Permissions ---
echo "--> Setting execute permissions for scripts..."
chmod +x files/etc/uci-defaults/99-peditxos-defaults
chmod +x files/usr/bin/peditx_runner.sh
chmod +x files/etc/profile.d/30-sysinfo.sh
chmod +x files/etc/profile.d/sys_bashrc.sh
echo "    ...permissions set."

# --- Final Instructions ---
echo ""
echo "=============================================================================="
echo "✅ PeDitXOS Repository Setup is Complete!"
echo "=============================================================================="
echo ""
echo "Next Steps:"
echo "1. Initialize a git repository in this directory: git init"
echo "2. Add all the newly created files: git add ."
echo "3. Create your first commit: git commit -m \"Initial project setup\""
echo "4. Add your remote GitHub repository: git remote add origin <your_repo_url>"
echo "5. Push the files to GitHub: git push -u origin main"
echo ""
echo "Remember to configure your repository secrets (GITHUB_PAT, SF_USERNAME, etc.)"
echo "in the GitHub settings for the workflow to run correctly."
echo ""
