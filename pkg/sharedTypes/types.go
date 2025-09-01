package sharedTypes

type Collection struct {
	Id          string `json:"id"`
	Title       string `json:"title"`
	Description string `json:"description,omitempty"`
	Bucket      string `json:"bucket"`
	Folder      string `json:"folder"`
	BounceLoop  bool   `json:"bounceLoop,omitempty"`
}
