# InheritanceHelper

Help finding the chain of inheritance (group memberships across Entra and DevOps) from a user to a group that is blamed for a certain permission in the UI.

## Overview

InheritanceHelper is a PowerShell script that traces group membership chains from a user to a target group across both Azure DevOps and Microsoft Entra ID. This is particularly useful for understanding why a user has certain permissions through nested group memberships. The script uses parallel processing to efficiently traverse complex group hierarchies and provides multiple output formats for different analysis needs.

> **Note**: This script was generated via GitHub Copilot and while it seems to be working great for the scenarios that have been tested, it's possible that there may be false positives or negitives.  I encourage you to review the output and open an issue for anything that seems incorrect.

## Features

- **Cross-Platform Authentication**: Automatically handles Azure authentication using the Az PowerShell module
- **Entra ID Integration**: Retrieves direct group memberships from Microsoft Entra ID
- **Azure DevOps Groups**: Discovers Azure DevOps group memberships (both native and Entra-backed)
- **Parallel Hierarchy Traversal**: Uses parallel processing to efficiently expand group memberships
- **Multiple Path Detection**: Finds all possible inheritance paths from user to target group
- **Robust Error Handling**: Gracefully handles edge cases like users with no group memberships
- **CSV Export**: Exports all discovered chains to a timestamped CSV file for analysis
- **JSON Export**: Optional export of complete parent-child relationship data for programmatic analysis
- **Verbose Logging**: Optional detailed progress messages for troubleshooting
- **Deduplication**: Deduplicates results by the path to the target group while keeping full chains in CSV

## Prerequisites

- PowerShell 5.1 or later
- Azure PowerShell module (Az) - automatically installed if not present
- Appropriate permissions:
  - Azure DevOps organization access
  - Microsoft Graph API permissions to read user and group data
  - Entra ID directory read permissions

## Parameters

- **`-UserIdentifier`** (Required): User's display name, principal name, or email address (e.g., "john.doe@contoso.com")
- **`-TargetGroupName`** (Required): Name of the target group to find inheritance paths to. Use fully qualified format: `[DOMAIN]\GroupName` (e.g., `[TEAM FOUNDATION]\Contributors`)
- **`-OrgName`** (Required): Azure DevOps organization name
- **`-ExportJson`** (Optional): Switch to export parent-child relationships as JSON
- **`-Verbose`** (Optional): Switch to display detailed progress messages and group expansion details

## Usage

### Basic Usage
```powershell
.\InheritanceHelper.ps1 -UserIdentifier "john.doe@contoso.com" -TargetGroupName "[TEAM FOUNDATION]\Contributors" -OrgName "myorg"
```

### With Verbose Output
```powershell
.\InheritanceHelper.ps1 -UserIdentifier "john.doe@contoso.com" -TargetGroupName "[TEAM FOUNDATION]\Contributors" -OrgName "myorg" -Verbose
```

### With JSON Export (for programmatic analysis)
```powershell
.\InheritanceHelper.ps1 -UserIdentifier "john.doe@contoso.com" -TargetGroupName "[TEAM FOUNDATION]\Contributors" -OrgName "myorg" -ExportJson
```

### With Both JSON and Verbose
```powershell
.\InheritanceHelper.ps1 -UserIdentifier "john.doe@contoso.com" -TargetGroupName "[TEAM FOUNDATION]\Contributors" -OrgName "myorg" -ExportJson -Verbose
```

## Output Formats

The script provides multiple output formats optimized for different use cases.

### Console Output

The console displays a visual hierarchy of inheritance paths from the user to the target group:

```
=== RESULTS ===
Found 2 inheritance path(s) from Jane Smith to [PROJECT]\Deploy-Admins

--- Path 1 ---
User: Jane Smith
 └─> Platform-Engineering-Group (Origin: aad)
   └─> [TEAM FOUNDATION]\Infrastructure-Team (Origin: aad)
     └─> [PROJECT]\Deploy-Admins (Origin: vsts)

--- Path 2 ---
User: Jane Smith
 └─> Release-Managers (Origin: vsts)
   └─> [PROJECT]\Deploy-Admins (Origin: vsts)
```

**Key Features:**
- Shows fully qualified group names when available
- Displays origin for each group (aad = Entra ID, vsts = Azure DevOps)
- Paths stop at the target group (groups after the target are not displayed)
- Paths are deduplicated by the route to the target group

### CSV Export: `InheritanceChains_<timestamp>.csv`

The CSV file contains **complete inheritance chains** with all groups in sequence:

