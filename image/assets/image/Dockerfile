# The workbench image: the environment of each worker sandbox, each Codespace, each dev container at a desk and each
# local run. The tools come from references/tools.tsv through scripts/tools.sh, and this file names none of them.
# The build context is image/ (devcontainer.json beside this file).
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG USERNAME=vscode
ENV DEBIAN_FRONTEND=noninteractive

# The base packages that no person runs; tools.sh holds this list as BASE_PACKAGES, and tools.sh lint holds this line to it.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates build-essential gnupg python3-pip python3-venv \
 && rm -rf /var/lib/apt/lists/*

# skills-manager-cli links the skills of a preset into each agent's skills folder. tools.tsv takes only latest, and this
# version is pinned with the checksum of each architecture's release asset, so the install is here.
RUN case "$(dpkg --print-architecture)" in \
      amd64) asset=skills-manager-cli-Linux-x64 sum=3be08b67e1ca1b035e948848242412ed7ff5b592a3c82cfb9e3728eede8b2a6a ;; \
      arm64) asset=skills-manager-cli-Linux-arm64 sum=02d89fffb94a0b5b9b55bfb7165d7c58bd45ae284e7ea579be01b144eca91c66 ;; \
      *) echo "skills-manager-cli: no pinned release for $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac \
 && curl -fsSL -o /usr/local/bin/skills-manager-cli "https://github.com/xingkongliang/skills-manager/releases/download/v1.44.0/$asset" \
 && echo "$sum  /usr/local/bin/skills-manager-cli" | sha256sum -c - \
 && chmod 0755 /usr/local/bin/skills-manager-cli

COPY references/tools.tsv scripts/tools.sh /opt/digio/tools/
RUN chmod 0755 /opt/digio/tools/tools.sh

# One layer for each source group keeps each layer under VCR's limit of 2 GB. /usr/local is on the PATH of each user, so
# a sandbox whose user is not vscode finds each tool. Each build supplies a new value to prevent cached tools and indexes.
ARG TOOLS_REFRESH
RUN test -n "$TOOLS_REFRESH"
RUN /opt/digio/tools/tools.sh apply --prefix /usr/local --sources apt
RUN /opt/digio/tools/tools.sh apply --prefix /usr/local --sources nodesource
RUN /opt/digio/tools/tools.sh apply --prefix /usr/local --sources npm \
 && npm cache clean --force
RUN /opt/digio/tools/tools.sh apply --prefix /usr/local --sources installer,gh-release

# The browser lives in the image so container create does no download. Shared path, readable by the user.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright
RUN playwright install --with-deps chromium \
 && chmod -R a+rX /opt/playwright \
 && rm -rf /var/lib/apt/lists/*

# A person starts the HumanLayer daemon with this; no start-up script runs it.
COPY scripts/humanlayer-daemon.sh /usr/local/bin/humanlayer-daemon.sh
RUN chmod 0755 /usr/local/bin/humanlayer-daemon.sh

# The base image's shim reports success without systemd, which prevents daemon fallbacks.
COPY assets/image/systemctl /usr/local/bin/systemctl
RUN chmod 0755 /usr/local/bin/systemctl

# Michelin git hooks: every push in the image runs secret-guard, then the repo's own hook.
# Staged by workbench-image.sh / the Build image workflow into image/.build/michelin-hooks.
# Worker sandboxes override core.hooksPath via GIT_CONFIG_* to digio-skills worker-hooks, which
# call secret-guard themselves, so the two paths never both run on one push.
COPY .build/michelin-hooks/ /opt/digio/michelin-hooks/
RUN test -r /opt/digio/michelin-hooks/pre-push/secret-guard.sh \
 && chmod -R a+rX /opt/digio/michelin-hooks \
 && find /opt/digio/michelin-hooks -type f \( -name '*.sh' -o -path '*/shims/*' \) -exec chmod a+x {} + \
 && git config --system core.hooksPath /opt/digio/michelin-hooks/shims

COPY scripts/workbench-start.sh /usr/local/bin/workbench-start.sh
RUN chmod 0755 /usr/local/bin/workbench-start.sh

USER ${USERNAME}
# The home does not depend on the runtime: a Vercel Sandbox runs no entrypoint and sets its own environment.
ENV HOME=/home/${USERNAME}
WORKDIR /workspaces
# A dev container tool replaces CMD and runs the start-up scripts from its own slots; a plain container run uses this.
CMD ["/usr/local/bin/workbench-start.sh"]
