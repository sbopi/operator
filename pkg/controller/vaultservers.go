package controller

import (
	"context"

	"github.com/appscode/go/encoding/json/types"
	apps_util "github.com/appscode/kutil/apps/v1"
	core_util "github.com/appscode/kutil/core/v1"
	meta_util "github.com/appscode/kutil/meta"
	rbac_util "github.com/appscode/kutil/rbac/v1"
	"github.com/appscode/kutil/tools/queue"
	"github.com/golang/glog"
	api "github.com/kubevault/operator/apis/kubevault/v1alpha1"
	patchutil "github.com/kubevault/operator/client/clientset/versioned/typed/kubevault/v1alpha1/util"
	"github.com/kubevault/operator/pkg/vault/util"
	"github.com/pkg/errors"
	appsv1 "k8s.io/api/apps/v1"
	core "k8s.io/api/core/v1"
	rbac "k8s.io/api/rbac/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

func (c *VaultController) initVaultServerWatcher() {
	c.vsInformer = c.extInformerFactory.Kubevault().V1alpha1().VaultServers().Informer()
	c.vsQueue = queue.New("VaultServer", c.MaxNumRequeues, c.NumThreads, c.runVaultServerInjector)
	c.vsInformer.AddEventHandler(queue.NewObservableHandler(c.vsQueue.GetQueue(), api.EnableStatusSubresource))
	c.vsLister = c.extInformerFactory.Kubevault().V1alpha1().VaultServers().Lister()
}

// runVaultSeverInjector gets the vault server object indexed by the key from cache
// and initializes, reconciles or garbage collects the vault cluster as needed.
func (c *VaultController) runVaultServerInjector(key string) error {
	obj, exists, err := c.vsInformer.GetIndexer().GetByKey(key)
	if err != nil {
		glog.Errorf("Fetching object with key %s from store failed with %v", key, err)
		return err
	}

	if !exists {
		// Below we will warm up our cache with a VaultServer, so that we will see a delete for one d
		glog.Warningf("VaultServer %s does not exist anymore\n", key)

		// stop vault status monitor
		if cancel, ok := c.ctxCancels[key]; ok {
			cancel()
			delete(c.ctxCancels, key)
		}

	} else {
		vs := obj.(*api.VaultServer).DeepCopy()

		glog.Infof("Sync/Add/Update for VaultServer %s/%s\n", vs.Namespace, vs.Name)

		v, err := NewVault(vs, c.kubeClient, c.extClient)
		if err != nil {
			return errors.Wrapf(err, "for VaultServer %s/%s", vs.Namespace, vs.Name)
		}

		err = c.reconcileVault(vs, v)
		if err != nil {
			return errors.Wrapf(err, "for VaultServer %s/%s", vs.Namespace, vs.Name)
		}
	}
	return nil
}

// reconcileVault reconciles the vault cluster's state to the spec specified by v
// by preparing the TLS secrets, deploying vault cluster,
// and finally updating the vault deployment if needed.
func (c *VaultController) reconcileVault(vs *api.VaultServer, v Vault) error {
	status := vs.Status

	err := c.CreateVaultTLSSecret(vs, v)
	if err != nil {
		status.Conditions = []api.VaultServerCondition{
			{
				Type:    api.VaultServerConditionFailure,
				Status:  core.ConditionTrue,
				Reason:  "FailedToCreateVaultTLSSecret",
				Message: err.Error(),
			},
		}

		err2 := c.updatedVaultServerStatus(&status, vs)
		if err2 != nil {
			return errors.Wrap(err2, "failed to update status")
		}
		return errors.Wrap(err, "failed to create vault server tls secret")
	}

	err = c.CreateVaultConfig(vs, v)
	if err != nil {
		status.Conditions = []api.VaultServerCondition{
			{
				Type:    api.VaultServerConditionFailure,
				Status:  core.ConditionTrue,
				Reason:  "FailedToCreateVaultConfig",
				Message: err.Error(),
			},
		}

		err2 := c.updatedVaultServerStatus(&status, vs)
		if err2 != nil {
			return errors.Wrap(err2, "failed to update status")
		}
		return errors.Wrap(err, "failed to create vault config")
	}

	err = c.DeployVault(vs, v)
	if err != nil {
		status.Conditions = []api.VaultServerCondition{
			{
				Type:    api.VaultServerConditionFailure,
				Status:  core.ConditionTrue,
				Reason:  "FailedToDeployVault",
				Message: err.Error(),
			},
		}

		err2 := c.updatedVaultServerStatus(&status, vs)
		if err2 != nil {
			return errors.Wrap(err2, "failed to update status")
		}
		return errors.Wrap(err, "failed to deploy vault")
	}

	status.Conditions = []api.VaultServerCondition{}
	status.ObservedGeneration = types.NewIntHash(vs.Generation, meta_util.GenerationHash(vs))
	err = c.updatedVaultServerStatus(&status, vs)
	if err != nil {
		return errors.Wrap(err, "failed to update status")
	}

	// Add vault monitor to watch vault seal or unseal status
	key := vs.GetKey()
	if _, ok := c.ctxCancels[key]; !ok {
		ctx, cancel := context.WithCancel(context.Background())
		c.ctxCancels[key] = cancel
		go c.monitorAndUpdateStatus(ctx, vs)
	}
	return nil
}

func (c *VaultController) CreateVaultTLSSecret(vs *api.VaultServer, v Vault) error {
	sr, err := v.GetServerTLS()
	if err != nil {
		return err
	}
	return ensureSecret(c.kubeClient, vs, sr)
}

func (c *VaultController) CreateVaultConfig(vs *api.VaultServer, v Vault) error {
	cm, err := v.GetConfig()
	if err != nil {
		return err
	}
	return ensureConfigMap(c.kubeClient, vs, cm)
}

// - create service account for vault pod
// - create deployment
// - create service
// - create rbac role and rolebinding
func (c *VaultController) DeployVault(vs *api.VaultServer, v Vault) error {
	sa := v.GetServiceAccount()
	err := ensureServiceAccount(c.kubeClient, vs, sa)
	if err != nil {
		return err
	}

	podT := v.GetPodTemplate(v.GetContainer(), sa.Name)

	err = v.Apply(podT)
	if err != nil {
		return err
	}

	d := v.GetDeployment(podT)
	err = ensureDeployment(c.kubeClient, vs, d)
	if err != nil {
		return err
	}

	svc := v.GetService()
	err = ensureService(c.kubeClient, vs, svc)
	if err != nil {
		return err
	}

	roles := v.GetRBACRoles()
	err = ensureRoleAndRoleBinding(c.kubeClient, vs, roles, sa.Name)
	if err != nil {
		return err
	}
	return nil
}

func (c *VaultController) updatedVaultServerStatus(status *api.VaultServerStatus, vs *api.VaultServer) error {
	_, err := patchutil.UpdateVaultServerStatus(c.extClient.KubevaultV1alpha1(), vs, func(s *api.VaultServerStatus) *api.VaultServerStatus {
		s = status
		return s
	})
	if err != nil {
		return err
	}
	return nil
}

// ensureServiceAccount creates/patches service account
func ensureServiceAccount(kc kubernetes.Interface, vs *api.VaultServer, sa *core.ServiceAccount) error {
	_, _, err := core_util.CreateOrPatchServiceAccount(kc, sa.ObjectMeta, func(in *core.ServiceAccount) *core.ServiceAccount {
		in.Labels = core_util.UpsertMap(in.Labels, sa.Labels)
		util.EnsureOwnerRefToObject(in, util.AsOwner(vs))
		return in
	})
	return err
}

// ensureDeployment creates/patches deployment
func ensureDeployment(kc kubernetes.Interface, vs *api.VaultServer, d *appsv1.Deployment) error {
	_, _, err := apps_util.CreateOrPatchDeployment(kc, d.ObjectMeta, func(in *appsv1.Deployment) *appsv1.Deployment {
		in.Labels = core_util.UpsertMap(in.Labels, d.Labels)
		in.Annotations = core_util.UpsertMap(in.Annotations, d.Annotations)
		in.Spec.Replicas = d.Spec.Replicas
		in.Spec.Selector = d.Spec.Selector
		in.Spec.Strategy = d.Spec.Strategy

		in.Spec.Template.Labels = d.Spec.Template.Labels
		in.Spec.Template.Annotations = d.Spec.Template.Annotations
		in.Spec.Template.Spec.Containers = core_util.UpsertContainers(in.Spec.Template.Spec.Containers, d.Spec.Template.Spec.Containers)
		in.Spec.Template.Spec.InitContainers = core_util.UpsertContainers(in.Spec.Template.Spec.InitContainers, d.Spec.Template.Spec.InitContainers)
		in.Spec.Template.Spec.ServiceAccountName = d.Spec.Template.Spec.ServiceAccountName
		in.Spec.Template.Spec.NodeSelector = d.Spec.Template.Spec.NodeSelector
		in.Spec.Template.Spec.Affinity = d.Spec.Template.Spec.Affinity
		if d.Spec.Template.Spec.SchedulerName != "" {
			in.Spec.Template.Spec.SchedulerName = d.Spec.Template.Spec.SchedulerName
		}
		in.Spec.Template.Spec.Tolerations = d.Spec.Template.Spec.Tolerations
		in.Spec.Template.Spec.ImagePullSecrets = d.Spec.Template.Spec.ImagePullSecrets
		in.Spec.Template.Spec.PriorityClassName = d.Spec.Template.Spec.PriorityClassName
		in.Spec.Template.Spec.Priority = d.Spec.Template.Spec.Priority
		in.Spec.Template.Spec.SecurityContext = d.Spec.Template.Spec.SecurityContext
		in.Spec.Template.Spec.Volumes = core_util.UpsertVolume(in.Spec.Template.Spec.Volumes, d.Spec.Template.Spec.Volumes...)

		util.EnsureOwnerRefToObject(in, util.AsOwner(vs))
		return in
	})
	return err
}

// ensureService creates/patches service
func ensureService(kc kubernetes.Interface, vs *api.VaultServer, svc *core.Service) error {
	_, _, err := core_util.CreateOrPatchService(kc, svc.ObjectMeta, func(in *core.Service) *core.Service {
		in.Labels = core_util.UpsertMap(in.Labels, svc.Labels)
		in.Annotations = core_util.UpsertMap(in.Annotations, svc.Annotations)

		in.Spec.Selector = svc.Spec.Selector
		in.Spec.Ports = core_util.MergeServicePorts(in.Spec.Ports, svc.Spec.Ports)
		if svc.Spec.ClusterIP != "" {
			in.Spec.ClusterIP = svc.Spec.ClusterIP
		}
		if svc.Spec.Type != "" {
			in.Spec.Type = svc.Spec.Type
		}
		if svc.Spec.LoadBalancerIP != "" {
			in.Spec.LoadBalancerIP = svc.Spec.LoadBalancerIP
		}
		in.Spec.ExternalIPs = svc.Spec.ExternalIPs
		in.Spec.LoadBalancerSourceRanges = svc.Spec.LoadBalancerSourceRanges
		in.Spec.ExternalTrafficPolicy = svc.Spec.ExternalTrafficPolicy
		if svc.Spec.HealthCheckNodePort > 0 {
			in.Spec.HealthCheckNodePort = svc.Spec.HealthCheckNodePort
		}
		util.EnsureOwnerRefToObject(in, util.AsOwner(vs))
		return in
	})
	return err
}

// ensureRoleAndRoleBinding creates or patches rbac role and rolebinding
func ensureRoleAndRoleBinding(kc kubernetes.Interface, vs *api.VaultServer, roles []rbac.Role, saName string) error {
	labels := vs.OffshootLabels()

	for _, role := range roles {
		_, _, err := rbac_util.CreateOrPatchRole(kc, role.ObjectMeta, func(in *rbac.Role) *rbac.Role {
			in.Labels = core_util.UpsertMap(in.Labels, role.Labels)
			in.Annotations = core_util.UpsertMap(in.Annotations, role.Annotations)
			in.Rules = role.Rules
			util.EnsureOwnerRefToObject(in, util.AsOwner(vs))
			return in
		})
		if err != nil {
			return errors.Wrapf(err, "failed to create rbac role %s/%s", role.Namespace, role.Name)
		}

		rObj := metav1.ObjectMeta{
			Name:      role.Name,
			Namespace: vs.Namespace,
			Labels:    labels,
		}
		_, _, err = rbac_util.CreateOrPatchRoleBinding(kc, rObj, func(in *rbac.RoleBinding) *rbac.RoleBinding {
			in.Labels = core_util.UpsertMap(in.Labels, rObj.Labels)
			in.RoleRef = rbac.RoleRef{
				APIGroup: rbac.GroupName,
				Kind:     "Role",
				Name:     role.Name,
			}
			in.Subjects = []rbac.Subject{
				{
					Kind:      rbac.ServiceAccountKind,
					Name:      saName,
					Namespace: vs.Namespace,
				},
			}
			util.EnsureOwnerRefToObject(in, util.AsOwner(vs))
			return in
		})
		if err != nil {
			return errors.Wrapf(err, "failed to create rbac role binding %s/%s", rObj.Namespace, rObj.Name)
		}
	}
	return nil
}

// ensureSecret creates/patches secret
func ensureSecret(kc kubernetes.Interface, vs *api.VaultServer, s *core.Secret) error {
	_, _, err := core_util.CreateOrPatchSecret(kc, s.ObjectMeta, func(in *core.Secret) *core.Secret {
		in.Labels = core_util.UpsertMap(in.Labels, s.Labels)
		in.Annotations = core_util.UpsertMap(in.Annotations, s.Annotations)
		in.Data = s.Data
		util.EnsureOwnerRefToObject(in, util.AsOwner(vs))
		return in
	})
	return err
}

// ensureConfigMap creates/patches configMap
func ensureConfigMap(kc kubernetes.Interface, vs *api.VaultServer, cm *core.ConfigMap) error {
	_, _, err := core_util.CreateOrPatchConfigMap(kc, cm.ObjectMeta, func(in *core.ConfigMap) *core.ConfigMap {
		in.Labels = core_util.UpsertMap(in.Labels, cm.Labels)
		in.Annotations = core_util.UpsertMap(in.Annotations, cm.Annotations)
		in.Data = cm.Data
		util.EnsureOwnerRefToObject(in, util.AsOwner(vs))
		return in
	})
	return err
}
