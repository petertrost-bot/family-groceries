#!/usr/bin/env bash
# Account deletion end to end against the running local stack (supabase start).
# Usage: supabase/functions/account/smoke.sh   Prints PASS/FAIL per step; exits 1 on any FAIL.
set -euo pipefail
cd "$(dirname "$0")/../../.."

status=$(supabase status -o json 2>/dev/null)
API=$(jq -r .API_URL <<<"$status")
KEY=$(jq -r .PUBLISHABLE_KEY <<<"$status")
SECRET=$(jq -r .SECRET_KEY <<<"$status")
FN="$API/functions/v1"
RUN=$RANDOM$RANDOM
PASSWORD='smoke-Passw0rd!'
failures=0

check() { # check <description> <actual> <expected>
  if [[ "$2" == "$3" ]]; then echo "PASS $1"; else echo "FAIL $1 (got '$2', want '$3')"; failures=$((failures + 1)); fi
}

signup() { # signup <name> -> access token, user id
  curl -sS "$API/auth/v1/signup" -H "apikey: $KEY" -H 'content-type: application/json' \
    -d "{\"email\":\"$1-$RUN@smoke.test\",\"password\":\"$PASSWORD\"}"
}

rpc() { # rpc <token> <function> <json args>
  curl -sS "$API/rest/v1/rpc/$2" -H "apikey: $KEY" -H "authorization: Bearer $1" \
    -H 'content-type: application/json' -d "$3"
}

rest() { # rest <token> <method> <path> [json body]
  curl -sS -X "$2" "$API/rest/v1/$3" -H "apikey: $KEY" -H "authorization: Bearer $1" \
    -H 'content-type: application/json' -H 'prefer: return=representation' ${4:+-d "$4"}
}

delete_account() { # delete_account <token> -> "<status> <body>"
  curl -sS -o /tmp/smoke-account-body -w '%{http_code}' -X POST "$FN/account/delete" \
    -H "authorization: Bearer $1" -H 'content-type: application/json' -d '{}'
  echo " $(cat /tmp/smoke-account-body)"
}

household_rows() { # household_rows <household id> -> "table=n ..." for every household-owned table
  local out=() n
  for table in households household_members invites categories stores store_category_order items \
    item_events category_memory item_store_memory personal_access_tokens; do
    local column=household_id
    [[ $table == households ]] && column=id
    n=$(curl -sS -o /dev/null -D - "$API/rest/v1/$table?$column=eq.$1&select=$column" \
      -H "apikey: $SECRET" -H 'prefer: count=exact' -H 'range: 0-0' |
      tr -d '\r' | awk -F/ 'tolower($0) ~ /^content-range:/ {print $2}')
    out+=("$table=$n")
  done
  echo "${out[*]}"
}

a=$(signup alice); A=$(jq -r .access_token <<<"$a"); A_ID=$(jq -r .user.id <<<"$a")
b=$(signup bob); B=$(jq -r .access_token <<<"$b"); B_ID=$(jq -r .user.id <<<"$b")
c=$(signup carl); C=$(jq -r .access_token <<<"$c"); C_ID=$(jq -r .user.id <<<"$c")
check 'three users signed up' "$([[ $A != null && $B != null && $C != null ]] && echo ok)" ok

HH=$(rpc "$A" create_household '{"p_name":"Smoke"}' | jq -r .id)
CODE=$(rpc "$A" create_invite "{\"p_household\":\"$HH\"}" | jq -r .code)
check 'Bob joins' "$(rpc "$B" join_household "{\"p_code\":\"$CODE\"}" | jq -r .)" "$HH"
check 'Carl joins' "$(rpc "$C" join_household "{\"p_code\":\"$CODE\"}" | jq -r .)" "$HH"

rest "$A" POST items "{\"household_id\":\"$HH\",\"name\":\"Milch\"}" >/dev/null
rest "$B" POST items "[{\"household_id\":\"$HH\",\"name\":\"Brot\"},{\"household_id\":\"$HH\",\"name\":\"Kaffee\"}]" >/dev/null
rest "$B" PATCH "items?household_id=eq.$HH&name=eq.Milch" '{"status":"bought"}' >/dev/null
rest "$C" POST items "{\"household_id\":\"$HH\",\"name\":\"Eier\"}" >/dev/null
B_PAT=$(rpc "$B" create_personal_access_token '{"p_name":"Siri"}' | jq -r '.[0].token')
A_PAT=$(rpc "$A" create_personal_access_token '{"p_name":"Siri"}' | jq -r '.[0].token')
voice() { curl -sS -o /dev/null -w '%{http_code}' "$FN/voice" -H "authorization: Bearer $1" \
  -H 'content-type: application/json' -d '{"text":"Gurken","mode":"parse"}'; }
