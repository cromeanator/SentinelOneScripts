
function Invoke-S1Auth {
    param (
        # Name under which the secret key will be stored in the Windows Credential Manager
        [string]$CredentialName = "S1_API_Secret"
    )

    # ------------------------------
    # Ensure the CredentialManager module is installed
    # This module allows secure storage and retrieval of credentials
    # ------------------------------
    if (-not (Get-Module -ListAvailable -Name CredentialManager)) {
        Write-Host "CredentialManager module not found. Installing..." -ForegroundColor Yellow
        try {
            Install-Module -Name CredentialManager -Scope CurrentUser -Force -AllowClobber
        } catch {
            Write-Error "Failed to install CredentialManager module. $_"
            return
        }
    }

    # Import the CredentialManager module
    Import-Module CredentialManager

    # ------------------------------
    # Prompt the user for the SentinelOne API URL
    # This is the base URL, e.g., https://usea1-pax8-03.sentinelone.net
    # ------------------------------
    $url = Read-Host "Enter the S1 API base URL (e.g., https://usea1-pax8-03.sentinelone.net)"

    # ------------------------------
    # Attempt to retrieve the stored secret key from Windows Credential Manager
    # If not present, prompt the user and store it securely
    # ------------------------------
    $storedSecret = Get-StoredCredential -Target $CredentialName -ErrorAction SilentlyContinue

    if (-not $storedSecret) {
        # Prompt user to enter the API secret key securely
        $secureSecret = Read-Host "Enter your S1 API secret key" -AsSecureString

        # Save it securely in Credential Manager
        New-StoredCredential -Target $CredentialName -UserName "S1User" -Password $secureSecret -Persist LocalMachine
    } else {
        $secureSecret = $storedSecret.Password
    }

    # ------------------------------
    # Convert the secure string to plain text for use in the HTTP header
    # ------------------------------
    $plainSecret = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureSecret)
    )

    # ------------------------------
    # Prepare the Authorization header using the S1 API token format
    # ------------------------------
    $headers = @{
        "Authorization" = "ApiToken $plainSecret"
    }

    # ------------------------------
    # Use the /system/info endpoint to test authentication
    # This endpoint provides info about the API environment and confirms auth
    # ------------------------------
    try {
        $testEndpoint = "$url/web/api/v2.1/system/info"
        $response = Invoke-RestMethod -Uri $testEndpoint -Headers $headers -Method Get

        Write-Host "Authentication successful. System Info:" -ForegroundColor Green
        $response | ConvertTo-Json -Depth 3
    } catch {
        # Print any error from the API call
        Write-Error "Authentication failed or URL is incorrect: $_"
    }
}
