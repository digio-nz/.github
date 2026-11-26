# The image of test-browser: one browser that an agent drives through Playwright MCP and that a person watches in a viewer.
# It holds no repo, no agent and no credential. The build context is bench/.
FROM node:26-bookworm-slim

ARG MCP_VERSION=0.0.86
ENV DEBIAN_FRONTEND=noninteractive \
    PLAYWRIGHT_BROWSERS_PATH=/opt/playwright \
    PATH=/opt/test-browser/node_modules/.bin:$PATH

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates tigervnc-standalone-server novnc websockify openbox \
 && rm -rf /var/lib/apt/lists/*

# The MCP package pins the Playwright version, and that version pins the Chromium build.
RUN mkdir -p /opt/test-browser && cd /opt/test-browser \
 && npm install --no-save "@playwright/mcp@$MCP_VERSION" \
 && playwright install --with-deps chromium \
 && npm cache clean --force \
 && rm -rf /var/lib/apt/lists/*

COPY scripts/test-browser-start.sh scripts/test-browser-bypass.ts /opt/test-browser/
# The base image's user has the ID 1000; this image renames it.
RUN usermod --login browser --home /home/browser --move-home node \
 && mkdir -p /home/browser/data /tmp/.X11-unix \
 && chmod 1777 /tmp/.X11-unix \
 && chown -R browser /home/browser

USER browser
WORKDIR /home/browser
# Chromium's own sandbox needs user namespaces, which Docker's default seccomp profile refuses. The container is the boundary.
ENV TEST_BROWSER_NO_SANDBOX=1 TEST_BROWSER_DATA=/home/browser/data
VOLUME /home/browser/data
EXPOSE 6080 8931
ENTRYPOINT ["bash", "/opt/test-browser/test-browser-start.sh"]
