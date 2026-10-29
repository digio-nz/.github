# digio-nz/.github

This public repository holds the org issue forms, PR template, and shared workflows.
GitHub uses `.github/ISSUE_TEMPLATE/` and `pull_request_template.md` when a repo has no local templates.

The org Discipline ruleset runs `.github/workflows/discipline.yml` on product repositories.
Its gates run on the Mac mini; its labeller runs on GitHub's hosted runners.
This repository runs the gate self-tests on a hosted runner through `check-discipline.yml`.

Michelin calls `digio-nz/.github/.github/workflows/label-pr.yml@main` to label its PRs without adding Discipline gates.
Digio-skills runs its trusted main-branch labeller directly through its local `label-pr.yml`.
Labelling includes draft PRs and has no path filter.
Bare Bug, Task, Plan and Phase label events rerun the labeller to remove legacy type duplication.

The shared packages call `digio-nz/.github/.github/workflows/package-release.yml@main`.
The workflow calls the package release action from this repository.
Michelin's design-map release checks out this repository to use the same release script.
The workflows pin the labeller action to a commit; that revision's `skills.ref` pins its skills checkout.

`DIGIO_SKILLS_READ_TOKEN` supplies Contents read access to `digio-skills` for checkout only.
It does not authorize PR writes or cross-repository issue reads.
Existing reader App credentials remain an alternative for checkout and allow cross-repository issue reads where configured.

Run the offline checks:

```sh
bash .github/actions/discipline/gates-selftest.sh
bash .github/actions/discipline/no-secret/secret-guard-selftest.sh
bash .github/actions/discipline/selftest-workflow.sh .github/workflows/discipline.yml
python3 .github/actions/discipline/label-coverage-selftest.py
bash .github/actions/package-release/release-selftest.sh
```

The gate tests use Bash, Git, Node, npm, Python with PyYAML, and Actionlint.
The release tests use local repositories and registry stubs.
The check workflows run the tests on pull requests that change these actions or workflows.
