#!/usr/bin/env bash
# export-schemas.sh - Export all schemas from a Confluent Schema Registry
#
# NOTE: For a more robust export with automatic dependency ordering,
# consider using srctl:
#   srctl export --url http://source-sr:8081 --output schemas.tar.gz
#   srctl backup --url http://source-sr:8081 --output backup.tar.gz
#
# This script uses curl and jq to pull every subject, every version of
# each subject, per-subject compatibility configs, and global config/mode
# from a Schema Registry instance, writing them to a local directory tree.
#
# Usage:
#   ./export-schemas.sh --sr-url http://localhost:8081 --output-dir ./export
#   ./export-schemas.sh --sr-url https://sr.example.com --output-dir ./export \
#       --username my-api-key --password my-api-secret

set -euo pipefail

###############################################################################
# Defaults
###############################################################################
SR_URL=""
OUTPUT_DIR=""
USERNAME=""
PASSWORD=""

###############################################################################
# Usage
###############################################################################
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Export all schemas from a Confluent Schema Registry.

Required:
  --sr-url URL          Schema Registry URL (e.g. http://localhost:8081)
  --output-dir DIR      Directory to write exported schemas into

Optional:
  --username USER       Basic-auth / API-key username
  --password PASS       Basic-auth / API-key password
  -h, --help            Show this help message

Examples:
  $(basename "$0") --sr-url http://localhost:8081 --output-dir ./export
  $(basename "$0") --sr-url https://sr.example.com:8081 --output-dir ./export \\
      --username my-key --password my-secret
EOF
    exit "${1:-0}"
}

###############################################################################
# Parse arguments
###############################################################################
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sr-url)
            SR_URL="$2"; shift 2 ;;
        --output-dir)
            OUTPUT_DIR="$2"; shift 2 ;;
        --username)
            USERNAME="$2"; shift 2 ;;
        --password)
            PASSWORD="$2"; shift 2 ;;
        -h|--help)
            usage 0 ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage 1 ;;
    esac
done

if [[ -z "$SR_URL" ]]; then
    echo "ERROR: --sr-url is required." >&2
    usage 1
fi
if [[ -z "$OUTPUT_DIR" ]]; then
    echo "ERROR: --output-dir is required." >&2
    usage 1
fi

# Strip trailing slash from SR_URL
SR_URL="${SR_URL%/}"

###############################################################################
# Dependency checks
###############################################################################
for cmd in curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: Required command '$cmd' is not installed." >&2
        exit 1
    fi
done

# Require bash 4.x+ for associative arrays / modern features
if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: bash 4.x or later is required (running ${BASH_VERSION})." >&2
    exit 1
fi

###############################################################################
# Helpers
###############################################################################

# Build curl auth flags (if credentials were provided)
declare -a CURL_AUTH=()
if [[ -n "$USERNAME" ]]; then
    CURL_AUTH=(-u "${USERNAME}:${PASSWORD}")
fi

# Perform an HTTP GET, returning the body. Sets LAST_HTTP_CODE.
LAST_HTTP_CODE=""
sr_get() {
    local path="$1"
    local url="${SR_URL}${path}"

    local tmp_file
    tmp_file="$(mktemp)"

    LAST_HTTP_CODE=$(curl -s -o "$tmp_file" -w "%{http_code}" \
        "${CURL_AUTH[@]+"${CURL_AUTH[@]}"}" \
        -H "Accept: application/vnd.schemaregistry.v1+json" \
        "$url")

    if [[ "$LAST_HTTP_CODE" -ge 200 && "$LAST_HTTP_CODE" -lt 300 ]]; then
        cat "$tmp_file"
        rm -f "$tmp_file"
        return 0
    else
        local body
        body="$(cat "$tmp_file")"
        rm -f "$tmp_file"
        # Let caller decide what to do with non-2xx
        echo "$body"
        return 1
    fi
}

# URL-encode a string (subjects may contain /, :, %, spaces, etc.)
url_encode() {
    local string="$1"
    local encoded=""
    local i char
    local length=${#string}
    for (( i = 0; i < length; i++ )); do
        char="${string:i:1}"
        case "$char" in
            [a-zA-Z0-9._~-])
                encoded+="$char"
                ;;
            *)
                # printf the byte value and percent-encode it
                encoded+="$(printf '%%%02X' "'$char")"
                ;;
        esac
    done
    echo "$encoded"
}

# Sanitise a subject name for use as a directory name on disk.
# Replaces characters that are problematic on common filesystems.
sanitize_dirname() {
    local name="$1"
    # Replace / with _SLASH_, : with _COLON_, and any other tricky chars
    name="${name//\//_SLASH_}"
    name="${name//:/_COLON_}"
    # Replace whitespace with underscores
    name="${name// /_}"
    echo "$name"
}

###############################################################################
# Create output directory structure
###############################################################################
echo "============================================="
echo "Schema Registry Export"
echo "============================================="
echo "Source:     $SR_URL"
echo "Output:    $OUTPUT_DIR"
echo "============================================="
echo ""

mkdir -p "${OUTPUT_DIR}/subjects"

###############################################################################
# Step (a): List all subjects
###############################################################################
echo "Fetching subject list..."
subjects_json=""
if ! subjects_json="$(sr_get /subjects)"; then
    echo "ERROR: Failed to list subjects (HTTP $LAST_HTTP_CODE)." >&2
    echo "Response: $subjects_json" >&2
    exit 1
