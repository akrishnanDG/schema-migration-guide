#!/usr/bin/env bash
# NOTE: For a more comprehensive comparison with multi-threaded
# execution, consider using srctl:
#   srctl compare --url http://source:8081 --target-url http://target:8081

# =============================================================================
# validate-migration.sh
#
# Validates that a Schema Registry migration was successful by comparing
# subjects, versions, schema IDs, schema content, compatibility settings,
# and mode between a source and target Schema Registry.
#
# Requires: bash 4.x+, curl, jq
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

declare -a RESULT_LINES=()
declare -a JSON_CHECKS=()

REPORT_FILE="validation-report.json"

# ---------------------------------------------------------------------------
# Usage / Help
# ---------------------------------------------------------------------------
usage() {
    cat <<'USAGE'
Usage: validate-migration.sh [OPTIONS]

Required:
  --source-url URL          Source Schema Registry URL
  --target-url URL          Target Schema Registry URL

Optional:
  --source-username USER    Basic-auth username for source SR
  --source-password PASS    Basic-auth password for source SR
  --target-username USER    Basic-auth username for target SR
  --target-password PASS    Basic-auth password for target SR
  --report-file FILE        Path for JSON report (default: validation-report.json)
  -h, --help                Show this help message

Examples:
  # No auth
  validate-migration.sh \
      --source-url http://source-sr:8081 \
      --target-url http://target-sr:8081

  # With auth on both sides
  validate-migration.sh \
      --source-url http://source-sr:8081 \
      --source-username admin --source-password secret \
      --target-url https://target-sr.confluent.cloud \
      --target-username APIKEY --target-password APISECRET
USAGE
    exit 0
}

# ---------------------------------------------------------------------------
# Argument Parsing
# ---------------------------------------------------------------------------
SOURCE_URL=""
TARGET_URL=""
SOURCE_USERNAME=""
SOURCE_PASSWORD=""
TARGET_USERNAME=""
TARGET_PASSWORD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-url)      SOURCE_URL="$2";      shift 2 ;;
        --target-url)      TARGET_URL="$2";      shift 2 ;;
        --source-username) SOURCE_USERNAME="$2";  shift 2 ;;
        --source-password) SOURCE_PASSWORD="$2";  shift 2 ;;
        --target-username) TARGET_USERNAME="$2";  shift 2 ;;
        --target-password) TARGET_PASSWORD="$2";  shift 2 ;;
        --report-file)     REPORT_FILE="$2";      shift 2 ;;
        -h|--help)         usage ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage
            ;;
    esac
done

if [[ -z "$SOURCE_URL" || -z "$TARGET_URL" ]]; then
    echo "ERROR: --source-url and --target-url are required." >&2
    usage
fi

# Strip trailing slashes
SOURCE_URL="${SOURCE_URL%/}"
TARGET_URL="${TARGET_URL%/}"

