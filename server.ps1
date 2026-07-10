#requires -Version 5.1

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$envPath = Join-Path $scriptDir ".env"
$dashboardPath = Join-Path $scriptDir "dashboard.html"
$listPath = Join-Path $scriptDir "list.html"
$pidPath = Join-Path $scriptDir "dashboard-server.pid.json"

$ticketResourcePath = "Assistance/Ticket"
$problemResourcePath = "Assistance/Problem"
$changeResourcePath = "Assistance/Change"

$ticketTaskEndpointTemplate = "Assistance/Ticket/{0}/Timeline/Task"
$problemTaskEndpointTemplate = "Assistance/Problem/{0}/Timeline/Task"
$changeTaskEndpointTemplate = "Assistance/Change/{0}/Timeline/Task"

$openItemFilter = "status.id=out=(5,6);is_deleted==false"

$script:httpListener = $null
$script:stopRequested = $false
$script:cancelHandler = $null
$script:exitSubscription = $null
$script:accessToken = $null
$script:logLevel = "INFO"
$script:taskConcurrency = 6
$script:autoRefreshSeconds = 60

# =========================
# LOGGING / ERRORS
# =========================

function Get-LogLevelNumber {
    param ([string]$Level)

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

    if ((Get-LogLevelNumber $Level) -lt (Get-LogLevelNumber $script:logLevel)) {
        return
    }

    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
    $line = "[{0}] [{1}] {2}" -f $timestamp, $Level.ToUpperInvariant(), $Message

    $color = switch ($Level.ToUpperInvariant()) {
        "DEBUG" { "DarkGray" }
        "INFO"  { "Cyan" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "White" }
    }

    Write-Host $line -ForegroundColor $color

    if ($null -ne $Data) {
        try {
            Write-Host ($Data | ConvertTo-Json -Depth 60) -ForegroundColor DarkGray
        }
        catch {
            Write-Host ([string]$Data) -ForegroundColor DarkGray
        }
    }
}

function Get-HttpStatusCode {
    param ($ErrorRecord)

    try {
        if ($ErrorRecord.Exception.Response -and $ErrorRecord.Exception.Response.StatusCode) {
            return [int]$ErrorRecord.Exception.Response.StatusCode
        }
    }
    catch {}

    return $null
}

function Read-ErrorResponseBody {
    param ($ErrorRecord)

    try {
        $response = $ErrorRecord.Exception.Response
        if ($null -eq $response) { return "" }

        $stream = $response.GetResponseStream()
        if ($null -eq $stream) { return "" }

        $reader = [System.IO.StreamReader]::new($stream)
        try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }

        if ($body.Length -gt 4000) {
            return $body.Substring(0, 4000) + "... [truncated]"
        }

        return $body
    }
    catch {
        return ""
    }
}

function Get-ExceptionDetails {
    param ($ErrorRecord)

    return [PSCustomObject]@{
        message = $ErrorRecord.Exception.Message
        type = $ErrorRecord.Exception.GetType().FullName
        statusCode = Get-HttpStatusCode $ErrorRecord
        responseBody = Read-ErrorResponseBody $ErrorRecord
        scriptStackTrace = $ErrorRecord.ScriptStackTrace
    }
}

# =========================
# ENVIRONMENT
# =========================

function Load-Env {
    param ([string]$Path)

    if (-not (Test-Path $Path)) {
        Write-Host "[ERR] File .env non trovato: $Path" -ForegroundColor Red
        exit 1
    }

    $values = @{}

    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()

        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
            return
        }

        if ($line -match "^\s*([^#][^=]+)=(.*)$") {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim().Trim('"').Trim("'")
            $values[$key] = $value
        }
    }

    return $values
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
    param ([hashtable]$EnvVars, [string]$Key)

    $value = Get-EnvValue -EnvVars $EnvVars -Key $Key

    if ([string]::IsNullOrWhiteSpace($value)) {
        Write-Log -Level ERROR -Message "$Key non trovato nel file .env"
        exit 1
    }

    return $value
}