check "Bob's token works before deletion" "$(voice "$B_PAT")" 200

export_doc=$(rpc "$B" export_my_data '{}')
check 'export has the documented format' "$(jq -r '.format + " " + (.version|tostring)' <<<"$export_doc")" 'family-groceries-export 1'
check "export lists Bob's own items only" "$(jq -c '[.items_added[].name] | sort' <<<"$export_doc")" '["Brot","Kaffee"]'
check 'export carries no token hash' "$(grep -c token_hash <<<"$export_doc" || true)" 0
r=$(delete_account "$B_PAT")
check 'a personal access token cannot delete the account' "${r%% *} $(jq -r .error <<<"${r#* }")" '403 session_required'
check 'a request without a token is refused' \
  "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$FN/account/delete")" 401
check 'GET is not allowed' "$(curl -sS -o /dev/null -w '%{http_code}' "$FN/account/delete" -H "authorization: Bearer $B")" 405

result=$(delete_account "$B")
check 'Bob deletes his account' "$result" '200 {"deleted":true,"household":"kept","apple":"not_linked"}'
check 'Alice still reads every item' "$(rest "$A" GET "items?household_id=eq.$HH&select=name&order=name" | jq -c '[.[].name]')" \
  '["Brot","Eier","Kaffee","Milch"]'
check "Bob's items stay without an author" \
  "$(rest "$A" GET "items?household_id=eq.$HH&name=in.(Brot,Kaffee)&select=added_by" | jq -c '[.[].added_by]')" '[null,null]'
check "the item Bob bought stays without a buyer" \
  "$(rest "$A" GET "items?household_id=eq.$HH&name=eq.Milch&select=added_by,bought_by,status" | jq -c '.[0]')" \
  "{\"added_by\":\"$A_ID\",\"bought_by\":null,\"status\":\"bought\"}"
check "Alice can still add items" \
  "$(rest "$A" POST items "{\"household_id\":\"$HH\",\"name\":\"Tee\"}" | jq -r '.[0].name')" Tee
check "Bob's token no longer works" "$(voice "$B_PAT")" 401
check 'Bob can no longer sign in' "$(curl -sS -o /dev/null -w '%{http_code}' "$API/auth/v1/token?grant_type=password" \
  -H "apikey: $KEY" -H 'content-type: application/json' \
  -d "{\"email\":\"bob-$RUN@smoke.test\",\"password\":\"$PASSWORD\"}")" 400
check "Bob is gone from Auth" "$(curl -sS -o /dev/null -w '%{http_code}' "$API/auth/v1/admin/users/$B_ID" -H "apikey: $SECRET")" 404
check 'a repeated delete with the old session answers like the first (idempotent 200)' \
  "$(delete_account "$B")" '200 {"deleted":true,"household":"none","apple":"not_linked"}'

check 'the Auth admin API (dashboard) deletes Carl, who added an item' \
  "$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$API/auth/v1/admin/users/$C_ID" -H "apikey: $SECRET")" 200
check "Carl's item stays without an author" \
  "$(rest "$A" GET "items?household_id=eq.$HH&name=eq.Eier&select=added_by" | jq -c '[.[].added_by]')" '[null]'
check 'Alice is now the only member' "$(rest "$A" GET "household_members?household_id=eq.$HH&select=user_id,role" | jq -c .)" \
  "[{\"user_id\":\"$A_ID\",\"role\":\"owner\"}]"

LIDL=$(rest "$A" GET "stores?household_id=eq.$HH&seed_key=eq.lidl&select=id" | jq -r '.[0].id')
DRINKS=$(rest "$A" GET "categories?household_id=eq.$HH&seed_key=eq.drinks&select=id" | jq -r '.[0].id')
rest "$A" PATCH "items?household_id=eq.$HH&name=eq.Tee" "{\"store_id\":\"$LIDL\",\"category_id\":\"$DRINKS\"}" >/dev/null
before=$(household_rows "$HH")
echo "     $before"
check 'before: the household has rows in every table' "$(tr ' ' '\n' <<<"$before" | grep -cvE '=[1-9][0-9]*$' || true)" 0
check 'Alice, the last member, deletes her account' "$(delete_account "$A")" \
  '200 {"deleted":true,"household":"deleted","apple":"not_linked"}'
check 'after: no row of the household is left in any table' "$(household_rows "$HH")" \
  'households=0 household_members=0 invites=0 categories=0 stores=0 store_category_order=0 items=0 item_events=0 category_memory=0 item_store_memory=0 personal_access_tokens=0'
check "Alice's token no longer works" "$(voice "$A_PAT")" 401

if ((failures)); then echo "$failures step(s) failed"; exit 1; fi
echo 'all steps passed'
