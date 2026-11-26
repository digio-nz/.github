// The init page of the MCP server: adds Vercel's protection bypass header to each request for a host of
// TEST_BROWSER_BYPASS_HOSTS, and to no other request. test-browser-start.sh checks the two variables.
const contexts = new WeakSet<object>();

export default async ({ page }) => {
  const secret = process.env.TEST_BROWSER_BYPASS_SECRET ?? '';
  const patterns = (process.env.TEST_BROWSER_BYPASS_HOSTS ?? '').split(',').map((host) => host.trim().toLowerCase()).filter(Boolean);
  if (!secret || patterns.length === 0) throw new Error('test-browser-bypass: TEST_BROWSER_BYPASS_SECRET or TEST_BROWSER_BYPASS_HOSTS is empty');
  const context = page.context();
  if (contexts.has(context)) return;
  contexts.add(context);
  const hosts = patterns.map((pattern) => new RegExp(`^${pattern.replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '[a-z0-9-]*')}$`));
  await context.route(
    (url: URL) => url.protocol === 'https:' && hosts.some((host) => host.test(url.hostname)),
    (route) => route.continue({ headers: { ...route.request().headers(), 'x-vercel-protection-bypass': secret } }),
  );
};