function Get-RequiredInt {
    param ([hashtable]$EnvVars, [string]$Key)

    $value = Get-RequiredString -EnvVars $EnvVars -Key $Key
    $parsed = 0

    if (-not [int]::TryParse($value, [ref]$parsed)) {
        Write-Log -Level ERROR -Message "$Key deve essere un numero" -Data @{ value = $value }
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

    $value = Get-EnvValue -EnvVars $EnvVars -Key $Key -Default ([string]$Default)
    $parsed = 0

    if (-not [int]::TryParse($value, [ref]$parsed)) {
        Write-Log -Level ERROR -Message "$Key deve essere un numero" -Data @{ value = $value }
        exit 1
    }

    if ($parsed -lt $Minimum -or $parsed -gt $Maximum) {
        Write-Log -Level ERROR -Message "$Key deve essere compreso tra $Minimum e $Maximum" -Data @{ value = $parsed }
        exit 1
    }

    return $parsed
}

function Normalize-GlpiWebBaseUrl {
    param ([string]$Value)

    $normalized = ($Value + "").Trim().TrimEnd("/")
    $normalized = $normalized -replace "(?i)/api\.php(?:/.*)?$", ""

    if ([string]::IsNullOrWhiteSpace($normalized)) {
        Write-Log -Level ERROR -Message "GLPI_WEB_BASE_URL non valido"
        exit 1
    }

    return $normalized.TrimEnd("/")
}

# =========================
# HOST / SHUTDOWN
# =========================

function Get-FreeLocalPort {
    $listener = [System.Net.Sockets.TcpListener]::new(
        [System.Net.IPAddress]::Parse("127.0.0.1"),
        0
    )

    try {
        $listener.Start()
        return [int]$listener.LocalEndpoint.Port
    }
    finally {
        $listener.Stop()
    }
}

function Resolve-LocalHostPrefix {
    param ([hashtable]$EnvVars)

    $hostValue = Get-EnvValue -EnvVars $EnvVars -Key "HOST" -Default $null
    $portValue = Get-EnvValue -EnvVars $EnvVars -Key "HOST_PORT" -Default "0"

    if (-not [string]::IsNullOrWhiteSpace($hostValue)) {
        if (-not $hostValue.StartsWith("http://127.0.0.1:")) {
            Write-Log -Level ERROR -Message "HOST deve usare 127.0.0.1"
            exit 1
        }

        if (-not $hostValue.EndsWith("/")) { $hostValue += "/" }
        return $hostValue
    }

    $port = 0
    if (-not [int]::TryParse($portValue, [ref]$port)) {
        Write-Log -Level ERROR -Message "HOST_PORT deve essere un numero"
        exit 1
    }

    if ($port -eq 0) { $port = Get-FreeLocalPort }

    if ($port -lt 1 -or $port -gt 65535) {
        Write-Log -Level ERROR -Message "HOST_PORT non valido"
        exit 1
    }

    return "http://127.0.0.1:$port/"
}

function Remove-CurrentPidFile {
    try {
        if (-not (Test-Path $pidPath)) { return }

        $pidData = Get-Content $pidPath -Raw | ConvertFrom-Json
        if ([int]$pidData.pid -eq [int]$PID) {
            Remove-Item $pidPath -Force -ErrorAction SilentlyContinue
        }
    }
    catch {}
}

function Stop-DashboardServer {
    param ([string]$Reason = "Shutdown")

    $script:stopRequested = $true

    try {
        Write-Log -Level INFO -Message "Arresto dashboard locale..." -Data @{ reason = $Reason; pid = $PID }
    }
    catch {}

    if ($null -ne $script:httpListener) {
        try { if ($script:httpListener.IsListening) { $script:httpListener.Stop() } } catch {}
        try { $script:httpListener.Close() } catch {}
        $script:httpListener = $null
    }

    Remove-CurrentPidFile

    if ($null -ne $script:cancelHandler) {
        try { [Console]::remove_CancelKeyPress($script:cancelHandler) } catch {}
        $script:cancelHandler = $null
    }

    if ($null -ne $script:exitSubscription) {
        try {
            Unregister-Event -SubscriptionId $script:exitSubscription.Id -ErrorAction SilentlyContinue
        }
        catch {}
        $script:exitSubscription = $null
    }
}

function Register-DashboardShutdownHandlers {
    try {
        $script:cancelHandler = [ConsoleCancelEventHandler] {
            param ($Sender, $EventArgs)

            $EventArgs.Cancel = $true
            $script:stopRequested = $true

            try {
                if ($script:httpListener) {
                    if ($script:httpListener.IsListening) { $script:httpListener.Stop() }
                    $script:httpListener.Close()
                }
            }
            catch {}
        }

        [Console]::add_CancelKeyPress($script:cancelHandler)
    }
    catch {
        Write-Log -Level WARN -Message "Impossibile registrare CTRL+C" -Data @{ error = $_.Exception.Message }
    }

    try {
        $script:exitSubscription = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
            try {
                if ($script:httpListener) {
                    if ($script:httpListener.IsListening) { $script:httpListener.Stop() }
                    $script:httpListener.Close()
                }
            }
            catch {}
        }
    }
    catch {
        Write-Log -Level WARN -Message "Impossibile registrare l'handler di uscita" -Data @{ error = $_.Exception.Message }
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
                    $isDashboard = ($commandLine -match "server\.ps1") -or ($oldScriptPath -and $commandLine -like "*$oldScriptPath*")

                    if ($isDashboard) {
                        Write-Log -Level WARN -Message "Arresto del vecchio processo dashboard..." -Data @{ oldPid = $oldPid }
                        Stop-Process -Id $oldPid -Force -ErrorAction Stop
                        Start-Sleep -Milliseconds 800
                    }
                }
            }
        }
        catch {
            Write-Log -Level WARN -Message "PID precedente non valido" -Data @{ error = $_.Exception.Message }
        }

        Remove-Item $pidPath -Force -ErrorAction SilentlyContinue
    }

    [PSCustomObject]@{
        pid = $PID
        scriptPath = Join-Path $scriptDir "server.ps1"
        folder = $scriptDir
        hostPrefix = $script:hostPrefix
        startedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    } | ConvertTo-Json -Depth 10 | Set-Content -Path $pidPath -Encoding UTF8 -Force
}

# =========================
# GLPI AUTH / REQUESTS
# =========================

function New-QueryString {
    param ([hashtable]$Params)

    if (-not $Params -or $Params.Count -eq 0) { return "" }

    $parts = @()
    foreach ($key in $Params.Keys) {
        $value = $Params[$key]
        if ($null -eq $value -or "$value" -eq "") { continue }

        $parts += "{0}={1}" -f `
            [Uri]::EscapeDataString([string]$key), `
            [Uri]::EscapeDataString([string]$value)
    }

    return ($parts -join "&")
}

