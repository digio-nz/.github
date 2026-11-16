# .github: agent brief

This public repo holds the org issue forms, the PR template, the shared workflows and actions, the git hooks and the workbench image.

## Stack

- Bash, Node and Python scripts, GitHub Actions workflows and composite actions, and a Dockerfile. The workflows run on GitHub's hosted runners.
- Check a change with the self-test of the part that you change. The [README](README.md) lists them, and the `check-*.yml` workflows run them on a PR.

## Merge

- A change reaches `main` through a PR.
- Merge with a merge commit.
- No ruleset requires a check.

## Approval

- Digby's yes, for that step: a run of `build-image.yml`. A run of `main` moves the `latest` tag of the image that each workbench uses.
- No approval: a commit, a branch, a PR.

## Rules

- The repo is public. Put no secret, no private repo detail beyond a repo name, no machine detail and no private data in it.
- Other repos call `label-pr.yml` and `package-release.yml` at `@main`, so a merge changes them at once.
- `discipline.yml` stays advisory: each gate continues on error, except no-secret and the setup steps.
- Pin each action to a commit in `discipline.yml`. `selftest-workflow.sh` checks this.

## Read

| Read | When |
| --- | --- |
| digio-os [`repos/dot-github.md`](https://github.com/digio-nz/digio-os/blob/main/repos/dot-github.md) | Before you change a part that other repos use. |
| [`image/README.md`](image/README.md) | Before you change the workbench image, `hooks/` or `lib/`. |
| [`.github/actions/preview-provision/README.md`](.github/actions/preview-provision/README.md) | Before you change Preview provisioning. |
