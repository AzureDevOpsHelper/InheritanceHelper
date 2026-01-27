param (
    [Parameter(Mandatory = $false)]
    [string]$UserIdentifier,
    
    [Parameter(Mandatory = $false)]
    [string]$TargetGroupName,
    
    [Parameter(Mandatory = $false)]
    [string]$OrgName,

    [Parameter(Mandatory = $false)]
    [string]$ProjectName,

    [switch]$ExportJson
)

function Get-EntraToken {
    if (Get-Module -Name Az -ListAvailable) {
        try {
            Write-Host "Found Az module, attempting to use it to get an access token."
            $result = Get-AzAccessToken -ResourceUrl '499b84ac-1321-427f-aa17-267ca6975798'
            Clear-Host
        }
        catch {
            Write-Host "AZ login will open a modal identity picker in the top left of the screen, please choose the account you want to use."
            Write-Host "It may take a few seconds to load, please be patient."  
            Write-Host "It will then ask you to pick a subscription, please choose a subscription that is associated with the tenant that backs your org."
            Connect-AzAccount 
            $result = Get-AzAccessToken -ResourceUrl '499b84ac-1321-427f-aa17-267ca6975798'
            Clear-Host
        } 
    }
    else {
        Clear-Host
        Write-Host "It seems that the Az module is not installed or not working properly."
        Write-Host "Please wait while we attempt to install the Az module."
        Install-Module -Name Az -Repository PSGallery -Force -AllowClobber -Verbose -Scope CurrentUser -ErrorAction Stop
        Clear-Host
        Write-Host "The Az module has been installed successfully."
        Write-Host "AZ login will open a modal identity picker in the top left of the screen, please choose the account you want to use."
        Write-Host "It may take a few seconds to load, please be patient."  
        Write-Host "It will then ask you to pick a subscription, please choose a subscription that is associated with the tenant that backs your org."
        Connect-AzAccount -WarningAction 'SilentlyContinue' -ErrorAction 'Stop' -InformationAction 'SilentlyContinue' -ProgressAction 'SilentlyContinue'
        $result = Get-AzAccessToken -ResourceUrl '499b84ac-1321-427f-aa17-267ca6975798'        
        Clear-Host
    }
    if ($result.Token -is [System.Security.SecureString]) {
        $plainToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($result.Token))
    } 
    else {
        $plainToken = $result.Token
    }
    $AuthHeader = "Bearer $plainToken"
    $result | Add-Member -NotePropertyName 'AuthHeader' -NotePropertyValue $AuthHeader -Force
    return $result
}

function Get-GraphToken {
    $result = Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com/"
    if ($result.Token -is [System.Security.SecureString]) {
        $plainToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($result.Token))
    }
    else {
        $plainToken = $result.Token
    }
    $AuthHeader = "Bearer $plainToken"
    $result | Add-Member -NotePropertyName 'AuthHeader' -NotePropertyValue $AuthHeader -Force
    return $result
}

function GET-AzureDevOpsRestAPI {
    param (
        [string]$Authheader,
        [string]$RestAPIUrl,
        [string]$Method = 'GET'
    )

    $Headers = @{
        Authorization           = $Authheader
        "X-TFS-FedAuthRedirect" = "Suppress"
    }
    $params = @{
        Uri                     = $RestAPIUrl
        Headers                 = $headers
        Method                  = $Method
        ContentType             = 'application/json'
        StatusCodeVariable      = 'statusCode' 
        ResponseHeadersVariable = 'responseHeaders'
    }
    try {   
        $WP = $WarningPreference
        $WarningPreference = 'SilentlyContinue'
        $PP = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        $results = New-Object "System.Collections.Generic.Dictionary[[String],[PSCustomObject]]"
        try {
            $result = Invoke-RestMethod @params 
        }
        catch {
            if ($_.Exception.Response.StatusCode.value__ -eq 429) {
                $RetryAfter = 30.0
                [double]::TryParse($responseHeaders."Retry-After", [ref]$RetryAfter)
                Write-Warning "Throttling (with Error: $($_.Exception.Response.StatusCode.value__)) sleeping for $RetryAfter seconds before resuming"
                $RetryAfter += 2
                Start-Sleep -Seconds $RetryAfter
                if ($null -eq $result) {
                    $result = GET-AzureDevOpsRestAPI $Authheader $RestAPIUrl
                }
            }
            else {
                throw $_
            }
        }
        $results.Add("results", $result)
        $results.Add("responseHeaders", $responseHeaders)
        $results.Add("statusCode", $statusCode)
        if ((($null -ne $responseHeaders."Retry-After") -and ($responseHeaders."Retry-After" -gt 0))) {
            $RetryAfter = 30.0
            [double]::TryParse($responseHeaders."Retry-After", [ref]$RetryAfter)
            Write-Warning "Throttling (non Error) sleeping for $RetryAfter seconds before resuming"
            $RetryAfter += 2
            Start-Sleep -Seconds $RetryAfter
        }
        $WarningPreference = $WP
        $ProgressPreference = $PP
        return $results
    }
    Catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        
        # For 404 errors, return null silently (common when checking if something exists)
        if ($statusCode -eq 404) {
            return $null
        }
        
        # For 503 (Service Unavailable) errors, retry after a delay
        if ($statusCode -eq 503) {
            Write-Warning "Service unavailable (503), retrying after 5 seconds..."
            Start-Sleep -Seconds 5
            return GET-AzureDevOpsRestAPI -RestAPIUrl $RestAPIURL -Authheader $Authheader
        }
        
        # For other errors, write error and throw
        Write-Error "Api call failed `nStatusCode: $statusCode - $($_.Exception.Response.StatusDescription)`nURL: $RestAPIURL"
        throw $_
    }
}

function Test-GroupMembership {
    param (
        [string]$MemberDescriptor,
        [string]$GroupDescriptor,
        [string]$OrgUrl,
        [string]$DevOpsAuthHeader
    )

    Write-Host "Checking if user is a member of the target group..." -ForegroundColor Yellow
    
    try {
        $vsspsUrl = $OrgUrl.Replace("dev.azure.com", "vssps.dev.azure.com")
        $membershipUrl = "$vsspsUrl/_apis/graph/memberships/$MemberDescriptor/$GroupDescriptor`?api-version=7.1-preview.1"
        
        $result = GET-AzureDevOpsRestAPI -RestAPIUrl $membershipUrl -Authheader $DevOpsAuthHeader
        
        if ($result.statusCode -eq 200 -and $result.results) {
            Write-Host "  ✓ Direct or inherited membership confirmed" -ForegroundColor Green
            return $true
        }
        else {
            Write-Host "  ✗ No membership found" -ForegroundColor Red
            return $false
        }
    }
    catch {
        # 404 means no membership exists
        if ($_.Exception.Response.StatusCode.value__ -eq 404) {
            Write-Host "  ✗ No membership found (404)" -ForegroundColor Red
            return $false
        }
        else {
            Write-Warning "  Could not verify membership: $_"
            return $null
        }
    }
}

