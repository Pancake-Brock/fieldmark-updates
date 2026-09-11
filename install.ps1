# Fieldmark installer (Windows). Published to the public fieldmark-updates repo on every
# release — run via:
#   irm https://raw.githubusercontent.com/Pancake-Brock/fieldmark-updates/main/install.ps1 | iex
#
# Written for Windows PowerShell 5.1 (the Windows default) — no ??/?:/?./&&/|| operators, and
# RNGCryptoServiceProvider instead of RandomNumberGenerator.Fill (which needs .NET 5+).

$ErrorActionPreference = "Stop"

$RepoRaw = "https://raw.githubusercontent.com/Pancake-Brock/fieldmark-updates/main"
$InstallDir = if ($env:FIELDMARK_INSTALL_DIR) { $env:FIELDMARK_INSTALL_DIR } else { "$env:USERPROFILE\Fieldmark" }

function New-RandomHex {
    param([int]$Bytes = 32)
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $buffer = New-Object byte[] $Bytes
    $rng.GetBytes($buffer)
    -join ($buffer | ForEach-Object { $_.ToString("x2") })
}

function Get-LanIp {
    try {
        $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1
        $ip = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1 -ExpandProperty IPAddress
        if ($ip) { return $ip }
    } catch {}
    return "localhost"
}

Write-Host "== Fieldmark Installer =="
Write-Host ""

$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerCmd) {
    Write-Host "Docker is required but wasn't found."
    Write-Host ""
    Write-Host "Install Docker Desktop from https://www.docker.com/products/docker-desktop/,"
    Write-Host "start it, then re-run this installer."
    exit 1
}

docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Docker Desktop is installed but doesn't appear to be running."
    Write-Host "Start Docker Desktop and re-run this installer."
    exit 1
}

docker compose version *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Docker was found, but the 'docker compose' plugin isn't available."
    Write-Host "Update Docker Desktop to a recent version and re-run this installer."
    exit 1
}

Write-Host "Docker found: $(docker --version)"
Write-Host ""

Write-Host "How will this be accessed?"
Write-Host "  1) LAN only - everyone opens it from this office's network (no domain needed)"
Write-Host "  2) Internet-facing - reachable from anywhere via a real domain name (automatic HTTPS)"
$modeChoice = Read-Host "Choose 1 or 2"

$domain = ""
if ($modeChoice -eq "2") {
    $domain = Read-Host "Domain name (must already point at this machine's public IP), e.g. takeoff.example.com"
    if (-not $domain) {
        Write-Error "A domain is required for internet-facing mode."
        exit 1
    }
}

$lanIp = Get-LanIp

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Set-Location $InstallDir
Write-Host ""
Write-Host "Installing into $InstallDir"

Write-Host "Downloading docker-compose.prod.yml..."
Invoke-WebRequest -Uri "$RepoRaw/docker-compose.prod.yml" -OutFile "docker-compose.prod.yml"

$settingsEncryptionKey = New-RandomHex
$watchtowerHttpToken = New-RandomHex

if ($modeChoice -eq "2") {
    $siteAddress = $domain
    $cookieSecure = "true"
    $webOrigin = "https://$domain"
} else {
    $siteAddress = ":80"
    $cookieSecure = "false"
    $webOrigin = "http://$lanIp"
}

$envLines = @(
    "SITE_ADDRESS=$siteAddress",
    "COOKIE_SECURE=$cookieSecure",
    "WEB_ORIGIN=$webOrigin",
    "SETTINGS_ENCRYPTION_KEY=$settingsEncryptionKey",
    "WATCHTOWER_HTTP_TOKEN=$watchtowerHttpToken",
    "FIELDMARK_VERSION=latest",
    "UPDATE_MANIFEST_URL=https://raw.githubusercontent.com/Pancake-Brock/fieldmark-updates/main/latest.json"
)
Set-Content -Path ".env" -Value $envLines -Encoding utf8

Write-Host ".env written."
Write-Host ""

