<#
.SYNOPSIS
    Check that this machine can reach the endpoints Chainguard tooling needs
    (a standalone take on 'chainctl config validate').

.DESCRIPTION
    A standalone take on `chainctl config validate` for machines where
    chainctl is not (or cannot be) installed. It checks that this machine can
    actually reach every endpoint Chainguard tooling needs, and prints the
    results in chainctl's table / JSON layout.

    Unlike chainctl, which only does a DNS lookup for most hosts, every check
    here makes a real HTTPS request through the same proxy settings other
    tools use. A row only passes when a response came back from the far end.

    Checks performed:
      1. platform.api, platform.console, platform.issuer, platform.registry:
         HTTPS GET of the URL (taken from CHAINGUARD_PLATFORM_* env vars >
         chainctl config file > built-in defaults, as `chainctl config
         validate` does when run with no flags).
      2. domains.*: HTTPS GET https://<domain>/ for each required third-party
         domain.
         For 1 and 2 any response from the server passes, except
         403/407/451/511, which are flagged as a possible proxy block page.
      3. issuer and api:
           - gRPC : chainguard.platform.ping.PingService/Ping over HTTP/2
           - HTTP : GET <url>/ping/v1/ping
           - HTTP : GET <issuer>/.well-known/openid-configuration and <issuer>/keys
           These must return 2xx AND the expected JSON, so a proxy's block
           page or login page can't pass for the real service.

    Failures say why: DNS, connection refused, timeout, blocked by a proxy,
    connection reset (firewall), untrusted TLS certificate (TLS-inspecting
    proxy), and so on.

    Works on Windows PowerShell 5.1 and PowerShell 7+ (Windows, macOS, Linux).
    The gRPC check needs HTTP/2: PowerShell 7+ does this natively; on Windows
    PowerShell 5.1 the script uses curl.exe if it supports HTTP/2.

    The exit code is 0 when the diagnostics ran (even if some checks failed),
    matching chainctl. A non-zero exit means the script itself could not run.

.PARAMETER Output
    Output format. One of: json, table, wide (default table). Alias: -o
    wide adds a TEST column describing the check behind each row.

.PARAMETER Timeout
    Per-request timeout in seconds (default 10).

.PARAMETER Help
    Show this help.

.EXAMPLE
    .\cgr-endpoint-checker.ps1

.EXAMPLE
    .\cgr-endpoint-checker.ps1 -o json

.EXAMPLE
    .\cgr-endpoint-checker.ps1 -o wide

.EXAMPLE
    .\cgr-endpoint-checker.ps1 -Verbose

    -Verbose logs the raw error for each failed check.
