# Ledger keeper sidecar: the only container that holds key.bin. It drains the shared spool into the chained
# ledger (Start-LedgerKeeper). The agent shares the spool volume with it and never mounts the ledger volume.
FROM mcr.microsoft.com/powershell:7.4-debian-12

# uid 10002 (agent is 10001, mitmproxy 1000). Group `spool` (gid 10100) is shared with the agent image so both
# can use /spool whichever container first populates the volume; /ledger is the keeper's alone.
RUN groupadd --gid 10100 spool \
 && useradd --uid 10002 --user-group --groups spool --no-create-home --shell /usr/sbin/nologin keeper \
 && mkdir -p /spool /ledger \
 && chown 10001:10100 /spool && chmod 2770 /spool \
 && chown keeper:keeper /ledger && chmod 0700 /ledger

COPY build/modules/Claude.Agent.Ledger/ /usr/local/share/powershell/Modules/Claude.Agent.Ledger/

ENV POWERSHELL_TELEMETRY_OPTOUT=1
USER keeper
ENTRYPOINT ["pwsh", "-NoProfile", "-Command", "Import-Module Claude.Agent.Ledger; Start-LedgerKeeper -Spool /spool -Ledger /ledger"]
