# scripts/process_devices.py
import requests
import json
import os

# The official URL for the OpenWrt firmware selector API data
API_URL = "https://sysupgrade.openwrt.org/api/v1/devices"
OUTPUT_FILE = "devices.json"

def fetch_and_process_devices():
    """
    Fetches the complete list of devices from the OpenWrt API,
    processes it into a simplified format, and saves it to a JSON file.
    """
    print("Fetching device list from OpenWrt API...")
    try:
        response = requests.get(API_URL, timeout=60)
        response.raise_for_status()  # Raise an exception for bad status codes
        data = response.json()
    except requests.exceptions.RequestException as e:
        print(f"Error: Could not fetch data from API. {e}")
        return

    print("Processing device data...")
    processed_devices = []
    
    # The API returns a dictionary where keys are device IDs and values are device details
    for device_id, details in data.get('devices', {}).items():
        # We only care about devices that have at least one release image
        if not details.get('images'):
            continue

        # Find the latest stable release for this device
        latest_release = details.get('supported_releases', {}).get('stable')
        if not latest_release:
            continue

        # Extract architecture from the first image link (it's consistent)
        first_image_url = details['images'][0].get('name', '')
        # Example url part: openwrt-23.05.3-ath79-generic-tplink_archer-c7-v5-squashfs-sysupgrade.bin
        # We need the architecture part, which is in the target.
        # The API provides the target directly.
        target_info = details.get('target', '') # e.g., "ath79/generic"
        arch = target_info.split('/')[0] if '/' in target_info else target_info

        processed_devices.append({
            "title": details.get('title', 'Unknown Device'),
            "target": target_info,
            "profile": device_id,
            "version": latest_release,
            "arch": arch # We save the architecture directly
        })

    # Sort the list alphabetically by title for a better user experience
    processed_devices.sort(key=lambda x: x['title'])

    print(f"Successfully processed {len(processed_devices)} devices.")

    # Save the processed list to the output file
    try:
        with open(OUTPUT_FILE, 'w', encoding='utf-8') as f:
            json.dump(processed_devices, f, ensure_ascii=False, indent=2)
        print(f"Device list saved to {OUTPUT_FILE}")
    except IOError as e:
        print(f"Error: Could not write to file {OUTPUT_FILE}. {e}")

if __name__ == "__main__":
    fetch_and_process_devices()
