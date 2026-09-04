## Arma 3 Manager — server image
##
## A fork of the upstream Arma 3 yolk (pelican-eggs/yolks, games/arma3), carrying
## a modified entrypoint that reports mod download progress as JSON and can sync
## mods without starting the game. See NOTICE.md for the full list of changes.
##
## The base and every package below are upstream's. The only addition is `jq`,
## and it is not optional: the entrypoint writes status.json with it. Hand-rolled
## JSON in shell is one unescaped quote in a mod title away from producing a
## document the panel cannot parse — and the panel's failure mode for that is a
## blank progress table, with the download running fine underneath it.

FROM        --platform=$TARGETOS/$TARGETARCH debian:bookworm-slim

LABEL       org.opencontainers.image.source="https://github.com/FyWolf/arma3-manager-egg"
LABEL       org.opencontainers.image.description="Arma 3 dedicated server with machine-readable mod download progress"
LABEL       org.opencontainers.image.licenses=AGPL-3.0-or-later
LABEL       org.opencontainers.image.title="arma3-manager"

## Update base packages and install dependencies
ENV         DEBIAN_FRONTEND=noninteractive
RUN         dpkg --add-architecture i386 \
            && apt-get update \
            && apt-get upgrade -y \
            && apt-get install -y \
                curl \
                jq \
                tzdata \
                locales \
                iproute2 \
                gettext-base \
                ca-certificates \
                libavahi-client3 \
                libssl-dev \
                lib32gcc-s1 \
                libsdl2-2.0-0 \
                libsdl2-2.0-0:i386 \
                libstdc++6 \
                libstdc++6:i386 \
                lib32stdc++6 \
                libnss-wrapper \
                libnss-wrapper:i386 \
                libtbbmalloc2 \
                libtbbmalloc2:i386 \
                tini \
            && apt-get clean \
            && rm -rf /var/lib/apt/lists/*

## Configure locale
RUN         update-locale lang=en_US.UTF-8 \
            && dpkg-reconfigure --frontend noninteractive locales

## Prepare NSS Wrapper for the entrypoint as a workaround for Arma 3 requiring a valid UID
ENV         NSS_WRAPPER_PASSWD=/tmp/passwd NSS_WRAPPER_GROUP=/tmp/group
RUN         touch ${NSS_WRAPPER_PASSWD} ${NSS_WRAPPER_GROUP} \
            && chgrp 0 ${NSS_WRAPPER_PASSWD} ${NSS_WRAPPER_GROUP} \
            && chmod g+rw ${NSS_WRAPPER_PASSWD} ${NSS_WRAPPER_GROUP}
ADD         passwd.template /passwd.template

## Setup user and working directory
RUN         useradd -m -d /home/container -s /bin/bash container
USER        container
ENV         USER=container HOME=/home/container
WORKDIR     /home/container

## Copy over the entrypoint and the two A3M scripts it needs.
##
## a3m-common.sh is sourced by both the entrypoint and the sync daemon, so the
## boot-time download and a background one report through identical code — the
## panel cannot tell which fetched a mod, and there is no second copy to drift.
COPY        --chown=container:container ./entrypoint.sh /entrypoint.sh
COPY        --chown=container:container ./a3m-common.sh /a3m-common.sh
COPY        --chown=container:container ./a3m-sync.sh /a3m-sync.sh
RUN         chmod +x /entrypoint.sh /a3m-sync.sh

## Start with Tini to pass future stop signals correctly
STOPSIGNAL  SIGINT
ENTRYPOINT  ["/usr/bin/tini", "-g", "--"]
CMD         ["/entrypoint.sh"]
