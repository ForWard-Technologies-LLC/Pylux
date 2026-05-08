#!/usr/bin/env python3
"""
Test the PSN Trophy API endpoint directly using the access token from Chiaki-NG.
This script fetches:
1. All trophy titles (games)
2. Trophy groups for each game
3. Individual trophies for each group

PSN API Endpoints Discovered:
=============================

Trophy API (Requires Auth):
---------------------------
1. Get all trophy titles (games):
   GET https://m.np.playstation.com/api/trophy/v1/users/me/trophyTitles
   Returns: Game name, platform, trophy counts, progress, npCommunicationId, game icon

2. Get trophy groups for a game:
   GET https://m.np.playstation.com/api/trophy/v1/npCommunicationIds/{npCommunicationId}/trophyGroups
   Returns: Trophy groups (main game + DLC), trophy counts per group

3. Get individual trophies:
   GET https://m.np.playstation.com/api/trophy/v1/npCommunicationIds/{npCommunicationId}/trophyGroups/{groupId}/trophies
   Returns: All trophy details (name, description, type, icon, hidden status)

PlayStation Store API (Public, No Auth Required):
-------------------------------------------------
4. Get game cover art and metadata:
   GET https://store.playstation.com/store/api/chihiro/00_09_000/container/{COUNTRY}/{LANG}/999/{TITLE_ID}_00/0
   Returns: Game name, cover art (multiple sizes), release date, provider
   
   URL Structure:
   - chihiro: PlayStation Store internal API name
   - 00_09_000: API version/endpoint type (not officially documented)
   - container: Content type being accessed
   - {COUNTRY}: Country code (US, GB, JP, etc.)
   - {LANG}: Language code (en, ja, etc.)
   - 999: Routing identifier (not officially documented, appears to be a placeholder)
   - {TITLE_ID}_00: Full title ID with version suffix
   - 0: Revision/version number
   
   Title ID Format: Append '_00' to the title ID
   - PS5: PPSA01325 → PPSA01325_00
   - PS4: CUSA07820 → CUSA07820_00
   - PS3: BCUS98174 → BCUS98174_00
   
   Image Types in response:
   - Type 10: Primary cover art
   - Type 12: Alternative cover
   - Type 13: Another variant
   
   Works across all platforms: PS3, PS4, PS5

NOTE: Trophy API uses npCommunicationId (e.g., NPWR20188_00), 
      Store API uses Title ID (e.g., PPSA01325_00).
      These are different identifiers for the same game.
"""

import json
import sys
import urllib.request
import urllib.error


def make_request(url, access_token):
    """Make an authenticated request to the PSN API."""
    headers = {
        'Authorization': f'Bearer {access_token}',
        'Accept': 'application/json'
    }
    
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req) as response:
            return json.loads(response.read().decode())
    except urllib.error.HTTPError as e:
        print(f"HTTP Error {e.code}: {e.reason}", file=sys.stderr)
        print(f"URL: {url}", file=sys.stderr)
        if hasattr(e, 'read'):
            print(f"Response: {e.read().decode()}", file=sys.stderr)
        return None
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return None


def get_trophy_titles(access_token):
    """Get all trophy titles (games) for the authenticated user."""
    url = "https://m.np.playstation.com/api/trophy/v1/users/me/trophyTitles"
    return make_request(url, access_token)


def get_trophy_groups(access_token, np_communication_id):
    """Get trophy groups for a specific game."""
    url = f"https://m.np.playstation.com/api/trophy/v1/npCommunicationIds/{np_communication_id}/trophyGroups"
    return make_request(url, access_token)


