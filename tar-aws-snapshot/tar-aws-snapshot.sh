#!/bin/sh

# Copyright (c) 2024 caydey

# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.


CONFIG_PATH="/root/tar-snapshot-config"
SNAR_FILENAME="index.snar"

# DRY_RUN_FOLDER=/tmpdisk/tar

function check_initialised() { # 1=CONFIG_PATH
  local CONFIG_PATH="$1"

  local FILES_CREATED=false # bool flag

  local INCLUDE_FILE="$CONFIG_PATH/include.list"
  if [[ ! -f "$INCLUDE_FILE" ]]; then
    echo "/home/*/Documents" > "$INCLUDE_FILE"
    FILES_CREATED=true
  fi

  local INJECT_FILE="$CONFIG_PATH/injectors.sh"
  if [[ ! -f "$INJECT_FILE" ]]; then
    echo "#!/bin/sh"                                                > "$INJECT_FILE"
    echo "# functions must start with \"inject_\""                  >> "$INJECT_FILE"
    echo "function inject_lsblk() { lsblk -OJ > "$1/lsblk.json"; }" >> "$INJECT_FILE"
    chmod +x "$INJECT_FILE"
    FILES_CREATED=true
  fi

  local SECRETS_FILE="$CONFIG_PATH/secrets.config"
  if [[ ! -f "$SECRETS_FILE" ]]; then
    echo "AWS_ACCESS_KEY_ID="       > "$SECRETS_FILE"
    echo "AWS_SECRET_ACCESS_KEY="   >> "$SECRETS_FILE"
    echo "AWS_DEFAULT_REGION="      >> "$SECRETS_FILE"
    echo "AWS_BUCKET_NAME="         >> "$SECRETS_FILE"
    echo "SECRET_MASTER_KEY="       >> "$SECRETS_FILE"
    echo "SECRET_MASTER_KEY_HINT="  >> "$SECRETS_FILE"
    FILES_CREATED=true
  fi

  if $FILES_CREATED; then
    echo "config files initialised at $CONFIG_PATH"
    echo "please review them before re-running this script"
    exit 1
  fi
}

function reviewSnapshot() { # 1=SNAPSHOT_OUTPUT
  SNAPSHOT_SIZE=$(du -h "$1" | awk '{ print $1 }')
  read -e -p "Upload Snapshot ($SNAPSHOT_SIZE)? [Y/n]: " yn
  if [[ "$yn" != "" ]] && [[ "$yn" != [Yy]* ]]; then
    echo "exiting"
    exit 1
  fi
}

function displayBucketInfo() {
  if [ -n "$DRY_RUN_FOLDER" ]; then
    return
  fi

  local SNAPSHOT_COUNT=$(echo "$BUCKET_FILE_LIST" | jq -r "[.Contents[]? | select(.Key != \"$SNAR_FILENAME.gpg\")] | length")

  if [ "$SNAPSHOT_COUNT" == "0" ]; then
    echo "First Snapshot"
  else
    local TOTAL_BUCKET_SIZE=$(echo "$BUCKET_FILE_LIST" | jq -r '[.Contents[]?.Size] | add' | numfmt --to=iec)
    local LAST_SNAPSHOT_SIZE=$(echo "$BUCKET_FILE_LIST" | jq -r "[.Contents[]?] | max_by(.LastModified) | .Size" | numfmt --to=iec)
    local LAST_SNAPSHOT_MODIFIED_RAW=$(echo "$BUCKET_FILE_LIST" | jq -r "[.Contents[]? | select(.Key != \"$SNAR_FILENAME.gpg\")] | max_by(.LastModified) | .LastModified")
    local LAST_SNAPSHOT_MODIFIED=$(date -d "$LAST_SNAPSHOT_MODIFIED_RAW" +'%Y/%m/%d %H:%M:%S')

    echo "Snapshots: $SNAPSHOT_COUNT ($TOTAL_BUCKET_SIZE)  Last: $LAST_SNAPSHOT_MODIFIED ($LAST_SNAPSHOT_SIZE)"
  fi
}

function encryptFile() { # 1=INPUT, 2=OUTPUT
  if [ ! -n "$SECRET_MASTER_KEY" ]; then
    echo "WARNING, ENCRYPTION KEY NOT SET, exiting..."
    exit 1
  fi

  printf "Encrypting $(basename "$1")..."
  gpg --symmetric --batch \
    --cipher-algo AES256 --compress-algo none \
    --passphrase "$SECRET_MASTER_KEY" \
    --output "$2" "$1"
  rm "$1"
  echo " Done"
}

function decryptFile() {
  gpg --decrypt --batch --quiet \
    --cipher-algo AES256 --compress-algo none \
    --passphrase "$SECRET_MASTER_KEY" \
    --output "$2" "$1"
}

function getBucketFileList() {
  if [ ! -n "$DRY_RUN_FOLDER" ]; then
    aws s3api list-objects-v2 --bucket "$AWS_BUCKET_NAME"
  fi
}

function downloadIndexSnar() { # 1=OUTPUT
  local OUTPUT="$1"

  if [ -n "$DRY_RUN_FOLDER" ]; then
    if [ -f "$DRY_RUN_FOLDER/$SNAR_FILENAME.gpg" ]; then
      decryptFile "$DRY_RUN_FOLDER/$SNAR_FILENAME.gpg" "$OUTPUT"
    else
      touch "$OUTPUT"
    fi
  else
    if echo "$BUCKET_FILE_LIST" | jq -r '.Contents[]? | .Key' | grep -q "$SNAR_FILENAME.gpg"; then
      local TMP_ENC_INDEX_SNAR="$TMP_FOLDER/$SNAR_FILENAME.gpg"
      aws s3api get-object --bucket $AWS_BUCKET_NAME --key "$SNAR_FILENAME.gpg" "$TMP_ENC_INDEX_SNAR" > /dev/null
      decryptFile "$TMP_ENC_INDEX_SNAR" "$OUTPUT"
      rm "$TMP_ENC_INDEX_SNAR"
    else
      touch "$OUTPUT"
    fi
  fi
}

