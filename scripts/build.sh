#!/usr/bin/env bash
set -e

CNAME="$1"
USERNAME="$2"
WORKDIR="$3"
IMAGE="$4"
DOCKERFILE="$5"
DOCKERFILE_DIR="$6"
BUILD_USER="$7"
STAMP_FILE="$8"
DOTFILES_REPO="$9"
shift 9

echo ""
echo ">>> [capsule] Stopping old container/image..."
(docker stop "$CNAME"; docker rm "$CNAME"; docker rmi "$IMAGE") 2>/dev/null || true

echo ">>> [capsule] Building Docker image..."
if ! docker build -f "$DOCKERFILE" --build-arg USERNAME="$BUILD_USER" -t "$IMAGE" "$DOCKERFILE_DIR"; then
  echo ""
  echo ">>> [capsule] BUILD FAILED. Fix the Dockerfile and press Ctrl+Shift+D to retry."
  exit 1
fi

# Write build stamp
if [ -n "$STAMP_FILE" ]; then
  MTIME=$(stat -c "%Y" "$DOCKERFILE" 2>/dev/null || true)
  [ -n "$MTIME" ] && printf '%s' "$MTIME" > "$STAMP_FILE"
fi

echo ">>> [capsule] Starting container..."
docker run -d --name "$CNAME" "$@" --restart unless-stopped "$IMAGE" sleep infinity || {
  echo ">>> [capsule] Failed to start container."
  exit 1
}

echo ">>> [capsule] Setting up user '$USERNAME'..."
docker exec "$CNAME" /usr/local/bin/setup-user.sh "$USERNAME" "$DOTFILES_REPO"

echo ">>> [capsule] Connecting..."
exec docker exec -it -u "$USERNAME" -w "$WORKDIR" "$CNAME" zsh
