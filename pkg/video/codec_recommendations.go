package video

import (
	"fmt"
	"strings"
)

// CodecType represents the type of codec
type CodecType int

const (
	CodecTypeMPEG1 CodecType = iota
	CodecTypeMPEG2
	CodecTypeMPEG4
	CodecTypeH264
	CodecTypeHEVC
	CodecTypeVP8
	CodecTypeVP9
	CodecTypeAV1
	CodecTypeUnknown
)

// CodecRecommendation contains codec analysis and recommendations
type CodecRecommendation struct {
	CurrentCodec        string
	CurrentType         CodecType
	IsHardwareAccel     bool
	IsOptimal           bool
	RecommendedCodec    string
	RecommendedType     CodecType
	Reason              string
	ExpectedImprovement string
	ReencodingCommand   string
}

// DetectCodecType determines the codec type from name
func DetectCodecType(codecName string) CodecType {
	lower := strings.ToLower(codecName)

	switch {
	case strings.Contains(lower, "h264"), strings.Contains(lower, "avc"):
		return CodecTypeH264
	case strings.Contains(lower, "h265"), strings.Contains(lower, "hevc"):
		return CodecTypeHEVC
	case strings.Contains(lower, "mpeg1"):
		return CodecTypeMPEG1
	case strings.Contains(lower, "mpeg2"):
		return CodecTypeMPEG2
	case strings.Contains(lower, "mpeg4"):
		return CodecTypeMPEG4
	case strings.Contains(lower, "vp8"):
		return CodecTypeVP8
	case strings.Contains(lower, "vp9"):
		return CodecTypeVP9
	case strings.Contains(lower, "av1"):
		return CodecTypeAV1
	default:
		return CodecTypeUnknown
	}
}

// String returns human-readable codec type name
func (c CodecType) String() string {
	switch c {
	case CodecTypeMPEG1:
		return "MPEG-1"
	case CodecTypeMPEG2:
		return "MPEG-2"
	case CodecTypeMPEG4:
		return "MPEG-4"
	case CodecTypeH264:
		return "H.264/AVC"
	case CodecTypeHEVC:
		return "H.265/HEVC"
	case CodecTypeVP8:
		return "VP8"
	case CodecTypeVP9:
		return "VP9"
	case CodecTypeAV1:
		return "AV1"
	default:
		return "Unknown"
	}
}

// AnalyzeCodec provides recommendations for codec optimization
func AnalyzeCodec(info CodecInfo) CodecRecommendation {
	currentType := DetectCodecType(info.Name)

	rec := CodecRecommendation{
		CurrentCodec:    info.Name,
		CurrentType:     currentType,
		IsHardwareAccel: info.IsHardwareAccel,
	}

	// Determine if current setup is optimal for Radxa Zero
	switch currentType {
	case CodecTypeH264:
		if info.IsHardwareAccel {
			rec.IsOptimal = true
			rec.Reason = "H.264 with hardware acceleration is optimal for Radxa Zero (Mali-G31 + Rockchip VPU)"
			rec.RecommendedCodec = info.Name
			rec.RecommendedType = CodecTypeH264
		} else {
			rec.IsOptimal = false
			rec.Reason = "H.264 software decoding detected. Hardware decoder available on Radxa Zero"
			rec.RecommendedCodec = "h264_rkmpp"
			rec.RecommendedType = CodecTypeH264
			rec.ExpectedImprovement = "60-80% faster decode (hardware vs software)"
			rec.ReencodingCommand = generateReencodingCommand(info, "h264", "baseline")
		}

	case CodecTypeMPEG1, CodecTypeMPEG2:
		rec.IsOptimal = false
		rec.Reason = "MPEG-1/2 has no hardware acceleration on Radxa Zero. CPU-intensive decode"
		rec.RecommendedCodec = "h264"
		rec.RecommendedType = CodecTypeH264
		rec.ExpectedImprovement = "50-70% faster decode (H.264 hardware vs MPEG software)"
		rec.ReencodingCommand = generateReencodingCommand(info, "h264", "baseline")

	case CodecTypeHEVC:
		if info.IsHardwareAccel {
			rec.IsOptimal = true
			rec.Reason = "HEVC with hardware acceleration provides excellent quality/bitrate"
			rec.RecommendedCodec = info.Name
			rec.RecommendedType = CodecTypeHEVC
		} else {
			rec.IsOptimal = false
			rec.Reason = "HEVC software decode is very CPU-intensive on ARM"
			rec.RecommendedCodec = "h264"
			rec.RecommendedType = CodecTypeH264
			rec.ExpectedImprovement = "H.264 has better hardware support on Radxa Zero"
			rec.ReencodingCommand = generateReencodingCommand(info, "h264", "baseline")
		}

	case CodecTypeAV1:
		rec.IsOptimal = false
		rec.Reason = "AV1 has no hardware support on Radxa Zero. Extremely CPU-intensive"
		rec.RecommendedCodec = "h264"
		rec.RecommendedType = CodecTypeH264
		rec.ExpectedImprovement = "90%+ faster decode (H.264 hardware vs AV1 software)"
		rec.ReencodingCommand = generateReencodingCommand(info, "h264", "baseline")

	default:
		rec.IsOptimal = false
		rec.Reason = "Unknown codec - recommend H.264 for best hardware support"
		rec.RecommendedCodec = "h264"
		rec.RecommendedType = CodecTypeH264
		rec.ExpectedImprovement = "Likely significant performance improvement with H.264 hardware decode"
		rec.ReencodingCommand = generateReencodingCommand(info, "h264", "baseline")
	}

	return rec
}