fi

# Parse into a bash array
declare -a SUBJECTS=()
while IFS= read -r subj; do
    SUBJECTS+=("$subj")
done < <(echo "$subjects_json" | jq -r '.[]')

TOTAL_SUBJECTS=${#SUBJECTS[@]}
echo "Found $TOTAL_SUBJECTS subjects."
echo ""

if [[ "$TOTAL_SUBJECTS" -eq 0 ]]; then
    echo "WARNING: No subjects found in Schema Registry. Nothing to export."
fi

###############################################################################
# Step (b): Export each subject (versions + per-subject config)
###############################################################################
TOTAL_VERSIONS=0
SUBJECT_INDEX=0

for subject in "${SUBJECTS[@]}"; do
    (( SUBJECT_INDEX++ )) || true
    echo "Exporting subject ${SUBJECT_INDEX}/${TOTAL_SUBJECTS}: ${subject}..."

    # Encode the subject for URL path segments
    encoded_subject="$(url_encode "$subject")"

    # Sanitise for filesystem directory name
    safe_dir="$(sanitize_dirname "$subject")"
    subject_dir="${OUTPUT_DIR}/subjects/${safe_dir}"
    mkdir -p "${subject_dir}/versions"

    # ---- List versions for this subject ----
    versions_json=""
    if ! versions_json="$(sr_get "/subjects/${encoded_subject}/versions")"; then
        echo "  WARNING: Could not list versions for '${subject}' (HTTP $LAST_HTTP_CODE). Skipping." >&2
        continue
    fi

    declare -a VERSIONS=()
    while IFS= read -r ver; do
        VERSIONS+=("$ver")
    done < <(echo "$versions_json" | jq -r '.[]')

    # ---- Fetch each version ----
    for version in "${VERSIONS[@]}"; do
        schema_json=""
        if ! schema_json="$(sr_get "/subjects/${encoded_subject}/versions/${version}")"; then
            echo "  WARNING: Could not fetch version ${version} of '${subject}' (HTTP $LAST_HTTP_CODE). Skipping." >&2
            continue
        fi

        # The API returns {subject, version, id, schema, schemaType?, references?}.
        # Normalise: ensure schemaType and references are always present.
        schema_json="$(echo "$schema_json" | jq '{
            id: .id,
            version: .version,
            subject: .subject,
            schema: .schema,
            schemaType: (.schemaType // "AVRO"),
            references: (.references // [])
        }')"

        echo "$schema_json" > "${subject_dir}/versions/${version}.json"
        (( TOTAL_VERSIONS++ )) || true
    done

    # ---- Per-subject compatibility config ----
    config_json=""
    if config_json="$(sr_get "/config/${encoded_subject}")"; then
        echo "$config_json" | jq '.' > "${subject_dir}/config.json"
    else
        # 404 is expected when no per-subject override exists; silently skip.
        if [[ "$LAST_HTTP_CODE" != "404" ]]; then
            echo "  WARNING: Could not fetch config for '${subject}' (HTTP $LAST_HTTP_CODE)." >&2
        fi
    fi

    # Clear VERSIONS for next iteration
    unset VERSIONS
done

echo ""
echo "Exported ${TOTAL_VERSIONS} schema version(s) across ${TOTAL_SUBJECTS} subject(s)."
echo ""

###############################################################################
# Step (c): Global compatibility config
###############################################################################
echo "Fetching global compatibility config..."
global_config=""
if global_config="$(sr_get /config)"; then
    echo "$global_config" | jq '.' > "${OUTPUT_DIR}/global-config.json"
    echo "  Saved global-config.json"
else
    echo "  WARNING: Could not fetch global config (HTTP $LAST_HTTP_CODE)." >&2
    echo '{}' > "${OUTPUT_DIR}/global-config.json"
fi

###############################################################################
# Step (d): Global mode
###############################################################################
echo "Fetching global mode..."
global_mode=""
if global_mode="$(sr_get /mode)"; then
    echo "$global_mode" | jq '.' > "${OUTPUT_DIR}/global-mode.json"
    echo "  Saved global-mode.json"
else
    echo "  WARNING: Could not fetch global mode (HTTP $LAST_HTTP_CODE)." >&2
    echo '{}' > "${OUTPUT_DIR}/global-mode.json"
fi

###############################################################################
# Step (e): Write manifest
###############################################################################
echo ""
echo "Writing manifest..."

EXPORT_DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

jq -n \
    --arg date "$EXPORT_DATE" \
    --arg source "$SR_URL" \
    --argjson subjectCount "$TOTAL_SUBJECTS" \
    --argjson totalVersions "$TOTAL_VERSIONS" \
    '{
        exportDate: $date,
        sourceUrl: $source,
        subjectCount: $subjectCount,
        totalVersions: $totalVersions
    }' > "${OUTPUT_DIR}/manifest.json"

echo "  Saved manifest.json"

###############################################################################
# Done
###############################################################################
echo ""
echo "============================================="
echo "Export complete."
echo "  Subjects:  $TOTAL_SUBJECTS"
echo "  Versions:  $TOTAL_VERSIONS"
echo "  Output:    $OUTPUT_DIR"
echo "============================================="
