#!/bin/bash
set -e
set -o pipefail

REPO_DIR=$(realpath $(dirname $(dirname "$0")))
FULL_IMAGE_NAME="${DOCKERHUB_USERNAME}/${IMAGE_NAME}:${TAG}"

echo "$DOCKERHUB_TOKEN" | docker login --username "$DOCKERHUB_USERNAME" --password-stdin

cd $REPO_DIR

docker build -t "$FULL_IMAGE_NAME" .
docker push "$FULL_IMAGE_NAME"
echo "FULL_IMAGE_NAME=$FULL_IMAGE_NAME" >>$GITHUB_ENV