function Get-GroupKey {
    param (
        [PSCustomObject]$Group
    )
    
    # Create a unique key for the group - use Descriptor if available, otherwise use OriginId or DisplayName
    if ($null -ne $Group.Descriptor -and $Group.Descriptor -ne "") {
        return $Group.Descriptor
    }
    elseif ($null -ne $Group.OriginId -and $Group.OriginId -ne "") {
        return "aad:$($Group.OriginId)"
    }
    else {
        return "name:$($Group.DisplayName)"
    }
}

function Get-UserEntraGroups {
    param (
        [string]$UserPrincipalName,
        [string]$GraphAuthHeader
    )

    Write-Host "Getting user's Entra (AAD) group memberships..." -ForegroundColor Yellow
    
    try {
        # Get user object first
        $userGraphUrl = "https://graph.microsoft.com/v1.0/users/$UserPrincipalName"
        $userResult = GET-AzureDevOpsRestAPI -RestAPIUrl $userGraphUrl -Authheader $GraphAuthHeader
        
        if (-not $userResult.results.id) {
            Write-Warning "Could not find user in Entra ID"
            return @()
        }
        
        $userId = $userResult.results.id
        Write-Host "  Found user in Entra: $($userResult.results.displayName)" -ForegroundColor Green
        
        # Get DIRECT group memberships only
        # We'll expand them recursively to find what contains them
        $aadGroups = @()
        $groupsUrl = "https://graph.microsoft.com/v1.0/users/$userId/memberOf/microsoft.graph.group"
        
        do {
            $groupsResult = GET-AzureDevOpsRestAPI -RestAPIUrl $groupsUrl -Authheader $GraphAuthHeader
            
            if ($null -eq $groupsResult) {
                Write-Warning "No result from Graph API"
                break
            }
            
            # Graph API returns data directly in results, not nested
            $graphData = if ($groupsResult.results) { $groupsResult.results } else { $groupsResult }
            $groups = if ($graphData.value) { $graphData.value } else { @() }
            
            foreach ($group in $groups) {
                $aadGroups += [PSCustomObject]@{
                    Descriptor    = $null
                    PrincipalName = $group.displayName
                    DisplayName   = $group.displayName
                    Domain        = "aad://"
                    Origin        = "aad"
                    OriginId      = $group.id
                }
            }
            
            # Check for next page
            $nextLink = if ($graphData.'@odata.nextLink') { $graphData.'@odata.nextLink' } else { $null }
            $groupsUrl = $nextLink
            if ($groupsUrl) {
                Write-Host "    Fetching next page of Entra groups..." -ForegroundColor DarkGray
            }
            
        } while ($groupsUrl)
        
        Write-Host "  Found $($aadGroups.Count) direct Entra group memberships" -ForegroundColor Green
        return $aadGroups
    }
    catch {
        Write-Warning "Failed to get Entra groups: $_"
        return @()
    }
}

function Get-UserGroupMemberships {
    param (
        [string]$UserDescriptor,
        [string]$UserPrincipalName,
        [string]$OrgUrl,
        [string]$DevOpsAuthHeader,
        [string]$GraphAuthHeader
    )

    Write-Host "Getting group memberships for user: $UserDescriptor"
    
    # Get user's direct group memberships from Azure DevOps
    $vsspsUrl = $OrgUrl.Replace("dev.azure.com", "vssps.dev.azure.com")
    $membershipsUrl = "$vsspsUrl/_apis/graph/memberships/$UserDescriptor`?direction=up&api-version=7.1-preview.1"
    
    $result = GET-AzureDevOpsRestAPI -RestAPIUrl $membershipsUrl -Authheader $DevOpsAuthHeader
    
    $groups = @()
    foreach ($membership in $result.results.value) {
        $containerDescriptor = $membership.containerDescriptor
        
        # Get group details
        $groupUrl = "$vsspsUrl/_apis/graph/groups/$containerDescriptor`?api-version=7.1-preview.1"
        $groupResult = GET-AzureDevOpsRestAPI -RestAPIUrl $groupUrl -Authheader $DevOpsAuthHeader
        
        $group = $groupResult.results
        $groups += [PSCustomObject]@{
            Descriptor   = $group.descriptor
            PrincipalName = $group.principalName
            DisplayName  = $group.displayName
            Domain       = $group.domain
            Origin       = $group.origin
            OriginId     = $group.originId
        }
    }
    
    Write-Host "  Found $($groups.Count) Azure DevOps group memberships" -ForegroundColor Green
    
    # Also get Entra (AAD) groups (direct only)
    $aadGroups = Get-UserEntraGroups -UserPrincipalName $UserPrincipalName -GraphAuthHeader $GraphAuthHeader
    
    # Combine both sets of groups using ArrayList to preserve object properties
    $allGroups = [System.Collections.ArrayList]::new()
    foreach ($g in $groups) {
        $allGroups.Add($g) | Out-Null
    }
    foreach ($g in $aadGroups) {
        $allGroups.Add($g) | Out-Null
    }
    
    Write-Host "  Total: $($allGroups.Count) group memberships (DevOps direct + Entra direct)" -ForegroundColor Cyan
    
    return @{
        Groups = $allGroups.ToArray()
        UserEntraTransitiveIds = @()  # Not implemented yet, placeholder for future use
    }
}

