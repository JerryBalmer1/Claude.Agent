# Claude.Agent image: Claude Code + PowerShell + the sibling modules (copied into build/modules by `Invoke-Build Modules`).
# No secrets are built in: the API key arrives via env at run time, the mitmproxy CA on a volume. The ledger key is
# never here at all: the agent writes unsigned entries to /spool and the `ledger` sidecar (ledger.Dockerfile) chains them.
FROM node:22-bookworm-slim

ARG CLAUDE_CODE_VERSION=2.1.295
ARG PWSH_VERSION=7.4.*

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && curl -fsSL https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb -o /tmp/packages-microsoft-prod.deb \
 && dpkg -i /tmp/packages-microsoft-prod.deb \
 && rm /tmp/packages-microsoft-prod.deb \
 && apt-get update \
 && apt-get install -y --no-install-recommends "powershell=${PWSH_VERSION}" \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm cache clean --force

# uid 10001, not 1000: the mitmproxy sidecar runs as 1000 and owns the CA private key on the shared volume.
# Group `spool` (gid 10100) is shared with the ledger keeper (uid 10002), which truncates what it has consumed.
RUN groupadd --gid 10100 spool \
 && useradd --uid 10001 --user-group --groups spool --create-home --shell /bin/bash agent \
 && mkdir -p /work /spool \
 && chown agent:agent /work \
 && chown agent:spool /spool && chmod 2770 /spool

COPY build/modules/ /usr/local/share/powershell/Modules/
COPY entrypoint.ps1 /opt/agent/entrypoint.ps1

ENV DISABLE_AUTOUPDATER=1 \
    POWERSHELL_TELEMETRY_OPTOUT=1

WORKDIR /work
# Starts as root only to add the mitmproxy CA to the system store, then re-executes itself as `agent`.
ENTRYPOINT ["pwsh", "-NoProfile", "-File", "/opt/agent/entrypoint.ps1"]
