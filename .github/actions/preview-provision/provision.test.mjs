// Offline fixtures only: stub APIs, no network and no credential.
// PREVIEW_PROVISION_CONFIGS adds real product configurations, separated by ":".
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, describe, it } from "node:test";
import { fileURLToPath } from "node:url";

import { assertPreviewDatabase } from "./guard.mjs";
import {
  apiClient,
  assertTrustedSources,
  parseArgs,
  parseConfig,
  provisionPreview,
  selectPreview,
  SOURCES,
} from "./provision.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const SHA = "a".repeat(40);
const OTHER_SHA = "b".repeat(40);
const PR = "pr:7";
const FEATURE = "feature/example";
const CI_RUN = "ci-run:555";

const threeVariables = {
  schema: 1,
  repo: "digio-nz/full-three",
  vercel: { project: "prj_three", team: "team_shared", name: "full-three" },
  neon: {
    project: "three-preview-1",
    root: { branch: "br-three-root", endpoint: "ep-three-root" },
    hostSuffix: ".c-5.eu-central-1.aws.neon.tech",
    database: "neondb",
    role: "neondb_owner",
  },
  variables: {
    pooled: ["DATABASE_URL"],
    direct: ["DATABASE_URL_UNPOOLED", "DATABASE_URL_DIRECT"],
  },
};
const twoVariables = {
  schema: 1,
  repo: "digio-nz/full-two",
  vercel: { project: "prj_two", team: "team_shared", name: "full-two" },
  neon: {
    project: "two-preview-2",
    root: { branch: "br-two-root", endpoint: "ep-two-root" },
    hostSuffix: ".c-7.eu-central-1.aws.neon.tech",
    database: "two_preview",
    role: "two_preview_owner",
  },
  variables: { pooled: ["DATABASE_URL"], direct: ["DATABASE_URL_UNPOOLED"] },
};
const extra = (process.env.PREVIEW_PROVISION_CONFIGS ?? "")
  .split(":")
  .filter(Boolean)
  .map((path) => JSON.parse(readFileSync(path, "utf8")));
const CONFIGS = [threeVariables, twoVariables, ...extra];

const hostOf = (config) => `ep-fixture${config.neon.hostSuffix}`;
const uriOf = (config, pooled = false) =>
  `postgresql://${config.neon.role}:fixture-only@${
    pooled ? `ep-fixture-pooler${config.neon.hostSuffix}` : hostOf(config)
  }/${config.neon.database}?sslmode=require`;

