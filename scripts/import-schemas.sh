#!/usr/bin/env bash
#
# import-schemas.sh - Import schemas to a target Schema Registry from an export directory.
#
# NOTE: For a more robust import with automatic dependency ordering
# and schema ID preservation, consider using srctl:
#   srctl clone --url http://source:8081 --target-url http://target:8081
#   srctl import --url http://target:8081 --input schemas.tar.gz
#
# Requirements: bash 4.x+, curl, jq
#
# Usage:
#   ./import-schemas.sh --sr-url http://target:8081 --input-dir ./schema-export \
#       [--username user] [--password pass] [--context my-context] [--dry-run]
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
SR_URL=""
INPUT_DIR=""
USERNAME=""
PASSWORD=""
CONTEXT=""
DRY_RUN=false

TOTAL_SUBJECTS=0
TOTAL_VERSIONS=0
IMPORTED_VERSIONS=0
FAILED_VERSIONS=0
SKIPPED_VERSIONS=0
FAILED_SUBJECTS=()
FAILED_DETAILS=()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()   { printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn()  { log "WARN: $*" >&2; }
error() { log "ERROR: $*" >&2; }
die()   { error "$@"; exit 1; }

usage() {
    cat <<'USAGE'
Usage: import-schemas.sh [OPTIONS]

Required:
  --sr-url URL        Target Schema Registry URL (e.g. http://localhost:8081)
  --input-dir DIR     Directory produced by export-schemas.sh

Optional:
  --username USER     Basic-auth username
  --password PASS     Basic-auth password
  --context NAME      Import into the given context (subjects prefixed with :.NAME:)
  --dry-run           Show what would be done without making any changes
  -h, --help          Show this help message
USAGE
    exit 0
}

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
check_prerequisites() {
    if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
        die "Bash 4.x or later is required (current: ${BASH_VERSION})"
    fi
    for cmd in curl jq; do
        command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not found in PATH"
    done
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sr-url)       SR_URL="$2"; shift 2 ;;
            --input-dir)    INPUT_DIR="$2"; shift 2 ;;
            --username)     USERNAME="$2"; shift 2 ;;
            --password)     PASSWORD="$2"; shift 2 ;;
            --context)      CONTEXT="$2"; shift 2 ;;
            --dry-run)      DRY_RUN=true; shift ;;
            -h|--help)      usage ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$SR_URL" ]]   || die "--sr-url is required"
    [[ -n "$INPUT_DIR" ]] || die "--input-dir is required"

    # Strip trailing slash from URL
    SR_URL="${SR_URL%/}"

    [[ -d "$INPUT_DIR" ]] || die "Input directory does not exist: $INPUT_DIR"
    [[ -f "$INPUT_DIR/manifest.json" ]] || die "manifest.json not found in $INPUT_DIR — is this a valid export?"
}

# ---------------------------------------------------------------------------
# Build curl auth arguments
# ---------------------------------------------------------------------------
curl_auth_args() {
    if [[ -n "$USERNAME" && -n "$PASSWORD" ]]; then
        printf -- '-u %s:%s' "$USERNAME" "$PASSWORD"
    fi
}

sr_curl() {
    local method="$1"
    local path="$2"
    shift 2
    local auth_args=""
    if [[ -n "$USERNAME" && -n "$PASSWORD" ]]; then
        auth_args="-u ${USERNAME}:${PASSWORD}"
    fi
    # shellcheck disable=SC2086
    curl -s -w "\n%{http_code}" -X "$method" \
        -H "Content-Type: application/json" \
        $auth_args \
        "$@" \
        "${SR_URL}${path}"
}

# Parse response produced by sr_curl (body + status code on last line)
parse_response() {
    local response="$1"
    local http_code
    http_code="$(tail -n1 <<< "$response")"
    local body
    body="$(sed '$d' <<< "$response")"
    echo "$http_code"
    echo "$body"
}

# ---------------------------------------------------------------------------
# Subject name with optional context prefix
# ---------------------------------------------------------------------------
contextualise_subject() {
    local subject="$1"
    if [[ -n "$CONTEXT" ]]; then
        echo ":.${CONTEXT}:${subject}"
    else
        echo "$subject"
    fi
}

