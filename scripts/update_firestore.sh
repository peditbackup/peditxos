#!/bin/bash
# This script updates a Firestore document with the build status.
# It's designed to be called from the GitHub Actions workflow.

# Exit immediately if a command fails
set -e

# --- Argument Validation ---
if [ "$#" -lt 4 ]; then
    echo "Error: Missing required arguments."
    echo "Usage: $0 <project_id> <user_id> <build_id> <status> [download_url]"
    exit 1
fi

PROJECT_ID="$1"
USER_ID="$2"
BUILD_ID="$3"
STATUS="$4"
DOWNLOAD_URL="$5" # This will be empty for failures

# --- Main Logic ---
DOCUMENT_PATH="users/${USER_ID}/builds/${BUILD_ID}"
GCLOUD_ERROR_LOG="gcloud_error.log"

echo "--> Preparing to update Firestore document..."
echo "    Document Path: ${DOCUMENT_PATH}"
echo "    Status: ${STATUS}"

# Build the --update-fields argument based on the status
if [ "$STATUS" == "completed" ]; then
    if [ -z "$DOWNLOAD_URL" ]; then
        echo "::error::Download URL is required for 'completed' status."
        exit 1
    fi
    UPDATE_FIELDS="status=completed,downloadUrl=${DOWNLOAD_URL}"
    echo "    Download URL: ${DOWNLOAD_URL}"
else
    UPDATE_FIELDS="status=failed,downloadUrl=null"
fi

# Run the gcloud command and redirect stderr to a log file.
# The '|| true' prevents the script from exiting immediately if gcloud fails,
# allowing us to capture and display the error message first.
echo "--> Executing gcloud command..."
gcloud beta firestore documents update "${DOCUMENT_PATH}" \
  --update-fields="${UPDATE_FIELDS}" \
  --project="${PROJECT_ID}" 2> "${GCLOUD_ERROR_LOG}" || true

# Check if the error log file has content. The -s flag checks if the file exists and is not empty.
if [ -s "${GCLOUD_ERROR_LOG}" ]; then
    echo "::error::Firestore update failed. See gcloud output below:"
    # Read the error log line by line and format it for GitHub Actions
    while IFS= read -r line; do
        echo "::error::${line}"
    done < "${GCLOUD_ERROR_LOG}"
    # Exit with a failure code to make the GitHub Actions step fail
    exit 1
else
    echo "--> Firestore update completed successfully."
fi
