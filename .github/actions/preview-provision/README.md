# Preview provision

This action provisions Previews for Full-tier products only. The [release brief](https://github.com/digio-nz/digio-michelin/blob/main/briefs/release.md#deployment-tiers) assigns the tiers. Mid and Minimal products do not use it.

The action creates or reuses `preview/<git branch>` under a product's synthetic root, writes branch-scoped Preview database variables and requests a Preview deployment of the exact SHA. It never writes a Production variable, resets or deletes a branch, or promotes a deployment.

## What a product holds

| File | Contents |
| --- | --- |
| `scripts/preview/provision.json` | Product identifiers: repository, Vercel project, Neon project, root branch and endpoint, host class, database, role and variable names. |
| `scripts/preview/database-guard.mjs` | A byte-identical copy of `guard.mjs`. The Vercel build runs it before migration. |
| `.github/workflows/preview-provision.yml` | A copy of `trusted-workflow.yml`. Only the action pin can differ. |
| `vercel.json` | `git.deploymentEnabled` enables `main` only, with `"**": false`. |

Keep product identifiers in the product. This repository is public.

The provisioner compares these files with its own commit before any API request, and fails on a difference. To change the guard or workflow, change them here, then change the product's copies and pin in one PR.

## Security boundaries

- The workflow runs reviewed `main` code on a GitHub-hosted runner. It checks out no PR code, installs no dependencies and exposes its credentials only to this action.
- The GitHub environment `preview-provision` allows only `main`. It holds `NEON_PREVIEW_API_KEY`, scoped to the product's Preview project, and `VERCEL_PREVIEW_TOKEN`, scoped to the product's Vercel project.
- A Vercel project token can affect Production. Trusted code and Preview-only requests enforce the boundary, not the token. Do not put either credential in application build variables.
- The guard is a safety check, not a security boundary. PR code can change its own copy. The boundary is that Preview credentials and data are synthetic.
- The provisioner refuses these sources: a fork, a Dependabot or merge-queue branch, a stale head and a standing branch that differs from `main`.
- The provisioner refuses these states: wrong ancestry, an integration-owned Preview variable, a database variable shared by Preview and Production, and an incomplete inventory.
- Any change to Production entries or the Production target stops the run. The provisioner never repairs state with a rollback.

## Commands

From a reviewed product checkout, with this repository beside it:

```sh
node ../.github/.github/actions/preview-provision/provision.mjs check pr:<number> --cli-auth
node ../.github/.github/actions/preview-provision/provision.mjs check standing-preview --cli-auth
node ../.github/.github/actions/preview-provision/provision.mjs list --cli-auth
node ../.github/.github/actions/preview-provision/provision.mjs test
```

`check` and `export` print the same metadata and make no writes. Their output says `metadata-only`: they check ancestry, variable scopes and the endpoint marker, not sensitive URL values, rows or deployed connections. `apply` creates missing Preview infrastructure and requests a deployment; use it only in the trusted workflow.

`test` compares the product's files with this commit, then runs the offline fixtures with the product's configuration.

Exit codes: 0 success, 1 a finding, 2 invalid usage or configuration, 3 an external API failure. `--cli-auth` uses the operator's `gh`, `neon` and `vercel` logins instead of named credentials.

## Prerequisites for a product

1. Prove the root's content without printing row values. An independent project and a branch name are not content proof. Record the comparison's coverage and negative control.
2. Review the product's change, and pin this action to a commit on this repository's `main`.
3. Create a Neon API key restricted to the Preview project and a Vercel token restricted to the product's project. Do not reuse a Production release token.
4. Store both in 1Password. Set them as environment secrets through memory or stdin, never through arguments, files or logs.
5. Keep `PREVIEW_LOGIN_ENABLED` absent until database, signing-key and integration-credential separation are proven.

## Cutover

WARNING: Do not run the replacement beside the coupled Neon integration. Either writer can replace branch credentials, and reconnecting the Preview project as a Production source points Production at fake data.

Do these steps for one product at a time. The product's runbook names its values.

1. Record Production environment entries and values in memory, the Production target and alias, existing Neon branches and the integration connection. Print only metadata and comparison results.
2. Run the product's tests and `check`. A `check` that names an integration-owned variable is expected before step 4.
3. Publish the reviewed workflow and guard. Then read back the environment policy and secret names, without values.
4. Disconnect only this product's coupled Neon connection, not the organisation integration or another product's connection. Read back the connection and compare Production.
5. Remove only old Preview-scoped database entries, including branch overrides and generic entries. The provisioner refuses an entry shared with Production until a reviewed operation splits its scopes without changing the Production value. Keep Production entries, other Preview settings, branches and deployments.
6. Run **Preview provision** for an open same-repository PR, then for `standing-preview`.
7. Read back Neon ancestry, Vercel branch scopes, Production values and routes, and both deployed commits. Check that the guard ran before migration.
8. Repeat after a second PR push and a mirror from `main`, to prove future provisioning.

An older branch without the new `vercel.json` keeps automatic deployment until it merges `main`. After step 5 it has no Preview database variables, so its migration fails loudly.

Existing deployments keep their captured environments. Preserving them does not make their old database targets safe. Keep them protected and login-disabled, and do not use them for acceptance.

## Acceptance and recovery

`READY` is build evidence only. Before enabling login, prove separate signing keys and integration credentials, fake-only data and Vercel Authentication. Also prove native-host cookie boundaries, login and logout, and Production rejection of Preview credentials. Check that Production stayed on its original deployment throughout.

If provisioning fails, keep Preview login disabled and repair the Preview-only configuration. Do not reset the root, delete branches, reconnect the coupled integration, restore old Preview credentials or dispatch a Production release.

A lost branch-create response triggers a fresh inventory read, not a reset. Retries reuse a valid database branch and request a new Preview deployment.

## Proof

`factory-sandbox` holds a synthetic product under `fixtures/preview-provision`, and its `Preview provision proof` workflow runs `test` from a pinned commit. That proof uses stub APIs. It does not prove live Vercel or Neon behaviour.
