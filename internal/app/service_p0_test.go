package app

import (
	"math"
	"testing"
)

func TestSumShardSizesOverflow(t *testing.T) {
	_, err := sumShardSizes([]ModelShard{
		{Size: math.MaxInt64},
		{Size: 1},
	})
	if err == nil {
		t.Fatalf("expected overflow error")
	}
}

func TestSumShardSizesRejectsNegative(t *testing.T) {
	_, err := sumShardSizes([]ModelShard{
		{Size: -1},
	})
	if err == nil {
		t.Fatalf("expected negative size error")
	}
}
