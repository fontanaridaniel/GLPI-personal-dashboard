#requires -Version 5.1

$scriptDir = if ($PSScriptRoot) {
    $PSScriptRoot
}
else {
    (Get-Location).Path
}

$envPath = Join-Path $scriptDir ".env"
$dashboardPath = Join-Path $scriptDir "dashboard.html"
$pidPath = Join-Path $scriptDir "dashboard-server.pid.json"

$ticketEndpoint = "Assistance/Ticket"
$ticketTaskEndpointTemplate = "Assistance/Ticket/{0}/Timeline/Task"
$openTicketFilter = "status.id=out=(5,6);is_deleted==false"

$script:httpListener = $null
$script:stopRequested = $false
$script:cancelHandler = $null
$script:exitSubscription = $null

$script:logLevel = "INFO"
$script:hostPrefix = $null
$script:accessToken = $null
$script:taskConcurrency = 6
$script:autoRefreshSeconds = 60

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

    $configuredLevel = if ($script:logLevel) {
        $script:logLevel
    }
    else {
        "INFO"
    }

    if (
        (Get-LogLevelNumber $Level) -lt
        (Get-LogLevelNumber $configuredLevel)
    ) {
        return
    }

    $timestamp = (Get-Date).ToString(
        "yyyy-MM-dd HH:mm:ss.fff"
    )

    $line = "[{0}] [{1}] {2}" -f `
        $timestamp,
        $Level.ToUpperInvariant(),
        $Message

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
            $json = $Data | ConvertTo-Json -Depth 40
            Write-Host $json -ForegroundColor DarkGray
        }
        catch {
            Write-Host ([string]$Data) `
                -ForegroundColor DarkGray
        }
    }
}

function Get-HttpStatusCode {
    param (
        $ErrorRecord
    )

    try {
        if (
            $ErrorRecord.Exception.Response -and
            $ErrorRecord.Exception.Response.StatusCode
        ) {
            return [int]$ErrorRecord.Exception.Response.StatusCode
        }
    }
    catch {}

    return $null
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

        try {
            $body = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }

        if ($body.Length -gt 4000) {
            return (
                $body.Substring(0, 4000) +
                "... [truncated]"
            )
        }

        return $body
    }
    catch {
        return ""
    }
}

function Get-ExceptionDetails {
    param (
        $ErrorRecord
    )

    return [PSCustomObject]@{
        message = $ErrorRecord.Exception.Message
        type = $ErrorRecord.Exception.GetType().FullName
        statusCode = Get-HttpStatusCode $ErrorRecord
        responseBody = Read-ErrorResponseBody $ErrorRecord
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
        timestamp = (Get-Date).ToString(
            "yyyy-MM-dd HH:mm:ss"
        )
    }
}

# =========================
# CLEANUP
# =========================

