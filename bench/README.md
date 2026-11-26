# Test bench

The test bench is two containers on one private network. [`compose.yaml`](compose.yaml) defines them.

| Container | Holds | Reaches |
| --- | --- | --- |
| `test-browser` | One browser, a viewer for a person and a [Playwright MCP](https://github.com/microsoft/playwright-mcp) server. No repo, no agent and no credential | The internet |
| `test-agent` | Claude Code, the skills of one preset, the agent brief and one model credential. No repo and no credential of another system | `test-browser` and the internet |

`test-agent` drives the browser through the MCP server, and a person watches the same browser in the [noVNC](https://novnc.com) viewer.
A page that the browser opens does not share a container with the model credential.

The two names do not change. A machine can also run a browser that agents share for other work, and that browser is not part of the bench.

## test-browser

[`Dockerfile`](Dockerfile) builds its image.

| Part | Port | Job |
| --- | --- | --- |
| The display | none | A virtual screen that holds the browser window. Only the viewer reaches it |
| The viewer | 6080 | Shows the screen at `/vnc.html?autoconnect=1&resize=scale`. Add `&view_only=1` for a link that cannot click or type |
| The MCP server | 8931 | Gives an agent the browser tools at `/mcp`. Each client shares one browser and one profile |
| The data folder | none | `/home/browser/data` holds `profile/`, the browser profile with its logins, and `output/`, the screenshots and traces |

`test-browser-start.sh` starts each part and stops the container, with the name of the part, when one part stops.

| Variable | Default | Sets |
| --- | --- | --- |
| `TEST_BROWSER_GEOMETRY` | `1440x900` | The size of the screen and of the page |
| `TEST_BROWSER_MCP_ALLOWED_HOSTS` | loopback only; `test-browser:8931` in the compose file | The `Host` values, each a name with its port, that a client can use for the MCP server |
| `TEST_BROWSER_ALLOWED_ORIGINS` | each origin | The origins that the browser can request. Playwright MCP states that this list is not a security boundary |
| `TEST_BROWSER_SECRETS_FILE` | none | A dotenv file of login values. The agent types a value by its name and does not see it |
| `TEST_BROWSER_BYPASS_SECRET` and `TEST_BROWSER_BYPASS_HOSTS` | none | A [Protection Bypass for Automation](https://vercel.com/docs/deployment-protection/methods-to-bypass-deployment-protection/protection-bypass-automation) secret of one Vercel project, and the hosts that get it, with commas between them. A host can have `*` in its first label, after a name, such as `product-*-team.vercel.app`. The browser adds the secret to each request for those hosts and to no other request |
| `TEST_BROWSER_NO_SANDBOX` | `1` in the image | Turns off Chromium's own sandbox, which Docker's default seccomp profile refuses |

## test-agent

`test-agent` runs the [workbench image](../image/README.md) with a different command, so it has the tools of a workbench and none of its logins.
The compose file mounts four things into it, each read-only:

| Mount | Job |
| --- | --- |
| `scripts/test-agent-start.sh` | The command of the container |
| `test-agent/managed-settings.json` | The tools that Claude Code permits: the browser tools, `Read`, `Glob`, `Grep`, `Skill` and the scripts of the linked skills. It replaces the managed settings of the image, and a setting inside the container cannot widen it |
| `test-agent/managed-mcp.json` | The one MCP server, that of `test-browser`. Claude Code accepts no other server |
| A digio-skills checkout and a digio-michelin checkout | The skills and the agent brief. The host keeps the two checkouts current, so the container needs no GitHub token |

`test-agent-start.sh` links the skills of the preset for Claude Code, writes the agent brief, checks that the MCP server answers, and then waits.
It stops the container with a `FAIL: test-agent:` line when the preset or the model credential is missing.
It does the same when its environment holds a credential of another system, or when a step fails.

## Run it

The compose file reads these variables from the environment or from a `.env` file beside it. Keep a `.env` file out of git.

| Variable | Default | Sets |
| --- | --- | --- |
| `DIGIO_SKILLS_ROOT` | required | The path of the digio-skills checkout on the host |
| `DIGIO_MICHELIN_ROOT` | required | The path of the digio-michelin checkout on the host |
| `TEST_AGENT_PRESET` | `test` | The skills preset of the test agent, a preset of digio-skills |
| `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` | the start needs one | The model credential |
| `TEST_AGENT_IMAGE` | `ghcr.io/digio-nz/workbench:latest` | The image of `test-agent` |
| `TEST_BROWSER_VIEW_PORT` | `6080` | The port of the viewer on the loopback address of the host |
| `TEST_BROWSER_BYPASS_SECRET` and `TEST_BROWSER_BYPASS_HOSTS` | none | The bypass secret and its hosts, for a Preview behind Vercel Authentication |

```sh
cd bench
docker compose up -d
docker compose exec test-agent claude -p "Use the browser-test skill. Test fcdispatch at <address of the Preview>."
```

Run `test-browser` alone, with its MCP port on the host:

```sh
docker build -t test-browser bench/
docker run -d --name test-browser -p 127.0.0.1:6080:6080 -p 127.0.0.1:8931:8931 test-browser
bash bench/scripts/test-browser-selftest.sh
```

## A long run

`test-agent-run.sh` runs full browser tests on the host of the bench for some hours, one person and one round at a time:

```sh
bash bench/scripts/test-agent-run.sh <product> <address> <hours> [<feature to skip>]
```

Each run is one Claude Code session in `test-agent`, so a long test does not fill one context.
The round sets the focus of the run; the method of the `browser-test` skill gives each focus.
The runner keeps these records in `~/test-bench/results/<product>-<UTC time>`, or in the folder that `RESULTS` names:

| File | Holds |
| --- | --- |
| `index.md` | A row for each run: the round, the person, the start, the exit code and the first line of the report |
| `r<round>-<person>.md` | The report of the run |
| `r<round>-<person>.jsonl` | The transcript of the session: each tool call and each page that the agent read |
| `browser-output/` | The screenshots and the session logs of the MCP server, copied from `test-browser` at the end |

A run that fails, such as at a usage limit of the model, gets a `FAIL:` line, and the next run waits 5 minutes.
Three failed runs in a row stop the runner. It exits 1 when a run failed.
`ROUNDS` stops it after that many rounds.

`test-agent-run-selftest.sh` checks the runner offline, with a stub of `docker`.
`test-browser-selftest.sh` checks a running `test-browser`: the viewer answers, the MCP server opens a session, and the browser opens a page.
`test-agent-start-selftest.sh` checks each refusal of `test-agent-start.sh` offline.

## Limits

- The viewer and the MCP server have no password. The compose file publishes the viewer on the loopback address and keeps the MCP port on the network of the bench. Give a person the viewer through the tailnet.
- A client of the MCP server can run Playwright code inside `test-browser`, so it can read each variable of that container. The settings of `test-agent` deny that tool, and the container is the limit. Give `test-browser` no mount and no variable that holds a secret of another system. The bypass secret is the one exception: it opens only the Previews of one project, which hold fake data.
- Put only a Preview login with fake data in the profile. A login that can change a real system gives the agent that system.
- `test-agent` reaches the internet, because the model API is there. Its limits are the tool list and the content of its container, not its network.
- The settings of `test-agent` deny file writes, web tools and subagents. Claude Code still runs a shell command that only reads, such as `ls`. The container holds nothing for such a command to find but the skills, the brief and the model credential.
