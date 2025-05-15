function Invoke-S1Auth {
    <#
    .SYNOPSIS
    Securely authenticates to the SentinelOne Management Console API.

    .DESCRIPTION
    Prompts the user for a SentinelOne Management Console URL and API Token. 
    Authenticates securely using a secure string in memory only. 
    If authentication fails, the user is prompted to re-enter credentials.
    The token is never stored locally on disk, ensuring maximum security.

    .PARAMETER ApiUrl
    The base URL of the SentinelOne Management Console, e.g. "https://yourtenant.sentinelone.net".

    .OUTPUTS
    Hashtable containing the API token, base URL, and headers to use in future API requests.

    .EXAMPLE
    $auth = Invoke-S1Auth
    Invoke-RestMethod -Uri "$($auth.ApiUrl)/web/api/v2.1/sites" -Headers $auth.Headers

    .NOTES
    Author: Josh (CrimzonHost)
    Updated: May 2025
    Version: 2.0 - Secure memory-only authentication with retry support.
    #>

    param (
        [string]$ApiUrl
    )

    do {
        if (-not $ApiUrl) {
            $ApiUrl = Read-Host "Enter your SentinelOne Management Console URL (e.g., https://company.sentinelone.net)"
        }

        $SecureToken = Read-Host "Enter your SentinelOne API Token" -AsSecureString
        $ApiToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureToken)
        )

        Write-Host "`n[*] Attempting to authenticate with SentinelOne..." -ForegroundColor Cyan

        try {
            $headers = @{ Authorization = "ApiToken $ApiToken" }
            $response = Invoke-RestMethod -Uri "$ApiUrl/web/api/v2.1/users" -Headers $headers -Method Get -ErrorAction Stop

            Write-Host "[+] Authentication successful. Logged in as: $($response.data.username)" -ForegroundColor Green

            return @{
                ApiToken = $ApiToken
                ApiUrl   = $ApiUrl
                Headers  = $headers
            }
        }
        catch {
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode.Value__ -eq 401) {
                Write-Warning "[!] Authentication failed: Invalid API token or URL. Please try again."
                $ApiUrl = $null # Let user re-enter the URL in case it's incorrect too
            } else {
                Write-Error "Unexpected error: $($_.Exception.Message)"
                return $null
            }
        }

    } while ($true)
}
