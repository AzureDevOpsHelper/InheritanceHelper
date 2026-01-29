# InheritanceHelper

Help finding the chain of inheritance (group memberships across Entra and DevOps) from a user to a group that is blamed for a certain permission in the UI.

## Overview

InheritanceHelper is a PowerShell script that traces group membership chains from a user to a target group across both Azure DevOps and Microsoft Entra ID. This is particularly useful for understanding why a user has certain permissions through nested group memberships. The script uses parallel processing to efficiently traverse complex group hierarchies.

> **Note**: This script was generated via GitHub Copilot and includes improvements for error handling, parallel processing efficiency, and user experience.

## Features

- **Cross-Platform Authentication**: Automatically handles Azure authentication using the Az PowerShell module
- **Entra ID Integration**: Retrieves direct group memberships from Microsoft Entra ID
- **Azure DevOps Groups**: Discovers Azure DevOps group memberships (both native and Entra-backed)
- **Parallel Hierarchy Traversal**: Uses parallel processing to efficiently expand group memberships
- **Multiple Path Detection**: Finds all possible inheritance paths from user to target group
- **Robust Error Handling**: Gracefully handles edge cases like users with no group memberships
- **CSV Export**: Exports all discovered chains to a timestamped CSV file for analysis
- **JSON Export**: Optional export of the complete group hierarchy as JSON
- **Deduplication**: Deduplicates results by the path to the target group while keeping full chains in CSV

## Prerequisites

- PowerShell 5.1 or later
- Azure PowerShell module (Az) - automatically installed if not present
- Appropriate permissions:
  - Azure DevOps organization access
  - Microsoft Graph API permissions to read user and group data
  - Entra ID directory read permissions

## Parameters

- **`-UserIdentifier`** (Required): User's display name, principal name, or email address
- **`-TargetGroupName`** (Required): Name of the target group to find inheritance paths to
- **`-OrgName`** (Required): Azure DevOps organization name
- **`-ExportJson`** (Optional): Switch to export the full hierarchy as JSON

## Usage

### Basic Usage
```powershell
.\InheritanceHelper.ps1 -UserIdentifier "john.doe@contoso.com" -TargetGroupName "Contributors" -OrgName "myorg"
```

### Fully Qualified Target Group
```powershell
.\InheritanceHelper.ps1 -UserIdentifier "john.doe@contoso.com" -TargetGroupName "[MyProject]\Contributors" -OrgName "myorg"
```

### With JSON Export
```powershell
.\InheritanceHelper.ps1 -UserIdentifier "john.doe@contoso.com" -TargetGroupName "Contributors" -OrgName "myorg" -ExportJson
```

## Output

The script provides:

1. **Console Output**: Visual display of all inheritance paths showing:
   - User information
   - Group membership hierarchy with indentation
   - Origin of each group (Entra or Azure DevOps)
   - Fully qualified group names when available
   - Paths stop at the target group (groups after the target are not shown on screen)
   - CSV export location

2. **CSV Export**: `InheritanceChains_<timestamp>.csv`
   - All discovered chains with groups organized by level
   - Includes fully qualified name (FQN), DisplayName, Origin, and Descriptor for each group
   - Includes groups after the target group
   - Can be imported into Excel or other tools for further analysis

3. **JSON Export** (Optional): `GroupHierarchy_<UserIdentifier>_<timestamp>.json`
   - Complete hierarchy data including relationships
   - User information
   - All group details
   - Useful for programmatic processing

## Notes on PIM (Privileged Identity Management) Groups

If the permission you are investigating is granted through a PIM-eligible group, the group name you see in PIM is often not the same as the group that actually appears in Azure DevOps permissions. To trace the inheritance path correctly:

1. **Activate** the PIM membership for the role/group.
2. **Re-evaluate** the permission in Azure DevOps after activation (permissions are only effective while active).
3. In the relevant security/permissions UI, use the **info/hover details** to find the exact group name that grants the permission.
4. Use that fully qualified group name as `-TargetGroupName` in this script to trace the inheritance chain.

This workflow ensures the script is searching for the actual permission-granting group, not the PIM eligibility group.

## How It Works

1. **Authentication**: Acquires tokens for Azure DevOps and Microsoft Graph APIs
2. **User Lookup**: Finds the user in Azure DevOps, searching through paginated results
3. **Target Group Search**: Locates the target group by name (fully qualified names recommended)
4. **Membership Check**: Validates whether the user has membership in the target group
5. **Direct Memberships**: Retrieves user's direct group memberships from both Azure DevOps and Entra ID
6. **Parallel Expansion**: Uses parallel processing to recursively discover parent groups
7. **Chain Building**: Constructs all possible inheritance paths from user to target group
8. **Filtering & Deduplication**: Deduplicates by the path to the target group
9. **Results Display**: Shows all unique paths to the target group on screen

## Example Output

```
=== RESULTS ===
Found 1 inheritance path(s) from John Doe to [MyProject]\Contributors

--- Path 1 ---
User: John Doe
 └─ Engineering (Origin: aad)
    └─ [MyProject]\Contributors (Origin: vsts)
```

## Error Handling

- **No membership found**: Script gracefully exits with a clear message when user is not a member of the target group
- **User not found**: Provides helpful guidance if the user identifier doesn't match
- **Group not found**: Suggests using a fully qualified group name if multiple groups match
- **No group memberships**: Clearly indicates when a user has no group memberships to trace
- **API throttling**: Automatic retry logic for HTTP 429 (rate limit) responses
- **Service unavailability**: Retry mechanism for HTTP 503 (service unavailable) errors

## Generated Files

The script creates timestamped export files in the current directory:
- `InheritanceChains_<timestamp>.csv` - Always generated
- `GroupHierarchy_<UserIdentifier>_<timestamp>.json` - Only if `-ExportJson` is used

These files are excluded from version control via `.gitignore`.

## License

See [LICENSE](LICENSE) file for details.
