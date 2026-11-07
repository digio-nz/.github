# Workbench image

Run `bash image/scripts/workbench-image.sh build` to build the image.
Run `bash image/scripts/workbench-image.sh test` to test the image scripts.

The devcontainer commands run `image/scripts/post-create.sh` and `image/scripts/post-start.sh`.
They use Michelin at `~/.digio/michelin` (`DIGIO_MICHELIN_ROOT`) and digio-skills at `~/devs/digio-skills`.
`DIGIO_SKILLS_ROOT` selects a different skills checkout.
The image installs the SkillPort virtual environment at `/opt/digio/skillport-venv` from the unpinned digio-skills requirements, using the latest stable public packages.
