# scripts/process_devices.py
import requests
import json
import sys
import re
from html.parser import HTMLParser
import subprocess

# This is the most robust starting point: the main releases directory page.
RELEASES_PAGE_URL = "https://downloads.openwrt.org/releases/"
# We will support these major versions. The script will find the latest point release for each.
SUPPORTED_MAJOR_VERSIONS = ["24.10", "23.05", "22.03", "21.02"]
OUTPUT_FILE = "devices.json"

class LinkFinder(HTMLParser):
    """A simple HTML parser to find links in a directory listing page."""
    def __init__(self):
        super().__init__()
        self.links = []
    def handle_starttag(self, tag, attrs):
        if tag == 'a':
            for attr, value in attrs:
                if attr == 'href':
                    # We only care about directory links
                    if value.endswith('/'):
                        self.links.append(value)

def get_latest_point_releases():
    """
    Scrapes the main releases page to find the latest point release for each
    major version we support. This is the most robust method.
    """
    print(f"--> Scraping release versions from {RELEASES_PAGE_URL}...")
    try:
        response = requests.get(RELEASES_PAGE_URL, timeout=30)
        response.raise_for_status()
        parser = LinkFinder()
        parser.feed(response.text)
    except requests.exceptions.RequestException as e:
        print(f"!!! ERROR: Could not scrape release page. {e}")
        return {}

    latest_releases = {}
    version_pattern = re.compile(r'^(\d+\.\d+\.\d+)/$')
    
    for link in parser.links:
        match = version_pattern.match(link)
        if match:
            full_version = match.group(1)
            major_version = '.'.join(full_version.split('.')[:2])
            
            if major_version in SUPPORTED_MAJOR_VERSIONS:
                if major_version not in latest_releases or full_version > latest_releases[major_version]:
                    latest_releases[major_version] = full_version
    
    if not latest_releases:
        print("!!! ERROR: No matching release versions found on the page.")
        return {}
        
    print(f"--> Found latest point releases: {latest_releases}")
    return latest_releases

def get_subdirectories(url):
    """Fetches an HTML directory listing and returns a list of subdirectories."""
    try:
        response = requests.get(url, timeout=30)
        response.raise_for_status()
        parser = LinkFinder()
        parser.feed(response.text)
        # Exclude 'Parent Directory' and other irrelevant links
        return [link for link in parser.links if not link.startswith('?') and link != '/']
    except requests.exceptions.RequestException:
        return []

def fetch_all_devices_from_structure(latest_releases):
    """
    Iterates through the discovered stable releases, scrapes their directory structure
    to find all profiles.json files, and builds a comprehensive device list.
    """
    all_processed_devices = []
    
    if not latest_releases:
        print("!!! ERROR: No stable releases found to process.")
        sys.exit(1)

    for major_version, version in latest_releases.items():
        targets_base_url = f"https://downloads.openwrt.org/releases/{version}/targets/"
        print(f"\n--- Processing version: {version} ---")
        
        targets = get_subdirectories(targets_base_url)
        if not targets:
            print(f"!!! WARNING: No targets found for version {version}. Skipping.")
            continue

        version_device_count = 0
        for target_dir in targets:
            subtargets = get_subdirectories(f"{targets_base_url}{target_dir}")
            for subtarget_dir in subtargets:
                target_path = f"{target_dir.strip('/')}/{subtarget_dir.strip('/')}"
                profiles_url = f"{targets_base_url}{target_path}/profiles.json"
                
                try:
                    response = requests.get(profiles_url, timeout=60)
                    if response.status_code == 404:
                        continue
                    response.raise_for_status()
                    profiles_data = response.json()
                except (requests.exceptions.RequestException, json.JSONDecodeError):
                    continue
                
                arch = profiles_data.get('arch_packages')
                profiles = profiles_data.get('profiles', {}) # Expect a dictionary
                
                if not all([arch, profiles]) or not isinstance(profiles, dict):
                    continue

                # --- CORRECTED LOGIC ---
                # Iterate over the key-value pairs of the profiles dictionary
                for profile_id, device_details in profiles.items():
                    title = device_details.get('title')
                    
                    if not all([title, profile_id]):
                        continue

                    all_processed_devices.append({
                        "title": title,
                        "target": target_path,
                        "profile": profile_id, # The key is the profile ID
                        "version": version,
                        "arch": arch
                    })
                    version_device_count += 1
        
        print(f"--> Processed {version_device_count} devices for version {version}.")

    if not all_processed_devices:
        print("!!! ERROR: No devices were processed across all versions.")
        sys.exit(1)

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
    stable_versions = get_latest_point_releases()
    if stable_versions:
        fetch_all_devices_from_structure(stable_versions)
    else:
        print("!!! FATAL: Could not proceed without a list of stable versions.")
        sys.exit(1)
