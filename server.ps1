#requires -Version 5.1

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$envPath = Join-Path $scriptDir ".env"
$dashboardPath = Join-Path $scriptDir "dashboard.html"
$listPath = Join-Path $scriptDir "list.html"
$pidPath = Join-Path $scriptDir "dashboard-server.pid.json"
$notesDbPath = Join-Path $scriptDir "notes-db.json"

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
$script:notesLock = New-Object object

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

function Get-PropertyObject {
    param (
        $Object,
        [string]$Name
    )

    if ($null -eq $Object) { return $null }

    try {
        return $Object.PSObject.Properties[$Name]
    }
    catch {
        return $null
    }
}

function Convert-ToArray {
    param ($Value)

    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Array]) { return @($Value) }

    foreach ($propertyName in @("data", "items", "results", "member", "hydra:member")) {
        $property = Get-PropertyObject -Object $Value -Name $propertyName
        if ($null -ne $property) {
            return Convert-ToArray $property.Value
        }
    }

    return @($Value)
}

function Get-PropValue {
    param (
        $Object,
        [string[]]$Names
    )

    if ($null -eq $Object) { return $null }

    foreach ($name in $Names) {
        $property = Get-PropertyObject -Object $Object -Name $name
        if ($null -ne $property) {
            return $property.Value
        }
    }

    return $null
}

function Get-IdValue {
    param ($Value)

    if ($null -eq $Value) { return $null }

    if (
        $Value -is [byte] -or
        $Value -is [int16] -or
        $Value -is [int] -or
        $Value -is [long] -or
        $Value -is [decimal]
    ) {
        return [long]$Value
    }

    if ($Value -is [string]) {
        $parsed = 0L
        if ([long]::TryParse($Value, [ref]$parsed)) { return $parsed }
        return $null
    }

    $property = Get-PropertyObject -Object $Value -Name "id"
    if ($null -ne $property) {
        return Get-IdValue $property.Value
    }

    return $null
}

function Get-TextValue {
    param ($Value)

    if ($null -eq $Value) { return "" }
    if ($Value -is [string]) { return $Value }

    $property = Get-PropertyObject -Object $Value -Name "name"
    if ($null -ne $property -and $null -ne $property.Value) {
        return [string]$property.Value
    }

    return [string]$Value
}

