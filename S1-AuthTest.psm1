<#
.SYNOPSIS
    Authenticates to the SentinelOne API by prompting for the API token.

.DESCRIPTION
    This function authenticates against the SentinelOne API by securely prompting the user for the API token.
    If authentication fails due to invalid credentials, it prompts the user again and retries. The token is 
    never stored on disk.

.NOTES
    Modified: 2025-05-16
    CrimzonHost LLC (Crimzonhost.com) | Josh Lytle (https://github.com/cromeanator)

.EXAMPLE
    Invoke-S1Auth
#>
function Invoke-S1Auth {
    [CmdletBinding()]
    param (
        [string]$ApiToken,
        [string]$BaseUrl
    )

    if (-not $ApiToken) {
        $secureToken = Read-Host "Enter SentinelOne API Token" -AsSecureString
        $ApiToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
        )
    }

    if (-not $BaseUrl) {
        $BaseUrl = Read-Host "Enter SentinelOne Console URL (e.g., https://usea1.sentinelone.net)"
    }

    $headers = @{
        "Authorization" = "ApiToken $ApiToken"
        "Accept"        = "application/json"
    }

    try {
        $test = Invoke-RestMethod -Uri "$BaseUrl/web/api/v2.1/users" -Headers $headers -Method Get -ErrorAction Stop
        Write-Host "✅ Connected to SentinelOne successfully." -ForegroundColor Green

        return @{
            ApiToken = $ApiToken
            BaseUrl  = $BaseUrl
            Headers  = $headers
        }
    } catch {
        Write-Error "❌ Failed to connect to SentinelOne: $($_.Exception.Message)"
        exit 1
    }
}