def get_trophies(access_token, np_communication_id, trophy_group_id):
    """Get individual trophies for a specific trophy group."""
    url = f"https://m.np.playstation.com/api/trophy/v1/npCommunicationIds/{np_communication_id}/trophyGroups/{trophy_group_id}/trophies"
    return make_request(url, access_token)


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 test_trophy_api.py <access_token>")
        print("\nThis script will fetch:")
        print("  1. All trophy titles (games)")
        print("  2. Trophy groups for each game")
        print("  3. Individual trophies for each group")
        sys.exit(1)
    
    access_token = sys.argv[1]
    
    # Store all data for final JSON output
    all_data = {
        'trophyTitles': [],
        'totalGames': 0
    }
    
    print("=" * 80)
    print("PSN TROPHY API TEST")
    print("=" * 80)
    print()
    
    # Step 1: Get all trophy titles
    print("[STEP 1] Fetching Trophy Titles...")
    print("-" * 80)
    titles_data = get_trophy_titles(access_token)
    
    if not titles_data or 'trophyTitles' not in titles_data:
        print("Failed to fetch trophy titles!")
        sys.exit(1)
    
    total_games = titles_data.get('totalItemCount', 0)
    all_data['totalGames'] = total_games
    print(f"Total Games: {total_games}")
    print()
    
    for i, title in enumerate(titles_data['trophyTitles'], 1):
        game_name = title.get('trophyTitleName', 'Unknown')
        platform = title.get('trophyTitlePlatform', 'Unknown')
        comm_id = title.get('npCommunicationId', 'N/A')
        progress = title.get('progress', 0)
        
        print(f"Game {i}: {game_name}")
        print(f"  Platform: {platform}")
        print(f"  Communication ID: {comm_id}")
        print(f"  Progress: {progress}%")
        
        defined = title.get('definedTrophies', {})
        earned = title.get('earnedTrophies', {})
        print(f"  Trophies: {earned.get('bronze', 0)}/{defined.get('bronze', 0)} Bronze, "
              f"{earned.get('silver', 0)}/{defined.get('silver', 0)} Silver, "
              f"{earned.get('gold', 0)}/{defined.get('gold', 0)} Gold, "
              f"{earned.get('platinum', 0)}/{defined.get('platinum', 0)} Platinum")
        print()
        
        # Create game entry for JSON
        game_entry = {
            'title': title,
            'trophyGroups': []
        }
        
        # Step 2: Get trophy groups for this game
        print(f"  [STEP 2] Fetching Trophy Groups for {game_name}...")
        print("  " + "-" * 76)
        groups_data = get_trophy_groups(access_token, comm_id)
        
        if not groups_data or 'trophyGroups' not in groups_data:
            print("  Failed to fetch trophy groups!")
            all_data['trophyTitles'].append(game_entry)
            continue
        
        trophy_groups = groups_data.get('trophyGroups', [])
        print(f"  Found {len(trophy_groups)} trophy group(s)")
        print()
        
        for j, group in enumerate(trophy_groups, 1):
            group_id = group.get('trophyGroupId', 'unknown')
            group_name = group.get('trophyGroupName', 'Unnamed Group')
            group_defined = group.get('definedTrophies', {})
            
            total_trophies = sum(group_defined.values())
            print(f"  Group {j}: {group_name} [{group_id}]")
            print(f"    Total Trophies: {total_trophies} "
                  f"({group_defined.get('bronze', 0)}B, "
                  f"{group_defined.get('silver', 0)}S, "
                  f"{group_defined.get('gold', 0)}G, "
                  f"{group_defined.get('platinum', 0)}P)")
            
            # Step 3: Get individual trophies for this group
            print(f"    [STEP 3] Fetching Individual Trophies...")
            trophies_data = get_trophies(access_token, comm_id, group_id)
            
            if not trophies_data or 'trophies' not in trophies_data:
                print("    Failed to fetch trophies!")
                game_entry['trophyGroups'].append({
                    'group': group,
                    'trophies': []
                })
                continue
            
            trophies = trophies_data.get('trophies', [])
            print(f"    Retrieved {len(trophies)} trophies")
            print()
            
            # Add to data structure
            game_entry['trophyGroups'].append({
                'group': group,
                'trophies': trophies
            })
            
            # Show first 5 trophies as sample
            sample_count = min(5, len(trophies))
            if sample_count > 0:
                print(f"    Sample Trophies (showing {sample_count} of {len(trophies)}):")
                for k, trophy in enumerate(trophies[:sample_count], 1):
                    trophy_type = trophy.get('trophyType', 'unknown').upper()
                    trophy_name = trophy.get('trophyName', 'Unnamed')
                    trophy_detail = trophy.get('trophyDetail', 'No description')
                    trophy_hidden = trophy.get('trophyHidden', False)
                    
                    hidden_str = " [HIDDEN]" if trophy_hidden else ""
                    print(f"      {k}. [{trophy_type}] {trophy_name}{hidden_str}")
                    print(f"         {trophy_detail}")
                
                if len(trophies) > sample_count:
                    print(f"      ... and {len(trophies) - sample_count} more trophies")
            
            print()
        
        all_data['trophyTitles'].append(game_entry)
    
    print("=" * 80)
    print("COMPLETE!")
    print("=" * 80)
    print()
    
    # Print full JSON output
    print("=" * 80)
    print("FULL JSON RESPONSE")
    print("=" * 80)
    print()
    print(json.dumps(all_data, indent=2))
    print()
    print("=" * 80)


if __name__ == "__main__":
    main()
