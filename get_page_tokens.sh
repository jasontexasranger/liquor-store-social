#!/bin/bash
# get_page_tokens.sh — exchanges a short-lived user token for permanent page tokens
# Usage: ./get_page_tokens.sh "<user_token>" <app_id> <app_secret>

USER_TOKEN="$1"
APP_ID="$2"
APP_SECRET="$3"

if [ -z "$USER_TOKEN" ] || [ -z "$APP_ID" ] || [ -z "$APP_SECRET" ]; then
  echo "Usage: ./get_page_tokens.sh \"<user_token>\" <app_id> <app_secret>"
  exit 1
fi

echo "Exchanging for 60-day long-lived user token..."
RESPONSE=$(curl -s "https://graph.facebook.com/oauth/access_token?grant_type=fb_exchange_token&client_id=${APP_ID}&client_secret=${APP_SECRET}&fb_exchange_token=${USER_TOKEN}")

LONG_LIVED=$(echo "$RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if 'access_token' in data:
    print(data['access_token'])
else:
    print('ERROR: ' + json.dumps(data), file=sys.stderr)
    sys.exit(1)
")

if [ $? -ne 0 ]; then
  echo "Failed to exchange token. Response: $RESPONSE"
  exit 1
fi

echo "Got 60-day token. Fetching permanent page tokens..."
PAGES=$(curl -s "https://graph.facebook.com/me/accounts?fields=id,name,access_token&access_token=${LONG_LIVED}")

echo ""
echo "======================================================"
echo "  PERMANENT PAGE TOKENS — save these to Supabase"
echo "======================================================"
echo "$PAGES" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if 'data' in data:
    for page in data['data']:
        print(f\"Secret Name : PT_{page['id']}\")
        print(f\"Page        : {page['name']}\")
        print(f\"Token       : {page['access_token']}\")
        print()
else:
    print('Error:', json.dumps(data))
"