```csv
Path_ID,Level_0,Level_0_FQN,Level_0_Origin,Level_1,Level_1_FQN,Level_1_Origin,Level_2,Level_2_FQN,Level_2_Origin,Level_3,Level_3_FQN,Level_3_Origin
1,Jane Smith,Jane Smith,user,Platform-Engineering-Group,[Entra]\Platform-Engineering-Group,aad,[TEAM FOUNDATION]\Infrastructure-Team,[TEAM FOUNDATION]\Infrastructure-Team,aad,[PROJECT]\Deploy-Admins,[PROJECT]\Deploy-Admins,vsts
2,Jane Smith,Jane Smith,user,Release-Managers,[TEAM FOUNDATION]\Release-Managers,vsts,[PROJECT]\Deploy-Admins,[PROJECT]\Deploy-Admins,vsts,,,,
```

**Key Features:**
- One row per unique chain from user to target group
- `Level_N` columns show DisplayName of group at each level
- `Level_N_FQN` columns show fully qualified names (with domain prefix)
- `Level_N_Origin` columns show whether group is from Entra ID (aad) or Azure DevOps (vsts)
- Includes all groups **after** the target group in the chain
- Can be imported into Excel for further analysis
- Useful for documenting inheritance paths for auditing

### JSON Export: `GroupHierarchy_<UserIdentifier>_<timestamp>.json`

The JSON file contains **parent-child relationship data** with complete group metadata:

```json
{
  "User": {
    "subjectKind": "user",
    "displayName": "Jane Smith",
    "principalName": "jane.smith@contoso.com",
    "origin": "aad",
    "originId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "descriptor": "aad.a1b2c3d4e5f67890abcdef1234567890"
  },
  "InitialGroups": [
    {
      "displayName": "Platform-Engineering-Group",
      "principalName": "[TEAM FOUNDATION]\\Platform-Engineering-Group",
      "origin": "aad",
      "originId": "b2c3d4e5-f6a7-8901-bcde-f1a2b3c4d5e6",
      "descriptor": "aad.b2c3d4e5f6a78901bcdef1a2b3c4d5e6"
    },
    {
      "displayName": "Release-Managers",
      "principalName": "[TEAM FOUNDATION]\\Release-Managers",
      "origin": "vsts",
      "originId": "d4e5f6a7-b8c9-0123-defg-h1i2j3k4l5m6",
      "descriptor": "vssgp.d4e5f6a7b8c90123defgh1i2j3k4l5m6"
    }
  ],
  "Hierarchy": [
    {
      "Child": {
        "displayName": "Platform-Engineering-Group",
        "originId": "b2c3d4e5-f6a7-8901-bcde-f1a2b3c4d5e6"
      },
      "Parent": {
        "displayName": "[TEAM FOUNDATION]\\Infrastructure-Team",
        "originId": "c3d4e5f6-a7b8-9012-cdef-a1b2c3d4e5f6"
      }
    },
    {
      "Child": {
        "displayName": "[TEAM FOUNDATION]\\Infrastructure-Team",
        "originId": "c3d4e5f6-a7b8-9012-cdef-a1b2c3d4e5f6"
      },
      "Parent": {
        "displayName": "[PROJECT]\\Deploy-Admins",
        "originId": "e5f6a7b8-c9d0-1234-e5f6-g7h8i9j0k1l2"
      }
    },
    {
      "Child": {
        "displayName": "Release-Managers",
        "originId": "d4e5f6a7-b8c9-0123-defg-h1i2j3k4l5m6"
      },
      "Parent": {
        "displayName": "[PROJECT]\\Deploy-Admins",
        "originId": "e5f6a7b8-c9d0-1234-e5f6-g7h8i9j0k1l2"
      }
    }
  ]
}
```

**Key Features:**
- Contains **parent-child relationship pairs** rather than complete chains
- Provides complete group metadata (descriptor, origin, IDs, etc.)
- Includes user information
- Includes initial groups (direct memberships)
- Each relationship object shows a Child-Parent pair
- Useful for:
  - Building custom reports
  - Programmatic analysis
  - Creating directed graphs of group relationships
  - Integrating with security tools

**Important Difference from CSV:**
- **CSV**: Complete linear chains from user → → → target group
- **JSON**: Individual parent-child relationships that can be reassembled programmatically

## Verbose Output

Use the `-Verbose` parameter to see detailed progress messages during execution:

```powershell
.\InheritanceHelper.ps1 -UserIdentifier "john.doe@contoso.com" -TargetGroupName "[TEAM FOUNDATION]\Contributors" -OrgName "myorg" -Verbose
```

