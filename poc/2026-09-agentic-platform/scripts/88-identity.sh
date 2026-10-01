#!/usr/bin/env bash
# 88-identity.sh — a person and an agent in every token the gateway sees.
#
# Keycloak (realm agentregistry) gets:
#   users     bob, alice                      the people signed in to the console
#   client    trustusbank-console (public)    signs them in; its tokens name every
#                                             agent client in aud, so an agent may
#                                             exchange them
#   clients   trustusbank-<domain> (confid.)  one identity per finance agent, with
#                                             standard token exchange (RFC 8693) and
#                                             a hardcoded agent_id claim
#
# A console turn exchanges bob's token at the agent's client: the result has
# preferred_username=bob AND azp=agent_id=trustusbank-payments. The agent sends
# that token to Gemma through agentgateway, which validates it (yaml/identity/)
# and attributes logs, traces and budgets to both.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require kubectl jq curl
load_env

NS=keycloak
REALM="${REALM:-agentregistry}"
PF_PORT="${IDENTITY_PF_PORT:-18088}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
DEMO_PASSWORD="${TRUSTUSBANK_USER_PASSWORD:-password}"
DOMAINS=(payments compliance credit gdpr)
# The SDLC demo's PM and engineer agents (demo-console/trustusbank-sdlc) act for bob too.
SDLC_CLIENTS=(tub-sdlc-pm tub-sdlc-dev)
USERS=("bob:Bob:Becker:bob@trustusbank.example:payments-ops" "alice:Alice:Albers:alice@trustusbank.example:compliance")

step "Keycloak admin API (port-forward :$PF_PORT)"
if lsof -nP -iTCP:"$PF_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  die "port $PF_PORT is in use; rerun with IDENTITY_PF_PORT=<free port>"
fi
kc -n "$NS" port-forward svc/keycloak "${PF_PORT}:8080" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
KC="http://localhost:${PF_PORT}"
for _ in $(seq 1 30); do curl -sf "$KC/realms/master" >/dev/null 2>&1 && break; sleep 1; done
ADM="$(curl -s -X POST "$KC/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=admin-cli&username=admin&password=${KEYCLOAK_ADMIN_PASSWORD}" | jq -r .access_token)"
[[ -n "$ADM" && "$ADM" != "null" ]] || die "could not get a Keycloak admin token"
ok "admin token"

api() {  # api METHOD PATH [JSON]
  local m="$1" p="$2"; shift 2
  curl -s -o /tmp/88-identity.out -w '%{http_code}' -X "$m" -H "Authorization: Bearer $ADM" \
    -H 'Content-Type: application/json' "$KC/admin/realms/${REALM}$p" ${1:+-d "$1"}
}
client_uuid() { curl -s -H "Authorization: Bearer $ADM" "$KC/admin/realms/${REALM}/clients?clientId=$1" | jq -r '.[0].id // empty'; }

# Create, or update in place, so a rerun converges instead of failing on 409.
upsert_client() {  # upsert_client JSON
  local id uuid; id="$(jq -r .clientId <<<"$1")"; uuid="$(client_uuid "$id")"
  if [[ -z "$uuid" ]]; then
    [[ "$(api POST /clients "$1")" == 201 ]] || die "create client $id: $(cat /tmp/88-identity.out)"
    uuid="$(client_uuid "$id")"
  else
    [[ "$(api PUT "/clients/$uuid" "$1")" == 204 ]] || die "update client $id: $(cat /tmp/88-identity.out)"
  fi
  echo "$uuid"
}
# kagent-controller authenticates every A2A call against this realm and maps the
# Groups claim to a role (configmap rbac-config-kagent-enterprise: writers ->
# global.Writer). Without Groups it 401s, so the tokens carry what the kagent
# clients' tokens carry.
kagent_mappers() {  # kagent_mappers CLIENT_UUID
  upsert_mapper "$1" '{"name":"groups","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper",
    "config":{"claim.name":"Groups","full.path":"false","access.token.claim":"true","id.token.claim":"true"}}'
  upsert_mapper "$1" '{"name":"kagent-backend-audience","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper",
    "config":{"included.client.audience":"kagent-backend","access.token.claim":"true","id.token.claim":"false"}}'
}
upsert_mapper() {  # upsert_mapper CLIENT_UUID JSON
  local name mid; name="$(jq -r .name <<<"$2")"
  mid="$(curl -s -H "Authorization: Bearer $ADM" "$KC/admin/realms/${REALM}/clients/$1/protocol-mappers/models" \
    | jq -r --arg n "$name" '.[] | select(.name==$n) | .id')"
  if [[ -z "$mid" ]]; then api POST "/clients/$1/protocol-mappers/models" "$2" >/dev/null
  else api PUT "/clients/$1/protocol-mappers/models/$mid" "$(jq --arg id "$mid" '. + {id:$id}' <<<"$2")" >/dev/null; fi
}

step "users"
# Keycloak 26's declarative user profile silently drops attributes it does not
# declare, so team would never reach a token. Allow unmanaged attributes.
curl -s -H "Authorization: Bearer $ADM" "$KC/admin/realms/${REALM}/users/profile" \
  | jq '. + {unmanagedAttributePolicy:"ENABLED"}' > /tmp/88-profile.json
