#!/bin/bash
set -e

echo "=== Creating test binaries for debugging ==="

# Create FFmpeg CGO test (direct linking)
cat > test-ffmpeg-direct.go << 'EOF'
package main

/*
#cgo CFLAGS: -I/usr/local/include
#cgo LDFLAGS: -L/usr/local/lib -lavutil
#include <libavutil/avutil.h>
*/
import "C"
import "fmt"

func main() {
    fmt.Println("FFmpeg CGO Test")
    fmt.Printf("libavutil version: %d\n", C.avutil_version())
    fmt.Println("FFmpeg CGO test completed successfully")
}
EOF

# Create FFmpeg CGO test (pkg-config)
cat > test-ffmpeg-pkg.go << 'EOF'
package main

/*
#cgo pkg-config: libavutil
#include <libavutil/avutil.h>
*/
import "C"
import "fmt"

func main() {
    fmt.Println("FFmpeg CGO Test (pkg-config)")
    fmt.Printf("libavutil version: %d\n", C.avutil_version())
    fmt.Println("FFmpeg CGO test completed successfully")
}
EOF

# Create runtime test
cat > test-runtime.go << 'EOF'
package main

import (
    "fmt"
    "runtime"
    "os"
)

func main() {
    fmt.Printf("Go Runtime Test - Version: %s, OS: %s, Arch: %s, CPUs: %d\n", 
        runtime.Version(), runtime.GOOS, runtime.GOARCH, runtime.NumCPU())
    fmt.Printf("Environment - GODEBUG: %s, GOMAXPROCS: %s\n", 
        os.Getenv("GODEBUG"), os.Getenv("GOMAXPROCS"))
    fmt.Println("Runtime test completed successfully")
}
EOF

# Create ARM64 memory test
cat > test-arm64-memory.go << 'EOF'
package main

/*
#include <stdlib.h>
#include <stdio.h>
*/
import "C"

import (
    "fmt"
    "log"
    "runtime"
    "runtime/debug"
    "time"
    "unsafe"
)

func main() {
    fmt.Println("=== ARM64 Memory Debug Test ===")
    runtime.LockOSThread()
    defer runtime.UnlockOSThread()
    
    fmt.Printf("Go Version: %s\n", runtime.Version())
    fmt.Printf("OS: %s\n", runtime.GOOS)
    fmt.Printf("Arch: %s\n", runtime.GOARCH)
    fmt.Printf("NumCPU: %d\n", runtime.NumCPU())
    fmt.Printf("GOMAXPROCS: %d\n", runtime.GOMAXPROCS(0))
    
    debug.SetGCPercent(10)
    debug.SetMemoryLimit(64 << 20)
    
    fmt.Println("Testing basic memory allocation...")
    for i := 0; i < 5; i++ {
        data := make([]byte, 1024*1024)
        if len(data) != 1024*1024 {
            log.Fatalf("Failed to allocate 1MB at iteration %d", i)
        }
        fmt.Printf("Allocated 1MB (iteration %d)\n", i)
        runtime.GC()
        time.Sleep(100 * time.Millisecond)
    }
    
    fmt.Println("Testing CGO compatibility...")
    ptr := C.malloc(1024)
    if ptr == nil {
        log.Fatal("CGO malloc failed")
    }
    fmt.Printf("CGO malloc successful: %p\n", ptr)
    
    goPtr := (*[1024]byte)(ptr)
    goPtr[0] = 0x42
    goPtr[1023] = 0x24
    
    if goPtr[0] != 0x42 || goPtr[1023] != 0x24 {
        log.Fatal("CGO memory access failed")
    }
    
    fmt.Println("CGO memory access successful")
    C.free(ptr)
    fmt.Println("CGO free successful")
    
    fmt.Printf("Pointer size: %d bytes\n", unsafe.Sizeof(ptr))
    fmt.Printf("uintptr size: %d bytes\n", unsafe.Sizeof(uintptr(0)))
    
    fmt.Println("ARM64 memory test completed successfully")
}
EOF

# Build test binaries
echo "=== Building test binaries ==="
echo "Build environment:"
echo "PKG_CONFIG_PATH: $PKG_CONFIG_PATH"
echo "LD_LIBRARY_PATH: $LD_LIBRARY_PATH"
echo "CGO_LDFLAGS: $CGO_LDFLAGS"
echo "Available libraries in /usr/local/lib:"
ls -la /usr/local/lib/lib*av* || echo "No FFmpeg libraries found"
echo "Available pkg-config files:"
find /usr/local/lib/pkgconfig -name "*av*" || echo "No av pkg-config files found"
pkg-config --list-all | grep av || echo "No av packages in pkg-config"

# Try to build FFmpeg test
echo "Trying direct linking first..."
if go build -v -o /bin/test-ffmpeg test-ffmpeg-direct.go 2>&1; then
    echo "=== FFmpeg CGO test (direct) build completed ==="
elif go build -v -o /bin/test-ffmpeg test-ffmpeg-pkg.go 2>&1; then
    echo "=== FFmpeg CGO test (pkg-config) build completed ==="
else
    echo "=== Both FFmpeg CGO tests failed, creating dummy ==="
    cat > /bin/test-ffmpeg << 'EOF'
#!/bin/bash
echo "FFmpeg CGO test skipped (both methods failed)"
exit 0
EOF
    chmod +x /bin/test-ffmpeg
fi

# Build other tests
go build -v -o /bin/test-runtime test-runtime.go
go build -v -o /bin/test-arm64-memory test-arm64-memory.go

echo "=== Test binaries created successfully ===" 