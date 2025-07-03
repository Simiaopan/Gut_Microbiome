#!/usr/bin/env bash
set -u  # no undefined variable

file="$1"
dest_dir="$2"
pod="$3"
logfile="$4"
loglock="$5"
success_log="$6"
failure_log="$7"

log() {
    (
        flock -x 200
        echo "$(date '+%F %T') | $*" | tee -a "$logfile"
    ) 200>>"$loglock"
}

upload_file() { 
    local filename dirname original_dir local_checksum remote_checksum remote_checksum_after local_size remote_size upload_method
    filename=$(basename "$file")
    dirname=$(dirname "$file")
    original_dir=$(pwd)

    cd "$dirname" || {
        log "❌ Failed to enter directory: $dirname"
        return 1
    }
    log "==> Entered directory: $dirname"

    if [[ ! -f "$filename" ]]; then
        log "❌ Local file not found: $filename (in $dirname)"
        cd "$original_dir" || true
        return 1
    fi

    log "==> Verifying target directory: '$dest_dir'"
    if ! oc exec "$pod" -- bash -c "ls -d \"$dest_dir\"" &>/dev/null; then
        log "❌ Target directory does not exist: '$dest_dir'"
        cd "$original_dir" || true
        return 1
    fi

    local_checksum=$(md5sum "$filename" | awk '{print $1}')
    remote_checksum=$(oc exec "$pod" -- bash -c "md5sum '$dest_dir/$filename'" 2>/dev/null | awk '{print $1}' || echo "")

    if [[ "$local_checksum" == "$remote_checksum" ]]; then
        log "✅ Skipped (already uploaded and verified): $filename"
        cd "$original_dir" || true
        return 0
    fi

    local retries=3
    local success=0

    for ((i=1; i<=retries; i++)); do
        log "==> Uploading: $filename (Attempt $i)"

        if oc cp "$filename" "$pod:$dest_dir/$filename" 2> >(while read -r line; do log "OC_DEBUG: $line"; done); then
            upload_method="oc cp"
        else
            log "⚠️ oc cp failed, trying base64 method"
            if base64 "$filename" | oc exec "$pod" -- bash -c "base64 -d > '$dest_dir/$filename'"; then
                upload_method="base64"
            else
                log "❌ Base64 upload failed"
                continue
            fi
        fi

        sleep 2

        local_size=$(wc -c < "$filename")
        remote_size=$(oc exec "$pod" -- bash -c "wc -c < '$dest_dir/$filename'" 2>/dev/null || echo "0")

        log "==> Size check: local=$local_size bytes, remote=$remote_size bytes (method: $upload_method)"
        if [[ "$local_size" != "$remote_size" ]]; then
            log "❌ Size mismatch: $filename"
            continue
        fi

        remote_md5_output=$(oc exec "$pod" -- bash -c "md5sum '$dest_dir/$filename'" 2>&1)
        remote_checksum_after=$(echo "$remote_md5_output" | awk '{print $1}' || echo "")
        log "==> MD5 check: local=$local_checksum, remote=$remote_checksum_after"

        if [[ "$local_checksum" == "$remote_checksum_after" ]]; then
            success=1
            break
        else
            log "❌ MD5 mismatch after upload: $filename"
        fi
    done

    cd "$original_dir" || true

    if [[ $success -eq 1 ]]; then
        log "✅ Upload successful: $filename (method: $upload_method)"
        return 0
    else
        log "❌ Upload failed after $retries attempts: $filename"
        return 1
    fi
}

if upload_file; then
    echo "$file" >> "$success_log"
else
    echo "$file" >> "$failure_log"
fi
