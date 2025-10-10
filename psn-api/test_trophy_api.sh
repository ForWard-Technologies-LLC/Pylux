#!/bin/bash
# Test the PSN Trophy API endpoint directly

if [ -z "$1" ]; then
    echo "Usage: $0 <access_token> [limit] [offset]"
    echo ""
    echo "Example:"
    echo "  $0 YOUR_ACCESS_TOKEN"
    echo "  $0 YOUR_ACCESS_TOKEN 10"
    echo "  $0 YOUR_ACCESS_TOKEN 10 20"
    exit 1
fi

ACCESS_TOKEN="$1"
LIMIT="${2:-}"
OFFSET="${3:-0}"

URL="https://m.np.playstation.com/api/trophy/v1/users/me/trophyTitles"

# Build query parameters
PARAMS=""
if [ -n "$LIMIT" ]; then
    PARAMS="?limit=$LIMIT&offset=$OFFSET"
fi

echo "Fetching trophy titles from: $URL$PARAMS"
echo "========================================"
echo ""

curl -s -H "Authorization: Bearer $ACCESS_TOKEN" "$URL$PARAMS" | jq '.'

