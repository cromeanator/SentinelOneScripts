<#
.SCRIPTNAME
    Patch-LocalUpgradeDowngradeAttack.ps1

.PUBLISHER
    CrimzonHost LLC (Crimzonhost.com) | Josh Lytle (https://github.com/cromeanator)

.CREATED
    May 15, 2025

.LAST REVISED
    May 16, 2025

.DESCRIPTION
    This script connects to the SentinelOne API. It retrieves ACTIVE accounts.
    For each account, it retrieves all ACTIVE sites.
    For each site, it fetches its policy: if the policy is NOT inherited, it checks 
    'allowUnprotectByApprovedProcess'.
    For each non-inherited site, it retrieves all groups (state filter removed for groups).
    For each group, it fetches its policy: if the policy is NOT inherited, it checks 
    'allowUnprotectByApprovedProcess'.
    It then patches the 'allowUnprotectByApprovedProcess' setting to False where applicable.
    The script uses pagination: up to 2000 accounts, 2000 sites per account, and 600 groups per site.
    It reports any changed policies to CSV files.
    The script runs directly upon execution and filters entities by state='active' (except groups) via API calls.
    The SentinelOne authentication function is now embedded within this script.

.AUTH DEPENDENCY
    The SentinelOne authentication function (Invoke-S1Auth) is embedded in this script.

.REQUIREMENTS
    • PowerShell 5.1 or newer
    • Network access to SentinelOne API endpoint
    • Valid SentinelOne API token and console URL

.HOW TO RUN
    Save this script (e.g., Patch-LocalUpgradeDowngradeAttack.ps1) and run it from PowerShell:
    .\Patch-LocalUpgradeDowngradeAttack.ps1
#>

# --- Script Configuration & Initialization ---
Set-StrictMode -Version Latest # Helps catch common scripting errors

# --- Embedded SentinelOne Authentication Function ---
function Invoke-S1Auth {
    [CmdletBinding()]
    param (
        [string]$ApiTokenInput, 
        [string]$BaseUrlInput  
    )

    if (-not $ApiTokenInput) {
        $secureToken = Read-Host "Enter SentinelOne API Token" -AsSecureString
        $ApiToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
        )
    } else {
        $ApiToken = $ApiTokenInput
    }

    if (-not $BaseUrlInput) {
        $BaseUrl = Read-Host "Enter SentinelOne Console URL (e.g., https://usea1.sentinelone.net)"
    } else {
        $BaseUrl = $BaseUrlInput
    }

    if ($BaseUrl -notlike "http*://*") {
        Write-Error "Invalid SentinelOne Console URL format. It should start with http:// or https://."
        return $null 
    }
    
    $BaseUrl = $BaseUrl.TrimEnd('/')

    $headers = @{
        "Authorization" = "ApiToken $ApiToken"
        "Accept"        = "application/json"
    }

    $testApiEndpoint = "$BaseUrl/web/api/v2.1/users" 
    Write-Host "Attempting to test connection to '$testApiEndpoint'..."
    try {
        $null = Invoke-RestMethod -Uri $testApiEndpoint -Headers $headers -Method Get -ErrorAction Stop 
        Write-Host "✅ Connected to SentinelOne successfully using URL: $BaseUrl" -ForegroundColor Green
        return @{
            ApiToken = $ApiToken 
            BaseUrl  = $BaseUrl  
            Headers  = $headers
        }
    } catch {
        Write-Error "❌ Failed to connect to SentinelOne at '$testApiEndpoint'. Error: $($_.Exception.Message)"
        Write-Warning "Please verify your API token, Console URL, and network connectivity."
        return $null 
    }
}
# --- End Embedded SentinelOne Authentication Function ---