function Remove-CurrentPidFile {
    try {
        if (-not (Test-Path $pidPath)) {
            return
        }

        $pidData = Get-Content $pidPath -Raw |
            ConvertFrom-Json

        if ([int]$pidData.pid -eq [int]$PID) {
            Remove-Item `
                $pidPath `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
    catch {}
}

function Stop-DashboardServer {
    param (
        [string]$Reason = "Shutdown"
    )

    $script:stopRequested = $true

    try {
        Write-Log `
            -Level INFO `
            -Message "Arresto dashboard locale..." `
            -Data @{
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

    Remove-CurrentPidFile

    if ($null -ne $script:cancelHandler) {
        try {
            [Console]::remove_CancelKeyPress(
                $script:cancelHandler
            )
        }
        catch {}

        $script:cancelHandler = $null
    }

    if ($null -ne $script:exitSubscription) {
        try {
            Unregister-Event `
                -SubscriptionId $script:exitSubscription.Id `
                -ErrorAction SilentlyContinue
        }
        catch {}

        $script:exitSubscription = $null
    }
}

function Register-DashboardShutdownHandlers {
    try {
        $script:cancelHandler =
            [ConsoleCancelEventHandler] {
                param (
                    $Sender,
                    $EventArgs
                )

                $EventArgs.Cancel = $true
                $script:stopRequested = $true

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

        [Console]::add_CancelKeyPress(
            $script:cancelHandler
        )
    }
    catch {
        Write-Log `
            -Level WARN `
            -Message "Impossibile registrare CTRL+C" `
            -Data @{
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
                    Remove-CurrentPidFile
                }
                catch {}
            }
    }
    catch {
        Write-Log `
            -Level WARN `
            -Message "Impossibile registrare l'handler di uscita" `
            -Data @{
                error = $_.Exception.Message
            }
    }
}

function Initialize-DashboardSingleInstance {
    if (Test-Path $pidPath) {
        try {
            $oldPidData = Get-Content $pidPath -Raw |
                ConvertFrom-Json

            $oldPid = [int]$oldPidData.pid
            $oldScriptPath = [string]$oldPidData.scriptPath

            if ($oldPid -ne $PID) {
                $oldProcess = Get-CimInstance `
                    Win32_Process `
                    -Filter "ProcessId = $oldPid" `
                    -ErrorAction SilentlyContinue

                if ($null -ne $oldProcess) {
                    $commandLine =
                        [string]$oldProcess.CommandLine

                    $looksLikeDashboard =
                        ($commandLine -match "server\.ps1") -or
                        (
                            $oldScriptPath -and
                            $commandLine -like "*$oldScriptPath*"
                        )

                    if ($looksLikeDashboard) {
                        Write-Log `
                            -Level WARN `
                            -Message "Arresto del vecchio processo dashboard..." `
                            -Data @{
                                oldPid = $oldPid
                            }

                        Stop-Process `
                            -Id $oldPid `
                            -Force `
                            -ErrorAction Stop

                        Start-Sleep -Milliseconds 800
                    }
                }
            }
        }
        catch {
            Write-Log `
                -Level WARN `
                -Message "PID precedente non valido" `
                -Data @{
                    error = $_.Exception.Message
                }
        }

        Remove-Item `
            $pidPath `
            -Force `
            -ErrorAction SilentlyContinue
    }

    $pidObject = [PSCustomObject]@{
        pid = $PID
        scriptPath = Join-Path $scriptDir "server.ps1"
        folder = $scriptDir
        hostPrefix = $script:hostPrefix
        startedAt = (Get-Date).ToString(
            "yyyy-MM-dd HH:mm:ss"
        )
    }

    $pidObject |
        ConvertTo-Json -Depth 10 |
        Set-Content `
            -Path $pidPath `
            -Encoding UTF8 `
            -Force
}

# =========================
# ENVIRONMENT
# =========================

function Load-Env {
    param (
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        Write-Host `
            "[ERR] File .env non trovato: $Path" `
            -ForegroundColor Red

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

            $value = $matches[2].
                Trim().
                Trim('"').
                Trim("'")

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

    if (
        $EnvVars.ContainsKey($Key) -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$EnvVars[$Key]
        )
    ) {
        return [string]$EnvVars[$Key]
    }

    return $Default
}

function Get-RequiredString {
    param (
        [hashtable]$EnvVars,
        [string]$Key
    )

    $value = Get-EnvValue `
        -EnvVars $EnvVars `
        -Key $Key

    if ([string]::IsNullOrWhiteSpace($value)) {
        Write-Log `
            -Level ERROR `
            -Message "$Key non trovato nel file .env"

        exit 1
    }

    return $value
}

function Get-RequiredInt {
    param (
        [hashtable]$EnvVars,
        [string]$Key
    )

    $value = Get-RequiredString `
        -EnvVars $EnvVars `
        -Key $Key

    $parsed = 0

    if (-not [int]::TryParse($value, [ref]$parsed)) {
        Write-Log `
            -Level ERROR `
            -Message "$Key deve essere un numero" `
            -Data @{
                value = $value
            }

        exit 1
    }

    return $parsed
}