#>
[CmdletBinding()]
param(
    [Alias('o')]
    [string]$Output = '',
    [ValidateRange(1, 3600)]
    [int]$Timeout = 10,
    [Alias('h')]
    [switch]$Help
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Endpoints (chainctl/pkg/config/defaults.go, production build values)
# ---------------------------------------------------------------------------
$Defaults = [ordered]@{
    api      = 'https://console-api.enforce.dev'
    console  = 'https://console.chainguard.dev'
    issuer   = 'https://issuer.enforce.dev'
    registry = 'https://cgr.dev'
}

# Required domains, in the order chainctl checks them.
$RequiredDomains = [ordered]@{
    'package-repo'        = 'packages.wolfi.dev'
    'wolfi'               = 'ghcr.io'
    'storage'             = '9236a389bd48b984df91adc1bc924620.r2.cloudflarestorage.com'
    'support'             = 'chainguardhelp.zendesk.com'
    'auth0'               = 'chainguard-cd-nvt30yluzzsmvk7t.edge.tenants.us.auth0.com'
    'google-user-content' = 'googlecode.l.googleusercontent.com'
    'github-content'      = 'raw.githubusercontent.com'
    'google-storage'      = 'storage.googleapis.com'
}

$GrpcPingPath = '/chainguard.platform.ping.PingService/Ping'
$HttpPingPath = '/ping/v1/ping'

$MsgGrpcOk = 'gRPC enabled'
$MsgGrpcHttp1 = 'gRPC not enabled. Please use --sts-http1-downgrade=true and --validate=false when logging in'
$MsgGrpcUntested = 'gRPC check unavailable (requires PowerShell 7+ or curl.exe with HTTP/2)'
$MsgEndpointOk = 'endpoint OK'

# HTTP statuses that proxies and firewalls typically use for block pages.
$BlockStatuses = @(403, 407, 451, 511)

# Emoji built from code points so the script file stays ASCII-safe (PS 5.1
# misreads UTF-8 scripts without a BOM).
$CheckMark = [char]0x2705
$CrossMark = [char]0x274C
$WarnMark = [char]0x2757

function Fail([string]$Message) {
    [Console]::Error.WriteLine("Error: $Message")
    exit 1
}

if ($Help) {
    Get-Help -Detailed $PSCommandPath | Out-String -Width 120 | Write-Host
    exit 0
}

if ($Output -notin @('', 'table', 'json', 'wide')) {
    Fail "format option `"$Output`" is not implemented"
}

$IsWindowsHost = ($PSVersionTable.PSEdition -eq 'Desktop') -or ((Test-Path variable:IsWindows) -and $IsWindows)
$IsMacHost = (Test-Path variable:IsMacOS) -and $IsMacOS
$PSMajor = $PSVersionTable.PSVersion.Major

# ---------------------------------------------------------------------------
# Config file discovery (chainctl/pkg/config/config.go: initialize)
# ---------------------------------------------------------------------------
$HomeDir = [Environment]::GetFolderPath('UserProfile')
if ([string]::IsNullOrEmpty($HomeDir)) { $HomeDir = $HOME }

function Get-UserConfigDir {
    if ($IsWindowsHost) { return $env:APPDATA }
    if ($IsMacHost) { return (Join-Path $HomeDir 'Library/Application Support') }
    if (-not [string]::IsNullOrEmpty($env:XDG_CONFIG_HOME)) { return $env:XDG_CONFIG_HOME }
    return (Join-Path $HomeDir '.config')
}

$ConfigFile = $null
$explicitConfig = if ($env:CHAINCTL_CONFIG) { $env:CHAINCTL_CONFIG } else { '' }
if ($explicitConfig) {
    if ($explicitConfig.StartsWith('~')) { $explicitConfig = $HomeDir + $explicitConfig.Substring(1) }
    if (-not (Test-Path -LiteralPath $explicitConfig)) { Fail "failed to access config file `"$explicitConfig`"" }
    if (Test-Path -LiteralPath $explicitConfig -PathType Container) { Fail "`"$explicitConfig`" is a directory, not a configuration file." }
    $ConfigFile = $explicitConfig
}
else {
    $candidates = @(
        (Join-Path (Join-Path (Get-Location).Path 'chainctl') 'config.yaml'),
        (Join-Path (Join-Path (Get-UserConfigDir) 'chainctl') 'config.yaml'),
        (Join-Path (Join-Path $HomeDir '.chainguard') 'config.yaml')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Leaf) { $ConfigFile = $c; break }
    }
}
if ($ConfigFile) { Write-Verbose "using config file $ConfigFile" }

# Minimal YAML reader for the scalar keys under the top-level `platform:` map.
$FilePlatform = @{}
if ($ConfigFile) {
    $inPlatform = $false
    foreach ($rawLine in (Get-Content -LiteralPath $ConfigFile)) {
        $line = $rawLine.TrimEnd("`r")
        if ($line -match '^[^\s#]') {
            $inPlatform = $line -match '^platform:\s*(#.*)?$'
            continue
        }
        if ($inPlatform -and $line -match '^\s+([A-Za-z0-9_-]+):(.*)$') {
            $k = $Matches[1]
            $v = $Matches[2].Trim()
            if ($v.StartsWith('"')) {
                $v = $v.Substring(1); $i = $v.IndexOf('"'); if ($i -ge 0) { $v = $v.Substring(0, $i) }
            }
            elseif ($v.StartsWith("'")) {
                $v = $v.Substring(1); $i = $v.IndexOf("'"); if ($i -ge 0) { $v = $v.Substring(0, $i) }
            }
            else {
                $v = ($v -replace '\s+#.*$', '').Trim()
            }
            if (-not $FilePlatform.ContainsKey($k)) { $FilePlatform[$k] = $v }
        }
    }
}

# chainctl util.IsValidURL: needs a scheme and a host.
function Test-ValidUrl([string]$u) {
    return $u -match '^[A-Za-z][A-Za-z0-9+.-]*://[^/?#\s]+([/?#]\S*)?$'
}

$ConfigWarnings = New-Object System.Collections.Generic.List[string]
$Platform = @{}
foreach ($key in $Defaults.Keys) {
    $envVal = [Environment]::GetEnvironmentVariable("CHAINGUARD_PLATFORM_$($key.ToUpperInvariant())")
    if ($envVal) { $val = $envVal }
    elseif ($FilePlatform.ContainsKey($key)) { $val = $FilePlatform[$key] }
    else { $val = $Defaults[$key] }
    if (-not (Test-ValidUrl $val)) {
        $ConfigWarnings.Add("`"$val`" is not a valid URL for platform.$key. Using the default `"$($Defaults[$key])`".")
        $val = $Defaults[$key]
    }
    $Platform[$key] = $val
}
if ($ConfigWarnings.Count -eq 1) {
    [Console]::Error.WriteLine("Configuration error: $($ConfigWarnings[0])`n")
}
elseif ($ConfigWarnings.Count -gt 1) {
    [Console]::Error.WriteLine("Configuration errors:`n$($ConfigWarnings -join "`n")`n")
}

# ---------------------------------------------------------------------------
# HTTP client setup
# ---------------------------------------------------------------------------
if ($PSMajor -lt 6) {
    Add-Type -AssemblyName System.Net.Http
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch { }
}
else {
    # Allow HTTP/2 without TLS (h2c) for http:// endpoints on .NET Core 3.x.
    [AppContext]::SetSwitch('System.Net.Http.SocketsHttpHandler.Http2UnencryptedSupport', $true)
}

# A small compiled helper records, per host, who issued the server's TLS
# certificate and what (if anything) was wrong with it. A PowerShell script
# block can't be used for this callback (it runs on a thread with no
# runspace). If it can't be compiled, the script still works, just without
# certificate details.
$TlsHelperSource = @'
using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;

public static class CgValidateTls
{
    private static readonly object Gate = new object();
    private static readonly Dictionary<string, string> Issuers = new Dictionary<string, string>();
    private static readonly Dictionary<string, SslPolicyErrors> Errors = new Dictionary<string, SslPolicyErrors>();

    public static bool Validate(HttpRequestMessage request, X509Certificate2 cert, X509Chain chain, SslPolicyErrors errors)
    {
        string host = request.RequestUri.Host.ToLowerInvariant();
        lock (Gate)
        {
            if (cert != null) { Issuers[host] = cert.GetNameInfo(X509NameType.SimpleName, true); }
            Errors[host] = errors;
        }
        return errors == SslPolicyErrors.None;
    }

    public static void Attach(HttpClientHandler handler)
    {
        handler.ServerCertificateCustomValidationCallback = Validate;
    }

    public static string GetIssuer(string host)
    {
        lock (Gate) { string v; return Issuers.TryGetValue(host.ToLowerInvariant(), out v) ? v : null; }
    }

    public static string GetErrors(string host)
    {
        lock (Gate) { SslPolicyErrors v; return Errors.TryGetValue(host.ToLowerInvariant(), out v) ? v.ToString() : null; }
    }
}
'@
$TlsHelper = $false
try {
    if (-not ('CgValidateTls' -as [type])) {
        if ($PSMajor -lt 6) {
            Add-Type -TypeDefinition $TlsHelperSource -ReferencedAssemblies 'System.Net.Http' -ErrorAction Stop
        }
        else {
            Add-Type -TypeDefinition $TlsHelperSource -ErrorAction Stop
        }
    }
    $TlsHelper = $true
}
catch {
    Write-Verbose "certificate details unavailable: $($_.Exception.Message)"
}

function New-HttpClient([bool]$FollowRedirects) {
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $FollowRedirects
    if ($FollowRedirects) { $handler.MaxAutomaticRedirections = 10 }
    if ($TlsHelper) {
        try { [CgValidateTls]::Attach($handler) } catch { $script:TlsHelper = $false }
    }
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($Timeout)
    return $client
}
$ReachClient = New-HttpClient $false  # reachability: any response counts
$HttpClient = New-HttpClient $true    # endpoint checks: follow redirects

function Get-HostPort([string]$url) {
    $u = [Uri]$url
    return "$($u.Host):$($u.Port)"
}

function Get-IssuerNote([string]$url) {
    if (-not $TlsHelper) { return '' }
    $issuer = [CgValidateTls]::GetIssuer(([Uri]$url).Host)
    if ($issuer) { return ", cert issuer: $issuer" }
    return ''
}

# Turns a failed request into a human reason. Returns @{ Reason; Reached },
# where Reached means the far-end server did answer but rejected TLS for this
# hostname (it is reachable, just not by that name).
function Get-FailureInfo($ErrorRecord, [string]$url) {
    $hostPort = Get-HostPort $url
    $hostName = ([Uri]$url).Host

    $chain = New-Object System.Collections.Generic.List[object]
    $e = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
    while ($null -ne $e) { $chain.Add($e); $e = $e.InnerException }
    $allText = ($chain | ForEach-Object { $_.Message }) -join ' | '
    Write-Verbose "${url}: $allText"

    # Certificate problems, as recorded by the validation callback.
    if ($TlsHelper) {
        $tlsErrors = [CgValidateTls]::GetErrors($hostName)
        if ($tlsErrors -and $tlsErrors -ne 'None') {
            if ($tlsErrors -eq 'RemoteCertificateNameMismatch') {
                return @{ Reason = 'server answered with a certificate for a different name'; Reached = $true }
            }
            return @{ Reason = 'TLS certificate not trusted (TLS-inspecting proxy?)'; Reached = $false }
        }
    }

    # Proxy refused the CONNECT tunnel (.NET: "...proxy tunnel request ... failed with status code '403'").
    if ($allText -match '(?i)proxy tunnel|proxy.*status code') {
        $code = if ($allText -match "status code '?(\d{3})") { $Matches[1] } else { '' }
        if ($code) { return @{ Reason = "Blocked by proxy (HTTP $code)"; Reached = $false } }
        return @{ Reason = 'Blocked by proxy'; Reached = $false }
    }

    foreach ($ex in $chain) {
        if ($ex -is [System.Threading.Tasks.TaskCanceledException] -or $ex -is [System.OperationCanceledException] -or $ex -is [System.TimeoutException]) {
            return @{ Reason = "Timed out after ${Timeout}s"; Reached = $false }
        }
        if ($ex -is [System.Net.Sockets.SocketException]) {
            switch ([string]$ex.SocketErrorCode) {
                { $_ -in 'HostNotFound', 'NoData', 'TryAgain' } { return @{ Reason = "Cannot resolve $hostName (DNS)"; Reached = $false } }
                'TimedOut' { return @{ Reason = "Timed out after ${Timeout}s"; Reached = $false } }
                'ConnectionReset' {
                    if ($allText -match '(?i)SSL|TLS') { return @{ Reason = 'Connection reset during TLS handshake (firewall?)'; Reached = $false } }
                    return @{ Reason = 'Connection reset (firewall?)'; Reached = $false }
                }
                default { return @{ Reason = "Cannot connect to $hostPort"; Reached = $false } }
            }
        }
        if ($ex -is [System.Net.WebException]) {
            switch ([string]$ex.Status) {
                'NameResolutionFailure' { return @{ Reason = "Cannot resolve $hostName (DNS)"; Reached = $false } }
                'ProxyNameResolutionFailure' { return @{ Reason = 'Cannot resolve proxy host'; Reached = $false } }
                'ConnectFailure' { return @{ Reason = "Cannot connect to $hostPort"; Reached = $false } }
                'Timeout' { return @{ Reason = "Timed out after ${Timeout}s"; Reached = $false } }
                'TrustFailure' { return @{ Reason = 'TLS certificate not trusted (TLS-inspecting proxy?)'; Reached = $false } }
                'SecureChannelFailure' { return @{ Reason = 'TLS handshake failed'; Reached = $false } }
                { $_ -in 'ConnectionClosed', 'ReceiveFailure', 'SendFailure', 'KeepAliveFailure' } { return @{ Reason = 'Connection reset (firewall?)'; Reached = $false } }
            }
        }
    }

    if ($allText -match '(?i)TLS alert|unrecognized.?name') {
        return @{ Reason = 'server answered but refused TLS for this name'; Reached = $true }
    }
    if ($allText -match '(?i)name or service not known|no such host|nodename nor servname|could not be resolved') {
        return @{ Reason = "Cannot resolve $hostName (DNS)"; Reached = $false }
    }
    if ($allText -match '(?i)connection reset|forcibly closed|unexpected EOF|0 bytes from the transport') {
        if ($allText -match '(?i)SSL|TLS') { return @{ Reason = 'Connection reset during TLS handshake (firewall?)'; Reached = $false } }
        return @{ Reason = 'Connection reset (firewall?)'; Reached = $false }
    }
    if ($allText -match '(?i)connection refused|actively refused') {
        return @{ Reason = "Cannot connect to $hostPort"; Reached = $false }
    }
    if ($allText -match '(?i)SSL connection could not be established|authentication failed') {
        return @{ Reason = 'TLS handshake failed'; Reached = $false }
    }
    return @{ Reason = $chain[$chain.Count - 1].Message.Trim(); Reached = $false }
}

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
$Results = @{}
function Add-Row([string]$key, [string]$value, [string]$status, [string]$display, [string]$detail, [string]$test) {
    $Results[$key] = [pscustomobject]@{ Value = $value; Status = $status; Display = $display; Detail = $detail; Test = $test }
}

# Reachability: any HTTP response from the server passes, except typical
# block-page statuses, which are flagged.
function Test-Reach([string]$key, [string]$value, [string]$url) {
    $test = if ($url -match '^(?i)http://') { 'HTTP GET /' } else { 'HTTPS GET /' }
    try {
        $resp = $ReachClient.GetAsync($url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $code = [int]$resp.StatusCode
        $resp.Dispose()
        $detail = "HTTP $code$(Get-IssuerNote $url)"
        if ($BlockStatuses -contains $code) {
            Add-Row $key $value 'warn' "$WarnMark HTTP $code - may be a proxy block page" $detail $test
        }
        else {
            Add-Row $key $value 'pass' ([string]$CheckMark) $detail $test
        }
    }
    catch {
        $info = Get-FailureInfo $_ $url
        if ($info.Reached) { Add-Row $key $value 'pass' ([string]$CheckMark) $info.Reason $test }
        else { Add-Row $key $value 'fail' "$CrossMark $($info.Reason)" $info.Reason $test }
    }
}

# Endpoint check: needs a 2xx response whose body contains $marker, so a
# proxy's block or login page cannot pass for the real endpoint.
function Test-Endpoint([string]$key, [string]$base, [string]$path, [string]$marker) {
    $test = "HTTP GET $path"
    $url = $base + $path
    try {
        $resp = $HttpClient.GetAsync($url).GetAwaiter().GetResult()
        try {
            $code = [int]$resp.StatusCode
            $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        }
        finally { $resp.Dispose() }
        $note = Get-IssuerNote $url
        if ($code -lt 200 -or $code -ge 300) {
            Add-Row $key $base 'fail' "$CrossMark HTTP $code from server" "HTTP $code from server$note" $test
        }
        elseif ($body.Contains($marker)) {
            Add-Row $key $base 'pass' $MsgEndpointOk "HTTP $code$note" $test
        }
        else {
            $snippet = if ($body.Length -gt 120) { $body.Substring(0, 120) } else { $body }
            Write-Verbose "${url}: HTTP $code but body has no ${marker}: $snippet"
            Add-Row $key $base 'fail' "$CrossMark HTTP $code but not the expected response (proxy page?)" "HTTP $code but the body is not the expected JSON (proxy page?)$note" $test
        }
    }
    catch {
        $info = Get-FailureInfo $_ $url
        Add-Row $key $base 'fail' "$CrossMark $($info.Reason)" $info.Reason $test
    }
}

$script:GrpcMode = $null
function Get-GrpcMode {
    if ($null -ne $script:GrpcMode) { return $script:GrpcMode }
    if ($PSMajor -ge 6) { $script:GrpcMode = 'dotnet' }
    else {
        $script:GrpcMode = 'none'
        $curl = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue
        if ($curl) {
            # Native stderr + EAP=Stop throws in Windows PowerShell 5.1.
            $ErrorActionPreference = 'Continue'
            $features = (& $curl.Source -V 2>$null | Out-String)
            $ErrorActionPreference = 'Stop'
            if ($features -match 'HTTP2') { $script:GrpcMode = 'curl' }
        }
        if ($script:GrpcMode -eq 'none') {
            Write-Warning 'gRPC checks need HTTP/2, which Windows PowerShell 5.1 and this curl.exe do not support. Run with PowerShell 7+ (pwsh) for the gRPC checks.'
        }
    }
    return $script:GrpcMode
}

# Unary gRPC call to PingService/Ping with an empty PingRequest. Needs an
# HTTP/2 response with grpc-status 0, which is what the chainctl gRPC client
# needs.
function Test-Grpc([string]$key, [string]$base) {
    $test = 'gRPC Ping (HTTP/2)'
    $u = [Uri]$base
    $url = "$($u.Scheme)://$($u.Host):$($u.Port)$GrpcPingPath"
    $emptyFrame = [byte[]](0, 0, 0, 0, 0)

    switch (Get-GrpcMode) {
        'dotnet' {
            $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $url)
            $req.Version = New-Object Version(2, 0)
            if ($null -ne $req.GetType().GetProperty('VersionPolicy')) {
                # Over TLS, ask for HTTP/2 but accept a downgrade so it can be
                # reported; plain http:// needs HTTP/2 prior knowledge (h2c).
                $req.VersionPolicy = if ($u.Scheme -eq 'http') { [System.Net.Http.HttpVersionPolicy]::RequestVersionExact } else { [System.Net.Http.HttpVersionPolicy]::RequestVersionOrLower }
            }
            $content = New-Object System.Net.Http.ByteArrayContent(, $emptyFrame)
            [void]$content.Headers.TryAddWithoutValidation('Content-Type', 'application/grpc')
            $req.Content = $content
            [void]$req.Headers.TryAddWithoutValidation('TE', 'trailers')
            [void]$req.Headers.TryAddWithoutValidation('grpc-accept-encoding', 'identity')
            try {
                $resp = $HttpClient.SendAsync($req).GetAwaiter().GetResult()
                try {
                    if ($resp.Version.Major -ne 2) {
                        Write-Verbose "${url}: answered with HTTP/$($resp.Version) instead of HTTP/2"
                        Add-Row $key $base 'fail' $MsgGrpcHttp1 "answered with HTTP/$($resp.Version) instead of HTTP/2" $test
                        return
                    }
                    [void]$resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                    $status = $null
                    $vals = $null
                    if ($resp.TrailingHeaders.TryGetValues('grpc-status', [ref]$vals)) { $status = @($vals)[0] }
                    elseif ($resp.Headers.TryGetValues('grpc-status', [ref]$vals)) { $status = @($vals)[0] }
                    if ($status -eq '0') { Add-Row $key $base 'pass' $MsgGrpcOk 'grpc-status 0' $test; return }
                    $shown = if ($status) { $status } else { 'missing' }
                    Add-Row $key $base 'fail' "$CrossMark gRPC call failed (grpc-status $shown)" "gRPC call failed (grpc-status $shown)" $test
                }
                finally { $resp.Dispose() }
            }
            catch {
                $info = Get-FailureInfo $_ $url
                Add-Row $key $base 'fail' "$CrossMark $($info.Reason)" $info.Reason $test
            }
        }
        'curl' {
            $tmp = [System.IO.Path]::GetTempFileName()
            try {
                [System.IO.File]::WriteAllBytes($tmp, $emptyFrame)
                $h2flag = if ($u.Scheme -eq 'http') { '--http2-prior-knowledge' } else { '--http2' }
                # Native stderr + EAP=Stop throws in Windows PowerShell 5.1.
                $ErrorActionPreference = 'Continue'
                $out = & curl.exe -sS $h2flag --max-time $Timeout -X POST `
                    -H 'content-type: application/grpc' -H 'te: trailers' -H 'grpc-accept-encoding: identity' `
                    --data-binary "@$tmp" -D - -o NUL $url 2>&1
                $ErrorActionPreference = 'Stop'
                $lines = @($out | ForEach-Object { "$_".TrimEnd("`r") })
                $first = if ($lines.Count -gt 0) { $lines[0] } else { '' }
                if ($first -match '^curl: \(\d+\)') {
                    Add-Row $key $base 'fail' "$CrossMark $first" $first $test
                }
                elseif ($first -notmatch '^HTTP/2') {
                    Add-Row $key $base 'fail' $MsgGrpcHttp1 "answered with $first instead of HTTP/2" $test
                }
                elseif ($lines -match '^(?i)grpc-status:\s*0$') {
                    Add-Row $key $base 'pass' $MsgGrpcOk 'grpc-status 0' $test
                }
                else {
                    Add-Row $key $base 'fail' "$CrossMark gRPC call failed" (($lines -match '^(?i)grpc-(status|message):') -join ' ') $test
                }
            }
            finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
        }
        default { Add-Row $key $base 'fail' $MsgGrpcUntested $MsgGrpcUntested $test }
    }
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
foreach ($k in @('api', 'console', 'issuer', 'registry')) {
    Test-Reach "platform.$k" $Platform[$k] $Platform[$k]
}
foreach ($k in $RequiredDomains.Keys) {
    $d = $RequiredDomains[$k]
    Test-Reach "domains.$k" $d "https://$d/"
}
foreach ($k in @('issuer', 'api')) {
    $u = $Platform[$k]
    Test-Grpc "protocol.grpc.platform.$k" $u
    Test-Endpoint "protocol.http.platform.$k" $u $HttpPingPath '"response"'
    if ($k -eq 'issuer') {
        Test-Endpoint 'issuer/.well-known/openid-configuration' $u '/.well-known/openid-configuration' '"jwks_uri"'
        Test-Endpoint 'issuer/keys' $u '/keys' '"keys"'
    }
}
$ReachClient.Dispose()
$HttpClient.Dispose()

[string[]]$SortedKeys = @($Results.Keys)
[Array]::Sort($SortedKeys, [StringComparer]::Ordinal)

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
$BS = [string][char]0x5C

# Go encoding/json string escaping (incl. HTML-safe escaping of < > &).
function ConvertTo-GoJsonString([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        $c = [int]$ch
        switch ($c) {
            0x22 { [void]$sb.Append($BS + '"') }
            0x5C { [void]$sb.Append($BS + $BS) }
            0x0A { [void]$sb.Append($BS + 'n') }
            0x0D { [void]$sb.Append($BS + 'r') }
            0x09 { [void]$sb.Append($BS + 't') }
            0x3C { [void]$sb.Append($BS + 'u003c') }
            0x3E { [void]$sb.Append($BS + 'u003e') }
            0x26 { [void]$sb.Append($BS + 'u0026') }
            0x2028 { [void]$sb.Append($BS + 'u2028') }
            0x2029 { [void]$sb.Append($BS + 'u2029') }
            default {
                if ($c -lt 0x20) { [void]$sb.Append($BS + ('u{0:x4}' -f $c)) }
                else { [void]$sb.Append($ch) }
            }
        }
    }
    return '"' + $sb.ToString() + '"'
}

# Display width: everything is ASCII except the emoji, which occupy two
# terminal columns each (as go-runewidth counts them).
function Get-DisplayWidth([string]$s) {
    $w = $s.Length
    foreach ($ch in $s.ToCharArray()) { if ($ch -eq $CheckMark -or $ch -eq $CrossMark -or $ch -eq $WarnMark) { $w++ } }
    return $w
}
function Format-Right([string]$s, [int]$width) { return (' ' * ($width - (Get-DisplayWidth $s))) + $s }
function Format-Center([string]$s, [int]$width) {
    $extra = $width - (Get-DisplayWidth $s)
    $left = [Math]::Floor($extra / 2)
    return (' ' * $left) + $s + (' ' * ($extra - $left))
}

$lines = New-Object System.Collections.Generic.List[string]
if ($Output -eq 'json') {
    $parts = foreach ($k in $SortedKeys) {
        $r = $Results[$k]
        (ConvertTo-GoJsonString $k) + ':{"Value":' + (ConvertTo-GoJsonString $r.Value) +
        ',"Result":' + (ConvertTo-GoJsonString $r.Status) +
        ',"Detail":' + (ConvertTo-GoJsonString $r.Detail) +
        ',"Test":' + (ConvertTo-GoJsonString $r.Test) + '}'
    }
    $lines.Add('{' + ($parts -join ',') + '}')
}
else {
    # tablewriter (Markdown symbols, no outer borders, header centered and
    # upper-cased, rows right-aligned), as chainctl renders it. -o wide
    # appends the TEST column.
    $wide = ($Output -eq 'wide')
    $headers = if ($wide) { @('NAME', 'VALUE', 'RESULT', 'TEST') } else { @('NAME', 'VALUE', 'RESULT') }
    $cols = $headers.Count
    $rows = foreach ($k in $SortedKeys) {
        $r = $Results[$k]
        # On a pass or warning, the TEST column also shows what came back
        # (e.g. "HTTP 400, cert issuer: R11").
        $t = $r.Test
        if ($r.Status -ne 'fail' -and $r.Detail) { $t = "$t ($($r.Detail))" }
        , @($k, $r.Value, $r.Display, $t)
    }
    $widths = @($headers | ForEach-Object { $_.Length })
    foreach ($row in $rows) {
        for ($i = 0; $i -lt $cols; $i++) {
            $w = Get-DisplayWidth $row[$i]
            if ($w -gt $widths[$i]) { $widths[$i] = $w }
        }
    }
    $lines.Add(' ' + ((0..($cols - 1) | ForEach-Object { Format-Center $headers[$_] $widths[$_] }) -join ' | ') + ' ')
    $lines.Add((0..($cols - 1) | ForEach-Object { '-' * ($widths[$_] + 2) }) -join '|')
    foreach ($row in $rows) {
        $lines.Add(' ' + ((0..($cols - 1) | ForEach-Object { Format-Right $row[$_] $widths[$_] }) -join ' | ') + ' ')
    }
}

# Make sure the emoji survive the Windows console.
$previousEncoding = $null
try {
    if ($IsWindowsHost -and -not [Console]::IsOutputRedirected) {
        $previousEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    }
}
catch { $previousEncoding = $null }
try {
    foreach ($l in $lines) { Write-Output $l }
}
finally {
    if ($null -ne $previousEncoding) { [Console]::OutputEncoding = $previousEncoding }
}
