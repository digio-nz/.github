// Provision only synthetic Preview branches for a Full-tier product, from trusted main code.
// No request writes a Production variable, deletes a branch or promotes a deployment.
// README.md owns the contract. Run with Node 24 and no installed dependencies.
import { spawnSync } from "node:child_process";
import { readFileSync, realpathSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath, pathToFileURL } from "node:url";

import { assertDatabaseUrl, MARKER } from "./guard.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const STANDING = "standing-preview";
const BUILD_DEADLINE_MS = 20 * 60 * 1000;

export const SOURCES = {
  config: "scripts/preview/provision.json",
  guard: "scripts/preview/database-guard.mjs",
  workflow: ".github/workflows/preview-provision.yml",
  vercel: "vercel.json",
};

class ProvisionError extends Error {
  constructor(message, exitCode = 1) {
    super(message);
    this.exitCode = exitCode;
  }
}

function requireThat(condition, message, exitCode = 1) {
  if (!condition) throw new ProvisionError(message, exitCode);
}

function exactKeys(value, keys, label) {
  requireThat(
    value &&
      typeof value === "object" &&
      !Array.isArray(value) &&
      JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...keys].sort()),
    `Invalid provisioning config: ${label} must have exactly ${keys.join(", ")}`,
    2,
  );
}

export function parseConfig(config) {
  const check = (condition, label) =>
    requireThat(condition, `Invalid provisioning config: ${label}`, 2);
  const text = (value, pattern) => typeof value === "string" && pattern.test(value);
  exactKeys(config, ["schema", "repo", "vercel", "neon", "variables"], "the root");
  exactKeys(config.vercel, ["project", "team", "name"], "vercel");
  exactKeys(config.neon, ["project", "root", "hostSuffix", "database", "role"], "neon");
  exactKeys(config.neon.root, ["branch", "endpoint"], "neon.root");
  exactKeys(config.variables, ["pooled", "direct"], "variables");
  check(config.schema === 1, "schema must be 1");
  check(text(config.repo, /^digio-nz\/[a-z0-9._-]+$/), "repo");
  check(text(config.vercel.project, /^prj_[A-Za-z0-9]+$/), "vercel.project");
  check(text(config.vercel.team, /^team_[A-Za-z0-9]+$/), "vercel.team");
  check(text(config.vercel.name, /^[a-z0-9-]+$/), "vercel.name");
  check(text(config.neon.project, /^[a-z0-9-]+$/), "neon.project");
  check(text(config.neon.root.branch, /^br-[a-z0-9-]+$/), "neon.root.branch");
  check(text(config.neon.root.endpoint, /^ep-[a-z0-9-]+$/), "neon.root.endpoint");
  check(text(config.neon.hostSuffix, /^(\.[a-z0-9-]+)+\.neon\.tech$/), "neon.hostSuffix");
  check(text(config.neon.database, /^[a-z_][a-z0-9_]*$/), "neon.database");
  check(text(config.neon.role, /^[a-z_][a-z0-9_]*$/), "neon.role");
  const { pooled, direct } = config.variables;
  check(Array.isArray(pooled) && pooled.includes("DATABASE_URL"), "variables.pooled");
  check(Array.isArray(direct) && direct.length > 0, "variables.direct");
  const keys = [...pooled, ...direct];
  check(new Set(keys).size === keys.length, "variables must not repeat");
  check(
    keys.every((key) => text(key, /^DATABASE_URL(_[A-Z]+)*$/)),
    "variables must be database URL names",
  );
  return config;
}

const managedKeys = (config) => [...config.variables.pooled, ...config.variables.direct, MARKER];
const targets = (env) => [env.target ?? []].flat();

export function assertTrustedSources(root) {
  const read = (path) => readFileSync(join(root, path), "utf8");
  const pinless = (text) => text.replace(/(preview-provision@)[0-9a-f]{40}\b/g, "$1PIN");
  requireThat(
    read(SOURCES.guard) === readFileSync(join(HERE, "guard.mjs"), "utf8"),
    `${SOURCES.guard} differs from the shared guard at this action's commit`,
  );
  requireThat(
    pinless(read(SOURCES.workflow)) ===
      pinless(readFileSync(join(HERE, "trusted-workflow.yml"), "utf8")),
    `${SOURCES.workflow} differs from the shared trusted workflow at this action's commit`,
  );
  const enabled = JSON.parse(read(SOURCES.vercel)).git?.deploymentEnabled ?? {};
  requireThat(
    enabled["**"] === false &&
      enabled.main === true &&
      Object.entries(enabled).every(([branch, on]) => branch === "main" || on === false),
    `${SOURCES.vercel} must enable automatic Git deployments for main only`,
  );
  return parseConfig(JSON.parse(read(SOURCES.config)));
}