function fixture(config) {
  const { neon, vercel, repo } = config;
  const [org, name] = repo.split("/");
  const parent = { id: neon.root.branch, project_id: neon.project, name: "preview" };
  const child = {
    id: "br-fixture",
    project_id: neon.project,
    parent_id: neon.root.branch,
    name: `preview/${FEATURE}`,
  };
  const project = {
    id: vercel.project,
    accountId: vercel.team,
    link: { org, repo: name, productionBranch: "main", repoId: 42 },
    ssoProtection: { deploymentType: "all_except_custom_domains" },
    autoAssignCustomDomains: false,
    gitForkProtection: true,
    customEnvironments: [],
    targets: { production: { id: "dpl_PROD" }, preview: {} },
  };
  const pr = {
    state: "open",
    user: { login: "person" },
    base: { ref: "main", repo: { full_name: repo, id: 42 } },
    head: { ref: FEATURE, sha: SHA, repo: { full_name: repo, id: 42 } },
  };
  const ciRun = (overrides = {}) => ({
    id: 555,
    path: ".github/workflows/ci.yml",
    status: "completed",
    conclusion: "success",
    event: "pull_request",
    head_sha: SHA,
    head_branch: FEATURE,
    repository: { full_name: repo },
    head_repository: { full_name: repo },
    pull_requests: [{ number: 7, base: { ref: "main", repo: { full_name: repo } } }],
    ...overrides,
  });
  const production = {
    id: "prod",
    key: "DATABASE_URL",
    target: ["production"],
    type: "sensitive",
    value: "withheld",
    updatedAt: 1,
  };
  const state = {
    parent,
    child,
    project,
    pr,
    production,
    branches: [],
    envs: [production],
    endpoint: {
      id: "ep-fixture",
      branch_id: child.id,
      host: hostOf(config),
      type: "read_write",
      disabled: false,
    },
    rootEndpoints: [{ id: neon.root.endpoint }],
    readyState: "READY",
    returnedTarget: null,
    returnedSha: SHA,
    standingSha: SHA,
    race: false,
    stale: false,
    wrongUri: false,
    ignoredWrite: false,
    productionDrift: false,
    productionTargetDrift: false,
    driftDuringBuild: false,
    coupledReadBack: false,
    failedWrite: false,
    envPagination: undefined,
    prReads: 0,
    ciRun: ciRun(),
    runs: [ciRun(), ciRun({ id: 556, event: "merge_group", head_branch: "gh-readonly-queue/x" })],
    openPulls: [{ number: 7 }],
    deployments: [],
  };
  const detail = (id) => ({
    id,
    url: `${vercel.name}-${id.toLowerCase().replace("_", "-")}.vercel.app`,
    projectId: vercel.project,
    target: state.returnedTarget,
    readyState: state.readyState,
    gitSource: {
      type: "github",
      repoId: 42,
      ref: state.deployRef ?? state.pr.head.ref,
      sha: state.returnedSha,
    },
    meta: {
      previewDatabaseBranch: child.id,
      previewDatabaseHost: state.endpoint.host,
      previewProvisioner: "v1",
    },
  });
  const calls = [];
  const api = async (service, path, body) => {
    calls.push({ service, path, body });
    let result;
    if (service === "github" && path === `/repos/${repo}/pulls/7`) {
      state.prReads += 1;
      result =
        state.stale && state.prReads > 1 ? { ...pr, head: { ...pr.head, sha: OTHER_SHA } } : pr;
    } else if (service === "github" && path.startsWith(`/repos/${repo}/actions/runs?`)) {
      const sha = new URLSearchParams(path.split("?")[1]).get("head_sha");
      result = { workflow_runs: state.runs.filter((run) => run.head_sha === sha) };
    } else if (service === "github" && path === `/repos/${repo}/actions/runs/555`)
      result = state.ciRun;
    else if (service === "github" && path.startsWith(`/repos/${repo}/pulls?`))
      result = state.openPulls;
    else if (service === "github" && path === `/repos/${repo}`) result = { id: 42 };
    else if (service === "github" && path.endsWith("/git/ref/heads/main"))
      result = { object: { sha: SHA } };
    else if (service === "github" && path.endsWith("/git/ref/heads/standing-preview"))
      result = { object: { sha: state.standingSha } };
    else if (path.startsWith(`/v9/projects/${vercel.project}?`)) result = project;
    else if (path.startsWith(`/v10/projects/${vercel.project}/env?`)) {
      if (body && !state.ignoredWrite) {
        for (const [i, env] of body.entries()) {
          const existing = state.envs.find(
            (old) =>
              old.key === env.key &&
              (old.gitBranch ?? null) === env.gitBranch &&
              old.target.some((target) => env.target.includes(target)),
          );
          const replacement = {
            ...env,
            id: existing?.id ?? `preview-${i}`,
            ...(state.coupledReadBack ? { configurationId: "icfg_coupled" } : {}),
          };
          if (existing) Object.assign(existing, replacement);
          else state.envs.push(replacement);
        }
        if (state.productionDrift) state.production.updatedAt = 2;
        if (state.productionTargetDrift) project.targets.production.id = "dpl_OTHER";
      }
      result = body
        ? { created: body, failed: state.failedWrite ? [{ error: { code: "fixture" } }] : [] }
        : { envs: state.envs, pagination: state.envPagination };
    } else if (path === `/projects/${neon.project}/branches/${neon.root.branch}`)
      result = { branch: parent };
    else if (path === `/projects/${neon.project}/branches/${neon.root.branch}/endpoints`)
      result = { endpoints: state.rootEndpoints };
    else if (path === `/projects/${neon.project}/branches` && body) {
      state.branches.push(child);
      if (state.race) throw new Error("Lost create response");
      result = { branch: child };
    } else if (path.startsWith(`/projects/${neon.project}/branches?`))
      result = { branches: state.branches };
    else if (path === `/projects/${neon.project}/branches/${child.id}/endpoints`)
      result = { endpoints: [state.endpoint] };
    else if (path.startsWith(`/projects/${neon.project}/connection_uri?`))
      result = {
        uri: state.wrongUri
          ? uriOf(config).replace(hostOf(config), "production.example.invalid")
          : uriOf(config, path.endsWith("pooled=true")),
      };
    else if (path.startsWith("/v7/deployments?")) result = { deployments: state.deployments };
    else if (path.startsWith("/v13/deployments?")) {
      state.deployRef = body.gitSource.ref;
      state.readyState = state.retryReadyState ?? state.readyState;
      result = { ...detail("dpl_TEST"), readyState: "QUEUED" };
    } else if (path.startsWith("/v13/deployments/dpl_TEST?")) {
      project.targets.preview = { id: "dpl_TEST" };
      if (state.driftDuringBuild) state.production.updatedAt = 3;
      result = detail("dpl_TEST");
    } else if (path.startsWith("/v13/deployments/")) {
      const id = path.split("/")[3].split("?")[0];
      const existing = state.deployments.find((d) => d.uid === id);
      result = { ...detail(id), ...existing.detail };
    } else throw new Error(`Unexpected fixture request ${service} ${path}`);
    if (path.startsWith("/v13/deployments/") && new URLSearchParams(path.split("?")[1]).get("withGitRepoInfo") !== "true") delete result.gitSource;
    return structuredClone(result);
  };
  return { api, state, calls, writes: () => calls.filter((call) => call.body !== undefined) };
}

