# The workbench

From the workbench image code: where the workbench runs, where a repo goes, and the facts of a Codespace.
digio-os `workbench.md` held these facts until Plan 73; it is now a pointer to this skill.

The workbench is the dev container that runs the workbench image, and it is the same machine wherever it runs.
The image is `ghcr.io/digio-nz/workbench`, published for amd64 and arm64.
GitHub Codespaces, VS Code, Cursor, T3 Code and the devcontainer CLI all read the same `.devcontainer/devcontainer.json` at the digio-michelin root.

## Where it runs

| Host | Engine | When |
| --- | --- | --- |
| Ubuntu (msi) | Docker Engine, from dotfiles `fleet/workbench` | always on: the T3 workbench |
| Mac | OrbStack or Docker Desktop | by hand only; the Macs are not agent environments |
| GitHub Codespaces | GitHub's VM | away from the desk, or for a clean instance |
| Vercel Sandbox | Vercel's microVM, from the `linux/amd64` copy in VCR | each worker job |

The config does not change between hosts. Inside, the container is Linux on each host.
The Mac never builds the image; it pulls the arm64 build.

From a terminal at a desk:

```sh
npm i -g @devcontainers/cli
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . zsh
```

## Released image selection

Each consumer selects one explicit `YYYY.MM.DD-N-release` image tag from a successful Build image release of `main`.
The same release tag exists in GitHub's registry and Vercel's registry.
A `trial` tests a build and is not a release selection.
`latest` moves after successful weekly and release builds; it is not a stable selection.

| Consumer | Selection |
| --- | --- |
| Codespace or desk container | The `image` field in its devcontainer config, such as `ghcr.io/digio-nz/workbench:YYYY.MM.DD-N-release`. |
| Worker sandbox | A dispatch's `--image`, such as `workbench:YYYY.MM.DD-N-release`. |
| Always-on container | Its container launcher selects `ghcr.io/digio-nz/workbench:YYYY.MM.DD-N-release`. |

Replace `YYYY.MM.DD-N-release` with an actual successful release tag.
The devcontainer config selects that release tag.
One image serves every agent.

To upgrade the image:

1. Publish a trial from the proposed image change and read its checks.
2. After the change merges, publish a release from `main` through `workbench-image.sh publish`.
3. Read the successful run's version and sandbox check.
4. Replace the selected tag with that released version.
5. Recreate or rebuild the container from the new selection.

A tools rebuild publishes another tag; it does not replace a running container or an explicit selection.
A stop and start uses the same container image.
To roll back, select the previous release tag and recreate the container.
The runtime starts HumanLayer with `HUMANLAYER_DISABLE_SELF_UPDATE=1` to keep its CLI at the image's built version.
That runtime setting is not an npm version pin.


## Start-up

The dev container standard runs two scripts, in its `postCreateCommand` and `postStartCommand` slots.
A Codespace on digio-nz/.github runs them from its own checkout.
digio-michelin's devcontainer config and the image's `CMD` run them from a digio-nz/.github checkout at `~/.digio/github`, which each start pulls.

- The dev container runs `scripts/post-create.sh` once after it creates the container.
  It clones digio-michelin to `~/.digio/michelin` and sets up the npm auth lines with `npm-auth.sh` and `node-auth-token.sh`, the same two scripts a physical machine runs.
  Where `DIGIO_HISTORY_DATABASE_URL` is unset, it writes `DATABASE_URL` to `~/devs/digio-history/.env.local` from `op://orchestrator/DIGIO_HISTORY_DATABASE_URL/credential`, once, if that file is missing. It prints a `WARN:` line when `op` cannot read the value.
- `scripts/post-start.sh` runs next, and at each start after that.
  It joins the tailnet, sets the global Git identity to `digbycampbell` with `96467498+digbycampbell@users.noreply.github.com` when none is set, pulls digio-michelin, clones or pulls `~/devs/digio-skills`, and configures public `skillport-mcp` with the workbench categories in digio-skills `consumers.tsv`.
  It prints a `WARN:` line when `~/.digio/michelin` is missing, has local changes or is behind `origin/main`, because the briefs then stay stale. A warning does not fail the start.
  It also writes the briefs, installs the skill dependencies, installs the session export hook, and starts the session export sweep.
  It does not start the HumanLayer daemon.
  To make the workbench an online HumanLayer host, run `humanlayer login`, then `humanlayer-daemon.sh start`.

