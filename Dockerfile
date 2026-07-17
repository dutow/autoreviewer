# Base image for the autoreviewer queue container.
# Shared tooling only - project build deps go into workspace/Dockerfile
# (FROM autoreviewer-base:local). Built locally by 'task build', no registry.
FROM ubuntu:24.04

ARG UID=1000
ARG GID=1000
ARG DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git gnupg jq less \
    openssh-client rsync ruby-full tmux \
 && rm -rf /var/lib/apt/lists/*

# node 22 from nodesource - claude-code needs node >= 22, ubuntu 24.04 ships 18
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

# gh (GitHub CLI) from its apt repo
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# go-task
RUN sh -c "$(curl -fsSL https://taskfile.dev/install.sh)" -- -b /usr/local/bin

# claude CLI (global install so it survives the home volume mount)
RUN npm install -g --no-fund --no-audit @anthropic-ai/claude-code \
 && npm cache clean --force

# default git identity so 'git am' and findings commits never fail on a fresh
# home volume. --system writes /etc/gitconfig, outside the mounted home dir, so
# it survives. GIT_{AUTHOR,COMMITTER}_* env vars from .env override it.
RUN git config --system user.name "autoreviewer" \
 && git config --system user.email "autoreviewer@localhost"

# non-root user matching the host user, so bind-mounted files stay host-owned.
# ubuntu:24.04 ships an 'ubuntu' user at uid 1000 - remove it first.
RUN userdel -r ubuntu 2>/dev/null || true \
 && (getent group ${GID} > /dev/null || groupadd -g ${GID} reviewer) \
 && useradd -m -u ${UID} -g ${GID} -s /bin/bash reviewer \
 && mkdir -p /app && chown ${UID}:${GID} /app

USER reviewer
WORKDIR /app

# seed claude settings so a fresh home volume skips first-run interactive
# prompts: theme picker, and the dangerous-mode accept screen that would
# otherwise hang the first unattended review. named volumes copy image content
# on first creation, so this lands in the home volume; an existing home volume
# won't pick it up - see docs/setup.md.
RUN mkdir -p ~/.claude \
 && printf '%s\n' '{"theme":"dark","skipDangerousModePermissionPrompt":true}' > ~/.claude/settings.json