function Expand-GroupMemberships {
    param (
        [PSCustomObject]$Group,
        [string]$OrgUrl,
        [string]$DevOpsAuthHeader,
        [string]$GraphAuthHeader,
        [hashtable]$ProcessedGroups,
        [hashtable]$AadGroupCache
    )

    # Avoid infinite loops
    $groupKey = Get-GroupKey -Group $Group
    if ($ProcessedGroups.ContainsKey($groupKey)) {
        return $ProcessedGroups[$groupKey].MemberOf
    }
    
    $memberOf = @()
    
    # IMPORTANT: Groups with origin=aad but WITH a Descriptor are already synced to DevOps
    # Treat them as DevOps groups (query DevOps API for parents)
    # Only groups with origin=aad WITHOUT a Descriptor need to be looked up in the cache
    
    if ($Group.Origin -eq "vsts" -or ($Group.Origin -eq "aad" -and $null -ne $Group.Descriptor -and $Group.Descriptor -ne "")) {
        # This is a DevOps group (either native VSTS or synced AAD with descriptor)
        # Use Azure DevOps API to get parent groups
        $vsspsUrl = $OrgUrl.Replace("dev.azure.com", "vssps.dev.azure.com")
        
        # Get parent groups (what this group is a member of)
        $membershipsUrl = "$vsspsUrl/_apis/graph/memberships/$($Group.Descriptor)`?direction=up&api-version=7.1-preview.1"
        
        try {
            $result = GET-AzureDevOpsRestAPI -RestAPIUrl $membershipsUrl -Authheader $DevOpsAuthHeader
            
            foreach ($membership in $result.results.value) {
                $containerDescriptor = $membership.containerDescriptor
                
                # Get group details
                $groupUrl = "$vsspsUrl/_apis/graph/groups/$containerDescriptor`?api-version=7.1-preview.1"
                $groupResult = GET-AzureDevOpsRestAPI -RestAPIUrl $groupUrl -Authheader $DevOpsAuthHeader
                
                $parentGroup = $groupResult.results
                $memberOf += [PSCustomObject]@{
                    Descriptor    = $parentGroup.descriptor
                    PrincipalName = $parentGroup.principalName
                    DisplayName   = $parentGroup.displayName
                    Domain        = $parentGroup.domain
                    Origin        = $parentGroup.origin
                    OriginId      = $parentGroup.originId
                }
            }
        }
        catch {
            Write-Warning "Failed to get parent memberships for group $($Group.DisplayName): $_"
        }
    }
    elseif ($Group.Origin -eq "aad" -and ($null -eq $Group.Descriptor -or $Group.Descriptor -eq "")) {
        # This is a pure Entra group (not yet synced to DevOps)
        # Try to find its DevOps representation in the cache
        # Not all Entra groups are synced to DevOps - if not found, skip (no DevOps permission path through this group)
        if ($null -ne $Group.OriginId -and $Group.OriginId -ne "") {
            $vsspsUrl = $OrgUrl.Replace("dev.azure.com", "vssps.dev.azure.com")
            
            # Use cached lookup instead of fetching all groups every time
            $devOpsGroup = $null
            if ($AadGroupCache -and $AadGroupCache.ContainsKey($Group.OriginId)) {
                $devOpsGroup = $AadGroupCache[$Group.OriginId]
            }
            
            if ($devOpsGroup) {
                # Found it! This Entra group is synced to DevOps
                Write-Host "      ✓ Found in DevOps: $($devOpsGroup.principalName)" -ForegroundColor Cyan
                
                try {
                    # Get what this DevOps group is a member of
                    $membershipsUrl = "$vsspsUrl/_apis/graph/memberships/$($devOpsGroup.descriptor)`?direction=up&api-version=7.1-preview.1"
                    $devOpsMemberships = GET-AzureDevOpsRestAPI -RestAPIUrl $membershipsUrl -Authheader $DevOpsAuthHeader
                    
                    if ($devOpsMemberships -and $devOpsMemberships.results -and $devOpsMemberships.results.value) {
                        $parentCount = $devOpsMemberships.results.value.Count
                        Write-Host "      Found $parentCount parent group(s)" -ForegroundColor DarkGray
                        
                        foreach ($membership in $devOpsMemberships.results.value) {
                            $containerDescriptor = $membership.containerDescriptor
                            $groupUrl = "$vsspsUrl/_apis/graph/groups/$containerDescriptor`?api-version=7.1-preview.1"
                            $groupResult = GET-AzureDevOpsRestAPI -RestAPIUrl $groupUrl -Authheader $DevOpsAuthHeader
                            
                            if ($groupResult -and $groupResult.results) {
                                $parentGroup = $groupResult.results
                                Write-Host "        → Parent: $($parentGroup.displayName) (Origin: $($parentGroup.origin))" -ForegroundColor DarkCyan
                                
                                $memberOf += [PSCustomObject]@{
                                    Descriptor    = $parentGroup.descriptor
                                    PrincipalName = $parentGroup.principalName
                                    DisplayName   = $parentGroup.displayName
                                    Domain        = $parentGroup.domain
                                    Origin        = $parentGroup.origin
                                    OriginId      = $parentGroup.originId
                                }
                            }
                        }
                    }
                    else {
                        Write-Host "      No parent groups found in DevOps" -ForegroundColor DarkGray
                    }
                }
                catch {
                    Write-Host "      Error getting parent groups: $($_.Exception.Message)" -ForegroundColor DarkRed
                }
            }
            else {
                # Not synced to DevOps yet, but we still need to traverse its Entra parents
                # because a parent group might be synced and provide the connection
                Write-Host "      ✗ Not synced to DevOps: $($Group.DisplayName) - checking Entra parents..." -ForegroundColor DarkGray
                
                try {
                    # Get Entra parent groups using Graph API
                    $graphUrl = "https://graph.microsoft.com/v1.0/groups/$($Group.OriginId)/memberOf"
                    # Ensure headers is a hashtable (it may be passed as a string from parallel context)
                    $graphHeaders = if ($GraphAuthHeader -is [hashtable]) { $GraphAuthHeader } else { @{ Authorization = $GraphAuthHeader } }
                    $graphResult = Invoke-RestMethod -Uri $graphUrl -Headers $graphHeaders -Method Get -ErrorAction Stop
                    
                    if ($graphResult.value -and $graphResult.value.Count -gt 0) {
                        Write-Host "      Found $($graphResult.value.Count) Entra parent group(s)" -ForegroundColor DarkGray
                        
                        foreach ($entraParent in $graphResult.value) {
                            # Only process group objects (not other directory objects)
                            if ($entraParent.'@odata.type' -eq '#microsoft.graph.group') {
                                Write-Host "        → Entra Parent: $($entraParent.displayName)" -ForegroundColor DarkCyan
                                
                                $memberOf += [PSCustomObject]@{
                                    Descriptor    = $null  # Will be populated if synced to DevOps
                                    PrincipalName = $null
                                    DisplayName   = $entraParent.displayName
                                    Domain        = $null
                                    Origin        = "aad"
                                    OriginId      = $entraParent.id
                                }
                            }
                        }
                    } else {
                        Write-Host "      No Entra parent groups found" -ForegroundColor DarkGray
                    }
                }
                catch {
                    Write-Host "      Error getting Entra parents: $($_.Exception.Message)" -ForegroundColor DarkRed
                }
            }
        }
    }
    
    # Store in processed cache
    $groupKey = Get-GroupKey -Group $Group
    $ProcessedGroups[$groupKey] = @{
        Group    = $Group
        MemberOf = $memberOf
    }
    
    return $memberOf
}