# ---------------------------------------------------------------------------
# Prerequisite Checks
# ---------------------------------------------------------------------------
check_prerequisites() {
    local missing=0

    if ! command -v curl &>/dev/null; then
        echo "ERROR: curl is required but not found." >&2
        missing=1
    fi

    if ! command -v jq &>/dev/null; then
        echo "ERROR: jq is required but not found." >&2
        missing=1
    fi

    # Bash version check (need 4.x+ for associative arrays)
    if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
        echo "ERROR: bash 4.x or later is required (found ${BASH_VERSION})." >&2
        missing=1
    fi

    if [[ "$missing" -ne 0 ]]; then
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------
# sr_curl <source|target> <path> [extra curl args...]
# Performs a curl request against the given SR and returns the body.
# Sets the global variable _HTTP_CODE to the HTTP status code.
sr_curl() {
    local side="$1"
    shift
    local path="$1"
    shift

    local url username password
    if [[ "$side" == "source" ]]; then
        url="${SOURCE_URL}${path}"
        username="$SOURCE_USERNAME"
        password="$SOURCE_PASSWORD"
    else
        url="${TARGET_URL}${path}"
        username="$TARGET_USERNAME"
        password="$TARGET_PASSWORD"
    fi

    local -a curl_args=( -s -w '\n%{http_code}' -H 'Accept: application/vnd.schemaregistry.v1+json' )
    if [[ -n "$username" && -n "$password" ]]; then
        curl_args+=( -u "${username}:${password}" )
    fi
    curl_args+=( "$@" "$url" )

    local response
    response=$(curl "${curl_args[@]}" 2>/dev/null) || {
        _HTTP_CODE="000"
        echo ""
        return 1
    }

    # Last line is the HTTP status code
    _HTTP_CODE=$(echo "$response" | tail -n1)
    # Everything except the last line is the body
    echo "$response" | sed '$d'
}

# sr_get <source|target> <path>
# Convenience wrapper; exits on non-2xx responses.
sr_get() {
    local side="$1"
    local path="$2"
    local body
    body=$(sr_curl "$side" "$path")
    if [[ "$_HTTP_CODE" == "000" ]]; then
        echo "ERROR: Could not connect to $side SR at path $path" >&2
        echo ""
        return 1
    fi
    echo "$body"
}

# ---------------------------------------------------------------------------
# Result recording helpers
# ---------------------------------------------------------------------------
record_result() {
    local status="$1"   # PASS, WARN, FAIL
    local label="$2"
    local detail="$3"
    local extra="${4:-}"  # optional multi-line extra info

    case "$status" in
        PASS) ((PASS_COUNT++)) ;;
        WARN) ((WARN_COUNT++)) ;;
        FAIL) ((FAIL_COUNT++)) ;;
    esac

    # Pad label with dots to fixed width
    local padded
    padded=$(printf "%-28s" "$label")
    padded="${padded// /.}"

    local line
    line=$(printf "[%s] %s %s" "$status" "$padded" "$detail")
    RESULT_LINES+=("$line")

    if [[ -n "$extra" ]]; then
        # Indent extra lines
        while IFS= read -r eline; do
            RESULT_LINES+=("         $eline")
        done <<< "$extra"
    fi
}

add_json_check() {
    local name="$1"
    local status="$2"
    local detail="$3"
    local data="${4:-null}"

    JSON_CHECKS+=("$(jq -n \
        --arg name "$name" \
        --arg status "$status" \
        --arg detail "$detail" \
        --argjson data "$data" \
        '{name: $name, status: $status, detail: $detail, data: $data}'
    )")
}

# ---------------------------------------------------------------------------
# Connectivity pre-check
# ---------------------------------------------------------------------------
preflight() {
    local ok=1

    sr_curl "source" "/" >/dev/null
    if [[ "$_HTTP_CODE" != "200" && "$_HTTP_CODE" != "2"* ]]; then
        # Some SRs return empty on /, try /subjects
        sr_curl "source" "/subjects" >/dev/null
        if [[ ! "$_HTTP_CODE" =~ ^2 ]]; then
            echo "ERROR: Cannot reach source SR at ${SOURCE_URL} (HTTP ${_HTTP_CODE})" >&2
            ok=0
        fi
    fi

    sr_curl "target" "/" >/dev/null
    if [[ "$_HTTP_CODE" != "200" && "$_HTTP_CODE" != "2"* ]]; then
        sr_curl "target" "/subjects" >/dev/null
        if [[ ! "$_HTTP_CODE" =~ ^2 ]]; then
            echo "ERROR: Cannot reach target SR at ${TARGET_URL} (HTTP ${_HTTP_CODE})" >&2
            ok=0
        fi
    fi

    if [[ "$ok" -eq 0 ]]; then
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# URL-encode a subject name (handles special characters)
# ---------------------------------------------------------------------------
urlencode() {
    local string="$1"
    local length="${#string}"
    local encoded=""
    local c
    for (( i = 0; i < length; i++ )); do
        c="${string:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) encoded+="$c" ;;
            *) encoded+=$(printf '%%%02X' "'$c") ;;
        esac
    done
    echo "$encoded"
}

# ---------------------------------------------------------------------------
# Normalize a schema string for comparison.
# Parses JSON and sorts keys so that ordering differences are ignored.
# ---------------------------------------------------------------------------
normalize_schema() {
    local raw="$1"
    # The schema field may be a JSON string (escaped) or a JSON object.
    # Try to parse it as JSON; if it fails, return it as-is (e.g., PROTOBUF).
    local parsed
    parsed=$(echo "$raw" | jq -S '.' 2>/dev/null) || parsed="$raw"
    echo "$parsed"
}

# ---------------------------------------------------------------------------
# Validation Checks
# ---------------------------------------------------------------------------

