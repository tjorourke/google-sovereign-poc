# lib-labels.sh — the company label on everything this repo applies with
# kubectl. Sourced by lib.sh, and by the TrustUsBank lab's scripts directly.
#
# Helm installs get the label from the company-labels post-renderer (see
# company_labels in lib.sh). Everything else here is `kubectl apply` of a file
# or a heredoc: model servers, MCP servers, agents, waypoints, test pods. Rather
# than edit every manifest and trust the next one to remember, `kubectl apply`
# is wrapped so its input goes through the same renderer. That labels each
# object, each pod template, and the CR fields controllers build pods from
# (EnterpriseAgentgatewayParameters, Gateway infrastructure, kagent MCPServer
# and Agent deployment). Selectors are never touched.
#
# Bypass for one call with LABEL_APPLY=0.

COMPANY_LABEL_KEY="${COMPANY_LABEL_KEY:-company}"
COMPANY_LABEL_VALUE="${COMPANY_LABEL_VALUE:-trustusbank}"
export COMPANY_LABEL_KEY COMPANY_LABEL_VALUE

COMPANY_LABEL_RENDERER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/infra/helm/plugins/company-labels/render.py"

# Concatenate one -f source as a YAML stream.
_label_source() {
  local src="$1" recursive="$2" f
  case "$src" in
    -) cat ;;
    http://*|https://*) curl -fsSL "$src" ;;
    *)
      if [[ -d "$src" ]]; then
        local depth=(-maxdepth 1); [[ "$recursive" == 1 ]] && depth=()
        while IFS= read -r f; do cat "$f"; printf '\n---\n'; done < <(
          find "$src" ${depth[@]+"${depth[@]}"} -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) | sort)
      else
        cat "$src"
      fi ;;
  esac
  printf '\n---\n'
}

kubectl() {
  if [[ "${LABEL_APPLY:-1}" == 0 ]]; then command kubectl "$@"; return; fi

  # Find the subcommand: the first bare word that is not a global flag's value.
  local a sub="" skip=0
  for a in "$@"; do
    if [[ $skip == 1 ]]; then skip=0; continue; fi
    case "$a" in
      --context|-n|--namespace|--kubeconfig|--cluster|--user|-s|--server) skip=1 ;;
      -*) ;;
      *) sub="$a"; break ;;
    esac
  done
  [[ "$sub" == apply ]] || { command kubectl "$@"; return; }

  local rest=() files=() kusts=() recursive=0 want=""
  for a in "$@"; do
    if [[ -n "$want" ]]; then
      [[ "$want" == f ]] && files+=("$a") || kusts+=("$a"); want=""; continue
    fi
    case "$a" in
      view-last-applied|set-last-applied|edit-last-applied) command kubectl "$@"; return ;;
      -f|--filename) want=f ;;
      --filename=*) files+=("${a#--filename=}") ;;
      -k|--kustomize) want=k ;;
      --kustomize=*) kusts+=("${a#--kustomize=}") ;;
      -R|--recursive|--recursive=true) recursive=1 ;;
      *) rest+=("$a") ;;
    esac
  done
  [[ ${#files[@]} -gt 0 || ${#kusts[@]} -gt 0 ]] || { command kubectl "$@"; return; }

  local s
  {
    for s in ${files[@]+"${files[@]}"}; do _label_source "$s" "$recursive"; done
    for s in ${kusts[@]+"${kusts[@]}"}; do command kubectl kustomize "$s"; printf '\n---\n'; done
  } | python3 "$COMPANY_LABEL_RENDERER" | command kubectl ${rest[@]+"${rest[@]}"} -f -
  local rc=("${PIPESTATUS[@]}")
  for s in "${rc[@]}"; do [[ "$s" == 0 ]] || return "$s"; done
}
