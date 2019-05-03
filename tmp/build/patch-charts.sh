#!/usr/bin/env bash

set -e

: ${HELM_DIR:?"Need to set HELM_DIR to output location for charts, e.g. tmp/_output/istio-releases/istio-1.1.0"}
: ${SOURCE_DIR:?"Need to set SOURCE_DIR to location of the istio-operator source directory"}

: ${THREESCALE_VERSION:=0.5.0}
: ${KIALI_VERSION:=0.16.2}

# copy maistra specific templates into charts
function copyOverlay() {
  echo "copying Maistra chart customizations over stock Istio charts"
  find "${SOURCE_DIR}/helm/" -maxdepth 1 -mindepth 1 -type d | xargs -I '{}' -n 1 -rt cp -r '{}' ${HELM_DIR}
}

# The following modifications are made to the generated helm template for the Istio yaml files
# - remove the create customer resources job, we handle this in the installer to deal with potential races
# - remove the cleanup secrets job, we handle this in the installer
# - remove the kubernetes gateways
# - change privileged value on istio-proxy injection configmap to false
# - update the namespaceSelector to ignore namespaces with the label istio.openshift.com/ignore-namespace
# - add a maistra-version label to all objects which have a release label
# - remove GODEBUG from the pilot environment
# - remove istio-multi service account
# - remove istio-multi cluster role binding
# - remove istio-reader cluster role
# - switch prometheus init container image from busybox to prometheus
# - switch webhook ports to 8443
# - switch health check files into /tmp
function patchTemplates() {
  echo "patching Helm charts"

  # Webhooks are not namespaced!  we do this to ensure we're not setting owner references on them
  sed -i -e '/metadata:/,/webhooks:/ { /namespace/d }' \
    ${HELM_DIR}/istio/charts/sidecarInjectorWebhook/templates/mutatingwebhookconfiguration.yaml.tpl \
    ${HELM_DIR}/istio/charts/galley/templates/validatingwebhookconfiguration.yaml.tpl

  # update global defaults
  # disable autoInject
  # enable grafana, tracing and kiali, by default
  sed -i -e 's/autoInject:.*$/autoInject: disabled/' \
         -e '/grafana:/,/enabled/ { s/enabled: .*$/enabled: true/ }' \
         -e '/tracing:/,/enabled/ { s/enabled: .*$/enabled: true/ }' \
         -e '/kiali:/,/enabled/ { s/enabled: .*$/enabled: true/ }' ${HELM_DIR}/istio/values.yaml

  # enable all namespaces by default
  sed -i -e 's/enableNamespacesByDefault:.*$/enableNamespacesByDefault: true/' ${HELM_DIR}/istio/charts/sidecarInjectorWebhook/values.yaml

  # enable egressgateway
  sed -i -e '/istio-egressgateway:/,/enabled/ { s/enabled: .*$/enabled: true/ }' ${HELM_DIR}/istio/charts/gateways/values.yaml
  # add support for IOR
  sed -i -e '/istio-ingressgateway:/,/enabled:/ {
    /enabled:/ a\
\  # set to true to enable route creation\
\  ior_enabled: false\
\  ior_image: ior\

  }' ${HELM_DIR}/istio/charts/gateways/values.yaml
  if [[ "${COMMUNITY,,}" == "true" ]]; then
    sed -i -e 's/ior_image:.*$/ior_image: ior-centos7/' ${HELM_DIR}/istio/charts/gateways/values.yaml
  fi

  # enable ingress for grafana
  sed -i -e '/ingress:/,/enabled/ { s/enabled: .*$/enabled: true/ }' ${HELM_DIR}/istio/charts/grafana/values.yaml

  # enable ingress for tracing
  sed -i -e '/ingress:/,/enabled/ { s/enabled: .*$/enabled: true/ }' ${HELM_DIR}/istio/charts/tracing/values.yaml

  # enable ingress for kaili
  # update hub/tag
  sed -i -e '/ingress:/,/enabled/ { s/enabled: .*$/enabled: true/ }' ${HELM_DIR}/istio/charts/kiali/values.yaml
  if [[ "${COMMUNITY,,}" == "true" ]]; then
    sed -i -e 's/hub:.*$/hub: kiali/' \
           -e 's/tag:.*$/tag: v'${KIALI_VERSION}'/' ${HELM_DIR}/istio/charts/kiali/values.yaml
  else
    sed -i -e 's+hub:.*$+hub: openshift-istio-tech-preview+' \
           -e 's/tag:.*$/tag: '${KIALI_VERSION}'/' ${HELM_DIR}/istio/charts/kiali/values.yaml
  fi

  # - remove the create customer resources job, we handle this in the installer to deal with potential races
  rm ${HELM_DIR}/istio/charts/grafana/templates/create-custom-resources-job.yaml

  # - remove the cleanup secrets job, we handle this in the installer
  rm ${HELM_DIR}/istio/charts/security/templates/cleanup-secrets.yaml

  # - we create custom resources in the normal way
  if [ "${PATCH_1_0}" == "" ]; then
    rm ${HELM_DIR}/istio/charts/security/templates/create-custom-resources-job.yaml
    rm ${HELM_DIR}/istio/charts/security/templates/configmap.yaml

    # now make sure they're available
    sed -i -e 's/define "security-default\.yaml\.tpl"/if and .Values.createMeshPolicy .Values.global.mtls.enabled/' ${HELM_DIR}/istio/charts/security/templates/enable-mesh-mtls.yaml
    sed -i -e 's/define "security-permissive\.yaml\.tpl"/if and .Values.createMeshPolicy (not .Values.global.mtls.enabled)/' ${HELM_DIR}/istio/charts/security/templates/enable-mesh-permissive.yaml
  fi

  # - remove the kubernetes gateways
  # this no longer exists
  # rm ${HELM_DIR}istio/charts/pilot/templates/gateway.yaml

  # - remove GODEBUG from the pilot environment (and mixer too)
  sed -i -e '/GODEBUG/d' ${HELM_DIR}/istio/charts/pilot/values.yaml ${HELM_DIR}/istio/charts/mixer/values.yaml

  # - change privileged value on istio-proxy injection configmap to false
  # setting the proper values will fix this:
  # global.proxy.privileged=false
  # global.proxy.enableCoreDump=false
  # however, we need to ensure privileged is set for istio_init
  sed -i -e '/- name: istio-init/,/- name: enable-core-dump/ {
    /- NET_ADMIN/,+3 {
      /{{/d
    }
  }' ${HELM_DIR}/istio/templates/sidecar-injector-configmap.yaml

  # - update the namespaceSelector to ignore namespaces with the label istio.openshift.com/ignore-namespace
  # set sidecarInjectorWebhook.enableNamespacesByDefault=true
  sed -i -e '/if \.Values\.enableNamespacesByDefault/,/else/s/istio-injection/istio.openshift.com\/ignore-namespace/' \
         -e 's/NotIn/DoesNotExist/' \
         -e '/values/d' \
         -e '/disabled/d' ${HELM_DIR}/istio/charts/sidecarInjectorWebhook/templates/mutatingwebhookconfiguration.yaml.tpl

  # - add a maistra-version label to all objects which have a release label
  find ${HELM_DIR} -name "*.yaml" -o -name "*.yaml.tpl" | \
    xargs sed -i -e 's/^\(.*\)release:\(.*\)$/\1maistra-version: '${MAISTRA_VERSION}'\
\1release:\2/'

  # update the images
  # set global.hub=docker.io/maistra
  if [[ "${COMMUNITY,,}" == "true" ]]; then
    sed -i -e 's+hub:.*$+hub: docker.io/maistra+g' \
          -e 's/tag:.*$/tag: '${MAISTRA_VERSION}'/' \
          -e 's/image: *proxy_init/image: proxy-init-centos7/' \
          -e 's/image: *proxyv2/image: proxyv2-centos7/' ${HELM_DIR}/istio/values.yaml ${HELM_DIR}/istio-init/values.yaml
    sed -i -e 's/image: *galley/image: galley-centos7/' ${HELM_DIR}/istio/charts/galley/values.yaml
    sed -i -e 's/image: *sidecar_injector/image: sidecar-injector-centos7/' ${HELM_DIR}/istio/charts/sidecarInjectorWebhook/values.yaml
    sed -i -e 's/image: *mixer/image: mixer-centos7/' ${HELM_DIR}/istio/charts/mixer/values.yaml
    sed -i -e 's/image: *pilot/image: pilot-centos7/' ${HELM_DIR}/istio/charts/pilot/values.yaml
    sed -i -e 's/image: *citadel/image: citadel-centos7/' ${HELM_DIR}/istio/charts/security/values.yaml
    sed -i -e 's|\(^jaeger:.*$\)|elasticsearch:\
  hub: registry.centos.org/rhsyseng\
  image: elasticsearch\
  tag: 5.6.10\
\
\1|' ${HELM_DIR}/istio/charts/tracing/values.yaml
    sed -i -e 's/hub:.*$/hub: openshift-istio-tech-preview/' \
           -e 's/tag:.*$/tag: v'${THREESCALE_VERSION}'/' ${HELM_DIR}/maistra-threescale/values.yaml
  else
    sed -i -e 's+hub:.*$+hub: openshift-istio-tech-preview+g' \
          -e 's/tag:.*$/tag: '${MAISTRA_VERSION}'/' \
          -e 's/image: *proxy_init/image: proxy-init/' \
          -e 's/image: *proxyv2/image: proxyv2/' ${HELM_DIR}/istio/values.yaml ${HELM_DIR}/istio-init/values.yaml
    sed -i -e 's/image: *galley/image: galley/' ${HELM_DIR}/istio/charts/galley/values.yaml
    sed -i -e 's/image: *sidecar_injector/image: sidecar-injector/' ${HELM_DIR}/istio/charts/sidecarInjectorWebhook/values.yaml
    sed -i -e 's/image: *mixer/image: mixer/' ${HELM_DIR}/istio/charts/mixer/values.yaml
    sed -i -e 's/image: *pilot/image: pilot/' ${HELM_DIR}/istio/charts/pilot/values.yaml
    sed -i -e 's/image: *citadel/image: citadel/' ${HELM_DIR}/istio/charts/security/values.yaml
    sed -i -e 's|\(^jaeger:.*$\)|elasticsearch:\
  hub: registry.centos.org/rhsyseng\
  image: elasticsearch\
  tag: 5.6.10\
\
\1|' ${HELM_DIR}/istio/charts/tracing/values.yaml
    sed -i -e 's/hub:.*$/hub: openshift-istio-tech-preview/' \
           -e 's/tag:.*$/tag: '${THREESCALE_VERSION}'/' ${HELM_DIR}/maistra-threescale/values.yaml
  fi

  # - remove istio-multi service account
  rm ${HELM_DIR}/istio/templates/serviceaccount.yaml
  # - remove istio-multi cluster role binding
  rm ${HELM_DIR}/istio/templates/clusterrolebinding.yaml
  # - remove istio-reader cluster role
  rm ${HELM_DIR}/istio/templates/clusterrole.yaml
  
  # - switch prometheus init container image from busybox to prometheus
  sed -i -r -e 's/"?busybox:?.*$/"docker.io\/prom\/prometheus:v2.3.1"/' ${HELM_DIR}/istio/charts/prometheus/templates/deployment.yaml

  # - enable ingress (route) for prometheus
  sed -i -e '/ingress:/,/service:/ {
    s/enabled:.*$/enabled: true/
}' ${HELM_DIR}/istio/charts/prometheus/values.yaml

  # - switch webhook ports to 8443: add targetPort name to galley service
  # XXX: move upstream (add targetPort name)
  sed -i -e 's/^\(.*\)\(- port: 443.*\)$/\1\2\
\1  targetPort: webhook/' ${HELM_DIR}/istio/charts/galley/templates/service.yaml

  # - switch webhook ports to 8443
  # add name to webhook port (XXX: move upstream)
  # change the location of the healthCheckFile from /health to /tmp/health
  # add --validation-port=8443
  sed -i -e 's/^\(.*\)\- containerPort: 443.*$/\1- name: webhook\
\1  containerPort: 8443/' \
           -e 's/\/health/\/tmp\/health/' \
           -e 's/^\(.*\)\(- --monitoringPort.*\)$/\1\2\
\1- --validation-port=8443/' ${HELM_DIR}/istio/charts/galley/templates/deployment.yaml

  # - switch webhook ports to 8443
  # XXX: move upstream (add targetPort name)
  sed -i -e 's/^\(.*\)\(- port: 443.*\)$/\1\2\
\1  targetPort: webhook/' ${HELM_DIR}/istio/charts/sidecarInjectorWebhook/templates/service.yaml

  # - switch webhook ports to 8443
  # add webhook port
  sed -i -e 's/^\(.*\)\(volumeMounts:.*\)$/\1  - --port=8443\
\1ports:\
\1- name: webhook\
\1  containerPort: 8443\
\1\2/' ${HELM_DIR}/istio/charts/sidecarInjectorWebhook/templates/deployment.yaml

  # change the location of the healthCheckFile from /health to /tmp/health
  if [[ "${COMMUNITY,,}" != "true" ]]; then
    sed -i -e 's/\/health/\/tmp\/health/' ${HELM_DIR}/istio/charts/sidecarInjectorWebhook/templates/deployment.yaml
  fi

}

