# Workbench image

Run `bash image/scripts/workbench-image.sh build` to build the image.
Run `bash image/scripts/workbench-image.sh test` to test the image scripts.

The devcontainer commands run `image/scripts/post-create.sh` and `image/scripts/post-start.sh`.
Outside a Codespace on this repository, they run from a checkout of it at `~/.digio/github`, which each start pulls.
They use Michelin at `~/.digio/michelin` (`DIGIO_MICHELIN_ROOT`) and digio-skills at `~/devs/digio-skills`.
`DIGIO_SKILLS_ROOT` selects a different skills checkout.

The image installs the [Skills Manager](https://github.com/xingkongliang/skills-manager) CLI at `/usr/local/bin/skills-manager-cli` with `image/scripts/skills-manager-cli.sh`.
That script pins one release and checks its SHA-256, because the CLI writes into each agent's skills folder.
It is the one tool outside `image/references/tools.tsv`, whose rows track the latest stable release.