const finding = (error) => error.exitCode === 1;

const deploymentRequested = (f) =>
  f.writes().some((call) => call.path.startsWith("/v13/deployments"));

for (const config of CONFIGS) {
  describe(`provisioning ${config.repo}`, () => {
    const { neon, vercel, variables } = config;

    it("accepts the configuration", () => {
      assert.equal(parseConfig(config), config);
    });

    it("creates from the explicit root, scopes credentials to Preview and deploys the exact head", async () => {
      const f = fixture(config);
      const result = await provisionPreview(f.api, config, "apply", PR);
      assert.equal(result.sha, SHA);
      assert.equal(result.branchId, "br-fixture");
      assert.equal(result.deploymentId, "dpl_TEST");
      assert.deepEqual(
        f.writes().map((call) => [call.service, call.path.split("?")[0]]),
        [
          ["neon", `/projects/${neon.project}/branches`],
          ["vercel", `/v10/projects/${vercel.project}/env`],
          ["vercel", "/v13/deployments"],
        ],
      );
      const [branchWrite, envWrite, deployWrite] = f.writes();
      assert.deepEqual(branchWrite.body, {
        branch: { name: `preview/${FEATURE}`, parent_id: neon.root.branch },
        endpoints: [{ type: "read_write" }],
      });
      const scoped = { target: ["preview"], gitBranch: FEATURE };
      assert.deepEqual(envWrite.body, [
        ...variables.pooled.map((key) => ({
          key,
          value: uriOf(config, true),
          type: "sensitive",
          ...scoped,
        })),
        ...variables.direct.map((key) => ({
          key,
          value: uriOf(config),
          type: "sensitive",
          ...scoped,
        })),
        { key: "PREVIEW_DATABASE_HOST", value: hostOf(config), type: "plain", ...scoped },
      ]);
      assert.deepEqual(deployWrite.body, {
        name: vercel.name,
        project: vercel.project,
        gitSource: { type: "github", repoId: 42, ref: FEATURE, sha: SHA },
        meta: {
          previewDatabaseBranch: "br-fixture",
          previewDatabaseHost: hostOf(config),
          previewProvisioner: "v1",
        },
      });
      assert.ok(!JSON.stringify(result).includes("fixture-only"));
    });

    it("preserves the Production entry and target through a complete run", async () => {
      const f = fixture(config);
      const before = structuredClone([f.state.production, f.state.project.targets.production]);
      await provisionPreview(f.api, config, "apply", PR);
      assert.deepEqual([f.state.envs[0], f.state.project.targets.production], before);
      assert.ok(f.writes().every((call) => !JSON.stringify(call.body).includes('"production"')));
    });

    it("fails a read-only check on missing provisioning without creating anything", async () => {
      const f = fixture(config);
      await assert.rejects(provisionPreview(f.api, config, "check", PR), /branch is missing/);
      assert.deepEqual(f.writes(), []);
    });

    for (const race of [false, true]) {
      it(`reuses a verified branch after an existing branch or lost create response, race=${race}`, async () => {
        const f = fixture(config);
        f.state.race = race;
        if (!race) f.state.branches.push(f.state.child);
        await provisionPreview(f.api, config, "apply", PR);
        assert.equal(f.writes().filter((call) => call.service === "neon").length, race ? 1 : 0);
        f.calls.length = 0;
        const checked = await provisionPreview(f.api, config, "check", PR);
        assert.equal(checked.verification, "metadata-only");
        assert.deepEqual(f.writes(), []);
      });
    }

    const refusals = {
      closed: (s) => (s.pr.state = "closed"),
      fork: (s) => (s.pr.head.repo.full_name = "outside/product"),
      "deleted fork": (s) => (s.pr.head.repo = null),
      main: (s) => (s.pr.head.ref = "main"),
      "standing as PR head": (s) => (s.pr.head.ref = "standing-preview"),
      dependabot: (s) => (s.pr.head.ref = "dependabot/npm/example"),
      "merge queue": (s) => (s.pr.head.ref = "gh-readonly-queue/main/pr-7"),
      "short SHA": (s) => (s.pr.head.sha = "abc123"),
      "control character in ref": (s) => (s.pr.head.ref = "feature\nexample"),
      "other base": (s) => (s.pr.base.ref = "release"),
      protection: (s) => (s.project.ssoProtection.deploymentType = "none"),
      promotion: (s) => (s.project.autoAssignCustomDomains = true),
      "other Vercel repository": (s) => (s.project.link.repo = "other"),
      "other Vercel repository ID": (s) => (s.project.link.repoId = 43),
      "other Production branch": (s) => (s.project.link.productionBranch = "release"),
      "missing Production target": (s) => Reflect.deleteProperty(s.project.targets, "production"),
      "missing Production database": (s) => (s.production.key = "OTHER"),
      "root with a parent": (s) => (s.parent.parent_id = "br-production"),
      "root renamed": (s) => (s.parent.name = "production"),
      "root from another project": (s) => (s.parent.project_id = "production-project"),
      "root on another endpoint": (s) => (s.rootEndpoints = [{ id: "ep-production" }]),
      "child from Production": (s) => {
        s.child.parent_id = "br-production";
        s.branches.push(s.child);
      },
      "child in another project": (s) => {
        s.child.project_id = "production-project";
        s.branches.push(s.child);
      },
      "child that expires": (s) => {
        s.child.expires_at = "2030-01-01T00:00:00Z";
        s.branches.push(s.child);
      },
      "child is the root": (s) => {
        s.child.id = neon.root.branch;
        s.branches.push(s.child);
      },
      duplicate: (s) => s.branches.push(s.child, s.child),
      "child on the root endpoint": (s) => {
        s.endpoint.id = neon.root.endpoint;
        s.endpoint.host = `${neon.root.endpoint}${neon.hostSuffix}`;
        s.branches.push(s.child);
      },
      "child in another host class": (s) => {
        s.endpoint.host = "ep-fixture.c-9.eu-central-1.aws.neon.tech";
        s.branches.push(s.child);
      },
      "Dependabot author on another branch name": (s) => (s.pr.user.login = "dependabot[bot]"),
      "capitalised Dependabot branch": (s) => (s.pr.head.ref = "Dependabot/npm/example"),
      "ref alias for main": (s) => (s.pr.head.ref = "refs/heads/main"),
      "short ref alias for main": (s) => (s.pr.head.ref = "heads/main"),
      "fork protection off": (s) => (s.project.gitForkProtection = false),
      "custom environment": (s) => s.project.customEnvironments.push({ id: "env_x" }),
      "incomplete Vercel inventory": (s) => (s.envPagination = { next: 123 }),
      "database variable shared with Production": (s) =>
        s.envs.push({
          id: "shared",
          key: "DATABASE_URL_UNPOOLED",
          target: ["production", "preview"],
          type: "encrypted",
        }),
      "integration-owned Preview variable": (s) =>
        s.envs.push({
          id: "legacy",
          key: "DATABASE_URL",
          target: ["preview"],
          type: "encrypted",
          configurationId: "icfg_coupled",
        }),
    };
    for (const [kind, arrange] of Object.entries(refusals)) {
      it(`refuses ${kind} before any write`, async () => {
        const f = fixture(config);
        arrange(f.state);
        await assert.rejects(provisionPreview(f.api, config, "apply", PR), finding);
        assert.deepEqual(f.writes(), []);
      });
    }

    const prProof = (s, change) => (s.runs = [{ ...s.ciRun, ...change(s.ciRun) }]);
    const proofRefusals = {
      "missing CI proof": (s) => (s.runs = []),
      "failed CI": (s) => prProof(s, () => ({ conclusion: "failure" })),
      "cancelled CI": (s) => prProof(s, () => ({ conclusion: "cancelled" })),
      "CI still running": (s) => prProof(s, () => ({ status: "in_progress", conclusion: null })),
      "a workflow named CI at another path": (s) =>
        prProof(s, () => ({ path: ".github/workflows/other.yml" })),
      "CI from a fork": (s) => prProof(s, () => ({ head_repository: { full_name: "outside/x" } })),
      "CI for an older head": (s) => prProof(s, () => ({ head_sha: OTHER_SHA })),
      "merge-group proof for a PR": (s) => prProof(s, () => ({ event: "merge_group" })),
    };
    for (const [kind, arrange] of Object.entries(proofRefusals)) {
      it(`refuses ${kind} before any write`, async () => {
        const f = fixture(config);
        arrange(f.state);
        await assert.rejects(provisionPreview(f.api, config, "apply", PR), finding);
        assert.deepEqual(f.writes(), []);
      });
    }

    it("deploys the PR that a successful CI run names", async () => {
      const f = fixture(config);
      const result = await provisionPreview(f.api, config, "apply", CI_RUN);
      assert.equal(result.sha, SHA);
      assert.equal(result.branch, FEATURE);
      assert.ok(!f.calls.some((call) => call.path.includes("/pulls?")));
    });

    it("resolves a CI run with no listed PR through the open PRs of its branch", async () => {
      const f = fixture(config);
      f.state.ciRun.pull_requests = [];
      await provisionPreview(f.api, config, "apply", CI_RUN);
      const lookup = f.calls.find((call) => call.path.includes("/pulls?"));
      assert.equal(
        new URLSearchParams(lookup.path.split("?")[1]).get("head"),
        `${config.repo.split("/")[0]}:${FEATURE}`,
      );
    });

    const wakeRefusals = {
      "failed CI run": (s) => (s.ciRun.conclusion = "failure"),
      "cancelled CI run": (s) => (s.ciRun.conclusion = "cancelled"),
      "CI run at another path": (s) => (s.ciRun.path = ".github/workflows/ci-copy.yml"),
      "CI run from a fork": (s) => (s.ciRun.head_repository = { full_name: "outside/x" }),
      "CI run for a push": (s) => (s.ciRun.event = "push"),
      "CI run for an older head": (s) => {
        s.ciRun.head_sha = OTHER_SHA;
        s.runs.push({ ...s.ciRun });
      },
      "CI run with no PR and no open PR": (s) => {
        s.ciRun.pull_requests = [];
        s.openPulls = [];
      },
      "CI run with no PR and two open PRs": (s) => {
        s.ciRun.pull_requests = [];
        s.openPulls = [{ number: 7 }, { number: 8 }];
      },
      "CI run for a Dependabot PR": (s) => (s.pr.user.login = "dependabot[bot]"),
    };
    for (const [kind, arrange] of Object.entries(wakeRefusals)) {
      it(`refuses a wake-up from a ${kind} before any write`, async () => {
        const f = fixture(config);
        arrange(f.state);
        await assert.rejects(provisionPreview(f.api, config, "apply", CI_RUN), finding);
        assert.deepEqual(f.writes(), []);
      });
    }

    const existing = (uid, readyState, detail = {}) => ({
      uid,
      readyState,
      target: null,
      detail: { readyState: "READY", ...detail },
    });

    for (const state of ["QUEUED", "BUILDING", "READY"]) {
      it(`reuses this provisioner's ${state} deployment of the same head`, async () => {
        const f = fixture(config);
        f.state.branches.push(f.state.child);
        f.state.deployments = [existing("dpl_OLD", state)];
        const result = await provisionPreview(f.api, config, "apply", PR);
        assert.equal(result.deploymentId, "dpl_OLD");
        assert.equal(deploymentRequested(f), false);
        const query = new URLSearchParams(
          f.calls.find((call) => call.path.startsWith("/v7/")).path.split("?")[1],
        );
        assert.deepEqual(
          [query.get("projectId"), query.get("sha"), query.get("branch")],
          [vercel.project, SHA, FEATURE],
        );
      });
    }

    const notReusable = {
      error: existing("dpl_OLD", "ERROR"),
      canceled: existing("dpl_OLD", "CANCELED"),
      "error on read-back": existing("dpl_OLD", "READY", { readyState: "ERROR" }),
      "production target": existing("dpl_OLD", "READY", { target: "production" }),
      "another head": existing("dpl_OLD", "READY", {
        gitSource: { type: "github", repoId: 42, ref: FEATURE, sha: OTHER_SHA },
      }),
      "another branch": existing("dpl_OLD", "READY", {
        gitSource: { type: "github", repoId: 42, ref: "other", sha: SHA },
      }),
      "an automatic Git build": existing("dpl_OLD", "READY", { meta: {} }),
      "another database branch": existing("dpl_OLD", "READY", {
        meta: {
          previewDatabaseBranch: "br-other",
          previewDatabaseHost: hostOf(config),
          previewProvisioner: "v1",
        },
      }),
      "another endpoint host": existing("dpl_OLD", "READY", {
        meta: {
          previewDatabaseBranch: "br-fixture",
          previewDatabaseHost: `ep-other${neon.hostSuffix}`,
          previewProvisioner: "v1",
        },
      }),
    };
    for (const [kind, deployment] of Object.entries(notReusable)) {
      it(`deploys afresh instead of reusing ${kind}`, async () => {
        const f = fixture(config);
        f.state.deployments = [deployment];
        const result = await provisionPreview(f.api, config, "apply", PR);
        assert.equal(result.deploymentId, "dpl_TEST");
        assert.equal(deploymentRequested(f), true);
      });
    }

    it("refuses the standing Preview without merge-group or push proof", async () => {
      const f = fixture(config);
      f.state.child.name = "preview/standing-preview";
      f.state.runs = f.state.runs.filter((run) => run.event === "pull_request");
      await assert.rejects(provisionPreview(f.api, config, "apply", "standing-preview"), finding);
      assert.deepEqual(f.writes(), []);
    });

    for (const kind of [
      "wrongUri",
      "ignoredWrite",
      "productionDrift",
      "productionTargetDrift",
      "coupledReadBack",
      "failedWrite",
      "stale",
    ]) {
      it(`refuses ${kind} before requesting a deployment`, async () => {
        const f = fixture(config);
        f.state[kind] = true;
        await assert.rejects(provisionPreview(f.api, config, "apply", PR), finding);
        assert.equal(deploymentRequested(f), false);
      });
    }

    const readBacks = {
      production: (s) => (s.returnedTarget = "production"),
      "wrong-sha": (s) => (s.returnedSha = OTHER_SHA),
      error: (s) => (s.readyState = "ERROR"),
      "production drift during the build": (s) => (s.driftDuringBuild = true),
    };
    for (const [kind, arrange] of Object.entries(readBacks)) {
      it(`does not report success for ${kind} deployment read-back`, async () => {
        const f = fixture(config);
        arrange(f.state);
        await assert.rejects(provisionPreview(f.api, config, "apply", PR), finding);
      });
    }

    it("requires the standing mirror to equal current main", async () => {
      const f = fixture(config);
      assert.deepEqual(await selectPreview(f.api, config, "standing-preview"), {
        branch: "standing-preview",
        sha: SHA,
        repoId: 42,
      });
      f.state.standingSha = OTHER_SHA;
      await assert.rejects(
        selectPreview(f.api, config, "standing-preview"),
        /does not match current main/,
      );
      assert.deepEqual(f.writes(), []);
    });

    it("provisions the standing branch only under the Preview name", async () => {
      const f = fixture(config);
      f.state.child.name = "preview/standing-preview";
      await provisionPreview(f.api, config, "apply", "standing-preview");
      assert.equal(f.writes()[0].body.branch.name, "preview/standing-preview");
      assert.ok(f.writes()[1].body.every((env) => env.gitBranch === "standing-preview"));
      assert.equal(f.writes()[2].body.gitSource.ref, "standing-preview");
    });

    it("fails when API latency exhausts the build polling deadline", async (t) => {
      const f = fixture(config);
      f.state.readyState = "BUILDING";
      let now = 0;
      t.mock.method(Date, "now", () => now);
      const slow = async (service, path, body) => {
        const result = await f.api(service, path, body);
        if (path.startsWith("/v13/deployments/dpl_TEST?")) now = 20 * 60 * 1000;
        return result;
      };
      await assert.rejects(provisionPreview(slow, config, "apply", PR), /within twenty minutes/);
    });
  });

  describe(`migration guard for ${config.repo}`, () => {
    const { neon, variables } = config;
    const env = () => ({
      VERCEL_ENV: "preview",
      PREVIEW_DATABASE_HOST: hostOf(config),
      ...Object.fromEntries(variables.pooled.map((key) => [key, uriOf(config, true)])),
      ...Object.fromEntries(variables.direct.map((key) => [key, uriOf(config)])),
    });

    it("accepts one provisioned endpoint", () => {
      assert.doesNotThrow(() => assertPreviewDatabase(env(), config));
    });

    it("refuses every missing value", () => {
      for (const key of Object.keys(env())) {
        assert.throws(
          () => assertPreviewDatabase({ ...env(), [key]: undefined }, config),
          new RegExp(key),
        );
      }
    });

    it("refuses the shared root, another host class and mixed targets", () => {
      assert.throws(
        () =>
          assertPreviewDatabase(
            { ...env(), PREVIEW_DATABASE_HOST: `${neon.root.endpoint}${neon.hostSuffix}` },
            config,
          ),
        /provisioned child/,
      );
      assert.throws(
        () =>
          assertPreviewDatabase(
            { ...env(), PREVIEW_DATABASE_HOST: "ep-fixture.c-9.eu-central-1.aws.neon.tech" },
            config,
          ),
        /provisioned child/,
      );
      for (const key of [...variables.pooled, ...variables.direct]) {
        const value = env()[key];
        for (const [label, broken] of [
          ["host", value.replace(/@[^/]+/, "@production.example.invalid")],
          ["ssl", value.replace("sslmode=require", "sslmode=disable")],
          ["database", value.replace(`/${neon.database}?`, "/other?")],
          ["role", value.replace(`${neon.role}:`, "other:")],
          ["host override", `${value}&host=production.example.invalid`],
          ["second sslmode", `${value}&sslmode=disable`],
        ]) {
          assert.throws(
            () => assertPreviewDatabase({ ...env(), [key]: broken }, config),
            new RegExp(key),
            `${key} ${label}`,
          );
        }
      }
    });

    it("refuses outside Preview", () => {
      assert.throws(() => assertPreviewDatabase({ ...env(), VERCEL_ENV: "production" }, config));
    });
  });
}

