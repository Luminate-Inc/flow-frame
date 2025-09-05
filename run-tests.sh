#!/bin/bash
# run-tests.sh - Test runner for Art Frame test scripts

set -e

echo "=== Art Frame Test Runner ==="
echo "This script runs all available test scripts"
echo ""

# Check if tests directory exists
if [ ! -d "tests" ]; then
    echo "❌ Error: tests directory not found"
    exit 1
fi

# Make sure all test scripts are executable
echo "Making test scripts executable..."
chmod +x tests/*.sh

echo ""
echo "Available test scripts:"
echo "1. GPU Access Test (test-gpu-access.sh)"
echo "2. Display Test (test-display.sh)"
echo "3. Decoder Test (test-decoders.sh)"
echo "4. Check Decoders (check-decoders.sh) - run inside container"
echo "5. Run all applicable tests"
echo ""

read -p "Choose test to run (1-5): " choice

case $choice in
    1)
        echo "Running GPU Access Test..."
        ./tests/test-gpu-access.sh
        ;;
    2)
        echo "Running Display Test..."
        ./tests/test-display.sh
        ;;
    3)
        echo "Running Decoder Test..."
        ./tests/test-decoders.sh
        ;;
    4)
        echo "Running Check Decoders (inside container)..."
        if docker-compose ps flow-frame | grep -q "Up"; then
            docker-compose exec flow-frame tests/check-decoders.sh
        else
            echo "❌ Container not running. Start with: docker-compose up -d"
        fi
        ;;
    5)
        echo "Running all applicable tests..."
        echo ""
        echo "1/3: GPU Access Test"
        ./tests/test-gpu-access.sh
        echo ""
        echo "2/3: Display Test"
        ./tests/test-display.sh
        echo ""
        echo "3/3: Decoder Test (inside container)"
        if docker-compose ps flow-frame | grep -q "Up"; then
            docker-compose exec flow-frame tests/check-decoders.sh
        else
            echo "❌ Container not running - skipping decoder check"
        fi
        echo ""
        echo "✅ All tests completed!"
        ;;
    *)
        echo "Invalid choice"
        exit 1
        ;;
esac

echo ""
echo "Test runner completed!"
echo ""
echo "For more information about tests, see: tests/README.md" 