# --- Reusable Paginated GET Function ---
function Invoke-S1PaginatedGet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$BaseUri,
        [Parameter(Mandatory=$true)]
        [string]$EndpointPath, 
        [Parameter(Mandatory=$false)]
        [hashtable]$InitialQueryParams = @{}, 
        [Parameter(Mandatory=$true)]
        [hashtable]$Headers,
        [Parameter(Mandatory=$true)]
        [string]$DataTypeForLogging,
        [Parameter(Mandatory=$true)]
        [int]$PageLimit, 
        [Parameter(Mandatory=$true)]
        [int]$MaxItemsToProcessInScript 
    )

    $allItems = [System.Collections.Generic.List[object]]::new()
    $fetchedItemsCount = 0
    $cursor = $null
    $totalItemsFromApi = 0
    $pageNumber = 1

    do {
        $currentQueryParams = $InitialQueryParams.Clone() 
        $currentQueryParams["limit"] = $PageLimit 
        if ($null -ne $cursor) {
            $currentQueryParams["cursor"] = $cursor
        }

        $queryStringParts = @()
        foreach ($key in $currentQueryParams.Keys) {
            $queryStringParts += "$($key)=$($currentQueryParams[$key])"
        }
        $queryString = if ($queryStringParts.Count -gt 0) { "?" + ($queryStringParts -join "&") } else { "" }
        
        $requestUri = "$BaseUri$EndpointPath$queryString"
        
        Write-Host "  Fetching page $pageNumber for $DataTypeForLogging from '$requestUri'..."
        $response = $null
        try {
            $response = Invoke-RestMethod -Uri $requestUri -Headers $Headers -Method Get -ErrorAction Stop
        } catch {
            Write-Warning "    Failed to fetch page $pageNumber for $DataTypeForLogging. Error: $($_.Exception.Message)"
            break 
        }

        if ($null -eq $response) {
            Write-Warning "    API response for page $pageNumber of $DataTypeForLogging was null."
            break
        }

        $pageData = $null
        if ($response.PSObject.Properties.Name -contains 'data') {
            if ($DataTypeForLogging -eq "sites" -and $response.data.PSObject.Properties.Name -contains 'sites' -and $response.data.sites -is [System.Array]) {
                $pageData = $response.data.sites
            } elseif (($DataTypeForLogging -eq "accounts" -or $DataTypeForLogging -eq "groups") -and $response.data -is [System.Array]) {
                $pageData = $response.data
            } else {
                 Write-Warning "    Unexpected data structure in response for $DataTypeForLogging page $pageNumber. 'data' field found, but not the expected array or nested array."
            }
        } else {
            Write-Warning "    API response for page $pageNumber of $DataTypeForLogging does not contain a 'data' property as expected."
        }
        
        if ($null -ne $pageData) {
            $allItems.AddRange($pageData)
            $fetchedItemsCount += $pageData.Count
            Write-Host "    Fetched $($pageData.Count) items on page $pageNumber for $DataTypeForLogging. Total fetched so far: $fetchedItemsCount."
        }

        if ($pageNumber -eq 1 -and $response.PSObject.Properties.Name -contains 'pagination' -and $null -ne $response.pagination) {
            $totalItemsFromApi = $response.pagination.totalItems | ForEach-Object { if ($_ -is [int]) { $_ } else { 0 } } 
        }
        
        $cursor = $null 
        if ($response.PSObject.Properties.Name -contains 'pagination' -and $null -ne $response.pagination -and $response.pagination.PSObject.Properties.Name -contains 'nextCursor') {
            $cursor = $response.pagination.nextCursor
        }

        $pageNumber++

    } while ($null -ne $cursor -and $fetchedItemsCount -lt $MaxItemsToProcessInScript -and $fetchedItemsCount -lt $totalItemsFromApi) 
    
    return @{ Data = $allItems; TotalItemsFromApi = $totalItemsFromApi; ProcessedItemsCount = $fetchedItemsCount }
}
# --- End Reusable Paginated GET Function ---


# --- Main Script Logic ---
$processingLimitWarnings = [System.Collections.Generic.List[string]]::new()

# Arrays for CSV reporting of changed items
$csvChangedAccountPolicies = [System.Collections.Generic.List[object]]::new()
$csvChangedSitePolicies = [System.Collections.Generic.List[object]]::new()
$csvChangedGroupPolicies = [System.Collections.Generic.List[object]]::new()