# URL-encode a subject name (handles special characters)
url_encode_subject() {
    local string="$1"
    local encoded=""
    local i c
    for (( i = 0; i < ${#string}; i++ )); do
        c="${string:$i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) encoded+="$c" ;;
            *) encoded+=$(printf '%%%02X' "'$c") ;;
        esac
    done
    echo "$encoded"
}

# ---------------------------------------------------------------------------
# Set Schema Registry mode
# ---------------------------------------------------------------------------
set_sr_mode() {
    local mode="$1"
    log "Setting Schema Registry mode to $mode ..."
    if $DRY_RUN; then
        log "[DRY-RUN] Would PUT /mode with {\"mode\": \"$mode\"}"
        return 0
    fi
    local response
    response="$(sr_curl PUT "/mode" -d "{\"mode\": \"${mode}\"}")"
    local http_code body
    read -r http_code <<< "$(parse_response "$response" | head -1)"
    body="$(parse_response "$response" | tail -n +2)"
    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        log "Schema Registry mode set to $mode"
    else
        die "Failed to set SR mode to $mode (HTTP $http_code): $body"
    fi
}

# ---------------------------------------------------------------------------
# Import a single schema version
# ---------------------------------------------------------------------------
import_schema_version() {
    local subject="$1"
    local version_file="$2"
    local context_subject
    context_subject="$(contextualise_subject "$subject")"
    local encoded_subject
    encoded_subject="$(url_encode_subject "$context_subject")"

    # Read version metadata
    local schema_string schema_type schema_id references_json
    schema_string="$(jq -r '.schema' "$version_file")"
    schema_type="$(jq -r '.schemaType // "AVRO"' "$version_file")"
    schema_id="$(jq -r '.id' "$version_file")"
    references_json="$(jq -c '.references // []' "$version_file")"

    # Build the payload — include id to preserve schema IDs
    local payload
    payload="$(jq -n \
        --arg schema "$schema_string" \
        --arg schemaType "$schema_type" \
        --argjson id "$schema_id" \
        --argjson references "$references_json" \
        '{schema: $schema, schemaType: $schemaType, id: $id, references: $references}'
    )"

    if $DRY_RUN; then
        log "[DRY-RUN] Would POST /subjects/${context_subject}/versions (id=$schema_id, type=$schema_type)"
        return 0
    fi

    local response
    response="$(sr_curl POST "/subjects/${encoded_subject}/versions" -d "$payload")"
    local http_code body
    read -r http_code <<< "$(parse_response "$response" | head -1)"
    body="$(parse_response "$response" | tail -n +2)"

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        return 0
    else
        error "Failed to import ${context_subject} id=$schema_id (HTTP $http_code): $body"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Restore per-subject compatibility config
# ---------------------------------------------------------------------------
restore_subject_config() {
    local subject="$1"
    local config_file="$2"
    local context_subject
    context_subject="$(contextualise_subject "$subject")"
    local encoded_subject
    encoded_subject="$(url_encode_subject "$context_subject")"

    local compat_level
    compat_level="$(jq -r '.compatibilityLevel // empty' "$config_file")"
    if [[ -z "$compat_level" ]]; then
        return 0
    fi

    if $DRY_RUN; then
        log "[DRY-RUN] Would PUT /config/${context_subject} with compatibility=$compat_level"
        return 0
    fi

    local payload
    payload="{\"compatibility\": \"${compat_level}\"}"
    local response
    response="$(sr_curl PUT "/config/${encoded_subject}" -d "$payload")"
    local http_code body
    read -r http_code <<< "$(parse_response "$response" | head -1)"
    body="$(parse_response "$response" | tail -n +2)"
    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        log "  Restored compatibility for ${context_subject}: $compat_level"
    else
        warn "Failed to set compatibility for ${context_subject} (HTTP $http_code): $body"
    fi
}

# ---------------------------------------------------------------------------
# Restore global compatibility config
# ---------------------------------------------------------------------------
restore_global_config() {
    local config_file="$INPUT_DIR/global-config.json"
    if [[ ! -f "$config_file" ]]; then
        log "No global config file found — skipping global compatibility restore."
        return 0
    fi

    local compat_level
    compat_level="$(jq -r '.compatibilityLevel // empty' "$config_file")"
    if [[ -z "$compat_level" ]]; then
        log "No global compatibility level in export — skipping."
        return 0
    fi

    if $DRY_RUN; then
        log "[DRY-RUN] Would PUT /config with compatibility=$compat_level"
        return 0
    fi

    local response
    response="$(sr_curl PUT "/config" -d "{\"compatibility\": \"${compat_level}\"}")"
    local http_code body
    read -r http_code <<< "$(parse_response "$response" | head -1)"
    body="$(parse_response "$response" | tail -n +2)"
    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        log "Restored global compatibility: $compat_level"
    else
        warn "Failed to restore global compatibility (HTTP $http_code): $body"
    fi
}

# ---------------------------------------------------------------------------
# Build dependency graph and determine import order
# ---------------------------------------------------------------------------
build_import_order() {
    # Returns two arrays via global variables:
    #   SUBJECTS_NO_REFS  - subjects with no references (import first)
    #   SUBJECTS_WITH_REFS - subjects with references (import second)

    SUBJECTS_NO_REFS=()
    SUBJECTS_WITH_REFS=()

    local subjects_dir="$INPUT_DIR/subjects"
    if [[ ! -d "$subjects_dir" ]]; then
        die "subjects/ directory not found in $INPUT_DIR"
    fi

    # Iterate over each subject directory
    local subject_dir
    for subject_dir in "$subjects_dir"/*/; do
        [[ -d "$subject_dir" ]] || continue
        local subject
        subject="$(basename "$subject_dir")"

        local has_refs=false
        # Check every version file for references
        local version_file
        for version_file in "$subject_dir"/version-*.json; do
            [[ -f "$version_file" ]] || continue
            local refs
            refs="$(jq -r '.references // [] | length' "$version_file")"
            if [[ "$refs" -gt 0 ]]; then
                has_refs=true
                break
            fi
        done

        if $has_refs; then
            SUBJECTS_WITH_REFS+=("$subject")
        else
            SUBJECTS_NO_REFS+=("$subject")
        fi
    done
}

# ---------------------------------------------------------------------------
# Import all versions for a subject
# ---------------------------------------------------------------------------
import_subject() {
    local subject="$1"
    local subject_index="$2"
    local total_subjects="$3"
    local subject_dir="$INPUT_DIR/subjects/$subject"

    # Collect version files sorted by version number
    local version_files=()
    local vf
    for vf in "$subject_dir"/version-*.json; do
        [[ -f "$vf" ]] || continue
        version_files+=("$vf")
    done

    # Sort version files numerically by version number in filename
    IFS=$'\n' read -r -d '' -a version_files < <(
        for f in "${version_files[@]}"; do
            # Extract version number from filename like version-1.json
            local num
            num="$(basename "$f" .json | sed 's/version-//')"
            printf '%s\t%s\n' "$num" "$f"
        done | sort -t$'\t' -k1,1n | cut -f2
        printf '\0'
    ) || true

    local num_versions=${#version_files[@]}
    local version_index=0

    for vf in "${version_files[@]}"; do
        version_index=$((version_index + 1))
        TOTAL_VERSIONS=$((TOTAL_VERSIONS + 1))
        log "Importing subject ${subject_index}/${total_subjects}: ${subject} (version ${version_index}/${num_versions})..."
        if import_schema_version "$subject" "$vf"; then
            IMPORTED_VERSIONS=$((IMPORTED_VERSIONS + 1))
        else
            FAILED_VERSIONS=$((FAILED_VERSIONS + 1))
            FAILED_SUBJECTS+=("$subject")
            local schema_id
            schema_id="$(jq -r '.id // "unknown"' "$vf")"
            FAILED_DETAILS+=("${subject} version ${version_index} (id=${schema_id})")
        fi
    done

    # Restore per-subject compatibility config if present
    local config_file="$subject_dir/config.json"
    if [[ -f "$config_file" ]]; then
        restore_subject_config "$subject" "$config_file"
    fi
}

# ---------------------------------------------------------------------------
# Generate the import report
# ---------------------------------------------------------------------------
generate_report() {
    local report_file="$INPUT_DIR/import-report.json"

    # Deduplicate failed subjects
    declare -A seen_failed
    local unique_failed=()
    local subj
    for subj in "${FAILED_SUBJECTS[@]+"${FAILED_SUBJECTS[@]}"}"; do
        if [[ -z "${seen_failed[$subj]+x}" ]]; then
            seen_failed["$subj"]=1
            unique_failed+=("$subj")
        fi
    done

    # Build failed details JSON array
    local failed_details_json="[]"
    if [[ ${#FAILED_DETAILS[@]} -gt 0 ]]; then
        failed_details_json="$(printf '%s\n' "${FAILED_DETAILS[@]}" | jq -R . | jq -s .)"
    fi

    # Build unique failed subjects JSON array
    local failed_subjects_json="[]"
    if [[ ${#unique_failed[@]} -gt 0 ]]; then
        failed_subjects_json="$(printf '%s\n' "${unique_failed[@]}" | jq -R . | jq -s .)"
    fi

    local status="success"
    if [[ "$FAILED_VERSIONS" -gt 0 && "$IMPORTED_VERSIONS" -gt 0 ]]; then
        status="partial"
    elif [[ "$FAILED_VERSIONS" -gt 0 && "$IMPORTED_VERSIONS" -eq 0 ]]; then
        status="failed"
    fi

    if $DRY_RUN; then
        status="dry-run"
    fi

    jq -n \
        --arg status "$status" \
        --arg timestamp "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg sr_url "$SR_URL" \
        --arg context "$CONTEXT" \
        --argjson dry_run "$DRY_RUN" \
        --argjson total_subjects "$TOTAL_SUBJECTS" \
        --argjson total_versions "$TOTAL_VERSIONS" \
        --argjson imported_versions "$IMPORTED_VERSIONS" \
        --argjson failed_versions "$FAILED_VERSIONS" \
        --argjson skipped_versions "$SKIPPED_VERSIONS" \
        --argjson failed_subjects "$failed_subjects_json" \
        --argjson failed_details "$failed_details_json" \
        '{
            status: $status,
            timestamp: $timestamp,
            target_sr_url: $sr_url,
            context: (if $context == "" then null else $context end),
            dry_run: $dry_run,
            summary: {
                total_subjects: $total_subjects,
                total_versions: $total_versions,
                imported_versions: $imported_versions,
                failed_versions: $failed_versions,
                skipped_versions: $skipped_versions
            },
            failed_subjects: $failed_subjects,
            failed_details: $failed_details
        }' > "$report_file"

    log "Import report written to $report_file"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    check_prerequisites
    parse_args "$@"

    log "============================================="
    log " Schema Registry Import"
    log "============================================="
    log "Target SR:   $SR_URL"
    log "Input dir:   $INPUT_DIR"
    if [[ -n "$CONTEXT" ]]; then
        log "Context:     $CONTEXT"
    fi
    if $DRY_RUN; then
        log "Mode:        DRY-RUN (no changes will be made)"
    fi
    log "============================================="

    # Validate manifest
    local manifest="$INPUT_DIR/manifest.json"
    local export_date export_subject_count
    export_date="$(jq -r '.export_date // .timestamp // "unknown"' "$manifest")"
    export_subject_count="$(jq -r '.subject_count // .total_subjects // "unknown"' "$manifest")"
    log "Export manifest: date=$export_date, subjects=$export_subject_count"

    # Build dependency-ordered import list
    log ""
    log "Analyzing schemas for dependency ordering..."
    build_import_order

    local no_ref_count=${#SUBJECTS_NO_REFS[@]}
    local with_ref_count=${#SUBJECTS_WITH_REFS[@]}
    TOTAL_SUBJECTS=$((no_ref_count + with_ref_count))

    log "  Subjects without references: $no_ref_count (will import first)"
    log "  Subjects with references:    $with_ref_count (will import second)"
    log "  Total subjects:              $TOTAL_SUBJECTS"
    log ""

    # Step a: Set target to IMPORT mode
    set_sr_mode "IMPORT"
    log ""

    # Step b: Import schemas — dependency-ordered
    local subject_counter=0

    # First pass: subjects without references
    if [[ $no_ref_count -gt 0 ]]; then
        log "--- Pass 1: Importing $no_ref_count subjects without references ---"
        for subject in "${SUBJECTS_NO_REFS[@]}"; do
            subject_counter=$((subject_counter + 1))
            import_subject "$subject" "$subject_counter" "$TOTAL_SUBJECTS"
        done
        log ""
    fi

    # Second pass: subjects with references
    if [[ $with_ref_count -gt 0 ]]; then
        log "--- Pass 2: Importing $with_ref_count subjects with references ---"
        for subject in "${SUBJECTS_WITH_REFS[@]}"; do
            subject_counter=$((subject_counter + 1))
            import_subject "$subject" "$subject_counter" "$TOTAL_SUBJECTS"
        done
        log ""
    fi

    # Step c: per-subject configs already restored inside import_subject()

    # Step d: Restore global compatibility config
    log "--- Restoring global compatibility config ---"
    restore_global_config
    log ""

    # Step e: Set target back to READWRITE mode
    set_sr_mode "READWRITE"
    log ""

    # Generate report
    generate_report

    # Summary
    log "============================================="
    log " Import Complete"
    log "============================================="
    log "  Total subjects:     $TOTAL_SUBJECTS"
    log "  Total versions:     $TOTAL_VERSIONS"
    log "  Imported:           $IMPORTED_VERSIONS"
    log "  Failed:             $FAILED_VERSIONS"
    if [[ ${#FAILED_DETAILS[@]} -gt 0 ]]; then
        log ""
        log "  Failed details:"
        for detail in "${FAILED_DETAILS[@]}"; do
            log "    - $detail"
        done
    fi
    log "============================================="

    if [[ "$FAILED_VERSIONS" -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
