#!/bin/bash

# Distribution testing script for ansible-role-jenkins
# Based on .gitlab-ci.yml matrix

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Results file
RESULTS_FILE="test_results_$(date +%Y%m%d_%H%M%S).log"
SUMMARY_FILE="test_summary_$(date +%Y%m%d_%H%M%S).md"

# Test matrix from .gitlab-ci.yml
declare -a TEST_MATRIX=(
    "amazonlinux:latest"
    "debian:latest"
    "fedora:latest"
    "enterpriselinux:latest"
    "ubuntu:latest"
    "ubuntu:jammy"
    "ubuntu:focal"
)

log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$RESULTS_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$RESULTS_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$RESULTS_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$RESULTS_FILE"
}

run_molecule_test() {
    local image="$1"
    local tag="$2"
    local test_name="${image}-${tag}"

    log "Starting test for ${test_name}..."

    # Set environment variables for molecule
    export image="$image"
    export tag="$tag"

    # Run molecule test with destroy=never
    if molecule test --destroy=never; then
        log_success "Test passed for ${test_name}"
        return 0
    else
        local exit_code=$?
        log_error "Test failed for ${test_name} (exit code: $exit_code)"
        return 1
    fi
}

collect_failure_logs() {
    local image="$1"
    local tag="$2"
    local test_name="${image}-${tag}"

    log "Collecting failure logs for ${test_name}..."

    # Find the container name
    local container_name="jenkins-${image}-${tag}"

    # Check if container exists and is running
    if docker ps -a --format "table {{.Names}}" | grep -q "^${container_name}$"; then
        log "Container ${container_name} found, collecting logs..."

        # Collect Jenkins service logs
        log "Collecting journalctl -u jenkins logs..."
        echo "=== Jenkins Service Logs for ${test_name} ===" >> "$RESULTS_FILE"
        docker exec "${container_name}" journalctl -u jenkins --no-pager >> "$RESULTS_FILE" 2>&1 || log_warning "Could not collect journalctl logs"
        echo "=== End Jenkins Service Logs ===" >> "$RESULTS_FILE"

        # Collect Jenkins process status
        log "Collecting Jenkins process status..."
        echo "=== Jenkins Process Status for ${test_name} ===" >> "$RESULTS_FILE"
        docker exec "${container_name}" ps aux | grep jenkins >> "$RESULTS_FILE" 2>&1 || log_warning "Could not collect process status"
        echo "=== End Jenkins Process Status ===" >> "$RESULTS_FILE"

        # Collect systemd service status
        log "Collecting systemd service status..."
        echo "=== Systemd Service Status for ${test_name} ===" >> "$RESULTS_FILE"
        docker exec "${container_name}" systemctl status jenkins >> "$RESULTS_FILE" 2>&1 || log_warning "Could not collect systemd status"
        echo "=== End Systemd Service Status ===" >> "$RESULTS_FILE"

    else
        log_warning "Container ${container_name} not found or not running"
    fi
}

cleanup_container() {
    local image="$1"
    local tag="$2"
    local test_name="${image}-${tag}"
    local container_name="jenkins-${image}-${tag}"

    log "Cleaning up container for ${test_name}..."

    # Stop and remove the container
    if docker ps -a --format "table {{.Names}}" | grep -q "^${container_name}$"; then
        docker stop "${container_name}" 2>/dev/null || true
        docker rm "${container_name}" 2>/dev/null || true
        log "Container ${container_name} cleaned up"
    else
        log "Container ${container_name} not found, nothing to clean up"
    fi
}

# Initialize results tracking
declare -A PASSED_TESTS
declare -A FAILED_TESTS
TOTAL_TESTS=${#TEST_MATRIX[@]}
PASSED_COUNT=0
FAILED_COUNT=0

log "Starting distribution testing for ansible-role-jenkins"
log "Testing ${TOTAL_TESTS} distributions from .gitlab-ci.yml"
log "Results will be saved to: $RESULTS_FILE"
log "Summary will be saved to: $SUMMARY_FILE"

# Test each distribution
for test_config in "${TEST_MATRIX[@]}"; do
    IFS=':' read -r image tag <<< "$test_config"

    if run_molecule_test "$image" "$tag"; then
        PASSED_TESTS["${image}-${tag}"]="PASSED"
        PASSED_COUNT=$((PASSED_COUNT + 1))
    else
        FAILED_TESTS["${image}-${tag}"]="FAILED"
        FAILED_COUNT=$((FAILED_COUNT + 1))

        # Collect failure logs
        collect_failure_logs "$image" "$tag"
    fi

    # Cleanup container after each test
    cleanup_container "$image" "$tag"

    # Brief pause between tests
    sleep 5
done

# Generate summary report
log "Generating summary report..."

cat > "$SUMMARY_FILE" << EOF
# Jenkins Role Distribution Test Results

**Test Date:** $(date)
**Total Tests:** $TOTAL_TESTS
**Passed:** $PASSED_COUNT
**Failed:** $FAILED_COUNT

## Test Results Summary

### ✅ Passed Tests ($PASSED_COUNT)
EOF

for test in "${!PASSED_TESTS[@]}"; do
    echo "- $test" >> "$SUMMARY_FILE"
done

cat >> "$SUMMARY_FILE" << EOF

### ❌ Failed Tests ($FAILED_COUNT)
EOF

for test in "${!FAILED_TESTS[@]}"; do
    echo "- $test" >> "$SUMMARY_FILE"
done

cat >> "$SUMMARY_FILE" << EOF

## Detailed Logs

See $RESULTS_FILE for detailed test logs, error messages, and Jenkins service logs.

## Analysis

EOF

if [ $FAILED_COUNT -eq 0 ]; then
    echo "🎉 All tests passed! The role is compatible with all tested distributions." >> "$SUMMARY_FILE"
else
    echo "⚠️  $FAILED_COUNT tests failed. Review the detailed logs for specific error messages and Jenkins service status." >> "$SUMMARY_FILE"
    echo "" >> "$SUMMARY_FILE"
    echo "Common issues to check:" >> "$SUMMARY_FILE"
    echo "- Jenkins service startup failures" >> "$SUMMARY_FILE"
    echo "- Java version compatibility" >> "$SUMMARY_FILE"
    echo "- Package installation issues" >> "$SUMMARY_FILE"
    echo "- Systemd service configuration" >> "$SUMMARY_FILE"
fi

log "Testing completed!"
log "Results: $PASSED_COUNT passed, $FAILED_COUNT failed"
log "Summary report: $SUMMARY_FILE"
log "Detailed logs: $RESULTS_FILE"

exit 0