Write-Host "`nAttempting SentinelOne authentication using embedded Invoke-S1Auth function..."
$authResult = $null
try {
    $authResult = Invoke-S1Auth 
}
catch {
    $exceptionDuringAuthCall = $_
    Write-Error "An exception occurred during the Invoke-S1Auth call: $($exceptionDuringAuthCall.Exception.Message)"
    $exceptionDuringAuthCall | Format-List * -Force 
    exit 1 
}

if ($null -eq $authResult) {
    Write-Error "FATAL: Authentication failed. The embedded 'Invoke-S1Auth' function returned null."
    exit 1
}
if ($authResult -isnot [System.Collections.Hashtable]) {
    Write-Error "FATAL: Authentication result is not a Hashtable as expected. Type received: $($authResult.GetType().FullName)"
    exit 1
}
if (-not $authResult['BaseUrl'] -or -not $authResult['Headers']) {
    Write-Error "FATAL: Authentication result is missing 'BaseUrl' or 'Headers'."
    exit 1
}

Write-Host "[+] SentinelOne authentication successful." -ForegroundColor Green
$baseUrl = $authResult['BaseUrl'] 
$headers = $authResult['Headers'] 

$patchedAccounts = @() 
$patchedSites = @()    
$patchedGroups = @()   

# Define pagination parameters
$defaultPageLimit = 1000
$defaultMaxItemsToProcess = 2000
$groupsPageLimit = 300
$groupsMaxItemsToProcess = 600 

# Step 1: Get all ACTIVE accounts
$accountsQueryParams = @{ "states" = "active" } 
$accountsResult = Invoke-S1PaginatedGet -BaseUri $baseUrl -EndpointPath "/web/api/v2.1/accounts" `
    -InitialQueryParams $accountsQueryParams -Headers $headers -DataTypeForLogging "accounts" `
    -PageLimit $defaultPageLimit -MaxItemsToProcessInScript $defaultMaxItemsToProcess
$accounts = $accountsResult.Data
Write-Host "Retrieved $($accounts.Count) total ACTIVE accounts (API reported $($accountsResult.TotalItemsFromApi) total)." -ForegroundColor Green
if ($accountsResult.TotalItemsFromApi -gt $defaultMaxItemsToProcess) {
    $processingLimitWarnings.Add("WARNING: API reported $($accountsResult.TotalItemsFromApi) total accounts, but script processed a maximum of $defaultMaxItemsToProcess.")
}

if ($accounts.Count -eq 0) {
    Write-Host "No ACTIVE accounts found to process. Exiting."
    exit 0
}

