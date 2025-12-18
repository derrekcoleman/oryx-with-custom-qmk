#!/bin/bash
# Apply custom QMK modifications to Oryx-generated files
# This script is designed to be idempotent and fail-fast with validation

set -e  # Exit immediately on error

KEYMAP_DIR="eZrPW"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}✓${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }

# Validation: Check file exists
validate_file() {
    if [[ ! -f "$1" ]]; then
        log_error "Required file not found: $1"
        exit 1
    fi
}

# Check if a pattern exists in file
has_pattern() {
    grep -qF "$1" "$2" 2>/dev/null
}

##############################################################################
# 1. PATCH rules.mk - Add achordion source file
##############################################################################
patch_rules_mk() {
    local file="${KEYMAP_DIR}/rules.mk"
    validate_file "$file"

    local pattern="SRC += features/achordion.c"

    if has_pattern "$pattern" "$file"; then
        log_info "rules.mk: achordion already enabled"
        return 0
    fi

    # Validate it's a proper rules.mk (should have some standard QMK flags)
    if ! grep -qE "(ENABLE|COMMAND)" "$file"; then
        log_error "rules.mk doesn't look like a QMK rules file"
        exit 1
    fi

    echo "" >> "$file"
    echo "$pattern" >> "$file"
    log_info "rules.mk: Added achordion source"
}

##############################################################################
# 2. PATCH config.h - Add achordion configuration
##############################################################################
patch_config_h() {
    local file="${KEYMAP_DIR}/config.h"
    validate_file "$file"

    local pattern="#define ACHORDION_STREAK"

    if has_pattern "ACHORDION_STREAK" "$file"; then
        log_info "config.h: ACHORDION_STREAK already defined"
        return 0
    fi

    # Validate it's a proper config.h (should have #define statements)
    if ! grep -qE "#define" "$file"; then
        log_error "config.h doesn't look like a QMK config file"
        exit 1
    fi

    echo "$pattern" >> "$file"
    log_info "config.h: Added ACHORDION_STREAK define"
}

##############################################################################
# 3. PATCH keymap.c - Integrate achordion
##############################################################################
patch_keymap_c() {
    local file="${KEYMAP_DIR}/keymap.c"
    local temp_file="${file}.tmp"
    validate_file "$file"

    # Check if already patched
    if has_pattern "process_achordion" "$file"; then
        log_info "keymap.c: Already patched with achordion"
        return 0
    fi

    # Validate expected structure exists
    if ! has_pattern 'bool process_record_user' "$file"; then
        log_error "keymap.c: process_record_user function not found"
        log_error "Oryx may have changed their code structure"
        exit 1
    fi

    log_info "keymap.c: Applying achordion patches..."

    # Create patched version
    awk '
    BEGIN {
        in_process_record = 0
        process_record_patched = 0
        added_include = 0
    }

    # Add achordion include after version.h
    /#include "version.h"/ && !added_include {
        print
        print "#include \"features/achordion.h\""
        added_include = 1
        next
    }

    # Detect start of process_record_user function
    /^bool process_record_user.*\{$/ {
        in_process_record = 1
        print  # Print the function declaration
        print "  if (!process_achordion(keycode, record)) { return false; }"
        process_record_patched = 1
        next
    }

    # Print all other lines
    { print }

    # At end of file, add custom achordion functions
    END {
        if (!process_record_patched) {
            print "ERROR: Could not patch process_record_user" > "/dev/stderr"
            exit 1
        }

        print ""
        print "void housekeeping_task_user(void) {"
        print "  achordion_task();"
        print "}"
        print ""
        print "uint16_t achordion_streak_chord_timeout("
        print "    uint16_t tap_hold_keycode, uint16_t next_keycode) {"
        print "  if (IS_QK_LAYER_TAP(tap_hold_keycode)) {"
        print "    return 0;  // Disable streak detection on layer-tap keys."
        print "  }"
        print ""
        print "  // Otherwise, tap_hold_keycode is a mod-tap key."
        print "  uint8_t mod = mod_config(QK_MOD_TAP_GET_MODS(tap_hold_keycode));"
        print "  if ((mod & (MOD_LSFT | MOD_RSFT)) != 0) {"
        print "    return 0;  // Exclude left and right shift from typing streak."
        print "  } else {"
        print "    return 400;  // Longer timeout for other mod-tap keys."
        print "  }"
        print "}"
        print ""
        print "bool achordion_streak_continue(uint16_t keycode) {"
        print "  // If mods other than shift or AltGr are held, dont continue the streak."
        print "  if (get_mods() & (MOD_MASK_CG | MOD_BIT_LALT)) return false;"
        print "  // Convert to tap keycodes."
        print "  if (IS_QK_MOD_TAP(keycode)) {"
        print "    keycode = QK_MOD_TAP_GET_TAP_KEYCODE(keycode);"
        print "  }"
        print "  if (IS_QK_LAYER_TAP(keycode)) {"
        print "    keycode = QK_LAYER_TAP_GET_TAP_KEYCODE(keycode);"
        print "  }"
        print "  // Regular letters and punctuation continue the streak."
        print "  if (keycode >= KC_A && keycode <= KC_Z) return true;"
        print "  switch (keycode) {"
        print "    case KC_DOT:"
        print "    case KC_COMMA:"
        print "    case KC_QUOTE:"
        print "    case KC_SPACE:"
        print "    case KC_EXLM:  // !"
        print "    case KC_QUES:  // ?"
        print "    case KC_AT:    // @"
        print "    case KC_DLR:   // $"
        print "      return true;"
        print "  }"
        print "  return false;  // All other keys end the streak."
        print "}"
    }
    ' "$file" > "$temp_file"

    # Validate the patched file was created successfully
    if [[ ! -s "$temp_file" ]]; then
        log_error "Failed to create patched keymap.c"
        rm -f "$temp_file"
        exit 1
    fi

    # Verify critical patterns exist in patched file
    if ! has_pattern "process_achordion" "$temp_file"; then
        log_error "Patching failed - process_achordion not found in result"
        rm -f "$temp_file"
        exit 1
    fi

    # Replace original with patched version
    mv "$temp_file" "$file"
    log_info "keymap.c: Successfully integrated achordion"
}

##############################################################################
# Main execution
##############################################################################
main() {
    echo "=========================================="
    echo "Applying custom QMK modifications"
    echo "=========================================="

    # Ensure we're in the right directory
    if [[ ! -d "$KEYMAP_DIR" ]]; then
        log_error "Keymap directory not found: $KEYMAP_DIR"
        log_error "Are you in the repository root?"
        exit 1
    fi

    # Ensure achordion source files exist
    if [[ ! -f "${KEYMAP_DIR}/features/achordion.c" ]] || [[ ! -f "${KEYMAP_DIR}/features/achordion.h" ]]; then
        log_error "Achordion source files not found in ${KEYMAP_DIR}/features/"
        exit 1
    fi

    # Apply all patches
    patch_rules_mk
    patch_config_h
    patch_keymap_c

    echo "=========================================="
    log_info "All modifications applied successfully"
    echo "=========================================="
}

main "$@"
