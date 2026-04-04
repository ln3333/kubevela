FROM docker:27-cli

RUN apk add --no-cache \
    git \
    openssh-client \
    bash \
    sed \
    coreutils

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