export async function selectPreview(api, config, selector) {
  const { repo } = config;
  if (selector === STANDING) {
    const repository = await api("github", `/repos/${repo}`);
    const main = await api("github", `/repos/${repo}/git/ref/heads/main`);
    const standing = await api("github", `/repos/${repo}/git/ref/heads/${STANDING}`);
    requireThat(main.object.sha === standing.object.sha, `${STANDING} does not match current main`);
    requireThat(/^[a-f0-9]{40}$/.test(standing.object.sha), `Invalid ${STANDING} SHA`);
    return { branch: selector, sha: standing.object.sha, repoId: repository.id };
  }
  requireThat(/^pr:[1-9][0-9]*$/.test(selector), `Expected pr:<number> or ${STANDING}`);
  const pr = await api("github", `/repos/${repo}/pulls/${selector.slice(3)}`);
  requireThat(
    pr.state === "open" && pr.base.ref === "main" && pr.base.repo.full_name === repo,
    "Preview requires an open PR into this repository's main",
  );
  requireThat(
    pr.head.repo?.full_name === repo && pr.head.repo.id === pr.base.repo.id,
    "Fork previews are not provisioned",
  );
  const { ref, sha } = pr.head;
  requireThat(
    pr.user?.login !== "dependabot[bot]" &&
      ref !== "main" &&
      ref !== STANDING &&
      !/^(dependabot|gh-readonly-queue|refs|heads)\//i.test(ref),
    "Ref is not an eligible PR branch",
  );
  requireThat(
    ref.length > 0 &&
      ref.length <= 180 &&
      !/[\x00-\x20\x7f]/.test(ref) &&
      /^[a-f0-9]{40}$/.test(sha),
    "Invalid Preview ref or SHA",
  );
  return { branch: ref, sha, repoId: pr.head.repo.id };
}

async function snapshot(api, config) {
  const { project, team } = config.vercel;
  const live = await api("vercel", `/v9/projects/${project}?teamId=${team}`);
  requireThat(live.id === project && live.accountId === team, "Unexpected Vercel project or team");
  requireThat(
    `${live.link?.org}/${live.link?.repo}` === config.repo && live.link.productionBranch === "main",
    "Unexpected Vercel repository or Production branch",
  );
  requireThat(
    live.ssoProtection?.deploymentType === "all_except_custom_domains" &&
      live.autoAssignCustomDomains === false,
    "Vercel protection or manual-promotion setting differs",
  );
  requireThat(
    live.gitForkProtection === true && !live.customEnvironments?.length,
    "Vercel fork protection or custom environment setting differs",
  );
  requireThat(
    /^dpl_[a-zA-Z0-9]+$/.test(live.targets?.production?.id ?? ""),
    "Production target inventory is missing",
  );
  const { envs, pagination } = await api("vercel", `/v10/projects/${project}/env?teamId=${team}`);
  requireThat(
    Array.isArray(envs) && !pagination?.next,
    "Vercel environment inventory is incomplete",
  );
  const production = envs
    .filter((env) => targets(env).includes("production"))
    .sort((a, b) => a.id.localeCompare(b.id));
  requireThat(
    production.some((env) => env.key === "DATABASE_URL"),
    "Production database variable is missing",
  );
  return {
    project: live,
    envs,
    production: JSON.stringify(production),
    target: JSON.stringify(live.targets.production),
  };
}

function assertNoUnsafeEntries(envs, config) {
  const managed = managedKeys(config);
  const shared = envs.filter(
    (env) =>
      managed.includes(env.key) &&
      targets(env).includes("production") &&
      targets(env).includes("preview"),
  );
  requireThat(
    shared.length === 0,
    `Preview shares ${[...new Set(shared.map((env) => env.key))].join(", ")} with Production; split the scopes in a reviewed operation first`,
  );
  const coupled = envs.filter(
    (env) => targets(env).includes("preview") && managed.includes(env.key) && env.configurationId,
  );
  requireThat(
    coupled.length === 0,
    `An integration owns Preview variables ${[...new Set(coupled.map((env) => env.key))].join(", ")}; stop it and remove them first`,
  );
}