function New-GlpiToken {
    Write-Log -Level INFO -Message "Richiesta token GLPI..."

    $body = @{
        grant_type = "password"
        client_id = $script:clientId
        client_secret = $script:clientSecret
        username = $script:credential.UserName
        password = $script:credential.GetNetworkCredential().Password
        scope = $script:scope
    }

    try {
        $response = Invoke-RestMethod `
            -Uri $script:authUrl `
            -Method POST `
            -ContentType "application/x-www-form-urlencoded" `
            -Body $body `
            -ErrorAction Stop

        if ([string]::IsNullOrWhiteSpace($response.access_token)) {
            throw "La risposta non contiene access_token"
        }

        Write-Log -Level INFO -Message "Token GLPI ricevuto correttamente"
        return $response.access_token
    }
    catch {
        $details = Get-ExceptionDetails $_
        Write-Log -Level ERROR -Message "Autenticazione GLPI fallita" -Data $details
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
    param ([int]$StatusCode, [string]$ResponseBody)

    if ($StatusCode -eq 401) { return $true }

    return (
        $StatusCode -eq 400 -and
        $ResponseBody -match "(?i)invalid oauth token|access token could not be verified"
    )
}

function Invoke-GlpiGet {
    param (
        [string]$Uri,
        [hashtable]$Query = @{}
    )

    $queryString = New-QueryString $Query
    if ($queryString) { $Uri = "$Uri`?$queryString" }

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

        if (Test-GlpiAuthError -StatusCode $statusCode -ResponseBody $responseBody) {
            Write-Log -Level WARN -Message "Token GLPI non valido. Nuova autenticazione..."
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
# DATA HELPERS
# =========================

function Convert-ToArray {
    param ($Value)

    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Array]) { return @($Value) }

    foreach ($propertyName in @("data", "items", "results", "member", "hydra:member")) {
        if ($Value.PSObject.Properties.Name -contains $propertyName) {
            return Convert-ToArray $Value.$propertyName
        }
    }

    return @($Value)
}

function Get-PropValue {
    param ($Object, [string[]]$Names)

    if ($null -eq $Object) { return $null }

    foreach ($name in $Names) {
        if ($Object.PSObject.Properties.Name -contains $name) {
            return $Object.$name
        }
    }

    return $null
}

function Get-IdValue {
    param ($Value)

    if ($null -eq $Value) { return $null }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [decimal]) {
        return [long]$Value
    }

    if ($Value -is [string]) {
        $parsed = 0L
        if ([long]::TryParse($Value, [ref]$parsed)) { return $parsed }
        return $null
    }

    if ($Value.PSObject.Properties.Name -contains "id") {
        return Get-IdValue $Value.id
    }

    return $null
}

function Get-TextValue {
    param ($Value)

    if ($null -eq $Value) { return "" }

    if ($Value.PSObject.Properties.Name -contains "name") {
        return [string]$Value.name
    }

    return [string]$Value
}

function Get-ItemDate {
    param ($Item, [string[]]$FieldNames)

    foreach ($field in $FieldNames) {
        $value = Get-PropValue $Item @($field)
        if ($null -eq $value -or "$value" -eq "") { continue }

        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse([string]$value, [ref]$parsed)) { return $parsed }
    }

    return [datetime]::MinValue
}

function Format-DateValue {
    param ([datetime]$Date)

    if ($Date -eq [datetime]::MinValue) { return "-" }
    return $Date.ToString("yyyy-MM-dd HH:mm")
}

function Convert-ToPlainText {
    param ($Value)

    if ($null -eq $Value) { return "" }

    $text = [string]$Value
    $text = $text -replace "<br\s*/?>", "`n"
    $text = $text -replace "</p>", "`n"
    $text = $text -replace "<[^>]+>", ""
    $text = [System.Net.WebUtility]::HtmlDecode($text)

    return $text.Trim()
}

function Get-TaskData {
    param ($Task)

    if ($Task -and $Task.PSObject.Properties.Name -contains "item" -and $Task.item) {
        return $Task.item
    }

    return $Task
}

function Get-AllOpenItems {
    param (
        [string]$ResourcePath,
        [string]$LogLabel
    )

    $endpoint = "$script:apiBaseUrl/$ResourcePath"
    $allItems = @()
    $start = 0
    $pageNumber = 1

    while ($true) {
        Write-Log -Level INFO -Message "Lettura $LogLabel pagina $pageNumber" -Data @{
            start = $start
            limit = $script:pageSize
        }

        $response = Invoke-GlpiGet -Uri $endpoint -Query @{
            filter = $openItemFilter
            start = $start
            limit = $script:pageSize
            sort = "date_creation:desc"
        }

        $page = @(Convert-ToArray $response)
        if ($page.Count -eq 0) { break }

        $allItems += $page

        if ($page.Count -lt $script:pageSize) { break }

        $start += $script:pageSize
        $pageNumber++
    }

    Write-Log -Level INFO -Message "Lettura $LogLabel completata" -Data @{
        total = $allItems.Count
        pagesRead = $pageNumber
    }

    return @($allItems)
}

function Get-TicketStatusId {
    param ($Ticket)

    return Get-IdValue (Get-PropValue $Ticket @("status", "status_id", "statuses_id"))
}

function Get-TicketTypeId {
    param ($Ticket)

    return Get-IdValue (Get-PropValue $Ticket @(
        "type",
        "type_id",
        "ticket_type",
        "tickettype",
        "request_type",
        "requesttype"
    ))
}

