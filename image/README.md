# Workbench image

Run `bash image/scripts/workbench-image.sh build` to build the image.
Run `bash image/scripts/workbench-image.sh test` to test the image scripts.

`image/references/tools.tsv` lists the tools of the image, and `image/scripts/tools.sh` reads it.
The build's sandbox check runs `tools.sh check --latest`.
It compares each tool with the newest version of the channel that installs it.
That channel is the APT candidate of a Debian package, the npm registry, or the release that an installer or a feature reads.
A tool that is older than its channel fails the check, because a new build fixes it.
An upstream release that the channel does not have yet does not fail the check.

The devcontainer commands run `image/scripts/post-create.sh` and `image/scripts/post-start.sh`.
Outside a Codespace on this repository, they run from a checkout of it at `~/.digio/github`, which each start pulls.
They use Michelin at `~/.digio/michelin` (`DIGIO_MICHELIN_ROOT`) and the installed digio-skills clone at `~/.digio/skills`.
The git hooks are the image's own copy of `hooks/`; `image/scripts/git-hooks.sh` fails a start when no pre-push hook is in effect.
`DIGIO_SKILLS_ROOT` selects a different skills checkout.

The image holds [skills-manager-cli](https://github.com/xingkongliang/skills-manager) in `/usr/local/bin`.
The Dockerfile pins its version and the checksum of the release asset for each architecture.
`post-start.sh` uses it to link the skills of the `factory` preset into `~/.claude/skills` and `~/.codex/skills`.
