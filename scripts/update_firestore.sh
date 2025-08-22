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

# Run the gcloud command to update the document
echo "--> Executing gcloud command..."
gcloud beta firestore documents update "${DOCUMENT_PATH}" \
  --update-fields="${UPDATE_FIELDS}" \
  --project="${PROJECT_ID}"

echo "--> Firestore update completed successfully."
