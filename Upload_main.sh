#!/usr/bin/env bash
set -x
set -euo pipefail

# ========== Configuration ==========
INPUT_LIST="/c/Users/P70096443/fastq_1.txt"
UPLOAD_PATH="/home/jovyan/work/persistent/project_1/Raw_Data"
POD_NAME="jupyterlab-1-ghf9s"
THREADS=4
LOG_FILE="/c/Users/P70096443/Log_2.txt"
LOG_LOCK_FILE="${LOG_FILE}.lock"
UPLOAD_SCRIPT="/c/Users/P70096443/Upload_single.sh"

# ========== Preparation ==========
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_LOCK_FILE"

TMP_FILES=()
cleanup() {
    for tmp in "${TMP_FILES[@]}"; do
        [[ -f "$tmp" ]] && rm -f "$tmp"
    done
}
trap 'echo "⚠️ Script interrupted, exiting"; cleanup; exit 1' INT TERM
trap cleanup EXIT

# ========== Environment Check ==========
for cmd in oc find grep xargs md5sum flock; do
    command -v "$cmd" &>/dev/null || { echo "❌ Missing command: $cmd"; exit 1; }
done
oc whoami &>/dev/null || { echo "❌ Not logged in to OpenShift, please run oc login"; exit 1; }
oc get pod "$POD_NAME" &>/dev/null || { echo "❌ Pod not found: $POD_NAME"; exit 1; }

# ========== Main Process ==========

if [[ ! -s "$INPUT_LIST" ]]; then
  echo "Input is empty: $INPUT_LIST" >&2
  exit 1
fi

set +e
line_num=0
while IFS= read -r raw_path || [[ -n "$raw_path" ]]; do
    ((line_num++))
    raw_path=$(echo "$raw_path" | tr -d '\r' | sed 's:/*$::')
    echo "$(date '+%F %T') | Processing line $line_num: [$raw_path]" | tee -a "$LOG_FILE"

    run_name=""
    IFS='/' read -ra parts <<< "$raw_path"
    for part in "${parts[@]}"; do
        [[ -z "$part" ]] && continue
        if [[ "$part" =~ [Rr][Uu][Nn] ]] && [[ "$part" =~ [0-9] ]]; then
            run_name="$part"
            break
        fi
    done
    if [[ -z "$run_name" ]]; then
        run_name=$(basename "$raw_path")
    fi

    echo "$(date '+%F %T') | Using directory name: $run_name" | tee -a "$LOG_FILE"

    full_upload_path="$UPLOAD_PATH/$run_name"
    echo "$(date '+%F %T') | Ensuring target directory exists: $full_upload_path" | tee -a "$LOG_FILE"

    if ! oc exec "$POD_NAME" -- bash -c "mkdir -p \"$full_upload_path\""; then
        echo "$(date '+%F %T') | ❌ Failed to create directory: $full_upload_path" | tee -a "$LOG_FILE"
        continue
    fi

    if ! oc exec "$POD_NAME" -- bash -c "ls -ld \"$full_upload_path\""; then
        echo "$(date '+%F %T') | ❗ Failed to verify directory: $full_upload_path" | tee -a "$LOG_FILE"
        continue
    fi

    TMP_FASTQ_LIST=$(mktemp)
    TMP_FILES+=("$TMP_FASTQ_LIST")
    find "$raw_path" -type f -iname "*.fastq.gz" ! -iname "*undetermined*" > "$TMP_FASTQ_LIST"

    SUCCESS_LOG=$(mktemp)
    FAILURE_LOG=$(mktemp)
    TMP_FILES+=("$SUCCESS_LOG" "$FAILURE_LOG")

    # Run upload, tolerate partial failure
    set +e
    cat "$TMP_FASTQ_LIST" | xargs -d '\n' -P "$THREADS" -I {} bash "$UPLOAD_SCRIPT" \
        "{}" "$full_upload_path" "$POD_NAME" "$LOG_FILE" "$LOG_LOCK_FILE" "$SUCCESS_LOG" "$FAILURE_LOG"
    xargs_status=$?
    set -e

    success_count=$(wc -l < "$SUCCESS_LOG" | tr -d ' ')
    failure_count=$(wc -l < "$FAILURE_LOG" | tr -d ' ')
    echo "$(date '+%F %T') | Done: $raw_path | Success: $success_count | Failure: $failure_count" | tee -a "$LOG_FILE"

    if [[ $xargs_status -ne 0 || $failure_count -gt 0 ]]; then
        echo "$(date '+%F %T') | ⚠️ Warning: some files failed to upload in [$raw_path]" | tee -a "$LOG_FILE"
    fi

done < "$INPUT_LIST"
set -e