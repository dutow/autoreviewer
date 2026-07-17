# Project-specific image for the review queue.
# The infra repo's 'task build' builds the base first, then this one
# (set QUEUE_DOCKERFILE=workspace/Dockerfile in .env to enable it).
FROM autoreviewer-base:local

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential meson ninja-build pkg-config \
    bison flex perl libipc-run-perl \
    libreadline-dev zlib1g-dev libicu-dev libssl-dev libcurl4-openssl-dev \
    libxml2-dev libxslt1-dev libkrb5-dev liblz4-dev libzstd-dev \
    gettext docbook-xml docbook-xsl xsltproc \
 && rm -rf /var/lib/apt/lists/*
USER reviewer
