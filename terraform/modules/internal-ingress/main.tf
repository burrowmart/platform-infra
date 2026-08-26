# The Cloudflare Tunnel forwards every public hostname to this controller's
# ClusterIP Service. From there, nginx does host/path -> backend Service
# routing using the per-service Ingress resources each service's own Helm
# chart creates (base-service chart, ingressClassName: nginx-internal).
#
# controller.service.type is pinned to ClusterIP — the only Service type
# used anywhere in this tree. Nothing here is internet-facing or exposed via
# a cloud load balancer or a host-level port.
resource "helm_release" "ingress_nginx_internal" {
  name             = "ingress-nginx-internal"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = true
  atomic           = true
  timeout          = 300

  values = [
    yamlencode({
      # fullnameOverride + controller.name="" makes the rendered Service name
      # exactly "ingress-nginx-internal" (the chart's fullname-controller
      # naming collapses to fullname when controller.name is empty), matching
      # the hostname the cloudflare-tunnel module's local config hardcodes.
      fullnameOverride = "ingress-nginx-internal"

      controller = {
        name = ""

        replicaCount = var.replica_count

        # ---------------------------------------------------------------
        # Required for the base-service chart to deploy at all.
        #
        # Every service's Ingress carries
        # nginx.ingress.kubernetes.io/configuration-snippet, which seeds
        # x-correlation-id from Cloudflare's $http_cf_ray — the start of the
        # correlation chain ARCHITECTURE.md's acceptance criterion 3 depends
        # on. ingress-nginx disables snippet annotations by default since
        # v1.9 (CVE-2021-25742), and v1.12+ additionally gates them behind an
        # annotations risk level. With either left at its default, the
        # admission webhook REJECTS the Ingress outright:
        #
        #   admission webhook "validate.nginx.ingress.kubernetes.io" denied
        #   the request: annotation group ConfigurationSnippet contains risky
        #   annotation based on ingress configuration
        #
        # i.e. every `helm upgrade --install` in CI fails. Verified against
        # ingress-nginx on a kind cluster: both settings are needed, neither
        # alone is enough.
        #
        # This re-opens the class of attack those defaults guard against
        # (snippet injection via a crafted Ingress). It is acceptable here
        # only because Ingress objects come exclusively from this repo's own
        # charts and CI has no path to create arbitrary ones. If untrusted
        # tenants ever get to create Ingresses in this cluster, move the
        # header injection into the controller's global config
        # (controller.config.http-snippet) and drop both of these.
        allowSnippetAnnotations = true

        config = merge({
          "annotations-risk-level" = "Critical"
        }, var.controller_config)

        ingressClassResource = {
          name            = var.ingress_class_name
          default         = false
          controllerValue = "k8s.io/${var.ingress_class_name}"
        }
        ingressClass             = var.ingress_class_name
        watchIngressWithoutClass = false
        electionID               = "${var.ingress_class_name}-leader"

        service = {
          type = "ClusterIP"
        }

        resources = var.resources
      }
    })
  ]
}
