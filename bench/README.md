# Test bench

The test bench is one container with one browser.
An agent drives the browser through a [Playwright MCP](https://github.com/microsoft/playwright-mcp) server, and a person watches the same browser in a [noVNC](https://novnc.com) viewer.
The container holds no repo, no agent, no model credential and no token.

The agent runs outside the bench, and its host gives it the tools of the bench's MCP server and no other tool.
That tool list and the container are the two limits of a test agent.

## The parts

| Part | Port | Job |
| --- | --- | --- |
| The display | none | A virtual screen that holds the browser window. Only the viewer reaches it |
| The viewer | 6080 | Shows the screen at `/vnc.html?autoconnect=1&resize=scale`. Add `&view_only=1` for a link that cannot click or type |
| The MCP server | 8931 | Gives an agent the browser tools at `/mcp`. Each client shares one browser and one profile |
| The data folder | none | `/home/bench/bench` holds `profile/`, the browser profile with its logins, and `output/`, the screenshots and traces |

## Run it

```sh
docker build -t bench bench/
docker run -d --name bench -p 127.0.0.1:6080:6080 -p 127.0.0.1:8931:8931 -v bench-data:/home/bench/bench bench
bash bench/scripts/bench-selftest.sh
```

`bench-start.sh` starts each part and stops the container, with the name of the part, when one part stops.
`bench-selftest.sh` checks a running bench: the viewer answers, the MCP server opens a session, and the browser opens a page.

## Settings

| Variable | Default | Sets |
| --- | --- | --- |
| `BENCH_GEOMETRY` | `1440x900` | The size of the screen and of the page |
| `BENCH_MCP_ALLOWED_HOSTS` | loopback only | The host names that a client can use for the MCP server, such as the container's name on a Docker network |
| `BENCH_ALLOWED_ORIGINS` | each origin | The origins that the browser can request. Playwright MCP states that this list is not a security boundary |
| `BENCH_SECRETS_FILE` | none | A dotenv file of login values. The agent types a value by its name and does not see it |
| `BENCH_NO_SANDBOX` | `1` in the image | Turns off Chromium's own sandbox, which Docker's default seccomp profile refuses |

## Limits

- The viewer and the MCP server have no password. Publish their ports on the loopback address or on a private Docker network only, and give a person the viewer through the tailnet.
- A client of the MCP server can run Playwright code inside the container. Give the bench no mount and no variable that holds a secret of another system.
- Put only a Preview login with fake data in the profile. A login that can change a real system gives the agent that system.