describe("configuration", () => {
  const breaks = {
    "unknown key": (c) => (c.extra = true),
    "wrong schema": (c) => (c.schema = 2),
    "repo outside the organisation": (c) => (c.repo = "outside/product"),
    "non-database variable": (c) => c.variables.direct.push("JWT_SECRET"),
    "marker as a variable": (c) => c.variables.direct.push("PREVIEW_DATABASE_HOST"),
    "repeated variable": (c) => c.variables.direct.push("DATABASE_URL"),
    "no pooled DATABASE_URL": (c) => (c.variables.pooled = ["DATABASE_URL_POOLED"]),
    "no direct variable": (c) => (c.variables.direct = []),
    "suffix outside Neon": (c) => (c.neon.hostSuffix = ".example.com"),
    "missing root endpoint": (c) => Reflect.deleteProperty(c.neon.root, "endpoint"),
  };
  for (const [kind, arrange] of Object.entries(breaks)) {
    it(`refuses ${kind} as invalid input`, () => {
      const config = structuredClone(twoVariables);
      arrange(config);
      assert.throws(
        () => parseConfig(config),
        (error) => error.exitCode === 2,
      );
    });
  }
});

describe("trusted sources", () => {
  const roots = [];
  after(() => roots.forEach((root) => rmSync(root, { recursive: true, force: true })));

  function product() {
    const root = mkdtempSync(join(tmpdir(), "preview-provision-"));
    roots.push(root);
    mkdirSync(join(root, "scripts/preview"), { recursive: true });
    mkdirSync(join(root, ".github/workflows"), { recursive: true });
    copyFileSync(join(HERE, "guard.mjs"), join(root, SOURCES.guard));
    writeFileSync(
      join(root, SOURCES.workflow),
      readFileSync(join(HERE, "trusted-workflow.yml"), "utf8").replace(/0{40}/, "c".repeat(40)),
    );
    writeFileSync(join(root, SOURCES.config), JSON.stringify(twoVariables));
    writeFileSync(
      join(root, SOURCES.vercel),
      JSON.stringify({ git: { deploymentEnabled: { "**": false, main: true, "x/**": false } } }),
    );
    return root;
  }

  it("accepts identical copies with any action pin", () => {
    assert.deepEqual(assertTrustedSources(product()), twoVariables);
  });

  it("refuses a guard that differs", () => {
    const root = product();
    writeFileSync(join(root, SOURCES.guard), "export {};\n");
    assert.throws(() => assertTrustedSources(root), /differs from the shared guard/);
  });

  it("refuses a workflow that differs anywhere but the pin", () => {
    const root = product();
    const text = readFileSync(join(root, SOURCES.workflow), "utf8");
    for (const change of [
      text.replace("persist-credentials: false", "persist-credentials: true"),
      text.replace("ref: main", "ref: ${{ github.event.pull_request.head.sha }}"),
      text.replace("mode: apply", "mode: apply\n          root: pr"),
    ]) {
      writeFileSync(join(root, SOURCES.workflow), change);
      assert.throws(() => assertTrustedSources(root), /differs from the shared trusted workflow/);
    }
  });

  it("accepts vercel.json with main disabled", () => {
    const root = product();
    writeFileSync(
      join(root, SOURCES.vercel),
      JSON.stringify({ git: { deploymentEnabled: { "**": false, main: false } } }),
    );
    assert.deepEqual(assertTrustedSources(root), twoVariables);
  });

  for (const [kind, enabled] of Object.entries({
    "no default refusal": { main: true },
    "main unnamed": { "**": false },
    "main not a boolean": { "**": false, main: "true" },
    "another enabled branch": { "**": false, main: true, "preview/**": true },
    "another enabled branch with main disabled": { "**": false, main: false, "x/**": true },
  })) {
    it(`refuses vercel.json with ${kind}`, () => {
      const root = product();
      writeFileSync(
        join(root, SOURCES.vercel),
        JSON.stringify({ git: { deploymentEnabled: enabled } }),
      );
      assert.throws(() => assertTrustedSources(root), /disable automatic Git deployments/);
    });
  }

  it("refuses an invalid configuration as invalid input", () => {
    const root = product();
    writeFileSync(join(root, SOURCES.config), JSON.stringify({ schema: 1 }));
    assert.throws(
      () => assertTrustedSources(root),
      (error) => error.exitCode === 2,
    );
  });

  it("runs the guard CLI through a symbolic link, without a silent pass", () => {
    const root = product();
    const link = `${root}-link`;
    roots.push(link);
    symlinkSync(root, link);
    const run = spawnSync(process.execPath, [join(link, SOURCES.guard)], {
      encoding: "utf8",
      env: { PATH: process.env.PATH, VERCEL_ENV: "preview" },
    });
    assert.equal(run.status, 1);
    assert.match(run.stderr, /PREVIEW_DATABASE_HOST must name/);
  });
});

describe("trusted workflow text", () => {
  const text = readFileSync(join(HERE, "trusted-workflow.yml"), "utf8");

  it("executes no PR code and installs nothing", () => {
    assert.ok(!/^\s*(- )?run:/m.test(text));
    assert.ok(!/\b(npm|npx|pnpm|yarn|corepack)\b/.test(text));
    assert.ok(!text.includes("head.sha"));
    assert.match(text, /ref: main\n/);
    assert.match(text, /persist-credentials: false/);
    assert.match(text, /package-manager-cache: false/);
    assert.ok(!text.includes("\n  pull_request:\n"));
    assert.ok(!text.includes("pull_request_target"));
  });

  it("pins every action to a full commit", () => {
    const uses = text.match(/uses: \S+/g);
    assert.equal(uses.length, 3);
    for (const line of uses) assert.match(line, /@[0-9a-f]{40}$/);
  });

  it("holds its credentials on the provisioning step in a main-only environment", () => {
    assert.deepEqual(text.match(/secrets\.[A-Z_]+/g), [
      "secrets.NEON_PREVIEW_API_KEY",
      "secrets.VERCEL_PREVIEW_TOKEN",
    ]);
    assert.match(text, /environment: preview-provision\n/);
    assert.match(text, /github\.ref == 'refs\/heads\/main'/);
    assert.match(text, /runs-on: ubuntu-latest\n/);
    assert.match(
      text,
      /permissions:\n {6}actions: read\n {6}contents: read\n {6}pull-requests: read\n/,
    );
  });

  it("wakes only on successful same-repository CI or mirror runs, by workflow path", () => {
    assert.match(text, /workflows: \[CI, Standing Preview\]\n {4}types: \[completed\]\n/);
    for (const condition of [
      "github.event.workflow_run.conclusion == 'success'",
      "github.event.workflow_run.head_repository.full_name == github.repository",
      "github.event.workflow_run.path == '.github/workflows/standing-preview.yml' &&\n      github.event.workflow_run.event == 'push' &&\n      github.event.workflow_run.head_branch == 'main'",
      "github.event.workflow_run.path == '.github/workflows/ci.yml' &&\n      github.event.workflow_run.event == 'pull_request'",
      "github.event.workflow_run.actor.login != 'dependabot[bot]'",
      "!startsWith(github.event.workflow_run.head_branch, 'dependabot/')",
    ]) {
      assert.ok(text.includes(condition), condition);
    }
  });

  it("passes a CI wake-up as its run ID and never defaults it to the standing Preview", () => {
    const selector = text.match(/^ {10}selector: (.+)$/m)[1];
    assert.ok(selector.includes("format('ci-run:{0}', github.event.workflow_run.id)"));
    assert.ok(
      selector.includes(
        "github.event.workflow_run.path == '.github/workflows/standing-preview.yml' && 'standing-preview'",
      ),
    );
    assert.ok(selector.endsWith("|| 'no-selector' }}"));
    assert.throws(
      () => parseArgs(["apply", "no-selector"]),
      (error) => error.exitCode === 2,
    );
  });
});

