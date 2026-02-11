#!/usr/bin/env bash
#
# pre-check.sh - Schema Registry Pre-Migration Assessment
#
# Performs automated checks against a source Schema Registry to identify
# potential issues before migration. Checks connectivity, schema counts,
# types, sizes, references, compatibility levels, modes, and dangling refs.
#
# NOTE: For a more comprehensive analysis, consider using:
#   srctl stats --url <sr-url> --workers <n>
# which provides deeper inspection and parallel processing.
#
# Requires: bash 4.x+, curl, jq
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Color codes
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SR_URL=""
USERNAME=""
PASSWORD=""
SIZE_THRESHOLD=1048576  # 1 MB in bytes

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") --sr-url <url> [OPTIONS]

Schema Registry Pre-Migration Assessment

Required:
  --sr-url <url>              Source Schema Registry URL (e.g. http://localhost:8081)

Optional:
  --username <user>           Basic-auth username
  --password <pass>           Basic-auth password
  --size-threshold <bytes>    Schema size warning threshold in bytes (default: 1048576 = 1 MB)
  --workers <n>               Parallelism hint (reserved for future use)
  -h, --help                  Show this help message

Examples:
  $(basename "$0") --sr-url http://schema-registry:8081
  $(basename "$0") --sr-url https://sr.example.com --username admin --password secret
  $(basename "$0") --sr-url http://localhost:8081 --size-threshold 524288

NOTE: For a more comprehensive analysis, consider:
  srctl stats --url <sr-url> --workers <n>
EOF
    exit 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sr-url)
            SR_URL="$2"; shift 2 ;;
        --username)
            USERNAME="$2"; shift 2 ;;
        --password)
            PASSWORD="$2"; shift 2 ;;
        --size-threshold)
            SIZE_THRESHOLD="$2"; shift 2 ;;
        --workers)
            # Reserved for future parallelism; accepted but not yet used.
            shift 2 ;;
        -h|--help)
            usage ;;
        *)
            echo "Unknown option: $1" >&2
            usage ;;
    esac
done

if [[ -z "$SR_URL" ]]; then
    echo "Error: --sr-url is required." >&2
    usage
fi

# Strip trailing slash from URL
SR_URL="${SR_URL%/}"

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
if ! command -v curl &>/dev/null; then
    echo "Error: curl is required but not installed." >&2
    exit 1
fi
if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but not installed." >&2
    exit 1
fi

# Verify bash version >= 4 (needed for associative arrays)
if (( BASH_VERSINFO[0] < 4 )); then
    echo "Error: bash 4.x+ is required. Current version: ${BASH_VERSION}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Helper: build curl auth flags
# ---------------------------------------------------------------------------
build_curl_args() {
    local -a args=(-s -S --max-time 30)
    if [[ -n "$USERNAME" ]]; then
        args+=(-u "${USERNAME}:${PASSWORD}")
    fi
    printf '%s\n' "${args[@]}"
}

# Materialise once into an array
CURL_AUTH_ARGS=()
while IFS= read -r line; do
    CURL_AUTH_ARGS+=("$line")
done < <(build_curl_args)

# Wrapper around curl that includes auth and common flags.
sr_curl() {
    local path="$1"
    curl "${CURL_AUTH_ARGS[@]}" -H "Accept: application/vnd.schemaregistry.v1+json" \
        "${SR_URL}${path}" 2>&1
}

# ---------------------------------------------------------------------------
# Counters for the final summary
# ---------------------------------------------------------------------------
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
INFO_COUNT=0

print_pass() {
    local label="$1" value="$2"
    printf "  ${GREEN}[PASS]${NC} %-28s %s\n" "$label" "$value"
    ((PASS_COUNT++))
}

print_warn() {
    local label="$1" value="$2"
    printf "  ${YELLOW}[WARN]${NC} %-28s %s\n" "$label" "$value"
    ((WARN_COUNT++))
}

print_fail() {
    local label="$1" value="$2"
    printf "  ${RED}[FAIL]${NC} %-28s %s\n" "$label" "$value"
    ((FAIL_COUNT++))
}

print_info() {
    local label="$1" value="$2"
    printf "  ${CYAN}[INFO]${NC} %-28s %s\n" "$label" "$value"
    ((INFO_COUNT++))
}

print_detail() {
    local label="$1" value="$2"
    printf "         %-28s %s\n" "$label" "$value"
}

human_size() {
    local bytes=$1
    if (( bytes >= 1073741824 )); then
        echo "$(( bytes / 1073741824 )) GB"
    elif (( bytes >= 1048576 )); then
        echo "$(( bytes / 1048576 )) MB"
    elif (( bytes >= 1024 )); then
        echo "$(( bytes / 1024 )) KB"
    else
        echo "${bytes} B"
    fi
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}============================================${NC}"
echo -e "${BOLD}  Schema Registry Pre-Migration Assessment${NC}"
echo -e "${BOLD}============================================${NC}"
echo "  Source SR: ${SR_URL}"
echo "  Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo "--------------------------------------------"
echo ""