function Get-OptionalInt {
    param (
        [hashtable]$EnvVars,
        [string]$Key,
        [int]$Default,
        [int]$Minimum,
        [int]$Maximum
    )

    $value = Get-EnvValue `
        -EnvVars $EnvVars `
        -Key $Key `
        -Default ([string]$Default)

    $parsed = 0

    if (-not [int]::TryParse($value, [ref]$parsed)) {
        Write-Log `
            -Level ERROR `
            -Message "$Key deve essere un numero" `
            -Data @{
                value = $value
            }

        exit 1
    }

    if ($parsed -lt $Minimum -or $parsed -gt $Maximum) {
        Write-Log `
            -Level ERROR `
            -Message "$Key deve essere compreso tra $Minimum e $Maximum" `
            -Data @{
                value = $parsed
            }

        exit 1
    }

    return $parsed
}

# =========================
# HOST
# =========================

function Get-FreeLocalPort {
    $tcpListener = New-Object `
        System.Net.Sockets.TcpListener `
        (
            [System.Net.IPAddress]::Parse("127.0.0.1"),
            0
        )

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

    $hostValue = Get-EnvValue `
        -EnvVars $EnvVars `
        -Key "HOST" `
        -Default $null

    $portValue = Get-EnvValue `
        -EnvVars $EnvVars `
        -Key "HOST_PORT" `
        -Default "0"

    if (-not [string]::IsNullOrWhiteSpace($hostValue)) {
        if (
            -not $hostValue.StartsWith(
                "http://127.0.0.1:"
            )
        ) {
            Write-Log `
                -Level ERROR `
                -Message "HOST deve usare 127.0.0.1"

            exit 1
        }

        if (-not $hostValue.EndsWith("/")) {
            $hostValue = "$hostValue/"
        }

        return $hostValue
    }

    $port = 0

    if (-not [int]::TryParse($portValue, [ref]$port)) {
        Write-Log `
            -Level ERROR `
            -Message "HOST_PORT deve essere un numero"

        exit 1
    }

    if ($port -eq 0) {
        $port = Get-FreeLocalPort
    }

    if ($port -lt 1 -or $port -gt 65535) {
        Write-Log `
            -Level ERROR `
            -Message "HOST_PORT non valido"

        exit 1
    }

    return "http://127.0.0.1:$port/"
}

# =========================
# HTTP / GLPI
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

        $encodedKey =
            [Uri]::EscapeDataString([string]$key)

        $encodedValue =
            [Uri]::EscapeDataString([string]$value)

        $parts += "$encodedKey=$encodedValue"
    }

    return ($parts -join "&")
}

function New-GlpiToken {
    Write-Log `
        -Level INFO `
        -Message "Richiesta token GLPI..."

    $body = @{
        grant_type = "password"
        client_id = $script:clientId
        client_secret = $script:clientSecret
        username = $script:credential.UserName
        password = $script:credential.
            GetNetworkCredential().
            Password
        scope = $script:scope
    }

    try {
        $response = Invoke-RestMethod `
            -Uri $script:authUrl `
            -Method POST `
            -ContentType "application/x-www-form-urlencoded" `
            -Body $body `
            -ErrorAction Stop

        if (
            [string]::IsNullOrWhiteSpace(
                $response.access_token
            )
        ) {
            throw "La risposta non contiene access_token"
        }

        Write-Log `
            -Level INFO `
            -Message "Token GLPI ricevuto correttamente"

        return $response.access_token
    }
    catch {
        $details = Get-ExceptionDetails $_

        Write-Log `
            -Level ERROR `
            -Message "Autenticazione GLPI fallita" `
            -Data @{
                authUrl = $script:authUrl
                message = $details.message
                statusCode = $details.statusCode
                responseBody = $details.responseBody
            }

        throw
    }
}

function Get-AccessToken {
    if (
        -not [string]::IsNullOrWhiteSpace(
            $script:accessToken
        )
    ) {
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

    if (
        $StatusCode -eq 400 -and
        $ResponseBody -match
        "(?i)invalid oauth token|access token could not be verified"
    ) {
        return $true
    }

    return $false
}

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

    try {
        return Invoke-RestMethod `
            -Uri $Uri `
            -Method GET `
            -Headers @{
                Authorization = "Bearer $token"
                accept = "application/json"
                "Accept-Language" = "en_GB"
            } `
            -ErrorAction Stop
    }
    catch {
        $statusCode = Get-HttpStatusCode $_
        $responseBody = Read-ErrorResponseBody $_

        if (
            Test-GlpiAuthError `
                -StatusCode $statusCode `
                -ResponseBody $responseBody
        ) {
            Write-Log `
                -Level WARN `
                -Message "Token GLPI non valido. Nuova autenticazione..."

            $script:accessToken = $null
            $token = Get-AccessToken

            return Invoke-RestMethod `
                -Uri $Uri `
                -Method GET `
                -Headers @{
                    Authorization = "Bearer $token"
                    accept = "application/json"
                    "Accept-Language" = "en_GB"
                } `
                -ErrorAction Stop
        }

        Write-Log `
            -Level ERROR `
            -Message "GLPI GET fallita" `
            -Data @{
                uri = $Uri
                message = $_.Exception.Message
                statusCode = $statusCode
                responseBody = $responseBody
            }

        throw
    }
}