api PUT /users/profile "$(cat /tmp/88-profile.json)" >/dev/null
for u in "${USERS[@]}"; do
  IFS=: read -r name first last email team <<<"$u"
  body="$(jq -n --arg u "$name" --arg f "$first" --arg l "$last" --arg e "$email" --arg t "$team" \
    '{username:$u, firstName:$f, lastName:$l, email:$e, emailVerified:true, enabled:true, attributes:{team:[$t]}}')"
  uid="$(curl -s -H "Authorization: Bearer $ADM" "$KC/admin/realms/${REALM}/users?username=$name&exact=true" | jq -r '.[0].id // empty')"
  if [[ -z "$uid" ]]; then
    api POST /users "$body" >/dev/null
    uid="$(curl -s -H "Authorization: Bearer $ADM" "$KC/admin/realms/${REALM}/users?username=$name&exact=true" | jq -r '.[0].id')"
  else
    api PUT "/users/$uid" "$body" >/dev/null
  fi
  gid="$(curl -s -H "Authorization: Bearer $ADM" "$KC/admin/realms/${REALM}/groups?search=writers&exact=true" | jq -r '.[] | select(.name=="writers") | .id')"
  if [[ -z "$gid" ]]; then
    api POST /groups '{"name":"writers"}' >/dev/null
    gid="$(curl -s -H "Authorization: Bearer $ADM" "$KC/admin/realms/${REALM}/groups?search=writers&exact=true" | jq -r '.[] | select(.name=="writers") | .id')"
  fi
  api PUT "/users/$uid/groups/$gid" >/dev/null
  api PUT "/users/$uid/reset-password" "$(jq -n --arg p "$DEMO_PASSWORD" '{type:"password",value:$p,temporary:false}')" >/dev/null
  ok "$name ($team)"
done

step "one confidential client per agent, with token exchange and an agent_id claim"
for c in "${DOMAINS[@]/#/trustusbank-}" "${SDLC_CLIENTS[@]}"; do
  uuid="$(upsert_client "$(jq -n --arg c "$c" --arg d "${c#trustusbank-}" '{
    clientId:$c, name:("TrustUsBank " + ($d | sub("-agent$"; "")) + " agent"), enabled:true, protocol:"openid-connect",
    publicClient:false, serviceAccountsEnabled:true, standardFlowEnabled:false, directAccessGrantsEnabled:false,
    attributes:{"standard.token.exchange.enabled":"true"}}')")"
  upsert_mapper "$uuid" "$(jq -n --arg c "$c" '{name:"agent_id", protocol:"openid-connect",
    protocolMapper:"oidc-hardcoded-claim-mapper", config:{"claim.name":"agent_id","claim.value":$c,
    "jsonType.label":"String","access.token.claim":"true","id.token.claim":"false","introspection.token.claim":"true"}}')"
  upsert_mapper "$uuid" "$(jq -n '{name:"team", protocol:"openid-connect", protocolMapper:"oidc-usermodel-attribute-mapper",
    config:{"user.attribute":"team","claim.name":"team","jsonType.label":"String","access.token.claim":"true"}}')"
  kagent_mappers "$uuid"
  ok "$c"
done

step "trustusbank-console: the public client the people sign in with"
uuid="$(upsert_client "$(jq -n '{clientId:"trustusbank-console", name:"TrustUsBank console", enabled:true,
  protocol:"openid-connect", publicClient:true, directAccessGrantsEnabled:true, standardFlowEnabled:true,
  redirectUris:["http://localhost:8900/*"], webOrigins:["+"]}')")"
# Standard token exchange only accepts a subject token whose aud names the
# requesting client, so the console's tokens are addressed to every agent.
for c in "${DOMAINS[@]/#/trustusbank-}" "${SDLC_CLIENTS[@]}"; do
  upsert_mapper "$uuid" "$(jq -n --arg c "$c" '{name:("aud-" + $c), protocol:"openid-connect",
    protocolMapper:"oidc-audience-mapper", config:{"included.client.audience":$c,"access.token.claim":"true","id.token.claim":"false"}}')"
done
upsert_mapper "$uuid" "$(jq -n '{name:"team", protocol:"openid-connect", protocolMapper:"oidc-usermodel-attribute-mapper",
  config:{"user.attribute":"team","claim.name":"team","jsonType.label":"String","access.token.claim":"true"}}')"
kagent_mappers "$uuid"
ok "trustusbank-console"

step "proof: bob's token, exchanged by the payments agent"
TOK="$KC/realms/${REALM}/protocol/openid-connect/token"
BOB="$(curl -s -X POST "$TOK" -d "grant_type=password&client_id=trustusbank-console&username=bob&password=${DEMO_PASSWORD}&scope=openid" | jq -r .access_token)"
[[ -n "$BOB" && "$BOB" != "null" ]] || die "bob could not sign in"
SECRET="$(curl -s -H "Authorization: Bearer $ADM" "$KC/admin/realms/${REALM}/clients/$(client_uuid trustusbank-payments)/client-secret" | jq -r .value)"
EX="$(curl -s -X POST "$TOK" -u "trustusbank-payments:${SECRET}" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange&subject_token=${BOB}&subject_token_type=urn:ietf:params:oauth:token-type:access_token&requested_token_type=urn:ietf:params:oauth:token-type:access_token")"
AT="$(jq -r '.access_token // empty' <<<"$EX")"
[[ -n "$AT" ]] || die "token exchange refused: $(jq -c '{error,error_description}' <<<"$EX")"
claims() { python3 -c 'import sys,json,base64; p=sys.argv[1].split(".")[1]; print(base64.urlsafe_b64decode(p+"="*(-len(p)%4)).decode())' "$1"; }
log "$(claims "$AT" | jq -c '{iss, preferred_username, azp, agent_id, team, Groups, aud}' 2>/dev/null || echo '(could not decode)')"
ok "one token names the person and the agent"
