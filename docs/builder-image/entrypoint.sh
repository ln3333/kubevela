#!/bin/bash
set -eo pipefail
set -x

# ── Required env vars ──
# GIT_URL        ssh:// GitLab URL
# CODE_TYPE      python3.12-pip | java21-maven | node-yarn | node-npm
# REPO           image repo path, e.g. "team"
# IMAGE_NAME     image name, e.g. "my-app"
#
# ── Optional env vars (with defaults) ──
# GIT_BRANCH     default: main
# DOCKER_HOST    default: tcp://192.168.1.1:2375
# REGISTRY       default: harbor.dev.example.com
# IMAGE_TAG      default: latest
# DOCKERFILE     custom Dockerfile path relative to repo root; empty = auto-generate
# BUILD_ARGS     comma-separated, e.g. KEY1=VAL1,KEY2=VAL2

log() { echo "[vela-builder] $(date '+%H:%M:%S') $*"; }

# ────────────────────────────────────────────────────
# 1. Validate required parameters
# ────────────────────────────────────────────────────
for var in GIT_URL CODE_TYPE REPO IMAGE_NAME; do
    if [ -z "${!var}" ]; then
        echo "ERROR: required env var ${var} is not set" >&2
        exit 1
    fi
done

GIT_BRANCH="${GIT_BRANCH:-main}"
REGISTRY="${REGISTRY:-harbor.dev.example.com}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
export DOCKER_HOST="${DOCKER_HOST:-tcp://192.168.1.1:2375}"

FULL_IMAGE="${REGISTRY}/${REPO}/${IMAGE_NAME}:${IMAGE_TAG}"

# ────────────────────────────────────────────────────
# 2. Configure SSH for GitLab access
# ────────────────────────────────────────────────────
# Secret subPath mounts are often read-only; chmod on the mount fails. The Pod sets
# defaultMode 0600 on the volume, but ssh still needs a writable key file with 0600.
# Copy to /tmp and point git at it via GIT_SSH_COMMAND.
log "Configuring SSH..."
mkdir -p /root/.ssh
SSH_KEY_SRC="/root/.ssh/id_rsa"
SSH_KEY_USE="/tmp/vela-git-ssh-key"
if [ ! -f "${SSH_KEY_SRC}" ]; then
    echo "ERROR: SSH private key not found at ${SSH_KEY_SRC}" >&2
    exit 1
fi
cp "${SSH_KEY_SRC}" "${SSH_KEY_USE}"
chmod 600 "${SSH_KEY_USE}"
export GIT_SSH_COMMAND="ssh -i ${SSH_KEY_USE} -o IdentitiesOnly=yes -o UserKnownHostsFile=/root/.ssh/known_hosts"

GIT_HOST=$(echo "${GIT_URL}" | sed -E 's|ssh://[^@]+@([^:/]+).*|\1|')
ssh-keyscan -H "${GIT_HOST}" >> /root/.ssh/known_hosts 2>/dev/null
log "SSH configured for host ${GIT_HOST}"

# ────────────────────────────────────────────────────
# 3. Clone repository
# ────────────────────────────────────────────────────
log "Cloning ${GIT_URL} branch=${GIT_BRANCH} ..."
git clone -b "${GIT_BRANCH}" --depth 1 "${GIT_URL}" /workspace
cd /workspace
log "Clone complete ($(du -sh . | awk '{print $1}'))"

# ────────────────────────────────────────────────────
# 4. Resolve Dockerfile
# ────────────────────────────────────────────────────
DOCKERFILE_PATH=""

if [ -n "${DOCKERFILE}" ] && [ -f "${DOCKERFILE}" ]; then
    DOCKERFILE_PATH="${DOCKERFILE}"
    log "Using user-specified Dockerfile: ${DOCKERFILE_PATH}"
else
    log "Auto-generating Dockerfile for code type: ${CODE_TYPE}"
    DOCKERFILE_PATH="/tmp/Dockerfile.generated"

    case "${CODE_TYPE}" in
        python3.12-pip)
            cat > "${DOCKERFILE_PATH}" <<'PYEOF'
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD ["python", "main.py"]
PYEOF
            ;;

        java21-maven)
            cat > "${DOCKERFILE_PATH}" <<'JAVAEOF'
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /build
COPY pom.xml ./
RUN mvn dependency:go-offline -B
COPY src ./src
RUN mvn package -B -DskipTests

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /build/target/*.jar app.jar
EXPOSE 8080
CMD ["java", "-jar", "app.jar"]
JAVAEOF
            ;;

        node-yarn)
            cat > "${DOCKERFILE_PATH}" <<'YARNEOF'
FROM node:20-slim
WORKDIR /app
COPY package.json yarn.lock ./
RUN yarn install --frozen-lockfile
COPY . .
RUN yarn build
CMD ["node", "dist/index.js"]
YARNEOF
            ;;

        node-npm)
            cat > "${DOCKERFILE_PATH}" <<'NPMEOF'
FROM node:20-slim
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build
CMD ["node", "dist/index.js"]
NPMEOF
            ;;

        *)
            echo "ERROR: unsupported CODE_TYPE '${CODE_TYPE}'" >&2
            echo "       supported: python3.12-pip, java21-maven, node-yarn, node-npm" >&2
            exit 1
            ;;
    esac
    log "Generated Dockerfile (${CODE_TYPE})"
fi

# ────────────────────────────────────────────────────
# 5. Parse build args
# ────────────────────────────────────────────────────
BUILD_ARG_FLAGS=""
if [ -n "${BUILD_ARGS}" ]; then
    IFS=',' read -ra ARGS <<< "${BUILD_ARGS}"
    for arg in "${ARGS[@]}"; do
        BUILD_ARG_FLAGS="${BUILD_ARG_FLAGS} --build-arg ${arg}"
    done
fi

# ────────────────────────────────────────────────────
# 6. Build image via remote Docker daemon
# ────────────────────────────────────────────────────
log "Building image ${FULL_IMAGE} (DOCKER_HOST=${DOCKER_HOST}) ..."
# shellcheck disable=SC2086
docker build -t "${FULL_IMAGE}" -f "${DOCKERFILE_PATH}" ${BUILD_ARG_FLAGS} .
log "Build succeeded"

# ────────────────────────────────────────────────────
# 7. Push image
# ────────────────────────────────────────────────────
log "Pushing ${FULL_IMAGE} ..."
docker push "${FULL_IMAGE}"
log "Push succeeded: ${FULL_IMAGE}"
