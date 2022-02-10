package matcher

import (
	"fmt"
	"github.com/mattfenwick/cyclonus/pkg/kube"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// SelectorTargetPod tracks the names and labels of a pod for matching to targets
type SelectorTargetPod struct {
	Namespace       string
	NamespaceLabels map[string]string
	Name            string
	Labels          map[string]string
}

type Selector struct {
	Namespaces *NameLabelsSelector
	Pods       *NameLabelsSelector
}

// GetPrimaryKey returns a deterministic combination of namespace and pod selectors
func (s *Selector) GetPrimaryKey() string {
	return fmt.Sprintf(`{"Namespaces": %s, "Pods": %s`, s.Namespaces.GetPrimaryKey(), s.Pods.GetPrimaryKey())
}

func (s *Selector) Matches(pod *SelectorTargetPod) bool {
	return s.Namespaces.Matches(pod.Namespace, pod.NamespaceLabels) && s.Pods.Matches(pod.Name, pod.Labels)
}

type NameLabelsSelector struct {
	Name   *string
	Labels *metav1.LabelSelector
}

func NewNameSelector(name string) *NameLabelsSelector {
	return &NameLabelsSelector{
		Name:   &name,
		Labels: nil,
	}
}

func NewLabelsSelector(labels metav1.LabelSelector) *NameLabelsSelector {
	return &NameLabelsSelector{
		Name:   nil,
		Labels: &labels,
	}
}

func NewNameAndLabelsSelector(name string, labels metav1.LabelSelector) *NameLabelsSelector {
	return &NameLabelsSelector{
		Name:   &name,
		Labels: &labels,
	}
}

func (s *NameLabelsSelector) GetPrimaryKey() string {
	var name, labels string
	if s.Name != nil {
		name = *s.Name
	}
	if s.Labels != nil {
		labels = kube.SerializeLabelSelector(*s.Labels)
	}
	return fmt.Sprintf(`{"Name": "%s", "Labels": %s}`, name, labels)
}

func (s *NameLabelsSelector) Matches(name string, labels map[string]string) bool {
	if s.Name != nil && *s.Name != name {
		return false
	}
	if s.Labels != nil && !kube.IsLabelsMatchLabelSelector(labels, *s.Labels) {
		return false
	}
	return true
}
