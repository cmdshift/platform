#!/bin/sh -eu

rustfs "/data" &
SERVER_PID=$!

rc alias set main "http://localhost:9000" "rustfsadmin" "rustfsadmin"

echo "Waiting for RustFS to be ready..."
for i in $(seq 1 30); do
  sleep 1
  if rc ready main --timeout 1; then
    break
  fi
done

for BUCKET in $RUSTFS_BUCKETS; do
  echo "Provisioning: $BUCKET"

  rc mb "main/$BUCKET"
  rc admin user add main/ "$BUCKET" "password"

  # Write policy to temp file
  POLICY_FILE=$(mktemp)
  cat > "$POLICY_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${BUCKET}",
        "arn:aws:s3:::${BUCKET}/*"
      ]
    }
  ]
}
EOF

  rc admin policy create main/ "${BUCKET}-policy" "$POLICY_FILE"
  rc admin policy attach main/ "${BUCKET}-policy" --user "$BUCKET"

  rm -f "$POLICY_FILE"
done

echo "Provisioning complete. Server running (PID $SERVER_PID)."

wait $SERVER_PID
