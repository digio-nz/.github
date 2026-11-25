# The test bench: one browser that an agent drives through Playwright MCP and that a person watches in a viewer.
# It holds no repo, no agent and no credential. The build context is bench/.
FROM node:26-bookworm-slim

ARG MCP_VERSION=0.0.86
ENV DEBIAN_FRONTEND=noninteractive \
    PLAYWRIGHT_BROWSERS_PATH=/opt/playwright \
    PATH=/opt/bench/node_modules/.bin:$PATH \
    BENCH_MCP_VERSION=$MCP_VERSION

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates tigervnc-standalone-server novnc websockify openbox \
 && rm -rf /var/lib/apt/lists/*

# The MCP package pins the Playwright version, and that version pins the Chromium build.
RUN mkdir -p /opt/bench && cd /opt/bench \
 && npm install --no-save "@playwright/mcp@$MCP_VERSION" \
 && playwright install --with-deps chromium \
 && npm cache clean --force \
 && rm -rf /var/lib/apt/lists/*

COPY scripts/bench-start.sh /opt/bench/bench-start.sh
# The base image's user has the ID 1000; the bench renames it.
RUN usermod --login bench --home /home/bench --move-home node \
 && mkdir -p /home/bench/bench /tmp/.X11-unix \
 && chmod 1777 /tmp/.X11-unix \
 && chown -R bench /home/bench

USER bench
WORKDIR /home/bench
# Chromium's own sandbox needs user namespaces, which Docker's default seccomp profile refuses. The container is the boundary.
ENV BENCH_NO_SANDBOX=1 BENCH_DATA=/home/bench/bench
VOLUME /home/bench/bench
EXPOSE 6080 8931
ENTRYPOINT ["bash", "/opt/bench/bench-start.sh"]
