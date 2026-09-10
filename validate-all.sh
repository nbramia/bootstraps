#!/bin/bash
# Validates all plugins in the marketplace
set -euo pipefail

# Always run from the repository root (where this script lives)
cd "$(dirname "${BASH_SOURCE[0]}")"

ERRORS=0
WARNINGS=0
CODEX_MARKETPLACE_VALID=false

echo "=== Bootstraps Plugin Validation ==="
echo ""

# Check .claude-plugin/marketplace.json exists and is valid JSON
if [ ! -f ".claude-plugin/marketplace.json" ]; then
  echo "ERROR: .claude-plugin/marketplace.json not found"
  ERRORS=$((ERRORS + 1))
else
  if ! jq . .claude-plugin/marketplace.json > /dev/null 2>&1; then
    echo "ERROR: .claude-plugin/marketplace.json is not valid JSON"
    ERRORS=$((ERRORS + 1))
  else
    echo "OK: .claude-plugin/marketplace.json is valid JSON"
  fi
fi

echo ""

# Check .agents/plugins/marketplace.json exists and is valid JSON
if [ ! -f ".agents/plugins/marketplace.json" ]; then
  echo "ERROR: .agents/plugins/marketplace.json not found"
  ERRORS=$((ERRORS + 1))
else
  if ! jq . .agents/plugins/marketplace.json > /dev/null 2>&1; then
    echo "ERROR: .agents/plugins/marketplace.json is not valid JSON"
    ERRORS=$((ERRORS + 1))
  else
    if ! jq -e '
      type == "object" and
      (.plugins | type == "array") and
      all(.plugins[];
        type == "object" and
        (.name | type == "string" and length > 0) and
        (.source | type == "object") and
        (.source.source == "local") and
        (.source.path | type == "string" and startswith("./plugins/"))
      )
    ' .agents/plugins/marketplace.json > /dev/null 2>&1; then
      echo "ERROR: .agents/plugins/marketplace.json has an invalid marketplace shape or non-local plugin source"
      ERRORS=$((ERRORS + 1))
    else
      CODEX_MARKETPLACE_VALID=true
      echo "OK: .agents/plugins/marketplace.json is valid JSON with local plugin sources"

      while IFS= read -r codex_plugin_name; do
        if [ ! -d "plugins/$codex_plugin_name" ]; then
          echo "ERROR: Codex marketplace references missing plugin: $codex_plugin_name"
          ERRORS=$((ERRORS + 1))
        fi
      done < <(jq -r '.plugins[].name' .agents/plugins/marketplace.json)
    fi
  fi
fi

echo ""

