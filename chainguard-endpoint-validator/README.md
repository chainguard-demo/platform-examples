# Check Chainguard Endpoint Reachability

Two scripts that check whether a machine can actually reach every endpoint Chainguard tooling needs. They cover the same endpoints as `chainctl config validate`, but open a real HTTPS connection to each one instead of stopping at DNS, and they don't need chainctl installed.

| File | Runs on |
|---|---|
| `cgr-endpoint-checker.sh` | macOS (bash 3.2+), Linux, WSL, Git Bash. Needs `curl`. |
| `cgr-endpoint-checker.ps1` | Windows PowerShell 5.1 and PowerShell 7+ (Windows, macOS, Linux). |

## Usage

```bash
./cgr-endpoint-checker.sh              # table (default)
./cgr-endpoint-checker.sh -o wide      # table plus a TEST column (what was checked, what came back)
./cgr-endpoint-checker.sh -o json      # JSON
./cgr-endpoint-checker.sh -v           # also print the raw error for each failure (stderr)
```

```powershell
.\cgr-endpoint-checker.ps1
.\cgr-endpoint-checker.ps1 -o wide
.\cgr-endpoint-checker.ps1 -o json
.\cgr-endpoint-checker.ps1 -Verbose
.\cgr-endpoint-checker.ps1 -Help
# If execution policy blocks it:
powershell -ExecutionPolicy Bypass -File .\cgr-endpoint-checker.ps1
```

The only options are `-o`/`--output` (`table`, `wide` or `json`), `--timeout` (seconds per request, 10 by default), `-v`/`--verbose` and `-h`/`--help`. In PowerShell they are `-o`, `-Timeout`, `-Verbose` and `-Help`.

## What each row checks

| Endpoint | `chainctl config validate` test | `cgr-endpoint-checker` test | `cgr-endpoint-checker` passes when |
|---|---|---|---|
| `platform.{api,console,issuer,registry}` | DNS lookup | HTTPS GET of the URL | The server sent back any HTTP response. |
| `domains.*` (8 required third-party domains) | DNS lookup | HTTPS GET `https://<domain>/` | The server sent back any HTTP response. |
| `protocol.grpc.platform.{api,issuer}` | gRPC `PingService/Ping` | gRPC `PingService/Ping` over HTTP/2 | An HTTP/2 response came back with `grpc-status: 0`. |
| `protocol.http.platform.{api,issuer}` | HTTP GET `/ping/v1/ping` | HTTP GET `/ping/v1/ping` | 2xx **and** the body is the ping JSON. |
| `issuer/.well-known/openid-configuration`, `issuer/keys` | HTTP GET | HTTP GET | 2xx **and** the body is the expected OIDC JSON. |

Results:

- ✅ means it's reachable.
- ❗ means the request got an answer, but the status was **403, 407, 451 or 511**. Proxies and firewalls typically use these for block pages, so it may not be the real server.
- ❌ means it's not reachable, and the cell gives the reason (DNS failure, connection refused, timeout, proxy block, connection reset, untrusted TLS cert, or a 200 that isn't the expected body).

Example (`-o wide`). The TEST column shows what was checked and what came back. **The certificate issuer is the quickest way to spot TLS inspection:** if unrelated sites (GitHub, Google, Cloudflare) all show the same issuer, such as a Zscaler or corporate CA, a proxy is decrypting the traffic.

```
                  NAME                   |                           VALUE                           |    RESULT    |                                        TEST
-----------------------------------------|-----------------------------------------------------------|--------------|-------------------------------------------------------------------------------------
                  domains.github-content |                                 raw.githubusercontent.com |           ✅ |                                            HTTPS GET / (HTTP 301, cert issuer: YR1)
                    domains.package-repo |                                        packages.wolfi.dev |           ✅ |                                            HTTPS GET / (HTTP 200, cert issuer: WR3)
 issuer/.well-known/openid-configuration |                                https://issuer.enforce.dev |  endpoint OK |             HTTP GET /.well-known/openid-configuration (HTTP 200, cert issuer: WR3)
                            platform.api |                           https://console-api.enforce.dev |           ✅ |                                            HTTPS GET / (HTTP 404, cert issuer: WR3)
                       platform.registry |                                           https://cgr.dev |           ✅ |                                            HTTPS GET / (HTTP 307, cert issuer: WR3)
              protocol.grpc.platform.api |                           https://console-api.enforce.dev | gRPC enabled |                                                  gRPC Ping (HTTP/2) (grpc-status 0)
              protocol.http.platform.api |                           https://console-api.enforce.dev |  endpoint OK |                                 HTTP GET /ping/v1/ping (HTTP 200, cert issuer: WR3)
```

JSON entries have `Value`, `Result` (`pass` / `warn` / `fail`), `Detail` and `Test`.

## Where the platform URLs come from

Same as `chainctl config validate` run with no flags: **`CHAINGUARD_PLATFORM_*` env vars > config file > production defaults**. The config file is the one set in `CHAINCTL_CONFIG`, otherwise the first found in this order: `./chainctl/config.yaml`, `<user config dir>/chainctl/config.yaml`, `~/.chainguard/config.yaml`. An invalid URL falls back to the default and prints a `Configuration error:` warning.

The exit code is `0` when the checks ran, even if some failed. A non-zero exit means the script itself couldn't run.

## Limitations

- **Domains that answer with a normal-looking page:** a TLS-inspecting proxy that returns its block page with HTTP 200 can't be told apart from the real site on the `domains.*` and `platform.*` rows. The API and issuer rows check the response body, so they do catch this. On the other rows, look at the cert issuer in `-o wide`.
- **`googlecode.l.googleusercontent.com`:** this is a CNAME target, and a browser on an open network couldn't load it over HTTPS. The script treats a TLS rejection from the real server as reachable. Check how it's classified on a network you know is unrestricted.
- **Windows PowerShell 5.1 can't do HTTP/2.** It falls back to `curl.exe` if that build supports HTTP/2. Otherwise the gRPC rows say `gRPC check unavailable` and a warning is printed. Use `pwsh` (PowerShell 7+) for the full check.
- The scripts don't print chainctl's warning about unknown keys in the config file.