function Build-GroupHierarchy {
    param (
        [array]$InitialGroups,
        [string]$OrgUrl,
        [string]$DevOpsAuthHeader,
        [string]$GraphAuthHeader,
        [string]$TargetGroupName,
        [string]$ScriptPath
    )

    # Thread-safe collections
    $processedGroups = [hashtable]::Synchronized(@{})
    $progressCounter = [ref]0
    $sharedData = [hashtable]::Synchronized(@{
        Lock = [System.Threading.Mutex]::new()
        Relationships = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
        Queue = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
        FoundTarget = $false
        ProcessedCount = $progressCounter
        TotalCount = 0
    })
    
    # Build cache of AAD groups in DevOps (fetch once, use many times)
    Write-Host "Building cache of Entra groups synced to DevOps..." -ForegroundColor Yellow
    $aadGroupCache = [hashtable]::Synchronized(@{})
    try {
        $vsspsUrl = $OrgUrl.Replace("dev.azure.com", "vssps.dev.azure.com")
        $searchUrl = "$vsspsUrl/_apis/graph/groups?api-version=7.1-preview.1"
        $allGroupsResult = GET-AzureDevOpsRestAPI -RestAPIUrl $searchUrl -Authheader $DevOpsAuthHeader
        
        if ($allGroupsResult -and $allGroupsResult.results -and $allGroupsResult.results.value) {
            $aadGroupsInDevOps = $allGroupsResult.results.value | Where-Object { $_.origin -eq "aad" }
            foreach ($g in $aadGroupsInDevOps) {
                if ($g.originId) {
                    $aadGroupCache[$g.originId] = $g
                }
            }
            Write-Host "  Found $($aadGroupCache.Count) Entra groups synced to DevOps" -ForegroundColor Green
        }
    }
    catch {
        Write-Warning "Failed to build AAD group cache: $_"
    }
    
    # Initialize queue
    foreach ($group in $InitialGroups) {
        $sharedData['Queue'].Enqueue($group)
    }
    
    $currentLevel = 0
    
    Write-Host "\nTraversing group hierarchy (with parallel processing)..." -ForegroundColor Yellow
    
    while ($sharedData['Queue'].Count -gt 0) {
        # Get current level groups
        $currentLevelGroups = @()
        $groupsAtLevel = $sharedData['Queue'].Count
        
        for ($i = 0; $i -lt $groupsAtLevel; $i++) {
            if ($sharedData['Queue'].Count -gt 0) {
                $currentLevelGroups += $sharedData['Queue'].Dequeue()
            }
        }
        
        if ($currentLevelGroups.Count -eq 0) {
            break
        }
        
        $sharedData['TotalCount'] = $currentLevelGroups.Count
        $sharedData['ProcessedCount'].Value = 0
        
        Write-Host "  Level $currentLevel - Processing $($currentLevelGroups.Count) groups in parallel..." -ForegroundColor Cyan
        
        # Process groups in parallel
        $currentLevelGroups | ForEach-Object -ThrottleLimit 5 -Parallel {
            $currentGroup = $_
            $sharedData = $using:sharedData
            $processedGroups = $using:processedGroups
            $aadGroupCache = $using:aadGroupCache
            $OrgUrl = $using:OrgUrl
            $DevOpsAuthHeader = $using:DevOpsAuthHeader
            $GraphAuthHeader = $using:GraphAuthHeader
            $TargetGroupName = $using:TargetGroupName
            $scriptPath = $using:ScriptPath
            $currentLevel = $using:currentLevel
            
            try {
                # Source the script in this thread
                $env:IS_CHILD_JOB = $true
                . "$scriptPath"
                
                # Get unique key
                $currentKey = Get-GroupKey -Group $currentGroup
                
                # Skip if already processed
                if ($processedGroups.ContainsKey($currentKey)) {
                    return
                }
                
                # Update progress using Interlocked
                $processed = [System.Threading.Interlocked]::Increment($sharedData['ProcessedCount'])
                $total = $sharedData['TotalCount']
                $percent = [math]::Round(($processed / $total) * 100, 1)
                Write-Host "    [$percent%] Expanding: $($currentGroup.DisplayName) (Origin: $($currentGroup.Origin), HasDescriptor: $($null -ne $currentGroup.Descriptor))" -ForegroundColor DarkGray
                
                # Check if this is the target group
                if ($currentGroup.DisplayName -eq $TargetGroupName -or $currentGroup.PrincipalName -eq $TargetGroupName) {
                    Write-Host "  ✓ Found target group at level $currentLevel`: $($currentGroup.DisplayName)" -ForegroundColor Green
                    $sharedData['FoundTarget'] = $true
                }
                
                # Expand group memberships
                $parentGroups = Expand-GroupMemberships -Group $currentGroup -OrgUrl $OrgUrl `
                    -DevOpsAuthHeader $DevOpsAuthHeader -GraphAuthHeader $GraphAuthHeader `
                    -ProcessedGroups $processedGroups -AadGroupCache $aadGroupCache
                
                # Add relationships and enqueue parents (thread-safe)
                if ($parentGroups.Count -gt 0) {
                    foreach ($parent in $parentGroups) {
                        # Add relationship
                        $relationship = [PSCustomObject]@{
                            Child  = $currentGroup
                            Parent = $parent
                        }
                        $sharedData['Relationships'].Add($relationship) | Out-Null
                        
                        # Check if parent is the target
                        # Debug: Show all parent groups that contain "Release" in the name
                        if ($parent.DisplayName -like "*Release*" -or $parent.PrincipalName -like "*Release*") {
                            Write-Host "      DEBUG: Found Release group - DisplayName: '$($parent.DisplayName)', PrincipalName: '$($parent.PrincipalName)'" -ForegroundColor Magenta
                            Write-Host "      DEBUG: Target name: '$TargetGroupName'" -ForegroundColor Magenta
                            Write-Host "      DEBUG: Match DisplayName? $($parent.DisplayName -eq $TargetGroupName), Match PrincipalName? $($parent.PrincipalName -eq $TargetGroupName)" -ForegroundColor Magenta
                        }
                        
                        if ($parent.DisplayName -eq $TargetGroupName -or $parent.PrincipalName -eq $TargetGroupName) {
                            Write-Host "  ✓ Found target group at level $($currentLevel + 1)`: $($parent.DisplayName)" -ForegroundColor Green
                            $sharedData['FoundTarget'] = $true
                        }
                        
                        # Add parent to queue for next level
                        $sharedData['Queue'].Enqueue($parent)
                    }
                }
            }
            catch {
                # Silently skip groups that fail to expand
                Write-Warning "Failed to process group $($currentGroup.DisplayName)`: $($_.Exception.Message)"
            }
        }
        
        $currentLevel++
        
        # Stop early if we found target and processed enough levels
        if ($sharedData['FoundTarget'] -and $currentLevel -gt 10) {
            Write-Host "  Target found and depth limit reached. Stopping traversal." -ForegroundColor Yellow
            break
        }
        
        if ($sharedData['Queue'].Count -eq 0) {
            break
        }
    }
    
    # Convert synchronized collections to regular arrays
    $allRelationships = @($sharedData['Relationships'])
    
    return @{
        ProcessedGroups = $processedGroups
        Relationships   = $allRelationships
    }
}

