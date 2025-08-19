# scripts/process_devices.py
import requests
import json
import sys
import subprocess

# This is the most robust starting point: the main releases directory.
RELEASES_PAGE_URL = "https://downloads.openwrt.org/releases/"
OUTPUT_FILE = "devices.json"

def get_stable_release_versions():
    """
    Uses the user-provided shell command pipeline to scrape the releases page
    and get a list of all available version strings. This is the most robust method.
    """
    print(f"--> Scraping release versions from {RELEASES_PAGE_URL}...")
    
    # The brilliant command provided by the user
    command = """
    curl -s https://downloads.openwrt.org/releases/ | \
    grep -oP '(?<=href=")[0-9]+\.[0-9]+\.[0-9]+/' | \
    sed 's:/$::' | \
    jq -R . | \
    jq -s .
    """
    
    try:
        # Execute the command in a shell
        result = subprocess.run(command, shell=True, capture_output=True, text=True, check=True)
        versions = json.loads(result.stdout)
        
        # Filter for the major versions we want to support
        supported_versions = [
            v for v in versions 
            if any(v.startswith(major) for major in ["21.", "22.", "23.", "24."])
        ]
        
        print(f"--> Found {len(supported_versions)} relevant stable release(s).")
        return sorted(supported_versions, reverse=True)
        
    except (subprocess.CalledProcessError, json.JSONDecodeError) as e:
        print(f"!!! ERROR: Failed to scrape release versions. {e}")
        return []

def fetch_all_devices_from_structure(versions_to_process):
    """
    Iterates through the discovered stable releases and their targets to build
    a comprehensive device list.
    """
    all_processed_devices = []
    
    for version in versions_to_process:
        targets_url = f"https://downloads.openwrt.org/releases/{version}/targets/targets.json"
        
        print(f"\n--- Processing version: {version} from {targets_url} ---")
        
        try:
            print(f"--> Fetching targets list for version {version}...")
            response = requests.get(targets_url, timeout=60)
            response.raise_for_status()
            targets_data = response.json()
        except requests.exceptions.RequestException as e:
            print(f"!!! WARNING: Could not fetch targets for version {version}. Skipping. Error: {e}")
            continue

        if not isinstance(targets_data, list):
            print(f"!!! WARNING: Expected a list of targets for version {version}. Skipping.")
            continue

        version_device_count = 0
        for target_info in targets_data:
            target_path = target_info.get('path')
            arch = target_info.get('arch_packages')
            profiles = target_info.get('profiles', [])

            if not all([target_path, arch, profiles]):
                continue

            for device in profiles:
                title = device.get('title')
                profile_id = device.get('profile')
                
                if not all([title, profile_id]):
                    continue

                all_processed_devices.append({
                    "title": title,
                    "target": target_path,
                    "profile": profile_id,
                    "version": version,
                    "arch": arch
                })
                version_device_count += 1
        
        print(f"--> Processed {version_device_count} devices for version {version}.")

    if not all_processed_devices:
        print("!!! ERROR: No devices were processed across all versions.")
        sys.exit(1)

    # Sort the final combined list by title, then by version descending
    all_processed_devices.sort(key=lambda x: (x['title'], x['version']), reverse=True)
    
    print(f"\n>>> Successfully processed a total of {len(all_processed_devices)} device entries.")

    try:
        with open(OUTPUT_FILE, 'w', encoding='utf-8') as f:
            json.dump(all_processed_devices, f, ensure_ascii=False, indent=2)
        print(f">>> Combined device list saved successfully to {OUTPUT_FILE}")
    except IOError as e:
        print(f"!!! ERROR: Could not write to file {OUTPUT_FILE}. {e}")
        sys.exit(1)

if __name__ == "__main__":
    stable_versions = get_stable_release_versions()
    if stable_versions:
        fetch_all_devices_from_structure(stable_versions)
    else:
        print("!!! FATAL: Could not proceed without a list of stable versions.")
        sys.exit(1)