This displays:
- Group membership discovery progress
- Parent group expansion details  
- Hierarchy traversal levels and processing status
- Cache building information
- Chain generation progress
- All progress indicators and intermediate status messages

**Without `-Verbose`**: Clean, concise output showing only essential information

**With `-Verbose`**: Detailed diagnostic information useful for troubleshooting

## Notes on PIM (Privileged Identity Management) Groups

If the permission you are investigating is granted through a PIM-eligible group, the group name you see in PIM is often not the same as the group that actually appears in Azure DevOps permissions. To trace the inheritance path correctly:

1. **Activate** the PIM membership for the role/group.
2. **Re-evaluate** the permission in Azure DevOps after activation (permissions are only effective while active).
3. In the relevant security/permissions UI, use the **info/hover details** to find the exact group name that grants the permission.
4. Use that fully qualified group name as `-TargetGroupName` in this script to trace the inheritance chain.

This workflow ensures the script is searching for the actual permission-granting group, not the PIM eligibility group.

## How It Works

1. **Authentication**: Acquires tokens for Azure DevOps and Microsoft Graph APIs using the Az module
2. **User Lookup**: Finds the user in Azure DevOps, searching through paginated results
3. **Target Group Search**: Locates the target group by name (fully qualified names recommended for accuracy)
4. **Membership Check**: Validates whether the user has membership in the target group
5. **Direct Memberships**: Retrieves user's direct group memberships from both Azure DevOps and Entra ID
6. **Parallel Expansion**: Uses parallel processing (5 threads) to recursively discover parent groups
7. **Relationship Building**: Stores all discovered parent-child relationships
8. **Chain Construction**: Builds all possible inheritance paths from user to target group
9. **Deduplication**: Removes duplicate paths based on the route to the target group
10. **Results Display**: Presents unique paths to the target group on console and exports to files

## Grouping by Origin

Groups can originate from either:
- **aad** (Entra ID): Groups in Azure Entra ID, may or may not be synced to Azure DevOps
- **vsts** (Azure DevOps): Native Azure DevOps groups

The script handles both seamlessly, following group relationships across both systems.

## Generated Files

The script creates timestamped export files in the current directory:

- **`InheritanceChains_<timestamp>.csv`** 
  - Always generated
  - Contains complete inheritance chains
  - Suitable for Excel analysis and auditing
  - Includes groups after the target group

- **`GroupHierarchy_<UserIdentifier>_<timestamp>.json`** 
  - Only if `-ExportJson` is used
  - Contains parent-child relationship pairs
  - Includes complete group metadata
  - Suitable for programmatic processing

These files are excluded from version control via `.gitignore`.

## Example Scenarios

### Scenario 1: Finding Unexpected Permissions

```
Issue: User John Doe has admin rights, but shouldn't
Solution:
1. Run the script with his admin group as the target
2. Review the inheritance chain
3. Identify which parent group shouldn't contain him
4. Remove him from the intermediate group
```

### Scenario 2: Verifying Permission Removal

```
Issue: Need to verify that removing user from a group removes all permissions
Solution:
1. Run the script before removal
2. Run the script after removal
3. Compare the output to confirm all paths are gone
```

### Scenario 3: Security Audit

```
Issue: Auditing who has access to critical resources
Solution:
1. Run with -ExportJson to get parent-child relationships
2. Process the JSON programmatically to build security report
3. Identify all transitive access paths
4. Document findings for compliance
```

## Error Handling

- **No membership found**: Script gracefully exits with a clear message when user is not a member of the target group
- **User not found**: Provides helpful guidance if the user identifier doesn't match any users
- **Group not found**: Suggests using a fully qualified group name if the exact group cannot be located
- **No group memberships**: Clearly indicates when a user has no group memberships to trace
- **API throttling**: Automatic retry logic with wait for HTTP 429 (rate limit) responses
- **Service unavailability**: Retry mechanism for HTTP 503 (service unavailable) errors

## Troubleshooting

**Problem**: Script shows "Group not found"
- **Solution**: Use the fully qualified format `[DOMAIN]\GroupName`, e.g., `[TEAM FOUNDATION]\Contributors`

**Problem**: Long execution time
- **Solution**: This is normal for large organizations with many groups. Use `-Verbose` to monitor progress

**Problem**: Different results when run multiple times
- **Solution**: Group memberships may change. Re-run the script to get current state

**Problem**: JSON file is very large
- **Solution**: Large organizations with complex hierarchies will have larger files. Filter the JSON programmatically as needed

## License

See [LICENSE](LICENSE) file for details.
