package kcp

import (
	"context"

	ws "github.com/kcp-dev/kcp/pkg/apis/tenancy/v1beta1"

	kubeCl "github.com/redhat-appstudio/e2e-tests/pkg/apis/kubernetes"
	rclient "sigs.k8s.io/controller-runtime/pkg/client"
)

type SuiteController struct {
	*kubeCl.K8sClient
}

func NewSuiteController(kubeC *kubeCl.K8sClient) (*SuiteController, error) {
	return &SuiteController{
		kubeC,
	}, nil
}

func (s *SuiteController) ListKCPWorkspaces() (*ws.WorkspaceList, error) {
	workspaces := &ws.WorkspaceList{}
	if err := s.KubeRest().List(context.TODO(), workspaces, &rclient.ListOptions{}); err != nil {
		return &ws.WorkspaceList{}, err
	}
	return workspaces, nil
}

func (s *SuiteController) DeleteKCPWorkspace(ws *ws.Workspace) error {
	if err := s.KubeRest().Delete(context.TODO(), ws, &rclient.DeleteOptions{}); err != nil {
		return err
	}
	return nil
}
