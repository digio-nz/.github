// Refuse a Preview migration unless every database URL names the endpoint the provisioner recorded.
// Products keep a byte-identical copy at scripts/preview/database-guard.mjs, beside their configuration.
// Owner: digio-nz/.github/.github/actions/preview-provision. The provisioner refuses a differing copy.
import { readFileSync, realpathSync } from "node:fs";
import { pathToFileURL } from "node:url";

export const MARKER = "PREVIEW_DATABASE_HOST";

export function assertDatabaseUrl(value, expectedHost, neon, label) {
  let url;
  try {
    url = new URL(value ?? "");
  } catch {
    throw new Error(`${label} is missing or invalid`);
  }
  const params = [...url.searchParams.keys()];
  if (
    new Set(params).size !== params.length ||
    params.some((name) => !["sslmode", "channel_binding"].includes(name)) ||
    url.hash ||
    url.protocol !== "postgresql:" ||
    url.hostname !== expectedHost ||
    url.port ||
    url.username !== neon.role ||
    !url.password ||
    url.pathname !== `/${neon.database}` ||
    !["require", "verify-full"].includes(url.searchParams.get("sslmode") ?? "")
  ) {
    throw new Error(`${label} does not match the provisioned Preview endpoint`);
  }
}

export function assertPreviewDatabase(env, config) {
  if (env.VERCEL_ENV !== "preview") {
    throw new Error("Preview database guard requires VERCEL_ENV=preview");
  }
  const { neon, variables } = config;
  const host = env[MARKER] ?? "";
  const endpoint = host.endsWith(neon.hostSuffix) ? host.slice(0, -neon.hostSuffix.length) : "";
  if (!/^ep-[a-z0-9-]+$/.test(endpoint) || endpoint === neon.root.endpoint) {
    throw new Error(`${MARKER} must name a provisioned child in the Preview project`);
  }
  for (const key of variables.pooled) {
    assertDatabaseUrl(env[key], `${endpoint}-pooler${neon.hostSuffix}`, neon, key);
  }
  for (const key of variables.direct) {
    assertDatabaseUrl(env[key], host, neon, key);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  try {
    const config = JSON.parse(readFileSync(new URL("./provision.json", import.meta.url), "utf8"));
    assertPreviewDatabase(process.env, config);
    console.log("[preview-database] provisioned endpoint verified");
  } catch (error) {
    console.error(
      `[preview-database] ${error instanceof Error ? error.message : "Invalid target"}`,
    );
    process.exitCode = 1;
  }
}
