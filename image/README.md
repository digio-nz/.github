# Workbench image

Run `bash image/scripts/workbench-image.sh build` to build the image.
Run `bash image/scripts/workbench-image.sh test` to test the image scripts.

`image/references/tools.tsv` lists the tools of the image, and `image/scripts/tools.sh` reads it.
The build's sandbox check runs `tools.sh check --latest`.
It compares each tool with the newest version of the channel that installs it.
That channel is the APT candidate of a Debian package, the npm registry, or the release that an installer or a feature reads.
A tool that is older than its channel fails the check, because a new build fixes it.
An upstream release that the channel does not have yet does not fail the check.

PyYAML (`python3-yaml`) is a base package of the Dockerfile, not a row, because it is a library with no command to probe.

The `postgresql` row installs the Postgres server and client from the PGDG apt repository, because Ubuntu 24.04 ships an older major than Neon runs.
`tools.sh` compares the fingerprint of the signing key with its pinned fingerprint before it adds the repository.
The image holds no cluster. A product makes its own cluster with `initdb`, in a folder that the user owns.

`image/references/node-major` is the Node major that the products declare in `.nvmrc`.
The image self-test fails when `node --version` shows a different major.
When the products move to a new major, change the file.

`PLAYWRIGHT_BROWSERS_PATH` is `/opt/playwright`, which holds the Chromium build of the image's `playwright`.
Each user can write the folder, because a dev container tool can change the uid of the user.
A product that pins a different Playwright version needs a different build.
To add that build, run `npx playwright install chromium` in the product.

The devcontainer commands run `image/scripts/post-create.sh` and `image/scripts/post-start.sh`.
Outside a Codespace on this repository, they run from a checkout of it at `~/.digio/github`, which each start pulls.
They use Michelin at `~/.digio/michelin` (`DIGIO_MICHELIN_ROOT`) and the installed digio-skills clone at `~/.digio/skills`.
The git hooks are the image's own copy of `hooks/`; `image/scripts/git-hooks.sh` fails a start when no pre-push hook is in effect.
`DIGIO_SKILLS_ROOT` selects a different skills checkout.

The image holds [skills-manager-cli](https://github.com/xingkongliang/skills-manager) in `/usr/local/bin`.
The Dockerfile pins its version and the checksum of the release asset for each architecture.
`post-start.sh` uses it to link the skills of the `factory` preset into `~/.claude/skills` and `~/.codex/skills`.

The image holds a single-user [nix](https://nix.dev/manual/nix/latest/), so an agent can check a flake before a commit.
The Dockerfile pins its release and the checksum of the tarball for each architecture, and the tarball stays in the image.
`nix-setup.sh` installs it into `/nix` for the user at the build.
`post-start.sh` runs the script again at each start, because a volume at `/nix` can be empty or can hold the nix of an older image.
The script also gives `/nix` to the user when a dev container tool has changed the uid of the user.
A host that mounts a volume at `/nix` keeps the store across a restart. With no volume, a restart empties the store.
`node-auth-token.sh` gives nix the `GH_TOKEN`, which a private input of a flake needs.
