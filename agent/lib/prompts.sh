#!/usr/bin/env bash
# =============================================================================
# Marvin — Prompt Assembly Library
# =============================================================================
# Modular prompt system: compose prompts from shared modules + task-specific
# content. Modules live in agent/prompts/modules/ and contain reusable
# personality, security rules, and output guidelines.
#
# Usage:
#   source "$(dirname "$0")/lib/prompts.sh"  (after common.sh)
#
#   # Load specific modules:
#   marvin_load_module "identity"          # → content of modules/identity.md
#   marvin_load_module "security-rules"    # → content of modules/security-rules.md
#
#   # Build a complete prompt from modules + task file:
#   prompt=$(marvin_build_prompt "enhance" identity security-rules output-rules)
#   # Result: task prompt + all module content appended
#
#   # Or load modules into a variable for manual assembly:
#   modules=$(marvin_load_modules identity security-rules)
#   FULL_PROMPT="${TASK_PROMPT}
#   ${modules}
#   ${CONTEXT}"
# =============================================================================

_MODULES_DIR="${MARVIN_DIR}/agent/prompts/modules"

# Load a single module file by name (without .md extension).
# Echoes the module content to stdout.
# Returns 1 if the module file doesn't exist.
#
# Usage: content=$(marvin_load_module "identity")
marvin_load_module() {
    local name="$1"
    local module_file="${_MODULES_DIR}/${name}.md"

    if [[ ! -f "$module_file" ]]; then
        marvin_log "WARN" "Prompt module not found: ${name} (${module_file})" >&2
        return 1
    fi

    cat "$module_file"
}

# Load multiple modules and concatenate them with blank line separators.
# Skips modules that don't exist (with a warning).
#
# Usage: modules=$(marvin_load_modules identity security-rules output-rules)
marvin_load_modules() {
    local result=""
    local first=true

    for name in "$@"; do
        local content
        content=$(marvin_load_module "$name") || continue

        if [[ "$first" == "true" ]]; then
            result="$content"
            first=false
        else
            result="${result}

${content}"
        fi
    done

    echo "$result"
}

# Build a complete prompt from a task prompt file + modules.
# The task prompt file is read from agent/prompts/<task>.md.
# Modules are appended after the task prompt content.
#
# Usage: prompt=$(marvin_build_prompt "enhance" identity security-rules)
# Result: contents of enhance.md + identity.md + security-rules.md
marvin_build_prompt() {
    local task="$1"
    shift
    local modules=("$@")

    local task_file="${MARVIN_DIR}/agent/prompts/${task}.md"
    if [[ ! -f "$task_file" ]]; then
        marvin_log "ERROR" "Task prompt not found: ${task} (${task_file})" >&2
        return 1
    fi

    local task_content
    task_content=$(cat "$task_file")

    if [[ ${#modules[@]} -eq 0 ]]; then
        echo "$task_content"
        return 0
    fi

    local module_content
    module_content=$(marvin_load_modules "${modules[@]}")

    echo "${task_content}

${module_content}"
}

# List all available modules (for debugging/inventory).
# Outputs one module name per line (without .md extension).
marvin_list_modules() {
    if [[ ! -d "$_MODULES_DIR" ]]; then
        return 0
    fi
    for f in "${_MODULES_DIR}"/*.md; do
        [[ -f "$f" ]] || continue
        basename "$f" .md
    done
}
