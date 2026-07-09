#requires -Version 5.1

# =========================
# GLPI LOCAL DASHBOARD SERVER
# =========================
# - Local only: 127.0.0.1
# - Auto free port when HOST_PORT=0
# - Asks GLPI password at startup
# - Serves dashboard.html
# - Exposes /api/stats
# - Reads tickets only, not tasks
# - Assigned tickets are detected from:
#   ticket.team[] where role == "assigned" and id == USER_ID
# - Detailed server logs
# - Clean shutdown on CTRL+C / script exit
# - Re-authenticates if GLPI returns invalid OAuth token, even with HTTP 400
# =========================

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$envPath = Join-Path $scriptDir ".env"
$dashboardPath = Join-Path $scriptDir "dashboard.html"
$pidPath = Join-Path $scriptDir "dashboard-server.pid.json"

$ticketEndpoint = "Assistance/Ticket"
$openTicketFilter = "status.id=out=(5,6);is_deleted==false"

$script:httpListener = $null
$script:stopRequested = $false
$script:ctrlCSubscription = $null
$script:exitSubscription = $null
$script:logLevel = "INFO"
$script:hostPrefix = $null

# =========================
# LOGGING
# =========================

function Get-LogLevelNumber {
    param (
        [string]$Level
    )

    switch (($Level + "").ToUpperInvariant()) {
        "DEBUG" { return 0 }
        "INFO"  { return 1 }
        "WARN"  { return 2 }
        "ERROR" { return 3 }
        default { return 1 }
    }
}

function Write-Log {
    param (
        [string]$Level,
        [string]$Message,
        $Data = $null
    )

    $configuredLevel = if ($script:logLevel) { $script:logLevel } else { "INFO" }

    if ((Get-LogLevelNumber $Level) -lt (Get-LogLevelNumber $configuredLevel)) {
        return
    }

    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
    $line = "[{0}] [{1}] {2}" -f $timestamp, $Level.ToUpperInvariant(), $Message

    $color = "White"

    switch ($Level.ToUpperInvariant()) {
        "DEBUG" { $color = "DarkGray" }
        "INFO"  { $color = "Cyan" }
        "WARN"  { $color = "Yellow" }
        "ERROR" { $color = "Red" }
    }

    Write-Host $line -ForegroundColor $color

    if ($null -ne $Data) {
        try {
            $json = $Data | ConvertTo-Json -Depth 20
            Write-Host $json -ForegroundColor DarkGray
        }
        catch {
            Write-Host ([string]$Data) -ForegroundColor DarkGray
        }
    }
}

function Read-ErrorResponseBody {
    param (
        $ErrorRecord
    )

    try {
        $response = $ErrorRecord.Exception.Response

        if ($null -eq $response) {
            return ""
        }

        $stream = $response.GetResponseStream()

        if ($null -eq $stream) {
            return ""
        }

        $reader = New-Object System.IO.StreamReader($stream)
        $body = $reader.ReadToEnd()

        if ($body.Length -gt 4000) {
            return $body.Substring(0, 4000) + "... [truncated]"
        }

        return $body
    }
    catch {
        return ""
    }
}

function Get-HttpStatusCode {
    param (
        $ErrorRecord
    )

    try {
        if ($ErrorRecord.Exception.Response -and $ErrorRecord.Exception.Response.StatusCode) {
            return [int]$ErrorRecord.Exception.Response.StatusCode
        }
    }
    catch {}

    return $null
}

function Get-ExceptionDetails {
    param (
        $ErrorRecord
    )

    $statusCode = Get-HttpStatusCode $ErrorRecord
    $responseBody = Read-ErrorResponseBody $ErrorRecord

    return [PSCustomObject]@{
        message = $ErrorRecord.Exception.Message
        type = $ErrorRecord.Exception.GetType().FullName
        statusCode = $statusCode
        responseBody = $responseBody
        scriptStackTrace = $ErrorRecord.ScriptStackTrace
    }
}

function New-ErrorResponseObject {
    param (
        $ErrorRecord,
        [string]$PublicMessage,
        [string]$RequestId
    )

    $details = Get-ExceptionDetails $ErrorRecord

    return [PSCustomObject]@{
        error = $PublicMessage
        message = $details.message
        type = $details.type
        statusCode = $details.statusCode
        responseBody = $details.responseBody
        requestId = $RequestId
        timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }
}

# =========================
# CLEANUP / SINGLE INSTANCE
# =========================

