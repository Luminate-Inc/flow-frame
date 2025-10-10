package collections

// Card represents a collection with visual styling
type Card struct {
	Title       string
	Description string
	ColorStart  [3]uint8 // RGB start color for gradient
	ColorEnd    [3]uint8 // RGB end color for gradient
}
