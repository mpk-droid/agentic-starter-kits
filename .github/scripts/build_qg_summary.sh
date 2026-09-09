#!/usr/bin/env bash
# Build the quality-gates-pipeline Slack summary: a gate-level status block
# (QG1/QG2/QG4/QG7) plus a per-agent QG4/QG7 matrix. Prints Slack mrkdwn to
# stdout.

set -euo pipefail

command -v jq >/dev/null 2>&1 || {
  echo "jq is required to build the QG summary" >&2
  exit 1
}

QG1_RESULT="${QG1_RESULT:?QG1_RESULT is required}"
QG2_RESULT="${QG2_RESULT:?QG2_RESULT is required}"
QG4_RESULT="${QG4_RESULT:?QG4_RESULT is required}"
QG7_RESULT="${QG7_RESULT:?QG7_RESULT is required}"
QG4_OUTCOMES_DIR="${QG4_OUTCOMES_DIR:-qg4-outcomes}"
QG7_OUTCOMES_DIR="${QG7_OUTCOMES_DIR:-qg7-outcomes}"

# Agents that pass QG4 but are intentionally excluded from QG7 behavioral
# evals. Keep in sync with the qg7_excluded list in the collect-qg4 job of
# quality-gates-pipeline.yml.
QG7_EXCLUDED='[
  "langgraph/examples/guardrailed_agent",
  "langgraph/templates/agentic_rag"
]'

gate_icon() {
  case "$1" in
    success) echo "✅" ;;
    skipped) echo "⏭️" ;;
    *) echo "❌" ;;
  esac
}

gate_line() {
  local label="$1" result="$2" note="${3:-}"
  local icon
  icon="$(gate_icon "${result}")"
  if [[ -n "${note}" ]]; then
    echo "${icon} ${label}: ${result} (${note})"
  else
    echo "${icon} ${label}: ${result}"
  fi
}

qg2_note=""
[[ "${QG2_RESULT}" == "skipped" ]] && qg2_note="blocked by QG1"
qg4_note=""
[[ "${QG4_RESULT}" == "skipped" ]] && qg4_note="blocked by QG1/QG2"
qg7_note=""
[[ "${QG7_RESULT}" == "skipped" ]] && qg7_note="no agents eligible"

gate_summary="$(
  {
    echo "*Gate Summary*"
    gate_line "QG1 — Cluster Readiness" "${QG1_RESULT}"
    gate_line "QG2 — Platform Readiness" "${QG2_RESULT}" "${qg2_note}"
    gate_line "QG4 — Deployment Health" "${QG4_RESULT}" "${qg4_note}"
    gate_line "QG7 — Behavioral Evals" "${QG7_RESULT}" "${qg7_note}"
  }
)"

agent_symbol() {
  case "$1" in
    success) echo "✅" ;;
    failure) echo "❌" ;;
    *) echo "⏭️" ;;
  esac
}

agent_note() {
  case "$1" in
    blocked_fail) echo "blocked: failed QG4" ;;
    blocked_skip) echo "QG4 skipped" ;;
    excluded) echo "excluded from QG7" ;;
    not_run) echo "QG7 did not run" ;;
    *) echo "" ;;
  esac
}

shopt -s nullglob
qg4_files=("${QG4_OUTCOMES_DIR}"/qg4-outcome-*/result.json)

agent_table=""
if [[ ${#qg4_files[@]} -gt 0 ]]; then
  qg7_files=("${QG7_OUTCOMES_DIR}"/qg7-outcome-*/result.json)
  if [[ ${#qg7_files[@]} -gt 0 ]]; then
    qg7_json="$(jq -s '[.[] | {(.name): .status}] | add // {}' "${qg7_files[@]}")"
  else
    qg7_json='{}'
  fi

  rows="$(
    jq -s --argjson excluded "${QG7_EXCLUDED}" --argjson qg7 "${qg7_json}" '
      map(
        . as $a
        | ($a.dir | ltrimstr("agents/")) as $qg7_id
        | ($qg7_id | IN($excluded[])) as $is_excluded
        | {
            name: $a.name,
            qg4: $a.status,
            qg7: (
              if $a.status == "skipped" then "blocked_skip"
              elif $a.status != "success" then "blocked_fail"
              elif $is_excluded then "excluded"
              elif ($qg7 | has($a.name)) then $qg7[$a.name]
              else "not_run"
              end
            )
          }
      )
      | sort_by(.name)
    ' "${qg4_files[@]}"
  )"

  table_body="$(
    while IFS=$'\t' read -r name qg4_status qg7_status; do
      qg4_sym="$(agent_symbol "${qg4_status}")"
      qg7_sym="$(agent_symbol "${qg7_status}")"
      note="$(agent_note "${qg7_status}")"
      printf '%-34s %-2s   %-2s   %s\n' "${name}" "${qg4_sym}" "${qg7_sym}" "${note}"
    done < <(jq -r '.[] | [.name, .qg4, .qg7] | @tsv' <<<"${rows}")
  )"

  agent_table="$(
    # shellcheck disable=SC2016 # backticks here are a literal Slack code-fence, not command substitution
    printf '*Agent Results*\n```\n%-34s %-4s %-4s\n%s\n```' \
      "agent" "qg4" "qg7" "${table_body}"
  )"
fi

if [[ -n "${agent_table}" ]]; then
  printf '%s\n\n%s\n' "${gate_summary}" "${agent_table}"
else
  printf '%s\n' "${gate_summary}"
fi
