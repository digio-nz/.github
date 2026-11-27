// The init page of the MCP server: adds Vercel's protection bypass header to each request for a host of a rule of
// TEST_BROWSER_BYPASS, with the secret of that rule, and to no other request. test-browser-start.sh checks the rules.
const contexts = new WeakSet<object>();

export default async ({ page }) => {
  const rules = (process.env.TEST_BROWSER_BYPASS ?? '').split(/[\s,]+/).filter(Boolean).map((rule) => {
    const at = rule.indexOf('=');
    const pattern = rule.slice(0, at).toLowerCase();
    const secret = rule.slice(at + 1);
    if (at < 1 || !secret) throw new Error('test-browser-bypass: a rule of TEST_BROWSER_BYPASS is not <host pattern>=<secret>');
    return { host: new RegExp(`^${pattern.replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '[a-z0-9-]*')}$`), secret };
  });
  if (rules.length === 0) throw new Error('test-browser-bypass: TEST_BROWSER_BYPASS is empty');
  const context = page.context();
  if (contexts.has(context)) return;
  contexts.add(context);
  const ruleOf = (url: URL) => (url.protocol === 'https:' ? rules.find((rule) => rule.host.test(url.hostname)) : undefined);
  await context.route(
    (url: URL) => ruleOf(url) !== undefined,
    (route) => route.continue({ headers: { ...route.request().headers(), 'x-vercel-protection-bypass': ruleOf(new URL(route.request().url()))!.secret } }),
  );
};