function getSnapshotName() {
  local SNAP_NUMBER=0
  if [ -n "$DRY_RUN_FOLDER" ]; then
    SNAP_NUMER=$(ls -1 "$DRY_RUN_FOLDER" | grep -v "$SNAR_FILENAME.gpg" | wc -l)
  else
    SNAP_NUMBER=$(echo "$BUCKET_FILE_LIST" | jq -r "[.Contents[]? | select(.Key != \"$SNAR_FILENAME.gpg\")] | length")
  fi
  echo "$(date +'%y%m%d-%H%M%S').$SNAP_NUMBER.tar.zst"
}

function uploadFile() { # 1=INPUT, 2=STORAGE_CLASS
  local INPUT="$1"
  local STORAGE_CLASS="$2"
  # ensure only encrypted files are uploaded
  if file "$INPUT" | grep -qv "PGP symmetric key encrypted data"; then
    echo "WARNING, ATTEMPTED TO UPLOAD AN UNENCRYPTED FILE, exiting..."
    exit 1
  fi
  local FILE_KEY=$(basename "$INPUT")

  printf "Uploading $FILE_KEY..."
  if [ -n "$DRY_RUN_FOLDER" ]; then
    cp "$INPUT" "$DRY_RUN_FOLDER/$FILE_KEY"
  else
    aws s3 cp "$INPUT" "s3://$AWS_BUCKET_NAME/$FILE_KEY" \
      --storage-class "$STORAGE_CLASS" \
      --quiet
    # tag with password hint
    local TAG=$(jq -n -c --arg password "$SECRET_MASTER_KEY_HINT" '{ "TagSet": [{ "Key": "password", "Value": $password }] }')
    aws s3api put-object-tagging \
      --bucket "$AWS_BUCKET_NAME" \
      --key "$FILE_KEY" \
      --tagging "$TAG"
  fi
  echo "Done"
}

function createSnapshot() { # 1=CONFIG_PATH, 2=INDEX_SNAR, 3=SNAPSHOT_OUTPUT 
  local CONFIG_PATH="$1"
  local INDEX_SNAR="$2"
  local SNAPSHOT_OUTPUT="$3"

  local INJECT_FOLDER="$TMP_FOLDER/inject"
  mkdir "$INJECT_FOLDER"

  ## Run injectors (files for tar --transform)
  printf "Running injectors"
  source "$CONFIG_PATH/injectors.sh"
  for injector in $(declare -F | grep "declare -f inject_" | awk '{ print $3 }'); do
    printf "."
    $injector "$INJECT_FOLDER"
  done
  echo " Done"

  cat "$CONFIG_PATH"/exclude*.list 2> /dev/null > "$INJECT_FOLDER/exclude.list"
  echo "$INJECT_FOLDER" > "$INJECT_FOLDER/include.list"
  cat "$CONFIG_PATH/include.list" >> "$INJECT_FOLDER/include.list"

  local transform="--transform=s|^$INJECT_FOLDER|/inject|"

    # --use-compress-program "pixz -9" \
  printf "Creating tarball..."
  tar \
    --use-compress-program "zstd -9 -T0" \
    --acls --xattrs \
    --absolute-names \
    --create --file="$SNAPSHOT_OUTPUT" \
    --listed-incremental="$INDEX_SNAR" \
    --wildcards-match-slash --exclude-from="$INJECT_FOLDER/exclude.list" \
    --transform="s|^$INJECT_FOLDER|/inject|" \
    --files-from="$INJECT_FOLDER/include.list" 
  echo " Done"
  rm -r "$INJECT_FOLDER"
}

check_initialised "$CONFIG_PATH"

# temp folder
TMP_FOLDER="$(mktemp -d)"
function cleanup { rm -r "$TMP_FOLDER"; }
trap cleanup EXIT

. $CONFIG_PATH/secrets.config # load secrets file

# AWS CREDENTIALS
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION

BUCKET_FILE_LIST=$(getBucketFileList)

displayBucketInfo

INDEX_SNAR="$TMP_FOLDER/$SNAR_FILENAME"
downloadIndexSnar "$INDEX_SNAR"

SNAPSHOT_NAME="$(getSnapshotName)"
SNAPSHOT_OUTPUT="$TMP_FOLDER/$SNAPSHOT_NAME"

createSnapshot "$CONFIG_PATH" "$INDEX_SNAR" "$SNAPSHOT_OUTPUT"

reviewSnapshot "$SNAPSHOT_OUTPUT"

ENCRYPTED_INDEX_SNAR="$TMP_FOLDER/$SNAR_FILENAME.gpg"
encryptFile "$INDEX_SNAR" "$ENCRYPTED_INDEX_SNAR"
uploadFile "$ENCRYPTED_INDEX_SNAR" "STANDARD"

ENCRYPTED_SNAPSHOT="$SNAPSHOT_OUTPUT.gpg"
encryptFile "$SNAPSHOT_OUTPUT" "$ENCRYPTED_SNAPSHOT"
uploadFile "$ENCRYPTED_SNAPSHOT" "DEEP_ARCHIVE"