function Get-ItemStatusText {
    param ($Item)

    $status = Get-PropValue $Item @("status", "status_id", "statuses_id")
    $text = Get-TextValue $status

    if ($text -and $text -notmatch "^\d+$") { return $text }

    switch (Get-IdValue $status) {
        1 { return "Nuovo" }
        2 { return "Assegnato" }
        3 { return "Pianificato" }
        4 { return "In attesa" }
        5 { return "Risolto" }
        6 { return "Chiuso" }
        default { return "-" }
    }
}

function Get-TicketTypeText {
    param ($Ticket)

    $type = Get-PropValue $Ticket @(
        "type",
        "type_id",
        "ticket_type",
        "tickettype",
        "request_type",
        "requesttype"
    )

    $text = Get-TextValue $type
    if ($text -and $text -notmatch "^\d+$") { return $text }

    switch (Get-IdValue $type) {
        1 { return "Incidente" }
        2 { return "Richiesta" }
        default { return "-" }
    }
}

function Test-TeamAssignedToUser {
    param ($Item, [int]$UserId)

    $team = Get-PropValue $Item @("team")
    if ($null -eq $team) { return $false }

    foreach ($member in @(Convert-ToArray $team)) {
        $role = (Get-TextValue (Get-PropValue $member @("role"))).Trim().ToLowerInvariant()
        $memberId = Get-IdValue (Get-PropValue $member @("id"))

        if ($role -eq "assigned" -and $null -ne $memberId -and [int]$memberId -eq $UserId) {
            return $true
        }
    }

    return $false
}

function Get-DashboardStatsFromTickets {
    param ([array]$Tickets)

    return [PSCustomObject]@{
        totaleTicketAperti = [int]$Tickets.Count
        nuoviIncidenti = [int](@($Tickets | Where-Object {
            (Get-TicketStatusId $_) -eq 1 -and (Get-TicketTypeId $_) -eq 1
        }).Count)
        nuoveRichieste = [int](@($Tickets | Where-Object {
            (Get-TicketStatusId $_) -eq 1 -and (Get-TicketTypeId $_) -eq 2
        }).Count)
        assegnatiAMe = [int](@($Tickets | Where-Object {
            Test-TeamAssignedToUser -Item $_ -UserId $script:targetUserId
        }).Count)
    }
}

function Test-TaskBelongsToUser {
    param ($Task, [int]$UserId)

    $taskData = Get-TaskData $Task

    foreach ($field in @("user", "user_editor", "user_tech")) {
        $id = Get-IdValue (Get-PropValue $taskData @($field))
        if ($null -ne $id -and [int]$id -eq $UserId) { return $true }
    }

    return $false
}

function Test-TaskIsTodo {
    param ($Task)

    $taskData = Get-TaskData $Task
    return (Get-IdValue (Get-PropValue $taskData @("state"))) -ne 2
}

# =========================
# STREAMING
# =========================

function Set-CommonResponseHeaders {
    param ([System.Net.HttpListenerResponse]$Response)

    $Response.Headers["Cache-Control"] = "no-store"
    $Response.Headers["Pragma"] = "no-cache"
    $Response.Headers["X-Content-Type-Options"] = "nosniff"
    $Response.Headers["Referrer-Policy"] = "no-referrer"
}

function Start-NdjsonResponse {
    param ([System.Net.HttpListenerContext]$Context)

    $response = $Context.Response
    $response.StatusCode = 200
    $response.ContentType = "application/x-ndjson; charset=utf-8"
    $response.SendChunked = $true
    $response.KeepAlive = $true
    Set-CommonResponseHeaders -Response $response
}

function Write-NdjsonEvent {
    param (
        [System.Net.HttpListenerContext]$Context,
        $Object
    )

    $json = $Object | ConvertTo-Json -Depth 60 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json + "`n")

    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Flush()
}

# =========================
# CONCURRENT CATEGORY SCAN
# =========================

