# scripts/process_devices.py
import requests
import json
import sys

# This URL is stable and provides the list of available releases.
RELEASES_INFO_URL = "https://firmware-selector.openwrt.org/data/releases.json"
OUTPUT_FILE = "devices.json"

def fetch_all_stable_devices():
    """
    Fetches data for ALL stable releases by discovering their data files dynamically,
    combines them, and saves the result to a single JSON file.
    This is the most robust method as it mimics the official firmware selector.
    """
    print(f"--> Fetching release information from {RELEASES_INFO_URL}...")
    try:
        response = requests.get(RELEASES_INFO_URL, timeout=30)
        response.raise_for_status()
        releases = response.json()
    except requests.exceptions.RequestException as e:
        print(f"!!! ERROR: Could not fetch release info. {e}")
        sys.exit(1)

    all_processed_devices = []
    
    # Filter for all stable releases from version 21 onwards
    stable_releases_to_process = [
        r for r in releases 
        if r.get('stable') and any(r.get('version', '').startswith(v) for v in ['21.', '22.', '23.', '24.'])
    ]

    if not stable_releases_to_process:
        print("!!! ERROR: No stable releases found to process (v21-v24).")
        sys.exit(1)

    print(f"--> Found {len(stable_releases_to_process)} stable release(s) to process.")

    for release in stable_releases_to_process:
        version = release.get('version')
        # This is the key: construct the URL to the targets.json for each version
        targets_url = f"https://downloads.openwrt.org/releases/{version}/targets/targets.json"
        
        print(f"\n--- Processing version: {version} from {targets_url} ---")
        
        try:
            print(f"--> Fetching targets data for version {version}...")
            response = requests.get(targets_url, timeout=120)
            response.raise_for_status()
            targets_data = response.json()
            print(f"--> Successfully fetched targets data for {version}.")
        except requests.exceptions.RequestException as e:
            print(f"!!! WARNING: Could not fetch targets data for version {version}. Skipping. Error: {e}")
            continue # Skip to the next version if one fails

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
    
    print(f"\n>>> Successfully processed a total of {len(all_processed_devices)} device entries across all versions.")

    try:
        with open(OUTPUT_FILE, 'w', encoding='utf-8') as f:
            json.dump(all_processed_devices, f, ensure_ascii=False, indent=2)
        print(f">>> Combined device list saved successfully to {OUTPUT_FILE}")
    except IOError as e:
        print(f"!!! ERROR: Could not write to file {OUTPUT_FILE}. {e}")
        sys.exit(1)

if __name__ == "__main__":
    fetch_all_stable_devices()
