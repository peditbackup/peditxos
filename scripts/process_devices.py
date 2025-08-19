# scripts/process_devices.py
import requests
import json
import sys # Import sys to exit with an error code

# NEW: Updated URL for the OpenWrt device list
API_URL = "https://sysupgrade.openwrt.org/json/v1/devices.json"
OUTPUT_FILE = "devices.json"

def fetch_and_process_devices():
    """
    Fetches the complete list of devices from the OpenWrt API,
    processes it into a simplified format, and saves it to a JSON file.
    """
    print(f"--> Fetching device list from {API_URL}...")
    try:
        response = requests.get(API_URL, timeout=60)
        response.raise_for_status()  # Raise an exception for bad status codes (like 404 or 500)
        data = response.json()
        print("--> Successfully fetched data from API.")
    except requests.exceptions.RequestException as e:
        print(f"!!! ERROR: Could not fetch data from API. {e}")
        sys.exit(1) # Exit with an error code to fail the workflow

    print("--> Processing device data...")
    processed_devices = []
    
    # The new API has a slightly different structure
    devices_data = data.get('devices', {})
    if not devices_data:
        print("!!! WARNING: The 'devices' key was not found or is empty in the API response.")
        sys.exit(1)

    for device_id, details in devices_data.items():
        if not details.get('images'):
            continue

        latest_release = details.get('supported_releases', {}).get('stable')
        if not latest_release:
            continue

        target_info = details.get('target', '')
        # The API provides the architecture directly now, which is more reliable.
        arch = details.get('arch_packages')

        if not target_info or not arch:
            continue # Skip devices with incomplete data

        processed_devices.append({
            "title": details.get('title', 'Unknown Device'),
            "target": target_info,
            "profile": device_id,
            "version": latest_release,
            "arch": arch
        })

    if not processed_devices:
        print("!!! ERROR: No devices were processed. The API might have changed or returned no valid data.")
        sys.exit(1)

    processed_devices.sort(key=lambda x: x['title'])
    print(f"--> Successfully processed {len(processed_devices)} devices.")

    try:
        with open(OUTPUT_FILE, 'w', encoding='utf-8') as f:
            json.dump(processed_devices, f, ensure_ascii=False, indent=2)
        print(f"--> Device list saved successfully to {OUTPUT_FILE}")
    except IOError as e:
        print(f"!!! ERROR: Could not write to file {OUTPUT_FILE}. {e}")
        sys.exit(1)

if __name__ == "__main__":
    fetch_and_process_devices()