function Invoke-TaskCategoryScan {
    param (
        [array]$Items,
        [string]$Category,
        [string]$TaskEndpointTemplate,
        [string]$FormPath,
        [System.Net.HttpListenerContext]$StreamContext = $null
    )

    $total = $Items.Count
    $completed = 0
    $results = New-Object "System.Collections.Generic.List[object]"

    if ($total -eq 0) {
        if ($null -ne $StreamContext) {
            Write-NdjsonEvent -Context $StreamContext -Object ([PSCustomObject]@{
                type = "progress"
                category = $Category
                completed = 0
                total = 0
            })
        }
        return @()
    }

    $token = Get-AccessToken

    $workerScript = {
        param ([string]$Endpoint, [string]$AccessToken)

        $ErrorActionPreference = "Stop"

        function Convert-WorkerArray {
            param ($Value)

            if ($null -eq $Value) { return @() }
            if ($Value -is [System.Array]) { return @($Value) }

            foreach ($propertyName in @("data", "items", "results", "member", "hydra:member")) {
                if ($Value.PSObject.Properties.Name -contains $propertyName) {
                    return Convert-WorkerArray $Value.$propertyName
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

            [PSCustomObject]@{
                success = $true
                tasks = @(Convert-WorkerArray $response)
                errorMessage = $null
                statusCode = $null
                responseBody = $null
            }
        }
        catch {
            $statusCode = $null
            $responseBody = ""

            try {
                if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                }
            }
            catch {}

            try {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) {
                    $reader = [System.IO.StreamReader]::new($stream)
                    try { $responseBody = $reader.ReadToEnd() } finally { $reader.Dispose() }
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

    $runspacePool = [runspacefactory]::CreateRunspacePool(1, $script:taskConcurrency)
    $runspacePool.Open()
    $jobs = New-Object System.Collections.ArrayList

    try {
        foreach ($item in $Items) {
            $parentId = Get-IdValue (Get-PropValue $item @("id"))

            if ($null -eq $parentId) {
                $completed++
                if ($null -ne $StreamContext) {
                    Write-NdjsonEvent -Context $StreamContext -Object ([PSCustomObject]@{
                        type = "progress"
                        category = $Category
                        completed = $completed
                        total = $total
                    })
                }
                continue
            }

            $parentTitle = Get-PropValue $item @("name", "title")
            if (-not $parentTitle) { $parentTitle = "(senza titolo)" }

            $endpoint = "{0}/{1}" -f $script:apiBaseUrl, ($TaskEndpointTemplate -f $parentId)
            $parentUrl = "{0}{1}?id={2}" -f $script:glpiWebBaseUrl.TrimEnd("/"), $FormPath, [int]$parentId

            $powerShell = [powershell]::Create()
            $powerShell.RunspacePool = $runspacePool
            [void]$powerShell.AddScript($workerScript.ToString())
            [void]$powerShell.AddArgument($endpoint)
            [void]$powerShell.AddArgument($token)

            [void]$jobs.Add([PSCustomObject]@{
                PowerShell = $powerShell
                Handle = $powerShell.BeginInvoke()
                ParentId = [int]$parentId
                ParentTitle = [string]$parentTitle
                ParentUrl = $parentUrl
            })
        }

        while ($jobs.Count -gt 0) {
            $finishedJobs = @($jobs | Where-Object { $_.Handle.IsCompleted })

            if ($finishedJobs.Count -eq 0) {
                Start-Sleep -Milliseconds 40
                continue
            }

            foreach ($job in $finishedJobs) {
                try {
                    $output = $job.PowerShell.EndInvoke($job.Handle)
                    $workerResult = if ($output.Count -gt 0) { $output[$output.Count - 1] } else { $null }

                    if ($null -ne $workerResult -and $workerResult.success) {
                        foreach ($task in @(Convert-ToArray $workerResult.tasks)) {
                            if (-not (Test-TaskBelongsToUser -Task $task -UserId $script:targetUserId)) { continue }
                            if (-not (Test-TaskIsTodo -Task $task)) { continue }

                            $taskData = Get-TaskData $task
                            $taskId = Get-IdValue (Get-PropValue $taskData @("id"))
                            if ($null -eq $taskId) { continue }

                            $taskDate = Get-ItemDate $taskData @("date_creation", "date", "begin", "date_mod")
                            $content = Convert-ToPlainText (Get-PropValue $taskData @("content", "description", "text"))
                            if (-not $content) { $content = "(senza contenuto)" }

                            $results.Add([PSCustomObject]@{
                                sortDate = $taskDate
                                parentId = $job.ParentId
                                parentTitle = $job.ParentTitle
                                parentUrl = $job.ParentUrl
                                taskId = [int]$taskId
                                taskDate = Format-DateValue $taskDate
                                content = [string]$content
                            })
                        }
                    }
                    elseif ($null -ne $workerResult) {
                        Write-Log -Level WARN -Message "Errore lettura attività" -Data @{
                            category = $Category
                            parentId = $job.ParentId
                            message = $workerResult.errorMessage
                            statusCode = $workerResult.statusCode
                            responseBody = $workerResult.responseBody
                        }
                    }
                }
                catch {
                    Write-Log -Level WARN -Message "Errore runspace attività" -Data @{
                        category = $Category
                        parentId = $job.ParentId
                        message = $_.Exception.Message
                    }
                }
                finally {
                    $completed++

                    if ($null -ne $StreamContext) {
                        Write-NdjsonEvent -Context $StreamContext -Object ([PSCustomObject]@{
                            type = "progress"
                            category = $Category
                            completed = $completed
                            total = $total
                        })
                    }

                    try { $job.PowerShell.Dispose() } catch {}
                    [void]$jobs.Remove($job)
                }
            }
        }
    }
    finally {
        foreach ($job in @($jobs)) {
            try { $job.PowerShell.Stop() } catch {}
            try { $job.PowerShell.Dispose() } catch {}
        }

        try { $runspacePool.Close() } catch {}
        try { $runspacePool.Dispose() } catch {}
    }

    return @(
        $results |
            Sort-Object `
                @{ Expression = { $_.sortDate }; Descending = $true }, `
                @{ Expression = { $_.parentId }; Descending = $true } |
            Select-Object parentId, parentTitle, parentUrl, taskId, taskDate, content
    )
}

function Get-DashboardData {
    param ([System.Net.HttpListenerContext]$StreamContext = $null)

    $started = Get-Date

    $tickets = @(Get-AllOpenItems -ResourcePath $ticketResourcePath -LogLabel "ticket")
    $problems = @(Get-AllOpenItems -ResourcePath $problemResourcePath -LogLabel "problemi")
    $changes = @(Get-AllOpenItems -ResourcePath $changeResourcePath -LogLabel "cambiamenti")

    $stats = Get-DashboardStatsFromTickets -Tickets $tickets
    $totals = [PSCustomObject]@{
        chiamate = [int]$tickets.Count
        problemi = [int]$problems.Count
        cambiamenti = [int]$changes.Count
    }

    if ($null -ne $StreamContext) {
        Write-NdjsonEvent -Context $StreamContext -Object ([PSCustomObject]@{
            type = "start"
            stats = $stats
            totals = $totals
            concurrency = $script:taskConcurrency
        })
    }

    if ($null -ne $StreamContext) {
        Write-NdjsonEvent -Context $StreamContext -Object ([PSCustomObject]@{
            type = "categoryStart"
            category = "chiamate"
            total = $tickets.Count
        })
    }

    $ticketTasks = @(Invoke-TaskCategoryScan `
        -Items $tickets `
        -Category "chiamate" `
        -TaskEndpointTemplate $ticketTaskEndpointTemplate `
        -FormPath "/front/ticket.form.php" `
        -StreamContext $StreamContext)

    if ($null -ne $StreamContext) {
        Write-NdjsonEvent -Context $StreamContext -Object ([PSCustomObject]@{
            type = "categoryResult"
            category = "chiamate"
            items = @($ticketTasks)
        })
    }

    if ($null -ne $StreamContext) {
        Write-NdjsonEvent -Context $StreamContext -Object ([PSCustomObject]@{
            type = "categoryStart"
            category = "problemi"
            total = $problems.Count
        })
    }

    $problemTasks = @(Invoke-TaskCategoryScan `
        -Items $problems `
        -Category "problemi" `
        -TaskEndpointTemplate $problemTaskEndpointTemplate `
        -FormPath "/front/problem.form.php" `
        -StreamContext $StreamContext)

    if ($null -ne $StreamContext) {
        Write-NdjsonEvent -Context $StreamContext -Object ([PSCustomObject]@{
            type = "categoryResult"
            category = "problemi"
            items = @($problemTasks)
        })
    }

    if ($null -ne $StreamContext) {
        Write-NdjsonEvent -Context $StreamContext -Object ([PSCustomObject]@{
            type = "categoryStart"
            category = "cambiamenti"
            total = $changes.Count
        })
    }

    $changeTasks = @(Invoke-TaskCategoryScan `
        -Items $changes `
        -Category "cambiamenti" `
        -TaskEndpointTemplate $changeTaskEndpointTemplate `
        -FormPath "/front/change.form.php" `
        -StreamContext $StreamContext)

    if ($null -ne $StreamContext) {
        Write-NdjsonEvent -Context $StreamContext -Object ([PSCustomObject]@{
            type = "categoryResult"
            category = "cambiamenti"
            items = @($changeTasks)
        })
    }

    $elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds

    Write-Log -Level INFO -Message "Dashboard aggiornata" -Data @{
        openTickets = $tickets.Count
        openProblems = $problems.Count
        openChanges = $changes.Count
        ticketTasks = $ticketTasks.Count
        problemTasks = $problemTasks.Count
        changeTasks = $changeTasks.Count
        elapsedMs = $elapsedMs
    }

    return [PSCustomObject]@{
        stats = $stats
        totals = $totals
        chiamate = @($ticketTasks)
        problemi = @($problemTasks)
        cambiamenti = @($changeTasks)
        aggiornatoAlle = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        durataMs = $elapsedMs
    }
}

# =========================
# LIST PAGE DATA
# =========================

function New-ListRow {
    param (
        $Item,
        [string]$Kind,
        [string]$FormPath
    )

    $id = Get-IdValue (Get-PropValue $Item @("id"))
    if ($null -eq $id) { return $null }

    $title = Get-PropValue $Item @("name", "title")
    if (-not $title) { $title = "(senza titolo)" }

    $typeText = if ($Kind -eq "ticket") { Get-TicketTypeText $Item } else { $Kind }
    $updatedDate = Get-ItemDate $Item @("date_mod", "date_creation", "date")

    return [PSCustomObject]@{
        id = [int]$id
        title = [string]$title
        status = Get-ItemStatusText $Item
        type = [string]$typeText
        updatedAt = Format-DateValue $updatedDate
        sortDate = $updatedDate
        url = "{0}{1}?id={2}" -f $script:glpiWebBaseUrl.TrimEnd("/"), $FormPath, [int]$id
    }
}

function Get-ListData {
    param ([string]$View)

    $normalizedView = ($View + "").Trim().ToLowerInvariant()
    $items = @()
    $kind = "ticket"
    $formPath = "/front/ticket.form.php"
    $title = "Totali aperti"

    switch ($normalizedView) {
        "totali-aperti" {
            $items = @(Get-AllOpenItems -ResourcePath $ticketResourcePath -LogLabel "ticket")
            $title = "Totali aperti"
        }

        "nuovi-incidenti" {
            $items = @(
                Get-AllOpenItems -ResourcePath $ticketResourcePath -LogLabel "ticket" |
                    Where-Object { (Get-TicketStatusId $_) -eq 1 -and (Get-TicketTypeId $_) -eq 1 }
            )
            $title = "Nuovi incidenti"
        }

        "nuove-richieste" {
            $items = @(
                Get-AllOpenItems -ResourcePath $ticketResourcePath -LogLabel "ticket" |
                    Where-Object { (Get-TicketStatusId $_) -eq 1 -and (Get-TicketTypeId $_) -eq 2 }
            )
            $title = "Nuove richieste"
        }

        "assegnati-a-me" {
            $items = @(
                Get-AllOpenItems -ResourcePath $ticketResourcePath -LogLabel "ticket" |
                    Where-Object { Test-TeamAssignedToUser -Item $_ -UserId $script:targetUserId }
            )
            $title = "Assegnati a me"
        }

        "chiamate" {
            $items = @(Get-AllOpenItems -ResourcePath $ticketResourcePath -LogLabel "ticket")
            $title = "Attività chiamate"
        }

        "problemi" {
            $items = @(Get-AllOpenItems -ResourcePath $problemResourcePath -LogLabel "problemi")
            $kind = "Problema"
            $formPath = "/front/problem.form.php"
            $title = "Attività problemi"
        }

        "cambiamenti" {
            $items = @(Get-AllOpenItems -ResourcePath $changeResourcePath -LogLabel "cambiamenti")
            $kind = "Cambiamento"
            $formPath = "/front/change.form.php"
            $title = "Attività cambiamenti"
        }

        default {
            throw "Vista elenco non valida: $View"
        }
    }

    $rows = @(
        foreach ($item in $items) {
            $row = New-ListRow -Item $item -Kind $kind -FormPath $formPath
            if ($null -ne $row) { $row }
        }
    )

    $publicRows = @(
        $rows |
            Sort-Object `
                @{ Expression = { $_.sortDate }; Descending = $true }, `
                @{ Expression = { $_.id }; Descending = $true } |
            Select-Object id, title, status, type, updatedAt, url
    )

    return [PSCustomObject]@{
        view = $normalizedView
        title = $title
        count = $publicRows.Count
        items = @($publicRows)
        aggiornatoAlle = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }
}

# =========================
# HTTP RESPONSES / ROUTES
# =========================

function Get-TemplatedHtml {
    param ([string]$Path)

    return (Get-Content -Path $Path -Raw -Encoding UTF8).Replace(
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

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $response = $Context.Response
    $response.StatusCode = $StatusCode
    $response.ContentType = "$ContentType; charset=utf-8"
    $response.ContentLength64 = $bytes.Length

    Set-CommonResponseHeaders -Response $response

    $response.Headers["Content-Security-Policy"] = `
        "default-src 'self'; " + `
        "script-src 'self' 'unsafe-inline'; " + `
        "style-src 'self' 'unsafe-inline'; " + `
        "connect-src 'self'; " + `
        "img-src 'self'; " + `
        "object-src 'none'; " + `
        "base-uri 'none'; " + `
        "frame-ancestors 'none'"

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

    Send-Response `
        -Context $Context `
        -StatusCode $StatusCode `
        -Body ($Object | ConvertTo-Json -Depth 60 -Compress) `
        -ContentType "application/json"
}

function Handle-Request {
    param (
        [System.Net.HttpListenerContext]$Context,
        [string]$RequestId
    )

    $request = $Context.Request
    $path = $request.Url.AbsolutePath.ToLowerInvariant()

    if ($request.HttpMethod -ne "GET") {
        Send-Response -Context $Context -StatusCode 405 -Body "Metodo non consentito" -ContentType "text/plain"
        return
    }

    if ($path -like "/list/*") {
        Send-Response `
            -Context $Context `
            -StatusCode 200 `
            -Body (Get-TemplatedHtml -Path $listPath) `
            -ContentType "text/html"
        return
    }

    switch ($path) {
        "/" {
            Send-Response -Context $Context -StatusCode 200 -Body (Get-TemplatedHtml -Path $dashboardPath) -ContentType "text/html"
        }

        "/dashboard.html" {
            Send-Response -Context $Context -StatusCode 200 -Body (Get-TemplatedHtml -Path $dashboardPath) -ContentType "text/html"
        }

        "/list.html" {
            Send-Response -Context $Context -StatusCode 200 -Body (Get-TemplatedHtml -Path $listPath) -ContentType "text/html"
        }

        "/api/dashboard" {
            Send-Json -Context $Context -Object (Get-DashboardData)
        }

        "/api/dashboard/stream" {
            Start-NdjsonResponse -Context $Context

            try {
                $data = Get-DashboardData -StreamContext $Context
                Write-NdjsonEvent -Context $Context -Object ([PSCustomObject]@{
                    type = "result"
                    data = $data
                })
            }
            catch {
                Write-Log -Level ERROR -Message "Errore stream dashboard" -Data @{
                    requestId = $RequestId
                    message = $_.Exception.Message
                }

                try {
                    Write-NdjsonEvent -Context $Context -Object ([PSCustomObject]@{
                        type = "error"
                        message = $_.Exception.Message
                    })
                }
                catch {}
            }
            finally {
                try { $Context.Response.OutputStream.Close() } catch {}
            }
        }

        "/api/list" {
            $view = [string]$request.QueryString["view"]
            Send-Json -Context $Context -Object (Get-ListData -View $view)
        }

        "/api/health" {
            Send-Json -Context $Context -Object ([PSCustomObject]@{
                ok = $true
                authenticated = -not [string]::IsNullOrWhiteSpace($script:accessToken)
                taskConcurrency = $script:taskConcurrency
                autoRefreshSeconds = $script:autoRefreshSeconds
                implementedActivities = @("chiamate", "problemi", "cambiamenti")
                time = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            })
        }

        "/favicon.ico" {
            Send-Response -Context $Context -StatusCode 204 -Body "" -ContentType "text/plain"
        }

        default {
            Send-Response -Context $Context -StatusCode 404 -Body "Non trovato" -ContentType "text/plain"
        }
    }
}

# =========================
# SERVER
# =========================

function Start-LocalServer {
    param ([string]$Prefix)

    if (-not $Prefix.StartsWith("http://127.0.0.1:")) {
        Write-Log -Level ERROR -Message "Il server deve usare 127.0.0.1"
        exit 1
    }

    if (-not $Prefix.EndsWith("/")) { $Prefix += "/" }

    foreach ($requiredFile in @($dashboardPath, $listPath)) {
        if (-not (Test-Path $requiredFile)) {
            Write-Log -Level ERROR -Message "File HTML non trovato" -Data @{ path = $requiredFile }
            exit 1
        }
    }

    $script:httpListener = [System.Net.HttpListener]::new()
    $script:httpListener.Prefixes.Add($Prefix)

    try {
        $script:httpListener.Start()
    }
    catch {
        Write-Log -Level ERROR -Message "Impossibile avviare il server locale" -Data (Get-ExceptionDetails $_)
        exit 1
    }

    Write-Log -Level INFO -Message "Web service locale avviato" -Data @{
        dashboard = $Prefix
        taskConcurrency = $script:taskConcurrency
        autoRefreshSeconds = $script:autoRefreshSeconds
        pid = $PID
    }

    Write-Host ""
    Write-Host "Dashboard: $Prefix" -ForegroundColor Green
    Write-Host "Premi CTRL+C per fermare." -ForegroundColor DarkCyan

    while ($script:httpListener -and $script:httpListener.IsListening -and -not $script:stopRequested) {
        $context = $null
        $requestId = [guid]::NewGuid().ToString("N").Substring(0, 8)
        $started = Get-Date

        try {
            $context = $script:httpListener.GetContext()
        }
        catch [System.Net.HttpListenerException] {
            if ($script:stopRequested) { break }
            Write-Log -Level WARN -Message "Listener HTTP interrotto" -Data @{ error = $_.Exception.Message }
            break
        }
        catch [System.ObjectDisposedException] {
            break
        }

        if ($null -eq $context) { continue }

        Write-Log -Level INFO -Message "Richiesta ricevuta" -Data @{
            requestId = $requestId
            method = $context.Request.HttpMethod
            path = $context.Request.Url.AbsolutePath
            remote = $context.Request.RemoteEndPoint.ToString()
        }

        try {
            Handle-Request -Context $context -RequestId $requestId

            Write-Log -Level INFO -Message "Richiesta completata" -Data @{
                requestId = $requestId
                path = $context.Request.Url.AbsolutePath
                elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds
            }
        }
        catch {
            $details = Get-ExceptionDetails $_

            Write-Log -Level ERROR -Message "Richiesta fallita" -Data @{
                requestId = $requestId
                path = $context.Request.Url.AbsolutePath
                details = $details
            }

            try {
                Send-Json -Context $context -StatusCode 500 -Object ([PSCustomObject]@{
                    error = "Errore interno durante la richiesta"
                    message = $details.message
                    requestId = $requestId
                    timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                })
            }
            catch {}
        }
    }
}

# =========================
# MAIN
# =========================

$envVars = Load-Env $envPath

$script:logLevel = Get-EnvValue -EnvVars $envVars -Key "LOG_LEVEL" -Default "INFO"
$script:apiBaseUrl = (Get-RequiredString -EnvVars $envVars -Key "GLPI_API_BASE_URL").TrimEnd("/")
$script:authUrl = Get-RequiredString -EnvVars $envVars -Key "GLPI_AUTH_URL"
$script:glpiWebBaseUrl = Normalize-GlpiWebBaseUrl (Get-RequiredString -EnvVars $envVars -Key "GLPI_WEB_BASE_URL")
$script:clientId = Get-RequiredString -EnvVars $envVars -Key "CLIENT_ID"
$script:clientSecret = Get-RequiredString -EnvVars $envVars -Key "CLIENT_SECRET"
$script:username = Get-RequiredString -EnvVars $envVars -Key "USERNAME"
$script:targetUserId = Get-RequiredInt -EnvVars $envVars -Key "USER_ID"
$script:scope = Get-EnvValue -EnvVars $envVars -Key "SCOPE" -Default "email user api inventory status graphql"
$script:pageSize = Get-OptionalInt -EnvVars $envVars -Key "PAGE_SIZE" -Default 100 -Minimum 1 -Maximum 1000
$script:taskConcurrency = Get-OptionalInt -EnvVars $envVars -Key "TASK_CONCURRENCY" -Default 6 -Minimum 1 -Maximum 20
$script:autoRefreshSeconds = Get-OptionalInt -EnvVars $envVars -Key "AUTO_REFRESH_SECONDS" -Default 60 -Minimum 10 -Maximum 3600
$script:hostPrefix = Resolve-LocalHostPrefix -EnvVars $envVars

Write-Log -Level INFO -Message "Configurazione caricata" -Data @{
    apiBaseUrl = $script:apiBaseUrl
    authUrl = $script:authUrl
    webBaseUrl = $script:glpiWebBaseUrl
    username = $script:username
    userId = $script:targetUserId
    pageSize = $script:pageSize
    taskConcurrency = $script:taskConcurrency
    autoRefreshSeconds = $script:autoRefreshSeconds
    host = $script:hostPrefix
    logLevel = $script:logLevel
}

Initialize-DashboardSingleInstance
Register-DashboardShutdownHandlers

Write-Host ""
Write-Host "Utente GLPI: $script:username" -ForegroundColor Cyan
$securePassword = Read-Host "Inserisci la password GLPI" -AsSecureString
$script:credential = [System.Management.Automation.PSCredential]::new($script:username, $securePassword)

try {
    [void](Get-AccessToken)
    Write-Log -Level INFO -Message "Autenticazione iniziale completata"
}
catch {
    Stop-DashboardServer -Reason "Autenticazione fallita"
    exit 1
}

try {
    Start-LocalServer -Prefix $script:hostPrefix
}
finally {
    Stop-DashboardServer -Reason "Script terminato"
}