# 1. Subject Count Match
check_subject_count() {
    local src_subjects_raw tgt_subjects_raw
    src_subjects_raw=$(sr_get "source" "/subjects") || { record_result "FAIL" "Subject Count" "Could not fetch source subjects"; add_json_check "subject_count" "FAIL" "Could not fetch source subjects"; return; }
    tgt_subjects_raw=$(sr_get "target" "/subjects") || { record_result "FAIL" "Subject Count" "Could not fetch target subjects"; add_json_check "subject_count" "FAIL" "Could not fetch target subjects"; return; }

    SRC_SUBJECT_COUNT=$(echo "$src_subjects_raw" | jq 'length')
    TGT_SUBJECT_COUNT=$(echo "$tgt_subjects_raw" | jq 'length')

    # Store subject lists globally for later checks
    SRC_SUBJECTS_JSON="$src_subjects_raw"
    TGT_SUBJECTS_JSON="$tgt_subjects_raw"

    if [[ "$SRC_SUBJECT_COUNT" -eq "$TGT_SUBJECT_COUNT" ]]; then
        record_result "PASS" "Subject Count" "${SRC_SUBJECT_COUNT} / ${TGT_SUBJECT_COUNT}"
        add_json_check "subject_count" "PASS" "${SRC_SUBJECT_COUNT} / ${TGT_SUBJECT_COUNT}" \
            "$(jq -n --argjson s "$SRC_SUBJECT_COUNT" --argjson t "$TGT_SUBJECT_COUNT" '{source: $s, target: $t}')"
    else
        record_result "FAIL" "Subject Count" "${SRC_SUBJECT_COUNT} / ${TGT_SUBJECT_COUNT}"
        add_json_check "subject_count" "FAIL" "${SRC_SUBJECT_COUNT} / ${TGT_SUBJECT_COUNT}" \
            "$(jq -n --argjson s "$SRC_SUBJECT_COUNT" --argjson t "$TGT_SUBJECT_COUNT" '{source: $s, target: $t}')"
    fi
}

# 2. Subject List Match
check_subject_list() {
    # Build arrays of sorted subjects
    local src_sorted tgt_sorted
    src_sorted=$(echo "$SRC_SUBJECTS_JSON" | jq -r '.[]' | sort)
    tgt_sorted=$(echo "$TGT_SUBJECTS_JSON" | jq -r '.[]' | sort)

    local missing
    missing=$(comm -23 <(echo "$src_sorted") <(echo "$tgt_sorted"))

    if [[ -z "$missing" ]]; then
        record_result "PASS" "Subject List" "All subjects present"
        add_json_check "subject_list" "PASS" "All subjects present"
    else
        local count
        count=$(echo "$missing" | wc -l | tr -d ' ')
        local extra_lines=""
        while IFS= read -r subj; do
            extra_lines+="Missing: ${subj}"$'\n'
        done <<< "$missing"
        extra_lines="${extra_lines%$'\n'}"  # trim trailing newline

        record_result "FAIL" "Subject List" "${count} subject(s) missing" "$extra_lines"
        add_json_check "subject_list" "FAIL" "${count} subject(s) missing" \
            "$(echo "$missing" | jq -R -s 'split("\n") | map(select(. != ""))')"
    fi
}

