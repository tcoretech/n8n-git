#!/usr/bin/env bash
#
# n8n Credentials Decryption Tool
# Decrypts n8n credentials encrypted with CryptoJS AES-256-CBC encryption
#
# Usage:
#   ./decrypt_n8n_credentials.sh <input.json> <output.json>
#   
# The script will prompt for the encryption key interactively.
# Input should be an exported n8n credentials JSON file (array format).
#
# Dependencies: jq, openssl, xxd
#
set -euo pipefail
IFS=$'\n\t'

# Constants
readonly AES_KEY_LEN=32  # 256 bits for AES-256
readonly AES_IV_LEN=16   # 128 bits IV
readonly SALTED_HEADER="53616c7465645f5f"  # "Salted__" in hex

# Print error message to stderr and exit
die() {
    local message="$1"
    local code="${2:-1}"
    echo "Error: $message" >&2
    if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
        exit "$code"
    else
        return "$code"
    fi
}

# Check required dependencies
check_dependencies() {
    local missing=()
    
    command -v jq >/dev/null 2>&1 || missing+=("jq")
    command -v openssl >/dev/null 2>&1 || missing+=("openssl")
    command -v xxd >/dev/null 2>&1 || missing+=("xxd")
    
    if [ ${#missing[@]} -gt 0 ]; then
        die "Missing required dependencies: ${missing[*]}" 2
        return 2
    fi
}

# Implement OpenSSL EVP_BytesToKey with MD5
# This matches the CryptoJS/OpenSSL key derivation algorithm
#
# Args:
#   $1: password (plaintext)
#   $2: salt (hex string, can be empty)
#   $3: key length in bytes
#   $4: IV length in bytes
# 
# Returns: key:iv (both as hex strings)
evp_bytes_to_key() {
    local password="$1"
    local salt_hex="$2"
    local key_len="$3"
    local iv_len="$4"
    
    local derived=""
    local prev=""
    local required_len=$((key_len + iv_len))
    
    # Iteratively hash until we have enough bytes for key + IV
    while [ ${#derived} -lt $((required_len * 2)) ]; do
        local to_hash=""
        
        # Concatenate: previous_hash + password + salt
        [ -n "$prev" ] && to_hash="$prev"
        to_hash="${to_hash}$(printf '%s' "$password" | xxd -p -c 256)"
        to_hash="${to_hash}${salt_hex}"
        
        # Hash with MD5 and append to derived material
        prev=$(echo -n "$to_hash" | xxd -r -p | openssl dgst -md5 -binary | xxd -p -c 256)
        derived="${derived}${prev}"
    done
    
    # Split derived bytes into key and IV
    local key_hex="${derived:0:$((key_len * 2))}"
    local iv_hex="${derived:$((key_len * 2)):$((iv_len * 2))}"
    
    echo "${key_hex}:${iv_hex}"
}

# Decrypt a single credential entry
#
# Args:
#   $1: base64 encrypted data
#   $2: encryption key (passphrase)
#   $3: temporary directory path
#
# Returns: decrypted plaintext or empty string on failure
# Exit code: 0 on success, 1 on failure
decrypt_credential() {
    local encrypted_b64="$1"
    local passphrase="$2"
    local tmpdir="$3"
    
    local cipher_file="$tmpdir/cipher.bin"
    local decrypted_file="$tmpdir/decrypted.txt"
    
    # Decode base64 to binary
    if ! printf '%s' "$encrypted_b64" | base64 -d > "$cipher_file" 2>/dev/null; then
        if ! printf '%s' "$encrypted_b64" | openssl base64 -d -A > "$cipher_file" 2>/dev/null; then
            return 1
        fi
    fi
    
    # Check for "Salted__" header and extract salt
    local salt_hex=""
    local ciphertext_file="$tmpdir/ciphertext.bin"
    
    local header
    header=$(xxd -p -l 8 "$cipher_file" | tr -d '\n')
    
    if [ "$header" = "$SALTED_HEADER" ]; then
        # Extract 8-byte salt after "Salted__" header
        salt_hex=$(xxd -p -s 8 -l 8 "$cipher_file" | tr -d '\n')
        # Extract actual ciphertext (skip 16-byte header+salt)
        dd if="$cipher_file" bs=1 skip=16 of="$ciphertext_file" 2>/dev/null
    else
        # No salt header, use entire file as ciphertext
        salt_hex=""
        cp "$cipher_file" "$ciphertext_file"
    fi
    
    # Derive key and IV using EVP_BytesToKey
    local key_iv
    key_iv=$(evp_bytes_to_key "$passphrase" "$salt_hex" "$AES_KEY_LEN" "$AES_IV_LEN")
    
    local key_hex="${key_iv%:*}"
    local iv_hex="${key_iv#*:}"
    
    # Decrypt using AES-256-CBC
    if openssl enc -d -aes-256-cbc \
        -K "$key_hex" \
        -iv "$iv_hex" \
        -in "$ciphertext_file" \
        -out "$decrypted_file" 2>/dev/null; then
        cat "$decrypted_file"
        return 0
    fi
    
    return 1
}

# Process credentials file
#
# Args:
#   $1: encryption key (passphrase)
#   $2: input JSON file path
#   $3: output JSON file path
decrypt_credentials_file() {
    local passphrase="$1"
    local input_file="$2"
    local output_file="$3"
    
    # Validate inputs
    if [ -z "$passphrase" ]; then
        die "Encryption key is required"
        return 1
    fi
    if [ ! -f "$input_file" ]; then
        die "Input file not found: $input_file"
        return 1
    fi
    
    # Create temporary directory
    local tmpdir
    tmpdir=$(mktemp -d 2>/dev/null || mktemp -d -t n8n-decrypt-XXXXXX)
    trap 'rm -rf '"$tmpdir"'; trap - RETURN' RETURN
    
    # Convert JSON array to line-delimited entries
    if ! jq -c 'if type=="array" then .[] else . end' "$input_file" > "$tmpdir/entries.txt"; then
        die "Failed to parse input JSON file"
        return 1
    fi
    
    # Process each credential entry
    local output_json="["
    local first_entry=true
    local success_count=0
    local skip_count=0
    local fail_count=0
    
    while IFS= read -r entry_json || [ -n "$entry_json" ]; do
        # Extract encrypted data field
        local data_field
        data_field=$(jq -r 'if type=="object" and has("data") then .data else "" end' <<<"$entry_json")
        
        if [ -z "$data_field" ] || [ "$data_field" = "null" ]; then
            # No data field, pass through unchanged
            skip_count=$((skip_count + 1))
            new_entry="$entry_json"
        else
            # Attempt decryption
            if decrypted=$(decrypt_credential "$data_field" "$passphrase" "$tmpdir"); then
                # Success - update entry with decrypted data
                new_entry=$(jq -c --arg dec "$decrypted" \
                    '.data = (try ($dec | fromjson) catch $dec)' <<<"$entry_json")
                success_count=$((success_count + 1))
            else
                # Failure - mark entry with error
                new_entry=$(jq -c '.data = null | . + {decryptionError: "Failed to decrypt"}' <<<"$entry_json")
                fail_count=$((fail_count + 1))
            fi
        fi
        
        # Append to output array
        if [ "$first_entry" = true ]; then
            first_entry=false
            output_json="${output_json}${new_entry}"
        else
            output_json="${output_json},${new_entry}"
        fi
    done < "$tmpdir/entries.txt"
    
    output_json="${output_json}]"
    
    # Write output file
    printf '%s' "$output_json" | jq '.' > "$output_file"
    
    # Report results
    echo "Decryption complete:" >&2
    echo "  ✓ Decrypted: $success_count" >&2
    echo "  ⊘ Skipped: $skip_count" >&2
    if [ $fail_count -gt 0 ]; then
        echo "  ✗ Failed: $fail_count" >&2
        return 1
    fi

    return 0
}

# Main entry point
main() {
    if [ $# -ne 2 ]; then
        cat >&2 << EOF
Usage: $(basename "$0") <input.json> <output.json>

Decrypts n8n credentials exported as JSON.

Arguments:
  input.json   - Exported n8n credentials file
  output.json  - Output file for decrypted credentials

The encryption key will be prompted for securely.

EOF
        exit 1
    fi
    
    local input_file="$1"
    local output_file="$2"
    
    # Check dependencies
    check_dependencies
    
    # Prompt for encryption key
    local encryption_key
    read -r -s -p "Enter encryption key: " encryption_key
    echo >&2
    
    # Decrypt credentials
    decrypt_credentials_file "$encryption_key" "$input_file" "$output_file"
}

# Run main function if executed directly
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi