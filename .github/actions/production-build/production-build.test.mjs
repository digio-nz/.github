// Offline fixtures only: a fake Vercel API, no network and no credential.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

import { apiClient, parseArgs, productionBuild } from "./production-build.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const SHA = "a".repeat(40);
const TIP = "b".repeat(40);
const ENV = {
  VERCEL_ORG_ID: "team_shared",
  VERCEL_PROJECT_ID: "prj_full",
  GITHUB_REPOSITORY: "digio-nz/full",
  PRODUCTION_DOMAIN: "full.example.nz",
};
const LIVE = "dpl_live";

const project = (overrides = {}) => ({
  id: "prj_full",
  accountId: "team_shared",
  name: "full",
  autoAssignCustomDomains: false,
  link: { type: "github", org: "digio-nz", repo: "full", repoId: 42, productionBranch: "main" },
  targets: { production: { id: LIVE } },
  ...overrides,
});

const deployment = (id, overrides = {}) => ({
  id,
  projectId: "prj_full",
  target: "production",
  url: `full-${id.slice(4).toLowerCase()}.vercel.app`,
  readyState: "READY",
  readySubstate: "STAGED",
  gitSource: { type: "github", repoId: 42, ref: "main", sha: SHA },
  meta: { githubCommitSha: SHA },
  ...overrides,
});

// A world answers each read from its current state; `afterPoll` can move it between reads.
function fakeVercel(world) {
  const calls = [];
  let polls = 0;
  const state = {
    project: world.project ?? project(),
    alias: world.alias === undefined ? { deploymentId: LIVE } : world.alias,
    listed: world.listed ?? [],
    deployments: { ...(world.deployments ?? {}) },
  };
  let projectReads = 0;
  const api = async (path, { body, allowMissing } = {}) => {
    calls.push(`${body ? "POST" : "GET"} ${path}`);
    const [route] = path.split("?");
    if (route === "/v9/projects/prj_full") {
      projectReads += 1;
      if (projectReads > 1) world.beforeSecondRead?.(state);
      return structuredClone(state.project);
    }
    if (route.startsWith("/v4/aliases/")) {
      assert.equal(allowMissing, true);
      return state.alias;
    }
    if (route === "/v7/deployments") return { deployments: state.listed };
    if (route === "/v13/deployments" && body) {
      calls.push(`BODY ${JSON.stringify(body)}`);
      const created = world.create(body);
      const first = [created].flat()[0];
      state.deployments[first.id] = created;
      return { id: first.id, target: first.target, url: first.url };
    }
    const id = route.replace("/v13/deployments/", "");
    assert.match(path, /withGitRepoInfo=true/);
    const sequence = state.deployments[id];
    if (Array.isArray(sequence)) return sequence[Math.min(polls++, sequence.length - 1)];
    return sequence;
  };
  let waits = 0;
  const wait = async () => {
    waits += 1;
    if (waits > 500) throw new Error("the fake build never finished");
    world.afterPoll?.(state);
  };
  return { api, wait, calls, state };
}

const run = (world, mode = "apply", sha = SHA) => {
  const fake = fakeVercel(world);
  return {
    fake,
    result: productionBuild({ api: fake.api, env: ENV, mode, sha, wait: fake.wait }),
  };
};

const posts = (fake) => fake.calls.filter((call) => call.startsWith("POST "));

describe("production-build creates", () => {
  it("a Production build of the exact SHA when none exists, then waits for STAGED", async () => {
    const { fake, result } = run({
      create: () => [
        deployment("dpl_new", { readyState: "QUEUED" }),
        deployment("dpl_new", { readyState: "BUILDING" }),
        deployment("dpl_new"),
      ],
    });
    assert.deepEqual(await result, {
      deploymentId: "dpl_new",
      deploymentUrl: "https://full-new.vercel.app",
      reused: false,
    });
    const body = JSON.parse(fake.calls.find((call) => call.startsWith("BODY ")).slice(5));
    assert.deepEqual(body, {
      name: "full",
      project: "prj_full",
      target: "production",
      gitSource: { type: "github", repoId: 42, ref: "main", sha: SHA },
      meta: { productionBuild: "v1" },
    });
    assert.deepEqual(posts(fake), ["POST /v13/deployments?teamId=team_shared&forceNew=1"]);
  });

  it("a new build when the only earlier builds ended ERROR or CANCELED", async () => {
    const { fake, result } = run({
      listed: [
        { uid: "dpl_err", readyState: "ERROR", created: 2 },
        { uid: "dpl_can", readyState: "CANCELED", created: 1 },
      ],
      create: () => deployment("dpl_new"),
    });
    assert.equal((await result).deploymentId, "dpl_new");
    assert.equal(posts(fake).length, 1);
    assert.ok(!fake.calls.some((call) => /dpl_err|dpl_can/.test(call) && call.includes("/v13/")));
  });

  it("a new build when a listed build reads back with another SHA, project or target", async () => {
    const { fake, result } = run({
      listed: [
        { uid: "dpl_tip", readyState: "READY", created: 3 },
        { uid: "dpl_prev", readyState: "READY", created: 2 },
        { uid: "dpl_other", readyState: "READY", created: 1 },
      ],
      deployments: {
        dpl_tip: deployment("dpl_tip", { gitSource: { type: "github", repoId: 42, sha: TIP } }),
        dpl_prev: deployment("dpl_prev", { target: null }),
        dpl_other: deployment("dpl_other", { projectId: "prj_other" }),
      },
      create: () => deployment("dpl_new"),
    });
    assert.equal((await result).deploymentId, "dpl_new");
    assert.equal(posts(fake).length, 1);
  });
});

describe("production-build reuses", () => {
  it("a READY STAGED build of the SHA without a request", async () => {
    const { fake, result } = run({
      listed: [{ uid: "dpl_ready", readyState: "READY", created: 1 }],
      deployments: { dpl_ready: deployment("dpl_ready") },
    });
    assert.deepEqual(await result, {
      deploymentId: "dpl_ready",
      deploymentUrl: "https://full-ready.vercel.app",
      reused: true,
    });
    assert.deepEqual(posts(fake), []);
  });

  it("a build that reports the SHA only in gitSource", async () => {
    const { result } = run({
      listed: [{ uid: "dpl_ready", readyState: "READY", created: 1 }],
      deployments: { dpl_ready: deployment("dpl_ready", { meta: {} }) },
    });
    assert.equal((await result).deploymentId, "dpl_ready");
  });

  it("the live deployment or a rollback candidate, which are PROMOTED", async () => {
    for (const id of [LIVE, "dpl_rollback"]) {
      const { fake, result } = run({
        listed: [{ uid: id, readyState: "READY", created: 1 }],
        deployments: { [id]: deployment(id, { readySubstate: "PROMOTED" }) },
      });
      assert.equal((await result).deploymentId, id);
      assert.deepEqual(posts(fake), []);
    }
  });

  it("the newest READY build ahead of an in-progress one", async () => {
    const { result } = run({
      listed: [
        { uid: "dpl_building", readyState: "BUILDING", created: 3 },
        { uid: "dpl_old", readyState: "READY", created: 1 },
        { uid: "dpl_new", readyState: "READY", created: 2 },
      ],
      deployments: {
        dpl_building: deployment("dpl_building", { readyState: "BUILDING" }),
        dpl_old: deployment("dpl_old"),
        dpl_new: deployment("dpl_new"),
      },
    });
    assert.equal((await result).deploymentId, "dpl_new");
  });

  it("an in-progress build, and waits for it to be STAGED", async () => {
    const { fake, result } = run({
      listed: [{ uid: "dpl_building", readyState: "BUILDING", created: 1 }],
      deployments: {
        dpl_building: [
          deployment("dpl_building", { readyState: "BUILDING" }),
          deployment("dpl_building", { readyState: "BUILDING" }),
          deployment("dpl_building"),
        ],
      },
    });
    assert.deepEqual(await result, {
      deploymentId: "dpl_building",
      deploymentUrl: "https://full-building.vercel.app",
      reused: true,
    });
    assert.deepEqual(posts(fake), []);
  });
});

describe("production-build refuses", () => {
  const refuses = async (world, pattern, mode = "apply") => {
    const { fake, result } = run(world, mode);
    await assert.rejects(result, (error) => {
      assert.match(error.message, pattern);
      assert.equal(error.exitCode, 1);
      return true;
    });
    return fake;
  };

  it("before any request when autoAssignCustomDomains is not false", async () => {
    for (const value of [true, undefined]) {
      for (const mode of ["apply", "check"]) {
        const fake = await refuses(
          { project: project({ autoAssignCustomDomains: value }) },
          /autoAssignCustomDomains reads .* no deployment was requested/,
          mode,
        );
        assert.deepEqual(fake.calls, ["GET /v9/projects/prj_full?teamId=team_shared"]);
      }
    }
  });

  it("another project, team, repository or Production branch", async () => {
    for (const overrides of [
      { id: "prj_other" },
      { accountId: "team_other" },
      { link: { ...project().link, repo: "other" } },
      { link: { ...project().link, productionBranch: "release" } },
      { link: { ...project().link, type: "gitlab" } },
    ]) {
      const fake = await refuses({ project: project(overrides) }, /project|linked/);
      assert.deepEqual(posts(fake), []);
    }
  });

  it("a new build that reads back as the main tip instead of the proven SHA", async () => {
    await refuses(
      {
        create: () => [
          deployment("dpl_new", {
            readyState: "QUEUED",
            gitSource: { type: "github", repoId: 42, ref: "main", sha: TIP },
            meta: { githubCommitSha: TIP },
          }),
        ],
      },
      new RegExp(`does not read back as a Production build of ${SHA}.*${TIP}`),
    );
  });

  it("a build whose gitSource and meta disagree, or that reports no SHA", async () => {
    for (const overrides of [
      { meta: { githubCommitSha: TIP } },
      { gitSource: { type: "github", repoId: 42, sha: TIP } },
      { gitSource: { type: "github", repoId: 42 }, meta: {} },
    ])
      await refuses(
        { create: () => deployment("dpl_new", { readyState: "QUEUED", ...overrides }) },
        /does not read back/,
      );
  });

  it("a build of another repository", async () => {
    await refuses(
      {
        create: () => deployment("dpl_new", { gitSource: { type: "github", repoId: 7, sha: SHA } }),
      },
      /does not read back/,
    );
  });

  it("a build that ends ERROR or CANCELED, without a second request", async () => {
    for (const end of ["ERROR", "CANCELED"]) {
      const fake = await refuses(
        {
          create: () => [
            deployment("dpl_new", { readyState: "BUILDING" }),
            deployment("dpl_new", { readyState: end }),
          ],
        },
        new RegExp(`ended ${end}; a rerun requests a new build`),
      );
      assert.equal(posts(fake).length, 1);
    }
  });

  it("a waited build that took production traffic", async () => {
    await refuses(
      {
        listed: [{ uid: "dpl_building", readyState: "BUILDING", created: 1 }],
        deployments: {
          dpl_building: [
            deployment("dpl_building", { readyState: "BUILDING" }),
            deployment("dpl_building", { readySubstate: "PROMOTED" }),
          ],
        },
      },
      /readySubstate 'PROMOTED', not STAGED/,
    );
  });

  it("a READY build in a rolling release", async () => {
    await refuses(
      {
        listed: [{ uid: "dpl_roll", readyState: "READY", created: 1 }],
        deployments: { dpl_roll: deployment("dpl_roll", { readySubstate: "ROLLING" }) },
      },
      /rolling release/,
    );
  });

  it("when the Production target or the domain moves during the build", async () => {
    for (const move of [
      (state) => (state.project = project({ targets: { production: { id: "dpl_new" } } })),
      (state) => (state.alias = { deploymentId: "dpl_new" }),
      (state) => (state.project = project({ autoAssignCustomDomains: true })),
    ])
      await refuses(
        {
          create: () => [deployment("dpl_new", { readyState: "BUILDING" }), deployment("dpl_new")],
          afterPoll: move,
        },
        /Production moved during the build|autoAssignCustomDomains reads/,
      );
  });

  it("when the Production target moves while reusing a READY build", async () => {
    await refuses(
      {
        listed: [{ uid: "dpl_ready", readyState: "READY", created: 1 }],
        deployments: { dpl_ready: deployment("dpl_ready") },
        beforeSecondRead: (state) =>
          (state.project = project({ targets: { production: { id: "dpl_ready" } } })),
      },
      /Production moved during the build: target dpl_live -> dpl_ready/,
    );
  });

  it("a build still not READY after 30 minutes", async (t) => {
    t.mock.timers.enable({ apis: ["Date"] });
    const { result } = run({
      create: () => deployment("dpl_new", { readyState: "BUILDING" }),
      afterPoll: () => t.mock.timers.tick(10 * 60 * 1000),
    });
    await assert.rejects(result, /not READY within 30 minutes/);
  });
});

