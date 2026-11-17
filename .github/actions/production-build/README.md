# Production build

This script builds one proven commit as a Production deployment for a Full-tier product. The [release brief](https://github.com/digio-nz/digio-michelin/blob/main/briefs/release.md#deployment-tiers) assigns the tiers.

A Full product's `vercel.json` disables automatic Git deployments of `main`. The product's manual release proves the commit, then calls this script, then migrates and promotes. The script never promotes, migrates, assigns a domain or cancels a deployment. The Vercel build of a Production deployment never migrates.

## What a product holds

- In `.github/workflows/release-manual.yml`, a sparse `actions/checkout` of this repository at a pinned commit, without credentials.
- A step that runs `production-build.mjs apply <sha>` under the product's secret wrapper, with `VERCEL_TOKEN` set from the product's project-scoped release token.
- `VERCEL_ORG_ID`, `VERCEL_PROJECT_ID`, `GITHUB_REPOSITORY` and `PRODUCTION_DOMAIN` in the step's environment.

## What `apply` does

1. It reads the project. The project, team, linked GitHub repository and Production branch `main` must match. `autoAssignCustomDomains` must be `false`, or the script stops before any request that writes.
2. It records the Production target and the deployment that the domain alias names.
3. It lists the project's Production deployments of the SHA, and reads each one back with `withGitRepoInfo=true`. A deployment matches only if its target is `production`, its `gitSource` names the linked repository, and each SHA that it reports in `gitSource.sha` and `meta.githubCommitSha` equals the commit.
4. It reuses the newest matching `READY` deployment. This includes a `PROMOTED` one: the live deployment, or a rollback candidate. It stops on a `ROLLING` deployment. If no deployment is `READY`, it waits for the newest matching `QUEUED`, `INITIALIZING` or `BUILDING` deployment. It never reuses `ERROR` or `CANCELED`.
5. If nothing matches, it requests a Production deployment: `POST /v13/deployments?forceNew=1` with a GitHub `gitSource` of `ref: "main"` and the exact `sha`.
6. It polls for up to 30 minutes. Each read must still match the commit. A deployment that it requested or waited for must end `READY` with `readySubstate` `STAGED`. `ERROR` or `CANCELED` stops the run, and a rerun requests a new build.
7. It reads the project and alias again. `autoAssignCustomDomains` must still be `false`, and the Production target and the alias must be unchanged.

On success it prints `deployment_id=` and `deployment_url=` for `$GITHUB_OUTPUT`.

## Commands

```sh
node production-build.mjs apply <sha>
node production-build.mjs check <sha>
node production-build.mjs test
```

`check` makes the same reads and the same refusals as `apply`, then prints what `apply` would reuse. It makes no POST.

Exit codes: 0 success, 1 a finding, 2 invalid usage or configuration, 3 an external API failure. An API failure does not print the response.

## Vendor behaviour

- [Create a new deployment](https://vercel.com/docs/rest-api/reference/endpoints/deployments/create-a-new-deployment): the GitHub `gitSource` requires `ref` and `repoId`, and `sha` is optional. The reference does not say that `sha` takes precedence over `ref`. The read-back of the SHA is the check that a build of the `main` tip is refused.
- [Get a deployment](https://vercel.com/docs/rest-api/reference/endpoints/deployments/get-a-deployment-by-id-or-url): `gitSource` is in the response only with `withGitRepoInfo=true`. `readySubstate` `STAGED` means that the deployment has not had production traffic.

## Proof

`production-build.test.mjs` uses a fake Vercel API. It does not prove live Vercel behaviour. A live proof is a release of a proven commit that is older than the `main` tip, with a read-back of the deployment's `gitSource.sha`, `readySubstate` and the unchanged Production target before the migration.