function Get-ItemDate {
    param (
        $Item,
        [string[]]$FieldNames
    )

    foreach ($field in $FieldNames) {
        $value = Get-PropValue -Object $Item -Names @($field)
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

    if ($null -eq $Task) { return $null }

    $property = Get-PropertyObject -Object $Task -Name "item"
    if ($null -ne $property -and $null -ne $property.Value) {
        return $property.Value
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

function Get-ItemStatusId {
    param ($Item)

    return Get-IdValue (
        Get-PropValue $Item @("status", "status_id", "statuses_id")
    )
}

function Get-ItemStatusText {
    param (
        $Item,
        [string]$Kind = ""
    )

    $status = Get-PropValue $Item @("status", "status_id", "statuses_id")
    $text = Get-TextValue $status

    if ($text -and $text -notmatch "^\d+$") {
        return $text
    }

    $statusId = Get-IdValue $status
    $normalizedKind = ($Kind + "").Trim().ToLowerInvariant()

    if ($normalizedKind -eq "ticket") {
        switch ($statusId) {
            1  { return "Nuova" }
            10 { return "Convalida" }
            2  { return "In lavorazione (assegnata)" }
            3  { return "In lavorazione (pianificata)" }
            4  { return "In sospeso" }
            5  { return "Risolto" }
            6  { return "Chiusa" }
        }
    }
    elseif ($normalizedKind -eq "problem") {
        switch ($statusId) {
            1 { return "Nuova" }
            7 { return "Accettato" }
            2 { return "In lavorazione (assegnata)" }
            3 { return "In lavorazione (pianificata)" }
            4 { return "In sospeso" }
            5 { return "Risolto" }
            8 { return "Sotto osservazione" }
            6 { return "Chiusa" }
        }
    }
    elseif ($normalizedKind -eq "change") {
        switch ($statusId) {
            1  { return "Nuova" }
            9  { return "Valutazione" }
            10 { return "Convalida" }
            7  { return "Accettato" }
            4  { return "In sospeso" }
            11 { return "Analisi" }
            12 { return "Qualificazione" }
            5  { return "Applicata" }
            8  { return "Revisione" }
            6  { return "Chiusa" }
            14 { return "Cancellato" }
            13 { return "Rifiutato" }
        }
    }

    switch ($statusId) {
        1 { return "Nuova" }
        2 { return "In lavorazione (assegnata)" }
        3 { return "In lavorazione (pianificata)" }
        4 { return "In sospeso" }
        5 { return "Risolto" }
        6 { return "Chiusa" }
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

    # Only the technician explicitly assigned to execute the task is valid.
    # Do not include the task author/editor, otherwise unrelated tasks appear.
    $taskData = Get-TaskData $Task
    $assignedTechnician = Get-PropValue $taskData @("user_tech")
    $assignedTechnicianId = Get-IdValue $assignedTechnician

    return (
        $null -ne $assignedTechnicianId -and
        [int]$assignedTechnicianId -eq [int]$UserId
    )
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
                $property = $null
                try { $property = $Value.PSObject.Properties[$propertyName] } catch {}

                if ($null -ne $property) {
                    return Convert-WorkerArray $property.Value
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

            $parentKind = switch ($Category) {
                "chiamate"    { "ticket" }
                "problemi"    { "problem" }
                "cambiamenti" { "change" }
                default       { "" }
            }

            $parentStatusId = Get-ItemStatusId -Item $item
            $parentStatusText = Get-ItemStatusText -Item $item -Kind $parentKind

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
                ParentKind = [string]$parentKind
                ParentStatusId = $parentStatusId
                ParentStatusText = [string]$parentStatusText
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
                                parentKind = $job.ParentKind
                                parentStatusId = $job.ParentStatusId
                                parentStatusText = $job.ParentStatusText
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
            Select-Object parentId, parentTitle, parentUrl, parentKind, parentStatusId, parentStatusText, taskId, taskDate, content
    )
}

function Get-DashboardData {
    param ([System.Net.HttpListenerContext]$StreamContext = $null)

    $started = Get-Date
    $allLists = [ordered]@{}
    $totals = [ordered]@{
        chiamate = 0
        problemi = 0
        cambiamenti = 0
    }

    $stats = $null
    $ticketTasks = @()
    $problemTasks = @()
    $changeTasks = @()

    if ($null -ne $StreamContext) {
        Write-NdjsonEvent -Context $StreamContext -Object ([PSCustomObject]@{
            type = "refreshStart"
        })
    }

    # Ticket list and ticket tasks first.
    $tickets = @(Get-AllOpenItems -ResourcePath $ticketResourcePath -LogLabel "ticket")
    $stats = Get-DashboardStatsFromTickets -Tickets $tickets
    $ticketListViews = Get-TicketListViews -Tickets $tickets
    $totals.chiamate = [int]$tickets.Count

    foreach ($property in $ticketListViews.PSObject.Properties) {
        $allLists[$property.Name] = @($property.Value)
    }

    if ($null -ne $StreamContext) {
        Write-NdjsonEvent -Context $StreamContext -Object ([PSCustomObject]@{
            type = "categoryStart"
            category = "chiamate"
            total = $tickets.Count
            stats = $stats
            totalsPatch = [PSCustomObject]@{ chiamate = [int]$tickets.Count }
            listViews = $ticketListViews
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
            updatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        })
    }

    # Problems are fetched and displayed only after ticket tasks have finished.
    $problems = @(Get-AllOpenItems -ResourcePath $problemResourcePath -LogLabel "problemi")
    $problemListViews = Get-ProblemListViews -Problems $problems
    $totals.problemi = [int]$problems.Count

    foreach ($property in $problemListViews.PSObject.Properties) {
        $allLists[$property.Name] = @($property.Value)
    }

    if ($null -ne $StreamContext) {
        Write-NdjsonEvent -Context $StreamContext -Object ([PSCustomObject]@{
            type = "categoryStart"
            category = "problemi"
            total = $problems.Count
            totalsPatch = [PSCustomObject]@{ problemi = [int]$problems.Count }
            listViews = $problemListViews
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
            updatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        })
    }

    # Changes are fetched and displayed last.
    $changes = @(Get-AllOpenItems -ResourcePath $changeResourcePath -LogLabel "cambiamenti")
    $changeListViews = Get-ChangeListViews -Changes $changes
    $totals.cambiamenti = [int]$changes.Count

    foreach ($property in $changeListViews.PSObject.Properties) {
        $allLists[$property.Name] = @($property.Value)
    }

    if ($null -ne $StreamContext) {
        Write-NdjsonEvent -Context $StreamContext -Object ([PSCustomObject]@{
            type = "categoryStart"
            category = "cambiamenti"
            total = $changes.Count
            totalsPatch = [PSCustomObject]@{ cambiamenti = [int]$changes.Count }
            listViews = $changeListViews
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
            updatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        })
    }

    $elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds
    $updatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

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
        totals = [PSCustomObject]$totals
        chiamate = @($ticketTasks)
        problemi = @($problemTasks)
        cambiamenti = @($changeTasks)
        lists = [PSCustomObject]$allLists
        aggiornatoAlle = $updatedAt
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

    $id = Get-IdValue (Get-PropValue -Object $Item -Names @("id"))
    if ($null -eq $id) { return $null }

    $title = Get-PropValue -Object $Item -Names @("name", "title")
    if (-not $title) { $title = "(senza titolo)" }

    $typeText = if ($Kind -eq "ticket") {
        Get-TicketTypeText -Ticket $Item
    }
    elseif ($Kind -eq "problem") {
        "Problema"
    }
    elseif ($Kind -eq "change") {
        "Cambiamento"
    }
    else {
        $Kind
    }

    $updatedDate = Get-ItemDate -Item $Item -FieldNames @("date_mod", "date_creation", "date")

    $statusId = Get-ItemStatusId -Item $Item

    return [PSCustomObject]@{
        id = [int]$id
        title = [string]$title
        status = Get-ItemStatusText -Item $Item -Kind $Kind
        statusId = $statusId
        kind = [string]$Kind
        type = [string]$typeText
        updatedAt = Format-DateValue -Date $updatedDate
        sortDate = $updatedDate
        url = "{0}{1}?id={2}" -f $script:glpiWebBaseUrl.TrimEnd("/"), $FormPath, [int]$id
    }
}

function Convert-ItemsToListRows {
    param (
        [array]$Items,
        [string]$Kind,
        [string]$FormPath
    )

    $rows = @(
        foreach ($item in $Items) {
            $row = New-ListRow -Item $item -Kind $Kind -FormPath $FormPath
            if ($null -ne $row) { $row }
        }
    )

    return @(
        $rows |
            Sort-Object `
                @{ Expression = { $_.sortDate }; Descending = $true }, `
                @{ Expression = { $_.id }; Descending = $true } |
            Select-Object id, title, status, statusId, kind, type, updatedAt, url
    )
}

function Get-TicketListViews {
    param ([array]$Tickets)

    $newIncidents = @(
        $Tickets | Where-Object {
            (Get-TicketStatusId -Ticket $_) -eq 1 -and
            (Get-TicketTypeId -Ticket $_) -eq 1
        }
    )

    $newRequests = @(
        $Tickets | Where-Object {
            (Get-TicketStatusId -Ticket $_) -eq 1 -and
            (Get-TicketTypeId -Ticket $_) -eq 2
        }
    )

    $assignedToMe = @(
        $Tickets | Where-Object {
            Test-TeamAssignedToUser -Item $_ -UserId $script:targetUserId
        }
    )

    $allRows = @(Convert-ItemsToListRows -Items $Tickets -Kind "ticket" -FormPath "/front/ticket.form.php")

    return [PSCustomObject][ordered]@{
        "totali-aperti" = @($allRows)
        "nuovi-incidenti" = @(Convert-ItemsToListRows -Items $newIncidents -Kind "ticket" -FormPath "/front/ticket.form.php")
        "nuove-richieste" = @(Convert-ItemsToListRows -Items $newRequests -Kind "ticket" -FormPath "/front/ticket.form.php")
        "assegnati-a-me" = @(Convert-ItemsToListRows -Items $assignedToMe -Kind "ticket" -FormPath "/front/ticket.form.php")
        "chiamate" = @($allRows)
    }
}

function Get-ProblemListViews {
    param ([array]$Problems)

    return [PSCustomObject][ordered]@{
        "problemi" = @(
            Convert-ItemsToListRows `
                -Items $Problems `
                -Kind "problem" `
                -FormPath "/front/problem.form.php"
        )
    }
}

function Get-ChangeListViews {
    param ([array]$Changes)

    return [PSCustomObject][ordered]@{
        "cambiamenti" = @(
            Convert-ItemsToListRows `
                -Items $Changes `
                -Kind "change" `
                -FormPath "/front/change.form.php"
        )
    }
}

function Get-ListViewTitle {
    param ([string]$View)

    switch ($View) {
        "totali-aperti" { return "Totali aperti" }
        "nuovi-incidenti" { return "Nuovi incidenti" }
        "nuove-richieste" { return "Nuove richieste" }
        "assegnati-a-me" { return "Assegnati a me" }
        "chiamate" { return "Chiamate" }
        "problemi" { return "Problemi" }
        "cambiamenti" { return "Cambiamenti" }
        default { return "Elenco GLPI" }
    }
}

function Get-ListData {
    param ([string]$View)

    $normalizedView = ($View + "").Trim().ToLowerInvariant()
    $validViews = @(
        "totali-aperti",
        "nuovi-incidenti",
        "nuove-richieste",
        "assegnati-a-me",
        "chiamate",
        "problemi",
        "cambiamenti"
    )

    if ($validViews -notcontains $normalizedView) {
        throw "Vista elenco non valida: $View"
    }

    $relatedViews = $null
    $stats = $null
    $totalsPatch = [ordered]@{}
    $tasksPatch = [ordered]@{}

    if ($normalizedView -in @("totali-aperti", "nuovi-incidenti", "nuove-richieste", "assegnati-a-me", "chiamate")) {
        # Refresh only tickets and their assigned unfinished tasks.
        # One ticket-list call updates every ticket-derived view.
        $tickets = @(Get-AllOpenItems -ResourcePath $ticketResourcePath -LogLabel "ticket")
        $relatedViews = Get-TicketListViews -Tickets $tickets
        $stats = Get-DashboardStatsFromTickets -Tickets $tickets
        $totalsPatch.chiamate = [int]$tickets.Count
        $tasksPatch.chiamate = @(
            Invoke-TaskCategoryScan `
                -Items $tickets `
                -Category "chiamate" `
                -TaskEndpointTemplate $ticketTaskEndpointTemplate `
                -FormPath "/front/ticket.form.php"
        )
    }
    elseif ($normalizedView -eq "problemi") {
        # Refresh only problems and their assigned unfinished tasks.
        $problems = @(Get-AllOpenItems -ResourcePath $problemResourcePath -LogLabel "problemi")
        $relatedViews = Get-ProblemListViews -Problems $problems
        $totalsPatch.problemi = [int]$problems.Count
        $tasksPatch.problemi = @(
            Invoke-TaskCategoryScan `
                -Items $problems `
                -Category "problemi" `
                -TaskEndpointTemplate $problemTaskEndpointTemplate `
                -FormPath "/front/problem.form.php"
        )
    }
    else {
        # Refresh only changes and their assigned unfinished tasks.
        $changes = @(Get-AllOpenItems -ResourcePath $changeResourcePath -LogLabel "cambiamenti")
        $relatedViews = Get-ChangeListViews -Changes $changes
        $totalsPatch.cambiamenti = [int]$changes.Count
        $tasksPatch.cambiamenti = @(
            Invoke-TaskCategoryScan `
                -Items $changes `
                -Category "cambiamenti" `
                -TaskEndpointTemplate $changeTaskEndpointTemplate `
                -FormPath "/front/change.form.php"
        )
    }

    $selectedItems = @(Get-PropValue -Object $relatedViews -Names @($normalizedView))
    $updatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

    return [PSCustomObject]@{
        view = $normalizedView
        title = Get-ListViewTitle -View $normalizedView
        count = $selectedItems.Count
        items = @($selectedItems)
        relatedViews = $relatedViews
        stats = $stats
        totalsPatch = [PSCustomObject]$totalsPatch
        tasksPatch = [PSCustomObject]$tasksPatch
        aggiornatoAlle = $updatedAt
    }
}


# =========================
# LOCAL NOTES DATABASE
# =========================

function Test-ValidNoteKind {
    param ([string]$Kind)

    return @("ticket", "problem", "change") -contains (($Kind + "").Trim().ToLowerInvariant())
}

function New-EmptyNotesDatabase {
    return [PSCustomObject]@{
        version = 1
        notes = @()
    }
}

function Initialize-NotesDatabase {
    if (Test-Path $notesDbPath) { return }

    $database = New-EmptyNotesDatabase
    $json = $database | ConvertTo-Json -Depth 20
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($notesDbPath, $json, $utf8NoBom)
}

function Read-NotesDatabaseUnlocked {
    Initialize-NotesDatabase

    try {
        $raw = [System.IO.File]::ReadAllText($notesDbPath, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return New-EmptyNotesDatabase
        }

        $database = $raw | ConvertFrom-Json
        if ($null -eq $database) { return New-EmptyNotesDatabase }

        $notesProperty = Get-PropertyObject -Object $database -Name "notes"
        if ($null -eq $notesProperty) {
            $database | Add-Member -NotePropertyName notes -NotePropertyValue @() -Force
        }

        return $database
    }
    catch {
        Write-Log -Level ERROR -Message "Database note non leggibile" -Data @{
            path = $notesDbPath
            message = $_.Exception.Message
        }
        throw "Impossibile leggere il database delle note."
    }
}

function Save-NotesDatabaseUnlocked {
    param ($Database)

    $temporaryPath = "$notesDbPath.tmp"
    $json = $Database | ConvertTo-Json -Depth 30
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

    try {
        [System.IO.File]::WriteAllText($temporaryPath, $json, $utf8NoBom)
        Move-Item -Path $temporaryPath -Destination $notesDbPath -Force
    }
    finally {
        if (Test-Path $temporaryPath) {
            Remove-Item -Path $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-WithNotesLock {
    param ([scriptblock]$ScriptBlock)

    [System.Threading.Monitor]::Enter($script:notesLock)
    try {
        return & $ScriptBlock
    }
    finally {
        [System.Threading.Monitor]::Exit($script:notesLock)
    }
}

function Convert-NoteToPublicObject {
    param ($Note)

    return [PSCustomObject]@{
        id = [string](Get-PropValue $Note @("id"))
        kind = [string](Get-PropValue $Note @("kind"))
        itemId = [int](Get-IdValue (Get-PropValue $Note @("itemId")))
        text = [string](Get-PropValue $Note @("text"))
        completed = [bool](Get-PropValue $Note @("completed"))
        order = [int](Get-IdValue (Get-PropValue $Note @("order")))
        createdAt = [string](Get-PropValue $Note @("createdAt"))
        updatedAt = [string](Get-PropValue $Note @("updatedAt"))
    }
}

function Get-NotesForItem {
    param (
        [string]$Kind,
        [int]$ItemId
    )

    $normalizedKind = ($Kind + "").Trim().ToLowerInvariant()
    if (-not (Test-ValidNoteKind $normalizedKind)) { throw "Tipo elemento non valido." }
    if ($ItemId -le 0) { throw "ID elemento non valido." }

    return Invoke-WithNotesLock {
        $database = Read-NotesDatabaseUnlocked
        $notes = @(
            @(Convert-ToArray (Get-PropValue $database @("notes"))) |
                Where-Object {
                    ([string](Get-PropValue $_ @("kind"))).ToLowerInvariant() -eq $normalizedKind -and
                    [int](Get-IdValue (Get-PropValue $_ @("itemId"))) -eq $ItemId
                } |
                Sort-Object `
                    @{ Expression = { [int](Get-IdValue (Get-PropValue $_ @("order"))) }; Descending = $false }, `
                    @{ Expression = { [string](Get-PropValue $_ @("createdAt")) }; Descending = $false }
        )

        return @($notes | ForEach-Object { Convert-NoteToPublicObject $_ })
    }
}

function Get-NoteCountsByKind {
    param ([string]$Kind)

    $normalizedKind = ($Kind + "").Trim().ToLowerInvariant()
    if (-not (Test-ValidNoteKind $normalizedKind)) { throw "Tipo elemento non valido." }

    return Invoke-WithNotesLock {
        $database = Read-NotesDatabaseUnlocked
        $counts = [ordered]@{}

        foreach ($note in @(Convert-ToArray (Get-PropValue $database @("notes")))) {
            if (([string](Get-PropValue $note @("kind"))).ToLowerInvariant() -ne $normalizedKind) {
                continue
            }

            $itemId = Get-IdValue (Get-PropValue $note @("itemId"))
            if ($null -eq $itemId) { continue }

            $key = [string][int]$itemId
            if (-not $counts.Contains($key)) { $counts[$key] = 0 }
            $counts[$key] = [int]$counts[$key] + 1
        }

        return [PSCustomObject]$counts
    }
}

function Add-ItemNote {
    param (
        [string]$Kind,
        [int]$ItemId,
        [string]$Text
    )

    $normalizedKind = ($Kind + "").Trim().ToLowerInvariant()
    $normalizedText = ($Text + "").Trim()

    if (-not (Test-ValidNoteKind $normalizedKind)) { throw "Tipo elemento non valido." }
    if ($ItemId -le 0) { throw "ID elemento non valido." }
    if ([string]::IsNullOrWhiteSpace($normalizedText)) { throw "La nota non può essere vuota." }
    if ($normalizedText.Length -gt 10000) { throw "La nota supera il limite di 10000 caratteri." }

    return Invoke-WithNotesLock {
        $database = Read-NotesDatabaseUnlocked
        $allNotes = @(Convert-ToArray (Get-PropValue $database @("notes")))
        $existing = @(
            $allNotes | Where-Object {
                ([string](Get-PropValue $_ @("kind"))).ToLowerInvariant() -eq $normalizedKind -and
                [int](Get-IdValue (Get-PropValue $_ @("itemId"))) -eq $ItemId
            }
        )

        $nextOrder = if ($existing.Count -eq 0) {
            0
        }
        else {
            1 + [int](($existing | ForEach-Object {
                [int](Get-IdValue (Get-PropValue $_ @("order")))
            } | Measure-Object -Maximum).Maximum)
        }

        $now = (Get-Date).ToString("o")
        $note = [PSCustomObject]@{
            id = [guid]::NewGuid().ToString("N")
            kind = $normalizedKind
            itemId = $ItemId
            text = $normalizedText
            completed = $false
            order = $nextOrder
            createdAt = $now
            updatedAt = $now
        }

        $database.notes = @($allNotes + $note)
        Save-NotesDatabaseUnlocked -Database $database

        return Convert-NoteToPublicObject $note
    }
}

function Update-ItemNote {
    param (
        [string]$NoteId,
        $Payload
    )

    $normalizedId = ($NoteId + "").Trim()
    if ([string]::IsNullOrWhiteSpace($normalizedId)) { throw "ID nota non valido." }

    return Invoke-WithNotesLock {
        $database = Read-NotesDatabaseUnlocked
        $allNotes = @(Convert-ToArray (Get-PropValue $database @("notes")))
        $note = $allNotes | Where-Object { [string](Get-PropValue $_ @("id")) -eq $normalizedId } | Select-Object -First 1

        if ($null -eq $note) { throw "Nota non trovata." }

        $textProperty = Get-PropertyObject -Object $Payload -Name "text"
        if ($null -ne $textProperty) {
            $newText = ([string]$textProperty.Value).Trim()
            if ([string]::IsNullOrWhiteSpace($newText)) { throw "La nota non può essere vuota." }
            if ($newText.Length -gt 10000) { throw "La nota supera il limite di 10000 caratteri." }
            $note.text = $newText
        }

        $completedProperty = Get-PropertyObject -Object $Payload -Name "completed"
        if ($null -ne $completedProperty) {
            $note.completed = [bool]$completedProperty.Value
        }

        $note.updatedAt = (Get-Date).ToString("o")
        $database.notes = @($allNotes)
        Save-NotesDatabaseUnlocked -Database $database

        return Convert-NoteToPublicObject $note
    }
}

function Remove-ItemNote {
    param ([string]$NoteId)

    $normalizedId = ($NoteId + "").Trim()
    if ([string]::IsNullOrWhiteSpace($normalizedId)) { throw "ID nota non valido." }

    return Invoke-WithNotesLock {
        $database = Read-NotesDatabaseUnlocked
        $allNotes = @(Convert-ToArray (Get-PropValue $database @("notes")))
        $note = $allNotes | Where-Object { [string](Get-PropValue $_ @("id")) -eq $normalizedId } | Select-Object -First 1
        if ($null -eq $note) { throw "Nota non trovata." }

        $remaining = @($allNotes | Where-Object { [string](Get-PropValue $_ @("id")) -ne $normalizedId })
        $database.notes = $remaining
        Save-NotesDatabaseUnlocked -Database $database

        return Convert-NoteToPublicObject $note
    }
}

function Set-ItemNoteOrder {
    param (
        [string]$Kind,
        [int]$ItemId,
        [array]$NoteIds
    )

    $normalizedKind = ($Kind + "").Trim().ToLowerInvariant()
    if (-not (Test-ValidNoteKind $normalizedKind)) { throw "Tipo elemento non valido." }
    if ($ItemId -le 0) { throw "ID elemento non valido." }

    return Invoke-WithNotesLock {
        $database = Read-NotesDatabaseUnlocked
        $allNotes = @(Convert-ToArray (Get-PropValue $database @("notes")))
        $itemNotes = @(
            $allNotes | Where-Object {
                ([string](Get-PropValue $_ @("kind"))).ToLowerInvariant() -eq $normalizedKind -and
                [int](Get-IdValue (Get-PropValue $_ @("itemId"))) -eq $ItemId
            }
        )

        $knownIds = @{}
        foreach ($note in $itemNotes) {
            $knownIds[[string](Get-PropValue $note @("id"))] = $note
        }

        $orderedIds = New-Object System.Collections.Generic.List[string]
        foreach ($id in @($NoteIds)) {
            $normalizedId = ([string]$id).Trim()
            if ($knownIds.ContainsKey($normalizedId) -and -not $orderedIds.Contains($normalizedId)) {
                $orderedIds.Add($normalizedId)
            }
        }

        foreach ($note in $itemNotes) {
            $id = [string](Get-PropValue $note @("id"))
            if (-not $orderedIds.Contains($id)) { $orderedIds.Add($id) }
        }

        for ($index = 0; $index -lt $orderedIds.Count; $index++) {
            $knownIds[$orderedIds[$index]].order = $index
            $knownIds[$orderedIds[$index]].updatedAt = (Get-Date).ToString("o")
        }

        $database.notes = @($allNotes)
        Save-NotesDatabaseUnlocked -Database $database

        return @(
            $orderedIds | ForEach-Object {
                Convert-NoteToPublicObject $knownIds[$_]
            }
        )
    }
}

function Read-JsonRequestBody {
    param ([System.Net.HttpListenerRequest]$Request)

    if (-not $Request.HasEntityBody) { return [PSCustomObject]@{} }
    if ($Request.ContentLength64 -gt 1048576) { throw "Corpo richiesta troppo grande." }

    # JSON sent by fetch is UTF-8. HttpListener may otherwise fall back to the
    # Windows ANSI code page when the charset is omitted, turning "è" into "Ã¨".
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    $reader = [System.IO.StreamReader]::new($Request.InputStream, $utf8, $true, 4096, $false)

    try {
        $raw = $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }

    if ([string]::IsNullOrWhiteSpace($raw)) { return [PSCustomObject]@{} }
    return $raw | ConvertFrom-Json
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
    $method = $request.HttpMethod.ToUpperInvariant()

    # Notes are stored locally and support a small CRUD API.
    if ($path -eq "/api/notes/counts" -and $method -eq "GET") {
        $kind = [string]$request.QueryString["kind"]
        Send-Json -Context $Context -Object ([PSCustomObject]@{
            kind = $kind
            counts = Get-NoteCountsByKind -Kind $kind
        })
        return
    }

    if ($path -eq "/api/notes" -and $method -eq "GET") {
        $kind = [string]$request.QueryString["kind"]
        $itemId = 0
        if (-not [int]::TryParse([string]$request.QueryString["itemId"], [ref]$itemId)) {
            throw "ID elemento non valido."
        }

        $notes = @(Get-NotesForItem -Kind $kind -ItemId $itemId)
        Send-Json -Context $Context -Object ([PSCustomObject]@{
            kind = $kind
            itemId = $itemId
            count = $notes.Count
            notes = $notes
        })
        return
    }

    if ($path -eq "/api/notes" -and $method -eq "POST") {
        $payload = Read-JsonRequestBody -Request $request
        $kind = [string](Get-PropValue $payload @("kind"))
        $itemId = [int](Get-IdValue (Get-PropValue $payload @("itemId")))
        $text = [string](Get-PropValue $payload @("text"))
        $note = Add-ItemNote -Kind $kind -ItemId $itemId -Text $text
        $notes = @(Get-NotesForItem -Kind $kind -ItemId $itemId)

        Send-Json -Context $Context -StatusCode 201 -Object ([PSCustomObject]@{
            note = $note
            count = $notes.Count
            notes = $notes
        })
        return
    }

    if ($path -eq "/api/notes/reorder" -and $method -eq "POST") {
        $payload = Read-JsonRequestBody -Request $request
        $kind = [string](Get-PropValue $payload @("kind"))
        $itemId = [int](Get-IdValue (Get-PropValue $payload @("itemId")))
        $ids = @(Convert-ToArray (Get-PropValue $payload @("ids")))
        $notes = @(Set-ItemNoteOrder -Kind $kind -ItemId $itemId -NoteIds $ids)

        Send-Json -Context $Context -Object ([PSCustomObject]@{
            count = $notes.Count
            notes = $notes
        })
        return
    }

    if ($path -match "^/api/notes/([a-z0-9]+)$" -and $method -eq "PUT") {
        $noteId = $matches[1]
        $payload = Read-JsonRequestBody -Request $request
        $note = Update-ItemNote -NoteId $noteId -Payload $payload
        $notes = @(Get-NotesForItem -Kind $note.kind -ItemId $note.itemId)

        Send-Json -Context $Context -Object ([PSCustomObject]@{
            note = $note
            count = $notes.Count
            notes = $notes
        })
        return
    }

    if ($path -match "^/api/notes/([a-z0-9]+)$" -and $method -eq "DELETE") {
        $noteId = $matches[1]
        $deleted = Remove-ItemNote -NoteId $noteId
        $notes = @(Get-NotesForItem -Kind $deleted.kind -ItemId $deleted.itemId)

        Send-Json -Context $Context -Object ([PSCustomObject]@{
            deletedId = $noteId
            count = $notes.Count
            notes = $notes
        })
        return
    }

    if ($method -ne "GET") {
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

Initialize-NotesDatabase
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