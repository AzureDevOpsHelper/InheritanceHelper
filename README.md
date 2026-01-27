# InheritanceHelper

Help finding the chain of inheritance (group memberships across Entra and DevOps) from a user to a group that is blamed for a certain permission in the UI.

## Overview

InheritanceHelper is a PowerShell script that traces group membership chains from a user to a target group across both Azure DevOps and Microsoft Entra ID (formerly Azure Active Directory). This is particularly useful for understanding why a user has certain permissions through nested group memberships.

> **Note**: This script was generated via GitHub Copilot and while it appears to function as designed, the creator has not had time yet to fully review and hopefully refactor. This is a large script that may benefit from additional optimization and code review.

## Features

- **Cross-Platform Authentication**: Automatically handles Azure authentication using the Az PowerShell module
- **Entra ID Integration**: Retrieves direct group memberships from Microsoft Entra ID
- **Azure DevOps Groups**: Discovers all Azure DevOps group memberships (both native and Entra-backed)
- **Recursive Chain Building**: Builds complete inheritance chains showing how a user inherits membership through nested groups
- **Multiple Path Detection**: Finds all possible inheritance paths from user to target group
- **CSV Export**: Exports all discovered chains to a timestamped CSV file
- **JSON Export**: Optional export of the complete group hierarchy as JSON
- **Deduplication**: Automatically removes duplicate inheritance paths

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
- **`-ProjectName`** (Optional): Project name to scope the group search to a specific project
- **`-ExportJson`** (Optional): Switch to export the full hierarchy as JSON

## Usage

### Basic Usage
```powershell
.\InheritanceHelper.ps1 -UserIdentifier "john.doe@contoso.com" -TargetGroupName "Contributors" -OrgName "myorg"
```

### With Project Scope
```powershell
.\InheritanceHelper.ps1 -UserIdentifier "john.doe@contoso.com" -TargetGroupName "Contributors" -OrgName "myorg" -ProjectName "MyProject"
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
   - Origin of each group (Entra ID or Azure DevOps)
   - Number of paths found

2. **CSV Export**: `InheritanceChains_<timestamp>.csv`
   - All discovered chains with groups organized by level
   - Includes DisplayName, Origin, and Descriptor for each group

3. **JSON Export** (Optional): `GroupHierarchy_<UserIdentifier>_<timestamp>.json`
   - Complete hierarchy data including relationships
   - User information
   - All group details

## How It Works

1. **Authentication**: Acquires tokens for Azure DevOps and Microsoft Graph APIs
2. **User Lookup**: Finds the user in both Azure DevOps and Entra ID
3. **Direct Memberships**: Retrieves user's direct group memberships from both systems
4. **Recursive Expansion**: Recursively discovers parent groups (groups that contain other groups)
5. **Chain Building**: Constructs all possible inheritance paths from user to target group
6. **Filtering & Deduplication**: Truncates chains at target group and removes duplicates
7. **Results Display**: Shows all unique paths from user to target group

## Example Output

```
=== RESULTS ===
Found 2 inheritance path(s) from John Doe to Contributors

--- Path 1 ---
User: John Doe
   └─> Development Team (Origin: aad)
     └─> Project Contributors (Origin: vstfs)
       └─> Contributors (Origin: vstfs)

--- Path 2 ---
User: John Doe
   └─> Engineering (Origin: aad)
     └─> Contributors (Origin: vstfs)
```

## Error Handling

- Automatic retry logic for API throttling (HTTP 429)
- Retry mechanism for service unavailability (HTTP 503)
- Graceful handling of 404 errors for non-existent resources
- Detailed error messages with stack traces for troubleshooting

## License

See [LICENSE](LICENSE) file for details.