# Validate each plugin
for plugin_dir in plugins/*/; do
  plugin_name=$(basename "$plugin_dir")
  echo "--- Plugin: $plugin_name ---"

  # Reset per-plugin variables
  name=""
  desc=""
  version=""
  codex_version=""

  # Check plugin.json
  if [ ! -f "$plugin_dir/.claude-plugin/plugin.json" ]; then
    echo "  ERROR: Missing plugin.json"
    ERRORS=$((ERRORS + 1))
  else
    if ! jq . "$plugin_dir/.claude-plugin/plugin.json" > /dev/null 2>&1; then
      echo "  ERROR: plugin.json is not valid JSON"
      ERRORS=$((ERRORS + 1))
    else
      # Check required fields
      name=$(jq -r '.name // empty' "$plugin_dir/.claude-plugin/plugin.json")
      desc=$(jq -r '.description // empty' "$plugin_dir/.claude-plugin/plugin.json")
      version=$(jq -r '.version // empty' "$plugin_dir/.claude-plugin/plugin.json")

      if [ -z "$name" ]; then
        echo "  ERROR: plugin.json missing 'name'"
        ERRORS=$((ERRORS + 1))
      fi
      if [ -z "$desc" ]; then
        echo "  ERROR: plugin.json missing 'description'"
        ERRORS=$((ERRORS + 1))
      fi
      if [ -z "$version" ]; then
        echo "  ERROR: plugin.json missing 'version'"
        ERRORS=$((ERRORS + 1))
      fi

      if [ -n "$name" ] && [ -n "$desc" ] && [ -n "$version" ]; then
        echo "  OK: plugin.json has required fields (name=$name, version=$version)"
      fi
    fi
  fi

  # Check skills
  for skill_dir in "$plugin_dir"/skills/*/; do
    [ -d "$skill_dir" ] || continue
    skill_name=$(basename "$skill_dir")
    if [ -f "$skill_dir/SKILL.md" ]; then
      if head -1 "$skill_dir/SKILL.md" | grep -q "^---$"; then
        echo "  OK: skills/$skill_name/SKILL.md has frontmatter"
      else
        echo "  WARN: skills/$skill_name/SKILL.md missing frontmatter delimiter"
        WARNINGS=$((WARNINGS + 1))
      fi

      # Check SKILL.md version sync for eponymous skill (skill name == plugin name)
      if [ "$skill_name" = "$plugin_name" ] && [ -n "$version" ]; then
        skill_version=$(sed -n '/^---$/,/^---$/p' "$skill_dir/SKILL.md" | grep 'version:' | head -1 | sed 's/.*version:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/')
        if [ -n "$skill_version" ] && [ "$skill_version" != "$version" ]; then
          echo "  ERROR: Version mismatch — plugin.json=$version, SKILL.md=$skill_version"
          ERRORS=$((ERRORS + 1))
        elif [ -n "$skill_version" ]; then
          echo "  OK: SKILL.md version in sync ($skill_version)"
        fi
      fi

      # Check line count
      lines=$(wc -l < "$skill_dir/SKILL.md")
      if [ "$lines" -gt 500 ]; then
        echo "  WARN: skills/$skill_name/SKILL.md is $lines lines (recommended: < 500)"
        WARNINGS=$((WARNINGS + 1))
      else
        echo "  OK: skills/$skill_name/SKILL.md is $lines lines"
      fi
    else
      echo "  WARN: skills/$skill_name/ exists but has no SKILL.md"
      WARNINGS=$((WARNINGS + 1))
    fi
  done

  # Check hooks.json if present
  if [ -f "$plugin_dir/hooks/hooks.json" ]; then
    if ! jq . "$plugin_dir/hooks/hooks.json" > /dev/null 2>&1; then
      echo "  ERROR: hooks/hooks.json is not valid JSON"
      ERRORS=$((ERRORS + 1))
    else
      echo "  OK: hooks/hooks.json is valid JSON"
    fi
  fi

  # implement-lifecycle distributes canonical worker skills, not harness-specific
  # agent templates. Its explicit required skill inventory must retain non-empty
  # optional OpenAI metadata with explicit invocation policy.
  if [ "$plugin_name" = "implement-lifecycle" ]; then
    lifecycle_templates=""
    if [ -d "$plugin_dir/agents" ]; then
      lifecycle_templates=$(find "$plugin_dir/agents" -mindepth 1 -print -quit)
    fi
    if [ -n "$lifecycle_templates" ]; then
      echo "  ERROR: implement-lifecycle must not distribute named agent templates"
      ERRORS=$((ERRORS + 1))
    else
      echo "  OK: No implement-lifecycle named agent templates distributed"
    fi

    lifecycle_metadata_missing=false
    lifecycle_interface_section_missing=false
    lifecycle_explicit_invocation_missing=false
    lifecycle_skills=(
      implement-code implement-address review-general review-correctness review-security
      review-architecture review-testing review-docs verify
      implement merge-pr pr-check
    )
    for lifecycle_skill in "${lifecycle_skills[@]}"; do
      lifecycle_skill_dir="$plugin_dir/skills/$lifecycle_skill"
      lifecycle_metadata="$lifecycle_skill_dir/agents/openai.yaml"
      if [ ! -d "$lifecycle_skill_dir" ]; then
        echo "  ERROR: implement-lifecycle is missing canonical skill directory: $lifecycle_skill"
        ERRORS=$((ERRORS + 1))
        lifecycle_metadata_missing=true
      elif [ ! -s "$lifecycle_metadata" ]; then
        echo "  ERROR: $lifecycle_skill is missing a non-empty agents/openai.yaml"
        ERRORS=$((ERRORS + 1))
        lifecycle_metadata_missing=true
      elif ! awk '
        /^interface:[[:space:]]*(#.*)?$/ { interface_line = NR; next }
        interface_line && /^[^[:space:]#]/ { exit !interface_content }
        interface_line && /^[[:space:]]+[^[:space:]#]/ { interface_content = 1 }
        END { exit !(interface_line && interface_content) }
      ' "$lifecycle_metadata"; then
        echo "  ERROR: $lifecycle_skill has no non-empty interface section in agents/openai.yaml"
        ERRORS=$((ERRORS + 1))
        lifecycle_interface_section_missing=true
      elif ! rg -Fq 'allow_implicit_invocation: false' "$lifecycle_metadata"; then
        echo "  ERROR: $lifecycle_skill must retain explicit-invocation policy in agents/openai.yaml"
        ERRORS=$((ERRORS + 1))
        lifecycle_explicit_invocation_missing=true
      fi
    done
    if [ "$lifecycle_metadata_missing" = false ] && [ "$lifecycle_interface_section_missing" = false ] && [ "$lifecycle_explicit_invocation_missing" = false ]; then
      echo "  OK: Every inventoried implement-lifecycle skill retains non-empty optional OpenAI metadata and explicit invocation policy"
    fi

    if rg -q 'named (subagent|worker)|preloaded (worker )?skill|reviewer agent adapter' \
      "$plugin_dir/skills/implement/SKILL.md" README.md; then
      echo "  ERROR: Lifecycle instructions still reference Claude Code named worker adapters"
      ERRORS=$((ERRORS + 1))
    else
      echo "  OK: Lifecycle instructions use generic skill-directed subagents"
    fi

    lifecycle_implement_skill="$plugin_dir/skills/implement/SKILL.md"
    lifecycle_mapping=$(awk '/^\| Phase \| Canonical skill \|$/,/^$/' "$lifecycle_implement_skill")
    lifecycle_mapping_invalid=false
    for lifecycle_worker in implement-code implement-address review-general review-correctness review-security review-architecture review-testing review-docs verify; do
      mapping_count=$(printf '%s\n' "$lifecycle_mapping" | rg -Fc "\`$lifecycle_worker\`")
      if [ "$mapping_count" -ne 1 ]; then
        echo "  ERROR: Canonical lifecycle mapping must contain $lifecycle_worker exactly once (found $mapping_count)"
        ERRORS=$((ERRORS + 1))
        lifecycle_mapping_invalid=true
      fi
    done
    mapping_rows=$(printf '%s\n' "$lifecycle_mapping" | rg -c '^\| (Implement|Address|Review (general|correctness|security|architecture|testing|docs)|Verify) \|')
    if [ "$mapping_rows" -ne 9 ]; then
      echo "  ERROR: Canonical lifecycle mapping must contain exactly nine worker rows (found $mapping_rows)"
      ERRORS=$((ERRORS + 1))
      lifecycle_mapping_invalid=true
    fi
    for adapter_syntax in \
      'Use the implement-lifecycle:<skill> plugin skill' \
      'Use $implement-lifecycle:<skill>' \
      'generic `delegate` child with `skill: <skill>`' \
      'fresh isolated child, load the mapped Agent Skill explicitly'; do
      adapter_count=$(rg -Fc "$adapter_syntax" "$lifecycle_implement_skill")
      if [ "$adapter_count" -ne 1 ]; then
        echo "  ERROR: Lifecycle adapter syntax must be centralized exactly once: $adapter_syntax (found $adapter_count)"
        ERRORS=$((ERRORS + 1))
        lifecycle_mapping_invalid=true
      fi
    done
    if [ "$lifecycle_mapping_invalid" = false ]; then
      echo "  OK: Canonical lifecycle mapping contains each worker once and adapter syntax is centralized"
    fi

    lifecycle_pi_manifest="$plugin_dir/package.json"
    if ! jq -e '
      .name == "implement-lifecycle" and
      (.version | type == "string" and length > 0) and
      (.keywords | type == "array" and index("pi-package")) and
      (.pi.skills == ["./skills"]) and
      (has("dependencies") | not) and
      (has("devDependencies") | not) and
      (has("scripts") | not)
    ' "$lifecycle_pi_manifest" > /dev/null 2>&1; then
      echo "  ERROR: implement-lifecycle package.json must be dependency-free Pi metadata that exposes ./skills"
      ERRORS=$((ERRORS + 1))
    elif [ "$version" != "$(jq -r '.version' "$lifecycle_pi_manifest")" ]; then
      echo "  ERROR: Version mismatch — plugin.json=$version, Pi package=$(jq -r '.version' "$lifecycle_pi_manifest")"
      ERRORS=$((ERRORS + 1))
    else
      echo "  OK: Pi package metadata exposes skills without runtime dependencies and version is in sync ($version)"
    fi

    lifecycle_reviewer_contract_missing=false
    for lifecycle_reviewer in review-general review-correctness review-security review-architecture review-testing review-docs; do
      if ! rg -Fq 'Do not modify the reviewed codebase.' "$plugin_dir/skills/$lifecycle_reviewer/SKILL.md" || \
        ! rg -Fq 'Do not post to GitHub.' "$plugin_dir/skills/$lifecycle_reviewer/SKILL.md"; then
        echo "  ERROR: $lifecycle_reviewer must prohibit modifying reviewed code and posting to GitHub"
        ERRORS=$((ERRORS + 1))
        lifecycle_reviewer_contract_missing=true
      fi
    done
    if [ "$lifecycle_reviewer_contract_missing" = false ]; then
      echo "  OK: Lifecycle reviewer skills prohibit modifying reviewed code and posting to GitHub"
    fi

    lifecycle_focused_contract="**Suite capability: \`focused-only\`. Run focused tests, lint, builds, and acceptance commands only. Do not execute or consume the target repository's authoritative verification command or ordered command plan. Final verification owns that evidence.**"
    lifecycle_owner_contract="**Suite capability: \`full-suite-owner\`. Verification is the sole phase authorized to execute or consume the target repository's authoritative verification command or ordered command plan, at most once for the exact PR head.**"
    lifecycle_focused_skills=(
      implement implement-code implement-address review-general review-correctness
      review-security review-architecture review-testing review-docs merge-pr pr-check
    )
    lifecycle_prohibited_runtime_pattern='((^|[^[:alnum:]_.-])(\./)?validate-all\.sh([^[:alnum:]_.-]|$)|(^|[^[:alnum:]_])(go\.mod|go\.work|mise|golangci-lint|pinned[[:space:]]+go|go[[:space:]-]+toolchain|go[[:space:]]+1\.[0-9]+)([^[:alnum:]_]|$)|(^|[^[:alnum:]_])go[[:space:]]+test([^[:alnum:]_-]|$)|(^|[^[:alnum:]_])/tmp(/|[^[:alnum:]_]|$))'
    lifecycle_suite_contract_invalid=false
    for lifecycle_skill in "${lifecycle_focused_skills[@]}"; do
      lifecycle_skill_file="$plugin_dir/skills/$lifecycle_skill/SKILL.md"
      if [ "$(rg -Fc '<!-- lifecycle-suite-capability: focused-only -->' "$lifecycle_skill_file")" -ne 1 ] || \
        [ "$(rg -Fc "$lifecycle_focused_contract" "$lifecycle_skill_file")" -ne 1 ]; then
        echo "  ERROR: $lifecycle_skill must declare focused-only exactly once with the canonical contract"
        ERRORS=$((ERRORS + 1))
        lifecycle_suite_contract_invalid=true
      fi

    done

    while IFS= read -r lifecycle_prohibited_reference; do
      echo "  ERROR: Distributed lifecycle skill contains a source-repository or language-specific runtime assumption: $lifecycle_prohibited_reference"
      ERRORS=$((ERRORS + 1))
      lifecycle_suite_contract_invalid=true
    done < <(rg -i -N "$lifecycle_prohibited_runtime_pattern" "$plugin_dir/skills"/*/SKILL.md || true)

    lifecycle_prohibited_positive_fixtures=(
      'Run go test ./...'
      'Run go test.'
      'Run go test,'
      'Run `go test`.'
      'Use the Go toolchain selected by this repository'
      'golangci-lint run'
      'Create a go.work file'
    )
    lifecycle_prohibited_negative_fixtures=(
      'Run the target repository authoritative command'
      'Use its pinned runtime, compiler, package manager, or toolchain'
      'Document ongoing testing work'
      'Reference go.workshop as an ordinary dotted name'
      'Discuss golangci-linting without naming a command'
      'Describe go test-driven examples'
      'Describe a go test-related workflow'
      'Use a system-provided temporary directory'
    )
    for lifecycle_fixture in "${lifecycle_prohibited_positive_fixtures[@]}"; do
      if ! printf '%s\n' "$lifecycle_fixture" | rg -iq "$lifecycle_prohibited_runtime_pattern"; then
        echo "  ERROR: Prohibited-assumption classifier missed positive fixture: $lifecycle_fixture"
        ERRORS=$((ERRORS + 1))
        lifecycle_suite_contract_invalid=true
      fi
    done
    for lifecycle_fixture in "${lifecycle_prohibited_negative_fixtures[@]}"; do
      if printf '%s\n' "$lifecycle_fixture" | rg -iq "$lifecycle_prohibited_runtime_pattern"; then
        echo "  ERROR: Prohibited-assumption classifier rejected negative fixture: $lifecycle_fixture"
        ERRORS=$((ERRORS + 1))
        lifecycle_suite_contract_invalid=true
      fi
    done

    lifecycle_capability_allows_command() {
      local capability="$1"
      local candidate_plan="$2"
      local authoritative_plan="$3"
      if [ "$capability" = full-suite-owner ]; then
        return 0
      fi
      ! jq -e -n --argjson candidate "$candidate_plan" --argjson authoritative "$authoritative_plan" \
        '$candidate == $authoritative' > /dev/null 2>&1
    }
    lifecycle_capability_fixtures=(
      'focused-authoritative-plan|focused-only|["npm run lint","npm test"]|["npm run lint","npm test"]|reject'
      'focused-equivalent-json-plan|focused-only|["npm run lint", "npm test"]|["npm run lint","npm test"]|reject'
      'focused-nonauthoritative-command|focused-only|["npm run lint -- --changed"]|["npm run lint","npm test"]|accept'
      'owner-authoritative-plan|full-suite-owner|["npm run lint","npm test"]|["npm run lint","npm test"]|accept'
    )
    for lifecycle_fixture in "${lifecycle_capability_fixtures[@]}"; do
      IFS='|' read -r lifecycle_fixture_name lifecycle_capability lifecycle_candidate_plan lifecycle_authoritative_plan lifecycle_expected_outcome <<< "$lifecycle_fixture"
      lifecycle_actual_outcome='reject'
      if lifecycle_capability_allows_command "$lifecycle_capability" "$lifecycle_candidate_plan" "$lifecycle_authoritative_plan"; then
        lifecycle_actual_outcome='accept'
      fi
      if [ "$lifecycle_actual_outcome" != "$lifecycle_expected_outcome" ]; then
        echo "  ERROR: Suite capability fixture $lifecycle_fixture_name expected $lifecycle_expected_outcome, got $lifecycle_actual_outcome"
        ERRORS=$((ERRORS + 1))
        lifecycle_suite_contract_invalid=true
      fi
    done

    lifecycle_evidence_is_mergeable() {
      local expected_sha="$1"
      local expected_plan_json="$2"
      local change_scope="$3"
      local serialized_record="$4"
      jq -e --arg expected_sha "$expected_sha" --argjson expected_plan "$expected_plan_json" --arg change_scope "$change_scope" '
        . as $record |
        $record["verification-record"] == "v1" and
        $record["verification-head"] == $expected_sha and
        if $change_scope == "documentation-only" then
          $record["suite-result"] == "not-required" and
          $record["suite-command"] == null and
          $record["suite-executions"] == 0 and
          $record["suite-exit-status"] == null and
          $record["suite-command-results"] == [] and
          $record["suite-evidence"] == {}
        else
          ((($expected_plan | type) == "string" and ($expected_plan | test("\\S"))) or
            (($expected_plan | type) == "array" and ($expected_plan | length) > 0 and
              all($expected_plan[]; type == "string" and test("\\S")))) and
          (if ($expected_plan | type) == "array" then $expected_plan else [$expected_plan] end) as $expected_commands |
          $record["suite-result"] == "pass" and
          $record["suite-command"] == $expected_plan and
          $record["suite-executions"] == 1 and
          $record["suite-exit-status"] == 0 and
          ($record["suite-command-results"] | type == "array") and
          ($record["suite-command-results"] | length) == ($expected_commands | length) and
          ($record["suite-evidence"] | type == "object") and
          all(range(0; $expected_commands | length); . as $index |
            ($record["suite-command-results"][$index]["evidence-pointer"] == "#/suite-evidence/command-\($index + 1)") and
            $record["suite-command-results"][$index]["command"] == $expected_commands[$index] and
            $record["suite-command-results"][$index]["result"] == "pass" and
            $record["suite-command-results"][$index]["exit-status"] == 0 and
            $record["suite-evidence"]["command-\($index + 1)"]["command"] == $expected_commands[$index] and
            ($record["suite-evidence"]["command-\($index + 1)"]["output"] | type == "string" and length > 0)
          )
        end
      ' <<< "$serialized_record" > /dev/null 2>&1
    }

    lifecycle_expected_sha='0123456789abcdef0123456789abcdef01234567'
    lifecycle_evidence_fixtures=(
      'exact|["npm run lint","npm test"]|executable|accept|{"verification-record":"v1","verification-head":"0123456789abcdef0123456789abcdef01234567","suite-result":"pass","suite-command":["npm run lint","npm test"],"suite-executions":1,"suite-exit-status":0,"suite-command-results":[{"command":"npm run lint","result":"pass","exit-status":0,"evidence-pointer":"#/suite-evidence/command-1"},{"command":"npm test","result":"pass","exit-status":0,"evidence-pointer":"#/suite-evidence/command-2"}],"suite-evidence":{"command-1":{"command":"npm run lint","output":"lint passed"},"command-2":{"command":"npm test","output":"tests passed"}}}'
      'equivalent-array-json|["npm run lint", "npm test"]|accept|{"verification-record":"v1","verification-head":"0123456789abcdef0123456789abcdef01234567","suite-result":"pass","suite-command":["npm run lint","npm test"],"suite-executions":1,"suite-exit-status":0,"suite-command-results":[{"command":"npm run lint","result":"pass","exit-status":0,"evidence-pointer":"#/suite-evidence/command-1"},{"command":"npm test","result":"pass","exit-status":0,"evidence-pointer":"#/suite-evidence/command-2"}],"suite-evidence":{"command-1":{"command":"npm run lint","output":"lint passed"},"command-2":{"command":"npm test","output":"tests passed"}}}'
      'scalar-command|"npm test"|accept|{"verification-record":"v1","verification-head":"0123456789abcdef0123456789abcdef01234567","suite-result":"pass","suite-command":"npm test","suite-executions":1,"suite-exit-status":0,"suite-command-results":[{"command":"npm test","result":"pass","exit-status":0,"evidence-pointer":"#/suite-evidence/command-1"}],"suite-evidence":{"command-1":{"command":"npm test","output":"tests passed"}}}'
      'null-plan|null|reject|{"verification-record":"v1","verification-head":"0123456789abcdef0123456789abcdef01234567","suite-result":"pass","suite-command":null,"suite-executions":1,"suite-exit-status":0,"suite-command-results":[{"command":null,"result":"pass","exit-status":0,"evidence-pointer":"#/suite-evidence/command-1"}],"suite-evidence":{"command-1":{"command":null,"output":"invalid plan"}}}'
      'empty-scalar|""|reject|{"verification-record":"v1","verification-head":"0123456789abcdef0123456789abcdef01234567","suite-result":"pass","suite-command":"","suite-executions":1,"suite-exit-status":0,"suite-command-results":[{"command":"","result":"pass","exit-status":0,"evidence-pointer":"#/suite-evidence/command-1"}],"suite-evidence":{"command-1":{"command":"","output":"invalid plan"}}}'
      'whitespace-scalar|"   "|reject|{"verification-record":"v1","verification-head":"0123456789abcdef0123456789abcdef01234567","suite-result":"pass","suite-command":"   ","suite-executions":1,"suite-exit-status":0,"suite-command-results":[{"command":"   ","result":"pass","exit-status":0,"evidence-pointer":"#/suite-evidence/command-1"}],"suite-evidence":{"command-1":{"command":"   ","output":"invalid plan"}}}'
      'empty-array|[]|reject|{"verification-record":"v1","verification-head":"0123456789abcdef0123456789abcdef01234567","suite-result":"pass","suite-command":[],"suite-executions":1,"suite-exit-status":0,"suite-command-results":[],"suite-evidence":{}}'
      'empty-array-element|["npm test",""]|reject|{"verification-record":"v1","verification-head":"0123456789abcdef0123456789abcdef01234567","suite-result":"pass","suite-command":["npm test",""],"suite-executions":1,"suite-exit-status":0,"suite-command-results":[{"command":"npm test","result":"pass","exit-status":0,"evidence-pointer":"#/suite-evidence/command-1"},{"command":"","result":"pass","exit-status":0,"evidence-pointer":"#/suite-evidence/command-2"}],"suite-evidence":{"command-1":{"command":"npm test","output":"tests passed"},"command-2":{"command":"","output":"invalid plan"}}}'
      'whitespace-array-element|["npm test","   "]|reject|{"verification-record":"v1","verification-head":"0123456789abcdef0123456789abcdef01234567","suite-result":"pass","suite-command":["npm test","   "],"suite-executions":1,"suite-exit-status":0,"suite-command-results":[{"command":"npm test","result":"pass","exit-status":0,"evidence-pointer":"#/suite-evidence/command-1"},{"command":"   ","result":"pass","exit-status":0,"evidence-pointer":"#/suite-evidence/command-2"}],"suite-evidence":{"command-1":{"command":"npm test","output":"tests passed"},"command-2":{"command":"   ","output":"invalid plan"}}}'
      'nonstring-array-element|["npm test",1]|reject|{"verification-record":"v1","verification-head":"0123456789abcdef0123456789abcdef01234567","suite-result":"pass","suite-command":["npm test",1],"suite-executions":1,"suite-exit-status":0,"suite-command-results":[{"command":"npm test","result":"pass","exit-status":0,"evidence-pointer":"#/suite-evidence/command-1"},{"command":1,"result":"pass","exit-status":0,"evidence-pointer":"#/suite-evidence/command-2"}],"suite-evidence":{"command-1":{"command":"npm test","output":"tests passed"},"command-2":{"command":1,"output":"invalid plan"}}}'
      'documentation-only-with-plan|"npm test"|documentation-only|accept|{"verification-record":"v1","verification-head":"0123456789abcdef0123456789abcdef01234567","suite-result":"not-required","suite-command":null,"suite-executions":0,"suite-exit-status":null,"suite-command-results":[],"suite-evidence":{}}'
      'executable-not-required|"npm test"|executable|reject|{"verification-record":"v1","verification-head":"0123456789abcdef0123456789abcdef01234567","suite-result":"not-required","suite-command":null,"suite-executions":0,"suite-exit-status":null,"suite-command-results":[],"suite-evidence":{}}'
      'missing-contract|["npm run lint","npm test"]|reject|{"verification-record":"v1","verification-head":"0123456789abcdef0123456789abcdef01234567","suite-result":"missing-contract","suite-command":null,"suite-executions":0,"suite-exit-status":null,"suite-command-results":[],"suite-evidence":{}}'
      'reordered|["npm run lint","npm test"]|reject|{"verification-record":"v1","verification-head":"0123456789abcdef0123456789abcdef01234567","suite-result":"pass","suite-command":["npm test","npm run lint"],"suite-executions":1,"suite-exit-status":0,"suite-command-results":[{"command":"npm test","result":"pass","exit-status":0,"evidence-pointer":"#/suite-evidence/command-1"},{"command":"npm run lint","result":"pass","exit-status":0,"evidence-pointer":"#/suite-evidence/command-2"}],"suite-evidence":{"command-1":{"command":"npm test","output":"tests passed"},"command-2":{"command":"npm run lint","output":"lint passed"}}}'
      'altered-arguments|["npm run lint","npm test"]|reject|{"verification-record":"v1","verification-head":"0123456789abcdef0123456789abcdef01234567","suite-result":"pass","suite-command":["npm run lint","npm test -- --quick"],"suite-executions":1,"suite-exit-status":0,"suite-command-results":[{"command":"npm run lint","result":"pass","exit-status":0,"evidence-pointer":"#/suite-evidence/command-1"},{"command":"npm test -- --quick","result":"pass","exit-status":0,"evidence-pointer":"#/suite-evidence/command-2"}],"suite-evidence":{"command-1":{"command":"npm run lint","output":"lint passed"},"command-2":{"command":"npm test -- --quick","output":"tests passed"}}}'
      'wrong-sha|["npm run lint","npm test"]|reject|{"verification-record":"v1","verification-head":"ffffffffffffffffffffffffffffffffffffffff","suite-result":"pass","suite-command":["npm run lint","npm test"],"suite-executions":1,"suite-exit-status":0,"suite-command-results":[{"command":"npm run lint","result":"pass","exit-status":0,"evidence-pointer":"#/suite-evidence/command-1"},{"command":"npm test","result":"pass","exit-status":0,"evidence-pointer":"#/suite-evidence/command-2"}],"suite-evidence":{"command-1":{"command":"npm run lint","output":"lint passed"},"command-2":{"command":"npm test","output":"tests passed"}}}'
      'incomplete-results|["npm run lint","npm test"]|reject|{"verification-record":"v1","verification-head":"0123456789abcdef0123456789abcdef01234567","suite-result":"pass","suite-command":["npm run lint","npm test"],"suite-executions":1,"suite-exit-status":0,"suite-command-results":[{"command":"npm run lint","result":"pass","exit-status":0,"evidence-pointer":"#/suite-evidence/command-1"}],"suite-evidence":{"command-1":{"command":"npm run lint","output":"lint passed"}}}'
      'wrong-execution-count|["npm run lint","npm test"]|reject|{"verification-record":"v1","verification-head":"0123456789abcdef0123456789abcdef01234567","suite-result":"pass","suite-command":["npm run lint","npm test"],"suite-executions":2,"suite-exit-status":0,"suite-command-results":[{"command":"npm run lint","result":"pass","exit-status":0,"evidence-pointer":"#/suite-evidence/command-1"},{"command":"npm test","result":"pass","exit-status":0,"evidence-pointer":"#/suite-evidence/command-2"}],"suite-evidence":{"command-1":{"command":"npm run lint","output":"lint passed"},"command-2":{"command":"npm test","output":"tests passed"}}}'
      'wrong-status|["npm run lint","npm test"]|reject|{"verification-record":"v1","verification-head":"0123456789abcdef0123456789abcdef01234567","suite-result":"fail","suite-command":["npm run lint","npm test"],"suite-executions":1,"suite-exit-status":1,"suite-command-results":[{"command":"npm run lint","result":"pass","exit-status":0,"evidence-pointer":"#/suite-evidence/command-1"},{"command":"npm test","result":"fail","exit-status":1,"evidence-pointer":"#/suite-evidence/command-2"}],"suite-evidence":{"command-1":{"command":"npm run lint","output":"lint passed"},"command-2":{"command":"npm test","output":"tests failed"}}}'
      'dangling-evidence|["npm run lint","npm test"]|reject|{"verification-record":"v1","verification-head":"0123456789abcdef0123456789abcdef01234567","suite-result":"pass","suite-command":["npm run lint","npm test"],"suite-executions":1,"suite-exit-status":0,"suite-command-results":[{"command":"npm run lint","result":"pass","exit-status":0,"evidence-pointer":"#/suite-evidence/command-1"},{"command":"npm test","result":"pass","exit-status":0,"evidence-pointer":"#/suite-evidence/command-2"}],"suite-evidence":{"command-1":{"command":"npm run lint","output":"lint passed"}}}'
      'mismatched-evidence|["npm run lint","npm test"]|reject|{"verification-record":"v1","verification-head":"0123456789abcdef0123456789abcdef01234567","suite-result":"pass","suite-command":["npm run lint","npm test"],"suite-executions":1,"suite-exit-status":0,"suite-command-results":[{"command":"npm run lint","result":"pass","exit-status":0,"evidence-pointer":"#/suite-evidence/command-1"},{"command":"npm test","result":"pass","exit-status":0,"evidence-pointer":"#/suite-evidence/command-2"}],"suite-evidence":{"command-1":{"command":"npm run lint","output":"lint passed"},"command-2":{"command":"npm test -- --quick","output":"quick tests passed"}}}'
    )
    for lifecycle_fixture in "${lifecycle_evidence_fixtures[@]}"; do
      IFS='|' read -r lifecycle_fixture_name lifecycle_fixture_plan lifecycle_fixture_field_3 lifecycle_fixture_field_4 lifecycle_fixture_field_5 <<< "$lifecycle_fixture"
      lifecycle_change_scope='executable'
      lifecycle_expected_outcome="$lifecycle_fixture_field_3"
      lifecycle_serialized_record="$lifecycle_fixture_field_4"
      if [ "$lifecycle_fixture_field_3" = executable ] || [ "$lifecycle_fixture_field_3" = documentation-only ]; then
        lifecycle_change_scope="$lifecycle_fixture_field_3"
        lifecycle_expected_outcome="$lifecycle_fixture_field_4"
        lifecycle_serialized_record="$lifecycle_fixture_field_5"
      fi
      lifecycle_actual_outcome='reject'
      if lifecycle_evidence_is_mergeable "$lifecycle_expected_sha" "$lifecycle_fixture_plan" "$lifecycle_change_scope" "$lifecycle_serialized_record"; then
        lifecycle_actual_outcome='accept'
      fi
      if [ "$lifecycle_actual_outcome" != "$lifecycle_expected_outcome" ]; then
        echo "  ERROR: Serialized verification fixture $lifecycle_fixture_name expected $lifecycle_expected_outcome, got $lifecycle_actual_outcome"
        ERRORS=$((ERRORS + 1))
        lifecycle_suite_contract_invalid=true
      fi
    done
    lifecycle_verify_file="$plugin_dir/skills/verify/SKILL.md"
    if [ "$(rg -Fc '<!-- lifecycle-suite-capability: full-suite-owner -->' "$lifecycle_verify_file")" -ne 1 ] || \
      [ "$(rg -Fc "$lifecycle_owner_contract" "$lifecycle_verify_file")" -ne 1 ] || \
      [ "$(rg -l '<!-- lifecycle-suite-capability: full-suite-owner -->' "$plugin_dir/skills"/*/SKILL.md | wc -l | tr -d ' ')" -ne 1 ]; then
      echo "  ERROR: verify must be the sole full-suite-owner with the canonical contract"
      ERRORS=$((ERRORS + 1))
      lifecycle_suite_contract_invalid=true
    fi
    if [ "$lifecycle_suite_contract_invalid" = false ]; then
      echo "  OK: Lifecycle suite capabilities reserve the authoritative suite for verify"
    fi

    if rg -Fq '<!-- lifecycle-docs-gate:v1' "$lifecycle_implement_skill" || \
      rg -Fq 'Phase 4.5' "$lifecycle_implement_skill"; then
      echo "  ERROR: Documentation compliance must not exist as an independent gate or phase"
      ERRORS=$((ERRORS + 1))
    else
      echo "  OK: Documentation relevance is folded into the single review round, not a separate gate"
    fi

    lifecycle_recovery_graph=$(sed -n '/^<!-- lifecycle-reviewer-recovery:v1$/,/^-->$/p' "$lifecycle_implement_skill")
    lifecycle_expected_recovery_graph='<!-- lifecycle-reviewer-recovery:v1
delegated + nonempty-canonical-result -> complete
delegated + empty-or-incomplete-result -> incomplete
incomplete + transcript-recovery-complete -> complete
incomplete + transcript-recovery-incomplete -> fresh-retry
incomplete + transcript-recovery-unavailable -> fresh-retry
fresh-retry + nonempty-canonical-result -> complete
fresh-retry + empty-or-incomplete-result -> stop
complete + referee -> refereeing
-->'
    if [ "$lifecycle_recovery_graph" != "$lifecycle_expected_recovery_graph" ]; then
      echo "  ERROR: Lifecycle reviewer recovery must match the authoritative non-empty-result state graph"
      ERRORS=$((ERRORS + 1))
    elif [ "$(rg -Fc 'context: "fresh"' "$lifecycle_implement_skill")" -lt 3 ]; then
      echo '  ERROR: Pi delegation and recovery must set context: "fresh" explicitly'
      ERRORS=$((ERRORS + 1))
    else
      echo "  OK: Pi reviewers use explicit fresh context and recover incomplete canonical results"
    fi

    lifecycle_reviewer_output_invalid=false
    for lifecycle_reviewer in review-general review-correctness review-security review-architecture review-testing review-docs; do
      lifecycle_reviewer_file="$plugin_dir/skills/$lifecycle_reviewer/SKILL.md"
      for lifecycle_heading in '### Defects' '### Missing Tests' '### Status' '### Summary'; do
        if [ "$(rg -Fc "$lifecycle_heading" "$lifecycle_reviewer_file")" -ne 1 ]; then
          echo "  ERROR: $lifecycle_reviewer must return canonical heading $lifecycle_heading exactly once"
          ERRORS=$((ERRORS + 1))
          lifecycle_reviewer_output_invalid=true
        fi
      done
      if ! rg -Fq 'Return all four headings. Write `None.` beneath Defects and Missing Tests when empty.' "$lifecycle_reviewer_file"; then
        echo "  ERROR: $lifecycle_reviewer must require all canonical result headings"
        ERRORS=$((ERRORS + 1))
        lifecycle_reviewer_output_invalid=true
      fi
      for lifecycle_stale_heading in '### Action Required' '### Recommended' '### Minor'; do
        if rg -Fq "$lifecycle_stale_heading" "$lifecycle_reviewer_file"; then
          echo "  ERROR: $lifecycle_reviewer must not retain the stale severity heading $lifecycle_stale_heading"
          ERRORS=$((ERRORS + 1))
          lifecycle_reviewer_output_invalid=true
        fi
      done
    done
    if [ "$lifecycle_reviewer_output_invalid" = false ]; then
      echo "  OK: Every reviewer requires a non-empty four-heading canonical result of exactly two finding kinds plus status and summary"
    fi

    lifecycle_merge_file="$plugin_dir/skills/merge-pr/SKILL.md"
    if ! rg -Fq "Apply repository instructions first, then CI configuration, documented development commands, and build or test configuration." "$lifecycle_verify_file" || \
      ! rg -Fq 'When it declares several required commands, preserve their order as one authoritative plan; do not select a subset or reorder them.' "$lifecycle_verify_file" || \
      ! rg -Fq 'If these sources do not establish an authoritative command or plan, report the missing contract explicitly and return PARTIAL without executing a guessed substitute.' "$lifecycle_verify_file" || \
      ! rg -Fq 'any complete authoritative evidence record for the exact current head consumes its one-execution allowance' "$lifecycle_verify_file" || \
      ! rg -Fq 'require addressing to produce a new head before another authoritative execution' "$lifecycle_verify_file" || \
      ! rg -Fq 'a fresh attempt against the exact SAME candidate is permitted, but only when you give' "$lifecycle_verify_file" || \
      ! rg -Fq 'gh pr merge <pr-number> <merge-method-flag> <optional-delete-branch-flag> --match-head-commit "$VERIFIED_SHA"' "$lifecycle_merge_file" || \
      ! rg -Fq 'verification-head: <full-head-sha>' "$lifecycle_verify_file" || \
      ! rg -Fq 'verification-record: v1' "$lifecycle_verify_file" || \
      ! rg -Fq 'suite-executions: 0 | 1' "$lifecycle_verify_file" || \
      ! rg -Fq 'suite-exit-status: <integer> | n/a' "$lifecycle_verify_file" || \
      ! rg -Fq 'suite-result: pass | fail | missing-contract | not-required' "$lifecycle_verify_file" || \
      ! rg -Fq 'suite-command: <exact-command-or-ordered-JSON-command-array> | none' "$lifecycle_verify_file" || \
      ! rg -Fq 'suite-command-results:' "$lifecycle_verify_file" || \
      ! rg -Fq 'The missing-contract/PARTIAL record is canonical:' "$lifecycle_verify_file" || \
      ! rg -Fq '{"verification-record":"v1","verification-head":"<full-head-sha>","suite-result":"not-required","suite-command":null,"suite-executions":0,"suite-exit-status":null,"suite-command-results":[],"retry-reason":null,"suite-evidence":{}}' "$lifecycle_verify_file" || \
      ! rg -Fq 'retry-reason' "$lifecycle_merge_file" || \
      ! rg -Fq 'stop rather than reconstructing evidence from an inaccessible parent transcript' "$lifecycle_merge_file" || \
      ! rg -Fq 'a commit that is distinct from the PR head and does not exist before that invocation' "$lifecycle_merge_file" || \
      ! rg -Fq 'the adapter'"'"'s required check is filed against the candidate'"'"'s own SHA, never the PR head' "$lifecycle_merge_file" || \
      ! rg -Fq "The adapter's own outcome" "$lifecycle_merge_file" || \
      ! rg -Fq 'For every result, require its `#/suite-evidence/command-<N>` pointer to resolve inside the handed-off object' "$lifecycle_merge_file" || \
      ! rg -Fq 'Accept `not-required` only after independently inspecting the changed files and confirming that every change is documentation or comments only' "$lifecycle_merge_file" || \
      ! rg -Fq 'Capture the verifier'"'"'s returned handoff-artifact JSON object: the complete durable `verification-record:v1`' "$lifecycle_implement_skill" || \
      ! rg -Fq 'Payload: <pr-number> <resolved-verification-record-path>' "$lifecycle_implement_skill"; then
      echo "  ERROR: Verification evidence and merge must remain bound to the exact PR head"
      ERRORS=$((ERRORS + 1))
    else
      echo "  OK: Verification evidence is exact-head and merge uses an atomic head guard"
    fi

    lifecycle_policy_decision() {
      local checks_pass="$1"
      local approvals_required="$2"
      local approvals_met="$3"
      local billing_failure="$4"
      local repository_billing="$5"
      local user_billing="$6"
      local repository_methods="$7"
      local user_method="$8"
      local repository_retention="$9"
      local user_retention="${10}"
      local selected_method
      local delete_branch=false

      if [ "$checks_pass" != true ] || \
        { [ "$approvals_required" = true ] && [ "$approvals_met" != true ]; }; then
        printf '%s\n' '{"outcome":"reject"}'
        return
      fi
      if [ "$billing_failure" = true ]; then
        if [ "$repository_billing" = deny ] || \
          { [ "$repository_billing" = silent ] && [ "$user_billing" != allow ]; }; then
          printf '%s\n' '{"outcome":"reject"}'
          return
        fi
      fi

      selected_method="$user_method"
      if [ "$selected_method" = silent ]; then
        selected_method="${repository_methods%%,*}"
      elif [[ ",$repository_methods," != *",$selected_method,"* ]]; then
        printf '%s\n' '{"outcome":"reject"}'
        return
      fi

      if [ "$repository_retention" != silent ] && \
        [ "$user_retention" != silent ] && \
        [ "$repository_retention" != "$user_retention" ]; then
        printf '%s\n' '{"outcome":"reject"}'
        return
      fi
      if [ "$repository_retention" = delete ] || \
        { [ "$repository_retention" = silent ] && [ "$user_retention" = delete ]; }; then
        delete_branch=true
      fi
      jq -cn --arg method "$selected_method" --argjson delete_branch "$delete_branch" \
        '{outcome:"accept",merge_method:$method,delete_branch:$delete_branch}'
    }

    lifecycle_policy_fixtures=(
      'no-review-required|true|false|false|false|silent|silent|merge,squash|merge|silent|silent|{"outcome":"accept","merge_method":"merge","delete_branch":false}'
      'required-check-failure|false|false|false|false|silent|silent|merge|merge|silent|silent|{"outcome":"reject"}'
      'approval-required-missing|true|true|false|false|silent|silent|merge|merge|silent|silent|{"outcome":"reject"}'
      'approval-required-met|true|true|true|false|silent|silent|merge|merge|silent|silent|{"outcome":"accept","merge_method":"merge","delete_branch":false}'
      'billing-exception-allowed|true|false|false|true|allow|silent|squash|squash|silent|silent|{"outcome":"accept","merge_method":"squash","delete_branch":false}'
      'billing-exception-policy-denied|true|false|false|true|deny|allow|squash|squash|silent|silent|{"outcome":"reject"}'
      'repository-method-selected|true|false|false|false|silent|silent|merge,rebase|rebase|silent|silent|{"outcome":"accept","merge_method":"rebase","delete_branch":false}'
      'disallowed-method|true|false|false|false|silent|silent|merge,squash|rebase|silent|silent|{"outcome":"reject"}'
      'retained-branch|true|false|false|false|silent|silent|merge|merge|retain|silent|{"outcome":"accept","merge_method":"merge","delete_branch":false}'
      'retention-conflict|true|false|false|false|silent|silent|merge|merge|retain|delete|{"outcome":"reject"}'
    )
    for lifecycle_fixture in "${lifecycle_policy_fixtures[@]}"; do
      IFS='|' read -r lifecycle_fixture_name lifecycle_checks_pass lifecycle_approvals_required lifecycle_approvals_met lifecycle_billing_failure lifecycle_repository_billing lifecycle_user_billing lifecycle_repository_methods lifecycle_user_method lifecycle_repository_retention lifecycle_user_retention lifecycle_expected_decision <<< "$lifecycle_fixture"
      lifecycle_actual_decision=$(lifecycle_policy_decision \
        "$lifecycle_checks_pass" "$lifecycle_approvals_required" "$lifecycle_approvals_met" \
        "$lifecycle_billing_failure" "$lifecycle_repository_billing" "$lifecycle_user_billing" \
        "$lifecycle_repository_methods" "$lifecycle_user_method" \
        "$lifecycle_repository_retention" "$lifecycle_user_retention")
      if [ "$lifecycle_actual_decision" != "$lifecycle_expected_decision" ]; then
        echo "  ERROR: Merge policy fixture $lifecycle_fixture_name expected $lifecycle_expected_decision, got $lifecycle_actual_decision"
        ERRORS=$((ERRORS + 1))
        lifecycle_suite_contract_invalid=true
      fi
    done

    if ! rg -Fq 'Enforced repository constraints are binding.' "$lifecycle_merge_file" || \
      ! rg -Fq 'Explicit user direction may select only among choices those constraints permit; it cannot waive or contradict them.' "$lifecycle_merge_file" || \
      ! rg -Fq 'Apply this precedence consistently to required checks, approvals, billing exceptions, merge method, and branch retention.' "$lifecycle_merge_file" || \
      ! rg -Fq 'If the established policy does not require approval, do not invent a requirement from the base branch name.' "$lifecycle_merge_file" || \
      ! rg -Fq 'the corresponding supported GitHub CLI method flag (`--merge`, `--squash`, or `--rebase`)' "$lifecycle_merge_file" || \
      ! rg -Fq 'omit it when the branch must be retained' "$lifecycle_merge_file"; then
      echo "  ERROR: Merge readiness must defer checks, approvals, billing exceptions, merge method, and branch retention to target policy"
      ERRORS=$((ERRORS + 1))
    else
      echo "  OK: Merge policy fixtures cover approvals, billing, non-squash methods, and retained branches"
    fi

    if ! rg -Fq 'Claude Code, Codex, Pi, or generic adapter' "$lifecycle_implement_skill" || \
      ! rg -Fq '**Claude Code:** use the Task/subagent facility, explicitly load the canonical `pr-check` skill' "$lifecycle_merge_file" || \
      ! rg -Fq '**Codex:** spawn a fresh subagent, instruct it to load the canonical `pr-check` skill' "$lifecycle_merge_file" || \
      ! rg -Fq '**Pi:** use `pi-subagents` with `context: "fresh"`, explicitly select the canonical `pr-check` skill' "$lifecycle_merge_file" || \
      ! rg -Fq '**Generic:** use the client'"'"'s isolated delegation mechanism with a fresh context and explicit canonical `pr-check` skill selection' "$lifecycle_merge_file" || \
      ! rg -Fq 'If isolated dispatch, fresh context, explicit skill loading, or result capture is unavailable, fail closed' "$lifecycle_merge_file"; then
      echo "  ERROR: Phase 6 and nested pr-check must use the shared harness-neutral adapter contract"
      ERRORS=$((ERRORS + 1))
    else
      echo "  OK: Phase 6 and nested pr-check support Claude Code, Codex, Pi, and generic adapters"
    fi
  fi

  # Run self-contained hook tests (test files that contain "# autotest" marker)
  for test_file in "$plugin_dir"/hooks/test-*.sh; do
    [ -f "$test_file" ] || continue
    test_name=$(basename "$test_file")
    if head -5 "$test_file" | grep -q '# autotest'; then
      if bash "$test_file" > /dev/null 2>&1; then
        echo "  OK: $test_name passed"
      else
        echo "  ERROR: $test_name failed"
        ERRORS=$((ERRORS + 1))
      fi
    fi
  done

  # Check .claude-plugin/marketplace.json references this plugin
  if [ -f ".claude-plugin/marketplace.json" ]; then
    if jq -e ".plugins[] | select(.name == \"$plugin_name\")" .claude-plugin/marketplace.json > /dev/null 2>&1; then
      echo "  OK: Listed in .claude-plugin/marketplace.json"

      # Check version sync between plugin.json and marketplace.json
      if [ -n "$version" ]; then
        marketplace_version=$(jq -r ".plugins[] | select(.name == \"$plugin_name\") | .version" .claude-plugin/marketplace.json)
        if [ "$version" != "$marketplace_version" ]; then
          echo "  ERROR: Version mismatch — plugin.json=$version, marketplace.json=$marketplace_version"
          ERRORS=$((ERRORS + 1))
        else
          echo "  OK: Version in sync ($version)"
        fi
      fi
    else
      echo "  WARN: Not listed in .claude-plugin/marketplace.json"
      WARNINGS=$((WARNINGS + 1))
    fi
  fi

  # Validate every native Codex manifest, independent of marketplace membership.
  codex_listed=false
  if [ "$CODEX_MARKETPLACE_VALID" = true ] && jq -e --arg name "$plugin_name" '.plugins[] | select(.name == $name)' .agents/plugins/marketplace.json > /dev/null 2>&1; then
    codex_listed=true
  fi

  if [ -f "$plugin_dir/.codex-plugin/plugin.json" ]; then
    if ! jq . "$plugin_dir/.codex-plugin/plugin.json" > /dev/null 2>&1; then
      echo "  ERROR: .codex-plugin/plugin.json is not valid JSON"
      ERRORS=$((ERRORS + 1))
    else
      codex_name=$(jq -r '.name // empty' "$plugin_dir/.codex-plugin/plugin.json")
      codex_version=$(jq -r '.version // empty' "$plugin_dir/.codex-plugin/plugin.json")
      codex_desc=$(jq -r '.description // empty' "$plugin_dir/.codex-plugin/plugin.json")
      codex_author=$(jq -r '.author.name // empty' "$plugin_dir/.codex-plugin/plugin.json")
      codex_display_name=$(jq -r '.interface.displayName // empty' "$plugin_dir/.codex-plugin/plugin.json")

      if [ "$codex_name" != "$plugin_name" ]; then
        echo "  ERROR: Codex plugin name must match directory ($codex_name != $plugin_name)"
        ERRORS=$((ERRORS + 1))
      fi
      if [ -z "$codex_version" ] || [ -z "$codex_desc" ] || [ -z "$codex_author" ] || [ -z "$codex_display_name" ]; then
        echo "  ERROR: Codex plugin manifest is missing required metadata"
        ERRORS=$((ERRORS + 1))
      else
        echo "  OK: .codex-plugin/plugin.json has required metadata"
      fi
      if [ -n "$version" ] && [ "$codex_version" != "$version" ]; then
        echo "  ERROR: Version mismatch — Claude=$version, Codex=$codex_version"
        ERRORS=$((ERRORS + 1))
      elif [ -n "$version" ]; then
        echo "  OK: Claude and Codex versions in sync ($version)"
      fi
    fi
  elif [ "$codex_listed" = true ]; then
    echo "  ERROR: Listed in Codex marketplace but missing .codex-plugin/plugin.json"
    ERRORS=$((ERRORS + 1))
  fi

  # Marketplace membership and entry policy are separate from manifest validity.
  if [ "$codex_listed" = true ]; then
    expected_source="./plugins/$plugin_name"
    codex_source=$(jq -r --arg name "$plugin_name" '.plugins[] | select(.name == $name) | .source.path // empty' .agents/plugins/marketplace.json)
    codex_installation=$(jq -r --arg name "$plugin_name" '.plugins[] | select(.name == $name) | .policy.installation // empty' .agents/plugins/marketplace.json)
    codex_authentication=$(jq -r --arg name "$plugin_name" '.plugins[] | select(.name == $name) | .policy.authentication // empty' .agents/plugins/marketplace.json)
    codex_category=$(jq -r --arg name "$plugin_name" '.plugins[] | select(.name == $name) | .category // empty' .agents/plugins/marketplace.json)

    if [ "$codex_source" != "$expected_source" ]; then
      echo "  ERROR: Codex marketplace source must be $expected_source"
      ERRORS=$((ERRORS + 1))
    elif [ -z "$codex_installation" ] || [ -z "$codex_authentication" ] || [ -z "$codex_category" ]; then
      echo "  ERROR: Codex marketplace entry is missing policy or category"
      ERRORS=$((ERRORS + 1))
    else
      echo "  OK: Listed in .agents/plugins/marketplace.json"
    fi
  elif [ -f "$plugin_dir/.codex-plugin/plugin.json" ] && [ "$CODEX_MARKETPLACE_VALID" = true ]; then
    echo "  WARN: Has a Codex manifest but is not listed in the Codex marketplace"
    WARNINGS=$((WARNINGS + 1))
  fi

  echo ""
done

# Summary
echo "=== Validation Summary ==="
echo "Errors:   $ERRORS"
echo "Warnings: $WARNINGS"

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "FAILED: Fix errors above before publishing"
  exit 1
fi

if [ "$WARNINGS" -gt 0 ]; then
  echo ""
  echo "PASSED with warnings"
  exit 0
fi

echo ""
echo "PASSED"