# Step 2: Loop through each (now already active) account
foreach ($account in $accounts) {
    if ($null -eq $account -or -not $account.PSObject.Properties['id'] -or -not $account.PSObject.Properties['name']) {
        Write-Warning "Skipping an account entry due to missing 'id' or 'name' property, or entry is null."
        continue
    }

    $accountId = $account.id
    $accountName = $account.name
    $accountStateLog = if ($account.PSObject.Properties.Name -contains 'state') { $account.state } else { "N/A" }
    Write-Host "`nProcessing Account: '$($accountName)' (ID: $($accountId)) (State: $accountStateLog)" -ForegroundColor Cyan

    # Step 3: Get account policy
    $accountPolicy = $null
    try {
        $accountPolicyResponse = Invoke-RestMethod -Uri "$baseUrl/web/api/v2.1/accounts/$accountId/policy" -Headers $headers -Method Get -ErrorAction Stop
        $accountPolicy = $accountPolicyResponse.data 
    } catch {
        Write-Warning ("    Failed to get account policy for '$($accountName)'. Error: $($_.Exception.Message)")
        continue
    }

    # Step 4: Check if patch needed for account
    if ($null -eq $accountPolicy) {
        Write-Warning "    Account policy data for '$($accountName)' is null. Skipping policy patch for this account."
    } elseif ($accountPolicy.allowUnprotectByApprovedProcess -eq $true) { 
        $policyPatchPayload = @{ data = @{ allowUnprotectByApprovedProcess = $false } } | ConvertTo-Json -Depth 3
        try {
            $null = Invoke-RestMethod -Uri "$baseUrl/web/api/v2.1/accounts/$accountId/policy" -Headers $headers -Method Put -Body $policyPatchPayload -ContentType 'application/json' -ErrorAction Stop
            Write-Host "    Patched account policy for '$($accountName)'." -ForegroundColor Yellow
            $patchedAccounts += [PSCustomObject]@{ AccountName = $accountName; AccountId = $accountId }
            $csvChangedAccountPolicies.Add([PSCustomObject]@{
                AccountName                            = $accountName
                AccountId                              = $accountId
                AllowUnprotectByApprovedProcess_Before = $true
                AllowUnprotectByApprovedProcess_After  = $false
            })
        } catch {
            Write-Warning ("    Failed to patch account policy for '$($accountName)'. Error: $($_.Exception.Message)")
        }
    } else {
        Write-Host "    Account policy for '$($accountName)' already secure." -ForegroundColor Gray
    }

    # Step 5: Get all ACTIVE sites for this account
    $sitesQueryParams = @{ "accountIds" = $accountId; "state" = "active" }
    $sitesResult = Invoke-S1PaginatedGet -BaseUri $baseUrl -EndpointPath "/web/api/v2.1/sites" `
        -InitialQueryParams $sitesQueryParams -Headers $headers -DataTypeForLogging "sites" `
        -PageLimit $defaultPageLimit -MaxItemsToProcessInScript $defaultMaxItemsToProcess
    $sites = $sitesResult.Data 
    Write-Host "  Retrieved $($sites.Count) total ACTIVE sites for account '$($accountName)' (API reported $($sitesResult.TotalItemsFromApi) total)." -ForegroundColor Green
    if ($sitesResult.TotalItemsFromApi -gt $defaultMaxItemsToProcess) { 
        $processingLimitWarnings.Add("WARNING: API reported $($sitesResult.TotalItemsFromApi) total ACTIVE sites for account '$($accountName)', but script processed a maximum of $defaultMaxItemsToProcess.")
    }

    # Step 6: Loop through sites
    foreach ($site in $sites) {
        if ($null -eq $site -or -not $site.PSObject.Properties['id'] -or -not $site.PSObject.Properties['name']) {
            Write-Warning "Skipping a site entry due to missing 'id' or 'name' property, or entry is null."
            continue
        }

        $siteId = $site.id
        $siteName = $site.name
        $siteStateLog = if ($site.PSObject.Properties.Name -contains 'state') { $site.state } else { "N/A" }
        Write-Host "    Processing Site: '$($siteName)' (ID: $($siteId)) (State: $siteStateLog)" -ForegroundColor Cyan

        # Step 7: Get site policy
        $sitePolicy = $null
        try {
            $sitePolicyResponse = Invoke-RestMethod -Uri "$baseUrl/web/api/v2.1/sites/$siteId/policy" -Headers $headers -Method Get -ErrorAction Stop
            $sitePolicy = $sitePolicyResponse.data 
        } catch {
            Write-Warning ("        Failed to get site policy for '$($siteName)'. Error: $($_.Exception.Message)")
            continue
        }
        
        if ($null -eq $sitePolicy) {
             Write-Warning "        Site policy data for '$($siteName)' is null. Skipping policy patch for this site."
        } elseif ($sitePolicy.PSObject.Properties.Name -contains 'inheritedFrom' -and $null -ne $sitePolicy.inheritedFrom -and $sitePolicy.inheritedFrom -ne "") {
            Write-Host ("        Site policy for '$($siteName)' is inherited from '$($sitePolicy.inheritedFrom)'; skipping patch.") -ForegroundColor Gray
        } elseif ($sitePolicy.allowUnprotectByApprovedProcess -eq $true) { 
            $policyPatchPayload = @{ data = @{ allowUnprotectByApprovedProcess = $false } } | ConvertTo-Json -Depth 3
            try {
                $null = Invoke-RestMethod -Uri "$baseUrl/web/api/v2.1/sites/$siteId/policy" -Headers $headers -Method Put -Body $policyPatchPayload -ContentType 'application/json' -ErrorAction Stop
                Write-Host "        Patched site policy for '$($siteName)'." -ForegroundColor Yellow
                $patchedSites += [PSCustomObject]@{ AccountName = $accountName; AccountId = $accountId; SiteName = $siteName; SiteId = $siteId }
                $csvChangedSitePolicies.Add([PSCustomObject]@{
                    ParentAccountName                      = $accountName
                    ParentAccountId                        = $accountId
                    SiteName                               = $siteName
                    SiteId                                 = $siteId
                    AllowUnprotectByApprovedProcess_Before = $true
                    AllowUnprotectByApprovedProcess_After  = $false
                })
            } catch {
                Write-Warning ("        Failed to patch site policy for '$($siteName)'. Error: $($_.Exception.Message)")
            }
        } else {
            Write-Host "        Site policy for '$($siteName)' already secure." -ForegroundColor Gray
        }

        # Step 8: Get groups for this site (state filter removed)
        $groupsQueryParams = @{ "siteIds" = $siteId } # Removed "state" = "active"
        $groupsResult = Invoke-S1PaginatedGet -BaseUri $baseUrl -EndpointPath "/web/api/v2.1/groups" `
            -InitialQueryParams $groupsQueryParams -Headers $headers -DataTypeForLogging "groups" `
            -PageLimit $groupsPageLimit -MaxItemsToProcessInScript $groupsMaxItemsToProcess
        $groups = $groupsResult.Data 
        Write-Host "      Retrieved $($groups.Count) total groups for site '$($siteName)' (API reported $($groupsResult.TotalItemsFromApi) total)." -ForegroundColor Green
        if ($groupsResult.TotalItemsFromApi -gt $groupsMaxItemsToProcess) { 
            $processingLimitWarnings.Add("WARNING: API reported $($groupsResult.TotalItemsFromApi) total groups for site '$($siteName)', but script processed a maximum of $groupsMaxItemsToProcess.")
        }

        # Step 9: Loop through groups
        foreach ($group in $groups) {
            if ($null -eq $group -or -not $group.PSObject.Properties['id'] -or -not $group.PSObject.Properties['name']) {
                Write-Warning "Skipping a group entry due to missing 'id' or 'name' property, or entry is null."
                continue
            }

            $groupId = $group.id
            $groupName = $group.name
            # Removed state logging for groups as it's not being filtered by state
            Write-Host "            Processing Group: '$($groupName)' (ID: $($groupId))" -ForegroundColor DarkCyan

            # Step 10: Get group policy
            $groupPolicy = $null
            try {
                $groupPolicyResponse = Invoke-RestMethod -Uri "$baseUrl/web/api/v2.1/groups/$groupId/policy" -Headers $headers -Method Get -ErrorAction Stop
                $groupPolicy = $groupPolicyResponse.data 
            } catch {
                Write-Warning ("            Failed to get group policy for '$($groupName)'. Error: $($_.Exception.Message)")
                continue
            }
            
            if ($null -eq $groupPolicy) {
                Write-Warning "            Group policy data for '$($groupName)' is null. Skipping policy patch for this group."
            } elseif ($groupPolicy.PSObject.Properties.Name -contains 'inheritedFrom' -and $null -ne $groupPolicy.inheritedFrom -and $groupPolicy.inheritedFrom -ne "") {
                Write-Host ("            Group policy for '$($groupName)' is inherited from '$($groupPolicy.inheritedFrom)'; skipping patch.") -ForegroundColor Gray
            } elseif ($groupPolicy.allowUnprotectByApprovedProcess -eq $true) { 
                $policyPatchPayload = @{ data = @{ allowUnprotectByApprovedProcess = $false } } | ConvertTo-Json -Depth 3
                try {
                    $null = Invoke-RestMethod -Uri "$baseUrl/web/api/v2.1/groups/$groupId/policy" -Headers $headers -Method Put -Body $policyPatchPayload -ContentType 'application/json' -ErrorAction Stop
                    Write-Host "            Patched group policy for '$($groupName)'." -ForegroundColor Yellow
                    $patchedGroups += [PSCustomObject]@{ AccountName = $accountName; AccountId = $accountId; SiteName = $siteName; SiteId = $siteId; GroupName = $groupName; GroupId = $groupId }
                    $csvChangedGroupPolicies.Add([PSCustomObject]@{
                        ParentAccountName                      = $accountName
                        ParentAccountId                        = $accountId
                        ParentSiteName                         = $siteName
                        ParentSiteId                           = $siteId
                        GroupName                              = $groupName
                        GroupId                                = $groupId
                        AllowUnprotectByApprovedProcess_Before = $true
                        AllowUnprotectByApprovedProcess_After  = $false
                    })
                } catch {
                    Write-Warning ("            Failed to patch group policy for '$($groupName)'. Error: $($_.Exception.Message)")
                }
            } else {
                Write-Host "            Group policy for '$($groupName)' already secure." -ForegroundColor Gray
            }
        } # End foreach group
    } # End foreach site
} # End foreach account

