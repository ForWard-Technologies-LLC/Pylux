#!/bin/bash
# Get all trophy information for all games and their individual trophies

if [ -z "$1" ]; then
    echo "Usage: $0 <access_token>"
    echo ""
    echo "This will fetch:"
    echo "  1. All trophy titles (games)"
    echo "  2. Trophy groups for each game"
    echo "  3. Individual trophies for each group"
    exit 1
fi

ACCESS_TOKEN="$1"
BASE_URL="https://m.np.playstation.com/api/trophy/v1"

echo "========================================"
echo "Fetching Trophy Data"
echo "========================================"
echo ""

# Step 1: Get all trophy titles
echo "[1/3] Fetching trophy titles..."
TITLES=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
    "$BASE_URL/users/me/trophyTitles")

echo "$TITLES" | jq -r '.trophyTitles[] | "\(.trophyTitleName) [\(.trophyTitlePlatform)] - \(.npCommunicationId)"'
echo ""

# Save to file
echo "$TITLES" > /tmp/trophy_titles.json

# Extract communication IDs
COMM_IDS=$(echo "$TITLES" | jq -r '.trophyTitles[].npCommunicationId')

if [ -z "$COMM_IDS" ]; then
    echo "No trophy titles found!"
    exit 0
fi

# Step 2: Get trophy groups for each title
echo "[2/3] Fetching trophy groups for each title..."
for COMM_ID in $COMM_IDS; do
    echo "  Getting groups for: $COMM_ID"
    
    GROUPS=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
        "$BASE_URL/npCommunicationIds/$COMM_ID/trophyGroups")
    
    echo "$GROUPS" | jq -r '.trophyGroups[] | "    - Group \(.trophyGroupId): \(.trophyGroupName // "Default") (\(.definedTrophies | to_entries | map("\(.value) \(.key)") | join(", ")))"'
    
    # Save to file
    echo "$GROUPS" > "/tmp/trophy_groups_${COMM_ID}.json"
    
    # Extract group IDs
    GROUP_IDS=$(echo "$GROUPS" | jq -r '.trophyGroups[].trophyGroupId')
    
    # Step 3: Get individual trophies for each group
    echo "[3/3] Fetching individual trophies..."
    for GROUP_ID in $GROUP_IDS; do
        echo "    Getting trophies for group: $GROUP_ID"
        
        TROPHIES=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
            "$BASE_URL/npCommunicationIds/$COMM_ID/trophyGroups/$GROUP_ID/trophies")
        
        # Count trophies
        TROPHY_COUNT=$(echo "$TROPHIES" | jq -r '.trophies | length')
        echo "      Found $TROPHY_COUNT trophies"
        
        # Save to file
        echo "$TROPHIES" > "/tmp/trophies_${COMM_ID}_${GROUP_ID}.json"
        
        # Show first few trophies as sample
        echo "$TROPHIES" | jq -r '.trophies[0:3][] | "        [\(.trophyType)] \(.trophyName): \(.trophyDetail)"'
        
        if [ "$TROPHY_COUNT" -gt 3 ]; then
            echo "        ... and $((TROPHY_COUNT - 3)) more trophies"
        fi
    done
    echo ""
done

echo "========================================"
echo "Complete! Data saved to /tmp/trophy_*.json"
echo "========================================"
echo ""
echo "Files created:"
ls -lh /tmp/trophy*.json 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}'