function assertProductionUnchanged(before, after, moment) {
  requireThat(
    after.production === before.production && after.target === before.target,
    `Production configuration changed ${moment}; stop and inspect`,
  );
}

export async function listBranches(api, config) {
  const result = [];
  const cursors = new Set();
  let cursor = "";
  do {
    const page = await api(
      "neon",
      `/projects/${config.neon.project}/branches?limit=100${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`,
    );
    requireThat(Array.isArray(page.branches), "Neon branch inventory is missing");
    result.push(...page.branches);
    cursor = page.pagination?.next ?? "";
    requireThat(!cursor || !cursors.has(cursor), "Neon branch pagination repeated a cursor");
    cursors.add(cursor);
  } while (cursor);
  return result;
}

async function assertRoot(api, config) {
  const { project, root } = config.neon;
  const { branch } = await api("neon", `/projects/${project}/branches/${root.branch}`);
  requireThat(
    branch.id === root.branch &&
      branch.project_id === project &&
      branch.name === "preview" &&
      !branch.parent_id &&
      !branch.expires_at &&
      !branch.archived,
    "Synthetic Preview root is not the configured independent root",
  );
  const { endpoints } = await api("neon", `/projects/${project}/branches/${root.branch}/endpoints`);
  requireThat(
    endpoints.some((endpoint) => endpoint.id === root.endpoint),
    "Synthetic Preview root does not use the configured endpoint",
  );
}

function assertChild(branch, name, config) {
  const { project, root } = config.neon;
  requireThat(
    branch.project_id === project &&
      branch.name === name &&
      branch.parent_id === root.branch &&
      branch.id !== root.branch &&
      !branch.expires_at &&
      !branch.archived,
    "Preview branch has unexpected project, ancestry or lifecycle",
  );
}

async function ensureChild(api, config, mode, name) {
  const find = (list) => {
    const matches = list.filter((branch) => branch.name === name);
    requireThat(matches.length <= 1, "Duplicate Preview branch names");
    return matches[0];
  };
  let branch = find(await listBranches(api, config));
  if (!branch && mode === "apply") {
    try {
      await api("neon", `/projects/${config.neon.project}/branches`, {
        branch: { name, parent_id: config.neon.root.branch },
        endpoints: [{ type: "read_write" }],
      });
    } catch (error) {
      // A concurrent creator or lost response can leave a valid branch; read it before retrying.
      branch = find(await listBranches(api, config));
      if (!branch) throw error;
    }
    branch = find(await listBranches(api, config));
  }
  requireThat(branch, "Preview database branch is missing");
  assertChild(branch, name, config);
  return branch;
}

async function childEndpoint(api, config, branch) {
  const { project, root, hostSuffix } = config.neon;
  const { endpoints } = await api("neon", `/projects/${project}/branches/${branch.id}/endpoints`);
  const writable = endpoints.filter(
    (endpoint) =>
      endpoint.type === "read_write" && endpoint.branch_id === branch.id && !endpoint.disabled,
  );
  requireThat(writable.length === 1, "Preview requires exactly one enabled read-write endpoint");
  const [endpoint] = writable;
  requireThat(
    /^ep-[a-z0-9-]+$/.test(endpoint.id) &&
      endpoint.id !== root.endpoint &&
      endpoint.host === `${endpoint.id}${hostSuffix}`,
    "Unexpected Preview endpoint hostname",
  );
  return endpoint;
}

