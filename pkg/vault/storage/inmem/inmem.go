package inmem

import (
	core "k8s.io/api/core/v1"
)

var inmenStorage = `
storage "inmem" {
}
`

type Options struct{}

func NewOptions() (*Options, error) {
	return &Options{}, nil
}

func (o *Options) Apply(pt *core.PodTemplateSpec) error {
	return nil
}

// GetStorageConfig will create storage config for inmem backend
func (o *Options) GetStorageConfig() (string, error) {
	return inmenStorage, nil
}
