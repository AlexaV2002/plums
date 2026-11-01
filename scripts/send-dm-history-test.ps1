param(
    [Parameter(Mandatory = $true)]
    [string] $Email,

    [Parameter(Mandatory = $true)]
    [string] $RecipientUsername,

    [ValidateRange(51, 200)]
    [int] $Count = 60,

    [string] $BaseUrl = 'http://127.0.0.1:3000'
)

$ErrorActionPreference = 'Stop'
$BaseUrl = $BaseUrl.TrimEnd('/')
$sent = 0
$marker = 'dm-history-' + [guid]::NewGuid().ToString('N').Substring(0, 12)

function Get-StatusText($errorRecord) {
    $response = $errorRecord.Exception.Response
    if ($null -ne $response) {
        return 'HTTP ' + [int] $response.StatusCode
    }
    return $errorRecord.Exception.Message
}

try {
    $securePassword = Read-Host 'Password for sender account' -AsSecureString
    $passwordPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    try {
        $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPtr)
        $loginBody = @{ email = $Email; password = $password } | ConvertTo-Json -Compress
        $login = Invoke-RestMethod -Method Post -Uri "$BaseUrl/auth/login" `
            -ContentType 'application/json; charset=utf-8' -Body $loginBody
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPtr)
        Remove-Variable password, loginBody -ErrorAction SilentlyContinue
    }

    $headers = @{ Authorization = 'Bearer ' + $login.accessToken }
    $encodedName = [uri]::EscapeDataString($RecipientUsername)
    $matches = @(Invoke-RestMethod -Method Get `
        -Uri "$BaseUrl/users/search?q=$encodedName&limit=20" -Headers $headers)
    $exact = @($matches | Where-Object { $_.username -ieq $RecipientUsername })
    if ($exact.Count -ne 1) {
        throw "Expected one exact recipient named '$RecipientUsername'; found $($exact.Count). No messages sent."
    }
    if ($exact[0].id -eq $login.user.id) {
        throw 'Sender and recipient must be different. No messages sent.'
    }

    $conversationBody = @{ userId = $exact[0].id } | ConvertTo-Json -Compress
    $conversation = Invoke-RestMethod -Method Post -Uri "$BaseUrl/dm/conversations" `
        -Headers $headers -ContentType 'application/json; charset=utf-8' `
        -Body $conversationBody
    $conversationId = $conversation.id
    if (-not $conversationId) {
        throw 'Backend did not return a conversation id. No messages sent.'
    }

    Write-Host "Sending $Count messages to '$RecipientUsername' ($marker)."
    for ($number = 1; $number -le $Count; $number++) {
        $content = '{0} [{1:D3}/{2:D3}]' -f $marker, $number, $Count
        $messageBody = @{ content = $content } | ConvertTo-Json -Compress
        $null = Invoke-RestMethod -Method Post `
            -Uri "$BaseUrl/dm/conversations/$conversationId/messages" `
            -Headers $headers -ContentType 'application/json; charset=utf-8' `
            -Body $messageBody
        $sent++
        if ($number % 10 -eq 0) { Write-Host "Sent $number/$Count" }
    }

    $found = @()
    $before = $null
    for ($pageNumber = 1; $pageNumber -le 20 -and $found.Count -lt $Count; $pageNumber++) {
        $url = "$BaseUrl/dm/conversations/$conversationId/messages?limit=100"
        if ($before) { $url += '&before=' + [uri]::EscapeDataString($before) }
        $page = @(Invoke-RestMethod -Method Get -Uri $url -Headers $headers)
        $page = @($page | Where-Object { $null -ne $_ })
        $found += @($page | Where-Object { $_.content -like "$marker *" })
        if ($page.Count -lt 100) { break }
        $before = $page[0].id
    }

    $uniqueIds = @($found | Select-Object -ExpandProperty id -Unique)
    Write-Host "History check: $($found.Count)/$Count messages, $($uniqueIds.Count) unique IDs."
    if ($found.Count -ne $Count -or $uniqueIds.Count -ne $Count) {
        throw 'History verification failed; check pagination and duplicates in the client.'
    }
    Write-Host "Done. Open the DM with '$RecipientUsername' and scroll upward. Marker: $marker"
}
catch {
    $status = Get-StatusText $_
    Write-Error "Stopped after $sent/$Count messages. $status. Marker: $marker. Do not blindly rerun; a new run sends another batch."
    exit 1
}