describe("command line", () => {
  const usage = (argv) =>
    assert.throws(
      () => parseArgs(argv),
      (error) => error.exitCode === 2,
    );

  it("accepts the standard verbs", () => {
    assert.equal(parseArgs(["apply", PR]).selector, PR);
    assert.equal(parseArgs(["check", "standing-preview", "--cli-auth"]).cli, true);
    assert.equal(parseArgs(["export", PR, "--root", "x"]).root, "x");
    assert.equal(parseArgs(["list"]).mode, "list");
    assert.equal(parseArgs(["test"]).mode, "test");
  });

  it("refuses bad usage", () => {
    usage([]);
    usage(["apply"]);
    usage(["apply", "main"]);
    usage(["apply", "pr:0"]);
    usage(["apply", "pr:7;rm"]);
    usage(["delete", PR]);
    usage(["list", PR]);
    usage(["test", "--cli-auth"]);
  });
});

describe("API client", () => {
  const stubCredentials = (t) => {
    const saved = { ...process.env };
    process.env.GITHUB_TOKEN = "github-fixture";
    process.env.NEON_PREVIEW_API_KEY = "neon-fixture";
    process.env.VERCEL_PREVIEW_TOKEN = "vercel-fixture";
    t.after(() => {
      process.env = saved;
    });
  };

  it("names a missing credential before any request", (t) => {
    stubCredentials(t);
    Reflect.deleteProperty(process.env, "VERCEL_PREVIEW_TOKEN");
    const fetcher = t.mock.method(globalThis, "fetch", async () => new Response("{}"));
    assert.throws(() => apiClient(false), /Missing vercel provisioning credential/);
    assert.equal(fetcher.mock.callCount(), 0);
  });

  it("withholds remote error bodies and refuses redirects with credentials", async (t) => {
    stubCredentials(t);
    const fetcher = t.mock.method(
      globalThis,
      "fetch",
      async () => new Response("secret response", { status: 403 }),
    );
    await assert.rejects(apiClient(false)("neon", "/projects/example"), (error) => {
      assert.equal(error.exitCode, 3);
      assert.match(error.message, /HTTP 403; response withheld/);
      assert.ok(!error.message.includes("secret response"));
      return true;
    });
    const [url, options] = fetcher.mock.calls[0].arguments;
    assert.equal(url, "https://console.neon.tech/api/v2/projects/example");
    assert.equal(options.redirect, "error");
    assert.equal(options.headers.Authorization, "Bearer neon-fixture");
  });

  it("withholds transport details", async (t) => {
    stubCredentials(t);
    t.mock.method(globalThis, "fetch", async () => {
      throw new Error("connect failed for secret-host");
    });
    await assert.rejects(apiClient(false)("vercel", "/x"), (error) => {
      assert.equal(error.exitCode, 3);
      assert.ok(!error.message.includes("secret-host"));
      return true;
    });
  });
});
