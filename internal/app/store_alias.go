package app

import st "github.com/dims/oci2gdsd/internal/store"

type Lease = st.Lease
type ModelRecord = st.ModelRecord
type StateStore = st.StateStore

func NewStateStore(path string) *StateStore {
	return st.NewStateStore(path)
}