describe("production-build check", () => {
  it("reports a reusable build and makes no request", async () => {
    const { fake, result } = run(
      {
        listed: [{ uid: "dpl_ready", readyState: "READY", created: 1 }],
        deployments: { dpl_ready: deployment("dpl_ready") },
      },
      "check",
    );
    assert.deepEqual(await result, {
      mode: "check",
      sha: SHA,
      reusable: { id: "dpl_ready", state: "READY" },
      productionTarget: LIVE,
    });
    assert.deepEqual(posts(fake), []);
  });
});

describe("production-build usage and transport", () => {
  it("accepts only apply or check with a full lowercase SHA, or test", () => {
    assert.deepEqual(parseArgs(["apply", SHA]), { mode: "apply", sha: SHA });
    assert.deepEqual(parseArgs(["test"]), { mode: "test", sha: undefined });
    for (const argv of [
      [],
      ["apply"],
      ["apply", "abc"],
      ["apply", SHA.toUpperCase()],
      ["promote", SHA],
      ["apply", SHA, "x"],
    ])
      assert.throws(
        () => parseArgs(argv),
        (error) => error.exitCode === 2,
      );
  });

  it("refuses a missing identifier before any request", async () => {
    for (const key of Object.keys(ENV)) {
      const fake = fakeVercel({});
      await assert.rejects(
        productionBuild({ api: fake.api, env: { ...ENV, [key]: "" }, mode: "apply", sha: SHA }),
        (error) => error.exitCode === 2,
      );
      assert.deepEqual(fake.calls, []);
    }
  });

  it("sends the token in a header, withholds responses and maps a 404 alias to absent", async () => {
    const seen = [];
    const fetchImpl = async (url, init) => {
      seen.push({ url, auth: init.headers.Authorization });
      if (url.includes("/v4/aliases/")) return new Response("{}", { status: 404 });
      return new Response('{"secret":"withheld"}', { status: 500 });
    };
    const api = apiClient("fixture-token", fetchImpl);
    assert.equal(
      await api("/v4/aliases/full.example.nz?teamId=team_shared", { allowMissing: true }),
      null,
    );
    await assert.rejects(api("/v9/projects/prj_full?teamId=team_shared"), (error) => {
      assert.equal(error.exitCode, 3);
      assert.doesNotMatch(error.message, /withheld"|secret|fixture-token/);
      return true;
    });
    assert.ok(
      seen.every(
        ({ url, auth }) => auth === "Bearer fixture-token" && !url.includes("fixture-token"),
      ),
    );
  });

  it("exits 2 on usage from the command line", () => {
    const result = spawnSync(process.execPath, [join(HERE, "production-build.mjs"), "promote"], {
      encoding: "utf8",
      env: { PATH: process.env.PATH },
    });
    assert.equal(result.status, 2);
    assert.match(result.stderr, /Usage: production-build\.mjs/);
  });
});