# The following modifications are made to the generated helm template to extract the CRDs
# - remove all content except for the crd configmaps
# - add maistra-version labels
# all of this is done above in patchTemplates()

# The following modifications are made to the generated helm template for the Grafana yaml file
# - add a service account for grafana
# - remove all non grafana configuration
# - remove the extraneous create custom resources job
# - add the service account to the deployment
# - add a maistra-version label to all objects which have a release label (done in patchTemplates())
function patchGrafanaTemplate() {
  echo "patching Grafana specific Helm charts"

  # - add a service account for grafana
  # added a file to overlays

  # - remove the extraneous create custom resources job
  if [ -f ${HELM_DIR}/istio/charts/grafana/templates/create-custom-resources-job.yaml ]; then
    rm ${HELM_DIR}/istio/charts/grafana/templates/create-custom-resources-job.yaml
  fi

  # - custom resources will be installed directly
  if [ -f ${HELM_DIR}/istio/charts/grafana/templates/configmap-custom-resources.yaml ]; then
    rm ${HELM_DIR}/istio/charts/grafana/templates/configmap-custom-resources.yaml
  fi
  sed -i -e '/grafana-default.yaml.tpl/d' -e '/{{.*end.*}}/d' ${HELM_DIR}/istio/charts/grafana/templates/grafana-ports-mtls.yaml

  # - add the service account to the deployment
  sed -i -e 's/^\(.*\)containers:\(.*\)$/\1serviceAccountName: grafana\
\1containers:\2/' ${HELM_DIR}/istio/charts/grafana/templates/deployment.yaml
}

