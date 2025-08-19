# scripts/process_devices.py
import requests
import json
import sys # Import sys to exit with an error code

# FINAL CORRECT URL: This is the data source for the official firmware selector.
API_URL = "https://firmware-selector.openwrt.org/data/models.json"
OUTPUT_FILE = "devices.json"

def fetch_and_process_devices():
    """
    Fetches the complete list of devices from the OpenWrt firmware selector data,
    processes it into a simplified format, and saves it to a JSON file.
    """
    print(f"--> Fetching device list from new URL: {API_URL}...")
    try:
        response = requests.get(API_URL, timeout=90) # Increased timeout for larger file
        response.raise_for_status()  # Raise an exception for bad status codes
        data = response.json()
        print("--> Successfully fetched data from API.")
    except requests.exceptions.RequestException as e:
        print(f"!!! ERROR: Could not fetch data from API. {e}")
        sys.exit(1) # Exit with an error code to fail the workflow

    print("--> Processing device data...")
    processed_devices = []
    
    # The new API provides a simple list of models
    models_data = data.get('models', [])
    if not models_data:
        print("!!! WARNING: The 'models' key was not found or is empty in the API response.")
        sys.exit(1)

    for device in models_data:
        # We need devices that have all the necessary information
        title = device.get('title')
        target = device.get('target')
        profile_id = device.get('id')
        version = device.get('version')
        arch = device.get('arch')

        if not all([title, target, profile_id, version, arch]):
            continue # Skip devices with incomplete data

        processed_devices.append({
            "title": title,
            "target": target,
            "profile": profile_id,
            "version": version,
            "arch": arch
        })

    if not processed_devices:
        print("!!! ERROR: No devices were processed. The API might have changed or returned no valid data.")
        sys.exit(1)

    # Sorting is not necessary as the source is already well-sorted
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
