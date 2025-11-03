#!/bin/bash

# ============================================================================
# AGPL Compliance Helper Script
# ============================================================================
# This script adds AGPL license compliance files to a distribution directory.
# It can be sourced by any build script to ensure consistent AGPL compliance.
#
# Usage:
#   add_agpl_compliance "/path/to/distribution/root"
#
# Example:
#   source scripts/add-agpl-compliance.sh
#   add_agpl_compliance "${PORTABLE_DIR}"
# ============================================================================

add_agpl_compliance() {
    local DIST_ROOT="$1"
    
    if [ -z "${DIST_ROOT}" ]; then
        echo "Error: Distribution root directory not specified"
        return 1
    fi
    
    if [ ! -d "${DIST_ROOT}" ]; then
        echo "Error: Distribution root directory does not exist: ${DIST_ROOT}"
        return 1
    fi
    
    echo "Adding AGPL compliance files to: ${DIST_ROOT}"
    
    # Get the repository root (where COPYING file is)
    local REPO_ROOT
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    
    # Create licenses directory (in standard location, less prominent)
    local LICENSE_DIR="${DIST_ROOT}/usr/share/licenses/psstream"
    mkdir -p "${LICENSE_DIR}"
    
    # Copy the license file
    if [ -f "${REPO_ROOT}/COPYING" ]; then
        cp "${REPO_ROOT}/COPYING" "${LICENSE_DIR}/"
        echo "  ✓ Copied COPYING"
    else
        echo "  ⚠ Warning: COPYING file not found in ${REPO_ROOT}"
    fi
    
    # Generate SOURCE_CODE.txt from template with build information
    if [ -f "${REPO_ROOT}/legal/agpl-source-notice.txt" ]; then
        sed \
            -e "s|__BUILD_DATE__|$(date -u +"%Y-%m-%d %H:%M:%S UTC")|g" \
            -e "s|__GIT_COMMIT__|$(cd "${REPO_ROOT}" && git rev-parse HEAD 2>/dev/null || echo "unknown")|g" \
            -e "s|__GIT_BRANCH__|$(cd "${REPO_ROOT}" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")|g" \
            -e "s|__ARCHITECTURE__|$(uname -m)|g" \
            "${REPO_ROOT}/legal/agpl-source-notice.txt" > "${LICENSE_DIR}/SOURCE_CODE.txt"
        echo "  ✓ Generated SOURCE_CODE.txt"
    else
        echo "  ⚠ Warning: agpl-source-notice.txt template not found"
    fi
    
    echo "  ✓ AGPL compliance files added to: usr/share/licenses/psstream/"
    return 0
}

# If script is executed directly (not sourced), show usage
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "This script should be sourced, not executed directly."
    echo ""
    echo "Usage in your build script:"
    echo "  source scripts/add-agpl-compliance.sh"
    echo "  add_agpl_compliance \"/path/to/distribution/root\""
    exit 1
fi