// generateReencodingCommand creates an ffmpeg command for re-encoding
func generateReencodingCommand(info CodecInfo, targetCodec, profile string) string {
	// Determine appropriate resolution for target
	var scaleFilter string
	if info.Height > 1080 {
		scaleFilter = "-vf scale=1920:1080 "
	} else {
		scaleFilter = ""
	}

	switch targetCodec {
	case "h264":
		return fmt.Sprintf(
			"ffmpeg -i input.mp4 -c:v libx264 -profile:v %s -preset slow -crf 23 %s-c:a copy output.mp4",
			profile, scaleFilter)

	case "hevc":
		return fmt.Sprintf(
			"ffmpeg -i input.mp4 -c:v libx265 -preset slow -crf 28 %s-c:a copy output.mp4",
			scaleFilter)

	default:
		return "# Contact support for custom encoding parameters"
	}
}

// GetOptimalCodecForRadxaZero returns the best codec recommendation
func GetOptimalCodecForRadxaZero() string {
	return `
Optimal Codec Strategy for Radxa Zero (Mali-G31 + Rockchip RK3566):

1. **Best Choice: H.264 Baseline Profile**
   - Hardware decoder: h264_rkmpp (Rockchip MPP)
   - Excellent performance: 1080p @ 60fps capable
   - Best compatibility and efficiency
   - Recommended for all content

2. **Alternative: H.264 Main Profile**
   - Same hardware support
   - Better compression than baseline
   - Slightly more CPU overhead (still fast)

3. **High Quality: HEVC/H.265**
   - Hardware support available (hevc_rkmpp)
   - Better compression than H.264
   - Use for 4K content downscaling to 1080p

4. **Avoid:**
   - MPEG-1/MPEG-2: No hardware support, slow
   - VP8/VP9: Limited/no hardware support
   - AV1: No hardware support, very slow

Example Re-encoding Commands:
--------------------------

# Convert MPEG-1 to H.264 (1080p):
ffmpeg -i input.mpg \
  -c:v libx264 \
  -profile:v baseline \
  -preset slow \
  -crf 23 \
  -vf scale=1920:1080 \
  -c:a copy \
  output.mp4

# Convert to H.264 Main profile (better quality):
ffmpeg -i input.mpg \
  -c:v libx264 \
  -profile:v main \
  -preset slow \
  -crf 20 \
  -vf scale=1920:1080 \
  -c:a copy \
  output.mp4

# Convert 4K to 1080p HEVC:
ffmpeg -i input_4k.mp4 \
  -c:v libx265 \
  -preset slow \
  -crf 28 \
  -vf scale=1920:1080 \
  -c:a copy \
  output.mp4

Notes:
------
- CRF 20-23: High quality (larger files)
- CRF 25-28: Good quality (smaller files)
- preset slow: Best compression (slow encoding, fast playback)
- baseline profile: Maximum compatibility
- main profile: Better compression, still widely supported
`
}
