# Art Frame Test Scripts

This directory contains various test scripts for the Art Frame application.

## Scripts Overview

### `test-gpu-access.sh`

**Purpose**: Tests GPU access and display configuration for balenaOS deployment.
**Usage**: Run from project root

```bash
./tests/test-gpu-access.sh
```

**What it does**:

- Rebuilds container with GPU fixes
- Tests GPU device accessibility
- Checks user group permissions
- Verifies V3D GPU access
- Monitors for display-related errors

### `test-display.sh`

**Purpose**: Quick rebuild and test for display issues.
**Usage**: Run from project root

```bash
./tests/test-display.sh
```

**What it does**:

- Rebuilds container with display configuration
- Tests decoder availability
- Provides monitoring commands
- Gives troubleshooting guidance

### `test-decoders.sh`

**Purpose**: Interactive decoder testing with various configurations.
**Usage**: Run from project root

```bash
./tests/test-decoders.sh
```

**What it does**:

- Interactive menu for decoder testing
- Tests different decoder configurations
- Provides detailed decoder debugging
- Shows codec ID mappings

### `check-decoders.sh`

**Purpose**: Comprehensive decoder availability check.
**Usage**: Run inside container

```bash
# Inside container
/usr/local/bin/tests/check-decoders.sh

# Or via docker-compose
docker-compose exec flow-frame tests/check-decoders.sh
```

**What it does**:

- Tests all available video decoders
- Checks for hardware acceleration support
- Provides system information
- Gives decoder recommendations

## Running Tests

### From Host (Development)

```bash
# GPU access test
./tests/test-gpu-access.sh

# Display test
./tests/test-display.sh

# Decoder test (interactive)
./tests/test-decoders.sh
```

### Inside Container

```bash
# Check decoder availability
docker-compose exec flow-frame tests/check-decoders.sh

# Interactive bash session
docker-compose exec flow-frame /bin/bash
# Then run any test script from /usr/local/bin/tests/
```

## Test Environment

All test scripts are designed to work with:

- Docker Compose (local development)
- BalenaOS (production deployment)
- Raspberry Pi 5 hardware
- ARM64 architecture

## Troubleshooting

If tests fail:

1. Check container is running: `docker-compose ps`
2. Check logs: `docker-compose logs -f`
3. Verify GPU devices: `ls -la /dev/dri/`
4. Check user permissions: `groups`

## Adding New Tests

When adding new test scripts:

1. Add them to this directory
2. Make them executable: `chmod +x new-test.sh`
3. Update this README
4. Ensure they work in both development and production environments