# $ErrorActionPreference = "Stop" only catches terminating PowerShell errors, NOT a native exe's
# nonzero exit code — docker compose failing here would otherwise go unnoticed and the script
# would carry on as if it had succeeded, exactly as it once did.
Write-Host "Pulling images (this can take a few minutes on first run)..."
docker compose -f docker-compose.prod.yml pull
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to pull images - check your internet connection and try again."
    exit 1
}
Write-Host "Starting Fieldmark..."
docker compose -f docker-compose.prod.yml up -d
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to start Fieldmark - a common cause is something else already using port 80 or 443 on this machine (another instance, IIS, Skype, etc). Check with: Get-NetTCPConnection -LocalPort 80,443"
    exit 1
}

Write-Host ""
Write-Host -NoNewline "Waiting for Fieldmark to start"
$ready = $false
$healthCheckJs = 'fetch(''http://localhost:3001/api/branding'').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))'
for ($i = 0; $i -lt 60; $i++) {
    docker compose -f docker-compose.prod.yml exec -T api node -e $healthCheckJs *> $null
    if ($LASTEXITCODE -eq 0) {
        $ready = $true
        break
    }
    Write-Host -NoNewline "."
    Start-Sleep -Seconds 2
}
Write-Host ""
if (-not $ready) {
    Write-Error "Fieldmark didn't come up within 2 minutes - check 'docker compose -f docker-compose.prod.yml logs api'."
    exit 1
}
Write-Host "Fieldmark is running."
Write-Host ""

Write-Host "Set up your first login:"
Write-Host "  1) Start blank - create the first admin account"
Write-Host "  2) Load sample data - explore Fieldmark with example projects first"
$dataChoice = Read-Host "Choose 1 or 2"

if ($dataChoice -eq "2") {
    docker compose -f docker-compose.prod.yml exec -T api pnpm seed-example-data
} else {
    $adminName = Read-Host "Admin name"
    $adminEmail = Read-Host "Admin email"
    $securePassword = Read-Host "Admin password (min 8 chars)" -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    $adminPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    docker compose -f docker-compose.prod.yml exec -T `
        -e "BOOTSTRAP_ADMIN_NAME=$adminName" `
        -e "BOOTSTRAP_ADMIN_EMAIL=$adminEmail" `
        -e "BOOTSTRAP_ADMIN_PASSWORD=$adminPassword" `
        api pnpm bootstrap-admin
}
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Warning "Account setup failed (see the error above) - Fieldmark may still be running, but you'll need to create a login by hand: docker compose -f docker-compose.prod.yml exec api pnpm bootstrap-admin"
}

# Checks the real published port, not just the api container's own internal health - the
# previous version of this script skipped this and would print "ready" even when Caddy failed
# to bind port 80/443 (e.g. because something else, like a leftover previous instance, was
# already using it), leaving the admin with a URL that just hangs forever.
Write-Host ""
Write-Host "Verifying Fieldmark is reachable..."
$checkHeaders = @{}
if ($modeChoice -eq "2") {
    $checkHeaders["Host"] = $domain
}
$reachable = $false
try {
    $response = Invoke-WebRequest -Uri "http://127.0.0.1/api/branding" -Headers $checkHeaders -UseBasicParsing -TimeoutSec 10
    if ($response.StatusCode -eq 200) {
        $reachable = $true
    }
} catch {}
if (-not $reachable) {
    Write-Error "Fieldmark did not respond on port 80/443. This usually means something else is already using that port. Check with: docker compose -f docker-compose.prod.yml logs caddy"
    exit 1
}

Write-Host ""
Write-Host "=========================================="
if ($modeChoice -eq "2") {
    Write-Host "Fieldmark is ready at: https://$domain"
    Write-Host "(HTTPS is provisioned automatically on first request - allow a minute.)"
} else {
    Write-Host "Fieldmark is ready at: http://$lanIp"
    Write-Host "(anyone on this network can open that address)"
}
Write-Host "=========================================="
