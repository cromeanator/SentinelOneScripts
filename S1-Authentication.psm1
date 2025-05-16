<#
.SYNOPSIS
    Authenticates to the SentinelOne API using a stored or prompted API token.

.DESCRIPTION
    This function authenticates against the SentinelOne API using either a saved SecureString API token
    or prompts the user securely if none is saved. If authentication fails due to invalid credentials,
    it prompts the user again and retries. Token type is verified to avoid conversion errors.

.NOTES
    Author: Josh Lytle
    Modified: 2025-05-15
    GitHub: https://github.com/cromeanator

.EXAMPLE
    Invoke-S1Auth
#>

function Invoke-S1Auth {
    [CmdletBinding()]
    param()

    Write-Host "`n[*] Attempting to authenticate with SentinelOne..." -ForegroundColor Cyan

    # Load stored token if available
    $TokenPath = "$PSScriptRoot\s1token.xml"
    $SecureStringToken = $null
    $ApiToken = $null

    if (Test-Path $TokenPath) {
        try {
            $SecureStringToken = Import-Clixml -Path $TokenPath
        } catch {
            Write-Warning "[!] Failed to import token. It may be corrupted or inaccessible."
        }
    }

    # Prompt user if no token found or if failed to load
    while (-not $ApiToken) {
        if (-not $SecureStringToken) {
            $SecureStringToken = Read-Host "Enter SentinelOne API token" -AsSecureString
        }

        # Safely convert SecureString to plain string, or handle string directly
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
            $SecureStringToken = $null
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
                $SecureStringToken = $null
                $ApiToken = $null
                continue
            } else {
                Write-Error "[!] Unexpected error during authentication: $_"
                break
            }
        }
    }
}