function Build-AllChains {
    param (
        [array]$InitialGroups,
        [array]$Relationships,
        [int]$MaxDepth = 10
    )
    
    Write-Host "Building relationship lookup table..." -ForegroundColor Cyan
    # Build a lookup hashtable for O(1) parent lookups instead of O(n) Where-Object
    $parentLookup = @{}
    foreach ($rel in $Relationships) {
        $key = "$($rel.Child.DisplayName)|$($rel.Child.Origin)|$($rel.Child.Descriptor)"
        if (-not $parentLookup.ContainsKey($key)) {
            $parentLookup[$key] = @()
        }
        $parentLookup[$key] += $rel.Parent
    }
    
    Write-Host "Generating chains for $($InitialGroups.Count) initial groups (max depth: $MaxDepth)..." -ForegroundColor Cyan
    $allChains = [System.Collections.ArrayList]::new()
    $processedCount = 0
    
    # For each initial group, build all possible chains
    foreach ($initialGroup in $InitialGroups) {
        $processedCount++
        if ($processedCount % 50 -eq 0) {
            Write-Host "  Processed $processedCount/$($InitialGroups.Count) initial groups..." -ForegroundColor Gray
        }
        
        # Start with a single-element chain
        $chains = [System.Collections.ArrayList]::new()
        $chains.Add(@(,$initialGroup)) | Out-Null
        
        # Expand chains up to MaxDepth
        for ($depth = 0; $depth -lt $MaxDepth; $depth++) {
            $newChains = [System.Collections.ArrayList]::new()
            $foundAnyParent = $false
            
            foreach ($chain in $chains) {
                $lastGroup = $chain[-1]
                $key = "$($lastGroup.DisplayName)|$($lastGroup.Origin)|$($lastGroup.Descriptor)"
                
                # O(1) lookup instead of O(n) Where-Object
                $parents = $parentLookup[$key]
                
                if ($parents -and $parents.Count -gt 0) {
                    $foundAnyParent = $true
                    foreach ($parent in $parents) {
                        # Create new chain by adding parent
                        $newChain = $chain + @($parent)
                        $newChains.Add($newChain) | Out-Null
                    }
                } else {
                    # No more parents, keep this chain
                    $newChains.Add($chain) | Out-Null
                }
            }
            
            $chains = $newChains
            if (-not $foundAnyParent) {
                break
            }
        }
        
        # Add chains from this initial group - only include chains with length > 1
        # (single-element chains have no inheritance relationships)
        foreach ($chain in $chains) {
            if ($chain.Count -gt 1) {
                $allChains.Add($chain) | Out-Null
            }
        }
    }
    
    return $allChains.ToArray()
}

function Find-PathsToGroup {
    param (
        [string]$UserDescriptor,
        [string]$TargetGroupName,
        [array]$Relationships,
        [array]$InitialGroups
    )

    $paths = @()
    
    # Handle both "[domain]\GroupName" and "GroupName" formats
    $targetDisplayName = if ($TargetGroupName -match '\[.*?\]\\(.+)') { $matches[1] } else { $TargetGroupName }
    
    # Find all groups matching the target name
    $targetGroups = $Relationships | Where-Object { 
        $_.Parent.DisplayName -eq $targetDisplayName -or
        $_.Parent.DisplayName -eq $TargetGroupName -or 
        $_.Parent.PrincipalName -eq $TargetGroupName 
    }
    
    # Also check if target is in initial groups
    $directTargets = $InitialGroups | Where-Object { 
        $_.DisplayName -eq $targetDisplayName -or
        $_.DisplayName -eq $TargetGroupName -or 
        $_.PrincipalName -eq $TargetGroupName 
    }
    
    if ($directTargets) {
        foreach ($target in $directTargets) {
            $paths += @(, @($target))  # Direct membership
        }
    }
    
    # Build paths recursively
    foreach ($targetRel in $targetGroups) {
        $subPaths = Find-PathsToNode -TargetNode $targetRel.Child -Relationships $Relationships -InitialGroups $InitialGroups
        
        foreach ($subPath in $subPaths) {
            $newPath = [System.Collections.ArrayList]::new()
            foreach ($item in $subPath) {
                $newPath.Add($item) | Out-Null
            }
            $newPath.Add($targetRel.Parent) | Out-Null
            $paths += @(, $newPath.ToArray())
        }
    }
    
    return $paths
}

function Find-PathsToNode {
    param (
        [PSCustomObject]$TargetNode,
        [array]$Relationships,
        [array]$InitialGroups
    )

    $paths = @()
    
    # Check if this node is in initial groups (direct connection)
    $directConnection = $InitialGroups | Where-Object { 
        $_.Descriptor -eq $TargetNode.Descriptor 
    }
    
    if ($directConnection) {
        $paths += @(, @($directConnection))
        return $paths
    }
    
    # Find all relationships where this node is the parent
    $childRels = $Relationships | Where-Object { 
        $_.Parent.Descriptor -eq $TargetNode.Descriptor 
    }
    
    foreach ($childRel in $childRels) {
        $subPaths = Find-PathsToNode -TargetNode $childRel.Child -Relationships $Relationships -InitialGroups $InitialGroups
        
        foreach ($subPath in $subPaths) {
            $newPath = [System.Collections.ArrayList]::new()
            foreach ($item in $subPath) {
                $newPath.Add($item) | Out-Null
            }
            $newPath.Add($childRel.Parent) | Out-Null
            $paths += @(, $newPath.ToArray())
        }
    }
    
    return $paths
}