# ---------------------------------------------------------------------------
# 1. Connectivity Check
# ---------------------------------------------------------------------------
CONNECTIVITY_RESPONSE=$(sr_curl "/" || true)

if echo "$CONNECTIVITY_RESPONSE" | jq . &>/dev/null; then
    print_pass "Connectivity ................" "OK"
else
    print_fail "Connectivity ................" "UNREACHABLE"
    echo ""
    echo -e "${RED}Cannot reach Schema Registry at ${SR_URL}. Aborting.${NC}"
    echo ""
    echo -e "${BOLD}============================================${NC}"
    echo -e "${BOLD}  Summary: ${PASS_COUNT} PASS | ${WARN_COUNT} WARN | ${FAIL_COUNT} FAIL${NC}"
    echo -e "${BOLD}============================================${NC}"
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Subject Count
# ---------------------------------------------------------------------------
SUBJECTS_JSON=$(sr_curl "/subjects" || true)

if ! echo "$SUBJECTS_JSON" | jq -e 'type == "array"' &>/dev/null; then
    print_fail "Total Subjects .............." "Failed to retrieve subjects"
else
    SUBJECT_COUNT=$(echo "$SUBJECTS_JSON" | jq 'length')
    mapfile -t SUBJECTS < <(echo "$SUBJECTS_JSON" | jq -r '.[]')

    if (( SUBJECT_COUNT == 0 )); then
        print_warn "Total Subjects .............." "0 (empty registry)"
    else
        print_pass "Total Subjects .............." "$SUBJECT_COUNT"
    fi
fi

# ---------------------------------------------------------------------------
# 3. Schema Types Breakdown
# ---------------------------------------------------------------------------
declare -A TYPE_COUNTS=( ["AVRO"]=0 ["PROTOBUF"]=0 ["JSON"]=0 )
declare -A SCHEMA_SIZES=()      # subject -> size in bytes
declare -a SUBJECTS_WITH_REFS=() # subjects that have references
declare -A REF_TARGETS=()       # referenced subject names

LARGEST_SIZE=0
LARGEST_SUBJECT=""