# patch tracing specific templates
function patchTracingtemplate() {
  echo "patching Jaeger (tracing) specific Helm charts"
  # update jaeger image hub
  if [[ "${COMMUNITY,,}" == "true" ]]; then
    sed -i -e 's+hub: docker.io/jaegertracing+hub: jaegertracing+g' \
           -e 's+tag: 1.9+tag: 1.11+g' ${HELM_DIR}/istio/charts/tracing/values.yaml
  else
    sed -i -e 's+hub: docker.io/jaegertracing+hub: distributed-tracing-tech-preview+g' \
           -e 's+tag: 1.9+tag: 1.11.0+g' ${HELM_DIR}/istio/charts/tracing/values.yaml
  fi

  # update jaeger zipkin port name
  sed -i -e '/service:$/,/externalPort:/ {
    s/name:.*$/name: jaeger-collector-zipkin/
}' ${HELM_DIR}/istio/charts/tracing/values.yaml

}

# The following modifications are made to the generated helm template for the Kiali yaml file
# - remove all non kiali configuration
# - remove the kiali username/password secret
function patchKialiTemplate() {
  echo "patching Kiali specific Helm charts"

  # - remove the kiali username/password secret
 rm ${HELM_DIR}/istio/charts/kiali/templates/demosecret.yaml
}

