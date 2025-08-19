# scripts/process_devices.py
import requests
import json
import sys
import re
from html.parser import HTMLParser
import gzip
import lzma

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

def fetch_and_decompress_profiles(url_base):
    """
    Tries to fetch profiles.json, then profiles.json.gz, then profiles.json.xz
    and returns the parsed JSON data. This is the robust method suggested by the user.
    """
    # Define the order of attempts: plain, gzip, xz
    attempts = [
        (".json", None),
        (".json.gz", gzip.decompress),
        (".json.xz", lzma.decompress)
    ]
    
    for extension, decompressor in attempts:
        url = url_base + extension
        try:
            resp = requests.get(url, timeout=60)
            if resp.status_code == 200:
                print(f"    ... Found profile data at {url}")
                content = resp.content
                if decompressor:
                    content = decompressor(content)
                return json.loads(content.decode("utf-8"))
        except (requests.exceptions.RequestException, gzip.BadGzipFile, lzma.LZMAError, json.JSONDecodeError):
            # If any error occurs, just try the next format
            continue
    # If all attempts fail, return None
    return None

def fetch_all_devices_from_structure(latest_releases):
    """
    Iterates through the discovered stable releases, scrapes their directory structure
    to find all profiles files (json, json.gz, json.xz), and builds a comprehensive device list.
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
                # We pass the base URL without extension to the helper function
                profiles_url_base = f"{targets_base_url}{target_path}/profiles"
                
                profiles_data = fetch_and_decompress_profiles(profiles_url_base)
                
                if not profiles_data:
                    continue
                
                arch = profiles_data.get('arch_packages')
                profiles = profiles_data.get('profiles')
                
                if not all([arch, profiles]):
                    continue

                # --- FINAL ROBUST PARSING LOGIC (v2) ---
                # This handles the actual structure of the profiles data.
                if isinstance(profiles, dict):
                    # New format (e.g., 23.05): profiles is a dictionary of dictionaries
                    for profile_id, device_details in profiles.items():
                        if isinstance(device_details, dict):
                            # The title is inside a 'titles' list of objects
                            titles_list = device_details.get('titles', [])
                            if titles_list:
                                title_info = titles_list[0]
                                vendor = title_info.get('vendor', 'Generic')
                                model = title_info.get('model', profile_id)
                                # Construct a clean, full title
                                full_title = f"{vendor} {model}".strip()
                                
                                all_processed_devices.append({
                                    "title": full_title, "target": target_path, "profile": profile_id,
                                    "version": version, "arch": arch
                                })
                                version_device_count += 1
                elif isinstance(profiles, list):
                    # Old format (e.g., 21.02): profiles is a list of strings
                    for profile_string in profiles:
                        # Simple heuristic to create a title from the profile string
                        title = profile_string.replace('_', ' ').replace('-', ' ').title()
                        all_processed_devices.append({
                            "title": title, "target": target_path, "profile": profile_string,
                            "version": version, "arch": arch
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