# =========================
# DATA HELPERS
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

    foreach (
        $propertyName in @(
            "data",
            "items",
            "results",
            "member",
            "hydra:member"
        )
    ) {
        if (
            $Value.PSObject.Properties.Name -contains
            $propertyName
        ) {
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
        if (
            $Object.PSObject.Properties.Name -contains
            $name
        ) {
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

    if (
        $Value -is [int] -or
        $Value -is [long] -or
        $Value -is [decimal]
    ) {
        return [long]$Value
    }

    if ($Value -is [string]) {
        $parsed = 0L

        if (
            [long]::TryParse(
                $Value,
                [ref]$parsed
            )
        ) {
            return $parsed
        }

        return $null
    }

    if (
        $Value.PSObject.Properties.Name -contains
        "id"
    ) {
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

    if (
        $Value.PSObject.Properties.Name -contains
        "name"
    ) {
        return [string]$Value.name
    }

    return [string]$Value
}

function Get-ItemDate {
    param (
        $Item,
        [string[]]$FieldNames
    )

    foreach ($field in $FieldNames) {
        $value = Get-PropValue $Item @($field)

        if ($null -eq $value -or "$value" -eq "") {
            continue
        }

        $parsed = [datetime]::MinValue

        if (
            [datetime]::TryParse(
                [string]$value,
                [ref]$parsed
            )
        ) {
            return $parsed
        }
    }

    return [datetime]::MinValue
}

function Format-DateValue {
    param (
        [datetime]$Date
    )

    if ($Date -eq [datetime]::MinValue) {
        return "data sconosciuta"
    }

    return $Date.ToString("yyyy-MM-dd HH:mm")
}

function Convert-ToPlainText {
    param (
        $Value
    )

    if ($null -eq $Value) {
        return ""
    }

    $text = [string]$Value
    $text = $text -replace "<br\s*/?>", "`n"
    $text = $text -replace "</p>", "`n"
    $text = $text -replace "<[^>]+>", ""
    $text = [System.Net.WebUtility]::HtmlDecode($text)

    return $text.Trim()
}

function Get-TaskData {
    param (
        $Task
    )

    if (
        $Task -and
        $Task.PSObject.Properties.Name -contains "item" -and
        $Task.item
    ) {
        return $Task.item
    }

    return $Task
}

# =========================
# TICKETS AND STATISTICS
# =========================

function Get-AllOpenTickets {
    $endpoint =
        "$script:apiBaseUrl/$ticketEndpoint"

    $allTickets = @()
    $start = 0
    $pageNumber = 1

    while ($true) {
        Write-Log `
            -Level INFO `
            -Message "Lettura ticket pagina $pageNumber" `
            -Data @{
                start = $start
                limit = $script:pageSize
            }

        $response = Invoke-GlpiGet `
            -Uri $endpoint `
            -Query @{
                filter = $openTicketFilter
                start = $start
                limit = $script:pageSize
                sort = "date_creation:desc"
            }

        $ticketsPage = @(Convert-ToArray $response)

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

    Write-Log `
        -Level INFO `
        -Message "Lettura ticket completata" `
        -Data @{
            totalTickets = $allTickets.Count
            pagesRead = $pageNumber
        }

    return @($allTickets)
}

function Get-TicketStatusId {
    param (
        $Ticket
    )

    $status = Get-PropValue `
        $Ticket `
        @("status", "status_id", "statuses_id")

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

    if (
        $statusText -match
        "(?i)pending|sospeso|in attesa"
    ) {
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

    $type = Get-PropValue `
        $Ticket `
        @(
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

    if (
        $typeText -match
        "(?i)incident|incidente|accident"
    ) {
        return 1
    }

    if (
        $typeText -match
        "(?i)request|richiesta"
    ) {
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
        $role = (
            Get-TextValue (
                Get-PropValue $member @("role")
            )
        ).Trim().ToLowerInvariant()

        $memberId = Get-IdValue (
            Get-PropValue $member @("id")
        )

        if (
            $role -eq "assigned" -and
            $null -ne $memberId -and
            [int]$memberId -eq [int]$UserId
        ) {
            return $true
        }
    }

    return $false
}

function Get-DashboardStatsFromTickets {
    param (
        [array]$Tickets
    )

    $totalOpen = $Tickets.Count

    $newAccidents = @(
        $Tickets | Where-Object {
            (Get-TicketStatusId $_) -eq 1 -and
            (Get-TicketTypeId $_) -eq 1
        }
    ).Count

    $newRequests = @(
        $Tickets | Where-Object {
            (Get-TicketStatusId $_) -eq 1 -and
            (Get-TicketTypeId $_) -eq 2
        }
    ).Count

    $myAssigned = @(
        $Tickets | Where-Object {
            Test-TeamAssignedToUser `
                -Ticket $_ `
                -UserId $script:targetUserId
        }
    ).Count

    return [PSCustomObject]@{
        totaleTicketAperti = [int]$totalOpen
        nuoviIncidenti = [int]$newAccidents
        nuoveRichieste = [int]$newRequests
        assegnatiAMe = [int]$myAssigned
    }
}

# =========================
# TASK HELPERS
# =========================

function Test-TaskBelongsToUser {
    param (
        $Task,
        [int]$UserId
    )

    $taskData = Get-TaskData $Task

    foreach (
        $field in @(
            "user",
            "user_editor",
            "user_tech"
        )
    ) {
        $value = Get-PropValue $taskData @($field)
        $id = Get-IdValue $value

        if (
            $null -ne $id -and
            [int]$id -eq [int]$UserId
        ) {
            return $true
        }
    }

    return $false
}

function Test-TaskIsTodo {
    param (
        $Task
    )

    $taskData = Get-TaskData $Task

    $stateId = Get-IdValue (
        Get-PropValue $taskData @("state")
    )

    return $stateId -ne 2
}

# =========================
# NDJSON STREAM
# =========================

function Set-CommonResponseHeaders {
    param (
        [System.Net.HttpListenerResponse]$Response
    )

    $Response.Headers["Cache-Control"] = "no-store"
    $Response.Headers["Pragma"] = "no-cache"
    $Response.Headers["X-Content-Type-Options"] = "nosniff"
    $Response.Headers["Referrer-Policy"] = "no-referrer"
}

function Start-NdjsonResponse {
    param (
        [System.Net.HttpListenerContext]$Context
    )

    $response = $Context.Response
    $response.StatusCode = 200
    $response.ContentType =
        "application/x-ndjson; charset=utf-8"

    $response.SendChunked = $true
    $response.KeepAlive = $true

    Set-CommonResponseHeaders `
        -Response $response
}

function Write-NdjsonEvent {
    param (
        [System.Net.HttpListenerContext]$Context,
        $Object
    )

    $json = $Object |
        ConvertTo-Json -Depth 50 -Compress

    $bytes = [System.Text.Encoding]::UTF8.GetBytes(
        $json + "`n"
    )

    $Context.Response.OutputStream.Write(
        $bytes,
        0,
        $bytes.Length
    )

    $Context.Response.OutputStream.Flush()
}

# =========================
# CONCURRENT TASK LOADING
# =========================

function Get-DashboardData {
    param (
        [System.Net.HttpListenerContext]$StreamContext = $null
    )

    $started = Get-Date

    # One ticket-list request per dashboard refresh.
    $tickets = @(Get-AllOpenTickets)

    $stats = Get-DashboardStatsFromTickets `
        -Tickets $tickets

    $totals = [PSCustomObject]@{
        chiamate = [int]$tickets.Count
        problemi = 0
        cambiamenti = 0
    }

    $total = $tickets.Count
    $completed = 0

    if ($null -ne $StreamContext) {
        Write-NdjsonEvent `
            -Context $StreamContext `
            -Object ([PSCustomObject]@{
                type = "start"
                completed = 0
                total = $total
                concurrency = $script:taskConcurrency
                stats = $stats
                totals = $totals
            })
    }

    $taskResults = New-Object `
        "System.Collections.Generic.List[object]"

    if ($total -eq 0) {
        $emptyResult = [PSCustomObject]@{
            stats = $stats
            totals = $totals
            chiamate = @()
            problemi = @()
            cambiamenti = @()
            aggiornatoAlle = (Get-Date).ToString(
                "yyyy-MM-dd HH:mm:ss"
            )
            durataMs = 0
        }

        return $emptyResult
    }

    $token = Get-AccessToken

    $workerScript = {
        param (
            [string]$Endpoint,
            [string]$AccessToken
        )

        $ErrorActionPreference = "Stop"

        function Convert-WorkerArray {
            param (
                $Value
            )

            if ($null -eq $Value) {
                return @()
            }

            if ($Value -is [System.Array]) {
                return @($Value)
            }

            foreach (
                $propertyName in @(
                    "data",
                    "items",
                    "results",
                    "member",
                    "hydra:member"
                )
            ) {
                if (
                    $Value.PSObject.Properties.Name -contains
                    $propertyName
                ) {
                    return Convert-WorkerArray `
                        $Value.$propertyName
                }
            }

            return @($Value)
        }

        try {
            $response = Invoke-RestMethod `
                -Uri $Endpoint `
                -Method GET `
                -Headers @{
                    Authorization = "Bearer $AccessToken"
                    accept = "application/json"
                    "Accept-Language" = "en_GB"
                } `
                -ErrorAction Stop

            $tasks = @(Convert-WorkerArray $response)

            [PSCustomObject]@{
                success = $true
                tasks = @($tasks)
                errorMessage = $null
                statusCode = $null
                responseBody = $null
            }
        }
        catch {
            $statusCode = $null
            $responseBody = ""

            try {
                if (
                    $_.Exception.Response -and
                    $_.Exception.Response.StatusCode
                ) {
                    $statusCode =
                        [int]$_.Exception.Response.StatusCode
                }
            }
            catch {}

            try {
                $stream =
                    $_.Exception.Response.GetResponseStream()

                if ($stream) {
                    $reader = New-Object `
                        System.IO.StreamReader($stream)

                    try {
                        $responseBody =
                            $reader.ReadToEnd()
                    }
                    finally {
                        $reader.Dispose()
                    }
                }
            }
            catch {}

            [PSCustomObject]@{
                success = $false
                tasks = @()
                errorMessage = $_.Exception.Message
                statusCode = $statusCode
                responseBody = $responseBody
            }
        }
    }

    $runspacePool = [runspacefactory]::CreateRunspacePool(
        1,
        $script:taskConcurrency
    )

    $runspacePool.Open()

    $jobs = New-Object System.Collections.ArrayList

    try {
        foreach ($ticket in $tickets) {
            $ticketId = Get-IdValue (
                Get-PropValue $ticket @("id")
            )

            if ($null -eq $ticketId) {
                $completed++

                if ($null -ne $StreamContext) {
                    Write-NdjsonEvent `
                        -Context $StreamContext `
                        -Object ([PSCustomObject]@{
                            type = "progress"
                            completed = $completed
                            total = $total
                        })
                }

                continue
            }

            $ticketTitle = Get-PropValue `
                $ticket `
                @("name", "title")

            if (-not $ticketTitle) {
                $ticketTitle = "(senza titolo)"
            }

            $relativeEndpoint =
                $ticketTaskEndpointTemplate -f $ticketId

            $endpoint =
                "$script:apiBaseUrl/$relativeEndpoint"

            $powerShell = [powershell]::Create()
            $powerShell.RunspacePool = $runspacePool

            [void]$powerShell.AddScript(
                $workerScript.ToString()
            )

            [void]$powerShell.AddArgument($endpoint)
            [void]$powerShell.AddArgument($token)

            $handle = $powerShell.BeginInvoke()

            [void]$jobs.Add(
                [PSCustomObject]@{
                    PowerShell = $powerShell
                    Handle = $handle
                    TicketId = [int]$ticketId
                    TicketTitle = [string]$ticketTitle
                    Endpoint = $endpoint
                }
            )
        }

        while ($jobs.Count -gt 0) {
            $finishedJobs = @(
                $jobs | Where-Object {
                    $_.Handle.IsCompleted
                }
            )

            if ($finishedJobs.Count -eq 0) {
                Start-Sleep -Milliseconds 40
                continue
            }

            foreach ($job in $finishedJobs) {
                try {
                    $workerOutput =
                        $job.PowerShell.EndInvoke(
                            $job.Handle
                        )

                    $workerResult = $null

                    if ($workerOutput.Count -gt 0) {
                        $workerResult =
                            $workerOutput[
                                $workerOutput.Count - 1
                            ]
                    }

                    if (
                        $null -ne $workerResult -and
                        $workerResult.success
                    ) {
                        foreach (
                            $task in @(
                                Convert-ToArray `
                                    $workerResult.tasks
                            )
                        ) {
                            if (
                                -not (
                                    Test-TaskBelongsToUser `
                                        -Task $task `
                                        -UserId $script:targetUserId
                                )
                            ) {
                                continue
                            }

                            if (
                                -not (
                                    Test-TaskIsTodo -Task $task
                                )
                            ) {
                                continue
                            }

                            $taskData = Get-TaskData $task

                            $taskId = Get-IdValue (
                                Get-PropValue `
                                    $taskData `
                                    @("id")
                            )

                            if ($null -eq $taskId) {
                                continue
                            }

                            $taskDate = Get-ItemDate `
                                $taskData `
                                @(
                                    "date_creation",
                                    "date",
                                    "begin",
                                    "date_mod"
                                )

                            $content = Convert-ToPlainText (
                                Get-PropValue `
                                    $taskData `
                                    @(
                                        "content",
                                        "description",
                                        "text"
                                    )
                            )

                            if (-not $content) {
                                $content = "(senza contenuto)"
                            }

                            $taskResults.Add(
                                [PSCustomObject]@{
                                    sortDate = $taskDate
                                    ticketId = $job.TicketId
                                    ticketTitle = $job.TicketTitle
                                    ticketUrl = (
                                        "$script:glpiWebBaseUrl" +
                                        "/front/ticket.form.php" +
                                        "?id=$($job.TicketId)"
                                    )
                                    taskId = [int]$taskId
                                    taskDate = Format-DateValue `
                                        $taskDate
                                    content = [string]$content
                                }
                            )
                        }
                    }
                    elseif ($null -ne $workerResult) {
                        Write-Log `
                            -Level WARN `
                            -Message "Errore lettura attività ticket" `
                            -Data @{
                                ticketId = $job.TicketId
                                message =
                                    $workerResult.errorMessage
                                statusCode =
                                    $workerResult.statusCode
                                responseBody =
                                    $workerResult.responseBody
                            }
                    }
                }
                catch {
                    Write-Log `
                        -Level WARN `
                        -Message "Errore runspace attività ticket" `
                        -Data @{
                            ticketId = $job.TicketId
                            message = $_.Exception.Message
                        }
                }
                finally {
                    $completed++

                    if ($null -ne $StreamContext) {
                        Write-NdjsonEvent `
                            -Context $StreamContext `
                            -Object ([PSCustomObject]@{
                                type = "progress"
                                completed = $completed
                                total = $total
                            })
                    }

                    try {
                        $job.PowerShell.Dispose()
                    }
                    catch {}

                    [void]$jobs.Remove($job)
                }
            }
        }
    }
    finally {
        foreach ($job in @($jobs)) {
            try {
                $job.PowerShell.Stop()
            }
            catch {}

            try {
                $job.PowerShell.Dispose()
            }
            catch {}
        }

        try {
            $runspacePool.Close()
        }
        catch {}

        try {
            $runspacePool.Dispose()
        }
        catch {}
    }

    $sortedResults = @(
        $taskResults |
            Sort-Object `
                @{
                    Expression = { $_.sortDate }
                    Descending = $true
                },
                @{
                    Expression = { $_.ticketId }
                    Descending = $true
                }
    )

    $publicResults = @(
        $sortedResults |
            Select-Object `
                ticketId,
                ticketTitle,
                ticketUrl,
                taskId,
                taskDate,
                content
    )

    $elapsedMs = [int](
        ((Get-Date) - $started).TotalMilliseconds
    )

    Write-Log `
        -Level INFO `
        -Message "Dashboard aggiornata" `
        -Data @{
            tickets = $total
            tasks = $publicResults.Count
            concurrency = $script:taskConcurrency
            elapsedMs = $elapsedMs
        }

    return [PSCustomObject]@{
        stats = $stats
        totals = $totals
        chiamate = @($publicResults)
        problemi = @()
        cambiamenti = @()
        aggiornatoAlle = (Get-Date).ToString(
            "yyyy-MM-dd HH:mm:ss"
        )
        durataMs = $elapsedMs
    }
}

# =========================
# WEB RESPONSES
# =========================

function Get-DashboardHtml {
    $html = Get-Content `
        -Path $dashboardPath `
        -Raw `
        -Encoding UTF8

    return $html.Replace(
        "__AUTO_REFRESH_SECONDS__",
        [string]$script:autoRefreshSeconds
    )
}

function Send-Response {
    param (
        [System.Net.HttpListenerContext]$Context,
        [int]$StatusCode,
        [string]$Body,
        [string]$ContentType
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes(
        $Body
    )

    $response = $Context.Response
    $response.StatusCode = $StatusCode
    $response.ContentType =
        "$ContentType; charset=utf-8"

    $response.ContentLength64 = $bytes.Length

    Set-CommonResponseHeaders `
        -Response $response

    $response.Headers["Content-Security-Policy"] =
        "default-src 'self'; " +
        "script-src 'self' 'unsafe-inline'; " +
        "style-src 'self' 'unsafe-inline'; " +
        "connect-src 'self'; " +
        "img-src 'self'; " +
        "object-src 'none'; " +
        "base-uri 'none'; " +
        "frame-ancestors 'none'"

    if ($bytes.Length -gt 0) {
        $response.OutputStream.Write(
            $bytes,
            0,
            $bytes.Length
        )
    }

    $response.OutputStream.Close()
}

function Send-Json {
    param (
        [System.Net.HttpListenerContext]$Context,
        $Object,
        [int]$StatusCode = 200
    )

    $json = $Object |
        ConvertTo-Json -Depth 50 -Compress

    Send-Response `
        -Context $Context `
        -StatusCode $StatusCode `
        -Body $json `
        -ContentType "application/json"
}

# =========================
# ROUTES
# =========================

function Handle-Request {
    param (
        [System.Net.HttpListenerContext]$Context,
        [string]$RequestId
    )

    $request = $Context.Request
    $path = $request.Url.AbsolutePath.ToLowerInvariant()

    if ($request.HttpMethod -ne "GET") {
        Send-Response `
            -Context $Context `
            -StatusCode 405 `
            -Body "Metodo non consentito" `
            -ContentType "text/plain"

        return
    }

    switch ($path) {
        "/" {
            Send-Response `
                -Context $Context `
                -StatusCode 200 `
                -Body (Get-DashboardHtml) `
                -ContentType "text/html"
        }

        "/dashboard.html" {
            Send-Response `
                -Context $Context `
                -StatusCode 200 `
                -Body (Get-DashboardHtml) `
                -ContentType "text/html"
        }

        "/api/dashboard" {
            $data = Get-DashboardData

            Send-Json `
                -Context $Context `
                -Object $data
        }

        "/api/dashboard/stream" {
            Start-NdjsonResponse -Context $Context

            try {
                $data = Get-DashboardData `
                    -StreamContext $Context

                Write-NdjsonEvent `
                    -Context $Context `
                    -Object ([PSCustomObject]@{
                        type = "result"
                        data = $data
                    })
            }
            catch {
                Write-Log `
                    -Level ERROR `
                    -Message "Errore stream dashboard" `
                    -Data @{
                        requestId = $RequestId
                        message = $_.Exception.Message
                    }

                try {
                    Write-NdjsonEvent `
                        -Context $Context `
                        -Object ([PSCustomObject]@{
                            type = "error"
                            message = $_.Exception.Message
                        })
                }
                catch {}
            }
            finally {
                try {
                    $Context.Response.OutputStream.Close()
                }
                catch {}
            }
        }

        "/api/health" {
            Send-Json `
                -Context $Context `
                -Object ([PSCustomObject]@{
                    ok = $true
                    authenticated =
                        -not [string]::IsNullOrWhiteSpace(
                            $script:accessToken
                        )
                    taskConcurrency =
                        $script:taskConcurrency
                    autoRefreshSeconds =
                        $script:autoRefreshSeconds
                    time = (Get-Date).ToString(
                        "yyyy-MM-dd HH:mm:ss"
                    )
                })
        }

        "/favicon.ico" {
            Send-Response `
                -Context $Context `
                -StatusCode 204 `
                -Body "" `
                -ContentType "text/plain"
        }

        default {
            Send-Response `
                -Context $Context `
                -StatusCode 404 `
                -Body "Non trovato" `
                -ContentType "text/plain"
        }
    }
}

# =========================
# LOCAL SERVER
# =========================

function Start-LocalServer {
    param (
        [string]$Prefix
    )

    if (
        -not $Prefix.StartsWith(
            "http://127.0.0.1:"
        )
    ) {
        Write-Log `
            -Level ERROR `
            -Message "Il server deve usare 127.0.0.1"

        exit 1
    }

    if (-not $Prefix.EndsWith("/")) {
        $Prefix = "$Prefix/"
    }

    if (-not (Test-Path $dashboardPath)) {
        Write-Log `
            -Level ERROR `
            -Message "dashboard.html non trovato" `
            -Data @{
                dashboardPath = $dashboardPath
            }

        exit 1
    }

    $script:httpListener =
        New-Object System.Net.HttpListener

    $script:httpListener.Prefixes.Add($Prefix)

    try {
        $script:httpListener.Start()
    }
    catch {
        $details = Get-ExceptionDetails $_

        Write-Log `
            -Level ERROR `
            -Message "Impossibile avviare il server locale" `
            -Data @{
                prefix = $Prefix
                message = $details.message
                type = $details.type
            }

        exit 1
    }

    Write-Log `
        -Level INFO `
        -Message "Web service locale avviato" `
        -Data @{
            dashboard = $Prefix
            taskConcurrency = $script:taskConcurrency
            autoRefreshSeconds =
                $script:autoRefreshSeconds
            pid = $PID
        }

    Write-Host ""

    Write-Host `
        "Dashboard: $Prefix" `
        -ForegroundColor Green

    Write-Host `
        "Premi CTRL+C per fermare." `
        -ForegroundColor DarkCyan

    while (
        $script:httpListener -and
        $script:httpListener.IsListening -and
        -not $script:stopRequested
    ) {
        $context = $null

        $requestId =
            [guid]::NewGuid().
                ToString("N").
                Substring(0, 8)

        $started = Get-Date

        try {
            $context =
                $script:httpListener.GetContext()
        }
        catch [System.Net.HttpListenerException] {
            if ($script:stopRequested) {
                break
            }

            Write-Log `
                -Level WARN `
                -Message "Listener HTTP interrotto" `
                -Data @{
                    error = $_.Exception.Message
                }

            break
        }
        catch [System.ObjectDisposedException] {
            break
        }

        if ($null -eq $context) {
            continue
        }

        $request = $context.Request

        Write-Log `
            -Level INFO `
            -Message "Richiesta ricevuta" `
            -Data @{
                requestId = $requestId
                method = $request.HttpMethod
                path = $request.Url.AbsolutePath
                remote =
                    $request.RemoteEndPoint.ToString()
            }

        try {
            Handle-Request `
                -Context $context `
                -RequestId $requestId

            $elapsedMs = [int](
                ((Get-Date) - $started).
                    TotalMilliseconds
            )

            Write-Log `
                -Level INFO `
                -Message "Richiesta completata" `
                -Data @{
                    requestId = $requestId
                    path = $request.Url.AbsolutePath
                    elapsedMs = $elapsedMs
                }
        }
        catch {
            $details = Get-ExceptionDetails $_

            Write-Log `
                -Level ERROR `
                -Message "Richiesta fallita" `
                -Data @{
                    requestId = $requestId
                    path = $request.Url.AbsolutePath
                    message = $details.message
                    type = $details.type
                    statusCode = $details.statusCode
                    responseBody =
                        $details.responseBody
                    stack =
                        $details.scriptStackTrace
                }

            try {
                $errorObject = New-ErrorResponseObject `
                    -ErrorRecord $_ `
                    -PublicMessage "Errore interno durante la richiesta" `
                    -RequestId $requestId

                Send-Json `
                    -Context $context `
                    -Object $errorObject `
                    -StatusCode 500
            }
            catch {}
        }
    }
}

# =========================
# MAIN
# =========================

$envVars = Load-Env $envPath

$script:logLevel = Get-EnvValue `
    -EnvVars $envVars `
    -Key "LOG_LEVEL" `
    -Default "INFO"

$script:apiBaseUrl = (
    Get-RequiredString `
        -EnvVars $envVars `
        -Key "GLPI_API_BASE_URL"
).TrimEnd("/")

$script:authUrl = Get-RequiredString `
    -EnvVars $envVars `
    -Key "GLPI_AUTH_URL"

$script:glpiWebBaseUrl = (
    Get-RequiredString `
        -EnvVars $envVars `
        -Key "GLPI_WEB_BASE_URL"
).TrimEnd("/")

$script:clientId = Get-RequiredString `
    -EnvVars $envVars `
    -Key "CLIENT_ID"

$script:clientSecret = Get-RequiredString `
    -EnvVars $envVars `
    -Key "CLIENT_SECRET"

$script:username = Get-RequiredString `
    -EnvVars $envVars `
    -Key "USERNAME"

$script:targetUserId = Get-RequiredInt `
    -EnvVars $envVars `
    -Key "USER_ID"

$script:scope = Get-EnvValue `
    -EnvVars $envVars `
    -Key "SCOPE" `
    -Default "email user api inventory status graphql"

$script:pageSize = Get-OptionalInt `
    -EnvVars $envVars `
    -Key "PAGE_SIZE" `
    -Default 100 `
    -Minimum 1 `
    -Maximum 1000

$script:taskConcurrency = Get-OptionalInt `
    -EnvVars $envVars `
    -Key "TASK_CONCURRENCY" `
    -Default 6 `
    -Minimum 1 `
    -Maximum 20

$script:autoRefreshSeconds = Get-OptionalInt `
    -EnvVars $envVars `
    -Key "AUTO_REFRESH_SECONDS" `
    -Default 60 `
    -Minimum 10 `
    -Maximum 3600

$script:hostPrefix = Resolve-LocalHostPrefix `
    -EnvVars $envVars

Write-Log `
    -Level INFO `
    -Message "Configurazione caricata" `
    -Data @{
        apiBaseUrl = $script:apiBaseUrl
        authUrl = $script:authUrl
        webBaseUrl = $script:glpiWebBaseUrl
        username = $script:username
        userId = $script:targetUserId
        pageSize = $script:pageSize
        taskConcurrency = $script:taskConcurrency
        autoRefreshSeconds =
            $script:autoRefreshSeconds
        host = $script:hostPrefix
        logLevel = $script:logLevel
    }

Initialize-DashboardSingleInstance
Register-DashboardShutdownHandlers

Write-Host ""

Write-Host `
    "Utente GLPI: $script:username" `
    -ForegroundColor Cyan

$securePassword = Read-Host `
    "Inserisci la password GLPI" `
    -AsSecureString

$script:credential =
    New-Object System.Management.Automation.PSCredential(
        $script:username,
        $securePassword
    )

try {
    [void](Get-AccessToken)

    Write-Log `
        -Level INFO `
        -Message "Autenticazione iniziale completata"
}
catch {
    Stop-DashboardServer `
        -Reason "Autenticazione fallita"

    exit 1
}

try {
    Start-LocalServer `
        -Prefix $script:hostPrefix
}
finally {
    Stop-DashboardServer `
        -Reason "Script terminato"
}