function Format-InheritanceChain {
    param (
        [string]$UserIdentifier,
        [array]$Path,
        [int]$PathNumber
    )

    $output = "`n=== Path $PathNumber ===`n"
    $output += "$UserIdentifier (User)`n"
    
    for ($i = 0; $i -lt $Path.Count; $i++) {
        $indent = "  " * ($i + 1)
        $arrow = "↳ "
        $group = $Path[$i]
        $output += "$indent$arrow$($group.DisplayName)"
        
        if ($group.PrincipalName -and $group.PrincipalName -ne $group.DisplayName) {
            $output += " [$($group.PrincipalName)]"
        }
        
        $output += " (Origin: $($group.Origin))`n"
    }
    
    return $output
}

function Main {
    param (
        [Parameter(Mandatory = $true)]
        [string]$UserIdentifier,
        
        [Parameter(Mandatory = $true)]
        [string]$TargetGroupName,
        
        [Parameter(Mandatory = $true)]
        [string]$OrgName,

        [Parameter(Mandatory = $false)]
        [string]$ProjectName,

        [switch]$ExportJson
    )

    $ErrorActionPreference = 'Stop'
    
    try {
        Write-Host "Script started successfully" -ForegroundColor Green
        Write-Host "=== Finding Inheritance Chains ===" -ForegroundColor Cyan
        Write-Host "User: $UserIdentifier"
        Write-Host "Target Group: $TargetGroupName"
        Write-Host "Organization: $OrgName`n"
        
        # Get tokens
        Write-Host "Authenticating..." -ForegroundColor Yellow
        $devOpsToken = Get-EntraToken
        $graphToken = Get-GraphToken
        
        $orgUrl = "https://dev.azure.com/$OrgName"
        $vsspsUrl = $orgUrl.Replace("dev.azure.com", "vssps.dev.azure.com")
        
        # Find user descriptor - try multiple approaches
        Write-Host "`nSearching for user..." -ForegroundColor Yellow
        $user = $null
        
        # Approach 1: Try to get user directly by subject query (most efficient)
        try {
            Write-Host "  Trying direct lookup..." -ForegroundColor Gray
            $userLookupUrl = "$vsspsUrl/_apis/graph/subjectlookup?api-version=7.1-preview.1"
            $body = @{
                lookupKeys = @(
                    @{
                        descriptor = "msa.$UserIdentifier"
                    }
                    @{
                        descriptor = "aad.$UserIdentifier"
                    }
                )
            } | ConvertTo-Json
            
            $lookupResult = Invoke-RestMethod -Uri $userLookupUrl -Headers @{
                Authorization = $devOpsToken.AuthHeader
                "Content-Type" = "application/json"
            } -Method Post -Body $body -ErrorAction SilentlyContinue
            
            if ($lookupResult.value -and $lookupResult.value.Count -gt 0) {
                $user = $lookupResult.value[0]
                Write-Host "  Found via direct lookup" -ForegroundColor Green
            }
        }
        catch {
            Write-Host "  Direct lookup not successful, trying search..." -ForegroundColor Gray
        }
        
        # Approach 2: Search through paginated user list
        if (-not $user) {
            Write-Host "  Searching through users (this may take a moment for large orgs)..." -ForegroundColor Gray
            $continuationToken = $null
            $foundUser = $false
            $pageCount = 0
            
            do {
                $pageCount++
                if ($continuationToken) {
                    $userSearchUrl = "$vsspsUrl/_apis/graph/users?continuationToken=$continuationToken&api-version=7.1-preview.1"
                } else {
                    $userSearchUrl = "$vsspsUrl/_apis/graph/users?api-version=7.1-preview.1"
                }
                
                Write-Host "    Checking page $pageCount..." -ForegroundColor DarkGray
                $usersResult = GET-AzureDevOpsRestAPI -RestAPIUrl $userSearchUrl -Authheader $devOpsToken.AuthHeader
                
                $user = $usersResult.results.value | Where-Object { 
                    $_.principalName -eq $UserIdentifier -or
                    $_.mailAddress -eq $UserIdentifier -or
                    $_.principalName -like "*$UserIdentifier*" -or 
                    $_.displayName -like "*$UserIdentifier*" -or
                    $_.mailAddress -like "*$UserIdentifier*"
                } | Select-Object -First 1
                
                if ($user) {
                    Write-Host "  Found user on page $pageCount" -ForegroundColor Green
                    $foundUser = $true
                    break
                }
                
                $continuationToken = $usersResult.responseHeaders."x-ms-continuationtoken"
                
                # Safety limit - don't search more than 20 pages
                if ($pageCount -ge 20) {
                    Write-Warning "  Searched 20 pages without finding user. Stopping search."
                    break
                }
                
            } while ($continuationToken)
        }
        
        if (-not $user) {
            Write-Host "`nUser not found: $UserIdentifier" -ForegroundColor Red
            Write-Host "Please ensure the user identifier is correct. Try using:" -ForegroundColor Yellow
            Write-Host "  - Full email address (e.g., user@domain.com)" -ForegroundColor Yellow
            Write-Host "  - Principal name exactly as shown in Azure DevOps" -ForegroundColor Yellow
            Write-Error "User not found: $UserIdentifier"
            return
        }
        
        Write-Host "Found user: $($user.displayName) ($($user.principalName))" -ForegroundColor Green
        
        # Find the target group to get its descriptor
        Write-Host "`nSearching for target group..." -ForegroundColor Yellow
        if ($ProjectName) {
            Write-Host "  Scoping search to project: $ProjectName" -ForegroundColor Gray
        }
        
        $targetGroups = @()
        $continuationToken = $null
        $pageCount = 0
        
        do {
            $pageCount++
            if ($continuationToken) {
                $groupSearchUrl = "$vsspsUrl/_apis/graph/groups?continuationToken=$continuationToken&api-version=7.1-preview.1"
            } else {
                $groupSearchUrl = "$vsspsUrl/_apis/graph/groups?api-version=7.1-preview.1"
            }
            
            Write-Host "  Checking page $pageCount..." -ForegroundColor DarkGray
            $groupsResult = GET-AzureDevOpsRestAPI -RestAPIUrl $groupSearchUrl -Authheader $devOpsToken.AuthHeader
            
            $matches = $groupsResult.results.value | Where-Object { 
                $matchesName = ($_.principalName -eq $TargetGroupName -or
                               $_.displayName -eq $TargetGroupName -or
                               $_.principalName -like "*$TargetGroupName" -or
                               $_.principalName -like "*\\$TargetGroupName" -or 
                               $_.displayName -like "*$TargetGroupName")
                
                if ($ProjectName) {
                    # If project specified, ensure it matches the scope
                    $matchesName -and ($_.principalName -like "[$ProjectName]\\*" -or $_.domain -like "*$ProjectName*")
                } else {
                    $matchesName
                }
            }
            
            if ($matches) {
                $targetGroups += $matches
            }
            
            $continuationToken = $groupsResult.responseHeaders."x-ms-continuationtoken"
            
            if ($pageCount -ge 20) {
                Write-Warning "  Searched 20 pages. Stopping search."
                break
            }
            
        } while ($continuationToken)
        
        $targetGroup = $null
        if ($targetGroups.Count -eq 0) {
            Write-Warning "No groups found matching: $TargetGroupName"
            if (-not $ProjectName) {
                Write-Host "Tip: Groups are scoped to projects. Try adding -ProjectName parameter" -ForegroundColor Yellow
            }
            return
        }
        elseif ($targetGroups.Count -eq 1) {
            $targetGroup = $targetGroups[0]
            Write-Host "  Found unique target group" -ForegroundColor Green
        }
        else {
            Write-Host "`nFound multiple groups matching '$TargetGroupName':" -ForegroundColor Yellow
            for ($i = 0; $i -lt $targetGroups.Count; $i++) {
                Write-Host "  [$($i+1)] $($targetGroups[$i].principalName)" -ForegroundColor Cyan
                Write-Host "      Display: $($targetGroups[$i].displayName)" -ForegroundColor Gray
                Write-Host "      Domain: $($targetGroups[$i].domain)" -ForegroundColor Gray
            }
            Write-Host "`nPlease re-run with -ProjectName to scope the search, or use the full group name." -ForegroundColor Yellow
            Write-Host "Example: -TargetGroupName '$($targetGroups[0].principalName)'" -ForegroundColor Gray
            return
        }
        
        if ($targetGroup) {
            Write-Host "Found target group: $($targetGroup.displayName) [$($targetGroup.principalName)]" -ForegroundColor Green
            
            # Validate membership using Check Membership API
            Write-Host ""
            $hasMembership = Test-GroupMembership -MemberDescriptor $user.descriptor `
                -GroupDescriptor $targetGroup.descriptor -OrgUrl $orgUrl `
                -DevOpsAuthHeader $devOpsToken.AuthHeader
            
            if ($hasMembership -eq $false) {
                Write-Host "`n⚠️  API Validation: User does NOT have membership in this group" -ForegroundColor Yellow
                Write-Host "The script will still search for any potential paths in case the API is delayed or cached." -ForegroundColor Gray
            }
            elseif ($hasMembership -eq $true) {
                Write-Host "`n✓ API Validation: User HAS membership in this group (direct or inherited)" -ForegroundColor Green
            }
            Write-Host ""
        }
        else {
            Write-Warning "Could not find target group. Will still search for paths using the provided name."
        }
        
        # Get user's initial group memberships
        Write-Host "`nGetting user's group memberships..." -ForegroundColor Yellow
        $membershipResult = Get-UserGroupMemberships -UserDescriptor $user.descriptor `
            -UserPrincipalName $user.principalName -OrgUrl $orgUrl `
            -DevOpsAuthHeader $devOpsToken.AuthHeader -GraphAuthHeader $graphToken.AuthHeader
        
        $initialGroups = $membershipResult.Groups
        $userEntraTransitiveIds = $membershipResult.UserEntraTransitiveIds
        
        Write-Host "Found $($initialGroups.Count) group memberships" -ForegroundColor Green
        
        if ($initialGroups.Count -eq 0) {
            Write-Warning "User is not a member of any groups"
            return
        }
        
        # Build complete hierarchy
        Write-Host "\nBuilding group hierarchy (expanding groups on-demand)..." -ForegroundColor Yellow
        
        # Get script path for thread jobs
        $scriptPath = $MyInvocation.MyCommand.Path
        if (-not $scriptPath) {
            $scriptPath = Get-ChildItem -Path "$((Get-Location).Path)\Find-GroupInheritanceChains.ps1" -ErrorAction Stop | Select-Object -ExpandProperty FullName -First 1
        }
        
        $hierarchy = Build-GroupHierarchy -InitialGroups $initialGroups `
            -OrgUrl $orgUrl -DevOpsAuthHeader $devOpsToken.AuthHeader `
            -GraphAuthHeader $graphToken.AuthHeader -TargetGroupName $TargetGroupName `
            -ScriptPath $scriptPath
        
        Write-Host "Processed $($hierarchy.ProcessedGroups.Count) unique groups" -ForegroundColor Green
        Write-Host "Found $($hierarchy.Relationships.Count) group relationships" -ForegroundColor Green
        
        # Build all chains
        Write-Host "`nBuilding all inheritance chains..." -ForegroundColor Yellow
        $allChains = Build-AllChains -InitialGroups $initialGroups -Relationships $hierarchy.Relationships -MaxDepth 10
        Write-Host "Found $($allChains.Count) total chains" -ForegroundColor Green
        
        # Export chains to CSV
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $chainsCsv = ".\InheritanceChains_$timestamp.csv"
        
        # Find the maximum chain length
        $maxLength = ($allChains | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum
        
        # Build CSV rows
        $csvData = foreach ($chain in $allChains) {
            $row = [ordered]@{}
            for ($i = 0; $i -lt $maxLength; $i++) {
                if ($i -lt $chain.Count) {
                    $group = $chain[$i]
                    $row["Level_$i`_DisplayName"] = $group.DisplayName
                    $row["Level_$i`_Origin"] = $group.Origin
                    $row["Level_$i`_Descriptor"] = $group.Descriptor
                } else {
                    $row["Level_$i`_DisplayName"] = ""
                    $row["Level_$i`_Origin"] = ""
                    $row["Level_$i`_Descriptor"] = ""
                }
            }
            [PSCustomObject]$row
        }
        
        $csvData | Export-Csv -Path $chainsCsv -NoTypeInformation
        Write-Host "All chains exported to: $chainsCsv" -ForegroundColor Cyan
        Write-Host "  Max chain depth: $maxLength levels" -ForegroundColor Cyan
        
        # Search for target in chains
        Write-Host "`nSearching for target group in chains..." -ForegroundColor Yellow
        # Handle both "[domain]\GroupName" and "GroupName" formats
        $targetDisplayName = if ($TargetGroupName -match '\[.*?\]\\(.+)') { $matches[1] } else { $TargetGroupName }
        $chainsWithTarget = $allChains | Where-Object {
            $_ | Where-Object { 
                $_.DisplayName -eq $targetDisplayName -or 
                $_.DisplayName -eq $TargetGroupName -or 
                $_.PrincipalName -eq $TargetGroupName 
            }
        }
        
        if ($chainsWithTarget) {
            Write-Host "Found $($chainsWithTarget.Count) chain(s) containing target group!" -ForegroundColor Green
            
            # Truncate each chain at the target group and remove duplicates
            $truncatedChains = @()
            $uniqueChainSignatures = @{}
            
            foreach ($chain in $chainsWithTarget) {
                # Find the index of the target group in this chain
                $targetIndex = -1
                for ($i = 0; $i -lt $chain.Count; $i++) {
                    if ($chain[$i].DisplayName -eq $targetDisplayName -or 
                        $chain[$i].DisplayName -eq $TargetGroupName -or 
                        $chain[$i].PrincipalName -eq $TargetGroupName) {
                        $targetIndex = $i
                        break
                    }
                }
                
                if ($targetIndex -ge 0) {
                    # Truncate the chain to only include groups up to and including the target
                    $truncatedChain = $chain[0..$targetIndex]
                    
                    # Create a signature for deduplication (concatenate all group names)
                    $signature = ($truncatedChain | ForEach-Object { "$($_.DisplayName)|$($_.Origin)|$($_.Descriptor)" }) -join "::"
                    
                    # Only add if we haven't seen this exact path before
                    if (-not $uniqueChainSignatures.ContainsKey($signature)) {
                        $uniqueChainSignatures[$signature] = $true
                        $truncatedChains += ,@($truncatedChain)
                    }
                }
            }
            
            $chainsWithTarget = $truncatedChains
            Write-Host "After truncation and deduplication: $($chainsWithTarget.Count) unique path(s)" -ForegroundColor Green
            
            Write-Host "`nExample chain to target:" -ForegroundColor Cyan
            $exampleChain = $chainsWithTarget[0]
            for ($i = 0; $i -lt $exampleChain.Count; $i++) {
                Write-Host "  $i. $($exampleChain[$i].DisplayName) (Origin: $($exampleChain[$i].Origin))" -ForegroundColor White
            }
        } else {
            Write-Host "Target group not found in any chains" -ForegroundColor Red
        }
        
        # Export JSON if requested
        if ($ExportJson) {
            $jsonOutput = @{
                User          = $user
                InitialGroups = $initialGroups
                Hierarchy     = $hierarchy.Relationships
            }
            $jsonPath = ".\GroupHierarchy_$($UserIdentifier)_$timestamp.json"
            $jsonOutput | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Force
            Write-Host "Hierarchy exported to: $jsonPath" -ForegroundColor Cyan
        }
        
        # Use the chains we already found that contain the target
        if ($chainsWithTarget.Count -eq 0) {
            Write-Warning "`nNo inheritance paths found from user to group: $TargetGroupName"
            return
        }
        
        # Display results
        Write-Host "`n`n=== RESULTS ===" -ForegroundColor Cyan
        Write-Host "Found $($chainsWithTarget.Count) inheritance path(s) from $($user.displayName) to $TargetGroupName`n" -ForegroundColor Green
        
        for ($i = 0; $i -lt $chainsWithTarget.Count; $i++) {
            Write-Host "`n--- Path $($i + 1) ---" -ForegroundColor Yellow
            Write-Host "User: $($user.displayName)" -ForegroundColor White
            $chain = $chainsWithTarget[$i]
            for ($j = 0; $j -lt $chain.Count; $j++) {
                $indent = "  " * ($j + 1)
                $arrow = if ($j -lt $chain.Count - 1) { " └─>" } else { " └─>" }
                Write-Host "$indent$arrow $($chain[$j].DisplayName) (Origin: $($chain[$j].Origin))" -ForegroundColor Cyan
            }
        }
        
    }
    catch {
        Write-Host "`n=== ERROR OCCURRED ===" -ForegroundColor Red
        Write-Host "Error Message: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "`nStack Trace:" -ForegroundColor Yellow
        Write-Host $_.ScriptStackTrace -ForegroundColor Yellow
        Write-Host "`nFull Error Details:" -ForegroundColor Yellow
        Write-Host ($_ | Format-List * -Force | Out-String) -ForegroundColor Yellow
        throw
    }
}

# Script entry point
# Only run main code if not being dot-sourced (e.g., by parallel threads)
if ($MyInvocation.InvocationName -ne '.') {
    try {
    if ([string]::IsNullOrWhiteSpace($UserIdentifier) -or 
        [string]::IsNullOrWhiteSpace($TargetGroupName) -or 
        [string]::IsNullOrWhiteSpace($OrgName)) {
        
        Write-Host "Usage: .\\Find-GroupInheritanceChains.ps1 -UserIdentifier <User> -TargetGroupName <Group> -OrgName <Org> [-ProjectName <Project>] [-ExportJson]" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Parameters:" -ForegroundColor Cyan
        Write-Host "  -UserIdentifier  : User's display name, principal name, or email"
        Write-Host "  -TargetGroupName : Name of the target group to find paths to"
        Write-Host "  -OrgName         : Azure DevOps organization name"
        Write-Host "  -ProjectName     : (Optional) Project name to scope the group search"
        Write-Host "  -ExportJson      : (Optional) Export the full hierarchy as JSON"
        Write-Host ""
        Write-Host "Example:" -ForegroundColor Cyan
        Write-Host '  .\\Find-GroupInheritanceChains.ps1 -UserIdentifier "john.doe@contoso.com" -TargetGroupName "Contributors" -OrgName "myorg" -ProjectName "MyProject"'
        Write-Host ""
        exit 1
    }
    
    Write-Host "Invoking Main function..." -ForegroundColor Cyan
    $mainParams = @{
        UserIdentifier  = $UserIdentifier
        TargetGroupName = $TargetGroupName
        OrgName         = $OrgName
        ExportJson      = $ExportJson
    }
    if ($ProjectName) {
        $mainParams['ProjectName'] = $ProjectName
    }
    Main @mainParams
}
catch {
    Write-Host "`n=== SCRIPT EXECUTION FAILED ===" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Stack Trace:" -ForegroundColor Yellow
    Write-Host $_.ScriptStackTrace
    exit 1
}
}