# 3-5. Version Count, Schema ID, Schema Content (per subject)
check_versions_and_schemas() {
    local version_mismatches=0
    local id_mismatches=0
    local content_mismatches=0
    local version_mismatch_details=""
    local id_mismatch_details=""
    local content_mismatch_details=""
    local subjects_checked=0

    declare -A per_subject_results=()

    # Iterate over source subjects
    local subjects
    mapfile -t subjects < <(echo "$SRC_SUBJECTS_JSON" | jq -r '.[]')

    local total=${#subjects[@]}

    for subject in "${subjects[@]}"; do
        ((subjects_checked++))
        # Progress indicator on stderr
        if (( subjects_checked % 20 == 0 )) || (( subjects_checked == total )); then
            printf "\r  Checking subjects: %d / %d" "$subjects_checked" "$total" >&2
        fi

        local encoded_subject
        encoded_subject=$(urlencode "$subject")

        local src_versions_raw tgt_versions_raw
        src_versions_raw=$(sr_get "source" "/subjects/${encoded_subject}/versions") || continue
        tgt_versions_raw=$(sr_get "target" "/subjects/${encoded_subject}/versions") || {
            # Subject might be missing on target; already caught by subject list check
            ((version_mismatches++))
            version_mismatch_details+="${subject}: target subject not found"$'\n'
            per_subject_results["$subject"]='{"versions":"FAIL","ids":"SKIP","content":"SKIP"}'
            continue
        }

        local src_ver_count tgt_ver_count
        src_ver_count=$(echo "$src_versions_raw" | jq 'length')
        tgt_ver_count=$(echo "$tgt_versions_raw" | jq 'length')

        local subj_version_ok="PASS"
        local subj_id_ok="PASS"
        local subj_content_ok="PASS"

        # 3. Version count
        if [[ "$src_ver_count" -ne "$tgt_ver_count" ]]; then
            ((version_mismatches++))
            version_mismatch_details+="${subject}: ${src_ver_count} (source) vs ${tgt_ver_count} (target)"$'\n'
            subj_version_ok="FAIL"
        fi

        # Compare each version present in source
        local versions
        mapfile -t versions < <(echo "$src_versions_raw" | jq -r '.[]')

        for ver in "${versions[@]}"; do
            local src_schema_raw tgt_schema_raw
            src_schema_raw=$(sr_get "source" "/subjects/${encoded_subject}/versions/${ver}") || continue
            tgt_schema_raw=$(sr_get "target" "/subjects/${encoded_subject}/versions/${ver}") || {
                ((id_mismatches++))
                id_mismatch_details+="${subject} v${ver}: version missing on target"$'\n'
                subj_id_ok="FAIL"
                subj_content_ok="FAIL"
                continue
            }

            # 4. Schema ID match
            local src_id tgt_id
            src_id=$(echo "$src_schema_raw" | jq '.id')
            tgt_id=$(echo "$tgt_schema_raw" | jq '.id')

            if [[ "$src_id" != "$tgt_id" ]]; then
                ((id_mismatches++))
                id_mismatch_details+="${subject} v${ver}: id ${src_id} (source) vs ${tgt_id} (target)"$'\n'
                subj_id_ok="FAIL"
            fi

            # 5. Schema content match
            local src_schema tgt_schema
            src_schema=$(echo "$src_schema_raw" | jq -r '.schema')
            tgt_schema=$(echo "$tgt_schema_raw" | jq -r '.schema')

            local src_normalized tgt_normalized
            src_normalized=$(normalize_schema "$src_schema")
            tgt_normalized=$(normalize_schema "$tgt_schema")

            if [[ "$src_normalized" != "$tgt_normalized" ]]; then
                ((content_mismatches++))
                content_mismatch_details+="${subject} v${ver}: schema content differs"$'\n'
                subj_content_ok="FAIL"
            fi
        done

        per_subject_results["$subject"]=$(jq -n \
            --arg v "$subj_version_ok" \
            --arg i "$subj_id_ok" \
            --arg c "$subj_content_ok" \
            '{versions: $v, ids: $i, content: $c}')
    done

    # Clear progress line
    printf "\r%80s\r" "" >&2

    # 3. Version Count result
    if [[ "$version_mismatches" -eq 0 ]]; then
        record_result "PASS" "Version Counts" "All match"
        add_json_check "version_counts" "PASS" "All match"
    else
        version_mismatch_details="${version_mismatch_details%$'\n'}"
        record_result "FAIL" "Version Counts" "${version_mismatches} mismatch(es)" "$version_mismatch_details"
        add_json_check "version_counts" "FAIL" "${version_mismatches} mismatch(es)" \
            "$(echo "$version_mismatch_details" | jq -R -s 'split("\n") | map(select(. != ""))')"
    fi

    # 4. Schema IDs result
    if [[ "$id_mismatches" -eq 0 ]]; then
        record_result "PASS" "Schema IDs" "All match"
        add_json_check "schema_ids" "PASS" "All match"
    else
        id_mismatch_details="${id_mismatch_details%$'\n'}"
        record_result "FAIL" "Schema IDs" "${id_mismatches} mismatch(es)" "$id_mismatch_details"
        add_json_check "schema_ids" "FAIL" "${id_mismatches} mismatch(es)" \
            "$(echo "$id_mismatch_details" | jq -R -s 'split("\n") | map(select(. != ""))')"
    fi

    # 5. Schema Content result
    if [[ "$content_mismatches" -eq 0 ]]; then
        record_result "PASS" "Schema Content" "All match"
        add_json_check "schema_content" "PASS" "All match"
    else
        content_mismatch_details="${content_mismatch_details%$'\n'}"
        record_result "FAIL" "Schema Content" "${content_mismatches} mismatch(es)" "$content_mismatch_details"
        add_json_check "schema_content" "FAIL" "${content_mismatches} mismatch(es)" \
            "$(echo "$content_mismatch_details" | jq -R -s 'split("\n") | map(select(. != ""))')"
    fi

    # Build per-subject JSON for report
    PER_SUBJECT_JSON="{"
    local first=1
    for subject in "${!per_subject_results[@]}"; do
        if [[ "$first" -eq 1 ]]; then
            first=0
        else
            PER_SUBJECT_JSON+=","
        fi
        local escaped_subject
        escaped_subject=$(echo "$subject" | jq -Rs '.')
        PER_SUBJECT_JSON+="${escaped_subject}:${per_subject_results[$subject]}"
    done
    PER_SUBJECT_JSON+="}"
}

# 6. Compatibility Config Match
check_compatibility() {
    # 6a. Global compatibility
    local src_compat_raw tgt_compat_raw
    src_compat_raw=$(sr_get "source" "/config")
    tgt_compat_raw=$(sr_get "target" "/config")

    local src_global_compat tgt_global_compat
    # The field may be "compatibilityLevel" or "compatibility" depending on SR version
    src_global_compat=$(echo "$src_compat_raw" | jq -r '.compatibilityLevel // .compatibility // "UNKNOWN"')
    tgt_global_compat=$(echo "$tgt_compat_raw" | jq -r '.compatibilityLevel // .compatibility // "UNKNOWN"')

    if [[ "$src_global_compat" == "$tgt_global_compat" ]]; then
        record_result "PASS" "Global Compatibility" "${src_global_compat} / ${tgt_global_compat}"
        add_json_check "global_compatibility" "PASS" "${src_global_compat} / ${tgt_global_compat}" \
            "$(jq -n --arg s "$src_global_compat" --arg t "$tgt_global_compat" '{source: $s, target: $t}')"
    else
        record_result "WARN" "Global Compatibility" "${src_global_compat} / ${tgt_global_compat}"
        add_json_check "global_compatibility" "WARN" "${src_global_compat} vs ${tgt_global_compat}" \
            "$(jq -n --arg s "$src_global_compat" --arg t "$tgt_global_compat" '{source: $s, target: $t}')"
    fi

    # 6b. Per-subject compatibility
    local compat_mismatches=0
    local compat_mismatch_details=""

    local subjects
    mapfile -t subjects < <(echo "$SRC_SUBJECTS_JSON" | jq -r '.[]')

    for subject in "${subjects[@]}"; do
        local encoded_subject
        encoded_subject=$(urlencode "$subject")

        local src_subj_compat_raw tgt_subj_compat_raw
        src_subj_compat_raw=$(sr_curl "source" "/config/${encoded_subject}")
        local src_http="$_HTTP_CODE"
        tgt_subj_compat_raw=$(sr_curl "target" "/config/${encoded_subject}")
        local tgt_http="$_HTTP_CODE"

        # A 404 means the subject uses the global default -- that is fine.
        local src_subj_compat="DEFAULT"
        local tgt_subj_compat="DEFAULT"

        if [[ "$src_http" =~ ^2 ]]; then
            src_subj_compat=$(echo "$src_subj_compat_raw" | jq -r '.compatibilityLevel // .compatibility // "DEFAULT"')
        fi
        if [[ "$tgt_http" =~ ^2 ]]; then
            tgt_subj_compat=$(echo "$tgt_subj_compat_raw" | jq -r '.compatibilityLevel // .compatibility // "DEFAULT"')
        fi

        if [[ "$src_subj_compat" != "$tgt_subj_compat" ]]; then
            ((compat_mismatches++))
            compat_mismatch_details+="${subject}: ${src_subj_compat} (source) vs ${tgt_subj_compat} (target)"$'\n'
        fi
    done

    if [[ "$compat_mismatches" -eq 0 ]]; then
        record_result "PASS" "Subject Compatibility" "All match"
        add_json_check "subject_compatibility" "PASS" "All match"
    else
        compat_mismatch_details="${compat_mismatch_details%$'\n'}"
        record_result "WARN" "Subject Compatibility" "${compat_mismatches} mismatch(es)" "$compat_mismatch_details"
        add_json_check "subject_compatibility" "WARN" "${compat_mismatches} mismatch(es)" \
            "$(echo "$compat_mismatch_details" | jq -R -s 'split("\n") | map(select(. != ""))')"
    fi
}

# 7. Mode Check
check_mode() {
    local tgt_mode_raw
    tgt_mode_raw=$(sr_curl "target" "/mode")
    local tgt_http="$_HTTP_CODE"

    local tgt_mode="UNKNOWN"
    if [[ "$tgt_http" =~ ^2 ]]; then
        tgt_mode=$(echo "$tgt_mode_raw" | jq -r '.mode // "UNKNOWN"')
    elif [[ "$tgt_http" == "404" ]]; then
        # Some SR versions do not expose /mode; assume READWRITE
        tgt_mode="READWRITE (assumed, /mode not available)"
    fi

    if [[ "$tgt_mode" == "READWRITE" ]]; then
        record_result "PASS" "Target Mode" "READWRITE"
        add_json_check "target_mode" "PASS" "READWRITE"
    elif [[ "$tgt_mode" == "IMPORT" ]]; then
        record_result "FAIL" "Target Mode" "IMPORT (should be READWRITE)"
        add_json_check "target_mode" "FAIL" "IMPORT (should be READWRITE)"
    else
        record_result "WARN" "Target Mode" "$tgt_mode"
        add_json_check "target_mode" "WARN" "$tgt_mode"
    fi
}

# ---------------------------------------------------------------------------
# Report generation
# ---------------------------------------------------------------------------
generate_json_report() {
    local checks_array="["
    local first=1
    for c in "${JSON_CHECKS[@]}"; do
        if [[ "$first" -eq 1 ]]; then
            first=0
        else
            checks_array+=","
        fi
        checks_array+="$c"
    done
    checks_array+="]"

    local per_subject="${PER_SUBJECT_JSON:-{\}}"

    jq -n \
        --arg source_url "$SOURCE_URL" \
        --arg target_url "$TARGET_URL" \
        --arg date "$(date '+%Y-%m-%d %H:%M:%S')" \
        --argjson pass "$PASS_COUNT" \
        --argjson warn "$WARN_COUNT" \
        --argjson fail "$FAIL_COUNT" \
        --argjson checks "$checks_array" \
        --argjson per_subject "$per_subject" \
        '{
            source_url: $source_url,
            target_url: $target_url,
            validation_date: $date,
            summary: {
                pass: $pass,
                warn: $warn,
                fail: $fail,
                overall: (if $fail > 0 then "FAIL" elif $warn > 0 then "WARN" else "PASS" end)
            },
            checks: $checks,
            per_subject_results: $per_subject
        }' > "$REPORT_FILE"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    check_prerequisites
    preflight

    local run_date
    run_date=$(date '+%Y-%m-%d %H:%M:%S')

    echo ""
    echo "============================================"
    echo "  Schema Registry Migration Validation"
    echo "============================================"
    echo "Source: ${SOURCE_URL}"
    echo "Target: ${TARGET_URL}"
    echo "Date: ${run_date}"
    echo "--------------------------------------------"
    echo ""

    # Initialize global subject data
    SRC_SUBJECTS_JSON=""
    TGT_SUBJECTS_JSON=""
    SRC_SUBJECT_COUNT=0
    TGT_SUBJECT_COUNT=0
    PER_SUBJECT_JSON="{}"

    check_subject_count
    check_subject_list
    check_versions_and_schemas
    check_compatibility
    check_mode

    # Print results
    for line in "${RESULT_LINES[@]}"; do
        echo "$line"
    done

    echo ""
    echo "============================================"
    printf "  Summary: %d PASS | %d WARN | %d FAIL\n" "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
    echo "============================================"
    echo ""

    # Generate JSON report
    generate_json_report
    echo "Detailed report written to: ${REPORT_FILE}"
    echo ""

    # Exit code: 0 if no failures, 1 if any failures
    if [[ "$FAIL_COUNT" -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main