# The following modifications are made to the upstream kiali configuration for deployment on OpenShift
# - Add jaeger and grafana URLs to the configmap as well as the identity certs
# - Add the route.openshift.io api group to the cluster role
# - Add the openshift annotation to the service
# - Remove the prometheus, grafana environment from the deployment
# - Add the kiali-cert volume mount
# - Add the kiali-cert volume
# - Add istio namespace to the configmap
function patchKialiOpenShift() {
  echo "more patching of Kiali specific Helm charts"
  # - Add jaeger and grafana URLs to the configmap as well as the identity certs
  #   these should be defined in the values file kiali.dashboard.grafanaURL
  #   and kiali.dashboard.jaegerURL.  If not specified, the URLs should be
  #   determined from the routes created for Jaeger and Grafana.  This needs to
  #   be done after rendering, unfortunately.
  # - Add istio namespace to the configmap (for 1.0 templates)
  # - Add the kiali-cert volume mount
  # - Add the kiali-cert volume
  if [ -n "${PATCH_1_0}" ]; then
    sed -i -e '/server:/ i\
\    istio_namespace: {{ .Release.Namespace }}' ${HELM_DIR}/istio/charts/kiali/templates/configmap.yaml
  fi
  sed -i -e '/port: 20001/ a\
\      static_content_root_directory: /opt/kiali/console' \
         -e '/grafana:/,/url:/ {
             /url:/ a\
\{\{- if not (and (.Values.dashboard.user) (.Values.dashboard.passphrase)) \}\}\
\    auth:\
\      strategy: openshift\
\{\{- end \}\}\
\    identity:\
\      cert_file: /kiali-cert/tls.crt\
\      private_key_file: /kiali-cert/tls.key
             }' ${HELM_DIR}/istio/charts/kiali/templates/configmap.yaml