function Stop-DashboardServer {
    param (
        [string]$Reason = "Shutdown"
    )

    $script:stopRequested = $true

    try {
        Write-Log -Level INFO -Message "Arresto dashboard locale..." -Data @{
            reason = $Reason
            pid = $PID
        }
    }
    catch {}

    if ($null -ne $script:httpListener) {
        try {
            if ($script:httpListener.IsListening) {
                $script:httpListener.Stop()
            }
        }
        catch {}

        try {
            $script:httpListener.Close()
        }
        catch {}

        $script:httpListener = $null
    }

    try {
        if (Test-Path $pidPath) {
            $pidData = Get-Content $pidPath -Raw | ConvertFrom-Json

            if ([int]$pidData.pid -eq [int]$PID) {
                Remove-Item $pidPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {}

    try {
        if ($script:ctrlCSubscription) {
            Unregister-Event -SubscriptionId $script:ctrlCSubscription.Id -ErrorAction SilentlyContinue
            Remove-Job -Id $script:ctrlCSubscription.Id -Force -ErrorAction SilentlyContinue
            $script:ctrlCSubscription = $null
        }
    }
    catch {}

    try {
        if ($script:exitSubscription) {
            Unregister-Event -SubscriptionId $script:exitSubscription.Id -ErrorAction SilentlyContinue
            Remove-Job -Id $script:exitSubscription.Id -Force -ErrorAction SilentlyContinue
            $script:exitSubscription = $null
        }
    }
    catch {}
}

function Register-DashboardShutdownHandlers {
    try {
        $script:ctrlCSubscription = Register-ObjectEvent `
            -InputObject ([Console]) `
            -EventName CancelKeyPress `
            -SourceIdentifier "GLPI_DASHBOARD_CTRL_C_$PID" `
            -Action {
                $Event.SourceEventArgs.Cancel = $true

                try {
                    $script:stopRequested = $true
                }
                catch {}

                try {
                    if ($script:httpListener) {
                        if ($script:httpListener.IsListening) {
                            $script:httpListener.Stop()
                        }

                        $script:httpListener.Close()
                    }
                }
                catch {}
            }

        Write-Log -Level DEBUG -Message "Handler CTRL+C registrato"
    }
    catch {
        Write-Log -Level WARN -Message "Impossibile registrare handler CTRL+C" -Data @{
            error = $_.Exception.Message
        }
    }

    try {
        $script:exitSubscription = Register-EngineEvent `
            -SourceIdentifier PowerShell.Exiting `
            -Action {
                try {
                    if ($script:httpListener) {
                        if ($script:httpListener.IsListening) {
                            $script:httpListener.Stop()
                        }

                        $script:httpListener.Close()
                    }
                }
                catch {}

                try {
                    if (Test-Path $pidPath) {
                        $pidData = Get-Content $pidPath -Raw | ConvertFrom-Json

                        if ([int]$pidData.pid -eq [int]$PID) {
                            Remove-Item $pidPath -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
                catch {}
            }

        Write-Log -Level DEBUG -Message "Handler uscita PowerShell registrato"
    }
    catch {
        Write-Log -Level WARN -Message "Impossibile registrare handler uscita PowerShell" -Data @{
            error = $_.Exception.Message
        }
    }
}

function Initialize-DashboardSingleInstance {
    if (Test-Path $pidPath) {
        try {
            $oldPidData = Get-Content $pidPath -Raw | ConvertFrom-Json
            $oldPid = [int]$oldPidData.pid
            $oldScriptPath = [string]$oldPidData.scriptPath

            if ($oldPid -ne $PID) {
                $oldProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $oldPid" -ErrorAction SilentlyContinue

                if ($null -ne $oldProcess) {
                    $commandLine = [string]$oldProcess.CommandLine

                    $looksLikeThisDashboard =
                        ($commandLine -match "server\.ps1") -or
                        ($commandLine -like "*$oldScriptPath*") -or
                        ($commandLine -like "*$scriptDir*")

                    if ($looksLikeThisDashboard) {
                        Write-Log -Level WARN -Message "Trovato vecchio processo dashboard. Lo fermo prima di continuare..." -Data @{
                            oldPid = $oldPid
                            commandLine = $commandLine
                        }

                        try {
                            Stop-Process -Id $oldPid -Force -ErrorAction Stop
                            Start-Sleep -Milliseconds 800
                        }
                        catch {
                            Write-Log -Level ERROR -Message "Impossibile fermare il vecchio processo dashboard" -Data @{
                                oldPid = $oldPid
                                error = $_.Exception.Message
                            }

                            exit 1
                        }
                    }
                    else {
                        Write-Log -Level WARN -Message "PID file trovato, ma il processo non sembra essere questa dashboard. Rimuovo solo il PID file." -Data @{
                            oldPid = $oldPid
                            commandLine = $commandLine
                        }
                    }
                }
            }
        }
        catch {
            Write-Log -Level WARN -Message "PID file non valido. Lo rimuovo." -Data @{
                pidFile = $pidPath
                error = $_.Exception.Message
            }
        }

        Remove-Item $pidPath -Force -ErrorAction SilentlyContinue
    }

    $pidObject = [PSCustomObject]@{
        pid = $PID
        scriptPath = Join-Path $scriptDir "server.ps1"
        folder = $scriptDir
        hostPrefix = $script:hostPrefix
        startedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }

    $pidObject | ConvertTo-Json -Depth 10 | Set-Content -Path $pidPath -Encoding UTF8 -Force

    Write-Log -Level INFO -Message "PID dashboard registrato" -Data @{
        pid = $PID
        pidFile = $pidPath
    }
}

# =========================
# ENV
# =========================

function Load-Env {
    param (
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        Write-Host "[ERR] File .env non trovato: $Path" -ForegroundColor Red
        exit 1
    }

    $envVars = @{}

    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()

        if ([string]::IsNullOrWhiteSpace($line)) {
            return
        }

        if ($line.StartsWith("#")) {
            return
        }

        if ($line -match "^\s*([^#][^=]+)=(.*)$") {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim().Trim('"').Trim("'")
            $envVars[$key] = $value
        }
    }

    return $envVars
}

function Get-EnvValue {
    param (
        [hashtable]$EnvVars,
        [string]$Key,
        [string]$Default = $null
    )

    if ($EnvVars.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace([string]$EnvVars[$Key])) {
        return [string]$EnvVars[$Key]
    }

    return $Default
}

function Get-RequiredString {
    param (
        [hashtable]$EnvVars,
        [string]$Key
    )

    $value = Get-EnvValue -EnvVars $EnvVars -Key $Key

    if ([string]::IsNullOrWhiteSpace($value)) {
        Write-Log -Level ERROR -Message "$Key non trovato nel file .env"
        exit 1
    }

    return $value
}

function Get-RequiredInt {
    param (
        [hashtable]$EnvVars,
        [string]$Key
    )

    $value = Get-RequiredString -EnvVars $EnvVars -Key $Key
    $parsed = 0

    if (-not [int]::TryParse($value, [ref]$parsed)) {
        Write-Log -Level ERROR -Message "$Key nel file .env deve essere un numero" -Data @{
            value = $value
        }
        exit 1
    }

    return $parsed
}

# =========================
# HOST / PORT
# =========================

function Get-FreeLocalPort {
    $tcpListener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Parse("127.0.0.1"), 0)

    try {
        $tcpListener.Start()
        return [int]$tcpListener.LocalEndpoint.Port
    }
    finally {
        $tcpListener.Stop()
    }
}

function Resolve-LocalHostPrefix {
    param (
        [hashtable]$EnvVars
    )

    $hostValue = Get-EnvValue -EnvVars $EnvVars -Key "HOST" -Default $null
    $portValue = Get-EnvValue -EnvVars $EnvVars -Key "HOST_PORT" -Default "0"

    if (-not [string]::IsNullOrWhiteSpace($hostValue)) {
        if (-not $hostValue.StartsWith("http://127.0.0.1:")) {
            Write-Log -Level ERROR -Message "HOST non sicuro. Deve iniziare con http://127.0.0.1:" -Data @{
                host = $hostValue
                example = "http://127.0.0.1:49173/"
            }

            exit 1
        }

        if (-not $hostValue.EndsWith("/")) {
            $hostValue = "$hostValue/"
        }

        return $hostValue
    }

    $port = 0

    if (-not [int]::TryParse($portValue, [ref]$port)) {
        Write-Log -Level ERROR -Message "HOST_PORT deve essere un numero" -Data @{
            HOST_PORT = $portValue
        }

        exit 1
    }

    if ($port -eq 0) {
        $port = Get-FreeLocalPort
    }

    if ($port -lt 1 -or $port -gt 65535) {
        Write-Log -Level ERROR -Message "HOST_PORT non valido" -Data @{
            HOST_PORT = $port
        }

        exit 1
    }

    return "http://127.0.0.1:$port/"
}

# =========================
# QUERY STRING
# =========================

function New-QueryString {
    param (
        [hashtable]$Params
    )

    if (-not $Params -or $Params.Count -eq 0) {
        return ""
    }

    $parts = @()

    foreach ($key in $Params.Keys) {
        $value = $Params[$key]

        if ($null -eq $value -or "$value" -eq "") {
            continue
        }

        $encodedKey = [Uri]::EscapeDataString([string]$key)
        $encodedValue = [Uri]::EscapeDataString([string]$value)

        $parts += "$encodedKey=$encodedValue"
    }

    return ($parts -join "&")
}

# =========================
# AUTH
# =========================

function New-GlpiToken {
    Write-Log -Level INFO -Message "Richiesta token GLPI..."

    $body = @{
        grant_type    = "password"
        client_id     = $script:clientId
        client_secret = $script:clientSecret
        username      = $script:credential.UserName
        password      = $script:credential.GetNetworkCredential().Password
        scope         = $script:scope
    }

    try {
        $response = Invoke-RestMethod `
            -Uri $script:authUrl `
            -Method POST `
            -ContentType "application/x-www-form-urlencoded" `
            -Body $body

        if ([string]::IsNullOrWhiteSpace($response.access_token)) {
            throw "La risposta di autenticazione non contiene access_token"
        }

        Write-Log -Level INFO -Message "Token GLPI ricevuto correttamente"
        return $response.access_token
    }
    catch {
        $details = Get-ExceptionDetails $_

        Write-Log -Level ERROR -Message "Autenticazione GLPI fallita" -Data @{
            authUrl = $script:authUrl
            message = $details.message
            statusCode = $details.statusCode
            responseBody = $details.responseBody
        }

        throw
    }
}

function Get-AccessToken {
    if (-not [string]::IsNullOrWhiteSpace($script:accessToken)) {
        return $script:accessToken
    }

    $script:accessToken = New-GlpiToken
    return $script:accessToken
}

function Test-GlpiAuthError {
    param (
        [int]$StatusCode,
        [string]$ResponseBody
    )

    if ($StatusCode -eq 401) {
        return $true
    }

    if ($StatusCode -eq 400 -and $ResponseBody -match "(?i)invalid oauth token|access token could not be verified|token") {
        return $true
    }

    return $false
}

# =========================
# GLPI GET
# =========================

function Invoke-GlpiGet {
    param (
        [string]$Uri,
        [hashtable]$Query = @{}
    )

    $queryString = New-QueryString $Query

    if ($queryString) {
        $Uri = "$Uri`?$queryString"
    }

    $token = Get-AccessToken

    Write-Log -Level DEBUG -Message "GLPI GET" -Data @{
        uri = $Uri
    }

    try {
        return Invoke-RestMethod `
            -Uri $Uri `
            -Method GET `
            -Headers @{
                Authorization     = "Bearer $token"
                accept            = "application/json"
                "Accept-Language" = "en_GB"
            }
    }
    catch {
        $statusCode = Get-HttpStatusCode $_
        $responseBody = Read-ErrorResponseBody $_

        if (Test-GlpiAuthError -StatusCode $statusCode -ResponseBody $responseBody) {
            Write-Log -Level WARN -Message "Token GLPI non valido. Cancello il token locale e riprovo autenticazione..." -Data @{
                statusCode = $statusCode
                responseBody = $responseBody
            }

            $script:accessToken = $null
            $token = Get-AccessToken

            try {
                Write-Log -Level INFO -Message "Riprovo GLPI GET con nuovo token..."

                return Invoke-RestMethod `
                    -Uri $Uri `
                    -Method GET `
                    -Headers @{
                        Authorization     = "Bearer $token"
                        accept            = "application/json"
                        "Accept-Language" = "en_GB"
                    }
            }
            catch {
                $retryStatusCode = Get-HttpStatusCode $_
                $retryResponseBody = Read-ErrorResponseBody $_

                Write-Log -Level ERROR -Message "GLPI GET fallita anche dopo nuova autenticazione" -Data @{
                    uri = $Uri
                    message = $_.Exception.Message
                    statusCode = $retryStatusCode
                    responseBody = $retryResponseBody
                }

                throw
            }
        }

        Write-Log -Level ERROR -Message "GLPI GET fallita" -Data @{
            uri = $Uri
            message = $_.Exception.Message
            statusCode = $statusCode
            responseBody = $responseBody
        }

        throw
    }
}

# =========================
# RESPONSE HELPERS
# =========================

function Convert-ToArray {
    param (
        $Value
    )

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        return @($Value)
    }

    foreach ($propertyName in @("data", "items", "results", "member", "hydra:member")) {
        if ($Value.PSObject.Properties.Name -contains $propertyName) {
            return Convert-ToArray $Value.$propertyName
        }
    }

    return @($Value)
}

function Get-PropValue {
    param (
        $Object,
        [string[]]$Names
    )

    if ($null -eq $Object) {
        return $null
    }

    foreach ($name in $Names) {
        if ($Object.PSObject.Properties.Name -contains $name) {
            return $Object.$name
        }
    }

    return $null
}

function Get-IdValue {
    param (
        $Value
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [decimal]) {
        return [long]$Value
    }

    if ($Value -is [string]) {
        $parsed = 0L

        if ([long]::TryParse($Value, [ref]$parsed)) {
            return $parsed
        }

        return $null
    }

    if ($Value.PSObject.Properties.Name -contains "id") {
        return Get-IdValue $Value.id
    }

    return $null
}

function Get-TextValue {
    param (
        $Value
    )

    if ($null -eq $Value) {
        return ""
    }

    if ($Value.PSObject.Properties.Name -contains "name") {
        return [string]$Value.name
    }

    return [string]$Value
}

# =========================
# TICKETS
# =========================

function Get-AllTickets {
    param (
        [string]$Filter
    )

    $endpoint = "$script:apiBaseUrl/$ticketEndpoint"

    $allTickets = @()
    $start = 0
    $pageNumber = 1

    while ($true) {
        Write-Log -Level INFO -Message ("Lettura ticket pagina {0}" -f $pageNumber) -Data @{
            start = $start
            limit = $script:pageSize
        }

        $response = Invoke-GlpiGet `
            -Uri $endpoint `
            -Query @{
                filter = $Filter
                start  = $start
                limit  = $script:pageSize
                sort   = "date_creation:desc"
            }

        $ticketsPage = @(Convert-ToArray $response)

        Write-Log -Level DEBUG -Message ("Pagina ticket {0} ricevuta" -f $pageNumber) -Data @{
            count = $ticketsPage.Count
        }

        if ($ticketsPage.Count -eq 0) {
            break
        }

        $allTickets += $ticketsPage

        if ($ticketsPage.Count -lt $script:pageSize) {
            break
        }

        $start += $script:pageSize
        $pageNumber++
    }

    Write-Log -Level INFO -Message "Lettura ticket completata" -Data @{
        totalTickets = $allTickets.Count
        pagesRead = $pageNumber
    }

    return $allTickets
}

function Get-TicketStatusId {
    param (
        $Ticket
    )

    $status = Get-PropValue $Ticket @("status", "status_id", "statuses_id")
    $statusId = Get-IdValue $status

    if ($null -ne $statusId) {
        return [int]$statusId
    }

    $statusText = Get-TextValue $status

    if ($statusText -match "(?i)new|nuovo|nuova") {
        return 1
    }

    if ($statusText -match "(?i)assigned|assegnato") {
        return 2
    }

    if ($statusText -match "(?i)planned|pianificato") {
        return 3
    }

    if ($statusText -match "(?i)pending|sospeso|in attesa") {
        return 4
    }

    if ($statusText -match "(?i)solved|risolto") {
        return 5
    }

    if ($statusText -match "(?i)closed|chiuso") {
        return 6
    }

    return $null
}

function Get-TicketTypeId {
    param (
        $Ticket
    )

    $type = Get-PropValue $Ticket @(
        "type",
        "type_id",
        "ticket_type",
        "tickettype",
        "request_type",
        "requesttype"
    )

    $typeId = Get-IdValue $type

    if ($null -ne $typeId) {
        return [int]$typeId
    }

    $typeText = Get-TextValue $type

    if ($typeText -match "(?i)incident|incidente|accident") {
        return 1
    }

    if ($typeText -match "(?i)request|richiesta") {
        return 2
    }

    return $null
}

function Test-TeamAssignedToUser {
    param (
        $Ticket,
        [int]$UserId
    )

    $team = Get-PropValue $Ticket @("team")

    if ($null -eq $team) {
        return $false
    }

    foreach ($member in @(Convert-ToArray $team)) {
        $role = (Get-TextValue (Get-PropValue $member @("role"))).Trim().ToLowerInvariant()
        $memberId = Get-IdValue (Get-PropValue $member @("id"))

        if ($role -eq "assigned" -and $null -ne $memberId -and [int]$memberId -eq [int]$UserId) {
            Write-Log -Level DEBUG -Message "Ticket assegnato trovato per USER_ID" -Data @{
                ticketId = Get-IdValue (Get-PropValue $Ticket @("id"))
                ticketName = Get-PropValue $Ticket @("name")
                userId = $UserId
                memberName = Get-PropValue $member @("display_name", "name")
            }

            return $true
        }
    }

    return $false
}

function Test-ValueContainsId {
    param (
        $Value,
        [int]$UserId,
        [int]$Depth = 0
    )

    if ($null -eq $Value) {
        return $false
    }

    if ($Depth -gt 6) {
        return $false
    }

    $id = Get-IdValue $Value

    if ($null -ne $id -and [int]$id -eq [int]$UserId) {
        return $true
    }

    if ($Value -is [System.Array]) {
        foreach ($item in $Value) {
            if (Test-ValueContainsId -Value $item -UserId $UserId -Depth ($Depth + 1)) {
                return $true
            }
        }
    }

    return $false
}

function Test-TicketAssignedToUser {
    param (
        $Ticket,
        [int]$UserId
    )

    if (Test-TeamAssignedToUser -Ticket $Ticket -UserId $UserId) {
        return $true
    }

    foreach ($field in @(
        "assignees",
        "assigned_users",
        "assigned_user",
        "assigned_to",
        "assignee",
        "technicians",
        "technician",
        "user_tech",
        "users_id_tech",
        "user_id_tech",
        "users_id_assign",
        "_users_id_assign",
        "user_assign"
    )) {
        $value = Get-PropValue $Ticket @($field)

        if (Test-ValueContainsId -Value $value -UserId $UserId) {
            return $true
        }
    }

    return $false
}

function Get-DashboardStats {
    $started = Get-Date

    Write-Log -Level INFO -Message "Calcolo statistiche dashboard..."

    $tickets = @(Get-AllTickets -Filter $openTicketFilter)

    $totalOpen = $tickets.Count

    $newAccidents = @(
        $tickets | Where-Object {
            (Get-TicketStatusId $_) -eq 1 -and
            (Get-TicketTypeId $_) -eq 1
        }
    ).Count

    $newRequests = @(
        $tickets | Where-Object {
            (Get-TicketStatusId $_) -eq 1 -and
            (Get-TicketTypeId $_) -eq 2
        }
    ).Count

    $myAssigned = @(
        $tickets | Where-Object {
            Test-TicketAssignedToUser -Ticket $_ -UserId $script:targetUserId
        }
    ).Count

    $elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds

    Write-Log -Level INFO -Message "Statistiche dashboard calcolate" -Data @{
        totaleTicketAperti = $totalOpen
        nuoviIncidenti = $newAccidents
        nuoveRichieste = $newRequests
        assegnatiAMe = $myAssigned
        elapsedMs = $elapsedMs
    }

    return [PSCustomObject]@{
        totaleTicketAperti = [int]$totalOpen
        nuoviIncidenti = [int]$newAccidents
        nuoveRichieste = [int]$newRequests
        assegnatiAMe = [int]$myAssigned
        durataMs = [int]$elapsedMs
        aggiornatoAlle = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }
}

# =========================
# WEB SERVER
# =========================

function Send-Response {
    param (
        [System.Net.HttpListenerContext]$Context,
        [int]$StatusCode,
        [string]$Body,
        [string]$ContentType
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)

    $response = $Context.Response
    $response.StatusCode = $StatusCode
    $response.ContentType = "$ContentType; charset=utf-8"
    $response.ContentLength64 = $bytes.Length

    $response.Headers["Cache-Control"] = "no-store"
    $response.Headers["Pragma"] = "no-cache"
    $response.Headers["X-Content-Type-Options"] = "nosniff"
    $response.Headers["Referrer-Policy"] = "no-referrer"
    $response.Headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"

    if ($bytes.Length -gt 0) {
        $response.OutputStream.Write($bytes, 0, $bytes.Length)
    }

    $response.OutputStream.Close()
}

function Send-Json {
    param (
        [System.Net.HttpListenerContext]$Context,
        $Object,
        [int]$StatusCode = 200
    )

    $json = $Object | ConvertTo-Json -Depth 20 -Compress
    Send-Response -Context $Context -StatusCode $StatusCode -Body $json -ContentType "application/json"
}

function Handle-Request {
    param (
        [System.Net.HttpListenerContext]$Context,
        [string]$RequestId
    )

    $request = $Context.Request
    $path = $request.Url.AbsolutePath.ToLowerInvariant()

    if ($request.HttpMethod -ne "GET") {
        Write-Log -Level WARN -Message "Metodo non consentito" -Data @{
            requestId = $RequestId
            method = $request.HttpMethod
            path = $path
        }

        Send-Response -Context $Context -StatusCode 405 -Body "Metodo non consentito" -ContentType "text/plain"
        return
    }

    switch ($path) {
        "/" {
            $html = Get-Content -Path $dashboardPath -Raw -Encoding UTF8
            Send-Response -Context $Context -StatusCode 200 -Body $html -ContentType "text/html"
        }

        "/dashboard.html" {
            $html = Get-Content -Path $dashboardPath -Raw -Encoding UTF8
            Send-Response -Context $Context -StatusCode 200 -Body $html -ContentType "text/html"
        }

        "/api/stats" {
            $stats = Get-DashboardStats
            Send-Json -Context $Context -Object $stats -StatusCode 200
        }

        "/api/health" {
            Send-Json -Context $Context -Object ([PSCustomObject]@{
                ok = $true
                authenticated = -not [string]::IsNullOrWhiteSpace($script:accessToken)
                time = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            }) -StatusCode 200
        }

        "/favicon.ico" {
            Send-Response -Context $Context -StatusCode 204 -Body "" -ContentType "text/plain"
        }

        default {
            Write-Log -Level WARN -Message "Percorso non trovato" -Data @{
                requestId = $RequestId
                path = $path
            }

            Send-Response -Context $Context -StatusCode 404 -Body "Non trovato" -ContentType "text/plain"
        }
    }
}

function Start-LocalServer {
    param (
        [string]$Prefix
    )

    if (-not $Prefix.StartsWith("http://127.0.0.1:")) {
        Write-Log -Level ERROR -Message "HOST non sicuro. Deve iniziare con http://127.0.0.1:" -Data @{
            host = $Prefix
            example = "http://127.0.0.1:49173/"
        }

        exit 1
    }

    if (-not $Prefix.EndsWith("/")) {
        $Prefix = "$Prefix/"
    }

    if (-not (Test-Path $dashboardPath)) {
        Write-Log -Level ERROR -Message "dashboard.html non trovato nella stessa cartella di server.ps1" -Data @{
            dashboardPath = $dashboardPath
        }

        exit 1
    }

    $script:httpListener = New-Object System.Net.HttpListener
    $script:httpListener.Prefixes.Add($Prefix)

    try {
        $script:httpListener.Start()
    }
    catch {
        $details = Get-ExceptionDetails $_

        Write-Log -Level ERROR -Message "Impossibile avviare il server locale" -Data @{
            prefix = $Prefix
            message = $details.message
            type = $details.type
        }

        Write-Host ""
        Write-Host "Se necessario, prova PowerShell come amministratore." -ForegroundColor Yellow
        exit 1
    }

    Write-Log -Level INFO -Message "Web service locale avviato" -Data @{
        dashboard = $Prefix
        apiStats = "$($Prefix.TrimEnd('/'))/api/stats"
        apiHealth = "$($Prefix.TrimEnd('/'))/api/health"
        localOnly = "127.0.0.1"
        logLevel = $script:logLevel
        pid = $PID
    }

    Write-Host ""
    Write-Host "Dashboard: $Prefix" -ForegroundColor Green
    Write-Host "Solo questo PC puo aprire la pagina, perche usa 127.0.0.1" -ForegroundColor DarkCyan
    Write-Host "Premi CTRL+C per fermare." -ForegroundColor DarkCyan

    while ($script:httpListener -and $script:httpListener.IsListening -and -not $script:stopRequested) {
        $context = $null
        $requestId = [guid]::NewGuid().ToString("N").Substring(0, 8)
        $started = Get-Date

        try {
            $context = $script:httpListener.GetContext()
        }
        catch [System.Net.HttpListenerException] {
            if ($script:stopRequested) {
                break
            }

            Write-Log -Level WARN -Message "Listener HTTP interrotto" -Data @{
                requestId = $requestId
                error = $_.Exception.Message
            }

            break
        }
        catch [System.ObjectDisposedException] {
            break
        }
        catch {
            if ($script:stopRequested) {
                break
            }

            Write-Log -Level ERROR -Message "Errore durante attesa richiesta HTTP" -Data @{
                requestId = $requestId
                error = $_.Exception.Message
            }

            break
        }

        if ($null -eq $context) {
            continue
        }

        $request = $context.Request

        Write-Log -Level INFO -Message "Richiesta ricevuta" -Data @{
            requestId = $requestId
            method = $request.HttpMethod
            path = $request.Url.AbsolutePath
            remote = $request.RemoteEndPoint.ToString()
        }

        try {
            Handle-Request -Context $context -RequestId $requestId

            $elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds

            Write-Log -Level INFO -Message "Richiesta completata" -Data @{
                requestId = $requestId
                path = $request.Url.AbsolutePath
                elapsedMs = $elapsedMs
            }
        }
        catch {
            $details = Get-ExceptionDetails $_

            Write-Log -Level ERROR -Message "Richiesta fallita" -Data @{
                requestId = $requestId
                path = $request.Url.AbsolutePath
                message = $details.message
                type = $details.type
                statusCode = $details.statusCode
                responseBody = $details.responseBody
                stack = $details.scriptStackTrace
            }

            $errorObject = New-ErrorResponseObject `
                -ErrorRecord $_ `
                -PublicMessage "Errore interno durante la richiesta" `
                -RequestId $requestId

            try {
                Send-Json -Context $context -Object $errorObject -StatusCode 500
            }
            catch {
                Write-Log -Level ERROR -Message "Impossibile inviare risposta di errore al browser" -Data @{
                    requestId = $requestId
                    message = $_.Exception.Message
                }
            }
        }
    }

    Write-Log -Level INFO -Message "Loop server terminato"
}

# =========================
# MAIN
# =========================

$envVars = Load-Env $envPath

$script:logLevel = Get-EnvValue -EnvVars $envVars -Key "LOG_LEVEL" -Default "INFO"

$script:apiBaseUrl = (Get-RequiredString -EnvVars $envVars -Key "GLPI_API_BASE_URL").TrimEnd("/")
$script:authUrl = Get-RequiredString -EnvVars $envVars -Key "GLPI_AUTH_URL"

$script:clientId = Get-RequiredString -EnvVars $envVars -Key "CLIENT_ID"
$script:clientSecret = Get-RequiredString -EnvVars $envVars -Key "CLIENT_SECRET"
$script:username = Get-RequiredString -EnvVars $envVars -Key "USERNAME"
$script:targetUserId = Get-RequiredInt -EnvVars $envVars -Key "USER_ID"

$script:scope = Get-EnvValue -EnvVars $envVars -Key "SCOPE" -Default "email user api inventory status graphql"
$script:pageSize = [int](Get-EnvValue -EnvVars $envVars -Key "PAGE_SIZE" -Default "100")
$script:accessToken = $null
$script:hostPrefix = Resolve-LocalHostPrefix -EnvVars $envVars

Write-Log -Level INFO -Message "Configurazione caricata" -Data @{
    apiBaseUrl = $script:apiBaseUrl
    authUrl = $script:authUrl
    username = $script:username
    userId = $script:targetUserId
    pageSize = $script:pageSize
    host = $script:hostPrefix
    logLevel = $script:logLevel
}

Initialize-DashboardSingleInstance
Register-DashboardShutdownHandlers

Write-Host ""
Write-Host "Utente GLPI: $script:username" -ForegroundColor Cyan
$securePassword = Read-Host "Inserisci la password GLPI" -AsSecureString

$script:credential = New-Object System.Management.Automation.PSCredential (
    $script:username,
    $securePassword
)

Write-Log -Level INFO -Message "Autenticazione iniziale in corso..."

try {
    [void](Get-AccessToken)
    Write-Log -Level INFO -Message "Autenticazione iniziale completata"
}
catch {
    $details = Get-ExceptionDetails $_

    Write-Log -Level ERROR -Message "Dashboard non avviata perche autenticazione fallita" -Data @{
        message = $details.message
        statusCode = $details.statusCode
        responseBody = $details.responseBody
    }

    Stop-DashboardServer -Reason "Autenticazione fallita"
    exit 1
}

try {
    Start-LocalServer -Prefix $script:hostPrefix
}
finally {
    Stop-DashboardServer -Reason "Script terminato"
}