async function writeVariables(api, config, selection, branch, endpoint) {
  const { neon, variables, vercel } = config;
  const query = new URLSearchParams({
    branch_id: branch.id,
    endpoint_id: endpoint.id,
    database_name: neon.database,
    role_name: neon.role,
  });
  const path = `/projects/${neon.project}/connection_uri?${query}`;
  const { uri: pooled } = await api("neon", `${path}&pooled=true`);
  const { uri: direct } = await api("neon", `${path}&pooled=false`);
  const pooledHost = `${endpoint.id}-pooler${neon.hostSuffix}`;
  for (const [uri, host] of [
    [pooled, pooledHost],
    [direct, endpoint.host],
  ]) {
    try {
      assertDatabaseUrl(uri, host, neon, "Neon connection URI");
    } catch (error) {
      throw new ProvisionError(error.message);
    }
  }
  const entry = (key, value, type) => ({
    key,
    value,
    type,
    target: ["preview"],
    gitBranch: selection.branch,
  });
  const written = await api(
    "vercel",
    `/v10/projects/${vercel.project}/env?teamId=${vercel.team}&upsert=true`,
    [
      ...variables.pooled.map((key) => entry(key, pooled, "sensitive")),
      ...variables.direct.map((key) => entry(key, direct, "sensitive")),
      entry(MARKER, endpoint.host, "plain"),
    ],
  );
  requireThat(
    !written?.failed?.length,
    "Vercel refused a Preview variable write; response withheld",
  );
}

function assertPreviewScopes(after, config, selection, endpoint) {
  for (const key of managedKeys(config)) {
    const matches = after.envs.filter(
      (env) => env.key === key && env.gitBranch === selection.branch,
    );
    requireThat(
      matches.length === 1 &&
        JSON.stringify(targets(matches[0])) === '["preview"]' &&
        !matches[0].configurationId &&
        matches[0].type === (key === MARKER ? "plain" : "sensitive"),
      `Preview variable ${key} has missing or unexpected scope`,
    );
    if (key === MARKER) {
      requireThat(matches[0].value === endpoint.host, "Preview endpoint marker differs");
    }
  }
}

async function deployExactHead(api, config, selection, branch, before) {
  const { project, team, name } = config.vercel;
  const deployment = await api("vercel", `/v13/deployments?teamId=${team}`, {
    name,
    project,
    gitSource: {
      type: "github",
      repoId: selection.repoId,
      ref: selection.branch,
      sha: selection.sha,
    },
    meta: { previewDatabaseBranch: branch.id, previewProvisioner: "v1" },
  });
  requireThat(
    /^dpl_[a-zA-Z0-9]+$/.test(deployment.id) &&
      [undefined, null, "preview"].includes(deployment.target) &&
      /^[a-z0-9-]+\.vercel\.app$/.test(deployment.url),
    "Vercel returned an unexpected Preview deployment",
  );
  const deadline = Date.now() + BUILD_DEADLINE_MS;
  while (Date.now() < deadline) {
    const built = await api("vercel", `/v13/deployments/${deployment.id}?teamId=${team}`);
    requireThat(
      built.id === deployment.id &&
        built.projectId === project &&
        [undefined, null, "preview"].includes(built.target) &&
        built.gitSource?.sha === selection.sha &&
        built.meta?.previewDatabaseBranch === branch.id,
      "Deployment read-back does not match the requested Preview",
    );
    if (built.readyState === "READY") {
      assertProductionUnchanged(before, await snapshot(api, config), "during the Preview build");
      return { deploymentId: deployment.id, url: `https://${deployment.url}` };
    }
    requireThat(
      ["QUEUED", "INITIALIZING", "BUILDING"].includes(built.readyState),
      "Preview deployment failed or was cancelled",
    );
    if (Date.now() >= deadline) break;
    await delay(10000);
  }
  throw new ProvisionError("Preview deployment did not become READY within twenty minutes");
}

export async function provisionPreview(api, config, mode, selector) {
  requireThat(mode === "check" || mode === "apply", "Expected check or apply");
  const selection = await selectPreview(api, config, selector);
  const before = await snapshot(api, config);
  requireThat(
    Number(before.project.link.repoId) === selection.repoId,
    "Vercel repository ID differs",
  );
  assertNoUnsafeEntries(before.envs, config);
  await assertRoot(api, config);
  const branch = await ensureChild(api, config, mode, `preview/${selection.branch}`);
  const endpoint = await childEndpoint(api, config, branch);
  if (mode === "apply") await writeVariables(api, config, selection, branch, endpoint);
  const after = await snapshot(api, config);
  assertProductionUnchanged(before, after, "during provisioning");
  assertPreviewScopes(after, config, selection, endpoint);
  requireThat(
    JSON.stringify(await selectPreview(api, config, selector)) === JSON.stringify(selection),
    "Preview source changed during provisioning; rerun for the current head",
  );
  const result = { ...selection, branchId: branch.id, host: endpoint.host };
  if (mode === "check") return { ...result, verification: "metadata-only" };
  return { ...result, ...(await deployExactHead(api, config, selection, branch, before)) };
}

