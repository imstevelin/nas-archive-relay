package relay

import (
	"os"
	"path/filepath"
	"time"
)

// Capacity uses the durable upload journal, not phase progress (which resets for verification).
type Capacity struct {
	TotalBytes          int64 `json:"total_bytes"`
	FreeBytes           int64 `json:"free_bytes"`
	ReserveBytes        int64 `json:"reserve_bytes"`
	ReservedUploads     int64 `json:"reserved_upload_bytes"`
	AvailableUploads    int64 `json:"available_upload_bytes"`
	CleanupPendingBytes int64 `json:"cleanup_pending_bytes"`
	CleanupPendingJobs  int   `json:"cleanup_pending_jobs"`
}

func (s *Store) capacityLocked() (Capacity, error) {
	free, total, err := diskSpace(s.Root)
	if err != nil {
		return Capacity{}, err
	}
	c := Capacity{TotalBytes: total, FreeBytes: free, ReserveBytes: s.Config.ReserveBytes}
	for _, j := range s.Jobs {
		if (j.Stage == "completed" || j.Stage == "cancelled") && !j.RelayClean {
			c.CleanupPendingBytes += j.Bytes
			c.CleanupPendingJobs++
		}
		if j.Accepted || j.Stage == "cancelled" || j.Stage == "cancelling" || j.Stage == "completed" || j.Stage == "failed" {
			continue
		}
		offsets, err := s.uploadOffsets(j.ID)
		if err != nil {
			return Capacity{}, err
		}
		remaining := j.Bytes
		for _, n := range offsets {
			if n > 0 {
				if n >= remaining {
					remaining = 0
					break
				}
				remaining -= n
			}
		}
		c.ReservedUploads += remaining
	}
	c.AvailableUploads = c.FreeBytes - c.ReserveBytes - c.ReservedUploads
	if c.AvailableUploads < 0 {
		c.AvailableUploads = 0
	}
	return c, nil
}

// The local receipt is durable only after final NAS verification and publication.
// It allows relay space to be released even if the NAS later becomes unreachable.
func (s *Store) hasCompletionReceipt(j Job) bool {
	var receipt struct {
		ID          string    `json:"id"`
		Owner       string    `json:"owner"`
		ManifestSHA string    `json:"manifest_sha256"`
		VerifiedAt  time.Time `json:"verified_at"`
	}
	return readJSON(filepath.Join(s.Root, "receipts", j.ID+".json"), &receipt) == nil &&
		receipt.ID == j.ID && receipt.Owner == j.Owner && receipt.ManifestSHA == j.ManifestSHA && !receipt.VerifiedAt.IsZero()
}

func (a *Server) cleanupRelayFinished(id string) error {
	j, ok := a.Store.Job(id)
	if !ok {
		return os.ErrNotExist
	}
	if j.RelayClean {
		return nil
	}
	if j.Stage != "cancelled" && (j.Stage != "completed" || !a.Store.hasCompletionReceipt(j)) {
		return nil
	}
	if err := os.RemoveAll(a.Store.jobPath(id, "payload")); err != nil {
		return err
	}
	return a.Store.Update(id, func(v *Job) error { v.RelayClean = true; return nil })
}