# --- Summary ---
Write-Host "`n-----------------------------------"
Write-Host "--- Summary of Patched Items (Console) ---" 
Write-Host "-----------------------------------"

Write-Host "`nPatched Accounts:" -ForegroundColor Yellow
if ($patchedAccounts.Count -gt 0) {
    $patchedAccounts | Format-Table -AutoSize
} else {
    Write-Host "None." -ForegroundColor Gray
}

Write-Host "`nPatched Sites:" -ForegroundColor Yellow
if ($patchedSites.Count -gt 0) {
    $patchedSites | Format-Table -AutoSize
} else {
    Write-Host "None." -ForegroundColor Gray
}

Write-Host "`nPatched Groups:" -ForegroundColor Yellow
if ($patchedGroups.Count -gt 0) {
    $patchedGroups | Format-Table -AutoSize
} else {
    Write-Host "None." -ForegroundColor Gray
}

# --- CSV Export of Changed Policies ---
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$scriptPath = $PSScriptRoot 
if ($csvChangedAccountPolicies.Count -gt 0) {
    $filePath = Join-Path $scriptPath "ChangedAccountPolicies_$timestamp.csv"
    $csvChangedAccountPolicies | Export-Csv -Path $filePath -NoTypeInformation
    Write-Host "`nExported changed account policies to '$filePath'" -ForegroundColor Green
}
if ($csvChangedSitePolicies.Count -gt 0) {
    $filePath = Join-Path $scriptPath "ChangedSitePolicies_$timestamp.csv"
    $csvChangedSitePolicies | Export-Csv -Path $filePath -NoTypeInformation
    Write-Host "Exported changed site policies to '$filePath'" -ForegroundColor Green
}
if ($csvChangedGroupPolicies.Count -gt 0) {
    $filePath = Join-Path $scriptPath "ChangedGroupPolicies_$timestamp.csv"
    $csvChangedGroupPolicies | Export-Csv -Path $filePath -NoTypeInformation
    Write-Host "Exported changed group policies to '$filePath'" -ForegroundColor Green
}
if ($csvChangedAccountPolicies.Count -eq 0 -and $csvChangedSitePolicies.Count -eq 0 -and $csvChangedGroupPolicies.Count -eq 0) {
    Write-Host "`nNo policies were changed that required CSV export." -ForegroundColor Cyan
}


# --- Report on Processing Limits ---
if ($processingLimitWarnings.Count -gt 0) {
    Write-Host "`n-----------------------------------" -ForegroundColor Red
    Write-Host "--- PROCESSING LIMIT WARNINGS ---" -ForegroundColor Red
    Write-Host "-----------------------------------" -ForegroundColor Red
    foreach ($warning in $processingLimitWarnings) {
        Write-Warning $warning
    }
    Write-Warning "The script has specific processing limits per category: Accounts (max $defaultMaxItemsToProcess), Sites per Account (max $defaultMaxItemsToProcess), Groups per Site (max $groupsMaxItemsToProcess)."
}


Write-Host "`nPatch process completed."
exit 0
