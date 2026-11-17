// Build or reuse a STAGED Production deployment of one proven commit, for a Gated release.
// It never promotes, aliases, migrates or cancels. README.md owns the contract.
// Run with Node 24 and no installed dependencies.
import { realpathSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const BUILDER = "v1";
const BUILD_STATES = ["QUEUED", "INITIALIZING", "BUILDING"];
const BUILD_DEADLINE_MS = 30 * 60 * 1000;
const POLL_MS = 10000;
const DEPLOYMENT_ID = /^dpl_[A-Za-z0-9]+$/;
const USAGE = "Usage: production-build.mjs <apply|check> <40-char sha>, or test";

export class BuildError extends Error {
  constructor(message, exitCode = 1) {
    super(message);
    this.exitCode = exitCode;
  }
}

function requireThat(condition, message, exitCode = 1) {
  if (!condition) throw new BuildError(message, exitCode);
}

export function parseArgs(argv) {
  const [mode, sha, ...rest] = argv;
  requireThat(
    (mode === "test" && sha === undefined) ||
      (["apply", "check"].includes(mode) && /^[0-9a-f]{40}$/.test(sha ?? "") && !rest.length),
    USAGE,
    2,
  );
  return { mode, sha };
}

export function parseEnv(env) {
  const config = {
    team: env.VERCEL_ORG_ID ?? "",
    project: env.VERCEL_PROJECT_ID ?? "",
    repo: env.GITHUB_REPOSITORY ?? "",
    domain: env.PRODUCTION_DOMAIN ?? "",
  };
  requireThat(/^team_[A-Za-z0-9]+$/.test(config.team), "VERCEL_ORG_ID must name a team", 2);
  requireThat(
    /^prj_[A-Za-z0-9]+$/.test(config.project),
    "VERCEL_PROJECT_ID must name a project",
    2,
  );
  requireThat(/^[\w.-]+\/[\w.-]+$/.test(config.repo), "GITHUB_REPOSITORY must be owner/name", 2);
  requireThat(/^[a-z0-9.-]+\.[a-z]+$/.test(config.domain), "PRODUCTION_DOMAIN must be a host", 2);
  return config;
}

async function production(api, config) {
  const { team, project, repo, domain } = config;
  const live = await api(`/v9/projects/${project}?teamId=${team}`);
  requireThat(
    live?.id === project && live.accountId === team,
    "The Vercel project or team differs from VERCEL_PROJECT_ID and VERCEL_ORG_ID",
  );
  requireThat(
    live.link?.type === "github" &&
      `${live.link.org}/${live.link.repo}` === repo &&
      live.link.productionBranch === "main" &&
      live.link.repoId !== undefined,
    "The Vercel project is not linked to this repository with main as its Production branch",
  );
  requireThat(
    live.autoAssignCustomDomains === false,
    `autoAssignCustomDomains reads '${live.autoAssignCustomDomains}', so a Production build would take ${domain}; no deployment was requested`,
  );
  const alias = await api(`/v4/aliases/${domain}?teamId=${team}`, { allowMissing: true });
  return {
    name: live.name,
    repoId: live.link.repoId,
    target: live.targets?.production?.id ?? "<absent>",
    alias: alias?.deploymentId ?? "<absent>",
  };
}

function reportedShas(built) {
  return [built.gitSource?.sha, built.meta?.githubCommitSha].filter((sha) => sha !== undefined);
}

export function isCommitBuild(built, config, live, sha) {
  const shas = reportedShas(built);
  return (
    DEPLOYMENT_ID.test(built?.id ?? "") &&
    built.projectId === config.project &&
    built.target === "production" &&
    /^[a-z0-9-]+\.vercel\.app$/.test(built.url ?? "") &&
    built.gitSource?.type === "github" &&
    String(built.gitSource.repoId) === String(live.repoId) &&
    shas.length > 0 &&
    shas.every((reported) => reported === sha)
  );
}

const read = (api, config, id) =>
  api(`/v13/deployments/${id}?teamId=${config.team}&withGitRepoInfo=true`);

// The list response carries no gitSource, so each candidate is read back in full.
async function findReusable(api, config, live, sha) {
  const query = new URLSearchParams({
    projectId: config.project,
    teamId: config.team,
    target: "production",
    sha,
    limit: "20",
  });
  const { deployments } = await api(`/v7/deployments?${query}`);
  requireThat(Array.isArray(deployments), "The Vercel deployment inventory is missing");
  const newestFirst = [...deployments].sort((a, b) => (b.created ?? 0) - (a.created ?? 0));
  const matches = [];
  for (const listed of newestFirst) {
    if (![...BUILD_STATES, "READY"].includes(listed.readyState)) continue;
    const built = await read(api, config, listed.uid);
    if (built?.id !== listed.uid || !isCommitBuild(built, config, live, sha)) continue;
    if (built.readyState === "READY") {
      requireThat(
        built.readySubstate !== "ROLLING",
        `Deployment ${built.id} of ${sha} is in a rolling release; stop and inspect`,
      );
      return { built, waited: false };
    }
    if (BUILD_STATES.includes(built.readyState)) matches.push(built);
  }
  return matches.length ? { built: matches[0], waited: true } : undefined;
}

async function waitForReady(api, config, live, sha, id, wait) {
  const deadline = Date.now() + BUILD_DEADLINE_MS;
  for (;;) {
    const built = await read(api, config, id);
    requireThat(
      built?.id === id && isCommitBuild(built, config, live, sha),
      `Deployment ${id} does not read back as a Production build of ${sha} from this repository; reported ${JSON.stringify(reportedShas(built ?? {}))}`,
    );
    if (built.readyState === "READY") {
      requireThat(
        built.readySubstate === "STAGED",
        `Deployment ${id} is READY with readySubstate '${built.readySubstate}', not STAGED, so it took production traffic`,
      );
      return built;
    }
    requireThat(
      BUILD_STATES.includes(built.readyState),
      `Deployment ${id} of ${sha} ended ${built.readyState}; a rerun requests a new build`,
    );
    requireThat(
      Date.now() < deadline,
      `Deployment ${id} of ${sha} was not READY within 30 minutes`,
    );
    await wait(POLL_MS);
  }
}

export async function productionBuild({ api, env, mode, sha, wait = delay }) {
  const config = parseEnv(env);
  const before = await production(api, config);
  const found = await findReusable(api, config, before, sha);
  if (mode === "check")
    return {
      mode,
      sha,
      reusable: found ? { id: found.built.id, state: found.built.readyState } : null,
      productionTarget: before.target,
    };
  let built = found?.built;
  if (!built) {
    built = await api(`/v13/deployments?teamId=${config.team}&forceNew=1`, {
      body: {
        name: before.name,
        project: config.project,
        target: "production",
        gitSource: { type: "github", repoId: before.repoId, ref: "main", sha },
        meta: { productionBuild: BUILDER },
      },
    });
    requireThat(
      DEPLOYMENT_ID.test(built?.id ?? "") && built.target === "production",
      "Vercel returned an unexpected deployment for the Production build request",
    );
  }
  if (!found || found.waited) built = await waitForReady(api, config, before, sha, built.id, wait);
  const after = await production(api, config);
  requireThat(
    after.target === before.target && after.alias === before.alias,
    `Production moved during the build: target ${before.target} -> ${after.target}, ${config.domain} ${before.alias} -> ${after.alias}; stop and inspect before any migration`,
  );
  return {
    deploymentId: built.id,
    deploymentUrl: `https://${built.url}`,
    reused: Boolean(found),
  };
}

export function apiClient(token, fetchImpl = fetch) {
  requireThat(Boolean(token), "VERCEL_TOKEN must hold the product's Vercel token", 2);
  return async (path, { body, allowMissing = false } = {}) => {
    const method = body === undefined ? "GET" : "POST";
    let response;
    try {
      response = await fetchImpl(`https://api.vercel.com${path}`, {
        method,
        redirect: "error",
        signal: AbortSignal.timeout(60000),
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
          Accept: "application/json",
        },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
    } catch {
      throw new BuildError(`Vercel ${method} request failed; transport details withheld`, 3);
    }
    if (allowMissing && response.status === 404) return null;
    requireThat(
      response.ok,
      `Vercel ${method} ${path.split("?")[0]} failed with HTTP ${response.status}; response withheld`,
      3,
    );
    try {
      return await response.json();
    } catch {
      throw new BuildError("Vercel returned invalid JSON", 3);
    }
  };
}

async function main(argv) {
  const { mode, sha } = parseArgs(argv);
  if (mode === "test") {
    const result = spawnSync(
      process.execPath,
      ["--test", join(HERE, "production-build.test.mjs")],
      {
        stdio: "inherit",
        timeout: 120000,
        env: { PATH: process.env.PATH, HOME: process.env.HOME },
      },
    );
    requireThat(result.status === 0, "Production build self-test failed");
    return;
  }
  const result = await productionBuild({
    api: apiClient(process.env.VERCEL_TOKEN),
    env: process.env,
    mode,
    sha,
  });
  if (mode === "check") {
    console.log(JSON.stringify(result));
    return;
  }
  console.error(
    `[production-build] ${result.reused ? "reused" : "built"} ${result.deploymentId} (${result.deploymentUrl}) for ${sha}; Production target and domain unchanged`,
  );
  console.log(`deployment_id=${result.deploymentId}\ndeployment_url=${result.deploymentUrl}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(
      `[production-build] REFUSED ${error instanceof Error ? error.message : "Production build failed"}`,
    );
    process.exitCode = error instanceof BuildError ? error.exitCode : 1;
  });
}