export function apiClient(cli) {
  const origins = {
    github: "https://api.github.com",
    neon: "https://console.neon.tech/api/v2",
    vercel: "https://api.vercel.com",
  };
  const tokens = {
    github: process.env.GITHUB_TOKEN,
    neon: process.env.NEON_PREVIEW_API_KEY,
    vercel: process.env.VERCEL_PREVIEW_TOKEN,
  };
  if (!cli) {
    for (const service of Object.keys(tokens)) {
      requireThat(tokens[service], `Missing ${service} provisioning credential`);
    }
  }
  return async (service, path, body) => {
    const method = body === undefined ? "GET" : "POST";
    if (cli) {
      const command = service === "github" ? "gh" : service;
      const args = ["api", path, "-X", method];
      if (service === "neon") args.push("--no-analytics");
      if (body !== undefined) args.push(service === "neon" ? "-d" : "--input", "-");
      const result = spawnSync(command, args, {
        input: body === undefined ? undefined : JSON.stringify(body),
        encoding: "utf8",
        timeout: 60000,
        maxBuffer: 8 * 1024 * 1024,
      });
      requireThat(result.status === 0, `${service} ${method} request failed; response withheld`, 3);
      try {
        return JSON.parse(result.stdout);
      } catch {
        throw new ProvisionError(`${service} returned invalid JSON`, 3);
      }
    }
    let response;
    try {
      response = await fetch(origins[service] + path, {
        method,
        redirect: "error",
        signal: AbortSignal.timeout(60000),
        headers: {
          Authorization: `Bearer ${tokens[service]}`,
          "Content-Type": "application/json",
          Accept: "application/json",
        },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
    } catch {
      throw new ProvisionError(
        `${service} ${method} request failed; transport details withheld`,
        3,
      );
    }
    requireThat(
      response.ok,
      `${service} ${method} request failed with HTTP ${response.status}; response withheld`,
      3,
    );
    try {
      return await response.json();
    } catch {
      throw new ProvisionError(`${service} returned invalid JSON`, 3);
    }
  };
}

function runTests(root) {
  const env = {
    PATH: process.env.PATH,
    HOME: process.env.HOME,
    PREVIEW_PROVISION_CONFIGS: resolve(root, SOURCES.config),
  };
  const result = spawnSync(process.execPath, ["--test", join(HERE, "provision.test.mjs")], {
    stdio: "inherit",
    timeout: 120000,
    env,
  });
  requireThat(result.status === 0, "Preview provisioning self-test failed");
}

const USAGE = `Usage: provision.mjs <apply|check|export> <pr:number|${STANDING}> [--root dir] [--cli-auth], list [--root dir] [--cli-auth], or test [--root dir]`;

export function parseArgs(argv) {
  const options = { root: ".", cli: false, positional: [] };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === "--cli-auth") options.cli = true;
    else if (argv[i] === "--root" && argv[i + 1]) options.root = argv[++i];
    else options.positional.push(argv[i]);
  }
  const [mode, selector] = options.positional;
  const count = options.positional.length;
  requireThat(
    ((mode === "list" || mode === "test") && count === 1 && !(mode === "test" && options.cli)) ||
      (["apply", "check", "export"].includes(mode) &&
        count === 2 &&
        new RegExp(`^(pr:[1-9][0-9]*|${STANDING})$`).test(selector)),
    USAGE,
    2,
  );
  return { ...options, mode, selector };
}

async function main(argv) {
  const { root, cli, mode, selector } = parseArgs(argv);
  const config = assertTrustedSources(root);
  if (mode === "test") {
    runTests(root);
    return;
  }
  const api = apiClient(cli);
  const result =
    mode === "list"
      ? (await listBranches(api, config)).map(({ id, name, project_id, parent_id }) => ({
          id,
          name,
          project_id,
          parent_id,
        }))
      : await provisionPreview(api, config, mode === "apply" ? "apply" : "check", selector);
  console.log(JSON.stringify(result));
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(
      `[preview-provision] ${error instanceof Error ? error.message : "Provisioning failed"}`,
    );
    process.exitCode = error instanceof ProvisionError ? error.exitCode : 1;
  });
}
