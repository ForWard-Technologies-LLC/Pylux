# PSN Trophy API Test Scripts

This directory contains test scripts for accessing PlayStation Network Trophy and Store APIs directly using Chiaki-NG OAuth access tokens.

## 🎯 Purpose

These scripts demonstrate how to:
- Retrieve user's game library via Trophy API
- Get detailed trophy information for each game
- Access game cover art from public PlayStation Store API
- All using Chiaki-NG's existing OAuth authentication (no PSNAWP dependency)

## 📋 Files

| File | Description |
|------|-------------|
| `test_trophy_api.py` | Comprehensive Python script that fetches all trophy data (titles, groups, individual trophies) with full JSON output |
| `test_trophy_api.sh` | Simple bash script for testing trophy titles endpoint |
| `get_all_trophies.sh` | Advanced bash script to fetch complete trophy hierarchy |

## 🚀 Quick Start

### Using Python Script (Recommended)

```bash
# Get all trophy data with pretty JSON output
python3 test_trophy_api.py YOUR_ACCESS_TOKEN
```

### Using Bash Scripts

```bash
# Get trophy titles only
./test_trophy_api.sh YOUR_ACCESS_TOKEN [limit]

# Get complete trophy hierarchy
./get_all_trophies.sh YOUR_ACCESS_TOKEN
```

## 🔑 Getting Access Token

The access token is your existing Chiaki-NG OAuth token. You can find it in:
- Chiaki-NG settings/config
- Network logs when connecting to PSN

## 📚 API Endpoints Documentation

### Trophy API (Requires Auth)

#### 1. Get All Trophy Titles (Games)
```
GET https://m.np.playstation.com/api/trophy/v1/users/me/trophyTitles
```

**Returns:**
- Game name, platform, trophy counts
- Progress percentage
- npCommunicationId (for fetching more trophy data)
- Game icon URL
- Last played date

**Example Response:**
```json
{
  "trophyTitles": [{
    "npCommunicationId": "NPWR20188_00",
    "trophyTitleName": "ASTRO's PLAYROOM",
    "trophyTitlePlatform": "PS5",
    "progress": 2,
    "definedTrophies": {"bronze": 31, "silver": 14, "gold": 5, "platinum": 1},
    "earnedTrophies": {"bronze": 2, "silver": 0, "gold": 0, "platinum": 0},
    "lastUpdatedDateTime": "2025-08-21T01:51:35Z"
  }],
  "totalItemCount": 1
}
```

#### 2. Get Trophy Groups
```
GET https://m.np.playstation.com/api/trophy/v1/npCommunicationIds/{npCommunicationId}/trophyGroups
```

**Returns:**
- Trophy groups (main game + DLC)
- Trophy counts per group
- Group names and icons

#### 3. Get Individual Trophies
```
GET https://m.np.playstation.com/api/trophy/v1/npCommunicationIds/{npCommunicationId}/trophyGroups/{groupId}/trophies
```

**Returns:**
- Trophy ID, name, description
- Trophy type (platinum/gold/silver/bronze)
- Trophy icon URL
- Hidden status
- Progress target value (for PS5 progress trophies)

### PlayStation Store API (Public, No Auth)

#### 4. Get Game Cover Art & Metadata
```
GET https://store.playstation.com/store/api/chihiro/00_09_000/container/{COUNTRY}/{LANG}/999/{TITLE_ID}_00/0
```

**Parameters:**
- `COUNTRY`: US, GB, JP, etc.
- `LANG`: en, ja, etc.
- `TITLE_ID_00`: Full title ID with `_00` suffix

**Returns:**
- Game name, release date, provider
- **Cover art images** (multiple sizes/types)
- Platform information
- Store metadata

**Title ID Format:**
| Platform | Example Short | Full Format |
|----------|--------------|-------------|
| PS5 | `PPSA01325` | `PPSA01325_00` |
| PS4 | `CUSA07820` | `CUSA07820_00` |
| PS3 | `BCUS98174` | `BCUS98174_00` |

**Image Types:**
- **Type 10**: Primary cover art
- **Type 12**: Alternative cover
- **Type 13**: Another variant

**Example:**
```bash
curl -s "https://store.playstation.com/store/api/chihiro/00_09_000/container/US/en/999/PPSA01325_00/0" | jq '.links[0].images'
```

## 🔍 Important Notes

### ID Differences
- **Trophy API** uses `npCommunicationId` (e.g., `NPWR20188_00`)
- **Store API** uses `Title ID` (e.g., `PPSA01325_00`)
- These are **different identifiers** for the same game
- Currently no official mapping API between them

### Authentication
- Trophy API requires OAuth `Bearer` token
- Store API is **public** (no auth needed)

### Scope Requirements
The Trophy API works with Chiaki-NG's default OAuth scopes:
- `psn:clientapp`
- `referenceDataService:countryConfig.read`
- `pushNotification:webSocket.desktop.connect`
- `sessionManager:remotePlaySession.system.update`

## 🎮 Use Cases for Chiaki-NG

These APIs enable:
1. **Game Library Display**: Show user's played games with icons
2. **Direct Game Launch**: Select which game to launch on console
3. **Trophy Integration**: Display trophy progress in UI
4. **Cover Art**: Enhance UI with official game artwork
5. **Recently Played**: Track last played games

## 📝 Example Output

See `test_trophy_api.py` output for a complete example showing:
- Summary of all games and trophy progress
- Complete JSON structure with all trophy data
- All individual trophy details

## ⚠️ Disclaimer

These are unofficial/undocumented PlayStation APIs. Use responsibly to avoid potential rate limiting or account restrictions.

---

**Created for Chiaki-NG** - Direct game launch feature research
