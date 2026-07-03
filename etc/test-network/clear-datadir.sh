#!/bin/bash

PARENT_DIR="local-validators"

if [ ! -d "$PARENT_DIR" ]; then
  echo "Error: Directory '$PARENT_DIR' not found."
  exit 1
fi

echo "Deleting 'blobstore', 'consensus-db', 'db', 'rocksdb', 'static_files' in '$PARENT_DIR' and its immediate children..."

find "$PARENT_DIR" -maxdepth 2 -type d \( -name "blobstore" -o -name "consensus-db" -o -name "db" -o -name "rocksdb" -o -name "static_files" \) -exec rm -rf {} +

echo "Done."
