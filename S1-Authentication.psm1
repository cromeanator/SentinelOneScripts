<#
.SYNOPSIS
    Authenticates to the SentinelOne API by prompting for the API token.

.DESCRIPTION
    This function authenticates against the SentinelOne API by securely prompting the user for the API token.
    If authentication fails due to invalid credentials, it prompts the user again and retries. The token is 
    never stored on disk.

.NOTES
    Author: Josh Lytle
    Modified: 2025-05-16
    GitHub: https://github.com/cromeanator

.EXAMPLE
    Invoke-S1Auth
#>

function Invoke-S1Auth {
    [CmdletBinding()]
    param()

    Write-Host "`n[*] Attempting to authenticate with SentinelOne..." -ForegroundColor Cyan

    $ApiToken = $null

    # Prompt user for token every time
    while (-not $ApiToken) {
        $SecureStringToken = Read-Host "Enter SentinelOne API token" -AsSecureString

        # Safely convert SecureString to plain string
        try {
            if ($SecureStringToken -is [System.Security.SecureString]) {
                $ApiToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureStringToken)
                )
            } elseif ($SecureStringToken -is [string]) {
                $ApiToken = $SecureStringToken
            } else {
                throw "[!] Invalid API token type. Must be a SecureString or string."
            }
        } catch {
            Write-Warning "[!] Error converting token: $_"
            continue
        }

        # Use configured SentinelOne URL
        if (-not $Global:S1BaseUrl) {
            $Global:S1BaseUrl = Read-Host "Enter SentinelOne Base URL (e.g. https://company.sentinelone.net)"
        }

        $headers = @{ Authorization = "ApiToken $ApiToken" }

        try {
            $response = Invoke-RestMethod -Uri "$($Global:S1BaseUrl)/web/api/v2.1/users" -Headers $headers -Method GET -ErrorAction Stop

            Write-Host "[+] Authentication successful!" -ForegroundColor Green
            $Global:S1AuthHeader = $headers
            return
        } catch {
            if ($_.ErrorDetails.Message -match "Authentication Failed" -or $_.Exception.Message -match "401") {
                Write-Warning "[!] Authentication failed: Invalid API token or URL."
                $ApiToken = $null
                continue
            } else {
                Write-Error "[!] Unexpected error during authentication: $_"
                break
            }
        }
    }
}