The image's `CMD` is `workbench-start.sh`, beside `humanlayer-daemon.sh` in `/usr/local/bin`. A dev container tool replaces `CMD`, so only a plain container run, such as the always-on one on msi, uses it.
It sets the same `containerEnv`, clones or pulls `~/.digio/github`, and runs the same lifecycle from it in the background: `post-create.sh` until it succeeds once in the home, then `post-start.sh` at each start. Then it execs T3.
Its log, `~/.local/state/digio-workbench/start.log`, ends with `start: exit N`.
On msi, `/workspaces/devs` is the host's `/data/devs`, and the home is a named volume, so a recreate keeps the repos, the logins, `~/.digio/github` and `~/.digio/michelin`.
So a change to the start-up scripts, to the briefs in digio-michelin or to digio-skills reaches a workbench at its next start, with no rebuild.
At start, the digio-skills importer, `lib/skillport-sets.py`, imports the third-party sets into namespaces under the skills checkout.
SkillPort keeps only `skill-search` in each harness's native skills folder.
The session export needs the `DIGIO_HISTORY_DATABASE_URL` secret or `~/devs/digio-history/.env.local`; `post-start.sh` prints a `WARN:` line when it has neither.
The sweep loop runs `session-export-sweep.sh once` every 15 minutes, the entrypoint a physical machine's timer runs too.
It writes its log to `${XDG_STATE_HOME:-$HOME/.local/state}/digio-workbench/session-export-sweep.log`.

`DIGIO_SKILLS_ROOT` selects a skills checkout other than `~/devs/digio-skills`.

## Where a repo goes

| Kind | Path | Why |
| --- | --- | --- |
| A repo you edit | `~/devs/<repo>`, which is `/workspaces/devs/<repo>` | A rebuild keeps it, and the path matches the machines. |
| The Codespace's own repo, digio-michelin | `/workspaces/digio-michelin`, linked as `~/devs/digio-michelin` | Codespaces clones it there, and VS Code opens it. |
| The factory's runtime copy of digio-michelin | `~/.digio/michelin` | Create clones it again. Start pulls it with `--ff-only`, so an edit there stops the pull. |
| Skills | `~/devs/digio-skills`, on the workspace disk | Start clones or pulls it, then configures public `skillport-mcp` with the workbench categories in digio-skills `consumers.tsv`. |

Do not edit the runtime copy.
To change digio-michelin, work in `/workspaces/digio-michelin` on a branch, and open a PR.
A worker sandbox has no `/workspaces`, so it uses the same `$HOME/.digio/michelin`.
`DIGIO_MICHELIN_ROOT` names the runtime copy for every script: `~/.digio/michelin` in a workbench or a sandbox, and `~/devs/digio-michelin` on a physical machine, where dotfiles sets it.

## Codespaces facts

- Several can run at once; the limit is core-hours and storage, not a count.
  The digio-nz org is on the Enterprise plan, and the org billing page says who pays.
- A stopped Codespace costs only storage, which is cents.
  A running 4-core one costs about a dollar for a three-hour session.
  Work local at the desk and in a Codespace away from it.
- Stop and start keep the whole disk.
  A container rebuild keeps only `/workspaces` and clears the rest, `$HOME` too.
  Start links `~/devs` to `/workspaces/devs`, so the repos there survive a rebuild.
  A rebuild also clears `~/.ssh`, so start routes `git@github.com:` addresses over HTTPS with the Codespace's token.
  Deletion keeps nothing.
  Codespaces auto-delete after an idle period, 30 days by default.
- Start links `~/.humanlayer/riptide` and `~/.codex` to `/workspaces/.home`, so a rebuild keeps the HumanLayer and Codex logins.
  To cut access, sign out or revoke the login; a rebuild does not remove it.
  Leave `/workspaces/.home` out of any copy of `/workspaces`.
- Moving work to a machine is git: commit, push, pull.
- There is no GUI browser inside.
  Agents use headless Playwright; people use their local browser on a forwarded port.
- The image is prebuilt, so a Codespace runs only `post-create.sh`. There is no Codespaces prebuild.

## Local models and heavy work

Docker on macOS cannot pass the GPU into a container.
So a local model runs natively on the host, and the container reaches it over the host network.
In a Codespace the model is also an endpoint somewhere else.
The model endpoint is configuration, never baked into the image.
CPU-heavy work runs inside the container at near native speed.

## Product repos

No product repo gets a `.devcontainer/`. A person works on a product repo in a Codespace from digio-michelin.
An app that deploys as a container keeps its own runtime Dockerfile, which describes the deployable rather than the environment.
