#!/usr/bin/env bash
set -eo pipefail

CONFIG_DIR="../configs"
mkdir -p "$CONFIG_DIR"
cd "$CONFIG_DIR"

echo "Generating encryption key..."
ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)

cat > encryption-config.yaml <<EOF
kind: EncryptionConfig
apiVersion: v1
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
EOF

echo "Encryption config generated successfully in $(pwd)"