#  # - Add the openshift annotation to the service
#  sed -i -e '/metadata/ a\
#\  annotations:\
#\    service.alpha.openshift.io/serving-cert-secret-name: kiali-cert-secret' ${HELM_DIR}/istio/charts/kiali/templates/service.yaml
  
  # - Remove the prometheus, grafana environment from the deployment
  sed -i -e '/SERVER_CREDENTIALS_USERNAME/,/volumeMounts/ {
    /volumeMounts/b
    d
  }' ${HELM_DIR}/istio/charts/kiali/templates/deployment.yaml
  
  # - Add the kiali-cert volume mount
  # - Add the kiali-cert volume
  sed -i -e '/kind.*Deployment$/,/^.*affinity:/ {
    /volumeMounts:/ {
      N
      N
      a\
\        - name: kiali-cert\
\          mountPath: "/kiali-cert"\
\{\{- if and (.Values.dashboard.user) (.Values.dashboard.passphrase) \}\}\
\        - name: kiali-secret\
\          mountPath: "/kiali-secret"\
\{\{- end \}\}
    }
    /configMap:/ {
      N
      a\
\      - name: kiali-cert\
\        secret:\
\          secretName: kiali-cert-secret\
\{\{- if and (.Values.dashboard.user) (.Values.dashboard.passphrase) \}\}\
\      - name: kiali-secret\
\        secret:\
\          secretName: \{\{ .Values.dashboard.secretName \}\}\
\{\{- end \}\}
    }
  }' ${HELM_DIR}/istio/charts/kiali/templates/deployment.yaml

  # - add authorization details for authentication.istio.io (for 1.0 templates)
  if [ -n "${PATCH_1_0}" ]; then
    sed -i -e '/apiGroups:.*networking.istio.io/,/^-/ {
      /- watch/ a\
\- apiGroups: ["authentication.istio.io"]\
\  resources:\
\  - policies\
\  - meshpolicies\
\  verbs:\
\  - create\
\  - delete\
\  - get\
\  - list\
\  - patch\
\  - watch
    }' ${HELM_DIR}/istio/charts/kiali/templates/clusterrole.yaml
  fi

  # add monitoring.kiali.io
  sed -i -e '/apiGroups:.*authentication.istio.io/,/^-/ {
      /- policies/ a\