if (( ${#SUBJECTS[@]} > 0 )); then
    for subject in "${SUBJECTS[@]}"; do
        # URL-encode the subject name (handles special chars like / and %)
        encoded_subject=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$subject', safe=''))" 2>/dev/null || echo "$subject")

        SCHEMA_JSON=$(sr_curl "/subjects/${encoded_subject}/versions/latest" || true)

        if ! echo "$SCHEMA_JSON" | jq -e '.schema' &>/dev/null; then
            continue
        fi

        # Determine schema type (missing schemaType field means AVRO)
        SCHEMA_TYPE=$(echo "$SCHEMA_JSON" | jq -r '.schemaType // "AVRO"')
        case "$SCHEMA_TYPE" in
            AVRO)     ((TYPE_COUNTS["AVRO"]++)) ;;
            PROTOBUF) ((TYPE_COUNTS["PROTOBUF"]++)) ;;
            JSON)     ((TYPE_COUNTS["JSON"]++)) ;;
            *)        ((TYPE_COUNTS["AVRO"]++)) ;;  # default to AVRO
        esac

        # 4. Schema size
        SCHEMA_STR=$(echo "$SCHEMA_JSON" | jq -r '.schema')
        SCHEMA_LEN=${#SCHEMA_STR}
        SCHEMA_SIZES["$subject"]=$SCHEMA_LEN

        if (( SCHEMA_LEN > LARGEST_SIZE )); then
            LARGEST_SIZE=$SCHEMA_LEN
            LARGEST_SUBJECT="$subject"
        fi

        # 5. Check for references
        HAS_REFS=$(echo "$SCHEMA_JSON" | jq 'if .references then (.references | length) else 0 end')
        if (( HAS_REFS > 0 )); then
            SUBJECTS_WITH_REFS+=("$subject")
            # Collect referenced subject names for dangling-ref check
            while IFS= read -r ref_subject; do
                REF_TARGETS["$ref_subject"]=1
            done < <(echo "$SCHEMA_JSON" | jq -r '.references[].subject')
        fi
    done
fi

# Print schema types result
TOTAL_TYPED=$(( TYPE_COUNTS["AVRO"] + TYPE_COUNTS["PROTOBUF"] + TYPE_COUNTS["JSON"] ))
if (( TOTAL_TYPED > 0 )); then
    print_pass "Schema Types" ""
    print_detail "Avro ......................" "${TYPE_COUNTS["AVRO"]}"
    print_detail "Protobuf .................." "${TYPE_COUNTS["PROTOBUF"]}"
    print_detail "JSON Schema ..............." "${TYPE_COUNTS["JSON"]}"
else
    print_warn "Schema Types" "Unable to determine"
fi

# ---------------------------------------------------------------------------
# 4. Schema Size Analysis (report)
# ---------------------------------------------------------------------------
OVERSIZED_COUNT=0
for subject in "${!SCHEMA_SIZES[@]}"; do
    if (( SCHEMA_SIZES["$subject"] > SIZE_THRESHOLD )); then
        ((OVERSIZED_COUNT++))
    fi
done

LARGEST_HUMAN=$(human_size "$LARGEST_SIZE")

if (( OVERSIZED_COUNT > 0 )); then
    print_warn "Schema Size Analysis" ""
    print_detail "Largest schema ............" "${LARGEST_HUMAN} (subject: ${LARGEST_SUBJECT})"
    print_detail "Schemas > $(human_size "$SIZE_THRESHOLD") ............" "$OVERSIZED_COUNT"
elif (( LARGEST_SIZE > 0 )); then
    print_pass "Schema Size Analysis" ""
    print_detail "Largest schema ............" "${LARGEST_HUMAN} (subject: ${LARGEST_SUBJECT})"
    print_detail "Schemas > $(human_size "$SIZE_THRESHOLD") ............" "0"
else
    print_pass "Schema Size Analysis ........" "No schemas to analyze"
fi

# ---------------------------------------------------------------------------
# 5. Subjects with References (report)
# ---------------------------------------------------------------------------
REF_COUNT=${#SUBJECTS_WITH_REFS[@]}
if (( REF_COUNT > 0 )); then
    print_pass "References ................." "${REF_COUNT} subjects with references"
else
    print_pass "References ................." "0 subjects with references"
fi

# ---------------------------------------------------------------------------
# 6. Compatibility Levels
# ---------------------------------------------------------------------------
GLOBAL_COMPAT_JSON=$(sr_curl "/config" || true)
GLOBAL_COMPAT=$(echo "$GLOBAL_COMPAT_JSON" | jq -r '.compatibilityLevel // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")

if [[ "$GLOBAL_COMPAT" == "UNKNOWN" ]]; then
    print_warn "Global Compatibility ........" "Unable to determine"
else
    print_pass "Global Compatibility ........" "$GLOBAL_COMPAT"
fi

# Check per-subject compatibility overrides
OVERRIDE_COUNT=0
if (( ${#SUBJECTS[@]} > 0 )); then
    for subject in "${SUBJECTS[@]}"; do
        encoded_subject=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$subject', safe=''))" 2>/dev/null || echo "$subject")
        SUBJECT_COMPAT_JSON=$(sr_curl "/config/${encoded_subject}" || true)
        SUBJECT_COMPAT=$(echo "$SUBJECT_COMPAT_JSON" | jq -r '.compatibilityLevel // empty' 2>/dev/null || true)

        if [[ -n "$SUBJECT_COMPAT" ]]; then
            ((OVERRIDE_COUNT++))
        fi
    done
fi

if (( OVERRIDE_COUNT > 0 )); then
    print_info "Compatibility Overrides ....." "${OVERRIDE_COUNT} subjects"
else
    print_info "Compatibility Overrides ....." "None"
fi

# ---------------------------------------------------------------------------
# 7. Mode Settings
# ---------------------------------------------------------------------------
MODE_JSON=$(sr_curl "/mode" || true)
GLOBAL_MODE=$(echo "$MODE_JSON" | jq -r '.mode // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")

if [[ "$GLOBAL_MODE" == "UNKNOWN" ]]; then
    print_warn "Global Mode ................." "Unable to determine"
else
    print_pass "Global Mode ................." "$GLOBAL_MODE"
fi

# ---------------------------------------------------------------------------
# 8. Dangling References
# ---------------------------------------------------------------------------
DANGLING_COUNT=0
DANGLING_SUBJECTS=()
if (( ${#REF_TARGETS[@]} > 0 )); then
    for ref_subject in "${!REF_TARGETS[@]}"; do
        FOUND=0
        for subject in "${SUBJECTS[@]}"; do
            if [[ "$subject" == "$ref_subject" ]]; then
                FOUND=1
                break
            fi
        done
        if (( FOUND == 0 )); then
            ((DANGLING_COUNT++))
            DANGLING_SUBJECTS+=("$ref_subject")
        fi
    done
fi

if (( DANGLING_COUNT > 0 )); then
    print_fail "Dangling References ........." "${DANGLING_COUNT} missing subjects"
    for ds in "${DANGLING_SUBJECTS[@]}"; do
        print_detail "" "- ${ds}"
    done
else
    print_pass "Dangling References ........." "None"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}============================================${NC}"
echo -e "${BOLD}  Summary: ${GREEN}${PASS_COUNT} PASS${NC} | ${YELLOW}${WARN_COUNT} WARN${NC} | ${RED}${FAIL_COUNT} FAIL${NC}"
echo -e "${BOLD}============================================${NC}"
echo ""

if (( FAIL_COUNT > 0 )); then
    echo -e "${RED}Recommendation: Resolve FAIL items before proceeding with migration.${NC}"
elif (( WARN_COUNT > 0 )); then
    echo -e "${YELLOW}Recommendation: Review WARN items before migration.${NC}"
else
    echo -e "${GREEN}Recommendation: All checks passed. Ready to proceed with migration.${NC}"
fi

echo -e "For detailed schema analysis, use: ${BOLD}srctl stats --url ${SR_URL}${NC}"
echo ""

# Exit with non-zero if any FAIL checks
if (( FAIL_COUNT > 0 )); then
    exit 1
fi
exit 0
