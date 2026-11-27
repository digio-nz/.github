# digio-nz/.github

This public repository holds the org issue forms, PR template, and shared workflows.
GitHub uses `.github/ISSUE_TEMPLATE/` and `pull_request_template.md` when a repo has no local templates.

The org Discipline ruleset runs `.github/workflows/discipline.yml` on product repositories.
Its gates run on GitHub's hosted runners, and it pins every action to a commit.
Discipline is advisory: every gate continues on error, so a failed gate does not block the merge.
The exception is no-secret: a commit that adds a credential-shaped value still fails Discipline and blocks the merge.
The setup steps (read the PR, checkout, install Node, fetch the range) also block, so a broken setup shows red rather than a false pass.
Failed gates show as warnings, in the job summary and in a sticky PR comment that each run updates.
This repository runs the gate self-tests on a hosted runner through `check-discipline.yml`.

`image/` holds the workbench image: every dev container and worker sandbox runs it, and `build-image.yml` builds it.
Its tools are in `image/references/tools.tsv`, and `image/skills.ref` pins the skills it checks against.
`hooks/` and `lib/` are what the image bakes in or sources. `check-workspace.yml` tests all three.

`bench/` holds the test bench: the container `test-browser`, with one browser that a person watches, and the container `test-agent`, which drives that browser. Its [README](bench/README.md) states its parts and limits, and `check-bench.yml` builds and tests it.

The shared packages call `digio-nz/.github/.github/workflows/package-release.yml@main`.
The workflow calls the package release action from this repository.
Michelin's design-map release checks out this repository to use the same release script.

`DIGIO_SKILLS_READ_TOKEN` supplies Contents read access to `digio-skills` for checkout only.

Gated products pin `.github/actions/preview-provision`, which owns Preview provisioning. Its [README](.github/actions/preview-provision/README.md) states the contract. Product identifiers stay in the products.

Gated products also pin `.github/actions/production-build`, which builds the proven commit as a staged Production deployment during a manual release. Its [README](.github/actions/production-build/README.md) states the contract.

Run the offline checks:

```sh
node --test .github/actions/preview-provision/provision.test.mjs
node --test .github/actions/production-build/production-build.test.mjs
bash .github/actions/discipline/gates-selftest.sh
bash .github/actions/discipline/no-secret/secret-guard-selftest.sh
bash .github/actions/discipline/selftest-workflow.sh .github/workflows/discipline.yml
bash .github/actions/package-release/release-selftest.sh
```

The gate tests use Bash, Git, Node, npm, Python with PyYAML, and Actionlint.
The release tests use local repositories and registry stubs.
The check workflows run the tests on pull requests that change these actions or workflows.