\  - meshpolicies
      /- watch/ a\
\- apiGroups: ["monitoring.kiali.io"]\
\  resources:\
\  - monitoringdashboards\
\  verbs:\
\  - get\
\- apiGroups: ["rbac.istio.io"]\
\  resources:\
\  - clusterrbacconfigs\
\  - serviceroles\
\  - servicerolebindings\
\  verbs:\
\  - create\
\  - delete\
\  - get\
\  - list\
\  - patch\
\  - watch
  }' ${HELM_DIR}/istio/charts/kiali/templates/clusterrole.yaml
  
  # - add create verb to config.istio.io (for 1.0 templates)
  if [ -n "${PATCH_1_0}" ]; then
    sed -i -e '/apiGroups:.*config.istio.io/,/^-/ {
      /verbs:/ a\
\  - create
    }' ${HELM_DIR}/istio/charts/kiali/templates/clusterrole.yaml
  fi
  
  # - add create verb to networking.istio.io  (for 1.0 templates)
  if [ -n "${PATCH_1_0}" ]; then
    sed -i -e '/apiGroups:.*networking.istio.io/,/^-/ {
      /verbs:/ a\
\  - create
    }' ${HELM_DIR}/istio/charts/kiali/templates/clusterrole.yaml
  fi

  # add new kiali-viewer role
  cat >> ${HELM_DIR}/istio/charts/kiali/templates/clusterrole.yaml << EOF
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kiali-viewer
  labels:
    app: {{ template "kiali.name" . }}
    chart: {{ template "kiali.chart" . }}
    heritage: {{ .Release.Service }}
    release: {{ .Release.Name }}
rules:
- apiGroups: [""]
  resources:
  - configmaps
  - endpoints
  - namespaces
  - nodes
  - pods
  - services
  - replicationcontrollers
  - routes
  verbs:
  - get
  - list
  - watch
- apiGroups: ["extensions", "apps"]
  resources:
  - deployments
  - statefulsets
  - replicasets
  verbs:
  - get
  - list
  - watch
- apiGroups: ["autoscaling"]
  resources:
  - horizontalpodautoscalers
  verbs:
  - get
  - list
  - watch
- apiGroups: ["batch"]
  resources:
  - cronjobs
  - jobs
  verbs:
  - get
  - list
  - watch
- apiGroups: ["config.istio.io"]
  resources:
  - apikeys
  - authorizations
  - checknothings
  - circonuses
  - deniers
  - fluentds
  - handlers
  - kubernetesenvs
  - kuberneteses
  - listcheckers
  - listentries
  - logentries
  - memquotas
  - metrics
  - opas
  - prometheuses
  - quotas
  - quotaspecbindings
  - quotaspecs
  - rbacs
  - reportnothings
  - rules
  - servicecontrolreports
  - servicecontrols
  - solarwindses
  - stackdrivers
  - statsds
  - stdios
  verbs:
  - get
  - list
  - watch
- apiGroups: ["networking.istio.io"]
  resources:
  - destinationrules
  - gateways
  - serviceentries
  - virtualservices
  verbs:
  - get
  - list
  - watch
- apiGroups: ["authentication.istio.io"]
  resources:
  - policies
  - meshpolicies
  verbs:
  - get
  - list
  - watch
- apiGroups: ["rbac.istio.io"]
  resources:
  - clusterrbacconfigs
  - rbacconfigs
  - serviceroles
  - servicerolebindings
  verbs:
  - get
  - list
  - watch
- apiGroups: ["apps.openshift.io"]
  resources:
  - deploymentconfigs
  verbs:
  - get
  - list
  - watch
- apiGroups: ["project.openshift.io"]
  resources:
  - projects
  verbs:
  - get
- apiGroups: ["route.openshift.io"]
  resources:
  - routes
  verbs:
  - get
- apiGroups: ["monitoring.kiali.io"]
  resources:
  - monitoringdashboards
  verbs:
  - get
EOF
}

copyOverlay

patchTemplates
patchGrafanaTemplate
patchTracingtemplate
#patchKialiTemplate
#patchKialiOpenShift
