# digio-nz/.github

This public repository holds the org issue forms, PR template, and shared workflows.
GitHub uses `.github/ISSUE_TEMPLATE/` and `pull_request_template.md` when a repo has no local templates.

The org Discipline ruleset runs `.github/workflows/discipline.yml` on product repositories.
Its gates run on the Mac mini; its labeller runs on GitHub's hosted runners.
This repository runs the gate self-tests on a hosted runner through `check-discipline.yml`.

The shared packages call `digio-nz/.github/.github/workflows/package-release.yml@main`.
The workflow calls the package release action from this repository.
Michelin's design-map release checks out this repository to use the same release script.
`skills.ref` pins the skills checkout that the PR labeller uses.

Run the offline checks:

```sh
bash .github/actions/discipline/gates-selftest.sh
bash .github/actions/discipline/no-secret/secret-guard-selftest.sh
bash .github/actions/discipline/selftest-workflow.sh .github/workflows/discipline.yml
bash .github/actions/package-release/release-selftest.sh
```

The gate tests use Bash, Git, Node, npm, Python with PyYAML, and Actionlint.
The release tests use local repositories and registry stubs.
The check workflows run the tests on pull requests that change these actions or workflows.
